#!/bin/sh
# Railway entrypoint for Solace Gatus (status.solace.onl).
# Public PORT is a thin proxy: Gatus on :8081, Stalwart→Discord bridge on /hooks/stalwart.
set -eu

mkdir -p /data

GATUS_INTERNAL_PORT="${GATUS_INTERNAL_PORT:-8081}"
PUBLIC_PORT="${PORT}"

write_base_config() {
	if [ -n "${GATUS_CONFIG_YAML:-}" ]; then
		printf '%s\n' "$GATUS_CONFIG_YAML" > /data/config.yaml
		return 0
	fi

	cp /etc/gatus/config.default.yaml /data/config.yaml
}

inject_basic_auth() {
	if [ -z "${GATUS_ADMIN_USERNAME:-}" ] || [ -z "${GATUS_ADMIN_PASSWORD:-}" ]; then
		return 0
	fi

	if grep -q '^security:' /data/config.yaml; then
		return 0
	fi

	BCRYPT_HASH=$(htpasswd -B -n -b "$GATUS_ADMIN_USERNAME" "$GATUS_ADMIN_PASSWORD" | cut -d: -f2)
	BCRYPT_B64=$(printf '%s' "$BCRYPT_HASH" | base64 -w0 2>/dev/null || printf '%s' "$BCRYPT_HASH" | base64)
	{
		echo "security:"
		echo "  basic:"
		echo "    username: \"$GATUS_ADMIN_USERNAME\""
		echo "    password-bcrypt-base64: \"$BCRYPT_B64\""
		echo ""
		cat /data/config.yaml
	} > /data/config.yaml.tmp
	mv /data/config.yaml.tmp /data/config.yaml
}

inject_prometheus_auth() {
	if [ -z "${prometheus_user:-}" ] || [ -z "${prometheus_password:-}" ]; then
		echo "prometheus_user and prometheus_password are required for Stalwart Metrics monitors." >&2
		return 0
	fi

	PROMETHEUS_BASIC_AUTH=$(
		printf '%s:%s' "$prometheus_user" "$prometheus_password" \
			| base64 -w0 2>/dev/null \
			|| printf '%s:%s' "$prometheus_user" "$prometheus_password" | base64 | tr -d '\n'
	)

	sed -i "s|__PROMETHEUS_BASIC_AUTH__|${PROMETHEUS_BASIC_AUTH}|g" /data/config.yaml
}

append_vps_ssh_endpoints() {
	if [ -z "${VPS_MONITOR_SSH_USERNAME:-}" ]; then
		return 0
	fi

	if grep -q 'name: vps-health' /data/config.yaml 2>/dev/null; then
		return 0
	fi

	if [ -z "${VPS_MONITOR_SSH_PRIVATE_KEY:-}" ] && [ -z "${VPS_MONITOR_SSH_PRIVATE_KEY_B64:-}" ]; then
		echo "VPS_MONITOR_SSH_USERNAME is set but no private key was provided; skipping VPS SSH monitors." >&2
		return 0
	fi

	if [ -n "${VPS_MONITOR_SSH_PRIVATE_KEY_B64:-}" ]; then
		printf '%s' "$VPS_MONITOR_SSH_PRIVATE_KEY_B64" | base64 -d > /data/vps_monitor_key
	else
		printf '%s\n' "$VPS_MONITOR_SSH_PRIVATE_KEY" > /data/vps_monitor_key
	fi
	chmod 600 /data/vps_monitor_key

	VPS_MONITOR_SSH_HOST="${VPS_MONITOR_SSH_HOST:-mail.solace.onl}"
	VPS_MONITOR_SSH_PORT="${VPS_MONITOR_SSH_PORT:-22}"
	VPS_MONITOR_SSH_COMMAND="${VPS_MONITOR_SSH_COMMAND:-/usr/local/bin/gatus-monitor.sh}"

	{
		echo ""
		echo "  - name: vps-health"
		echo "    group: VPS"
		echo "    url: ssh://${VPS_MONITOR_SSH_HOST}:${VPS_MONITOR_SSH_PORT}"
		echo "    interval: 60s"
		echo "    ui:"
		echo "      period: 90d"
		echo "    alerts:"
		echo "      - type: discord"
		echo "    ssh:"
		echo "      username: \"${VPS_MONITOR_SSH_USERNAME}\""
		echo "      private-key: |"
		sed 's/^/        /' /data/vps_monitor_key
		echo "    body: |"
		echo "      {"
		echo "        \"command\": \"${VPS_MONITOR_SSH_COMMAND}\""
		echo "      }"
		echo "    conditions:"
		echo "      - \"[CONNECTED] == true\""
		echo "      - \"[STATUS] == 0\""
		echo "      - \"[BODY].status == healthy\""
	} >> /data/config.yaml
}

write_base_config
inject_basic_auth
inject_prometheus_auth

if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
	echo "DISCORD_WEBHOOK_URL is not set; Discord downtime alerts are disabled." >&2
fi

if [ -z "${STALWART_WEBHOOK_BEARER:-}" ]; then
	echo "STALWART_WEBHOOK_BEARER is not set; /hooks/stalwart will reject Stalwart alerts." >&2
fi

append_vps_ssh_endpoints

# Gatus binds internally; the public PORT is the Discord bridge + reverse proxy.
# Bind PORT immediately so Railway/Docker healthchecks are not connection-refused
# while Gatus is still starting. /health is proxied; 502s during boot are covered
# by HEALTHCHECK start-period.
export GATUS_CONFIG_PATH="${GATUS_CONFIG_PATH:-/data/config.yaml}"
export GATUS_INTERNAL_PORT
export PORT="${GATUS_INTERNAL_PORT}"

/usr/local/bin/gatus &
GATUS_PID=$!

if ! kill -0 "$GATUS_PID" 2>/dev/null; then
	echo "Gatus failed to start" >&2
	exit 1
fi

export PORT="${PUBLIC_PORT}"
exec python3 /usr/local/bin/stalwart-discord-bridge.py
