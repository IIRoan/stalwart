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
		HTTP_PORT=18080
		;;
	green)
		SMTP_PORT=11025
		HTTP_PORT=19080
		;;
	*)
		echo "Slot must be blue or green." >&2
		exit 1
		;;
esac

ACTIVE_SLOT_FILE="/etc/haproxy/stalwart-active-slot"
HTTP_READY_TIMEOUT="${HTTP_READY_TIMEOUT:-60}"
HAPROXY_SOCKET="${HAPROXY_SOCKET:-/run/haproxy/admin.sock}"
GRADUAL_SWITCH="${GRADUAL_SWITCH:-0}"
OVERLAP_SECONDS="${OVERLAP_SECONDS:-30}"
FINAL_DRAIN_SECONDS="${FINAL_DRAIN_SECONDS:-5}"
TRANSITION_SECONDS="${TRANSITION_SECONDS:-}"
TRANSITION_STEPS="${TRANSITION_STEPS:-6}"
WARM_WEIGHT="${WARM_WEIGHT:-1}"

ALL_BACKENDS="bk_smtp bk_submissions bk_imaps bk_https bk_http_admin"

if [ -z "$TRANSITION_SECONDS" ]; then
	TRANSITION_SECONDS=$((OVERLAP_SECONDS - FINAL_DRAIN_SECONDS))
fi

if [ "$TRANSITION_SECONDS" -lt 1 ]; then
	TRANSITION_SECONDS=1
fi

run_haproxy_command() {
	command="$1"
	python3 - "$HAPROXY_SOCKET" "$command" <<'PY'
import socket
import sys

sock_path = sys.argv[1]
command = sys.argv[2] + "\n"

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sock_path)
sock.sendall(command.encode())
response = b""
while True:
    data = sock.recv(65536)
    if not data:
        break
    response += data
sock.close()
sys.stdout.write(response.decode())
PY
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

	for backend in $ALL_BACKENDS; do
		run_haproxy_command "set server ${backend}/railway_${slot} state ${state}"
	done
}

set_slot_weights() {
	blue_weight="$1"
	green_weight="$2"

	for backend in $ALL_BACKENDS; do
		if [ "$blue_weight" -ge "$green_weight" ]; then
			run_haproxy_command "set weight ${backend}/railway_blue ${blue_weight}%"
			run_haproxy_command "set weight ${backend}/railway_green ${green_weight}%"
		else
			run_haproxy_command "set weight ${backend}/railway_green ${green_weight}%"
			run_haproxy_command "set weight ${backend}/railway_blue ${blue_weight}%"
		fi
	done
}

set_warm_weights() {
	incumbent="$1"
	target="$2"

	case "$incumbent:$target" in
		green:blue) set_slot_weights "$WARM_WEIGHT" 100 ;;
		blue:green) set_slot_weights 100 "$WARM_WEIGHT" ;;
		*)
			echo "Unknown warm weight pair ${incumbent}->${target}." >&2
			return 1
			;;
	esac
}

set_exclusive_weights() {
	slot="$1"

	case "$slot" in
		blue) set_slot_weights 100 0 ;;
		green) set_slot_weights 0 100 ;;
	esac
}

ramp_exclusive_weights() {
	target_slot="$1"
	incumbent_slot="$2"

	for step in 90 70 50 30 10 0; do
		target_weight=$((100 - step))
		incumbent_weight=$step

		case "$target_slot" in
			blue) set_slot_weights "$incumbent_weight" "$target_weight" ;;
			green) set_slot_weights "$target_weight" "$incumbent_weight" ;;
		esac

		if ! wait_for_edge_jmap 4; then
			echo "Edge probe failed during ramp (${incumbent_weight}/${target_weight})." >&2
			return 1
		fi
		sleep 0.5
	done

	return 0
}

wait_for_stable_slot_up() {
	slot="$1"
	required="${2:-2}"
	streak=0
	i=0
	while [ "$i" -lt "$HTTP_READY_TIMEOUT" ]; do
		status="$(get_server_status bk_https "$slot")"
		case "$status" in
			UP|UP\ *)
				streak=$((streak + 1))
				if [ "$streak" -ge "$required" ]; then
					return 0
				fi
				;;
			*)
				streak=0
				;;
		esac
		i=$((i + 1))
		sleep 0.5
	done

	echo "Slot $slot did not stay UP on bk_https for ${required}s." >&2
	return 1
}

