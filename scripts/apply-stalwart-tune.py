#!/usr/bin/env python3
"""Apply balanced Stalwart settings: fast webmail, lower RAM than factory defaults.

BlobStore on Railway volume (FileSystem). Keeps 50 MB message cache and JMAP
concurrency fixes; trims auxiliary caches and disables Postgres telemetry history.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from pathlib import Path

BASE_URL = "https://mail.solace.onl"

CACHE = {
    "messages": 52428800,
    "files": 5242880,
    "accounts": 5242880,
    "events": 5242880,
    "contacts": 5242880,
    "scheduling": 1048576,
    "mailingLists": 1048576,
    "dkimSignatures": 5242880,
    "domains": 2097152,
    "domainNames": 3145728,
    "domainNamesNegative": 1048576,
    "emailAddresses": 3145728,
    "emailAddressesNegative": 1048576,
    "tenants": 2097152,
    "roles": 2097152,
    "accessTokens": 5242880,
    "httpAuth": 1048576,
    "dnsTxt": 1048576,
    "dnsMx": 1048576,
    "dnsPtr": 1048576,
    "dnsIpv4": 1048576,
    "dnsIpv6": 1048576,
    "dnsTlsa": 1048576,
    "dnsMtaSts": 1048576,
    "dnsRbl": 1048576,
    "negativeTtl": 1800000,
}

JMAP = {
    "getMaxResults": 500,
    "maxConcurrentRequests": 32,
    "maxMethodCalls": 16,
    "eventSourceThrottle": 3000,
    "websocketThrottle": 3000,
}


def load_token() -> str:
    env_path = Path(__file__).resolve().parents[1] / ".env"
    for line in env_path.read_text().splitlines():
        if line.startswith("STALWART_ADMIN_TOKEN="):
            return line.split("=", 1)[1].strip()
    sys.exit("STALWART_ADMIN_TOKEN required in .env")


class Client:
    def __init__(self, token: str) -> None:
        self.token = token
        req = urllib.request.Request(
            f"{BASE_URL}/jmap/session",
            headers={"Authorization": f"Bearer {token}"},
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            self.api = json.load(resp)["apiUrl"]

    def jmap(self, calls: list) -> dict:
        body = {
            "using": ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"],
            "methodCalls": calls,
        }
        req = urllib.request.Request(
            self.api,
            data=json.dumps(body).encode(),
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)

    def set_singleton(self, name: str, update: dict) -> None:
        out = self.jmap([[f"x:{name}/set", {"update": {"singleton": update}}, "s"]])
        status = out["methodResponses"][0][1]
        if status.get("notUpdated"):
            raise RuntimeError(json.dumps(status, indent=2))

    def reload(self) -> None:
        self.jmap([["x:Action/set", {"create": {"r": {"@type": "ReloadSettings"}}}, "r"]])


def apply(token: str) -> None:
    client = Client(token)

    print("Cache: 50 MB messages, trimmed auxiliary caches")
    client.set_singleton("Cache", CACHE)

    print("Jmap: maxConcurrent=32, getMaxResults=500, 3s EventSource/WebSocket throttle")
    client.set_singleton("Jmap", JMAP)

    print("SystemSettings: default thread pool")
    client.set_singleton("SystemSettings", {"threadPoolSize": None})

    print("DataStore: poolMaxConnections=6, fast recycling")
    client.set_singleton(
        "DataStore",
        {"poolMaxConnections": 6, "poolRecyclingMethod": "fast"},
    )

    print("MetricsStore / TracingStore -> Disabled (less Postgres RAM)")
    client.set_singleton("MetricsStore", {"@type": "Disabled"})
    client.set_singleton("TracingStore", {"@type": "Disabled"})

    print("DataRetention: moderate history")
    client.set_singleton(
        "DataRetention",
        {
            "maxChangesHistory": 5000,
            "holdMtaReportsFor": 2592000000,
            "holdMetricsFor": 2592000000,
        },
    )

    client.reload()
    print("Reloaded settings.")


def main() -> int:
    parser = argparse.ArgumentParser(description="Apply balanced Stalwart RAM/perf tune")
    parser.parse_args()
    apply(load_token())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
