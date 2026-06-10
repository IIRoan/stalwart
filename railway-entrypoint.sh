#!/bin/sh
set -eu

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
  "useTls": false,
  "allowInvalidCerts": false,
  "poolMaxConnections": 10,
  "poolRecyclingMethod": "fast"
}
EOF

exec /usr/local/bin/stalwart --config /etc/stalwart/config.json