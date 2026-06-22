#!/usr/bin/env bash
# Apply low-memory Stalwart settings via stalwart-cli.
# Requires: STALWART_ADMIN_TOKEN, optional STALWART_URL (default mail.solace.onl)
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

mode="${1:-apply}"

case "$mode" in
	status)
		echo "=== Cache ==="
		"${CLI[@]}" get Cache
		echo
		echo "=== SystemSettings ==="
		"${CLI[@]}" get SystemSettings
		echo
		for obj in InMemoryStore SearchStore DataStore BlobStore Logging DataRetention; do
			echo "=== ${obj} ==="
			"${CLI[@]}" get "$obj" 2>&1 || true
			echo
		done
		;;
	apply)
		echo "Applying low-memory Cache settings..."
		# Sizes are bytes (CLI/server expect unsigned integers, not "10mb" strings).
		"${CLI[@]}" update Cache --json '{
			"messages": 10485760,
			"accounts": 5242880,
			"events": 5242880,
			"contacts": 5242880,
			"files": 5242880,
			"mailingLists": 1048576,
			"dkimSignatures": 5242880,
			"domains": 3145728,
			"domainNames": 5242880,
			"domainNamesNegative": 1048576,
			"emailAddresses": 5242880,
			"emailAddressesNegative": 1048576,
			"tenants": 3145728,
			"roles": 3145728,
			"accessTokens": 5242880,
			"httpAuth": 1048576,
			"dnsTxt": 2097152,
			"dnsMx": 2097152,
			"dnsPtr": 1048576,
			"dnsIpv4": 2097152,
			"dnsIpv6": 2097152,
			"dnsTlsa": 1048576,
			"dnsMtaSts": 1048576,
			"dnsRbl": 2097152
		}'

		echo "Applying connection limit (RAM-related; leaves CPU thread pool at default)..."
		"${CLI[@]}" update SystemSettings \
			--field maxConnections=256 \
			--field threadPoolSize=null

		echo "Applying Postgres pool limits on DataStore singleton..."
		"${CLI[@]}" update DataStore --field poolMaxConnections=4

		echo "Trimming metrics retention in Postgres (90d -> 30d)..."
		# Duration fields use milliseconds via --field (30d = 2_592_000_000).
		"${CLI[@]}" update DataRetention --field holdMetricsFor=2592000000

		echo "Reloading settings..."
		"${CLI[@]}" create Action/ReloadSettings

		echo "Done. Current settings:"
		"${CLI[@]}" get Cache
		echo
		"${CLI[@]}" get SystemSettings
		;;
	*)
		echo "Usage: $0 [status|apply]" >&2
		exit 1
		;;
esac
