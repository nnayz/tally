#!/usr/bin/env python3
"""Operator-hosted connector for a private LiteLLM gateway.

The connector reads LiteLLM 1.49.6 or 1.106.2 on the private network, or
accepts outbound events when that network cannot be called. Tally talks only
to this process, using a per-person tracking key. The private gateway address
and the upstream key stay here.

Publish the listen address with https. Tally rejects a private address, so the
imported profile names the public host and /tally/v1/requests only.

  python3 connector/tally_connector.py \\
    --listen 127.0.0.1:8787 \\
    --upstream http://127.0.0.1:4000 \\
    --upstream-key sk-admin \\
    --litellm 1.106.2 \\
    --track track-alice=alice \\
    --ingest-key ingest-secret
"""

from __future__ import annotations

import argparse
import json
import hmac
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

FORMAT = 1
MAX_BODY = 1_000_000
PUBLIC_FIELDS = ("id", "time", "model", "input", "output", "spend", "status", "session")


def same(left: str, right: str) -> bool:
    return hmac.compare_digest(left.encode(), right.encode())


def bearer(header: str) -> str:
    prefix = "Bearer "
    if not header.startswith(prefix):
        return ""
    return header[len(prefix):].strip()


def number(value) -> float:
    if isinstance(value, bool) or value is None:
        return 0
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0


def status_code(value) -> int:
    if isinstance(value, bool) or value is None:
        return 200
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    text = str(value).strip()
    if text.isdigit():
        return int(text)
    if text == "" or text.lower() == "success":
        return 200
    return 500


def session_of(row: dict) -> str:
    session = str(row.get("session_id") or "").strip()
    if session:
        return session
    for tag in row.get("request_tags") or []:
        text = str(tag).strip()
        if text and not text.startswith("User-Agent"):
            return text
    return ""


def event_from_row(row: dict) -> dict | None:
    identifier = str(row.get("request_id") or "").strip()
    if not identifier:
        return None
    user = str(row.get("user") or row.get("end_user") or "").strip()
    return {
        "id": identifier,
        "time": str(row.get("startTime") or row.get("start_time") or ""),
        "model": str(row.get("model") or ""),
        "input": int(number(row.get("prompt_tokens"))),
        "output": int(number(row.get("completion_tokens"))),
        "spend": number(row.get("spend")),
        "status": status_code(row.get("status")),
        "session": session_of(row),
        "user": user,
        "origin": "pull",
    }


def event_from_push(raw: dict) -> dict | None:
    identifier = str(raw.get("id") or "").strip()
    user = str(raw.get("user") or "").strip()
    if not identifier or not user:
        return None
    return {
        "id": identifier,
        "time": str(raw.get("time") or ""),
        "model": str(raw.get("model") or ""),
        "input": int(number(raw.get("input"))),
        "output": int(number(raw.get("output"))),
        "spend": number(raw.get("spend")),
        "status": status_code(raw.get("status")),
        "session": str(raw.get("session") or ""),
        "user": user,
        "origin": "push",
    }


def public_event(event: dict) -> dict:
    return {key: event.get(key, "" if key in ("id", "time", "model", "session") else 0) for key in PUBLIC_FIELDS}


def in_window(event: dict, start: str, end: str) -> bool:
    stamp = str(event.get("time") or "")
    if start and stamp < start:
        return False
    if end and stamp > end:
        return False
    return True


def parse_upstream(body: bytes, version: str) -> tuple[list[dict], int]:
    try:
        parsed = json.loads(body.decode())
    except (UnicodeDecodeError, json.JSONDecodeError):
        return [], 1
    if version == "1.106.2":
        rows = parsed.get("data") if isinstance(parsed, dict) else None
        total = int(parsed.get("total_pages") or 1) if isinstance(parsed, dict) else 1
    else:
        rows = parsed if isinstance(parsed, list) else None
        total = 1
    if not isinstance(rows, list):
        return [], 1
    events = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        event = event_from_row(row)
        if event:
            events.append(event)
    return events, max(total, 1)


