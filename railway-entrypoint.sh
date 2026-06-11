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

extract_json_value() {
	key="$1"
	input="$2"
	printf '%s\n' "$input" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}

extract_json_bool() {
	key="$1"
	input="$2"
	printf '%s\n' "$input" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\\(true\\|false\\).*/\\1/p"
}

slot_manager_request() {
	method="$1"
	path="$2"
	body="${3:-}"

	SLOT_MANAGER_URL="${SLOT_MANAGER_URL:-https://mail.solace.onl/slot-manager}"
	SLOT_MANAGER_CONNECT_TIMEOUT="${SLOT_MANAGER_CONNECT_TIMEOUT:-5}"
	SLOT_MANAGER_MAX_TIME="${SLOT_MANAGER_MAX_TIME:-60}"
	SLOT_MANAGER_RETRIES="${SLOT_MANAGER_RETRIES:-6}"

	attempt=1
	while [ "$attempt" -le "$SLOT_MANAGER_RETRIES" ]; do
		log info "Slot manager ${method} ${path}, attempt ${attempt}/${SLOT_MANAGER_RETRIES} via ${SLOT_MANAGER_URL}."

		if [ "$method" = "GET" ]; then
			if response="$(curl -fsS \
				--connect-timeout "$SLOT_MANAGER_CONNECT_TIMEOUT" \
				--max-time "$SLOT_MANAGER_MAX_TIME" \
				-H "Authorization: Bearer ${SLOT_MANAGER_TOKEN}" \
				"${SLOT_MANAGER_URL}${path}" 2>&1)"; then
				printf '%s\n' "$response"
				return 0
			fi
		else
			if response="$(curl -fsS -X "$method" \
				--connect-timeout "$SLOT_MANAGER_CONNECT_TIMEOUT" \
				--max-time "$SLOT_MANAGER_MAX_TIME" \
				-H "Authorization: Bearer ${SLOT_MANAGER_TOKEN}" \
				-H "Content-Type: application/json" \
				-d "$body" \
				"${SLOT_MANAGER_URL}${path}" 2>&1)"; then
				printf '%s\n' "$response"
				return 0
			fi
		fi

		log error "Slot manager request failed: ${response}"
		attempt=$((attempt + 1))
		if [ "$attempt" -le "$SLOT_MANAGER_RETRIES" ]; then
			sleep 2
		fi
	done

	log error "Slot manager remained unreachable after ${SLOT_MANAGER_RETRIES} attempts."
	return 1
}

determine_frpc_slot() {
	FRPC_SLOT="${FRPC_SLOT:-auto}"
	SLOT_OCCUPANCY_TIMEOUT="${SLOT_OCCUPANCY_TIMEOUT:-600}"
	SLOT_OCCUPANCY_POLL_SECONDS="${SLOT_OCCUPANCY_POLL_SECONDS:-5}"

	if [ "$FRPC_SLOT" != "auto" ]; then
		log info "Using explicitly configured slot ${FRPC_SLOT}."
		return 0
	fi

	if [ -z "${SLOT_MANAGER_TOKEN:-}" ]; then
		log error "SLOT_MANAGER_TOKEN is required when FRPC_SLOT=auto."
		exit 1
	fi

	response="$(slot_manager_request GET /status)"
	active_slot="$(extract_json_value active "$response")"
	blue_occupied="$(extract_json_bool blueOccupied "$response")"
	green_occupied="$(extract_json_bool greenOccupied "$response")"

	case "$active_slot" in
		blue)
			if [ "$blue_occupied" = "true" ]; then
				FRPC_SLOT="green"
				slot_occupied="$green_occupied"
			else
				FRPC_SLOT="blue"
				slot_occupied="$blue_occupied"
			fi
			;;
		green)
			if [ "$green_occupied" = "true" ]; then
				FRPC_SLOT="blue"
				slot_occupied="$blue_occupied"
			else
				FRPC_SLOT="green"
				slot_occupied="$green_occupied"
			fi
			;;
		*)
			log error "Slot manager returned invalid active slot: ${response}"
			exit 1
			;;
	esac

	log info "Auto-selected slot ${FRPC_SLOT} while active slot is ${active_slot} (blueOccupied=${blue_occupied:-unknown}, greenOccupied=${green_occupied:-unknown})."

	elapsed=0
	while [ "$slot_occupied" = "true" ]; do
		if [ "$elapsed" -ge "$SLOT_OCCUPANCY_TIMEOUT" ]; then
			log error "Slot ${FRPC_SLOT} remained occupied for ${SLOT_OCCUPANCY_TIMEOUT}s."
			exit 1
		fi

		log info "Slot ${FRPC_SLOT} is still occupied, waiting ${SLOT_OCCUPANCY_POLL_SECONDS}s before retrying."
		sleep "$SLOT_OCCUPANCY_POLL_SECONDS"
		elapsed=$((elapsed + SLOT_OCCUPANCY_POLL_SECONDS))

		response="$(slot_manager_request GET /status)"
		case "$FRPC_SLOT" in
			blue)
				slot_occupied="$(extract_json_bool blueOccupied "$response")"
				;;
			green)
				slot_occupied="$(extract_json_bool greenOccupied "$response")"
				;;
		esac
	done
}

