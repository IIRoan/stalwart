#!/usr/bin/env bash
# Migrate blobs from Postgres (Default) -> Railway volume (FileSystem BlobStore).
# Run on stalwart-mail via: railway ssh -s stalwart-mail -- bash /path/to/script
# Or set BLOB_MIGRATE_TO_FS=true on the service and redeploy (railway-entrypoint.sh).
set -euo pipefail

BLOB_PATH="${BLOB_FS_PATH:-/var/stalwart/blobs}"
EXPORT_DIR="${BLOB_EXPORT_DIR:-/tmp/stalwart-blob-export-fs}"
CONFIG="${STALWART_CONFIG:-/etc/stalwart/config.json}"

IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
STALWART_URL="${STALWART_URL:-http://${IP}:8080}"
STALWART_ADMIN_TOKEN="${STALWART_ADMIN_TOKEN:?STALWART_ADMIN_TOKEN required}"

CLI=(stalwart-cli --url "$STALWART_URL" --api-key "$STALWART_ADMIN_TOKEN")

mkdir -p "$BLOB_PATH"
chown -R stalwart:stalwart "$BLOB_PATH" 2>/dev/null || true

echo "=== Ensure BlobStore -> Default (export from Postgres) ==="
"${CLI[@]}" update BlobStore --json '{"@type": "Default"}'
"${CLI[@]}" create Action/ReloadSettings
sleep 2

echo "=== Export blobs from Postgres ==="
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
EXPORT_TYPES=blob /usr/local/bin/stalwart --config "$CONFIG" --export "$EXPORT_DIR"
du -sh "$EXPORT_DIR"

echo "=== Switch BlobStore -> FileSystem ($BLOB_PATH) ==="
"${CLI[@]}" update BlobStore --json "{\"@type\": \"FileSystem\", \"path\": \"$BLOB_PATH\", \"depth\": 2}"
"${CLI[@]}" create Action/ReloadSettings
sleep 2

echo "=== Import blobs into volume ==="
/usr/local/bin/stalwart --config "$CONFIG" --import "$EXPORT_DIR"
rm -rf "$EXPORT_DIR"

echo "=== Done ==="
"${CLI[@]}" get BlobStore
du -sh "$BLOB_PATH"
