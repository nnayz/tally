#!/usr/bin/env python3
"""The private gateway stays behind the connector. Tracking keys cannot cross users."""

import json
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import tally_connector as connector


ALICE = {
    "request_id": "alice-1",
    "startTime": "2026-10-24 12:00:00",
    "model": "gpt-4o",
    "prompt_tokens": 2,
    "completion_tokens": 1,
    "spend": 1.25,
    "status": "success",
    "session_id": "draft",
    "user": "alice",
    "messages": [{"role": "user", "content": "alice-prompt"}],
    "response": "alice-hidden",
}
BOB = {
    "request_id": "bob-1",
    "startTime": "2026-10-24 12:05:00",
    "model": "gpt-4o",
    "prompt_tokens": 8,
    "completion_tokens": 3,
    "spend": 7.25,
    "status": "success",
    "user": "bob",
    "messages": [{"role": "user", "content": "bob-prompt"}],
    "response": "bob-hidden",
}


class Upstream(BaseHTTPRequestHandler):
    rows = []
    version = "1.49.6"
    seen = []

    def do_GET(self):
        token = self.headers.get("Authorization", "")
        Upstream.seen.append((self.path, token))
        if token != "Bearer sk-upstream-admin":
            self.send_error(401)
            return
        if self.version == "1.106.2":
            if not self.path.startswith("/spend/logs/v2"):
                self.send_error(404)
                return
            body = json.dumps({"data": self.rows, "total_pages": 1}).encode()
        else:
            if self.path.split("?", 1)[0] != "/spend/logs":
                self.send_error(404)
                return
            body = json.dumps(self.rows).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


def listen(handler):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def request(url, token, method="GET", payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def assert_hidden(body, upstream):
    host, port = upstream.server_address[:2]
    assert f"{host}:{port}" not in body
    assert "sk-upstream-admin" not in body
    assert "alice-prompt" not in body
    assert "bob-prompt" not in body
    assert "alice-hidden" not in body
    assert "bob-hidden" not in body
    assert "/spend/logs" not in body


def deploy(version):
    Upstream.rows = [ALICE, BOB]
    Upstream.version = version
    Upstream.seen = []
    upstream = listen(Upstream)
    host, port = upstream.server_address[:2]
    gate = connector.Connector(
        upstream=f"http://{host}:{port}",
        upstream_key="sk-upstream-admin",
        litellm=version,
        tracks={"track-alice": ["alice"], "track-team": ["alice", "bob"]},
        ingest_key="ingest-secret",
    )
    public = connector.serve(gate, "127.0.0.1", 0)
    return upstream, public


def test_private_read(version):
    upstream, public = deploy(version)
    base = "http://%s:%s" % public.server_address[:2]
    status, body = request(f"{base}/tally/v1/requests?id=bob-1&user=bob", "track-alice")
    assert status == 200, body
    assert_hidden(body, upstream)
    parsed = json.loads(body)
    assert parsed["events"] == []
    status, missing = request(f"{base}/tally/v1/requests/bob-1", "track-alice")
    assert status == 404
    assert "7.25" not in missing
    status, own = request(f"{base}/tally/v1/requests", "track-alice")
    assert status == 200
    events = json.loads(own)["events"]
    assert [event["id"] for event in events] == ["alice-1"]
    assert events[0]["spend"] == 1.25
    assert "user" not in events[0]
    assert_hidden(own, upstream)
    status, summary = request(f"{base}/tally/v1/summary", "track-alice")
    assert json.loads(summary)["spend"] == 1.25
    status, caps = request(f"{base}/tally/v1/capabilities", "track-alice")
    assert json.loads(caps)["scope"] == "this user"
    assert json.loads(caps)["adapter"] == version
    status, team = request(f"{base}/tally/v1/summary", "track-team")
    assert json.loads(team)["spend"] == 8.5
    assert json.loads(request(f"{base}/tally/v1/capabilities", "track-team")[1])["scope"] == "team"
    assert Upstream.seen
    assert all(token == "Bearer sk-upstream-admin" for _, token in Upstream.seen)
    assert all("bob-1" not in path for path, _ in Upstream.seen)
    status, denied = request(f"{base}/tally/v1/requests", "ingest-secret")
    assert status == 403
    status, posted = request(
        f"{base}/tally/v1/events",
        "track-alice",
        method="POST",
        payload={"format": 1, "events": [{"id": "x", "user": "alice", "spend": 1}]},
    )
    assert status == 403
    public.shutdown()
    upstream.shutdown()


def test_both_private_versions():
    test_private_read("1.49.6")
    test_private_read("1.106.2")


def test_repeated_event_does_not_double_count():
    gate = connector.Connector("", "", "1.106.2", {"track-alice": ["alice"]}, "ingest-secret")
    public = connector.serve(gate, "127.0.0.1", 0)
    base = "http://%s:%s" % public.server_address[:2]
    event = {"id": "same", "user": "alice", "time": "2026-10-24 12:00:00", "model": "gpt-4o", "input": 1, "output": 1, "spend": 3, "status": 200, "session": "s", "messages": [{"content": "push-prompt"}]}
    for _ in range(2):
        status, body = request(f"{base}/tally/v1/events", "ingest-secret", method="POST", payload={"format": 1, "events": [event]})
        assert status == 200, body
    status, summary = request(f"{base}/tally/v1/summary", "track-alice")
    assert json.loads(summary) == {"format": 1, "spend": 3, "tokensIn": 1, "tokensOut": 1, "requests": 1}
    _, listed = request(f"{base}/tally/v1/requests", "track-alice")
    assert "push-prompt" not in listed
    assert "messages" not in listed
    public.shutdown()


def test_push_retries_then_one_copy():
    attempts = {"count": 0}

    class Flaky(BaseHTTPRequestHandler):
        def do_POST(self):
            attempts["count"] += 1
            if attempts["count"] == 1:
                self.send_error(503)
                return
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length)
            Flaky.body = raw
            body = b'{"format":1,"ids":["same"]}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            return

    flaky = listen(Flaky)
    url = "http://%s:%s/tally/v1/events" % flaky.server_address[:2]
    result = connector.push_events(url, "ingest-secret", [{"id": "same", "user": "alice", "spend": 3}])
    assert result["ids"] == ["same"]
    assert attempts["count"] == 2
    flaky.shutdown()


def test_empty_source_is_not_invented():
    Upstream.rows = []
    Upstream.version = "1.49.6"
    Upstream.seen = []
    upstream = listen(Upstream)
    host, port = upstream.server_address[:2]
    gate = connector.Connector(f"http://{host}:{port}", "sk-upstream-admin", "1.49.6", {"track-alice": ["alice"]}, "ingest-secret")
    public = connector.serve(gate, "127.0.0.1", 0)
    base = "http://%s:%s" % public.server_address[:2]
    _, body = request(f"{base}/tally/v1/requests", "track-alice")
    assert json.loads(body)["events"] == []
    _, summary = request(f"{base}/tally/v1/summary", "track-alice")
    assert json.loads(summary)["spend"] == 0
    public.shutdown()
    upstream.shutdown()


if __name__ == "__main__":
    test_both_private_versions()
    test_repeated_event_does_not_double_count()
    test_push_retries_then_one_copy()
    test_empty_source_is_not_invented()
    print("connector tests passed")