activate_frpc_slot() {
	if [ -z "${SLOT_MANAGER_TOKEN:-}" ]; then
		log error "SLOT_MANAGER_TOKEN is required to activate slot ${FRPC_SLOT}."
		exit 1
	fi

	response="$(slot_manager_request POST /activate "{\"slot\":\"${FRPC_SLOT}\"}")"

	active_slot="$(extract_json_value active "$response")"
	if [ "$active_slot" != "$FRPC_SLOT" ]; then
		log error "Slot manager failed to activate ${FRPC_SLOT}: ${response}"
		exit 1
	fi

	log info "Activated slot ${FRPC_SLOT}."
}

cleanup() {
	printf "%s [error] Entrypoint exiting at line %d (exit code %d).\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${LINENO:-0}" "${?:-0}" >&2 || true
	if [ -n "${FRPC_PID:-}" ] && kill -0 "$FRPC_PID" 2>/dev/null; then
		kill "$FRPC_PID" 2>/dev/null || true
	fi
	if [ -n "${FRPC_RELAY_PID:-}" ] && kill -0 "$FRPC_RELAY_PID" 2>/dev/null; then
		kill "$FRPC_RELAY_PID" 2>/dev/null || true
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
	FRPC_LOG_FILE="${FRPC_LOG_FILE:-/tmp/frpc.log}"

	case "$FRPC_SLOT" in
		blue)
			FRPC_PROXY_SUFFIX="blue"
			FRPC_SMTP_REMOTE_PORT=10025
			FRPC_SUBMISSIONS_REMOTE_PORT=10465
			FRPC_SUBMISSION_REMOTE_PORT=10587
			FRPC_IMAPS_REMOTE_PORT=10993
			FRPC_HTTPS_REMOTE_PORT=10443
			FRPC_HTTP_ADMIN_REMOTE_PORT=18080
			;;
		green)
			FRPC_PROXY_SUFFIX="green"
			FRPC_SMTP_REMOTE_PORT=11025
			FRPC_SUBMISSIONS_REMOTE_PORT=11465
			FRPC_SUBMISSION_REMOTE_PORT=11587
			FRPC_IMAPS_REMOTE_PORT=11993
			FRPC_HTTPS_REMOTE_PORT=11443
			FRPC_HTTP_ADMIN_REMOTE_PORT=19080
			;;
		*)
			log error "FRPC_SLOT must be blue or green, got: ${FRPC_SLOT}"
			exit 1
			;;
	esac

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
name = "smtp-${FRPC_PROXY_SUFFIX}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 25
remotePort = ${FRPC_SMTP_REMOTE_PORT}
EOF

		if [ "${FRPC_ENABLE_SMTPS_PROXY:-false}" = "true" ]; then
			cat >> "$FRPC_CONFIG" <<EOF

