#!/usr/bin/env python3
"""Sync Stalwart's ACME certificate into the VPS HAProxy PEM for :443.

HAProxy terminates HTTPS with /etc/haproxy/certs/mail.solace.onl.pem.
Stalwart renews its own certs via ACME (Dns01 + Cloudflare). This script
copies the newest matching Stalwart cert+key onto the VPS and reloads HAProxy.

Typical flow (GitHub Actions):
  1. Probe https://mail.solace.onl and read notAfter
  2. If expiry is within RENEW_BEFORE_DAYS (default 14), export from Postgres
  3. SCP the PEM and reload HAProxy over SSH

Env:
  STALWART_DATABASE_URL   Postgres URL for the Stalwart store (required to export)
  VPS_SSH_HOST            default: mail.solace.onl
  VPS_SSH_USER            default: root
  VPS_SSH_PORT            default: 22
  VPS_SSH_PRIVATE_KEY     PEM private key contents (required to deploy)
  CERT_HOST               default: mail.solace.onl
  RENEW_BEFORE_DAYS       default: 14
"""

from __future__ import annotations

import argparse
import os
import re
import socket
import ssl
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


PEM_BLOCK_RE = re.compile(
    r"-----BEGIN ([^-]+)-----\n(.*?)-----END \1-----",
    re.DOTALL,
)


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--force",
        action="store_true",
        help="Sync even when the live cert has more than RENEW_BEFORE_DAYS left",
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Only print live cert expiry; do not export or deploy",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Export the PEM locally but do not SSH/deploy",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Write exported PEM to this path (default: temp file)",
    )
    return parser.parse_args()


def live_certificate_not_after(host: str, port: int = 443) -> datetime:
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with socket.create_connection((host, port), timeout=15) as sock:
        with context.wrap_socket(sock, server_hostname=host) as tls:
            der = tls.getpeercert(binary_form=True)
    if not der:
        raise RuntimeError(f"no peer certificate from {host}:{port}")
    # Prefer cryptography-free path via openssl
    result = subprocess.run(
        ["openssl", "x509", "-inform", "DER", "-noout", "-enddate"],
        input=der,
        capture_output=True,
        check=True,
    )
    line = result.stdout.decode().strip()  # notAfter=Nov  9 08:32:19 2026 GMT
    raw = line.split("=", 1)[1]
    return datetime.strptime(raw, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)


def openssl_cert_info(pem: str) -> dict[str, str]:
    result = subprocess.run(
        [
            "openssl",
            "x509",
            "-noout",
            "-dates",
            "-subject",
            "-ext",
            "subjectAltName",
        ],
        input=pem,
        capture_output=True,
        text=True,
        check=True,
    )
    info: dict[str, str] = {"raw": result.stdout}
    for line in result.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            info[key.strip()] = value.strip()
    return info


def build_haproxy_pem(blob: bytes, hostname: str) -> str | None:
    text = blob.decode("utf-8", errors="replace")
    if "PRIVATE KEY" not in text or "BEGIN CERTIFICATE" not in text:
        return None
    if hostname not in text:
        return None

    key = None
    leaf = None
    chain: list[str] = []
    for kind, body in PEM_BLOCK_RE.findall(text):
        pem = f"-----BEGIN {kind}-----\n{body}-----END {kind}-----\n"
        if "PRIVATE" in kind:
            key = pem
            continue
        info = openssl_cert_info(pem)
        if hostname in info.get("raw", ""):
            leaf = pem
        else:
            chain.append(pem)

    if not key or not leaf:
        return None

    subprocess.run(
        ["openssl", "pkey", "-noout", "-check"],
        input=key,
        capture_output=True,
        text=True,
        check=True,
    )
    return key + leaf + "".join(chain)


def export_pem_from_stalwart_db(database_url: str, hostname: str) -> str:
    try:
        import psycopg
    except ImportError as exc:  # pragma: no cover
        raise SystemExit(
            "psycopg is required: pip install 'psycopg[binary]'"
        ) from exc

    candidates: list[tuple[datetime, int, str]] = []
    with psycopg.connect(database_url) as conn:
        with conn.cursor() as cur:
            # Stalwart stores registry objects in single-letter KV tables.
            # Certificate PEMs (leaf + chain + key) live in table `s`.
            cur.execute(
                """
                SELECT v
                FROM s
                WHERE position(E'PRIVATE KEY' in encode(v, 'escape')) > 0
                  AND position(E'BEGIN CERTIFICATE' in encode(v, 'escape')) > 0
                """
            )
            rows = cur.fetchall()

    for (blob,) in rows:
        if not isinstance(blob, (bytes, memoryview)):
            continue
        data = bytes(blob)
        try:
            pem = build_haproxy_pem(data, hostname)
        except subprocess.CalledProcessError:
            continue
        if not pem:
            continue
        info = openssl_cert_info(pem)
        not_after = datetime.strptime(
            info["notAfter"], "%b %d %H:%M:%S %Y %Z"
        ).replace(tzinfo=timezone.utc)
        if not_after <= utcnow():
            continue
        san_count = info.get("raw", "").count("DNS:")
        candidates.append((not_after, san_count, pem))

    if not candidates:
        raise RuntimeError(
            f"no valid Stalwart certificate containing {hostname} found in Postgres"
        )

    # Prefer the newest expiry cohort, then the broadest SAN set
    # (mail + autoconfig/autodiscover/mta-sts/apex beats mail-only).
    max_expiry = max(item[0] for item in candidates)
    fresh = [
        item
        for item in candidates
        if (max_expiry - item[0]).total_seconds() < 86400
    ]
    fresh.sort(key=lambda item: (item[1], item[0]), reverse=True)
    best_expiry, san_count, best_pem = fresh[0]
    print(
        f"Selected Stalwart cert expiring {best_expiry.isoformat()} "
        f"({san_count} DNS SANs)"
    )
    return best_pem


