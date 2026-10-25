#!/usr/bin/env python3
"""Authorization-code + PKCE issuer for a cooperating operator.

Register Tally as a public client, then serve:

- GET /authorize — response_type=code, client_id, redirect_uri=tally://callback,
  state, code_challenge, code_challenge_method=S256, scope=spend.read.
  Rejects master_key, api_key, token, and any value that is the master key or
  an existing tracking key. Redirects to the callback with code and state.
- POST /token — grant_type authorization_code or refresh_token. No client
  secret and no Authorization header. Returns access_token, expires_in,
  refresh_token, and scope.
- POST /revoke — form field token is the refresh token. Later refresh and
  spend reads fail.
- GET /spend/logs/v2 — LiteLLM 1.106.2 shape. The issued access token works
  until expires_in, then the read is rejected.

A gateway that does not serve this exchange is unchanged. The person pastes a
tracking key. This process is the contract a test operator runs. It does not
terminate TLS.

  python3 connector/tracking_issuer.py --listen 127.0.0.1:8788 --client-id tally
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

REDIRECT_URI = "tally://callback"
BANNED_NAMES = {
    "master_key",
    "masterkey",
    "api_key",
    "apikey",
    "token",
    "access_token",
    "refresh_token",
    "authorization",
    "bearer",
    "secret",
    "password",
}
MAX_BODY = 1_000_000


def s256(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode()).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode()


def same(left: str, right: str) -> bool:
    if len(left) != len(right):
        return False
    return hmac.compare_digest(left.encode(), right.encode())


def bearer(header: str) -> str:
    prefix = "Bearer "
    if not header.startswith(prefix):
        return ""
    return header[len(prefix):].strip()


class Issuer:
    def __init__(self, client_id: str = "tally", master_key: str = "sk-master", access_ttl: int = 3600):
        self.client_id = client_id
        self.master_key = master_key
        self.access_ttl = access_ttl
        self.lock = threading.Lock()
        self.codes: dict[str, tuple[str, float]] = {}
        self.access: dict[str, float] = {}
        self.refresh: set[str] = set()

    def live_secrets(self) -> set[str]:
        with self.lock:
            return {self.master_key, *self.access, *self.refresh}

    def rejected(self, pairs: list[tuple[str, str]]) -> bool:
        secrets_now = self.live_secrets()
        for key, value in pairs:
            if key.lower() in BANNED_NAMES:
                return True
            if any(same(value, secret) for secret in secrets_now if secret):
                return True
        return False

    def handle_get(self, handler: BaseHTTPRequestHandler) -> None:
        parts = urlparse(handler.path)
        if parts.path == "/authorize":
            self.authorize(handler, parts.query)
            return
        if parts.path == "/spend/logs/v2":
            self.spend(handler, parts.query)
            return
        send(handler, 404, {"error": "not_found"})

    def handle_post(self, handler: BaseHTTPRequestHandler) -> None:
        parts = urlparse(handler.path)
        body = read_body(handler)
        if body is None:
            send(handler, 400, {"error": "invalid_request"})
            return
        pairs = form_pairs(body)
        if parts.path == "/token":
            self.token(handler, pairs)
            return
        if parts.path == "/revoke":
            self.revoke(handler, pairs)
            return
        send(handler, 404, {"error": "not_found"})

    def authorize(self, handler: BaseHTTPRequestHandler, query: str) -> None:
        pairs = query_pairs(query)
        if self.rejected(pairs):
            send(handler, 400, {"error": "invalid_request"})
            return
        values = {key: value for key, value in pairs}
        if values.get("response_type") != "code":
            send(handler, 400, {"error": "invalid_request"})
            return
        if values.get("client_id") != self.client_id:
            send(handler, 400, {"error": "invalid_request"})
            return
        if values.get("redirect_uri") != REDIRECT_URI:
            send(handler, 400, {"error": "invalid_request"})
            return
        state = values.get("state") or ""
        challenge = values.get("code_challenge") or ""
        if not state or not challenge or values.get("code_challenge_method") != "S256":
            send(handler, 400, {"error": "invalid_request"})
            return
        if values.get("scope") != "spend.read":
            send(handler, 400, {"error": "invalid_request"})
            return
        code = "code-" + secrets.token_urlsafe(18)
        with self.lock:
            self.codes[code] = (challenge, time.time() + 60)
        location = REDIRECT_URI + "?" + urlencode({"code": code, "state": state})
        send(handler, 302, location=location)

    def token(self, handler: BaseHTTPRequestHandler, pairs: list[tuple[str, str]]) -> None:
        # refresh_token is banned on the authorize URL. Here it is the grant.
        banned = BANNED_NAMES - {"refresh_token"}
        if any(key.lower() in banned or key == "client_secret" for key, _ in pairs):
            send(handler, 400, {"error": "invalid_client"})
            return
        if any(same(value, self.master_key) for _, value in pairs):
            send(handler, 400, {"error": "invalid_client"})
            return
        values = {key: value for key, value in pairs}
        grant = values.get("grant_type")
        if values.get("client_id") != self.client_id:
            send(handler, 400, {"error": "invalid_client"})
            return
        if grant == "authorization_code":
            self.exchange_code(handler, values)
            return
        if grant == "refresh_token":
            self.exchange_refresh(handler, values.get("refresh_token") or "")
            return
        send(handler, 400, {"error": "unsupported_grant"})

    def exchange_code(self, handler: BaseHTTPRequestHandler, values: dict[str, str]) -> None:
        code = values.get("code") or ""
        verifier = values.get("code_verifier") or ""
        if values.get("redirect_uri") != REDIRECT_URI or not verifier:
            send(handler, 400, {"error": "invalid_grant"})
            return
        with self.lock:
            stored = self.codes.pop(code, None)
        if stored is None:
            send(handler, 400, {"error": "invalid_grant"})
            return
        challenge, deadline = stored
        if time.time() >= deadline or not same(s256(verifier), challenge):
            send(handler, 400, {"error": "invalid_grant"})
            return
        send(handler, 200, self.issue(self.access_ttl))

    def exchange_refresh(self, handler: BaseHTTPRequestHandler, token: str) -> None:
        with self.lock:
            if token not in self.refresh:
                found = False
            else:
                self.refresh.remove(token)
                found = True
        if not found:
            send(handler, 400, {"error": "invalid_grant"})
            return
        # A refreshed key outlives the short first TTL so a retry can still read.
        send(handler, 200, self.issue(max(self.access_ttl, 60)))

    def revoke(self, handler: BaseHTTPRequestHandler, pairs: list[tuple[str, str]]) -> None:
        values = {key: value for key, value in pairs}
        token = values.get("token") or ""
        with self.lock:
            self.refresh.discard(token)
            self.access.clear()
        send(handler, 200, {})

    def issue(self, ttl: int) -> dict:
        access = "tk-" + secrets.token_urlsafe(18)
        refresh = "rt-" + secrets.token_urlsafe(18)
        with self.lock:
            self.access[access] = time.time() + ttl
            self.refresh.add(refresh)
        return {
            "access_token": access,
            "expires_in": ttl,
            "refresh_token": refresh,
            "scope": "this user",
        }

    def spend(self, handler: BaseHTTPRequestHandler, query: str) -> None:
        if self.rejected(query_pairs(query)):
            send(handler, 401, {"error": "invalid_token"})
            return
        presented = bearer(handler.headers.get("Authorization") or "")
        with self.lock:
            deadline = self.access.get(presented)
        if deadline is None or time.time() >= deadline or not presented:
            send(handler, 401, {"error": "invalid_token"})
            return
        send(handler, 200, {
            "data": [{
                "request_id": "issued-1",
                "startTime": "2026-10-24 12:00:00",
                "model": "gpt-4o",
                "prompt_tokens": 3,
                "completion_tokens": 2,
                "spend": 1.25,
                "status": "success",
                "session_id": "draft",
                "user": "ada",
            }],
            "total_pages": 1,
        })


def query_pairs(query: str) -> list[tuple[str, str]]:
    parsed = parse_qs(query, keep_blank_values=True)
    pairs = []
    for key, values in parsed.items():
        for value in values:
            pairs.append((key, value))
    return pairs


def form_pairs(body: bytes) -> list[tuple[str, str]]:
    return query_pairs(body.decode(errors="replace"))


def read_body(handler: BaseHTTPRequestHandler) -> bytes | None:
    length = int(handler.headers.get("Content-Length") or 0)
    if length < 0 or length > MAX_BODY:
        return None
    return handler.rfile.read(length)


def send(handler: BaseHTTPRequestHandler, status: int, payload: dict | None = None, location: str | None = None) -> None:
    body = b"" if payload is None else json.dumps(payload).encode()
    handler.send_response(status)
    if location:
        handler.send_header("Location", location)
    if payload is not None:
        handler.send_header("Content-Type", "application/json")
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    if body:
        handler.wfile.write(body)


def listen(address: str) -> tuple[str, int]:
    host, _, port = address.rpartition(":")
    return host or "127.0.0.1", int(port or "8788")


def serve(issuer: Issuer, address: str = "127.0.0.1:0") -> ThreadingHTTPServer:
    host, port = listen(address if not address.endswith(":0") else "127.0.0.1:0")
    if address.endswith(":0"):
        port = 0

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            issuer.handle_get(self)

        def do_POST(self) -> None:
            issuer.handle_post(self)

        def log_message(self, format: str, *args) -> None:
            return

    httpd = ThreadingHTTPServer((host, port), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    return httpd


def main() -> None:
    parser = argparse.ArgumentParser(description="Issue scoped tracking keys for Tally.")
    parser.add_argument("--listen", default="127.0.0.1:8788")
    parser.add_argument("--client-id", default="tally")
    parser.add_argument("--master-key", default="sk-master")
    parser.add_argument("--expires-in", type=int, default=3600)
    args = parser.parse_args()
    issuer = Issuer(client_id=args.client_id, master_key=args.master_key, access_ttl=args.expires_in)
    httpd = serve(issuer, args.listen)
    host, port = httpd.server_address[:2]
    print(f"tracking issuer on http://{host}:{port}")
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        httpd.shutdown()


if __name__ == "__main__":
    main()
