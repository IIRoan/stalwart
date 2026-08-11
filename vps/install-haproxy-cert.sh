#!/usr/bin/env bash
# Install a PEM (private key + leaf + chain) for HAProxy TLS on :443.
# Usage:
#   sudo ./vps/install-haproxy-cert.sh /path/to/mail.solace.onl.pem
set -euo pipefail

PEM_SRC="${1:-}"
PEM_DST="${HAPROXY_CERT_PATH:-/etc/haproxy/certs/mail.solace.onl.pem}"

if [[ -z "$PEM_SRC" || ! -f "$PEM_SRC" ]]; then
  echo "usage: $0 /path/to/mail.solace.onl.pem" >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "run as root (sudo)" >&2
  exit 1
fi

openssl x509 -in "$PEM_SRC" -noout -dates -subject >/dev/null
openssl pkey -in "$PEM_SRC" -noout -check >/dev/null

install -d -m 0750 /etc/haproxy/certs
install -m 0640 "$PEM_SRC" "$PEM_DST"
chown root:haproxy "$PEM_DST" 2>/dev/null || chown root:root "$PEM_DST"

haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl reload haproxy

echo "Installed $PEM_DST and reloaded haproxy."
openssl x509 -in "$PEM_DST" -noout -dates -subject -ext subjectAltName
