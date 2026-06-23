#!/usr/bin/env bash
# Point BlobStore back at Postgres (Default) so historical mail bodies are readable.
set -euo pipefail

STALWART_URL="${STALWART_URL:-https://mail.solace.onl}"
STALWART_ADMIN_TOKEN="${STALWART_ADMIN_TOKEN:?STALWART_ADMIN_TOKEN is required}"

CLI_DIR="${TMPDIR:-/tmp}/stalwart-cli-bin"
mkdir -p "$CLI_DIR"

if [ ! -x "$CLI_DIR/stalwart-cli" ]; then
	curl -fsSL "https://github.com/stalwartlabs/cli/releases/download/v1.0.8/stalwart-cli-x86_64-unknown-linux-gnu.tar.xz" \
		| tar xJ -C "$CLI_DIR" --strip-components=1
	chmod +x "$CLI_DIR/stalwart-cli"
fi

CLI=( "$CLI_DIR/stalwart-cli" --url "$STALWART_URL" --api-key "$STALWART_ADMIN_TOKEN" )

echo "Setting BlobStore -> Default (Postgres)..."
"${CLI[@]}" update BlobStore --json '{"@type": "Default"}'
"${CLI[@]}" create Action/ReloadSettings
echo "Current BlobStore:"
"${CLI[@]}" get BlobStore
