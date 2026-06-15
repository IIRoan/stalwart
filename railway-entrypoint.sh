#!/bin/sh
# Railway-native entrypoint: Stalwart + health listener + frpc.
set -eu

# The stalwart image user has no home dir; stalwart-cli needs a writable HOME.
export HOME="${HOME:-/tmp}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp}"

FRPC_LOG_FILE="${FRPC_LOG_FILE:-/tmp/frpc.log}"
FRPC_RELAY_LOG_FILE="${FRPC_RELAY_LOG_FILE:-/tmp/frpc-relay.log}"
FRPC_RELAY_STCP_KEY="${FRPC_RELAY_STCP_KEY:-relay-stcp-secret}"
FRPC_RELAY_LOCAL_PORT="${FRPC_RELAY_LOCAL_PORT:-2525}"
RELAY_ROUTE_ID="${RELAY_ROUTE_ID:-ivnbzc1aaba9}"
# Stalwart HTTP/JMAP listener (from DB config). frpc tunnels target this port.
STALWART_HTTP_PORT="${STALWART_HTTP_PORT:-8080}"
# Railway healthchecks probe PORT (set PORT=8090 in Railway variables).
HEALTH_PORT="${PORT:-8090}"
HEALTH_STATE_PATH="${HEALTH_STATE_PATH:-/tmp/railway-health.json}"

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

json_get_bool() {
	printf '%s\n' "$2" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\\(true\\|false\\).*/\\1/p"
}

fetch_slot_status() {
	if [ -n "${SLOT_MANAGER_TOKEN:-}" ]; then
		curl -fsS --connect-timeout 3 --max-time 5 \
			-H "Authorization: Bearer ${SLOT_MANAGER_TOKEN}" \
			"${SLOT_MANAGER_URL:-https://mail.solace.onl/slot-manager}/status" \
			2>/dev/null || true
		return 0
	fi

	curl -fsS --connect-timeout 3 --max-time 5 \
		"${SLOT_MANAGER_URL:-https://mail.solace.onl/slot-manager}/active" \
		2>/dev/null || true
}

slot_occupied() {
	slot="$1"
	status="$2"
	key="${slot}Occupied"
	value="$(json_get_bool "$key" "$status")"
	[ "$value" = "true" ]
}

wait_for_slot_vacant() {
	slot="$1"
	[ -n "${SLOT_MANAGER_TOKEN:-}" ] || return 0

	i=0
	max_wait="${SLOT_VACANT_TIMEOUT_SECONDS:-180}"
	while [ "$i" -lt "$max_wait" ]; do
		status="$(fetch_slot_status)"
		if [ -n "$status" ] && ! slot_occupied "$slot" "$status"; then
			log info "Slot ${slot} tunnel is vacant on VPS."
			return 0
		fi
		i=$((i + 1))
		sleep 2
	done

	log warn "Slot ${slot} still occupied after ${max_wait}s; starting frpc anyway."
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
	FRPC_PROXY_SUFFIX=""
	case "$FRPC_SLOT" in
		blue)
			suffix=blue
			FRPC_PROXY_SUFFIX=blue
			smtp=10025
			subs=10465
			subm=10587
			imaps=10993
			https=10443
			admin=18080
			;;
		green)
			suffix=green
			FRPC_PROXY_SUFFIX=green
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

write_health_state() {
	ready="${1:-false}"
	python3 - "$HEALTH_STATE_PATH" "$ready" <<'PY'
import json
import os
import sys

path, ready = sys.argv[1], sys.argv[2] == "true"
state = {
    "ready": ready,
    "recovery_mode": os.environ.get("RECOVERY_MODE") == "true",
    "stalwart_pid": int(os.environ.get("STALWART_PID", "0") or 0),
    "frpc_pid": int(os.environ.get("FRPC_PID", "0") or 0),
    "frpc_relay_pid": int(os.environ.get("FRPC_RELAY_PID", "0") or 0),
    "http_port": int(os.environ.get("STALWART_HTTP_PORT", "8080")),
    "relay_port": int(os.environ.get("FRPC_RELAY_LOCAL_PORT", "2525")),
    "frpc_log": os.environ.get("FRPC_LOG_FILE", "/tmp/frpc.log"),
    "required_proxies": [
        proxy for proxy in os.environ.get("FRPC_REQUIRED_PROXIES", "").split() if proxy
    ],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle)
PY
}

