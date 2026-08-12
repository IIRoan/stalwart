#!/usr/bin/env bash
# Tune Stalwart RAM vs webmail performance via stalwart-cli / apply-stalwart-tune.py.
set -euo pipefail

STALWART_URL="${STALWART_URL:-https://mail.solace.onl}"
STALWART_ADMIN_TOKEN="${STALWART_ADMIN_TOKEN:?STALWART_ADMIN_TOKEN is required}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

CLI_DIR="${TMPDIR:-/tmp}/stalwart-cli-bin"
mkdir -p "$CLI_DIR"

if [ ! -x "$CLI_DIR/stalwart-cli" ]; then
	curl -fsSL "https://github.com/stalwartlabs/cli/releases/download/v1.0.12/stalwart-cli-x86_64-unknown-linux-gnu.tar.xz" \
		| tar xJ -C "$CLI_DIR" --strip-components=1
	chmod +x "$CLI_DIR/stalwart-cli"
fi

CLI=( "$CLI_DIR/stalwart-cli" --url "$STALWART_URL" --api-key "$STALWART_ADMIN_TOKEN" )

mode="${1:-apply}"

case "$mode" in
	status)
		"${CLI[@]}" get Cache
		echo
		"${CLI[@]}" get Jmap
		echo
		"${CLI[@]}" get SystemSettings
		echo
		"${CLI[@]}" get DataStore
		echo
		for obj in BlobStore MetricsStore TracingStore DataRetention; do
			echo "=== ${obj} ==="
			"${CLI[@]}" get "$obj" 2>&1 || true
			echo
		done
		;;
	apply)
		exec python3 "$SCRIPT_DIR/apply-stalwart-tune.py"
		;;
	apply-minimal)
		echo "Applying minimal-RAM cache (5 MB messages — slow mailbox loads)..."
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
		"${CLI[@]}" update DataStore --field poolMaxConnections=3 --field poolRecyclingMethod=clean
		"${CLI[@]}" update MetricsStore --json '{"@type": "Disabled"}'
		"${CLI[@]}" update TracingStore --json '{"@type": "Disabled"}'
		"${CLI[@]}" create Action/ReloadSettings
		;;
	*)
		echo "Usage: $0 [status|apply|apply-minimal]" >&2
		exit 1
		;;
esac
