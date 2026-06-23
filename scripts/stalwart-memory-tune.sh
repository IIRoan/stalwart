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
		for obj in InMemoryStore SearchStore DataStore BlobStore MetricsStore TracingStore DataRetention; do
			echo "=== ${obj} ==="
			"${CLI[@]}" get "$obj" 2>&1 || true
			echo
		done
		;;
	apply)
		echo "Applying low-memory Cache settings..."
		# ~45 MB total configured cache ceiling (down from ~75 MB).
		"${CLI[@]}" update Cache --json '{
			"messages": 5242880,
			"accounts": 3145728,
			"events": 3145728,
			"contacts": 3145728,
			"files": 3145728,
			"mailingLists": 1048576,
			"dkimSignatures": 3145728,
			"domains": 2097152,
			"domainNames": 3145728,
			"domainNamesNegative": 1048576,
			"emailAddresses": 3145728,
			"emailAddressesNegative": 1048576,
			"tenants": 2097152,
			"roles": 2097152,
			"accessTokens": 3145728,
			"httpAuth": 1048576,
			"dnsTxt": 1048576,
			"dnsMx": 1048576,
			"dnsPtr": 1048576,
			"dnsIpv4": 1048576,
			"dnsIpv6": 1048576,
			"dnsTlsa": 1048576,
			"dnsMtaSts": 1048576,
			"dnsRbl": 1048576,
			"negativeTtl": 1800000
		}'

		echo "Applying connection limit (RAM-related; leaves CPU thread pool at default)..."
		"${CLI[@]}" update SystemSettings \
			--field maxConnections=128 \
			--field threadPoolSize=null

		echo "Applying Postgres pool limits on DataStore singleton..."
		"${CLI[@]}" update DataStore \
			--field poolMaxConnections=3 \
			--field poolRecyclingMethod=clean

		echo "Stopping Postgres-backed metrics history (Prometheus scrape unchanged)..."
		"${CLI[@]}" update MetricsStore --json '{"@type": "Disabled"}'

		echo "Disabling delivery tracing history in Postgres..."
		"${CLI[@]}" update TracingStore --json '{"@type": "Disabled"}'

		echo "Reducing JMAP/MTA history retained in Postgres..."
		"${CLI[@]}" update DataRetention \
			--field holdMtaReportsFor=604800000 \
			--field holdMetricsFor=2592000000 \
			--field maxChangesHistory=2000

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
