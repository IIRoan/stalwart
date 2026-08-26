#!/usr/bin/env python3
"""Front Gatus and forward Stalwart telemetry.alert webhooks to Discord."""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


LISTEN_PORT = int(os.environ.get("PORT", "8080"))
GATUS_PORT = int(os.environ.get("GATUS_INTERNAL_PORT", "8081"))
DISCORD_WEBHOOK_URL = (os.environ.get("DISCORD_WEBHOOK_URL") or "").strip()
BEARER = (os.environ.get("STALWART_WEBHOOK_BEARER") or "").strip()
HOOK_PATH = "/hooks/stalwart"
# Drop hop-by-hop + length/encoding: we buffer the body and set Content-Length ourselves.
_SKIP_RESPONSE_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "content-encoding",
    "content-length",
}


def _proxy(handler: BaseHTTPRequestHandler) -> None:
    length = int(handler.headers.get("Content-Length") or 0)
    body = handler.rfile.read(length) if length else b""
    url = f"http://127.0.0.1:{GATUS_PORT}{handler.path}"

    headers = {
        key: value
        for key, value in handler.headers.items()
        if key.lower() not in {"host", "connection", "transfer-encoding", "content-length"}
    }
    req = urllib.request.Request(url, data=body or None, headers=headers, method=handler.command)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = resp.read()
            handler.send_response(resp.status)
            for key, value in resp.headers.items():
                if key.lower() in _SKIP_RESPONSE_HEADERS:
                    continue
                handler.send_header(key, value)
            handler.send_header("Content-Length", str(len(payload)))
            handler.end_headers()
            if handler.command != "HEAD":
                handler.wfile.write(payload)
    except urllib.error.HTTPError as err:
        payload = err.read()
        handler.send_response(err.code)
        handler.send_header("Content-Type", err.headers.get("Content-Type", "text/plain"))
        handler.send_header("Content-Length", str(len(payload)))
        handler.end_headers()
        if handler.command != "HEAD":
            handler.wfile.write(payload)
    except Exception as exc:  # noqa: BLE001 — surface upstream failure
        msg = f"gatus proxy error: {exc}\n".encode()
        handler.send_response(502)
        handler.send_header("Content-Type", "text/plain")
        handler.send_header("Content-Length", str(len(msg)))
        handler.end_headers()
        handler.wfile.write(msg)


def _authorized(handler: BaseHTTPRequestHandler) -> bool:
    if not BEARER:
        return False
    auth = handler.headers.get("Authorization", "")
    return auth == f"Bearer {BEARER}"


def _discord_payload(events: list[dict[str, Any]]) -> dict[str, Any]:
    lines: list[str] = []
    for event in events:
        etype = event.get("type", "unknown")
        data = event.get("data") or {}
        message = ""
        if isinstance(data, dict):
            message = (
                data.get("message")
                or data.get("eventMessage")
                or data.get("text")
                or ""
            )
            if not message and data:
                message = json.dumps(data, separators=(",", ":"))[:500]
        created = event.get("createdAt", "")
        line = f"**{etype}**"
        if created:
            line += f" · `{created}`"
        if message:
            line += f"\n{message}"
        lines.append(line)

    description = "\n\n".join(lines)[:3900] or "Stalwart metric alert fired."
    return {
        "username": "Solace Mail Alerts",
        "embeds": [
            {
                "title": "Stalwart metric alert",
                "description": description,
                "color": 0xE54D2E,
                "footer": {"text": "Enterprise Alert → status.solace.onl/hooks/stalwart"},
            }
        ],
    }


def _post_discord(payload: dict[str, Any]) -> tuple[int, str]:
    if not DISCORD_WEBHOOK_URL:
        return 503, "DISCORD_WEBHOOK_URL not configured"
    req = urllib.request.Request(
        DISCORD_WEBHOOK_URL,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode("utf-8", "replace")
    except urllib.error.URLError as err:
        return 502, f"discord unreachable: {err.reason}"
    except Exception as exc:  # noqa: BLE001 — timeouts, SSL, and other network failures
        return 502, f"discord post failed: {exc}"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_HEAD(self) -> None:  # noqa: N802
        self._dispatch()

    def do_GET(self) -> None:  # noqa: N802
        self._dispatch()

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch()

    def do_PUT(self) -> None:  # noqa: N802
        self._dispatch()

    def do_DELETE(self) -> None:  # noqa: N802
        self._dispatch()

    def do_OPTIONS(self) -> None:  # noqa: N802
        self._dispatch()

    def _dispatch(self) -> None:
        path = self.path.split("?", 1)[0]
        if path.rstrip("/") == HOOK_PATH.rstrip("/") and self.command == "POST":
            self._handle_stalwart()
            return
        _proxy(self)

    def _handle_stalwart(self) -> None:
        if not _authorized(self):
            body = b"unauthorized\n"
            self.send_response(401)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            body = b"invalid json\n"
            self.send_response(400)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        events = payload.get("events") if isinstance(payload, dict) else None
        if not isinstance(events, list):
            events = [payload] if isinstance(payload, dict) else []

        alerts = [
            e
            for e in events
            if isinstance(e, dict) and str(e.get("type", "")).startswith("telemetry.alert")
        ]
        if not alerts:
            # Still acknowledge non-alert batches so Stalwart does not retry forever.
            body = b'{"ok":true,"forwarded":0}\n'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        status, detail = _post_discord(_discord_payload(alerts))
        out = json.dumps({"ok": 200 <= status < 300, "discord": status, "detail": detail[:200]}).encode()
        self.send_response(200 if 200 <= status < 300 else 502)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


def main() -> int:
    if not BEARER:
        print("STALWART_WEBHOOK_BEARER unset; /hooks/stalwart will reject all posts.", file=sys.stderr)
    if not DISCORD_WEBHOOK_URL:
        print("DISCORD_WEBHOOK_URL unset; Stalwart alerts cannot reach Discord.", file=sys.stderr)

    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    print(f"proxy listening on :{LISTEN_PORT}, gatus upstream :{GATUS_PORT}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
