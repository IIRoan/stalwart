#!/bin/sh
set -eu

# Build Stalwart config.json from Railway PostgreSQL variables.
# Link your PostgreSQL service in Railway so PGHOST, PGPORT, PGDATABASE,
# PGUSER, and PGPASSWORD are injected automatically.

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

if [ -z "$PGHOST" ] || [ -z "$PGUSER" ] || [ -z "$PGPASSWORD" ]; then
	echo "error: missing PostgreSQL credentials." >&2
	echo "In Railway, open your Stalwart service -> Variables -> add references from your PostgreSQL service (PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD)." >&2
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

start_frpc() {
	if [ -z "${FRPS_ADDR:-}" ]; then
		echo "FRPS_ADDR not set; skipping outbound tunnel (mail must reach Stalwart another way)." >&2
		return 0
	fi

	if [ -z "${FRPC_TOKEN:-}" ]; then
		echo "error: FRPC_TOKEN is required when FRPS_ADDR is set." >&2
		exit 1
	fi

	FRPS_PORT="${FRPS_PORT:-7000}"
	FRPC_CONFIG="${FRPC_CONFIG:-/tmp/frpc.toml}"

	cat > "$FRPC_CONFIG" <<EOF
serverAddr = "${FRPS_ADDR}"
serverPort = ${FRPS_PORT}

[auth]
method = "token"
token = "${FRPC_TOKEN}"

[[proxies]]
name = "smtp"
type = "tcp"
localIP = "127.0.0.1"
localPort = 25
remotePort = 10025

[[proxies]]
name = "submissions"
type = "tcp"
localIP = "127.0.0.1"
localPort = 465
remotePort = 10465

[[proxies]]
name = "submission"
type = "tcp"
localIP = "127.0.0.1"
localPort = 587
remotePort = 10587

[[proxies]]
name = "imaps"
type = "tcp"
localIP = "127.0.0.1"
localPort = 993
remotePort = 10993

[[proxies]]
name = "https"
type = "tcp"
localIP = "127.0.0.1"
localPort = 443
remotePort = 10443

[[proxies]]
name = "http-admin"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8080
remotePort = 18080
EOF

	echo "Starting frpc tunnel to ${FRPS_ADDR}:${FRPS_PORT}..." >&2
	/usr/local/bin/frpc -c "$FRPC_CONFIG" &
	FRPC_PID=$!

	sleep 2
	if ! kill -0 "$FRPC_PID" 2>/dev/null; then
		echo "error: frpc failed to start." >&2
		exit 1
	fi
}

start_frpc

exec /usr/local/bin/stalwart --config /etc/stalwart/config.json
