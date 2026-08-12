#!/usr/bin/env python3
"""Copy Stalwart FileSystem blobs to an S3-compatible bucket.

Stalwart stores FS blobs as nested dirs whose leaf filename is the base32 blob
id. S3 uses that same base32 id as the object key (optionally with keyPrefix).
This copies leaf files -> S3; it does NOT use stalwart --import (which refuses
to write into a non-empty key range).
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


def sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def sigv4_headers(
    method: str,
    url_path: str,
    payload: bytes,
    host: str,
    access: str,
    secret: str,
    region: str,
) -> dict[str, str]:
    now = datetime.now(timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(payload).hexdigest()
    canonical_headers = (
        f"host:{host}\n"
        f"x-amz-content-sha256:{payload_hash}\n"
        f"x-amz-date:{amz_date}\n"
    )
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical_request = (
        f"{method}\n{url_path}\n\n{canonical_headers}\n{signed_headers}\n{payload_hash}"
    )
    credential_scope = f"{datestamp}/{region}/s3/aws4_request"
    string_to_sign = (
        "AWS4-HMAC-SHA256\n"
        f"{amz_date}\n"
        f"{credential_scope}\n"
        f"{hashlib.sha256(canonical_request.encode()).hexdigest()}"
    )
    signing_key = sign(
        sign(sign(sign(("AWS4" + secret).encode("utf-8"), datestamp), region), "s3"),
        "aws4_request",
    )
    signature = hmac.new(signing_key, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    return {
        "Host": host,
        "x-amz-date": amz_date,
        "x-amz-content-sha256": payload_hash,
        "Authorization": (
            f"AWS4-HMAC-SHA256 Credential={access}/{credential_scope}, "
            f"SignedHeaders={signed_headers}, Signature={signature}"
        ),
        "Content-Length": str(len(payload)),
    }


def put_object(
    endpoint: str,
    bucket: str,
    key: str,
    body: bytes,
    access: str,
    secret: str,
    region: str,
) -> None:
    endpoint = endpoint.rstrip("/")
    host = endpoint.removeprefix("https://").removeprefix("http://")
    # Path-style matches Stalwart's rust-s3 client (.with_path_style()).
    url_path = f"/{bucket}/{key}"
    url = f"{endpoint}{url_path}"
    headers = sigv4_headers("PUT", url_path, body, host, access, secret, region)
    req = urllib.request.Request(url, data=body, method="PUT", headers=headers)
    with urllib.request.urlopen(req, timeout=120) as resp:
        if resp.status < 200 or resp.status >= 300:
            raise RuntimeError(f"PUT {key} -> HTTP {resp.status}")


def head_object(
    endpoint: str,
    bucket: str,
    key: str,
    access: str,
    secret: str,
    region: str,
) -> int:
    endpoint = endpoint.rstrip("/")
    host = endpoint.removeprefix("https://").removeprefix("http://")
    url_path = f"/{bucket}/{key}"
    url = f"{endpoint}{url_path}"
    headers = sigv4_headers("HEAD", url_path, b"", host, access, secret, region)
    req = urllib.request.Request(url, method="HEAD", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status
    except urllib.error.HTTPError as exc:
        return exc.code


def iter_blob_files(root: Path):
    for path in root.rglob("*"):
        if path.is_file():
            yield path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src", default=os.environ.get("BLOB_FS_PATH", "/var/stalwart/blobs"))
    parser.add_argument("--prefix", default=os.environ.get("BLOB_S3_KEY_PREFIX", "stalwart/"))
    args = parser.parse_args()

    bucket = os.environ["BUCKET"]
    endpoint = os.environ["BUCKET_ENDPOINT"]
    region = os.environ.get("BUCKET_REGION") or "auto"
    access = os.environ["BUCKET_ACCESS_KEY_ID"]
    secret = os.environ["BUCKET_SECRET_ACCESS_KEY"]
    prefix = args.prefix or ""
    src = Path(args.src)

    if not src.is_dir():
        print(f"error: source directory missing: {src}", file=sys.stderr)
        return 1

    files = list(iter_blob_files(src))
    if not files:
        print(f"error: no blob files under {src}", file=sys.stderr)
        return 1

    total_bytes = 0
    uploaded = 0
    for path in files:
        key = f"{prefix}{path.name}"
        body = path.read_bytes()
        put_object(endpoint, bucket, key, body, access, secret, region)
        status = head_object(endpoint, bucket, key, access, secret, region)
        if status < 200 or status >= 300:
            print(f"error: HEAD failed for {key}: HTTP {status}", file=sys.stderr)
            return 1
        total_bytes += len(body)
        uploaded += 1
        if uploaded % 50 == 0 or uploaded == len(files):
            print(f"uploaded {uploaded}/{len(files)} files ({total_bytes} bytes)", flush=True)

    print(f"done: {uploaded} files, {total_bytes} bytes -> s3://{bucket}/{prefix}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
