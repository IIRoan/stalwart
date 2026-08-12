#!/usr/bin/env bash
# Copy FileSystem blobs -> Railway bucket, then point BlobStore at S3.
# Prefer: set BLOB_MIGRATE_TO_S3=true on stalwart-mail and redeploy.
# Requires BUCKET / BUCKET_ENDPOINT / BUCKET_REGION / BUCKET_ACCESS_KEY_ID /
# BUCKET_SECRET_ACCESS_KEY (Railway bucket variable references).
set -euo pipefail

BLOB_PATH="${BLOB_FS_PATH:-/var/stalwart/blobs}"
KEY_PREFIX="${BLOB_S3_KEY_PREFIX:-stalwart/}"
SYNC_SCRIPT="${BLOB_S3_SYNC_SCRIPT:-/usr/local/share/stalwart/sync-fs-blobs-to-s3.py}"

: "${BUCKET:?BUCKET required}"
: "${BUCKET_ENDPOINT:?BUCKET_ENDPOINT required}"
: "${BUCKET_REGION:?BUCKET_REGION required}"
: "${BUCKET_ACCESS_KEY_ID:?BUCKET_ACCESS_KEY_ID required}"
: "${BUCKET_SECRET_ACCESS_KEY:?BUCKET_SECRET_ACCESS_KEY required}"

IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
STALWART_URL="${STALWART_URL:-http://${IP}:8080}"
STALWART_ADMIN_TOKEN="${STALWART_ADMIN_TOKEN:?STALWART_ADMIN_TOKEN required}"

CLI=(stalwart-cli --url "$STALWART_URL" --api-key "$STALWART_ADMIN_TOKEN")

if [ ! -f "$SYNC_SCRIPT" ]; then
	SYNC_SCRIPT="$(CDPATH= cd -- "$(dirname "$0")" && pwd)/sync-fs-blobs-to-s3.py"
fi

echo "=== Copy FileSystem blobs -> S3 ($BUCKET) ==="
python3 "$SYNC_SCRIPT" --src "$BLOB_PATH" --prefix "$KEY_PREFIX"

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

echo "=== Switch BlobStore -> S3 ==="
"${CLI[@]}" update BlobStore --json "$S3_JSON"
"${CLI[@]}" create Action/ReloadSettings
sleep 2

echo "=== Done ==="
"${CLI[@]}" get BlobStore
echo "Next: unset BLOB_MIGRATE_TO_S3, detach volume /var/stalwart/blobs, redeploy."
