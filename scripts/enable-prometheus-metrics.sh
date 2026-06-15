#!/usr/bin/env bash
# Enable Stalwart Prometheus export at /metrics/prometheus (once per deployment).
#
# Usage:
#   export STALWART_ADMIN_TOKEN=...
#   export STALWART_METRICS_USERNAME=prometheus
#   export STALWART_METRICS_PASSWORD=...
#   ./scripts/enable-prometheus-metrics.sh
#
# Then set the same username/password on the Gatus Railway service.

set -euo pipefail

STALWART_URL="${STALWART_URL:-https://mail.solace.onl}"
STALWART_ADMIN_TOKEN="${STALWART_ADMIN_TOKEN:?STALWART_ADMIN_TOKEN is required}"
STALWART_METRICS_USERNAME="${STALWART_METRICS_USERNAME:?STALWART_METRICS_USERNAME is required}"
STALWART_METRICS_PASSWORD="${STALWART_METRICS_PASSWORD:?STALWART_METRICS_PASSWORD is required}"

if ! command -v stalwart-cli >/dev/null 2>&1; then
	echo "stalwart-cli not found in PATH." >&2
	exit 1
fi

export HOME="${HOME:-/tmp}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp}"

METRICS_ID="$(stalwart-cli --url "$STALWART_URL" --api-key "$STALWART_ADMIN_TOKEN" \
	query Metrics --limit 1 --output json 2>/dev/null | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

if [ -z "$METRICS_ID" ]; then
	echo "Could not resolve Metrics object id from $STALWART_URL" >&2
	exit 1
fi

stalwart-cli --url "$STALWART_URL" --api-key "$STALWART_ADMIN_TOKEN" \
	update Metrics "$METRICS_ID" \
	--field "prometheus.@type=Enabled" \
	--field "prometheus.authUsername=${STALWART_METRICS_USERNAME}" \
	--field "prometheus.authSecret.@type=Value" \
	--field "prometheus.authSecret.secret=${STALWART_METRICS_PASSWORD}"

stalwart-cli --url "$STALWART_URL" --api-key "$STALWART_ADMIN_TOKEN" \
	create Action/ReloadSettings >/dev/null

echo "Prometheus enabled at ${STALWART_URL}/metrics/prometheus"
echo "Verify: curl -u '${STALWART_METRICS_USERNAME}:****' '${STALWART_URL}/metrics/prometheus' | head"