[[proxies]]
name = "submissions-${FRPC_PROXY_SUFFIX}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 465
remotePort = ${FRPC_SUBMISSIONS_REMOTE_PORT}
EOF
		else
			log info "Skipping SMTPS proxy on port 465."
		fi

		if [ "${FRPC_ENABLE_IMAPS_PROXY:-false}" = "true" ]; then
			cat >> "$FRPC_CONFIG" <<EOF

[[proxies]]
name = "imaps-${FRPC_PROXY_SUFFIX}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 993
remotePort = ${FRPC_IMAPS_REMOTE_PORT}
EOF
		else
			log info "Skipping IMAPS proxy on port 993."
		fi

		if [ "$FRPC_ENABLE_SUBMISSION_PROXY" = "true" ]; then
			cat >> "$FRPC_CONFIG" <<EOF

[[proxies]]
name = "submission-${FRPC_PROXY_SUFFIX}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 587
remotePort = ${FRPC_SUBMISSION_REMOTE_PORT}
EOF
		fi
	else
		log info "Recovery mode enabled, exposing only admin/JMAP HTTP."
	fi

	cat >> "$FRPC_CONFIG" <<EOF

[[proxies]]
name = "https-${FRPC_PROXY_SUFFIX}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8080
remotePort = ${FRPC_HTTPS_REMOTE_PORT}

[[proxies]]
name = "http-admin-${FRPC_PROXY_SUFFIX}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8080
remotePort = ${FRPC_HTTP_ADMIN_REMOTE_PORT}
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

wait_for_frpc_ready() {
	FRPC_READY_TIMEOUT="${FRPC_READY_TIMEOUT:-60}"
	required_proxies="smtp-${FRPC_PROXY_SUFFIX} https-${FRPC_PROXY_SUFFIX} http-admin-${FRPC_PROXY_SUFFIX}"

	if [ "$RECOVERY_MODE_ACTIVE" = "true" ]; then
		required_proxies="https-${FRPC_PROXY_SUFFIX} http-admin-${FRPC_PROXY_SUFFIX}"
	fi

	elapsed=0
	while [ "$elapsed" -lt "$FRPC_READY_TIMEOUT" ]; do
		if ! kill -0 "$FRPC_PID" 2>/dev/null; then
			log error "frpc exited before becoming ready."
			wait "$FRPC_PID" || true
			return 1
		fi

		if grep -q "login to server success" "$FRPC_LOG_FILE" 2>/dev/null; then
			all_ready=true
			for proxy in $required_proxies; do
				if ! grep -q "\\[$proxy\\] start proxy success" "$FRPC_LOG_FILE" 2>/dev/null; then
					all_ready=false
					break
				fi
			done
			if [ "$all_ready" = "true" ]; then
				log info "frpc connected and all required proxies are active."
				return 0
			fi
		fi

		elapsed=$((elapsed + 1))
		sleep 1
	done

	log error "frpc did not activate all required proxies within ${FRPC_READY_TIMEOUT}s."
	tail -n 40 "$FRPC_LOG_FILE" >&2 || true
	return 1
}

start_frpc() {
	build_frpc_config
	log info "Starting frpc tunnel to ${FRPS_ADDR}:${FRPS_PORT:-7000} for slot ${FRPC_PROXY_SUFFIX}."
	: > "$FRPC_LOG_FILE"
	/usr/local/bin/frpc -c "${FRPC_CONFIG:-/tmp/frpc.toml}" >> "$FRPC_LOG_FILE" 2>&1 &
	FRPC_PID=$!
	log info "Started frpc with pid ${FRPC_PID}."

	# Start a separate frpc process for the STCP visitor (outbound relay tunnel)
	# This ensures the visitor works even if the main frpc config has issues.
	# Bind on 0.0.0.0 so Stalwart can connect via the container's non-loopback IP.
	FRPC_RELAY_STCP_KEY="${FRPC_RELAY_STCP_KEY:-relay-stcp-secret}"
	FRPC_RELAY_LOCAL_PORT="${FRPC_RELAY_LOCAL_PORT:-12587}"
	FRPC_RELAY_CONFIG="/tmp/frpc-relay-visitor.toml"

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

	log info "Starting frpc relay visitor to ${FRPS_ADDR}:${FRPS_PORT:-7000} on 0.0.0.0:${FRPC_RELAY_LOCAL_PORT}."
	/usr/local/bin/frpc -c "$FRPC_RELAY_CONFIG" >> /tmp/frpc-relay-visitor.log 2>&1 &
	FRPC_RELAY_PID=$!
	log info "Started frpc relay visitor with pid ${FRPC_RELAY_PID}."
}

