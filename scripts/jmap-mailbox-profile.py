#!/usr/bin/env python3
"""Profile JMAP mailbox load like the web UI — per-method timings and errors.

Usage:
  python scripts/jmap-mailbox-profile.py
  python scripts/jmap-mailbox-profile.py --account n --mailbox a --limit 50
  python scripts/jmap-mailbox-profile.py --user-token "$USER_TOKEN" --with-bodies
  python scripts/jmap-mailbox-profile.py --parallel   # mimic browser concurrent calls
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


def load_env() -> dict[str, str]:
    env: dict[str, str] = {}
    env_path = Path(__file__).resolve().parents[1] / ".env"
    if not env_path.exists():
        return env
    for line in env_path.read_text().splitlines():
        if "=" in line and not line.strip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


@dataclass
class Step:
    label: str
    ms: float
    ok: bool
    detail: str = ""
    methods: list[str] = field(default_factory=list)


class JmapClient:
    def __init__(self, base_url: str, token: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.api_url = ""
        self.session: dict[str, Any] = {}

    def _request(self, url: str, body: dict | None = None, timeout: float = 120) -> tuple[float, dict]:
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(
            url,
            data=data,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
            method="POST" if body is not None else "GET",
        )
        t0 = time.perf_counter()
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            out = json.load(resp)
        return (time.perf_counter() - t0) * 1000, out

    def session_get(self) -> tuple[float, dict]:
        ms, sess = self._request(f"{self.base_url}/jmap/session")
        self.session = sess
        self.api_url = sess["apiUrl"]
        return ms, sess

    def call(self, method_calls: list, timeout: float = 120) -> tuple[float, dict]:
        body = {
            "using": [
                "urn:ietf:params:jmap:core",
                "urn:ietf:params:jmap:mail",
                "urn:ietf:params:jmap:submission",
            ],
            "methodCalls": method_calls,
        }
        return self._request(self.api_url, body, timeout=timeout)

    def parse_responses(self, payload: dict) -> list[tuple[str, dict | str, str]]:
        rows: list[tuple[str, dict | str, str]] = []
        for item in payload.get("methodResponses", []):
            name, status, call_id = item[0], item[1], item[2] if len(item) > 2 else ""
            rows.append((name, status, call_id))
        return rows


def fmt_ms(ms: float) -> str:
    if ms >= 1000:
        return f"{ms / 1000:.2f}s"
    return f"{ms:.0f}ms"


def summarize_methods(rows: list[tuple[str, dict | str, str]]) -> tuple[list[str], str]:
    names: list[str] = []
    problems: list[str] = []
    for name, status, call_id in rows:
        names.append(name)
        if name == "error":
            problems.append(f"{call_id or '?'}: {status}")
        elif isinstance(status, dict):
            if "notFound" in status and status["notFound"]:
                problems.append(f"{name}: notFound={len(status['notFound'])}")
            if "list" in status and not status["list"] and name.endswith("/get"):
                problems.append(f"{name}: empty list")
    return names, "; ".join(problems)


def profile_mailbox_load(
    client: JmapClient,
    account_id: str,
    mailbox_id: str,
    limit: int,
    with_bodies: bool,
    parallel: bool,
) -> list[Step]:
    steps: list[Step] = []

    ms, sess = client.session_get()
    steps.append(Step("JMAP session", ms, True, f"accounts={len(sess.get('accounts', {}))}"))

    def run_step(label: str, calls: list, timeout: float = 120) -> dict:
        t0 = time.perf_counter()
        try:
            _, payload = client.call(calls, timeout=timeout)
            ms = (time.perf_counter() - t0) * 1000
            rows = client.parse_responses(payload)
            methods, problems = summarize_methods(rows)
            ok = not problems and all(name != "error" for name, _, _ in rows)
            steps.append(
                Step(label, ms, ok, problems or f"{len(methods)} method(s)", methods)
            )
            return payload
        except urllib.error.HTTPError as exc:
            ms = (time.perf_counter() - t0) * 1000
            body = exc.read().decode("utf-8", errors="replace")[:200]
            steps.append(Step(label, ms, False, f"HTTP {exc.code}: {body}"))
            raise
        except Exception as exc:  # noqa: BLE001
            ms = (time.perf_counter() - t0) * 1000
            steps.append(Step(label, ms, False, str(exc)))
            raise

    if parallel:
        futures = {}
        with ThreadPoolExecutor(max_workers=4) as pool:
            futures[pool.submit(client.call, [["Mailbox/get", {"accountId": account_id, "ids": None}, "m"]])] = "Mailbox/get"
            futures[pool.submit(client.call, [["Email/query", {"accountId": account_id, "filter": {"inMailbox": mailbox_id}, "sort": [{"property": "receivedAt", "isAscending": False}], "limit": limit}, "q"]])] = "Email/query"
            t0 = time.perf_counter()
            payloads: dict[str, dict] = {}
            for fut in as_completed(futures):
                label = futures[fut]
                try:
                    ms, payload = fut.result()
                    rows = client.parse_responses(payload)
                    methods, problems = summarize_methods(rows)
                    ok = not problems and all(name != "error" for name, _, _ in rows)
                    steps.append(Step(f"parallel {label}", ms, ok, problems, methods))
                    payloads[label] = payload
                except Exception as exc:  # noqa: BLE001
                    steps.append(Step(f"parallel {label}", (time.perf_counter() - t0) * 1000, False, str(exc)))
            query_payload = payloads.get("Email/query", {})
    else:
        query_payload = run_step(
            "Mailbox/get",
            [["Mailbox/get", {"accountId": account_id, "ids": None}, "m"]],
        )
        query_payload = run_step(
            "Email/query",
            [[
                "Email/query",
                {
                    "accountId": account_id,
                    "filter": {"inMailbox": mailbox_id},
                    "sort": [{"property": "receivedAt", "isAscending": False}],
                    "limit": limit,
                },
                "q",
            ]],
        )

    ids: list[str] = []
    for _, status, _ in client.parse_responses(query_payload):
        if isinstance(status, dict) and "ids" in status:
            ids = status["ids"]
            break

    if not ids:
        steps.append(Step("Email/get (preview)", 0, False, "no ids from Email/query"))
        return steps

    preview_props = [
        "id",
        "blobId",
        "threadId",
        "mailboxIds",
        "keywords",
        "size",
        "receivedAt",
        "from",
        "to",
        "cc",
        "bcc",
        "replyTo",
        "subject",
        "preview",
        "hasAttachment",
    ]
    run_step(
        f"Email/get preview x{len(ids)}",
        [[
            "Email/get",
            {"accountId": account_id, "ids": ids, "properties": preview_props},
            "gp",
        ]],
    )

    if with_bodies:
        body_props = ["id", "bodyValues", "textBody", "htmlBody", "attachments"]
        run_step(
            f"Email/get bodyValues x{len(ids)}",
            [[
                "Email/get",
                {
                    "accountId": account_id,
                    "ids": ids,
                    "properties": body_props,
                    "fetchTextBodyValues": True,
                    "fetchHTMLBodyValues": True,
                },
                "gb",
            ]],
            timeout=300,
        )

    # Batched request similar to a single browser POST (sequential methods in one HTTP call).
    batch_calls = [
        ["Mailbox/get", {"accountId": account_id, "ids": None}, "bm"],
        [
            "Email/query",
            {
                "accountId": account_id,
                "filter": {"inMailbox": mailbox_id},
                "sort": [{"property": "receivedAt", "isAscending": False}],
                "limit": limit,
            },
            "bq",
        ],
        [
            "Email/get",
            {"accountId": account_id, "ids": ids, "properties": preview_props},
            "bg",
        ],
    ]
    run_step(f"batched mailbox+query+get x{len(ids)}", batch_calls)

    return steps


def print_report(steps: list[Step]) -> int:
    total = sum(s.ms for s in steps)
    print()
    print("JMAP mailbox load profile")
    print("=" * 72)
    print(f"{'Step':<40} {'Time':>10}  {'Status':<6} Detail")
    print("-" * 72)
    for step in steps:
        status = "OK" if step.ok else "FAIL"
        methods = f" [{', '.join(step.methods)}]" if step.methods else ""
        detail = (step.detail + methods)[:80]
        print(f"{step.label:<40} {fmt_ms(step.ms):>10}  {status:<6} {detail}")
    print("-" * 72)
    print(f"{'TOTAL (sum of steps)':<40} {fmt_ms(total):>10}")
    print()

    slow = sorted([s for s in steps if s.ok], key=lambda s: s.ms, reverse=True)[:3]
    if slow:
        print("Slowest steps:")
        for s in slow:
            print(f"  - {s.label}: {fmt_ms(s.ms)}")
        print()

    failed = [s for s in steps if not s.ok]
    if failed:
        print("Failures (likely match web UI errors):")
        for s in failed:
            print(f"  - {s.label}: {s.detail}")
        print()
        return 1

    # Heuristic guidance
    body_steps = [s for s in steps if "bodyValues" in s.label and s.ok]
    preview_steps = [s for s in steps if "preview" in s.label and s.ok]
    if body_steps and preview_steps:
        body_ms = body_steps[0].ms
        preview_ms = preview_steps[0].ms
        if body_ms > preview_ms * 3:
            print(
                "Note: body fetches are much slower than previews — "
                "the server expands MIME bodies for each message sequentially (~60ms/msg)."
            )
            print("Browser 'Queued' time is often waiting for earlier parallel requests, not server wait.")
            print()

    return 0


def main() -> int:
    env = load_env()
    parser = argparse.ArgumentParser(description="Profile JMAP mailbox load timings")
    parser.add_argument("--base-url", default=env.get("STALWART_URL", "https://mail.solace.onl"))
    parser.add_argument("--token", default=env.get("STALWART_USER_TOKEN") or env.get("STALWART_ADMIN_TOKEN"))
    parser.add_argument("--account", default="n", help="JMAP account id (default: n)")
    parser.add_argument("--mailbox", default="a", help="Mailbox id (default: a = Inbox)")
    parser.add_argument("--limit", type=int, default=50, help="Email/query limit (web UI uses ~50)")
    parser.add_argument("--with-bodies", action="store_true", help="Also time Email/get with bodyValues")
    parser.add_argument("--parallel", action="store_true", help="Fire Mailbox/get and Email/query concurrently")
    args = parser.parse_args()

    if not args.token:
        print("Set STALWART_USER_TOKEN or STALWART_ADMIN_TOKEN in .env", file=sys.stderr)
        return 2

    client = JmapClient(args.base_url, args.token)
    print(f"Profiling {args.base_url} account={args.account} mailbox={args.mailbox} limit={args.limit}")
    steps = profile_mailbox_load(
        client,
        args.account,
        args.mailbox,
        args.limit,
        args.with_bodies,
        args.parallel,
    )
    return print_report(steps)


if __name__ == "__main__":
    raise SystemExit(main())
