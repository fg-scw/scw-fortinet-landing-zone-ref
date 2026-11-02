# python3 -m unittest discover -s modules/dsi/ipam_follow
import io
import json
import os
import unittest
import urllib.error
from unittest import mock

os.environ.update(
    REGION="fr-par",
    SCW_SECRET_KEY="x",
    NODES=json.dumps({
        "fw1": [{"ip_id": "hub", "mac": "02:00:00:00:00:01", "name": "fw1"},
                {"ip_id": "egress", "mac": "02:00:00:00:00:02", "name": "fw1"}],
    }),
)
import handler  # noqa: E402


class FakeIpam:
    """IPAM holders by ip id; conflicts = moves to refuse with 412 first."""

    def __init__(self, holders, conflicts=0):
        self.holders, self.conflicts, self.moves = holders, conflicts, []

    def __call__(self, method, url, body=None):
        ip_id = url.split("/ips/")[1].split("/")[0]
        if method == "GET":
            mac = self.holders[ip_id]
            return {"resource": {"mac_address": mac.upper()} if mac else None}
        if self.conflicts:
            self.conflicts -= 1
            raise urllib.error.HTTPError(url, 412, "precondition", {}, io.BytesIO())
        assert body.get("from_resource", {}).get("mac_address", "") == self.holders[ip_id]
        self.holders[ip_id] = body["to_resource"]["mac_address"]
        self.moves.append(ip_id)
        return {}


def run(body):
    return handler.handle({"body": json.dumps(body)}, None)


class HandleTest(unittest.TestCase):
    def test_moves_both_vips_then_is_idempotent(self):
        ipam = FakeIpam({"hub": "02:00:00:00:00:a1", "egress": "02:00:00:00:00:a2"})
        with mock.patch.object(handler, "call", ipam):
            self.assertEqual(run({"node": "fw1"})["statusCode"], 200)
            self.assertEqual(ipam.moves, ["hub", "egress"])
            self.assertEqual(set(json.loads(run({"node": "fw1"})["body"]).values()), {"in place"})
            self.assertEqual(len(ipam.moves), 2)

    def test_retries_when_the_holder_changed(self):
        ipam = FakeIpam({"hub": "02:00:00:00:00:a1", "egress": "02:00:00:00:00:02"}, conflicts=1)
        with mock.patch.object(handler, "call", ipam):
            self.assertEqual(run({"node": "fw1"})["statusCode"], 200)
        self.assertEqual(ipam.holders["hub"], "02:00:00:00:00:01")

    def test_detached_vip_is_attached(self):
        ipam = FakeIpam({"hub": "", "egress": "02:00:00:00:00:02"})
        with mock.patch.object(handler, "call", ipam):
            self.assertEqual(run({"node": "fw1"})["statusCode"], 200)
        self.assertEqual(ipam.holders["hub"], "02:00:00:00:00:01")

    def test_unknown_node_or_bad_body_moves_nothing(self):
        ipam = FakeIpam({})
        with mock.patch.object(handler, "call", ipam):
            self.assertEqual(run({"node": "fw9"})["statusCode"], 400)
            self.assertEqual(handler.handle({"body": "not json"}, None)["statusCode"], 400)

    def test_api_error_is_a_502(self):
        def broken(*_):
            raise urllib.error.HTTPError("u", 500, "boom", {}, io.BytesIO())
        with mock.patch.object(handler, "call", broken):
            self.assertEqual(run({"node": "fw1"})["statusCode"], 502)


if __name__ == "__main__":
    unittest.main()
