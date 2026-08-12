#!/usr/bin/env python3
"""Configure Stalwart Enterprise metric Alerts + Discord webhook (via Gatus bridge).

Complements Gatus endpoint monitors: Gatus watches HTTP/Prometheus scrape health;
these Alerts fire on live metric thresholds inside Stalwart and notify by email
and/or event → WebHook → https://status.solace.onl/hooks/stalwart → Discord.

Requires Enterprise license. Uses STALWART_ADMIN_TOKEN from .env (or env).

Optional env:
  STALWART_ALERT_TO          recipient (default admin@solace.onl)
  STALWART_ALERT_FROM        sender   (default alert@solace.onl)
  STALWART_ALERT_FROM_NAME   display  (default Solace Mail Alerts)
  STALWART_WEBHOOK_URL       bridge   (default https://status.solace.onl/hooks/stalwart)
  STALWART_WEBHOOK_BEARER    Bearer for the bridge (required to create/update WebHook)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path
from typing import Any

BASE_URL = os.environ.get("STALWART_URL", "https://mail.solace.onl").rstrip("/")

# Idempotent labels stored in eventMessage / subject prefixes so re-runs update
# the same logical alerts instead of duplicating forever.
ALERT_SPECS = [
    {
        "key": "store-errors",
        "condition": (
            "store_s3_error > 0 || store_unexpected_error > 0 || "
            "store_postgresql_error > 0 || store_filesystem_error > 0"
        ),
        "event_message": (
            "[store-errors] Store errors — S3 %{store.s3-error}%, "
            "unexpected %{store.unexpected-error}%, "
            "postgres %{store.postgresql-error}%, "
            "fs %{store.filesystem-error}%"
        ),
        "subject": "[Solace Mail] Store errors (S3/PG/FS)",
        "body": (
            "Stalwart reported store errors.\n\n"
            "S3: %{store.s3-error}%\n"
            "Unexpected: %{store.unexpected-error}%\n"
            "PostgreSQL: %{store.postgresql-error}%\n"
            "Filesystem: %{store.filesystem-error}%\n\n"
            "Gatus also watches these counters on status.solace.onl "
            "(stalwart-error-counters)."
        ),
    },
    {
        "key": "smtp-concurrency",
        "condition": "smtp_concurrency_limit_exceeded > 0",
        "event_message": (
            "[smtp-concurrency] SMTP concurrency limit exceeded "
            "%{smtp.concurrency-limit-exceeded}% times"
        ),
        "subject": "[Solace Mail] SMTP concurrency limit exceeded",
        "body": (
            "Inbound/outbound SMTP hit the concurrency limit "
            "(%{smtp.concurrency-limit-exceeded}%).\n"
            "Check load, connection storms, or tune SMTP limits."
        ),
    },
    {
        "key": "calendar-expansion",
        "condition": "calendar_rule_expansion_error > 0",
        "event_message": (
            "[calendar-expansion] Calendar rule expansion errors: "
            "%{calendar.rule-expansion-error}%"
        ),
        "subject": "[Solace Mail] Calendar rule expansion errors",
        "body": (
            "Calendar recurrence expansion failed "
            "(%{calendar.rule-expansion-error}% events).\n"
            "Inspect Live Tracing for calendar.rule-expansion-error."
        ),
    },
    {
        "key": "queue-backlog",
        "condition": "queue_count > 2000",
        "event_message": "[queue-backlog] Delivery queue count %{queue.count}%",
        "subject": "[Solace Mail] Delivery queue backlog",
        "body": (
            "The message queue has %{queue.count}% messages pending.\n"
            "Check the VPS relay, outbound DNS, and delivery connections."
        ),
    },
]


def load_token() -> str:
    token = (os.environ.get("STALWART_ADMIN_TOKEN") or "").strip()
    if token:
        return token
    env_path = Path(__file__).resolve().parents[1] / ".env"
    if env_path.is_file():
        for line in env_path.read_text().splitlines():
            if line.startswith("STALWART_ADMIN_TOKEN="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    sys.exit("STALWART_ADMIN_TOKEN required in env or .env")


def load_env(name: str, default: str = "") -> str:
    value = (os.environ.get(name) or "").strip()
    if value:
        return value
    env_path = Path(__file__).resolve().parents[1] / ".env"
    if env_path.is_file():
        for line in env_path.read_text().splitlines():
            if line.startswith(f"{name}="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    return default


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

    def reload(self) -> None:
        self.jmap([["x:Action/set", {"create": {"r": {"@type": "ReloadSettings"}}}, "r"]])


def _first_response(out: dict) -> dict:
    return out["methodResponses"][0][1]


def _objects_by_id(raw: Any) -> dict[str, dict]:
    """Index JMAP Get `list` (Foo[] per RFC 8620) by object id."""
    if not raw:
        return {}
    if isinstance(raw, dict):
        out: dict[str, dict] = {}
        for key, obj in raw.items():
            if isinstance(obj, dict):
                out[str(obj.get("id") or key)] = obj
        return out
    if isinstance(raw, list):
        return {
            str(obj["id"]): obj
            for obj in raw
            if isinstance(obj, dict) and obj.get("id") is not None
        }
    return {}


def list_alerts(client: Client) -> dict[str, dict]:
    out = client.jmap([["x:Alert/query", {"filter": {}}, "q"]])
    ids = _first_response(out).get("ids") or []
    if not ids:
        return {}
    got = client.jmap([["x:Alert/get", {"ids": ids}, "g"]])
    return _objects_by_id(_first_response(got).get("list"))


def list_webhooks(client: Client) -> dict[str, dict]:
    out = client.jmap([["x:WebHook/query", {"filter": {}}, "q"]])
    ids = _first_response(out).get("ids") or []
    if not ids:
        return {}
    got = client.jmap([["x:WebHook/get", {"ids": ids}, "g"]])
    return _objects_by_id(_first_response(got).get("list"))


def find_by_marker(objects: dict[str, dict], marker: str, fields: tuple[str, ...]) -> str | None:
    for oid, obj in objects.items():
        blob = json.dumps(obj)
        if marker in blob:
            return oid
        for field in fields:
            val = obj.get(field)
            if isinstance(val, str) and marker in val:
                return oid
            if isinstance(val, dict) and marker in json.dumps(val):
                return oid
    return None


def alert_payload(
    spec: dict,
    *,
    to_addr: str,
    from_addr: str,
    from_name: str,
    email: bool,
    event: bool,
) -> dict:
    email_alert: dict
    if email:
        email_alert = {
            "@type": "Enabled",
            "fromName": from_name,
            "fromAddress": from_addr,
            "to": {to_addr: True},
            "subject": spec["subject"],
            "body": spec["body"],
        }
    else:
        email_alert = {"@type": "Disabled"}

    event_alert: dict
    if event:
        event_alert = {
            "@type": "Enabled",
            "eventMessage": spec["event_message"],
        }
    else:
        event_alert = {"@type": "Disabled"}

    return {
        "enable": True,
        "condition": {"else": spec["condition"]},
        "emailAlert": email_alert,
        "eventAlert": event_alert,
    }


def upsert_alerts(
    client: Client,
    *,
    to_addr: str,
    from_addr: str,
    from_name: str,
    email: bool,
    event: bool,
) -> None:
    existing = list_alerts(client)
    create: dict[str, dict] = {}
    update: dict[str, dict] = {}

    for spec in ALERT_SPECS:
        marker = f"[{spec['key']}]"
        oid = find_by_marker(
            existing,
            marker,
            ("eventMessage", "subject", "condition"),
        )
        # Also match by scanning nested email/event message fields
        if oid is None:
            for cand_id, obj in existing.items():
                ea = obj.get("eventAlert") or {}
                em = obj.get("emailAlert") or {}
                if marker in str(ea.get("eventMessage", "")) or marker in str(em.get("subject", "")):
                    oid = cand_id
                    break
                # Legacy: match condition text
                cond = obj.get("condition") or {}
                if cond.get("else") == spec["condition"]:
                    oid = cand_id
                    break

        payload = alert_payload(
            spec,
            to_addr=to_addr,
            from_addr=from_addr,
            from_name=from_name,
            email=email,
            event=event,
        )
        if oid:
            update[oid] = payload
            print(f"Alert update {spec['key']} → {oid}")
        else:
            create[f"a-{spec['key']}"] = payload
            print(f"Alert create {spec['key']}")

    if not create and not update:
        return

    args: dict = {}
    if create:
        args["create"] = create
    if update:
        args["update"] = update
    out = client.jmap([["x:Alert/set", args, "s"]])
    status = _first_response(out)
    if status.get("notCreated") or status.get("notUpdated"):
        raise RuntimeError(json.dumps(status, indent=2))
    for cid, obj in (status.get("created") or {}).items():
        print(f"  created {cid} → {obj.get('id')}")


def upsert_webhook(client: Client, *, url: str, bearer: str) -> None:
    existing = list_webhooks(client)
    marker = "/hooks/stalwart"
    oid = None
    for cand_id, obj in existing.items():
        if marker in str(obj.get("url", "")):
            oid = cand_id
            break

    payload = {
        "enable": True,
        "url": url,
        "events": {"telemetry.alert": True},
        "eventsPolicy": "include",
        "level": "info",
        "throttle": 5000,
        "timeout": 30000,
        "discardAfter": 300000,
        "allowInvalidCerts": False,
        "lossy": False,
        "httpHeaders": {"X-Solace-Source": "stalwart-alert"},
        "signatureKey": {"@type": "None"},
        "httpAuth": {
            "@type": "Bearer",
            "bearerToken": {"@type": "Value", "secret": bearer},
        },
    }

    if oid:
        print(f"WebHook update → {oid} ({url})")
        out = client.jmap([["x:WebHook/set", {"update": {oid: payload}}, "w"]])
    else:
        print(f"WebHook create → {url}")
        out = client.jmap([["x:WebHook/set", {"create": {"discord-bridge": payload}}, "w"]])

    status = _first_response(out)
    if status.get("notCreated") or status.get("notUpdated"):
        raise RuntimeError(json.dumps(status, indent=2))
    for cid, obj in (status.get("created") or {}).items():
        print(f"  created {cid} → {obj.get('id')}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--email-only", action="store_true", help="Disable eventAlert / webhook")
    parser.add_argument("--event-only", action="store_true", help="Disable emailAlert")
    parser.add_argument("--skip-webhook", action="store_true", help="Do not create/update WebHook")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    email = not args.event_only
    event = not args.email_only
    to_addr = load_env("STALWART_ALERT_TO", "admin@solace.onl")
    from_addr = load_env("STALWART_ALERT_FROM", "alert@solace.onl")
    from_name = load_env("STALWART_ALERT_FROM_NAME", "Solace Mail Alerts")
    webhook_url = load_env(
        "STALWART_WEBHOOK_URL",
        "https://status.solace.onl/hooks/stalwart",
    )
    bearer = load_env("STALWART_WEBHOOK_BEARER", "")

    print(f"Email → {to_addr} (enabled={email})")
    print(f"Event → webhook (enabled={event})")
    if event and not args.skip_webhook:
        print(f"WebHook → {webhook_url}")

    if args.dry_run:
        print("Dry run — no changes.")
        for spec in ALERT_SPECS:
            print(f"  {spec['key']}: {spec['condition']}")
        return 0

    if event and not args.skip_webhook and not bearer:
        sys.exit(
            "STALWART_WEBHOOK_BEARER required to wire Discord bridge "
            "(same value as on the Monitoring / Gatus Railway service)"
        )

    client = Client(load_token())
    upsert_alerts(
        client,
        to_addr=to_addr,
        from_addr=from_addr,
        from_name=from_name,
        email=email,
        event=event,
    )
    if event and not args.skip_webhook:
        upsert_webhook(client, url=webhook_url, bearer=bearer)

    client.reload()
    print("Reloaded settings.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
