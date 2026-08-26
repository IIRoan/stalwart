#!/usr/bin/env python3
"""Emit JSON health for Gatus SSH monitoring on the mail VPS."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.request

ACTIVE_SLOT_FILE = os.environ.get("ACTIVE_SLOT_FILE", "/etc/haproxy/stalwart-active-slot")
FRPS_DASHBOARD = os.environ.get("FRPS_DASHBOARD_URL", "http://127.0.0.1:7500")
SERVICES = (
    "haproxy",
    "frps",
    "frpc-relay",
    "postfix",
    "stalwart-slot-manager",
    "stalwart-slot-watcher",
)
SLOT_PORTS = {
    "blue": (10025, 18080),
    "green": (11025, 19080),
}
FRP_PROXIES = {
    "blue": ("smtp-blue", "https-blue"),
    "green": ("smtp-green", "https-green"),
}


def read_active_slot() -> str:
    try:
        with open(ACTIVE_SLOT_FILE, encoding="utf-8") as handle:
            slot = handle.read().strip()
            return slot if slot in {"blue", "green"} else "blue"
    except OSError:
        return "blue"


def slot_http_ready(port: int) -> bool:
    # HTTP listeners require PROXY v2; a bare TCP connect logs network.proxy-error end-of-stream.
    try:
        result = subprocess.run(
            [
                "curl",
                "-fsS",
                "--max-time",
                "2",
                "--haproxy-protocol",
                "-H",
                "Host: mail.solace.onl",
                f"http://127.0.0.1:{port}/jmap/session",
            ],
            check=False,
            capture_output=True,
        )
    except OSError:
        return False
    return result.returncode == 0


def slot_occupied(slot: str) -> bool:
    proxies = fetch_frp_proxies()
    names = FRP_PROXIES[slot]
    if proxies:
        return any(proxies.get(name) == "online" for name in names)
    return slot_http_ready(SLOT_PORTS[slot][1])


def service_active(unit: str) -> str:
    try:
        result = subprocess.run(
            ["systemctl", "is-active", unit],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return "unknown"
    return (result.stdout or result.stderr or "unknown").strip()


def fetch_frp_proxies() -> dict[str, str]:
    try:
        request = urllib.request.Request(
            f"{FRPS_DASHBOARD}/api/proxy/tcp",
            headers={"Connection": "close"},
            method="GET",
        )
        with urllib.request.urlopen(request, timeout=3) as response:
            payload = json.load(response)
    except Exception:  # noqa: BLE001
        return {}

    return {
        entry.get("name", ""): entry.get("status", "offline")
        for entry in payload.get("proxies", [])
        if entry.get("name")
    }


def postfix_queue_count() -> int | None:
    try:
        result = subprocess.run(
            ["postqueue", "-p"],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return None

    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if not lines:
        return 0
    if lines[-1].startswith("-- "):
        try:
            return int(lines[-1].split()[0])
        except (IndexError, ValueError):
            return None
    return len(lines)


def main() -> int:
    active = read_active_slot()
    proxies = fetch_frp_proxies()
    services = {name: service_active(name) for name in SERVICES}
    queue = postfix_queue_count()

    tunnels: dict[str, dict[str, object]] = {}
    for slot in ("blue", "green"):
        proxy_names = FRP_PROXIES[slot]
        tunnels[slot] = {
            "occupied": slot_occupied(slot),
            "http": proxies.get(proxy_names[1], "unknown") == "online" if proxies else slot_http_ready(SLOT_PORTS[slot][1]),
            "proxies": {
                name: proxies.get(name, "unknown") for name in proxy_names
            },
        }

    unhealthy_services = [
        name for name, state in services.items() if state != "active"
    ]
    active_tunnel = tunnels.get(active, {})
    active_proxies = active_tunnel.get("proxies", {})
    proxy_down = any(status != "online" for status in active_proxies.values()) if active_proxies else False

    status = "healthy"
    if unhealthy_services or not active_tunnel.get("http") or proxy_down:
        status = "degraded"
    if unhealthy_services or not active_tunnel.get("occupied"):
        status = "unhealthy"

    payload = {
        "status": status,
        "activeSlot": active,
        "services": services,
        "tunnels": tunnels,
        "postfixQueue": queue,
        "unhealthyServices": unhealthy_services,
    }
    print(json.dumps(payload, separators=(",", ":")))
    return 0 if status == "healthy" else 1


if __name__ == "__main__":
    sys.exit(main())