wait_for_slot_jmap() {
	slot="$1"
	host="${HTTP_HEALTHCHECK_HOST:-mail.solace.onl}"
	max_wait="${2:-20}"

	case "$slot" in
		blue) port=18080 ;;
		green) port=19080 ;;
		*)
			echo "Unknown slot $slot for direct JMAP probe." >&2
			return 1
			;;
	esac

	i=0
	while [ "$i" -lt "$max_wait" ]; do
		if curl -fsS --max-time 2 --haproxy-protocol \
			-H "Host: ${host}" \
			"http://127.0.0.1:${port}/jmap/session" >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 0.5
	done

	echo "Direct JMAP probe failed for slot $slot on :${port}." >&2
	return 1
}

wait_for_edge_jmap() {
	host="${HTTP_HEALTHCHECK_HOST:-mail.solace.onl}"
	max_wait="${1:-15}"
	i=0
	while [ "$i" -lt "$max_wait" ]; do
		if curl -fsS --max-time 2 "https://${host}/jmap/session" >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 0.5
	done

	echo "Public JMAP probe failed after cutover." >&2
	return 1
}

rollback_finalize() {
	target_slot="$1"

	case "$target_slot" in
		blue)
			set_exclusive_weights green
			set_slot_state green ready
			set_slot_state blue maint
			printf '%s\n' green >"$ACTIVE_SLOT_FILE"
			;;
		green)
			set_exclusive_weights blue
			set_slot_state blue ready
			set_slot_state green maint
			printf '%s\n' blue >"$ACTIVE_SLOT_FILE"
			;;
	esac
}

finalize_active_slot() {
	target_slot="$1"
	incumbent_slot="$2"

	set_slot_state "$target_slot" ready
	set_warm_weights "$incumbent_slot" "$target_slot"

	if ! wait_for_slot_jmap "$target_slot"; then
		rollback_finalize "$target_slot"
		return 1
	fi

	set_slot_weights 100 100
	if ! wait_for_stable_slot_up "$target_slot" 2; then
		rollback_finalize "$target_slot"
		return 1
	fi
	if ! ramp_exclusive_weights "$target_slot" "$incumbent_slot"; then
		rollback_finalize "$target_slot"
		return 1
	fi

	set_slot_state "$incumbent_slot" maint
	printf '%s\n' "$target_slot" | tee "$ACTIVE_SLOT_FILE" >/dev/null
}

wait_for_tcp_port() {
	port="$1"
	i=0
	while [ "$i" -lt "$HTTP_READY_TIMEOUT" ]; do
		if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 0.5
	done

	echo "Port $port for slot $TARGET_SLOT did not become ready." >&2
	return 1
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

	for backend in $ALL_BACKENDS; do
		elapsed=0
		while [ "$elapsed" -lt "$HTTP_READY_TIMEOUT" ]; do
			status="$(get_server_status "$backend" "$slot")"
			case "$status" in
				UP|UP\ *)
					break
					;;
			esac
			elapsed=$((elapsed + 1))
			sleep 0.5
		done

		status="$(get_server_status "$backend" "$slot")"
		case "$status" in
			UP|UP\ *)
				;;
			*)
				echo "Slot $slot in backend $backend did not become UP in HAProxy, current status: ${status:-unknown}." >&2
				return 1
				;;
		esac
	done
}

gradual_switch() {
	other_slot="$1"

	set_slot_state "$other_slot" ready
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

	set_slot_state "$other_slot" drain
	sleep "$FINAL_DRAIN_SECONDS"
	wait_for_slot_up "$TARGET_SLOT"
	finalize_active_slot "$TARGET_SLOT" "$other_slot"
	echo "Active slot shifted to $TARGET_SLOT over ${TRANSITION_SECONDS}s with ${FINAL_DRAIN_SECONDS}s final drain buffer."
}

if [ ! -S "$HAPROXY_SOCKET" ]; then
	echo "HAProxy socket $HAPROXY_SOCKET is not available." >&2
	exit 1
fi

wait_for_tcp_port "$SMTP_PORT"
wait_for_tcp_port "$HTTP_PORT"

CURRENT_SLOT="$(read_active_slot)"

if [ "$CURRENT_SLOT" = "$TARGET_SLOT" ]; then
	set_slot_state "$TARGET_SLOT" ready
	set_exclusive_weights "$TARGET_SLOT"
	printf '%s\n' "$TARGET_SLOT" | tee "$ACTIVE_SLOT_FILE" >/dev/null
	echo "Active slot already set to $TARGET_SLOT."
	exit 0
fi

OTHER_SLOT="$CURRENT_SLOT"

if [ "$GRADUAL_SWITCH" = "1" ]; then
	gradual_switch "$OTHER_SLOT"
else
	finalize_active_slot "$TARGET_SLOT" "$OTHER_SLOT"
	echo "Active slot switched to $TARGET_SLOT (instant cutover)."
fi