update_relay_route() {
	# Stalwart rejects loopback addresses for relay. Detect the container's
	# own non-loopback IP and update the relay route via the management API.
	CONTAINER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
	if [ -z "$CONTAINER_IP" ]; then
		CONTAINER_IP="$(ip route get 1 2>/dev/null | awk '{print $7; exit}')"
	fi
	if [ -z "$CONTAINER_IP" ]; then
		log warn "Could not detect container IP; relay route not updated."
		return 0
	fi

	FRPC_RELAY_LOCAL_PORT="${FRPC_RELAY_LOCAL_PORT:-12587}"
	STALWART_ADMIN_PORT="${STALWART_ADMIN_PORT:-8080}"
	RELAY_ROUTE_ID="${RELAY_ROUTE_ID:-ivnbzc1aaba9}"
	STALWART_ADMIN_TOKEN="${STALWART_ADMIN_TOKEN:-${STALWART_TOKEN}}"

	log info "Detected container IP: ${CONTAINER_IP}. Updating relay route ${RELAY_ROUTE_ID} to ${CONTAINER_IP}:${FRPC_RELAY_LOCAL_PORT}."

	# Use Stalwart management API to update the relay route address
	for attempt in 1 2 3 4 5; do
		if response="$(curl -fsS -X PATCH \
			-H "Authorization: Bearer ${STALWART_ADMIN_TOKEN}" \
			-H "Content-Type: application/json" \
			-d "{\"address\":\"${CONTAINER_IP}\",\"port\":${FRPC_RELAY_LOCAL_PORT}}" \
			"http://127.0.0.1:${STALWART_ADMIN_PORT}/api/mta/route/relay/${RELAY_ROUTE_ID}" 2>&1)"; then
			log info "Relay route updated successfully: ${response}"
			return 0
		fi
		log warn "Relay route update attempt ${attempt} failed: ${response}"
		sleep 2
	done

	log error "Failed to update relay route after 5 attempts."
	return 1
}

verify_startup() {
	STARTUP_GRACE_SECONDS="${STARTUP_GRACE_SECONDS:-5}"
	FRPC_START_DELAY_SECONDS="${FRPC_START_DELAY_SECONDS:-2}"

	sleep "$FRPC_START_DELAY_SECONDS"
	if ! kill -0 "$STALWART_PID" 2>/dev/null; then
		log error "Stalwart exited during startup."
		wait "$STALWART_PID" || true
		exit 1
	fi

	start_frpc
	wait_for_frpc_ready

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

	sleep "$STARTUP_GRACE_SECONDS"
	activate_frpc_slot

	# Update the Stalwart relay route to use the container's non-loopback IP
	# so Stalwart doesn't reject it as a loopback address.
	update_relay_route || log warn "Relay route update failed; will retry later."

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
		if ! kill -0 "${FRPC_RELAY_PID:-}" 2>/dev/null; then
			log warn "frpc relay visitor exited after startup; outbound relay may not work."
			# Don't kill the entire container - the relay visitor is non-essential
			# for the core Stalwart functionality (inbound mail and JMAP still work).
		fi
		sleep 2
	done
}

start_stalwart
determine_frpc_slot
verify_startup
monitor_processes
