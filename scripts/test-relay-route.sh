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

cat > "$MOCK_BIN/stalwart-cli" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
	case "$1" in
		--url|--api-key) shift 2 ;;
		get)
			shift
			if [ "$1" = "MtaRoute" ]; then
				printf '%s\n' "$ROUTE_OK"
				exit 0
			fi
			exit 1
			;;
		update) exit 0 ;;
		create) exit 0 ;;
		*) shift ;;
	esac
done
exit 1
EOF
chmod +x "$MOCK_BIN/stalwart-cli"
export PATH="$MOCK_BIN:$PATH"
export ROUTE_OK="$route_ok"

eval "$(sed -n '/^detect_container_ip()/,/^}/p; /^stalwart_management_url()/,/^}/p; /^stalwart_api_ready()/,/^}/p' "$ENTRYPOINT")"

STALWART_HTTP_PORT=8080
FRPC_RELAY_LOCAL_PORT=2525
RELAY_ROUTE_ID=ivnbzc1aaba9
STALWART_ADMIN_TOKEN=dummy
RELAY_BIND_ADDR=10.250.11.177

url="$(stalwart_management_url)"
[ "$url" = "http://10.250.11.177:8080" ] || fail "stalwart_management_url"
pass "stalwart_management_url uses container private IP (not loopback)"

stalwart_api_ready || fail "stalwart_api_ready with mocked cli"
pass "stalwart_api_ready accepts MtaRoute get fallback"

printf 'All relay-route helper tests passed.\n'
