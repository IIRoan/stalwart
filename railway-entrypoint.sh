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

log_file_tail() {
	label="$1"
	path="$2"
	lines="${3:-40}"
	if [ -f "$path" ]; then
		log info "Last ${lines} lines of ${label} (${path}):"
		tail -n "$lines" "$path" >&2 || true
	else
		log warn "${label} log not found at ${path}."
	fi
}

log_listener_ports() {
	if command -v ss >/dev/null 2>&1; then
		log info "Listening TCP ports: $(ss -tlnH 2>/dev/null | awk '{print $4}' | tr '\n' ' ' || echo 'unavailable')"
	elif command -v netstat >/dev/null 2>&1; then
		log info "Listening TCP ports: $(netstat -tln 2>/dev/null | awk 'NR>2 {print $4}' | tr '\n' ' ' || echo 'unavailable')"
	else
		log warn "Could not list listening ports (ss/netstat missing)."
	fi
}

probe_stalwart_http() {
	url="$1"
	response_file="/tmp/stalwart-probe.$$"
	http_code="000"
	curl_error=""

	http_code="$(curl -sS -o "$response_file" -w '%{http_code}' \
		--connect-timeout "${STALWART_PROBE_CONNECT_TIMEOUT:-3}" \
		--max-time "${STALWART_PROBE_MAX_TIME:-8}" \
		"$url" 2>/tmp/stalwart-probe.err || true)"
	if [ -f /tmp/stalwart-probe.err ]; then
		curl_error="$(tr '\n' ' ' </tmp/stalwart-probe.err | sed 's/[[:space:]]\+/ /g')"
		rm -f /tmp/stalwart-probe.err
	fi

	body_snippet=""
	if [ -f "$response_file" ]; then
		body_snippet="$(head -c 200 "$response_file" | tr '\n' ' ')"
		rm -f "$response_file"
	fi

	printf '%s|%s|%s\n' "$http_code" "$curl_error" "$body_snippet"
}

stalwart_http_status() {
	probe="$(probe_stalwart_http "http://127.0.0.1:${STALWART_HTTP_PORT:-8080}/jmap/session")"
	http_code="${probe%%|*}"
	rest="${probe#*|}"
	curl_error="${rest%%|*}"
	body_snippet="${rest#*|}"

	case "$http_code" in
		2*|401|403)
			printf 'ready|%s\n' "$http_code"
			return 0
			;;
	esac

	printf 'not-ready|%s|%s|%s\n' "$http_code" "$curl_error" "$body_snippet"
	return 1
}

stalwart_http_ready() {
	if status_line="$(stalwart_http_status)"; then
		http_code="${status_line#ready|}"
		log info "Stalwart HTTP probe ready: GET /jmap/session -> HTTP ${http_code}."
		return 0
	fi

	http_code="${status_line#not-ready|}"
	rest="${http_code#*|}"
	http_code="${status_line#not-ready|}"
	http_code="${http_code%%|*}"
	rest="${status_line#not-ready|}"
	rest="${rest#*|}"
	curl_error="${rest%%|*}"
	body_snippet="${rest#*|}"
	log warn "Stalwart HTTP probe not ready: GET /jmap/session -> HTTP ${http_code}; curl='${curl_error:-ok}'; body='${body_snippet}'."
	return 1
}

stalwart_http_ready_quiet() {
	stalwart_http_status >/dev/null 2>&1
}

