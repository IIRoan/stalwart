#!/usr/bin/env bash
# Point Stalwart BlobStore at S3-compatible storage.
#
# Required on the Stalwart host (Railway container):
#   AWS_S3_BUCKET_NAME, AWS_ENDPOINT_URL, AWS_DEFAULT_REGION,
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#   STALWART_ADMIN_TOKEN
#
# Optional:
#   STALWART_URL (default https://mail.solace.onl)
#   AWS_S3_KEY_PREFIX (object key prefix inside the bucket)
set -euo pipefail

STALWART_URL="${STALWART_URL:-https://mail.solace.onl}"
STALWART_ADMIN_TOKEN="${STALWART_ADMIN_TOKEN:?STALWART_ADMIN_TOKEN is required}"
AWS_S3_BUCKET_NAME="${AWS_S3_BUCKET_NAME:?AWS_S3_BUCKET_NAME is required}"
AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:?AWS_ENDPOINT_URL is required}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:?AWS_DEFAULT_REGION is required}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set on the Stalwart host}"

CLI_DIR="${TMPDIR:-/tmp}/stalwart-cli-bin"
mkdir -p "$CLI_DIR"

if [ ! -x "$CLI_DIR/stalwart-cli" ]; then
	curl -fsSL "https://github.com/stalwartlabs/cli/releases/download/v1.0.8/stalwart-cli-x86_64-unknown-linux-gnu.tar.xz" \
		| tar xJ -C "$CLI_DIR" --strip-components=1
	chmod +x "$CLI_DIR/stalwart-cli"
fi

CLI=( "$CLI_DIR/stalwart-cli" --url "$STALWART_URL" --api-key "$STALWART_ADMIN_TOKEN" )

blob_json="$(AWS_S3_BUCKET_NAME="$AWS_S3_BUCKET_NAME" \
	AWS_ENDPOINT_URL="$AWS_ENDPOINT_URL" \
	AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION" \
	AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
	AWS_S3_KEY_PREFIX="${AWS_S3_KEY_PREFIX:-}" \
	python3 - <<'PY'
import json
import os

payload = {
    "@type": "S3",
    "bucket": os.environ["AWS_S3_BUCKET_NAME"],
    "region": {
        "@type": "Custom",
        "customEndpoint": os.environ["AWS_ENDPOINT_URL"],
        "customRegion": os.environ["AWS_DEFAULT_REGION"],
    },
    "accessKey": os.environ["AWS_ACCESS_KEY_ID"],
    "secretKey": {
        "@type": "EnvironmentVariable",
        "variableName": "AWS_SECRET_ACCESS_KEY",
    },
    "securityToken": {"@type": "None"},
    "sessionToken": {"@type": "None"},
}
prefix = os.environ.get("AWS_S3_KEY_PREFIX", "").strip()
if prefix:
    payload["keyPrefix"] = prefix
print(json.dumps(payload))
PY
)"

echo "Configuring BlobStore -> s3://${AWS_S3_BUCKET_NAME} (${AWS_ENDPOINT_URL})"
"${CLI[@]}" update BlobStore --json "$blob_json"
"${CLI[@]}" create Action/ReloadSettings
echo "BlobStore configured. Current settings:"
"${CLI[@]}" get BlobStore
