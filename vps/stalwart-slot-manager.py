#!/usr/bin/env python3
import json
import os
import socket
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ACTIVE_SLOT_FILE = os.environ.get("ACTIVE_SLOT_FILE", "/etc/haproxy/stalwart-active-slot")
SWITCH_COMMAND = os.environ.get("SWITCH_COMMAND", "/usr/local/bin/stalwart-switch-slot")
AUTH_TOKEN = os.environ.get("SLOT_MANAGER_TOKEN", "")
BIND_ADDR = os.environ.get("SLOT_MANAGER_BIND", "127.0.0.1")
PORT = int(os.environ.get("SLOT_MANAGER_PORT", "9081"))
SLOT_PORTS = {
    "blue": (10025, 18080),
    "green": (11025, 19080),
}
HTTP_HEALTHCHECK_HOST = os.environ.get("HTTP_HEALTHCHECK_HOST", "mail.solace.onl")


def read_active_slot():
    try:
        with open(ACTIVE_SLOT_FILE, "r", encoding="utf-8") as handle:
            slot = handle.read().strip()
            return slot if slot in {"blue", "green"} else "blue"
    except FileNotFoundError:
        return "blue"


def port_open(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(1)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def read_status():
    return {
        "active": read_active_slot(),
        "blueOccupied": any(port_open(port) for port in SLOT_PORTS["blue"]),
        "greenOccupied": any(port_open(port) for port in SLOT_PORTS["green"]),
    }


def fetch_active_prometheus(authorization):
    """Scrape Prometheus from the active slot's local HTTP port (bypasses HAProxy round-robin)."""
    slot = read_active_slot()
    http_port = SLOT_PORTS[slot][1]
    command = [
        "curl",
        "-fsS",
        "--max-time",
        "15",
        "--haproxy-protocol",
        "-H",
        f"Host: {HTTP_HEALTHCHECK_HOST}",
    ]
    if authorization:
        command.extend(["-H", f"Authorization: {authorization}"])
    command.append(f"http://127.0.0.1:{http_port}/metrics/prometheus")
    return subprocess.run(command, capture_output=True, text=True)


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        if not AUTH_TOKEN:
            return False
        return self.headers.get("Authorization") == f"Bearer {AUTH_TOKEN}"

    def _proxy_prometheus(self):
        result = fetch_active_prometheus(self.headers.get("Authorization", ""))
        if result.returncode != 0:
            details = (result.stderr or result.stdout or "prometheus scrape failed").strip()
            self._send(502, {"error": "prometheus_proxy_failed", "details": details})
            return

        body = result.stdout.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/metrics/prometheus":
            self._proxy_prometheus()
            return
        if self.path == "/active":
            self._send(200, {"active": read_active_slot()})
            return
        if self.path == "/status":
            if not self._authorized():
                self._send(401, {"error": "unauthorized"})
                return
            self._send(200, read_status())
            return
        else:
            self._send(404, {"error": "not_found"})
            return

    def do_POST(self):
        if self.path != "/activate":
            self._send(404, {"error": "not_found"})
            return
        if not self._authorized():
            self._send(401, {"error": "unauthorized"})
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(length or 0)
        try:
            payload = json.loads(raw_body or b"{}")
        except json.JSONDecodeError:
            self._send(400, {"error": "invalid_json"})
            return

        slot = payload.get("slot")
        if slot not in {"blue", "green"}:
            self._send(400, {"error": "invalid_slot"})
            return

        try:
            subprocess.run([SWITCH_COMMAND, slot], check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as exc:
            self._send(502, {"error": "switch_failed", "details": exc.stderr or exc.stdout})
            return

        self._send(200, {"active": read_active_slot()})

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    ThreadingHTTPServer((BIND_ADDR, PORT), Handler).serve_forever()
