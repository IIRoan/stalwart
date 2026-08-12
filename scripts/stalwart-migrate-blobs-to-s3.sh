#!/usr/bin/env bash
# Migrate blobs from current BlobStore (usually FileSystem volume) -> Railway bucket (S3).
# Prefer the entrypoint path: set BLOB_MIGRATE_TO_S3=true on stalwart-mail and redeploy.
# Requires BUCKET / BUCKET_ENDPOINT / BUCKET_REGION / BUCKET_ACCESS_KEY_ID /
# BUCKET_SECRET_ACCESS_KEY (Railway bucket variable references).
set -euo pipefail

EXPORT_DIR="${BLOB_EXPORT_DIR:-/tmp/stalwart-blob-export-s3}"
CONFIG="${STALWART_CONFIG:-/etc/stalwart/config.json}"
KEY_PREFIX="${BLOB_S3_KEY_PREFIX:-stalwart/}"

: "${BUCKET:?BUCKET required}"
: "${BUCKET_ENDPOINT:?BUCKET_ENDPOINT required}"
: "${BUCKET_REGION:?BUCKET_REGION required}"
: "${BUCKET_ACCESS_KEY_ID:?BUCKET_ACCESS_KEY_ID required}"
: "${BUCKET_SECRET_ACCESS_KEY:?BUCKET_SECRET_ACCESS_KEY required}"

IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
STALWART_URL="${STALWART_URL:-http://${IP}:8080}"
STALWART_ADMIN_TOKEN="${STALWART_ADMIN_TOKEN:?STALWART_ADMIN_TOKEN required}"

CLI=(stalwart-cli --url "$STALWART_URL" --api-key "$STALWART_ADMIN_TOKEN")

S3_JSON="$(python3 - <<PY
import json, os
print(json.dumps({
    "@type": "S3",
    "bucket": os.environ["BUCKET"],
    "region": {
        "@type": "Custom",
        "customEndpoint": os.environ["BUCKET_ENDPOINT"],
        "customRegion": os.environ["BUCKET_REGION"],
    },
    "accessKey": {
        "@type": "EnvironmentVariable",
        "variableName": "BUCKET_ACCESS_KEY_ID",
    },
    "secretKey": {
        "@type": "EnvironmentVariable",
        "variableName": "BUCKET_SECRET_ACCESS_KEY",
    },
    "securityToken": {"@type": "None"},
    "sessionToken": {"@type": "None"},
    "keyPrefix": os.environ.get("BLOB_S3_KEY_PREFIX", "stalwart/"),
    "verifyAfterWrite": True,
}))
PY
)"

echo "=== Export blobs from current BlobStore ==="
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
EXPORT_TYPES=blob /usr/local/bin/stalwart --config "$CONFIG" --export "$EXPORT_DIR"
du -sh "$EXPORT_DIR"

echo "=== Switch BlobStore -> S3 ($BUCKET @ $BUCKET_ENDPOINT, prefix=$KEY_PREFIX) ==="
"${CLI[@]}" update BlobStore --json "$S3_JSON"
"${CLI[@]}" create Action/ReloadSettings
sleep 2

echo "=== Import blobs into Railway bucket ==="
/usr/local/bin/stalwart --config "$CONFIG" --import "$EXPORT_DIR"
rm -rf "$EXPORT_DIR"

echo "=== Done ==="
"${CLI[@]}" get BlobStore
echo "Next: unset BLOB_MIGRATE_TO_S3, detach volume /var/stalwart/blobs, redeploy."
