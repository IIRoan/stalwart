#!/bin/sh
# Offline tests for relay-route helpers in railway-entrypoint.sh.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ENTRYPOINT="$ROOT/railway-entrypoint.sh"
MOCK_BIN="$(mktemp -d)"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	rm -rf "$MOCK_BIN"
	exit 1
}

pass() {
	printf 'PASS: %s\n' "$1"
}

cleanup() {
	rm -rf "$MOCK_BIN"
}
trap cleanup EXIT

route_ok="Type: Relay Host

Relay Host
  Address:  10.250.11.177
  Port:     2525
  Protocol: SMTP"

route_bad="Type: Relay Host

Relay Host
  Address:  10.250.11.40
  Port:     2525
  Protocol: SMTP"

cat > "$MOCK_BIN/stalwart-cli" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
	case "$1" in
		--url|--api-key) shift 2 ;;
		get)
			shift
			if [ "$1" = "MtaRoute" ]; then
				if [ "${TEST_ROUTE:-ok}" = "ok" ]; then
					printf '%s\n' "$ROUTE_OK"
				else
					printf '%s\n' "$ROUTE_BAD"
				fi
				exit 0
			fi
			exit 1
			;;
		*) shift ;;
	esac
done
exit 1
EOF
chmod +x "$MOCK_BIN/stalwart-cli"
export PATH="$MOCK_BIN:$PATH"
export ROUTE_OK="$route_ok"
export ROUTE_BAD="$route_bad"

eval "$(sed -n '/^detect_container_ip()/,/^}/p; /^stalwart_management_url()/,/^}/p; /^relay_route_matches()/,/^}/p' "$ENTRYPOINT")"

STALWART_HTTP_PORT=8080
FRPC_RELAY_LOCAL_PORT=2525
RELAY_ROUTE_ID=ivnbzc1aaba9
STALWART_ADMIN_TOKEN=dummy
RELAY_BIND_ADDR=10.250.11.177

url="$(stalwart_management_url)"
[ "$url" = "http://10.250.11.177:8080" ] || fail "stalwart_management_url"
pass "stalwart_management_url uses container IP (not loopback)"

relay_route_matches "10.250.11.177" || fail "relay_route_matches positive case"
pass "relay_route_matches accepts matching route"

TEST_ROUTE=bad
relay_route_matches "10.250.11.177" && fail "relay_route_matches should reject stale route"
pass "relay_route_matches rejects stale route"

printf 'All relay-route helper tests passed.\n'