start_health_server() {
	log info "Starting Railway health listener on 0.0.0.0:${HEALTH_PORT}/healthz/ready."
	write_health_state false
	HEALTH_PORT="$HEALTH_PORT" HEALTH_STATE_PATH="$HEALTH_STATE_PATH" python3 -u <<'PY' &
import json
import os
import socket
import threading

port = int(os.environ["HEALTH_PORT"])
state_path = os.environ["HEALTH_STATE_PATH"]

OK = (
    b'HTTP/1.1 200 OK\r\n'
    b'Content-Type: application/json\r\n'
    b'Connection: close\r\n'
    b'Content-Length: 62\r\n\r\n'
    b'{"type":"about:blank","title":"OK","status":200,"detail":"OK"}'
)
UNAVAILABLE = (
    b'HTTP/1.1 503 Service Unavailable\r\n'
    b'Content-Type: application/json\r\n'
    b'Connection: close\r\n'
    b'Content-Length: 78\r\n\r\n'
    b'{"type":"about:blank","title":"Unavailable","status":503,"detail":"Not ready"}'
)


def load_state():
    try:
        with open(state_path, encoding="utf-8") as handle:
            return json.load(handle)
    except OSError:
        return {}
    except json.JSONDecodeError:
        return {}


def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
    except OSError:
        return False
    return True


def port_open(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.5)
        return sock.connect_ex(("127.0.0.1", int(port))) == 0


def frpc_proxies_ready(state):
    log_path = state.get("frpc_log")
    required = state.get("required_proxies") or []
    if not log_path or not required:
        return False
    try:
        with open(log_path, encoding="utf-8") as handle:
            content = handle.read()
    except OSError:
        return False
    for proxy in required:
        found = False
        for line in content.splitlines():
            if proxy in line and "start proxy success" in line:
                found = True
                break
        if not found:
            return False
    return True


def ready():
    state = load_state()
    if not state.get("ready"):
        return False
    for key in ("stalwart_pid", "frpc_pid", "frpc_relay_pid"):
        if not pid_alive(state.get(key)):
            return False
    for port in (25, state.get("http_port", 8080), state.get("relay_port", 2525)):
        if not port_open(port):
            return False
    if not state.get("recovery_mode") and not frpc_proxies_ready(state):
        return False
    return True


def handle(conn):
    try:
        conn.recv(4096)
        conn.sendall(OK if ready() else UNAVAILABLE)
    finally:
        conn.close()


sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("0.0.0.0", port))
sock.listen(32)
while True:
    client, _addr = sock.accept()
    threading.Thread(target=handle, args=(client,), daemon=True).start()
PY
	HEALTH_PID=$!

	i=0
	while [ "$i" -lt 20 ]; do
		if curl -fsS --max-time 1 "http://127.0.0.1:${HEALTH_PORT}/healthz/ready" >/dev/null 2>&1; then
			log warn "Health listener responded before readiness gate; expected 503."
		else
			log info "Health listener ready on :${HEALTH_PORT} (returns 503 until stack is up)."
			return 0
		fi
		i=$((i + 1))
		sleep 0.5
	done
	die "Health listener failed to respond on :${HEALTH_PORT}."
}

start_stalwart() {
	log info "Starting Stalwart (db=${PGHOST}:${PGPORT}/${PGDATABASE})."
	/usr/local/bin/stalwart --config /etc/stalwart/config.json 2>&1 &
	STALWART_PID=$!
	log info "Stalwart pid=${STALWART_PID}."
	wait_for_stalwart_ports
}

write_frpc_relay_config() {
	FRPC_RELAY_CONFIG="${FRPC_RELAY_CONFIG:-/tmp/frpc-relay.toml}"
	cat > "$FRPC_RELAY_CONFIG" <<EOF
serverAddr = "${FRPS_ADDR}"
serverPort = ${FRPS_PORT:-7000}

[auth]
method = "token"
token = "${FRPC_TOKEN}"

[[visitors]]
name = "relay-postfix-visitor"
type = "stcp"
serverName = "relay-postfix"
secretKey = "${FRPC_RELAY_STCP_KEY}"
bindAddr = "0.0.0.0"
bindPort = ${FRPC_RELAY_LOCAL_PORT}
EOF
}

