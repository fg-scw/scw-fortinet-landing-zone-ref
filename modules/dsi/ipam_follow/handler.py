"""Moves the firewall data VIPs in IPAM to the real NIC MACs of a node.

The VPC router sends the hub ingress traffic to the MAC of the IPAM
reservation of the hub VIP, never to a gratuitous ARP: the VIPs must follow
the FGCP primary. The automation stitch of the node that just became primary
POSTs {"node": "<hostname>"}; every call is idempotent, so repeated or late
calls are harmless. The function is private: the platform checks the
function token (X-Auth-Token) before this code runs.

Environment: REGION, NODES (JSON {hostname: [{ip_id, mac, name}, ...]}, hub
VIP first), secret SCW_SECRET_KEY (IAM application limited to IPAM).
"""

import json
import os
import urllib.error
import urllib.request

API = "https://api.scaleway.com/ipam/v1/regions/{region}/ips/{ip_id}"


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
    try:
        node = json.loads(event.get("body") or "{}").get("node")
    except (ValueError, AttributeError):
        node = None
    vips = json.loads(os.environ["NODES"]).get(node)
    if not vips:
        print(json.dumps({"node": node, "error": "unknown node"}))
        return {"statusCode": 400, "body": f"unknown node {node!r}"}
    result = {}
    try:
        for vip in vips:
            result[f'{vip["ip_id"]} -> {vip["mac"]}'] = follow(vip, os.environ["REGION"])
    except Exception as e:  # logged for Cockpit, the stitch retries
        print(json.dumps({"node": node, "done": result, "error": str(e)}))
        return {"statusCode": 502, "body": json.dumps({"done": result, "error": str(e)})}
    print(json.dumps({"node": node, "done": result}))
    return {"statusCode": 200, "body": json.dumps(result)}
