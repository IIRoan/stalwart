#!/bin/sh
set -eu

TARGET_SLOT="${1:-}"

if [ -z "$TARGET_SLOT" ]; then
	echo "Usage: $0 <blue|green>" >&2
	exit 1
fi

case "$TARGET_SLOT" in
	blue)
		CHECK_PORTS="10025 10443 18080"
		;;
	green)
		CHECK_PORTS="11025 11443 19080"
		;;
	*)
		echo "Slot must be blue or green." >&2
		exit 1
		;;
esac

ACTIVE_SLOT_FILE="/etc/haproxy/stalwart-active-slot"
HAPROXY_CONFIG="/etc/haproxy/haproxy.cfg"

for port in $CHECK_PORTS; do
	i=0
	while [ "$i" -lt 30 ]; do
		if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
			break
		fi
		i=$((i + 1))
		sleep 1
	done

	if ! nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
		echo "Port $port for slot $TARGET_SLOT did not become ready." >&2
		exit 1
	fi
done

printf '%s\n' "$TARGET_SLOT" | sudo tee "$ACTIVE_SLOT_FILE" >/dev/null
sudo haproxy -c -f "$HAPROXY_CONFIG"
sudo systemctl reload haproxy
echo "Active slot switched to $TARGET_SLOT."
