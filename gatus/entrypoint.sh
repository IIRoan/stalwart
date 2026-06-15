#!/bin/sh
# Railway entrypoint for Solace Gatus (status.solace.onl).
set -eu

mkdir -p /data

write_base_config() {
	if [ -n "${GATUS_CONFIG_YAML:-}" ]; then
		printf '%s\n' "$GATUS_CONFIG_YAML" > /data/config.yaml
		return 0
	fi

	if [ ! -f /data/config.yaml ]; then
		cp /etc/gatus/config.default.yaml /data/config.yaml
	fi
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

append_stalwart_metrics_endpoints() {
	if [ -z "${STALWART_METRICS_USERNAME:-}" ] || [ -z "${STALWART_METRICS_PASSWORD:-}" ]; then
		return 0
	fi

	if grep -q 'name: stalwart-metrics' /data/config.yaml 2>/dev/null; then
		return 0
	fi

	STALWART_METRICS_BASIC_AUTH=$(
		printf '%s:%s' "$STALWART_METRICS_USERNAME" "$STALWART_METRICS_PASSWORD" \
			| base64 -w0 2>/dev/null \
			|| printf '%s:%s' "$STALWART_METRICS_USERNAME" "$STALWART_METRICS_PASSWORD" | base64 | tr -d '\n'
	)

	{
		echo ""
		echo "  - name: stalwart-metrics"
		echo "    group: Mail"
		echo "    url: https://mail.solace.onl/metrics/prometheus"
		echo "    interval: 60s"
		echo "    client:"
		echo "      timeout: 15s"
		echo "      headers:"
		echo "        Authorization: \"Basic ${STALWART_METRICS_BASIC_AUTH}\""
		echo "    conditions:"
		echo "      - \"[STATUS] == 200\""
		echo "      - \"[BODY] == pat(*queue_count*)\""
		echo "      - \"[BODY] == pat(*smtp_active_connections*)\""
		echo "      - \"[BODY] == pat(*delivery_active_connections*)\""
	} >> /data/config.yaml
}

write_base_config
inject_basic_auth
append_stalwart_metrics_endpoints
append_vps_ssh_endpoints

export GATUS_CONFIG_PATH="${GATUS_CONFIG_PATH:-/data/config.yaml}"

exec /usr/local/bin/gatus
