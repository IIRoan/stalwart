#!/bin/sh
# Railway entrypoint: start Stalwart + frpc, then supervise and activate slot/relay when ready.
set -eu

FRPC_LOG_FILE="${FRPC_LOG_FILE:-/tmp/frpc.log}"
STALWART_LOG_DIR="${STALWART_LOG_DIR:-/var/log/stalwart}"
HTTP_PORT="${STALWART_HTTP_PORT:-8080}"
HTTP_HOST="${STALWART_HTTP_HOST:-mail.solace.onl}"

log() {
	printf '%s [%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$1" "$2" >&2
}

die() {
	log error "$1"
	exit 1
}

parse_database_url() {
	url="$1"
	url="${url#postgresql://}"
	url="${url#postgres://}"
	url="${url%%\?*}"

	auth="${url%%@*}"
	rest="${url#*@}"

	PGUSER="${PGUSER:-${auth%%:*}}"
	if [ -z "${PGPASSWORD:-}" ]; then
		export PGPASSWORD="${auth#*:}"
	fi

	hostport="${rest%%/*}"
	PGDATABASE="${PGDATABASE:-${rest#*/}}"

	if [ "${hostport#*:}" != "$hostport" ]; then
		PGHOST="${PGHOST:-${hostport%%:*}}"
		PGPORT="${PGPORT:-${hostport##*:}}"
	else
		PGHOST="${PGHOST:-$hostport}"
		PGPORT="${PGPORT:-5432}"
	fi
}

if [ -z "${PGHOST:-}" ]; then
	if [ -n "${DATABASE_URL:-}" ]; then
		parse_database_url "$DATABASE_URL"
	elif [ -n "${DATABASE_PUBLIC_URL:-}" ]; then
		parse_database_url "$DATABASE_PUBLIC_URL"
	fi
fi

PGHOST="${PGHOST:-}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-${POSTGRES_DB:-railway}}"
PGUSER="${PGUSER:-${POSTGRES_USER:-postgres}}"
export PGPASSWORD="${PGPASSWORD:-${POSTGRES_PASSWORD:-}}"

USE_TLS=false
ALLOW_INVALID=false
RECOVERY_MODE=false

case "$PGHOST" in
	*.proxy.rlwy.net|*.rlwy.net) USE_TLS=true; ALLOW_INVALID=true ;;
	*.railway.internal) USE_TLS=false; ALLOW_INVALID=false ;;
esac
case "${DATABASE_URL:-}${DATABASE_PUBLIC_URL:-}" in
	*sslmode=require*|*sslmode=verify*) USE_TLS=true; ALLOW_INVALID=true ;;
esac
case "${STALWART_RECOVERY_MODE:-}" in
	1|true|TRUE|yes|YES) RECOVERY_MODE=true ;;
esac

json_get() {
	printf '%s\n' "$2" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}

json_bool() {
	printf '%s\n' "$2" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\\(true\\|false\\).*/\\1/p"
}

slot_api() {
	method="$1"
	path="$2"
	body="${3:-}"
	url="${SLOT_MANAGER_URL:-https://mail.solace.onl/slot-manager}${path}"

	if [ "$method" = "GET" ]; then
		curl -fsS --connect-timeout 5 --max-time 60 \
			-H "Authorization: Bearer ${SLOT_MANAGER_TOKEN}" \
			"$url"
	else
		curl -fsS -X "$method" --connect-timeout 5 --max-time 60 \
			-H "Authorization: Bearer ${SLOT_MANAGER_TOKEN}" \
			-H "Content-Type: application/json" \
			-d "$body" \
			"$url"
	fi
}

pick_slot() {
	FRPC_SLOT="${FRPC_SLOT:-auto}"
	[ "$FRPC_SLOT" != "auto" ] && { log info "Using FRPC_SLOT=${FRPC_SLOT}."; return 0; }
	[ -n "${SLOT_MANAGER_TOKEN:-}" ] || die "SLOT_MANAGER_TOKEN is required when FRPC_SLOT=auto."

	status="$(slot_api GET /status)"
	active="$(json_get active "$status")"
	blue="$(json_bool blueOccupied "$status")"
	green="$(json_bool greenOccupied "$status")"

	case "$active" in
		blue)
			if [ "$blue" = "true" ]; then FRPC_SLOT=green; else FRPC_SLOT=blue; fi
			;;
		green)
			if [ "$green" = "true" ]; then FRPC_SLOT=blue; else FRPC_SLOT=green; fi
			;;
		*) die "Invalid active slot from slot manager: ${status}" ;;
	esac

	log info "Selected slot ${FRPC_SLOT} (active=${active}, blueOccupied=${blue}, greenOccupied=${green})."
}

