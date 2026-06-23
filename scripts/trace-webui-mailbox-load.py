#!/usr/bin/env python3
"""Reproduce the web UI mailbox load JMAP call and break down server vs client time.

Mimics getMailboxMessages: Email/query + Email/get with bodyValues for ~44-50 msgs.
"""
from __future__ import annotations

import json
import sys
import time
import urllib.request
from pathlib import Path


def load_token() -> str:
    env_path = Path(__file__).resolve().parents[1] / ".env"
    for line in env_path.read_text().splitlines():
        if line.startswith("STALWART_USER_TOKEN="):
            return line.split("=", 1)[1].strip()
        if line.startswith("STALWART_ADMIN_TOKEN="):
            admin = line.split("=", 1)[1].strip()
    return admin


def main() -> int:
    token = load_token()
    base = "https://mail.solace.onl"
    account = "n"
    mailbox = "a"

    t0 = time.perf_counter()
    req = urllib.request.Request(
        f"{base}/jmap/session",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        session = json.load(resp)
    session_ms = (time.perf_counter() - t0) * 1000
    api = session["apiUrl"]

    # Same shape as web UI: query then get with full properties + body fetch.
    body = {
        "using": [
            "urn:ietf:params:jmap:core",
            "urn:ietf:params:jmap:mail",
            "urn:ietf:params:jmap:submission",
        ],
        "methodCalls": [
            [
                "Email/query",
                {
                    "accountId": account,
                    "filter": {"inMailbox": mailbox},
                    "sort": [{"property": "receivedAt", "isAscending": False}],
                    "limit": 50,
                },
                "q1",
            ],
        ],
    }

    t1 = time.perf_counter()
    req = urllib.request.Request(
        api,
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        raw = resp.read()
    query_ms = (time.perf_counter() - t1) * 1000
    query_out = json.loads(raw)
    ids = query_out["methodResponses"][0][1]["ids"]
    resp_kb = len(raw) / 1024

    get_props = [
        "id",
        "threadId",
        "messageId",
        "inReplyTo",
        "references",
        "mailboxIds",
        "from",
        "to",
        "cc",
        "bcc",
        "subject",
        "receivedAt",
        "keywords",
        "bodyStructure",
        "bodyValues",
        "textBody",
        "htmlBody",
        "attachments",
    ]
    body = {
        "using": [
            "urn:ietf:params:jmap:core",
            "urn:ietf:params:jmap:mail",
            "urn:ietf:params:jmap:submission",
        ],
        "methodCalls": [
            [
                "Email/get",
                {
                    "accountId": account,
                    "ids": ids,
                    "properties": get_props,
                    "fetchTextBodyValues": True,
                    "fetchHTMLBodyValues": True,
                },
                "g1",
            ],
        ],
    }

    t2 = time.perf_counter()
    req = urllib.request.Request(
        api,
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        raw = resp.read()
    get_ms = (time.perf_counter() - t2) * 1000
    get_out = json.loads(raw)
    get_kb = len(raw) / 1024

    msgs = get_out["methodResponses"][0][1]["list"]
    with_bodies = sum(
        1
        for m in msgs
        if m.get("bodyValues") and any(v.get("value") for v in m["bodyValues"].values())
    )
    encrypted = sum(
        1
        for m in msgs
        if (m.get("bodyStructure") or {}).get("type") == "multipart/encrypted"
    )
    zero_blobs = sum(
        1
        for m in msgs
        for part in _walk_parts(m.get("bodyStructure"))
        if part.get("blobId") and part.get("size") == 0
    )

    # Batched (single HTTP round-trip like browser can do).
    batch = {
        "using": body["using"],
        "methodCalls": [
            [
                "Email/query",
                {
                    "accountId": account,
                    "filter": {"inMailbox": mailbox},
                    "sort": [{"property": "receivedAt", "isAscending": False}],
                    "limit": 50,
                },
                "q1",
            ],
            [
                "Email/get",
                {
                    "accountId": account,
                    "ids": ids,
                    "properties": get_props,
                    "fetchTextBodyValues": True,
                    "fetchHTMLBodyValues": True,
                },
                "g1",
            ],
        ],
    }
    t3 = time.perf_counter()
    req = urllib.request.Request(
        api,
        data=json.dumps(batch).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        batch_raw = resp.read()
    batch_ms = (time.perf_counter() - t3) * 1000
    batch_kb = len(batch_raw) / 1024

    print("Web UI mailbox load trace (mail.solace.onl)")
    print("=" * 60)
    print(f"JMAP session                     {session_ms:7.0f} ms")
    print(f"Email/query ({len(ids)} ids)       {query_ms:7.0f} ms  ({resp_kb:.1f} KB)")
    print(f"Email/get + bodyValues           {get_ms:7.0f} ms  ({get_kb:.1f} KB)")
    print(f"Batched query+get (1 HTTP)       {batch_ms:7.0f} ms  ({batch_kb:.1f} KB)")
    print()
    print(f"Messages: {len(msgs)}  with text bodyValues: {with_bodies}")
    print(f"  multipart/encrypted (PGP): {encrypted}")
    print(f"  body parts with blobId but size=0: {zero_blobs}")
    print()
    print("Browser 'Waiting' ~= server processing for this POST (not KB transferred).")
    print(f"Per-message Email/get cost: ~{get_ms / max(len(ids), 1):.0f} ms/msg")
    return 0


def _walk_parts(structure: dict | None):
    if not structure:
        return
    yield structure
    for sub in structure.get("subParts") or []:
        yield from _walk_parts(sub)


if __name__ == "__main__":
    raise SystemExit(main())
