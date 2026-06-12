#!/bin/sh
# Railway-native entrypoint: Stalwart + health listener + frpc.
set -eu

FRPC_LOG_FILE="${FRPC_LOG_FILE:-/tmp/frpc.log}"
# Stalwart HTTP/JMAP listener (from DB config). frpc tunnels target this port.
STALWART_HTTP_PORT="${STALWART_HTTP_PORT:-8080}"
# Railway healthchecks probe PORT (set PORT=8090 in Railway variables).
HEALTH_PORT="${PORT:-8090}"

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

resolve_slot() {
	FRPC_SLOT="${FRPC_SLOT:-auto}"

	if [ "$FRPC_SLOT" != "auto" ]; then
		log info "FRPC_SLOT=${FRPC_SLOT} (from environment)."
		return 0
	fi

	active="$(curl -fsS --connect-timeout 3 --max-time 5 \
		"${SLOT_MANAGER_URL:-https://mail.solace.onl/slot-manager}/active" \
		2>/dev/null || true)"
	current="$(json_get active "$active")"

	case "$current" in
		blue) FRPC_SLOT=green ;;
		green) FRPC_SLOT=blue ;;
		*)
			FRPC_SLOT=blue
			log warn "Could not read active slot; defaulting to blue."
			return 0
			;;
	esac

	log info "FRPC_SLOT=${FRPC_SLOT} (inactive side of active=${current})."
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
localPort = ${STALWART_HTTP_PORT}
remotePort = ${https}

[[proxies]]
name = "http-admin-${suffix}"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${STALWART_HTTP_PORT}
remotePort = ${admin}
EOF
}

port_listening() {
	ss -tln 2>/dev/null | grep -q ":$1 "
}

wait_for_stalwart_ports() {
	i=0
	max_wait="${STALWART_READY_TIMEOUT_SECONDS:-180}"
	while [ "$i" -lt "$max_wait" ]; do
		if port_listening 25 && port_listening "${STALWART_HTTP_PORT}"; then
			log info "Stalwart listening on :25 and :${STALWART_HTTP_PORT}."
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	die "Stalwart did not open mail/http ports within ${max_wait}s."
}

start_health_server() {
	log info "Starting Railway health listener on :${HEALTH_PORT}/healthz/ready."
	while true; do
		socat "TCP-LISTEN:${HEALTH_PORT},bind=[::],reuseaddr,fork" \
			"OPEN:/etc/stalwart/railway-health.http" 2>/dev/null || sleep 1
	done &
	HEALTH_PID=$!
}

start_stalwart() {
	log info "Starting Stalwart (db=${PGHOST}:${PGPORT}/${PGDATABASE})."
	/usr/local/bin/stalwart --config /etc/stalwart/config.json 2>&1 &
	STALWART_PID=$!
	log info "Stalwart pid=${STALWART_PID}."
	wait_for_stalwart_ports
}

start_frpc() {
	write_frpc_config
	: > "$FRPC_LOG_FILE"
	log info "Starting frpc -> ${FRPS_ADDR}:${FRPS_PORT:-7000} slot=${FRPC_SLOT}."
	/usr/local/bin/frpc -c "${FRPC_CONFIG:-/tmp/frpc.toml}" >>"$FRPC_LOG_FILE" 2>&1 &
	FRPC_PID=$!
	log info "frpc pid=${FRPC_PID}."
}

# --- main ---

[ -n "$PGHOST" ] && [ -n "$PGUSER" ] && [ -n "$PGPASSWORD" ] || die "Missing PostgreSQL credentials."
[ -n "${FRPS_ADDR:-}" ] && [ -n "${FRPC_TOKEN:-}" ] || die "FRPS_ADDR and FRPC_TOKEN are required."

write_store_config
resolve_slot
start_stalwart
start_health_server
sleep "${STALWART_BOOT_DELAY_SECONDS:-3}"
start_frpc

log info "Running (Railway health :${HEALTH_PORT}/healthz/ready; Stalwart :${STALWART_HTTP_PORT}; VPS promotes slot)."

while :; do
	if ! kill -0 "$STALWART_PID" 2>/dev/null; then
		wait "$STALWART_PID" 2>/dev/null || true
		die "Stalwart exited."
	fi
	if ! kill -0 "$HEALTH_PID" 2>/dev/null; then
		die "Health listener exited."
	fi
	if ! kill -0 "$FRPC_PID" 2>/dev/null; then
		tail -n 20 "$FRPC_LOG_FILE" >&2 || true
		die "frpc exited."
	fi
	sleep 5
done