write_store_config() {
	mkdir -p /etc/stalwart
	cat > /etc/stalwart/config.json <<EOF
{
  "@type": "PostgreSql",
  "host": "${PGHOST}",
  "port": ${PGPORT},
  "database": "${PGDATABASE}",
  "authUsername": "${PGUSER}",
  "authSecret": {
    "@type": "EnvironmentVariable",
    "variableName": "PGPASSWORD"
  },
  "useTls": ${USE_TLS},
  "allowInvalidCerts": ${ALLOW_INVALID},
  "poolMaxConnections": 10,
  "poolRecyclingMethod": "fast"
}
EOF
}

write_frpc_config() {
	FRPC_CONFIG="${FRPC_CONFIG:-/tmp/frpc.toml}"
	case "$FRPC_SLOT" in
		blue)
			suffix=blue
			smtp=10025
			subs=10465
			subm=10587
			imaps=10993
			https=10443
			admin=18080
			;;
		green)
			suffix=green
			smtp=11025
			subs=11465
			subm=11587
			imaps=11993
			https=11443
			admin=19080
			;;
		*) die "FRPC_SLOT must be blue or green." ;;
	esac

	cat > "$FRPC_CONFIG" <<EOF
serverAddr = "${FRPS_ADDR}"
serverPort = ${FRPS_PORT:-7000}

[auth]
method = "token"
token = "${FRPC_TOKEN}"
EOF

	if [ "$RECOVERY_MODE" != "true" ]; then
		cat >> "$FRPC_CONFIG" <<EOF

[[proxies]]
name = "smtp-${suffix}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 25
remotePort = ${smtp}
transport.proxyProtocolVersion = "v2"

[[proxies]]
name = "submissions-${suffix}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 465
remotePort = ${subs}
transport.proxyProtocolVersion = "v2"

[[proxies]]
name = "imaps-${suffix}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 993
remotePort = ${imaps}
transport.proxyProtocolVersion = "v2"

[[proxies]]
name = "submission-${suffix}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 587
remotePort = ${subm}
transport.proxyProtocolVersion = "v2"
EOF
	fi

	cat >> "$FRPC_CONFIG" <<EOF

[[proxies]]
name = "https-${suffix}"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${HTTP_PORT}
remotePort = ${https}

[[proxies]]
name = "http-admin-${suffix}"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${HTTP_PORT}
remotePort = ${admin}
EOF
}

start_stalwart() {
	log info "Starting Stalwart (db=${PGHOST}:${PGPORT}/${PGDATABASE}, tls=${USE_TLS})."
	# Stalwart writes file logs under STALWART_LOG_DIR; also mirror stderr to Railway logs.
	/usr/local/bin/stalwart --config /etc/stalwart/config.json 2>&1 &
	STALWART_PID=$!
	log info "Stalwart pid=${STALWART_PID}."
}

start_frpc() {
	write_frpc_config
	: > "$FRPC_LOG_FILE"
	log info "Starting frpc -> ${FRPS_ADDR}:${FRPS_PORT:-7000} slot=${FRPC_SLOT}."
	/usr/local/bin/frpc -c "${FRPC_CONFIG:-/tmp/frpc.toml}" >>"$FRPC_LOG_FILE" 2>&1 &
	FRPC_PID=$!
	log info "frpc pid=${FRPC_PID}."
}

stalwart_http_up() {
	for url in \
		"http://127.0.0.1:${HTTP_PORT}/jmap/session" \
		"http://[::1]:${HTTP_PORT}/jmap/session"; do
		code="$(curl -sS -o /dev/null -w '%{http_code}' --http1.1 --connect-timeout 2 --max-time 5 \
			-H "Host: ${HTTP_HOST}" \
			"$url" 2>/dev/null || echo 000)"
		case "$code" in
			2*|401|403|404) return 0 ;;
		esac
	done
	return 1
}

activate_slot() {
	[ -n "${SLOT_MANAGER_TOKEN:-}" ] || { log warn "No SLOT_MANAGER_TOKEN; skip slot activation."; return 1; }
	resp="$(slot_api POST /activate "{\"slot\":\"${FRPC_SLOT}\"}")"
	active="$(json_get active "$resp")"
	[ "$active" = "$FRPC_SLOT" ] || { log warn "Slot activation failed: ${resp}"; return 1; }
	log info "Activated slot ${FRPC_SLOT}."
	return 0
}

