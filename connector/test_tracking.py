#!/usr/bin/env python3
"""A test operator can issue a tracking key. The master key never goes on the request."""

import http.client
import json
import time
import urllib.parse

import tracking_issuer as issuer


MASTER = "sk-master"
VERIFIER = "a" * 43


def raw(method: str, url: str, body: bytes | None = None, headers: dict | None = None):
    parts = urllib.parse.urlparse(url)
    connection = http.client.HTTPConnection(parts.hostname, parts.port, timeout=5)
    path = parts.path or "/"
    if parts.query:
        path += "?" + parts.query
    connection.request(method, path, body=body, headers=headers or {})
    response = connection.getresponse()
    payload = response.read()
    header = {key.lower(): value for key, value in response.getheaders()}
    status = response.status
    connection.close()
    return status, header, payload


def authorize_query(**extra) -> str:
    fields = {
        "response_type": "code",
        "client_id": "tally",
        "redirect_uri": issuer.REDIRECT_URI,
        "state": "state-1",
        "code_challenge": issuer.s256(VERIFIER),
        "code_challenge_method": "S256",
        "scope": "spend.read",
    }
    fields.update(extra)
    return urllib.parse.urlencode(fields)


def main() -> None:
    assert issuer.s256(VERIFIER) == "ZtNPunH49FD35FWYhT5Tv8I7vRKQJ8uxMaL0_9eHjNA"
    operator = issuer.Issuer(master_key=MASTER, access_ttl=1)
    httpd = issuer.serve(operator)
    host, port = httpd.server_address[:2]
    base = f"http://{host}:{port}"
    try:
        planted = authorize_query(master_key=MASTER)
        assert MASTER in planted
        status, _, body = raw("GET", f"{base}/authorize?{planted}")
        assert status == 400, status
        assert MASTER.encode() not in body

        honest = authorize_query()
        assert MASTER not in honest
        assert "api_key" not in honest
        assert "sk-existing" not in honest
        status, headers, _ = raw("GET", f"{base}/authorize?{honest}")
        assert status == 302, status
        location = urllib.parse.urlparse(headers["location"])
        params = urllib.parse.parse_qs(location.query)
        assert params["state"] == ["state-1"]
        code = params["code"][0]

        form = urllib.parse.urlencode({
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": issuer.REDIRECT_URI,
            "client_id": "tally",
            "code_verifier": VERIFIER,
        })
        assert MASTER not in form
        assert "api_key" not in form
        status, _, body = raw(
            "POST",
            f"{base}/token",
            body=form.encode(),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        assert status == 200, body
        issued = json.loads(body)
        assert issued["expires_in"] == 1
        assert issued["scope"] == "this user"
        assert issued["access_token"].startswith("tk-")
        assert MASTER not in issued["access_token"]
        access = issued["access_token"]
        refresh = issued["refresh_token"]

        status, _, body = raw("GET", f"{base}/spend/logs/v2", headers={"Authorization": f"Bearer {access}"})
        assert status == 200, body
        spend = json.loads(body)
        assert spend["data"][0]["spend"] == 1.25
        assert MASTER.encode() not in body

        stolen = authorize_query(state="state-2", api_key=access)
        status, _, _ = raw("GET", f"{base}/authorize?{stolen}")
        assert status == 400, status

        time.sleep(1.2)
        status, _, _ = raw("GET", f"{base}/spend/logs/v2", headers={"Authorization": f"Bearer {access}"})
        assert status == 401, status

        refresh_form = urllib.parse.urlencode({
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": "tally",
        })
        assert MASTER not in refresh_form
        status, _, body = raw(
            "POST",
            f"{base}/token",
            body=refresh_form.encode(),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        assert status == 200, body
        renewed = json.loads(body)
        next_access = renewed["access_token"]
        next_refresh = renewed["refresh_token"]
        status, _, body = raw("GET", f"{base}/spend/logs/v2", headers={"Authorization": f"Bearer {next_access}"})
        assert status == 200, body
        assert json.loads(body)["data"][0]["spend"] == 1.25

        revoke_form = urllib.parse.urlencode({"token": next_refresh, "token_type_hint": "refresh_token"})
        status, _, _ = raw(
            "POST",
            f"{base}/revoke",
            body=revoke_form.encode(),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        assert status == 200
        status, _, _ = raw(
            "POST",
            f"{base}/token",
            body=urllib.parse.urlencode({
                "grant_type": "refresh_token",
                "refresh_token": next_refresh,
                "client_id": "tally",
            }).encode(),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        assert status == 400
        status, _, _ = raw("GET", f"{base}/spend/logs/v2", headers={"Authorization": f"Bearer {next_access}"})
        assert status == 401
    finally:
        httpd.shutdown()
    print("tracking tests passed")


if __name__ == "__main__":
    main()
