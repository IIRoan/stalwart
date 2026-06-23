#!/usr/bin/env bash
# Manual blob migration (server must be STOPPED).
#
# Prefer Railway: set BLOB_MIGRATE_MODE=true on stalwart-mail and redeploy.
# railway-entrypoint.sh sets BlobStore Default before export and S3 before import.
#
# If you run this script by hand:
#   1. stalwart-cli: BlobStore -> Default, reload, stop Stalwart
#   2. EXPORT_TYPES=blob stalwart --export ...
#   3. stalwart-cli: BlobStore -> S3, reload, stop Stalwart
#   4. stalwart --import ...
set -euo pipefail

EXPORT_DIR="${BLOB_EXPORT_DIR:-/tmp/stalwart-blob-export}"
CONFIG="${STALWART_CONFIG:-/etc/stalwart/config.json}"

if [ ! -f "$CONFIG" ]; then
	echo "Missing ${CONFIG}. Run inside the Stalwart image or set STALWART_CONFIG." >&2
	exit 1
fi

if [ -n "${STALWART_PID:-}" ] && kill -0 "$STALWART_PID" 2>/dev/null; then
	echo "Stalwart is still running (pid=${STALWART_PID}). Stop it before migrating." >&2
	exit 1
fi

if ss -tln 2>/dev/null | grep -q ':25 '; then
	echo "Something is listening on :25. Stop Stalwart before migrating." >&2
	exit 1
fi

echo "Exporting blobs from Postgres to ${EXPORT_DIR}..."
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
EXPORT_TYPES=blob /usr/local/bin/stalwart --config "$CONFIG" --export "$EXPORT_DIR"

if ! find "$EXPORT_DIR" -type f 2>/dev/null | head -n 1 | grep -q .; then
	echo "Export produced no files. Aborting." >&2
	exit 1
fi

echo "Export size: $(du -sh "$EXPORT_DIR" | awk '{print $1}')"
echo "Importing blobs into configured BlobStore (expect S3)..."
/usr/local/bin/stalwart --config "$CONFIG" --import "$EXPORT_DIR"
rm -rf "$EXPORT_DIR"
echo "Done. Spot-check an old message and run scripts/s3-bucket-stats.py."
