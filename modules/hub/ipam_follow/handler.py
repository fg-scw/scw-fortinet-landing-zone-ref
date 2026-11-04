"""Moves the firewall data VIPs in IPAM to the real NIC MACs of a node.

The VPC router takes the next hop of the hub VIP from its last writer: a
Gratuitous ARP or this IPAM reservation. FGCP's Gratuitous ARP moves the
traffic first; this function keeps IPAM right and is a second path if that ARP
has no effect. The automation stitch of the node that just became primary
POSTs {"node": "<hostname>", "at": "<event time, ns>"}. This code does not know
who is primary, and FortiOS can send a call long after its event: a call
naming a secondary would black-hole the hub. So a call older than the newest
one seen is refused; the Gratuitous ARP has already moved the traffic, and the
hourly reconcile puts IPAM right. It runs in a private Serverless Container
reached on its private endpoint in the hub Private Network: the platform
checks the token (X-Auth-Token) before this code runs.

Environment: REGION, NODES (JSON {hostname: [{ip_id, mac, name}, ...]}, hub
VIP first), secret SCW_SECRET_KEY (IAM application limited to IPAM).
"""

import json
import os
import threading
import urllib.error
import urllib.request

API = "https://api.scaleway.com/ipam/v1/regions/{region}/ips/{ip_id}"

# Kept in memory, hence max_scale = 1. Lost on restart; the reconcile corrects any late call.
latest = 0
lock = threading.Lock()


def call(method, url, body=None):
    req = urllib.request.Request(
        url,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"X-Auth-Token": os.environ["SCW_SECRET_KEY"], "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def follow(vip, region):
    """Moves one VIP to vip["mac"]; returns "in place" or "moved from <mac>"."""
    url = API.format(region=region, ip_id=vip["ip_id"])
    for _ in range(3):
        cur = ((call("GET", url).get("resource") or {}).get("mac_address") or "").lower()
        if cur == vip["mac"]:
            return "in place"
        move = {"to_resource": {"mac_address": vip["mac"], "name": vip["name"]}}
        if cur:
            move["from_resource"] = {"mac_address": cur}
        try:
            call("POST", url + "/move", move)
            return f"moved from {cur or 'nothing'}"
        except urllib.error.HTTPError as e:
            # 412: the holder changed between GET and move, read it again.
            if e.code != 412:
                raise
    raise RuntimeError(f"{vip['ip_id']}: holder kept changing")


def handle(event, context):
    global latest
    try:
        body = json.loads(event.get("body") or "{}")
        node, at = body.get("node"), int(body.get("at") or 0)
    except (ValueError, TypeError, AttributeError):
        node, at = None, 0
    vips = json.loads(os.environ["NODES"]).get(node)
    if not vips:
        print(json.dumps({"node": node, "error": "unknown node"}))
        return {"statusCode": 400, "body": f"unknown node {node!r}"}
    with lock:
        if at < latest:
            print(json.dumps({"node": node, "at": at, "latest": latest, "error": "stale call"}))
            return {"statusCode": 409, "body": "stale call"}
        latest = at
        result = {}
        try:
            for vip in vips:
                result[f'{vip["ip_id"]} -> {vip["mac"]}'] = follow(vip, os.environ["REGION"])
        except Exception as e:  # Logged to Cockpit; the hourly reconcile retries
            print(json.dumps({"node": node, "done": result, "error": str(e)}))
            return {"statusCode": 502, "body": json.dumps({"done": result, "error": str(e)})}
    print(json.dumps({"node": node, "done": result}))
    return {"statusCode": 200, "body": json.dumps(result)}


def serve():
    """HTTP server of the container: POST body -> handle()."""
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
            r = handle({"body": body}, None)
            out = r["body"].encode()
            self.send_response(r["statusCode"])
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

    ThreadingHTTPServer(("", int(os.environ.get("PORT", "8080"))), Handler).serve_forever()


if __name__ == "__main__":
    serve()
