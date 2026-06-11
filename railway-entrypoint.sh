#!/bin/sh
set -eu

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
RECOVERY_MODE_ACTIVE=false

case "$PGHOST" in
	*.proxy.rlwy.net|*.rlwy.net)
		USE_TLS=true
		ALLOW_INVALID=true
		;;
	*.railway.internal)
		USE_TLS=false
		ALLOW_INVALID=false
		;;
esac

case "${DATABASE_URL:-}${DATABASE_PUBLIC_URL:-}" in
	*sslmode=require*|*sslmode=verify*)
		USE_TLS=true
		ALLOW_INVALID=true
		;;
esac

case "${STALWART_RECOVERY_MODE:-}" in
	1|true|TRUE|yes|YES)
		RECOVERY_MODE_ACTIVE=true
		;;
esac

timestamp() {
	date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
	level="$1"
	shift
	printf '%s [%s] %s\n' "$(timestamp)" "$level" "$*" >&2
}

cleanup() {
	if [ -n "${FRPC_PID:-}" ] && kill -0 "$FRPC_PID" 2>/dev/null; then
		kill "$FRPC_PID" 2>/dev/null || true
	fi
	if [ -n "${STALWART_PID:-}" ] && kill -0 "$STALWART_PID" 2>/dev/null; then
		kill "$STALWART_PID" 2>/dev/null || true
	fi
}

trap cleanup EXIT INT TERM

if [ -z "$PGHOST" ] || [ -z "$PGUSER" ] || [ -z "$PGPASSWORD" ]; then
	log error "Missing PostgreSQL credentials."
	exit 1
fi

if [ -z "${FRPS_ADDR:-}" ] || [ -z "${FRPC_TOKEN:-}" ]; then
	log error "FRPS_ADDR and FRPC_TOKEN are required."
	exit 1
fi

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

build_frpc_config() {
	FRPS_PORT="${FRPS_PORT:-7000}"
	FRPC_CONFIG="${FRPC_CONFIG:-/tmp/frpc.toml}"
	FRPC_ENABLE_SUBMISSION_PROXY="${FRPC_ENABLE_SUBMISSION_PROXY:-false}"

	cat > "$FRPC_CONFIG" <<EOF
serverAddr = "${FRPS_ADDR}"
serverPort = ${FRPS_PORT}

[auth]
method = "token"
token = "${FRPC_TOKEN}"
EOF

	if [ "$RECOVERY_MODE_ACTIVE" != "true" ]; then
		cat >> "$FRPC_CONFIG" <<EOF

[[proxies]]
name = "smtp"
type = "tcp"
localIP = "127.0.0.1"
localPort = 25
remotePort = 10025

[[proxies]]
name = "submissions"
type = "tcp"
localIP = "127.0.0.1"
localPort = 465
remotePort = 10465

[[proxies]]
name = "imaps"
type = "tcp"
localIP = "127.0.0.1"
localPort = 993
remotePort = 10993
EOF

		if [ "$FRPC_ENABLE_SUBMISSION_PROXY" = "true" ]; then
			cat >> "$FRPC_CONFIG" <<EOF

[[proxies]]
name = "submission"
type = "tcp"
localIP = "127.0.0.1"
localPort = 587
remotePort = 10587
EOF
		fi
	else
		log info "Recovery mode enabled, exposing only admin/JMAP HTTP."
	fi

	cat >> "$FRPC_CONFIG" <<EOF

[[proxies]]
name = "https"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8080
remotePort = 10443

[[proxies]]
name = "http-admin"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8080
remotePort = 18080
EOF
}

start_stalwart() {
	log info "Starting Stalwart."
	log info "Database target: host=${PGHOST} port=${PGPORT} database=${PGDATABASE} tls=${USE_TLS} allowInvalidCerts=${ALLOW_INVALID}."
	log info "Recovery mode active: ${RECOVERY_MODE_ACTIVE}."
	/usr/local/bin/stalwart --config /etc/stalwart/config.json &
	STALWART_PID=$!
	log info "Started stalwart with pid ${STALWART_PID}."
}

start_frpc() {
	build_frpc_config
	log info "Starting frpc tunnel to ${FRPS_ADDR}:${FRPS_PORT:-7000}."
	/usr/local/bin/frpc -c "${FRPC_CONFIG:-/tmp/frpc.toml}" &
	FRPC_PID=$!
	log info "Started frpc with pid ${FRPC_PID}."
}

verify_startup() {
	STARTUP_GRACE_SECONDS="${STARTUP_GRACE_SECONDS:-20}"
	FRPC_START_DELAY_SECONDS="${FRPC_START_DELAY_SECONDS:-2}"

	sleep "$FRPC_START_DELAY_SECONDS"
	if ! kill -0 "$STALWART_PID" 2>/dev/null; then
		log error "Stalwart exited during startup."
		wait "$STALWART_PID" || true
		exit 1
	fi

	start_frpc
	sleep "$STARTUP_GRACE_SECONDS"

	if ! kill -0 "$STALWART_PID" 2>/dev/null; then
		log error "Stalwart exited within startup grace period."
		wait "$STALWART_PID" || true
		exit 1
	fi

	if ! kill -0 "$FRPC_PID" 2>/dev/null; then
		log error "frpc exited within startup grace period."
		wait "$FRPC_PID" || true
		exit 1
	fi

	log info "Startup grace period passed."
}

monitor_processes() {
	while :; do
		if ! kill -0 "$STALWART_PID" 2>/dev/null; then
			wait "$STALWART_PID"
			exit $?
		fi
		if ! kill -0 "$FRPC_PID" 2>/dev/null; then
			log error "frpc exited after startup."
			wait "$FRPC_PID" || true
			kill "$STALWART_PID" 2>/dev/null || true
			wait "$STALWART_PID" || true
			exit 1
		fi
		sleep 2
	done
}

start_stalwart
verify_startup
monitor_processes