update_relay_route() {
	[ -n "${STALWART_ADMIN_TOKEN:-}" ] || { log warn "No STALWART_ADMIN_TOKEN; skip relay update."; return 1; }

	addr="${RELAY_ROUTE_ADDRESS:-mailsend.solace.onl}"
	port="${RELAY_ROUTE_PORT:-587}"
	id="${RELAY_ROUTE_ID:-ivnbzc1aaba9}"

	log info "Updating relay route ${id} -> ${addr}:${port}."
	if out="$(/usr/local/bin/stalwart-cli \
		--url "http://127.0.0.1:${HTTP_PORT}" \
		--api-key "$STALWART_ADMIN_TOKEN" \
		update MtaRoute "$id" \
		--field "address=${addr}" \
		--field "port=${port}" 2>&1)"; then
		log info "Relay route updated."
		return 0
	fi
	log warn "Relay route update failed: ${out}"
	return 1
}

log_status() {
	stalwart_state="running"
	frpc_state="running"
	kill -0 "$STALWART_PID" 2>/dev/null || stalwart_state="stopped"
	kill -0 "$FRPC_PID" 2>/dev/null || frpc_state="stopped"
	http_state="down"
	stalwart_http_up && http_state="up"
	pg_state="unknown"
	if command -v pg_isready >/dev/null 2>&1; then
		pg_state="$(pg_isready -h "$PGHOST" -p "$PGPORT" -d "$PGDATABASE" -U "$PGUSER" 2>&1 | awk '{print $NF}')"
	fi
	ports=""
	if command -v ss >/dev/null 2>&1; then
		ports="$(ss -tlnH 2>/dev/null | awk '{print $4}' | tr '\n' ' ')"
	fi
	log info "status stalwart=${stalwart_state} frpc=${frpc_state} http=${http_state} pg=${pg_state} slot=${FRPC_SLOT} activated=${SLOT_DONE:-false} relay=${RELAY_DONE:-false}"
	log info "ports: ${ports:-unknown}"
	if [ -d "$STALWART_LOG_DIR" ]; then
		latest="$(ls -1t "$STALWART_LOG_DIR"/*.log 2>/dev/null | head -n 1 || true)"
		if [ -n "$latest" ]; then
			log info "stalwart log tail (${latest}):"
			tail -n 8 "$latest" >&2 || true
		fi
	fi
	if ! stalwart_http_up; then
		log warn "HTTP probe failed; last curl to http://127.0.0.1:${HTTP_PORT}/jmap/session with Host:${HTTP_HOST}"
	fi
}

# --- main ---

[ -n "$PGHOST" ] && [ -n "$PGUSER" ] && [ -n "$PGPASSWORD" ] || die "Missing PostgreSQL credentials."
[ -n "${FRPS_ADDR:-}" ] && [ -n "${FRPC_TOKEN:-}" ] || die "FRPS_ADDR and FRPC_TOKEN are required."

write_store_config
pick_slot
start_stalwart
sleep "${STALWART_BOOT_DELAY_SECONDS:-5}"
start_frpc

SLOT_DONE=false
RELAY_DONE=false
tick=0
STATUS_EVERY="${STATUS_LOG_INTERVAL_SECONDS:-30}"
log info "Supervisor running (status every ${STATUS_EVERY}s)."

while :; do
	if ! kill -0 "$STALWART_PID" 2>/dev/null; then
		wait "$STALWART_PID" 2>/dev/null || true
		die "Stalwart exited."
	fi
	if ! kill -0 "$FRPC_PID" 2>/dev/null; then
		log error "frpc exited."
		tail -n 20 "$FRPC_LOG_FILE" >&2 || true
		die "frpc exited."
	fi

	if stalwart_http_up; then
		if [ "$SLOT_DONE" != "true" ]; then
			if activate_slot; then SLOT_DONE=true; fi
		fi
		if [ "$RELAY_DONE" != "true" ]; then
			if update_relay_route; then RELAY_DONE=true; fi
		fi
	fi

	tick=$((tick + 1))
	if [ $((tick % STATUS_EVERY)) -eq 0 ]; then
		log_status
	fi
	sleep 1
done
