#!/bin/sh
# Reconcile HAProxy weights with /etc/haproxy/stalwart-active-slot after start/reload.
set -eu

ACTIVE_SLOT_FILE="/etc/haproxy/stalwart-active-slot"
SWITCH_COMMAND="${SWITCH_COMMAND:-/usr/local/bin/stalwart-switch-slot.sh}"

if [ ! -f "$ACTIVE_SLOT_FILE" ]; then
	printf '%s\n' blue >"$ACTIVE_SLOT_FILE"
fi

slot="$(tr -d '[:space:]' <"$ACTIVE_SLOT_FILE")"
case "$slot" in
	blue|green) ;;
	*)
		slot=blue
		printf '%s\n' "$slot" >"$ACTIVE_SLOT_FILE"
		;;
esac

exec "$SWITCH_COMMAND" "$slot"
