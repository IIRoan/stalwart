#!/usr/bin/env python3
"""Promote blue/green HAProxy slots when a Railway frpc tunnel becomes healthy."""

from __future__ import annotations

import fcntl
import json
import os
import socket
import subprocess
import time
import urllib.request

ACTIVE_SLOT_FILE = os.environ.get("ACTIVE_SLOT_FILE", "/etc/haproxy/stalwart-active-slot")
SWITCH_COMMAND = os.environ.get("SWITCH_COMMAND", "/usr/local/bin/stalwart-switch-slot")
POLL_SECONDS = int(os.environ.get("SLOT_WATCHER_POLL_SECONDS", "10"))
FRPS_DASHBOARD = os.environ.get("FRPS_DASHBOARD_URL", "http://127.0.0.1:7500")

SLOT_PORTS = {
    "blue": {"http": 18080, "proxies": ("smtp-blue", "https-blue")},
    "green": {"http": 19080, "proxies": ("smtp-green", "https-green")},
}


def read_active_slot() -> str:
    try:
        with open(ACTIVE_SLOT_FILE, encoding="utf-8") as handle:
            slot = handle.read().strip()
            return slot if slot in {"blue", "green"} else "blue"
    except FileNotFoundError:
        return "blue"


def port_open(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(1)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def fetch_frp_proxies() -> dict[str, str]:
    try:
        request = urllib.request.Request(
            f"{FRPS_DASHBOARD}/api/proxy/tcp",
            headers={"Connection": "close"},
            method="GET",
        )
        with urllib.request.urlopen(request, timeout=3) as resp:
            payload = json.load(resp)
    except Exception:  # noqa: BLE001
        return {}

    return {
        entry.get("name", ""): entry.get("status", "offline")
        for entry in payload.get("proxies", [])
        if entry.get("name")
    }


def slot_tunnel_up(slot: str) -> bool:
    info = SLOT_PORTS[slot]
    if not port_open(info["http"]):
        return False

    proxies = fetch_frp_proxies()
    if not proxies:
        return port_open(info["http"])

    return all(proxies.get(name) == "online" for name in info["proxies"])


def switch_slot(slot: str) -> None:
    lock_path = os.environ.get("SLOT_SWITCH_LOCK", "/run/stalwart-slot-switch.lock")
    with open(lock_path, "w", encoding="utf-8") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        if read_active_slot() == slot:
            return
        subprocess.run(
            [SWITCH_COMMAND, slot],
            check=True,
            capture_output=True,
            text=True,
        )


def maybe_promote() -> None:
    """Fail over only when the active slot tunnel is down.

    New deploys promote themselves via Railway POST /slot-manager/activate once
    the container health gate opens. Avoid switching while both slots are up or
    HAProxy will flip-flop during Railway overlap and return 503.
    """
    active = read_active_slot()
    occupancy = {slot: slot_tunnel_up(slot) for slot in ("blue", "green")}

    if occupancy[active]:
        return

    for slot in ("blue", "green"):
        if slot == active or not occupancy[slot]:
            continue
        print(
            f"failover: promoting {slot} because active={active} tunnel is down",
            flush=True,
        )
        switch_slot(slot)
        return


def main() -> None:
    print(
        f"stalwart-slot-watcher: poll={POLL_SECONDS}s dashboard={FRPS_DASHBOARD}",
        flush=True,
    )
    while True:
        try:
            maybe_promote()
        except subprocess.CalledProcessError as exc:
            detail = exc.stderr or exc.stdout or str(exc)
            print(f"switch failed: {detail}", flush=True)
        except Exception as exc:  # noqa: BLE001
            print(f"watcher error: {exc}", flush=True)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