detect_container_ip() {
	if [ -n "${RELAY_BIND_ADDR:-}" ]; then
		printf '%s\n' "$RELAY_BIND_ADDR"
		return 0
	fi

	for ip in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
		case "$ip" in
			10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*)
				printf '%s\n' "$ip"
				return 0
				;;
		esac
	done

	die "Could not detect container private IP for relay route."
}

wait_for_relay_port() {
	i=0
	while [ "$i" -lt 30 ]; do
		if port_listening "${FRPC_RELAY_LOCAL_PORT}"; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	die "Relay STCP visitor did not open :${FRPC_RELAY_LOCAL_PORT}."
}

stalwart_management_url() {
	# Stalwart HTTP on :8080 is reachable on the container private IP, not loopback.
	printf 'http://%s:%s\n' "$(detect_container_ip)" "${STALWART_HTTP_PORT}"
}

stalwart_api_ready() {
	stalwart_url="$(stalwart_management_url)"

	if curl -fsSL --max-time 2 \
		-H "Authorization: Bearer ${STALWART_ADMIN_TOKEN}" \
		"${stalwart_url}/jmap/session" >/dev/null 2>&1; then
		return 0
	fi

	stalwart-cli --url "$stalwart_url" --api-key "$STALWART_ADMIN_TOKEN" \
		get MtaRoute "$RELAY_ROUTE_ID" >/dev/null 2>&1
}

update_relay_route() {
	[ -n "${STALWART_ADMIN_TOKEN:-}" ] || {
		log warn "STALWART_ADMIN_TOKEN unset; skipping relay route update."
		return 0
	}

	relay_addr="$(detect_container_ip)"
	stalwart_url="$(stalwart_management_url)"

	i=0
	max_attempts="${RELAY_ROUTE_UPDATE_ATTEMPTS:-90}"
	err_log="/tmp/relay-route-update.err"
	while [ "$i" -lt "$max_attempts" ]; do
		if stalwart_api_ready \
			&& stalwart-cli --url "$stalwart_url" --api-key "$STALWART_ADMIN_TOKEN" \
				update MtaRoute "$RELAY_ROUTE_ID" \
				--field "address=${relay_addr}" \
				--field "port=${FRPC_RELAY_LOCAL_PORT}" \
				2>"$err_log"; then
			stalwart-cli --url "$stalwart_url" --api-key "$STALWART_ADMIN_TOKEN" \
				create Action/ReloadSettings >/dev/null 2>&1 || true
			log info "Relay route -> ${relay_addr}:${FRPC_RELAY_LOCAL_PORT} (id=${RELAY_ROUTE_ID}; via ${stalwart_url})."
			return 0
		fi
		i=$((i + 1))
		sleep 2
	done

	tail -n 3 "$err_log" >&2 || true
	log error "Could not update relay route to ${relay_addr}:${FRPC_RELAY_LOCAL_PORT} via ${stalwart_url}."
	return 1
}

wait_for_frpc_proxies() {
	[ "$RECOVERY_MODE" = "true" ] && return 0

	FRPC_REQUIRED_PROXIES="smtp-${FRPC_PROXY_SUFFIX} https-${FRPC_PROXY_SUFFIX}"
	export FRPC_REQUIRED_PROXIES

	i=0
	max_wait="${FRPC_READY_TIMEOUT_SECONDS:-120}"
	while [ "$i" -lt "$max_wait" ]; do
		ready=true
		for proxy in $FRPC_REQUIRED_PROXIES; do
			if ! grep -q "$proxy" "$FRPC_LOG_FILE" 2>/dev/null \
				|| ! grep "$proxy" "$FRPC_LOG_FILE" 2>/dev/null | grep -q "start proxy success"; then
				ready=false
				break
			fi
		done
		if [ "$ready" = "true" ]; then
			log info "frpc proxies online: ${FRPC_REQUIRED_PROXIES}."
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done

	tail -n 20 "$FRPC_LOG_FILE" >&2 || true
	die "frpc did not register required proxies within ${max_wait}s."
}