class Connector:
    def __init__(self, upstream: str, upstream_key: str, litellm: str, tracks: dict[str, list[str]], ingest_key: str):
        self.upstream = upstream.rstrip("/")
        self.upstream_key = upstream_key
        self.litellm = litellm
        self.tracks = tracks
        self.ingest_key = ingest_key
        self.events: dict[str, dict] = {}
        self.lock = threading.Lock()

    def subject(self, token: str) -> list[str] | None:
        for key, users in self.tracks.items():
            if same(token, key):
                return users
        return None

    def refresh(self) -> None:
        if not self.upstream:
            return
        pulled: list[dict] = []
        page = 1
        while page <= 10:
            batch, total = self.pull_page(page)
            pulled.extend(batch)
            if self.litellm != "1.106.2" or not batch or page >= total:
                break
            page += 1
        with self.lock:
            kept = {key: value for key, value in self.events.items() if value.get("origin") == "push"}
            for event in pulled:
                kept[event["id"]] = event
            self.events = kept

    def pull_page(self, page: int) -> tuple[list[dict], int]:
        if self.litellm == "1.106.2":
            path = f"/spend/logs/v2?start_date=1970-01-01%2000:00:00&end_date=2999-01-01%2000:00:00&page={page}&page_size=200"
        else:
            path = "/spend/logs"
        request = urllib.request.Request(
            self.upstream + path,
            headers={"Authorization": f"Bearer {self.upstream_key}", "Accept": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=12) as response:
            body = response.read(MAX_BODY)
        events, total = parse_upstream(body, self.litellm)
        return events, total

    def visible(self, users: list[str], query: dict[str, list[str]]) -> list[dict]:
        wanted = (query.get("id") or [""])[0].strip()
        start = (query.get("start") or [""])[0].strip()
        end = (query.get("end") or [""])[0].strip()
        allowed = set(users)
        with self.lock:
            rows = [public_event(event) for event in self.events.values() if event.get("user") in allowed]
        if wanted:
            rows = [row for row in rows if row["id"] == wanted]
        return [row for row in rows if in_window(row, start, end)]

    def summary(self, rows: list[dict]) -> dict:
        return {
            "format": FORMAT,
            "spend": sum(row["spend"] for row in rows),
            "tokensIn": sum(row["input"] for row in rows),
            "tokensOut": sum(row["output"] for row in rows),
            "requests": len(rows),
        }

    def capabilities(self, users: list[str]) -> dict:
        scope = "team" if len(users) > 1 else "this user"
        return {
            "format": FORMAT,
            "capabilities": ["spend", "tokens", "models", "requests"],
            "scope": scope,
            "adapter": self.litellm if self.upstream else "connector",
        }

    def upsert(self, incoming: list[dict]) -> list[str]:
        with self.lock:
            for event in incoming:
                self.events[event["id"]] = event
        return [event["id"] for event in incoming]


def push_events(url: str, ingest_key: str, events: list[dict], attempts: int = 3) -> dict:
    """Deliver events. A later attempt of the same id does not add spend."""
    body = json.dumps({"format": FORMAT, "events": events}).encode()
    last_error: Exception | None = None
    for _ in range(attempts):
        request = urllib.request.Request(
            url,
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {ingest_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return json.loads(response.read(MAX_BODY).decode())
        except urllib.error.HTTPError as error:
            last_error = error
            if error.code < 500:
                raise
        except urllib.error.URLError as error:
            last_error = error
    if last_error:
        raise last_error
    raise RuntimeError("no attempt")


def serve(connector: Connector, host: str, port: int) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            handle_get(connector, self)

        def do_POST(self):
            handle_post(connector, self)

        def log_message(self, fmt, *args):
            return

    server = ThreadingHTTPServer((host, port), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def send_json(handler: BaseHTTPRequestHandler, status: int, payload: dict) -> None:
    raw = json.dumps(payload).encode()
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(raw)))
    handler.end_headers()
    handler.wfile.write(raw)


def tracking_users(connector: Connector, handler: BaseHTTPRequestHandler) -> list[str] | None:
    token = bearer(handler.headers.get("Authorization", ""))
    if token and same(token, connector.ingest_key):
        send_json(handler, 403, {"format": FORMAT, "error": "This credential cannot read records."})
        return None
    users = connector.subject(token)
    if users is None:
        send_json(handler, 401, {"format": FORMAT, "error": "Unknown tracking credential."})
        return None
    return users


def handle_get(connector: Connector, handler: BaseHTTPRequestHandler) -> None:
    users = tracking_users(connector, handler)
    if users is None:
        return
    try:
        connector.refresh()
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError):
        send_json(handler, 502, {"format": FORMAT, "error": "The source did not return spend logs."})
        return
    parsed = urlparse(handler.path)
    query = parse_qs(parsed.query)
    parts = [part for part in parsed.path.split("/") if part]
    rows = connector.visible(users, query)
    if parts == ["tally", "v1", "capabilities"]:
        send_json(handler, 200, connector.capabilities(users))
        return
    if parts == ["tally", "v1", "summary"]:
        send_json(handler, 200, connector.summary(rows))
        return
    if parts == ["tally", "v1", "requests"]:
        send_json(handler, 200, {"format": FORMAT, "events": rows})
        return
    if len(parts) == 4 and parts[:3] == ["tally", "v1", "requests"]:
        matched = [row for row in rows if row["id"] == parts[3]]
        if not matched:
            send_json(handler, 404, {"format": FORMAT, "error": "No record for this credential."})
            return
        send_json(handler, 200, {"format": FORMAT, "event": matched[0]})
        return
    send_json(handler, 404, {"format": FORMAT, "error": "Unknown connector route."})


def handle_post(connector: Connector, handler: BaseHTTPRequestHandler) -> None:
    parsed = urlparse(handler.path)
    if [part for part in parsed.path.split("/") if part] != ["tally", "v1", "events"]:
        send_json(handler, 404, {"format": FORMAT, "error": "Unknown connector route."})
        return
    token = bearer(handler.headers.get("Authorization", ""))
    if connector.subject(token) is not None:
        send_json(handler, 403, {"format": FORMAT, "error": "A tracking credential cannot submit events."})
        return
    if not token or not same(token, connector.ingest_key):
        send_json(handler, 401, {"format": FORMAT, "error": "Unknown ingestion credential."})
        return
    length = int(handler.headers.get("Content-Length") or 0)
    if length > MAX_BODY:
        send_json(handler, 413, {"format": FORMAT, "error": "The event batch is too large."})
        return
    try:
        payload = json.loads(handler.rfile.read(length).decode())
    except (UnicodeDecodeError, json.JSONDecodeError):
        send_json(handler, 400, {"format": FORMAT, "error": "Events must be the connector JSON."})
        return
    raw_events = payload.get("events") if isinstance(payload, dict) else None
    if payload.get("format") != FORMAT or not isinstance(raw_events, list):
        send_json(handler, 400, {"format": FORMAT, "error": "Events must use connector format 1."})
        return
    incoming = []
    for raw in raw_events:
        if not isinstance(raw, dict):
            continue
        event = event_from_push(raw)
        if event:
            incoming.append(event)
    if len(incoming) != len(raw_events):
        send_json(handler, 400, {"format": FORMAT, "error": "Each event needs an id and a user."})
        return
    connector.upsert(incoming)
    send_json(handler, 200, {"format": FORMAT, "ids": [event["id"] for event in incoming]})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", default="127.0.0.1:8787")
    parser.add_argument("--upstream", default="")
    parser.add_argument("--upstream-key", default="")
    parser.add_argument("--litellm", choices=("1.49.6", "1.106.2"), default="1.106.2")
    parser.add_argument("--track", action="append", default=[], help="tracking-key=user[,user]")
    parser.add_argument("--ingest-key", required=True)
    args = parser.parse_args()
    host, separator, port_text = args.listen.rpartition(":")
    if not separator:
        raise SystemExit("Use --listen host:port.")
    tracks = {}
    for item in args.track:
        key, separator, users = item.partition("=")
        names = [name.strip() for name in users.split(",") if name.strip()]
        if not key or not names:
            raise SystemExit("Use --track tracking-key=user.")
        tracks[key] = names
    connector = Connector(args.upstream, args.upstream_key, args.litellm, tracks, args.ingest_key)
    server = serve(connector, host, int(port_text))
    host_name, port = server.server_address[:2]
    print(f"Connector listening on http://{host_name}:{port}")
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
