#!/bin/sh
set -eu

# Build Stalwart config.json from Railway PostgreSQL variables.
# Link your PostgreSQL service in Railway so PGHOST, PGPORT, PGDATABASE,
# PGUSER, and PGPASSWORD are injected automatically.

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

if [ -z "$PGHOST" ] || [ -z "$PGUSER" ] || [ -z "$PGPASSWORD" ]; then
	echo "error: missing PostgreSQL credentials." >&2
	echo "In Railway, open your Stalwart service -> Variables -> add references from your PostgreSQL service (PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD)." >&2
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

timestamp() {
	date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
	level="$1"
	shift
	printf '%s [%s] %s\n' "$(timestamp)" "$level" "$*" >&2
}

STARTUP_COMPLETE=false
SHUTDOWN_REQUESTED=false

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		log error "Required command not found: $1"
		exit 1
	fi
}

handle_signal() {
	SHUTDOWN_REQUESTED=true
}

cleanup() {
	status=$?

	if [ "$status" -ne 0 ]; then
		if [ "$SHUTDOWN_REQUESTED" = "true" ]; then
			log info "Shutdown signal received."
		elif [ "$STARTUP_COMPLETE" = "true" ]; then
			log error "Container exited after startup with exit code $status."
		else
			log error "Container startup failed with exit code $status."
		fi
		if [ "$SHUTDOWN_REQUESTED" != "true" ]; then
			if [ -n "${STALWART_LOG_FILE:-}" ] && [ -f "$STALWART_LOG_FILE" ]; then
				log error "Last Stalwart log lines:"
				tail -n 40 "$STALWART_LOG_FILE" >&2 || true
			fi
			if [ -n "${FRPC_LOG_FILE:-}" ] && [ -f "$FRPC_LOG_FILE" ]; then
				log error "Last frpc log lines:"
				tail -n 40 "$FRPC_LOG_FILE" >&2 || true
			fi
		fi
	fi

	if [ -n "${STALWART_LOGGER_PID:-}" ] && kill -0 "$STALWART_LOGGER_PID" 2>/dev/null; then
		kill "$STALWART_LOGGER_PID" 2>/dev/null || true
	fi
	if [ -n "${FRPC_LOGGER_PID:-}" ] && kill -0 "$FRPC_LOGGER_PID" 2>/dev/null; then
		kill "$FRPC_LOGGER_PID" 2>/dev/null || true
	fi
	if [ -n "${FRPC_PID:-}" ] && kill -0 "$FRPC_PID" 2>/dev/null; then
		kill "$FRPC_PID" 2>/dev/null || true
	fi
	if [ -n "${STALWART_PID:-}" ] && kill -0 "$STALWART_PID" 2>/dev/null; then
		kill "$STALWART_PID" 2>/dev/null || true
	fi
}

trap handle_signal INT TERM
trap cleanup EXIT

dump_stalwart_diagnostics() {
	log error "Stalwart diagnostics begin."

	if [ -n "${STALWART_PID:-}" ]; then
		log error "Process status for pid ${STALWART_PID}:"
		ps -p "$STALWART_PID" -o pid=,ppid=,stat=,etime=,cmd= >&2 || true
	fi

	log error "Listening sockets on port 8080:"
	ss -lntp 2>/dev/null | grep ':8080' >&2 || netstat -lntp 2>/dev/null | grep ':8080' >&2 || true

	if nc -z 127.0.0.1 8080 >/dev/null 2>&1; then
		log error "TCP connect to 127.0.0.1:8080 succeeded."
	else
		log error "TCP connect to 127.0.0.1:8080 failed."
	fi

	log error "HTTP probe to ${STALWART_HEALTHCHECK_URL}:"
	curl -sS -i --max-time 2 "$STALWART_HEALTHCHECK_URL" >&2 || true

	log error "HTTP probe to http://127.0.0.1:8080/:"
	curl -sS -i --max-time 2 http://127.0.0.1:8080/ >&2 || true

	log error "Stalwart diagnostics end."
}

wait_for_http_ready() {
	name="$1"
	url="$2"
	timeout="$3"
	pid="$4"
	elapsed=0

	while [ "$elapsed" -lt "$timeout" ]; do
		if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
			log info "$name is ready."
			return 0
		fi
		if ! kill -0 "$pid" 2>/dev/null; then
			log error "$name exited before becoming ready."
			return 1
		fi
		elapsed=$((elapsed + 1))
		sleep 1
	done

	log error "$name did not become ready within ${timeout}s."
	dump_stalwart_diagnostics
	return 1
}