log_stalwart_diagnostics() {
	reason="$1"
	log error "Stalwart diagnostics (${reason})."
	if kill -0 "$STALWART_PID" 2>/dev/null; then
		log info "Stalwart process ${STALWART_PID} is still running."
	else
		log error "Stalwart process ${STALWART_PID} is not running."
		wait "$STALWART_PID" 2>/dev/null || true
		log error "Stalwart exit status: $?."
	fi
	log_listener_ports
	log_file_tail "stalwart" "${STALWART_LOG_FILE:-/tmp/stalwart.log}"
	log_file_tail "frpc" "${FRPC_LOG_FILE:-/tmp/frpc.log}"
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
	FRPC_ENABLE_SUBMISSION_PROXY="${FRPC_ENABLE_SUBMISSION_PROXY:-true}"
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
transport.proxyProtocolVersion = "v2"
EOF

		if [ "${FRPC_ENABLE_SMTPS_PROXY:-true}" = "true" ]; then
			cat >> "$FRPC_CONFIG" <<EOF

[[proxies]]
name = "submissions-${FRPC_PROXY_SUFFIX}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 465
remotePort = ${FRPC_SUBMISSIONS_REMOTE_PORT}
transport.proxyProtocolVersion = "v2"
EOF
		else
			log info "Skipping SMTPS proxy on port 465."
		fi

		if [ "${FRPC_ENABLE_IMAPS_PROXY:-true}" = "true" ]; then
			cat >> "$FRPC_CONFIG" <<EOF

[[proxies]]
name = "imaps-${FRPC_PROXY_SUFFIX}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 993
remotePort = ${FRPC_IMAPS_REMOTE_PORT}
transport.proxyProtocolVersion = "v2"
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
transport.proxyProtocolVersion = "v2"
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
	STALWART_LOG_FILE="${STALWART_LOG_FILE:-/tmp/stalwart.log}"
	STALWART_HTTP_PORT="${STALWART_HTTP_PORT:-8080}"

	log info "Starting Stalwart."
	log info "Database target: host=${PGHOST} port=${PGPORT} database=${PGDATABASE} tls=${USE_TLS} allowInvalidCerts=${ALLOW_INVALID}."
	log info "Recovery mode active: ${RECOVERY_MODE_ACTIVE}."
	log info "Stalwart logs: ${STALWART_LOG_FILE}."
	: > "$STALWART_LOG_FILE"
	/usr/local/bin/stalwart --config /etc/stalwart/config.json >>"$STALWART_LOG_FILE" 2>&1 &
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
}

wait_for_stalwart_admin() {
	ADMIN_READY_TIMEOUT="${ADMIN_READY_TIMEOUT:-300}"
	ADMIN_LOG_INTERVAL="${ADMIN_LOG_INTERVAL:-15}"
	elapsed=0
	next_log=0

	log info "Waiting up to ${ADMIN_READY_TIMEOUT}s for Stalwart HTTP on 127.0.0.1:${STALWART_HTTP_PORT:-8080}."

	while [ "$elapsed" -lt "$ADMIN_READY_TIMEOUT" ]; do
		if ! kill -0 "$STALWART_PID" 2>/dev/null; then
			log_stalwart_diagnostics "process exited while waiting for admin API"
			return 1
		fi
		if stalwart_http_ready_quiet; then
			stalwart_http_ready
			log info "Stalwart admin API is ready after ${elapsed}s."
			return 0
		fi
		if [ "$elapsed" -ge "$next_log" ]; then
			log info "Still waiting for Stalwart admin API (${elapsed}s/${ADMIN_READY_TIMEOUT}s elapsed)."
			stalwart_http_ready || true
			log_listener_ports
			log_file_tail "stalwart" "${STALWART_LOG_FILE:-/tmp/stalwart.log}" 15
			next_log=$((elapsed + ADMIN_LOG_INTERVAL))
		fi
		elapsed=$((elapsed + 1))
		sleep 1
	done

	log_stalwart_diagnostics "admin API not ready within ${ADMIN_READY_TIMEOUT}s"
	return 1
}