mark_health_ready() {
	export STALWART_PID FRPC_PID FRPC_RELAY_PID STALWART_HTTP_PORT FRPC_RELAY_LOCAL_PORT
	export FRPC_LOG_FILE FRPC_REQUIRED_PROXIES
	export RECOVERY_MODE="${RECOVERY_MODE}"
	write_health_state true
	log info "Railway health gate open (Stalwart + frpc + relay ready)."
}

activate_slot() {
	[ -n "${SLOT_MANAGER_TOKEN:-}" ] || {
		log warn "SLOT_MANAGER_TOKEN unset; VPS slot promotion relies on watcher failover."
		return 0
	}

	log info "Requesting VPS promotion for slot=${FRPC_SLOT} (before Railway health gate)."
	if curl -fsS --connect-timeout 5 --max-time 120 \
		-X POST "${SLOT_MANAGER_URL:-https://mail.solace.onl/slot-manager}/activate" \
		-H "Authorization: Bearer ${SLOT_MANAGER_TOKEN}" \
		-H "Content-Type: application/json" \
		-d "{\"slot\":\"${FRPC_SLOT}\"}" >/dev/null; then
		log info "VPS promoted slot=${FRPC_SLOT}."
		return 0
	fi

	die "VPS slot promotion failed; refusing to open Railway health gate."
}

start_frpc() {
	wait_for_slot_vacant "$FRPC_SLOT"
	write_frpc_config
	: > "$FRPC_LOG_FILE"
	log info "Starting frpc -> ${FRPS_ADDR}:${FRPS_PORT:-7000} slot=${FRPC_SLOT}."
	/usr/local/bin/frpc -c "${FRPC_CONFIG:-/tmp/frpc.toml}" >>"$FRPC_LOG_FILE" 2>&1 &
	FRPC_PID=$!
	log info "frpc pid=${FRPC_PID}."

	write_frpc_relay_config
	: > "$FRPC_RELAY_LOG_FILE"
	log info "Starting relay STCP visitor on 0.0.0.0:${FRPC_RELAY_LOCAL_PORT}."
	/usr/local/bin/frpc -c "${FRPC_RELAY_CONFIG:-/tmp/frpc-relay.toml}" >>"$FRPC_RELAY_LOG_FILE" 2>&1 &
	FRPC_RELAY_PID=$!
	log info "frpc relay visitor pid=${FRPC_RELAY_PID}."
	wait_for_relay_port
	wait_for_frpc_proxies
	update_relay_route || die "Relay route update failed; refusing to open health gate."
}

# --- main ---

[ -n "$PGHOST" ] && [ -n "$PGUSER" ] && [ -n "$PGPASSWORD" ] || die "Missing PostgreSQL credentials."
[ -n "${FRPS_ADDR:-}" ] && [ -n "${FRPC_TOKEN:-}" ] || die "FRPS_ADDR and FRPC_TOKEN are required."

write_store_config
resolve_slot
start_health_server
start_stalwart
sleep "${STALWART_BOOT_DELAY_SECONDS:-3}"
start_frpc
activate_slot
mark_health_ready

i=0
while [ "$i" -lt 30 ]; do
	if curl -fsS --max-time 1 "http://127.0.0.1:${HEALTH_PORT}/healthz/ready" >/dev/null 2>&1; then
		break
	fi
	i=$((i + 1))
	sleep 1
done
[ "$i" -lt 30 ] || die "Health gate did not return 200 after readiness."

log info "Running (Railway health :${HEALTH_PORT}/healthz/ready; slot=${FRPC_SLOT}; Stalwart :${STALWART_HTTP_PORT})."

while :; do
	if ! kill -0 "$STALWART_PID" 2>/dev/null; then
		write_health_state false
		wait "$STALWART_PID" 2>/dev/null || true
		die "Stalwart exited."
	fi
	if ! kill -0 "$HEALTH_PID" 2>/dev/null; then
		die "Health listener exited."
	fi
	if ! kill -0 "$FRPC_PID" 2>/dev/null; then
		write_health_state false
		tail -n 20 "$FRPC_LOG_FILE" >&2 || true
		die "frpc exited."
	fi
	if ! kill -0 "$FRPC_RELAY_PID" 2>/dev/null; then
		write_health_state false
		tail -n 20 "$FRPC_RELAY_LOG_FILE" >&2 || true
		die "frpc relay visitor exited."
	fi
	sleep 5
done