wait_for_frpc_ready() {
	timeout="$1"
	elapsed=0

	while [ "$elapsed" -lt "$timeout" ]; do
		if ! kill -0 "$FRPC_PID" 2>/dev/null; then
			log error "frpc exited before becoming ready."
			return 1
		fi
		if grep -q "login to server success" "$FRPC_LOG_FILE" 2>/dev/null && \
			(grep -q "proxy added:" "$FRPC_LOG_FILE" 2>/dev/null || grep -q "start proxy success" "$FRPC_LOG_FILE" 2>/dev/null); then
			log info "frpc connected to FRPS and registered proxies."
			return 0
		fi
		elapsed=$((elapsed + 1))
		sleep 1
	done

	log error "frpc did not report a successful FRPS login within ${timeout}s."
	return 1
}

start_logged_process() {
	name="$1"
	log_file="$2"
	pipe_file="$3"
	shift 3

	rm -f "$pipe_file"
	: > "$log_file"
	mkfifo "$pipe_file"
	tee -a "$log_file" < "$pipe_file" >&2 &
	logger_pid=$!
	"$@" > "$pipe_file" 2>&1 &
	process_pid=$!
	rm -f "$pipe_file"

	if [ "$name" = "stalwart" ]; then
		STALWART_LOG_FILE="$log_file"
		STALWART_LOGGER_PID="$logger_pid"
		STALWART_PID="$process_pid"
	else
		FRPC_LOG_FILE="$log_file"
		FRPC_LOGGER_PID="$logger_pid"
		FRPC_PID="$process_pid"
	fi

	log info "Started $name with pid $process_pid."
}

start_frpc() {
	if [ -z "${FRPS_ADDR:-}" ]; then
		log error "FRPS_ADDR is not set. frpc is required for this deployment."
		exit 1
	fi

	if [ -z "${FRPC_TOKEN:-}" ]; then
		log error "FRPC_TOKEN is required when FRPS_ADDR is set."
		exit 1
	fi

	require_command frpc

	FRPS_PORT="${FRPS_PORT:-7000}"
	FRPC_CONFIG="${FRPC_CONFIG:-/tmp/frpc.toml}"
	FRPC_ENABLE_SUBMISSION_PROXY="${FRPC_ENABLE_SUBMISSION_PROXY:-false}"
	FRPC_READY_TIMEOUT="${FRPC_READY_TIMEOUT:-20}"

	log info "Preparing frpc config for ${FRPS_ADDR}:${FRPS_PORT}."
	log info "Submission proxy enabled: ${FRPC_ENABLE_SUBMISSION_PROXY}."

	cat > "$FRPC_CONFIG" <<EOF
serverAddr = "${FRPS_ADDR}"
serverPort = ${FRPS_PORT}

[auth]
method = "token"
token = "${FRPC_TOKEN}"

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
	else
		log info "Skipping submission proxy on port 587."
	fi

	cat >> "$FRPC_CONFIG" <<EOF

[[proxies]]
name = "imaps"
type = "tcp"
localIP = "127.0.0.1"
localPort = 993
remotePort = 10993

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

	log info "Starting frpc tunnel to ${FRPS_ADDR}:${FRPS_PORT}."
	start_logged_process "frpc" "${FRPC_LOG_FILE:-/tmp/frpc.log}" "${FRPC_PIPE_FILE:-/tmp/frpc.pipe}" /usr/local/bin/frpc -c "$FRPC_CONFIG"
	wait_for_frpc_ready "$FRPC_READY_TIMEOUT"
}

start_stalwart() {
	require_command curl
	require_command stalwart

	STALWART_READY_TIMEOUT="${STALWART_READY_TIMEOUT:-20}"
	STALWART_HEALTHCHECK_URL="${STALWART_HEALTHCHECK_URL:-http://127.0.0.1:8080/healthz/live}"

	log info "Starting Stalwart."
	log info "Database target: host=${PGHOST} port=${PGPORT} database=${PGDATABASE} tls=${USE_TLS} allowInvalidCerts=${ALLOW_INVALID}."
	start_logged_process "stalwart" "${STALWART_LOG_FILE:-/tmp/stalwart.log}" "${STALWART_PIPE_FILE:-/tmp/stalwart.pipe}" /usr/local/bin/stalwart --config /etc/stalwart/config.json
	wait_for_http_ready "Stalwart management listener" "$STALWART_HEALTHCHECK_URL" "$STALWART_READY_TIMEOUT" "$STALWART_PID"
}

start_stalwart
start_frpc

STARTUP_COMPLETE=true
log info "Startup checks passed. Waiting on Stalwart process."
wait "$STALWART_PID"
