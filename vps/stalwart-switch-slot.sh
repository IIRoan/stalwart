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
OVERLAP_SECONDS="${OVERLAP_SECONDS:-30}"
FINAL_DRAIN_SECONDS="${FINAL_DRAIN_SECONDS:-5}"
TRANSITION_SECONDS="${TRANSITION_SECONDS:-}"
TRANSITION_STEPS="${TRANSITION_STEPS:-6}"

if [ -z "$TRANSITION_SECONDS" ]; then
	TRANSITION_SECONDS=$((OVERLAP_SECONDS - FINAL_DRAIN_SECONDS))
fi

if [ "$TRANSITION_SECONDS" -lt 1 ]; then
	TRANSITION_SECONDS=1
fi

run_haproxy_command() {
	command="$1"
	printf '%s\n' "$command" | sudo nc -U "$HAPROXY_SOCKET"
}

get_server_status() {
	backend="$1"
	slot="$2"

	run_haproxy_command "show stat" | awk -F, -v backend="$backend" -v server="railway_${slot}" '
		$1 == backend && $2 == server {
			print $18
			exit
		}
	'
}

set_slot_state() {
	slot="$1"
	state="$2"

	for backend in bk_smtp bk_https bk_http_admin; do
		run_haproxy_command "set server ${backend}/railway_${slot} state ${state}"
	done
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

wait_for_slot_up() {
	slot="$1"

	for backend in bk_smtp bk_https bk_http_admin; do
		elapsed=0
		while [ "$elapsed" -lt "$HTTP_READY_TIMEOUT" ]; do
			status="$(get_server_status "$backend" "$slot")"
			case "$status" in
				UP|UP\ *)
					break
					;;
			esac
			elapsed=$((elapsed + 1))
			sleep 1
		done

		status="$(get_server_status "$backend" "$slot")"
		case "$status" in
			UP|UP\ *)
				;;
			*)
				echo "Slot $slot in backend $backend did not become UP in HAProxy, current status: ${status:-unknown}." >&2
				exit 1
				;;
		esac
	done
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
	set_slot_state "$TARGET_SLOT" ready
	wait_for_slot_up "$TARGET_SLOT"
	case "$TARGET_SLOT" in
		blue)
			set_slot_state green maint
			set_slot_weights 100 0
			;;
		green)
			set_slot_state blue maint
			set_slot_weights 0 100
			;;
	esac
	printf '%s\n' "$TARGET_SLOT" | sudo tee "$ACTIVE_SLOT_FILE" >/dev/null
	echo "Active slot already set to $TARGET_SLOT."
	exit 0
fi

set_slot_state "$CURRENT_SLOT" ready
set_slot_state "$TARGET_SLOT" ready
wait_for_slot_up "$TARGET_SLOT"

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

set_slot_state "$CURRENT_SLOT" drain
sleep "$FINAL_DRAIN_SECONDS"
wait_for_slot_up "$TARGET_SLOT"
set_slot_state "$CURRENT_SLOT" maint
set_slot_state "$TARGET_SLOT" ready

printf '%s\n' "$TARGET_SLOT" | sudo tee "$ACTIVE_SLOT_FILE" >/dev/null
echo "Active slot shifted to $TARGET_SLOT over ${TRANSITION_SECONDS}s with ${FINAL_DRAIN_SECONDS}s final drain buffer."