def write_ssh_key(private_key: str) -> Path:
    handle = tempfile.NamedTemporaryFile("w", delete=False)
    path = Path(handle.name)
    handle.write(private_key.strip() + "\n")
    handle.close()
    path.chmod(0o600)
    return path


def deploy_pem(pem: str, host: str, user: str, port: int, key_path: Path) -> None:
    remote_tmp = "/tmp/mail.solace.onl.pem"
    ssh_base = [
        "ssh",
        "-i",
        str(key_path),
        "-p",
        str(port),
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=accept-new",
        f"{user}@{host}",
    ]
    scp_base = [
        "scp",
        "-i",
        str(key_path),
        "-P",
        str(port),
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=accept-new",
    ]

    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".pem") as handle:
        local_pem = Path(handle.name)
        handle.write(pem)

    try:
        subprocess.run(
            [*scp_base, str(local_pem), f"{user}@{host}:{remote_tmp}"],
            check=True,
        )
        # Prefer the dedicated installer when present (gh-cert-sync user + sudoers).
        remote_script = f"""
set -euo pipefail
PEM_SRC={remote_tmp}
if [[ -x /usr/local/bin/install-haproxy-cert.sh ]]; then
  sudo -n /usr/local/bin/install-haproxy-cert.sh "$PEM_SRC"
else
  sudo -n openssl x509 -in "$PEM_SRC" -noout -dates -subject >/dev/null
  sudo -n openssl pkey -in "$PEM_SRC" -noout -check >/dev/null
  sudo -n install -d -m 0750 /etc/haproxy/certs
  sudo -n install -m 0640 "$PEM_SRC" /etc/haproxy/certs/mail.solace.onl.pem
  sudo -n chown root:haproxy /etc/haproxy/certs/mail.solace.onl.pem 2>/dev/null \\
    || sudo -n chown root:root /etc/haproxy/certs/mail.solace.onl.pem
  sudo -n haproxy -c -f /etc/haproxy/haproxy.cfg
  sudo -n systemctl reload haproxy
  sudo -n openssl x509 -in /etc/haproxy/certs/mail.solace.onl.pem -noout -dates -subject -ext subjectAltName
  sudo -n rm -f "$PEM_SRC"
fi
"""
        subprocess.run([*ssh_base, "bash", "-s"], input=remote_script, text=True, check=True)
    finally:
        local_pem.unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    host = os.environ.get("CERT_HOST", "mail.solace.onl")
    renew_before_days = float(os.environ.get("RENEW_BEFORE_DAYS", "14"))

    print(f"Checking live certificate for {host}:443 …")
    try:
        not_after = live_certificate_not_after(host)
    except Exception as exc:
        print(f"WARN: could not read live cert ({exc}); treating as expired")
        not_after = utcnow()

    days_left = (not_after - utcnow()).total_seconds() / 86400
    print(f"Live cert notAfter={not_after.isoformat()} ({days_left:.1f} days left)")

    if args.check_only:
        return 0 if days_left > 0 else 1

    if not args.force and days_left > renew_before_days:
        print(
            f"No sync needed (>{renew_before_days} days remaining). "
            "Pass --force to sync anyway."
        )
        return 0

    database_url = os.environ.get("STALWART_DATABASE_URL", "").strip()
    if not database_url:
        raise SystemExit("STALWART_DATABASE_URL is required to export the certificate")

    pem = export_pem_from_stalwart_db(database_url, host)
    info = openssl_cert_info(pem)
    print("Exported PEM:")
    print(info["raw"])

    output = args.output
    if output is None:
        output = Path(tempfile.mkstemp(prefix="haproxy-", suffix=".pem")[1])
    output.write_text(pem)
    output.chmod(0o600)
    print(f"Wrote {output}")

    if args.dry_run:
        print("Dry run: skipping SSH deploy")
        return 0

    ssh_key = os.environ.get("VPS_SSH_PRIVATE_KEY", "").strip()
    if not ssh_key:
        raise SystemExit("VPS_SSH_PRIVATE_KEY is required to deploy")

    vps_host = os.environ.get("VPS_SSH_HOST", host)
    vps_user = os.environ.get("VPS_SSH_USER", "root")
    vps_port = int(os.environ.get("VPS_SSH_PORT", "22"))
    key_path = write_ssh_key(ssh_key)
    try:
        print(f"Deploying to {vps_user}@{vps_host}:{vps_port} …")
        deploy_pem(pem, vps_host, vps_user, vps_port, key_path)
    finally:
        key_path.unlink(missing_ok=True)

    print("Verifying live certificate after deploy …")
    new_not_after = live_certificate_not_after(host)
    print(f"Live cert notAfter={new_not_after.isoformat()}")
    if new_not_after <= utcnow():
        raise SystemExit("deploy finished but live certificate is still expired")
    print("HAProxy certificate sync complete.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        sys.stderr.write(exc.stderr.decode() if isinstance(exc.stderr, bytes) else (exc.stderr or str(exc)))
        raise SystemExit(exc.returncode or 1)