update_relay_route() {
	RELAY_ROUTE_ID="${RELAY_ROUTE_ID:-ivnbzc1aaba9}"
	RELAY_ROUTE_ADDRESS="${RELAY_ROUTE_ADDRESS:-mailsend.solace.onl}"
	RELAY_ROUTE_PORT="${RELAY_ROUTE_PORT:-587}"

	if [ -z "${STALWART_ADMIN_TOKEN:-}" ]; then
		log warn "STALWART_ADMIN_TOKEN is not set; skipping relay route update."
		return 1
	fi

	RELAY_ADDRESS="$RELAY_ROUTE_ADDRESS"

	log info "Updating relay route ${RELAY_ROUTE_ID} to ${RELAY_ADDRESS}:${RELAY_ROUTE_PORT}."
	if RELAY_UPDATE_OUTPUT="$(/usr/local/bin/stalwart-cli \
		--url "http://127.0.0.1:8080" \
		--api-key "$STALWART_ADMIN_TOKEN" \
		update MtaRoute "$RELAY_ROUTE_ID" \
		--field "address=${RELAY_ADDRESS}" \
		--field "port=${RELAY_ROUTE_PORT}" 2>&1)"; then
		log info "Relay route updated to ${RELAY_ADDRESS}:${RELAY_ROUTE_PORT}."
		RELAY_ROUTE_UPDATED=true
		return 0
	fi

	log warn "Failed to update relay route via stalwart-cli: ${RELAY_UPDATE_OUTPUT:-unknown error}"
	return 1
}

verify_startup() {
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

	if wait_for_stalwart_admin; then
		activate_frpc_slot
		update_relay_route || log warn "Relay route update failed at startup; will retry in background."
		SLOT_ACTIVATED=true
		log info "Startup complete."
	else
		case "${ADMIN_READY_FATAL:-false}" in
			1|true|TRUE|yes|YES)
				log error "Refusing to continue before Stalwart is ready (ADMIN_READY_FATAL=true)."
				exit 1
				;;
			*)
				log warn "Continuing in degraded mode; slot activation and relay update deferred until Stalwart is ready."
				STARTUP_DEGRADED=true
				;;
		esac
	fi
}

monitor_processes() {
	RELAY_ROUTE_UPDATED="${RELAY_ROUTE_UPDATED:-false}"
	SLOT_ACTIVATED="${SLOT_ACTIVATED:-false}"
	STARTUP_DEGRADED="${STARTUP_DEGRADED:-false}"
	relay_retry_interval="${RELAY_ROUTE_RETRY_SECONDS:-30}"
	relay_retry_elapsed=0
	degraded_retry_interval="${DEGRADED_RETRY_SECONDS:-30}"
	degraded_retry_elapsed=0

	while :; do
		if ! kill -0 "$STALWART_PID" 2>/dev/null; then
			log_stalwart_diagnostics "stalwart exited during monitoring"
			wait "$STALWART_PID"
			exit $?
		fi
		if ! kill -0 "$FRPC_PID" 2>/dev/null; then
			log error "frpc exited after startup."
			log_file_tail "frpc" "${FRPC_LOG_FILE:-/tmp/frpc.log}"
			wait "$FRPC_PID" || true
			kill "$STALWART_PID" 2>/dev/null || true
			wait "$STALWART_PID" || true
			exit 1
		fi
		if [ "$STARTUP_DEGRADED" = "true" ] || [ "$SLOT_ACTIVATED" != "true" ] || [ "$RELAY_ROUTE_UPDATED" != "true" ]; then
			degraded_retry_elapsed=$((degraded_retry_elapsed + 2))
			if [ "$degraded_retry_elapsed" -ge "$degraded_retry_interval" ]; then
				degraded_retry_elapsed=0
				if stalwart_http_ready_quiet; then
					if [ "$SLOT_ACTIVATED" != "true" ]; then
						log info "Stalwart became ready; activating slot ${FRPC_SLOT}."
						if activate_frpc_slot; then
							SLOT_ACTIVATED=true
							STARTUP_DEGRADED=false
						fi
					fi
					if [ "$RELAY_ROUTE_UPDATED" != "true" ]; then
						update_relay_route || true
					fi
				else
					log warn "Deferred startup tasks still waiting for Stalwart HTTP (slotActivated=${SLOT_ACTIVATED}, relayUpdated=${RELAY_ROUTE_UPDATED})."
				fi
			fi
		elif [ "$RELAY_ROUTE_UPDATED" != "true" ]; then
			relay_retry_elapsed=$((relay_retry_elapsed + 2))
			if [ "$relay_retry_elapsed" -ge "$relay_retry_interval" ]; then
				relay_retry_elapsed=0
				update_relay_route || true
			fi
		fi
		sleep 2
	done
}

start_stalwart
determine_frpc_slot
verify_startup
monitor_processes
