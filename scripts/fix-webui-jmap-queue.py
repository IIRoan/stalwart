#!/usr/bin/env python3
"""Reduce JMAP connection/polling pressure for web UI."""
import json
import urllib.request
from pathlib import Path

env = {}
for line in Path(__file__).resolve().parents[1].joinpath(".env").read_text().splitlines():
    if "=" in line and not line.strip().startswith("#"):
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()

token = env["STALWART_ADMIN_TOKEN"]
base = "https://mail.solace.onl"
req = urllib.request.Request(
    f"{base}/jmap/session", headers={"Authorization": f"Bearer {token}"}
)
with urllib.request.urlopen(req, timeout=30) as resp:
    api = json.load(resp)["apiUrl"]


def jmap(calls):
    body = {"using": ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"], "methodCalls": calls}
    req = urllib.request.Request(
        api,
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


# Higher concurrent cap: browser fires many parallel /jmap/ + EventSource/WebSocket.
jmap(
    [
        [
            "x:Jmap/set",
            {
                "update": {
                    "singleton": {
                        "maxConcurrentRequests": 32,
                        "eventSourceThrottle": 3000,
                        "websocketThrottle": 3000,
                    }
                }
            },
            "j",
        ]
    ]
)

# Quiet noisy debug logging (re-enabled after redeploy).
out = jmap([["x:Tracer/get", {"ids": None}, "g"]])
updates = {}
for t in out["methodResponses"][0][1]["list"]:
    tid = t["id"]
    if t.get("@type") == "Stdout":
        updates[tid] = {"level": "info", "buffered": True}
    elif t.get("@type") == "Log":
        updates[tid] = {"level": "info", "enable": t.get("path") != "/tmp"}
if updates:
    jmap([["x:Tracer/set", {"update": updates}, "t"]])

jmap([["x:Action/set", {"create": {"r": {"@type": "ReloadSettings"}}}, "r"]])
print("Applied: maxConcurrentRequests=32, eventSourceThrottle=3s, debug logging off")
