#!/usr/bin/env python3
"""Enable/disable JMAP debug tracing and profile slow mailbox loads.

Client-side profiler (run any time):
  python scripts/jmap-mailbox-profile.py --with-bodies

Server-side tracing (already enabled on production):
  python scripts/stalwart-jmap-tracer.py status
  python scripts/stalwart-jmap-tracer.py tail
  railway ssh -s stalwart-mail tail -f /var/log/stalwart/stalwart.log.$(date -u +%F)
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from pathlib import Path

TRACER_ID = "jmap-debug"
# Stalwart's Tracer.events only accepts {} (filter all or none via eventsPolicy).
# debug level + exclude nothing => jmap.method-call, http.request-url, limit.*, store.* at debug+.


def load_env() -> dict[str, str]:
    env: dict[str, str] = {}
    env_path = Path(__file__).resolve().parents[1] / ".env"
    for line in env_path.read_text().splitlines():
        if "=" in line and not line.strip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def jmap_api(token: str, base_url: str) -> str:
    req = urllib.request.Request(
        f"{base_url.rstrip('/')}/jmap/session",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)["apiUrl"]


def jmap_call(api: str, token: str, method_calls: list) -> dict:
    body = {
        "using": ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"],
        "methodCalls": method_calls,
    }
    req = urllib.request.Request(
        api,
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def list_tracers(api: str, token: str) -> list[dict]:
    out = jmap_call(api, token, [["x:Tracer/get", {"ids": None}, "g"]])
    return out["methodResponses"][0][1].get("list", [])


def find_stdout_tracers(tracers: list[dict]) -> list[dict]:
    return [t for t in tracers if t.get("@type") == "Stdout"]


def query_tracer(api: str, token: str) -> dict | None:
    stdout = find_stdout_tracers(list_tracers(api, token))
    if not stdout:
        return None
    # Prefer our debug tracer id if present.
    for item in stdout:
        if item.get("id") == TRACER_ID:
            return item
    # Prefer unbuffered debug tracer.
    for item in stdout:
        if item.get("level") == "debug" and not item.get("buffered", True):
            return item
    return stdout[0]


def cleanup_extra_stdout_tracers(api: str, token: str, keep_id: str) -> None:
    extras = [t["id"] for t in find_stdout_tracers(list_tracers(api, token)) if t["id"] != keep_id]
    if not extras:
        return
    out = jmap_call(api, token, [["x:Tracer/set", {"destroy": extras}, "d"]])
    status = out["methodResponses"][0][1]
    if status.get("notDestroyed"):
        raise RuntimeError(json.dumps(status, indent=2))
    print(f"Removed {len(extras)} duplicate Stdout tracer(s).")


def enable_tracer(api: str, token: str) -> None:
    payload = {
        "@type": "Stdout",
        "enable": True,
        "level": "debug",
        "buffered": False,
        "ansi": False,
        "multiline": False,
        "lossy": True,
        "eventsPolicy": "exclude",
        "events": {},
    }
    existing = query_tracer(api, token)
    if existing:
        tracer_id = existing["id"]
        out = jmap_call(
            api,
            token,
            [["x:Tracer/set", {"update": {tracer_id: payload}}, "s"]],
        )
        cleanup_extra_stdout_tracers(api, token, tracer_id)
    else:
        out = jmap_call(
            api,
            token,
            [["x:Tracer/set", {"create": {TRACER_ID: payload}}, "s"]],
        )
        status = out["methodResponses"][0][1]
        if status.get("created"):
            tracer_id = list(status["created"].values())[0]["id"]
            cleanup_extra_stdout_tracers(api, token, tracer_id)
    status = out["methodResponses"][0][1]
    if status.get("notCreated") or status.get("notUpdated"):
        raise RuntimeError(json.dumps(status, indent=2))
    print("JMAP debug tracer enabled (Stdout -> container logs).")
    print("Level: debug (includes jmap.method-call with elapsed time, http.request-url, limit.*, store.*)")
    print("Reproduce slow load, then: python scripts/stalwart-jmap-tracer.py tail")
    configure_file_tracer(api, token)


def disable_tracer(api: str, token: str) -> None:
    existing = query_tracer(api, token)
    if not existing:
        print("No Stdout tracer found.")
        return
    tracer_id = existing["id"]
    payload = {
        "enable": True,
        "level": "info",
        "buffered": True,
        "lossy": False,
    }
    out = jmap_call(
        api,
        token,
        [["x:Tracer/set", {"update": {tracer_id: payload}}, "s"]],
    )
    status = out["methodResponses"][0][1]
    if status.get("notUpdated"):
        raise RuntimeError(json.dumps(status, indent=2))
    print(f"Stdout tracer {tracer_id} reset to info (debug JMAP logging off).")


def show_status(api: str, token: str) -> None:
    existing = query_tracer(api, token)
    if not existing:
        print("JMAP debug tracer: not configured")
        return
    print("JMAP debug tracer: enabled")
    print(json.dumps(existing, indent=2))


def configure_file_tracer(api: str, token: str) -> str:
    """Raise the active file tracer to debug (writes to /var/log/stalwart/)."""
    tracers = list_tracers(api, token)
    log_tracers = [t for t in tracers if t.get("@type") == "Log"]
    # Prefer the tracer that actually writes on Railway (/var/log/stalwart).
    active = next(
        (t for t in log_tracers if "/var/log/stalwart" in t.get("path", "")),
        log_tracers[0] if log_tracers else None,
    )
    if not active:
        raise RuntimeError("No Log tracer found")
    tracer_id = active["id"]
    out = jmap_call(
        api,
        token,
        [
            [
                "x:Tracer/set",
                {
                    "update": {
                        tracer_id: {
                            "enable": True,
                            "level": "debug",
                            "lossy": True,
                        }
                    }
                },
                "s",
            ]
        ],
    )
    status = out["methodResponses"][0][1]
    if status.get("notUpdated"):
        raise RuntimeError(json.dumps(status, indent=2))
    print(f"File tracer {tracer_id} -> debug ({active.get('path')}/{active.get('prefix')}*)")
    return tracer_id


def tail_file_logs(lines: int = 80) -> int:
    import subprocess
    from datetime import datetime, timezone

    log_date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    log_path = f"/var/log/stalwart/stalwart.log.{log_date}"
    cmd = ["railway", "ssh", "-s", "stalwart-mail", "tail", f"-n{lines}", log_path]
    result = subprocess.run(cmd, capture_output=True, text=True)
    output = (result.stdout or "") + (result.stderr or "")
    # railway prints SSH key notice on stderr; keep log lines only.
    log_lines = [
        line
        for line in output.splitlines()
        if line and not line.startswith("Using SSH key:")
    ]
    if not log_lines:
        print("Could not read server log via railway ssh.", file=sys.stderr)
        print(f"Try manually: railway ssh -s stalwart-mail tail -f {log_path}", file=sys.stderr)
        return 1
    print("\n".join(log_lines))
    print()
    print("Tip: grep for jmap.method-call, elapsed, concurrent-request, s3-error")
    return 0


def reload_settings(api: str, token: str) -> None:
    out = jmap_call(
        api,
        token,
        [
            [
                "x:Action/set",
                {"create": {"reload": {"@type": "ReloadSettings"}}},
                "r",
            ]
        ],
    )
    status = out["methodResponses"][0][1]
    if status.get("notCreated"):
        raise RuntimeError(json.dumps(status, indent=2))


def main() -> int:
    env = load_env()
    parser = argparse.ArgumentParser(description="Manage Stalwart JMAP debug tracer")
    parser.add_argument("action", choices=["enable", "disable", "status", "tail"])
    parser.add_argument("--lines", type=int, default=80, help="Lines for tail action")
    parser.add_argument("--base-url", default=env.get("STALWART_URL", "https://mail.solace.onl"))
    parser.add_argument("--token", default=env.get("STALWART_ADMIN_TOKEN"))
    parser.add_argument("--no-reload", action="store_true")
    args = parser.parse_args()

    if not args.token:
        print("STALWART_ADMIN_TOKEN required in .env", file=sys.stderr)
        return 2

    api = jmap_api(args.token, args.base_url)
    if args.action == "enable":
        enable_tracer(api, args.token)
        if not args.no_reload:
            reload_settings(api, args.token)
    elif args.action == "disable":
        disable_tracer(api, args.token)
        if not args.no_reload:
            reload_settings(api, args.token)
    elif args.action == "tail":
        return tail_file_logs(args.lines)
    else:
        show_status(api, args.token)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
