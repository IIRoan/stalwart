#!/bin/sh
set -eu

TARGET_SLOT="${1:-}"

if [ -z "$TARGET_SLOT" ]; then
	echo "Usage: $0 <blue|green>" >&2
	exit 1
fi

case "$TARGET_SLOT" in
	blue)
		SMTP_PORT=10025
		HTTPS_PORT=10443
		HTTP_ADMIN_PORT=18080
		;;
	green)
		SMTP_PORT=11025
		HTTPS_PORT=11443
		HTTP_ADMIN_PORT=19080
		;;
	*)
		echo "Slot must be blue or green." >&2
		exit 1
		;;
esac

ACTIVE_SLOT_FILE="/etc/haproxy/stalwart-active-slot"
HTTP_READY_TIMEOUT="${HTTP_READY_TIMEOUT:-60}"
HTTP_HEALTHCHECK_HOST="${HTTP_HEALTHCHECK_HOST:-mail.solace.onl}"
HAPROXY_SOCKET="${HAPROXY_SOCKET:-/run/haproxy/admin.sock}"
TRANSITION_SECONDS="${TRANSITION_SECONDS:-30}"
TRANSITION_STEPS="${TRANSITION_STEPS:-6}"

run_haproxy_command() {
	command="$1"
	printf '%s\n' "$command" | sudo nc -U "$HAPROXY_SOCKET"
}

set_slot_weights() {
	blue_weight="$1"
	green_weight="$2"

	for backend in bk_smtp bk_https bk_http_admin; do
		run_haproxy_command "set weight ${backend}/railway_blue ${blue_weight}%"
		run_haproxy_command "set weight ${backend}/railway_green ${green_weight}%"
	done
}

wait_for_tcp_port() {
	port="$1"
	i=0
	while [ "$i" -lt 30 ]; do
		if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done

	echo "Port $port for slot $TARGET_SLOT did not become ready." >&2
	exit 1
}

wait_for_http_port() {
	port="$1"
	elapsed=0
	while [ "$elapsed" -lt "$HTTP_READY_TIMEOUT" ]; do
		status_code="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 -H "Host: ${HTTP_HEALTHCHECK_HOST}" "http://127.0.0.1:${port}/" || printf '000')"
		case "$status_code" in
			2*|3*|4*)
				return 0
				;;
		esac
		elapsed=$((elapsed + 1))
		sleep 1
	done

	echo "HTTP port $port for slot $TARGET_SLOT did not become ready." >&2
	exit 1
}

read_active_slot() {
	if [ -f "$ACTIVE_SLOT_FILE" ]; then
		slot="$(tr -d '[:space:]' < "$ACTIVE_SLOT_FILE")"
		case "$slot" in
			blue|green)
				printf '%s\n' "$slot"
				return 0
				;;
		esac
	fi

	printf '%s\n' "blue"
}

wait_for_tcp_port "$SMTP_PORT"
wait_for_http_port "$HTTPS_PORT"
wait_for_http_port "$HTTP_ADMIN_PORT"

if [ ! -S "$HAPROXY_SOCKET" ]; then
	echo "HAProxy socket $HAPROXY_SOCKET is not available." >&2
	exit 1
fi

CURRENT_SLOT="$(read_active_slot)"

if [ "$CURRENT_SLOT" = "$TARGET_SLOT" ]; then
	case "$TARGET_SLOT" in
		blue)
			set_slot_weights 100 0
			;;
		green)
			set_slot_weights 0 100
			;;
	esac
	printf '%s\n' "$TARGET_SLOT" | sudo tee "$ACTIVE_SLOT_FILE" >/dev/null
	echo "Active slot already set to $TARGET_SLOT."
	exit 0
fi

step_sleep=$((TRANSITION_SECONDS / TRANSITION_STEPS))
if [ "$step_sleep" -lt 1 ]; then
	step_sleep=1
fi

i=0
while [ "$i" -le "$TRANSITION_STEPS" ]; do
	target_weight=$((i * 100 / TRANSITION_STEPS))
	other_weight=$((100 - target_weight))

	case "$TARGET_SLOT" in
		blue)
			set_slot_weights "$target_weight" "$other_weight"
			;;
		green)
			set_slot_weights "$other_weight" "$target_weight"
			;;
	esac

	if [ "$i" -lt "$TRANSITION_STEPS" ]; then
		sleep "$step_sleep"
	fi
	i=$((i + 1))
done

printf '%s\n' "$TARGET_SLOT" | sudo tee "$ACTIVE_SLOT_FILE" >/dev/null
echo "Active slot shifted to $TARGET_SLOT over ${TRANSITION_SECONDS}s."
