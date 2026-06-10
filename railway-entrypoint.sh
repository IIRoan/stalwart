#!/bin/sh
set -eu

cat > /etc/stalwart/config.json <<EOF
{
  "@type": "PostgreSql",
  "host": "${PGHOST}",
  "port": ${PGPORT},
  "database": "${PGDATABASE}",
  "authUsername": "${PGUSER}",
  "authSecret": {
    "@type": "EnvironmentVariable",
    "id": "PGPASSWORD"
  },
  "useTls": false,
  "allowInvalidCerts": false,
  "poolMaxConnections": 10,
  "poolRecyclingMethod": "fast",
  "timeout": "15s"
}
EOF

exec /usr/local/bin/stalwart --config /etc/stalwart/config.json