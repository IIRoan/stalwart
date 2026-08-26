#!/usr/bin/env bash
# Bootstrap a least-privilege SSH user for the GitHub HAProxy cert-sync Action.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

USER_NAME="${GH_CERT_SYNC_USER:-gh-cert-sync}"
HOME_DIR="/home/${USER_NAME}"
SSH_DIR="${HOME_DIR}/.ssh"
KEY_PATH="${SSH_DIR}/github_haproxy_cert"
AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"
SUDOERS_FILE="/etc/sudoers.d/${USER_NAME}"
PRIVATE_KEY_OUT="/root/${USER_NAME}-github-haproxy-cert.pem"
CERT_DIR="/etc/haproxy/certs"
INSTALLER="/usr/local/bin/install-haproxy-cert.sh"

echo "==> Creating system user ${USER_NAME}"
if ! id -u "${USER_NAME}" >/dev/null 2>&1; then
  adduser --system --group --home "${HOME_DIR}" --shell /bin/bash "${USER_NAME}"
else
  echo "    user already exists"
fi

install -d -m 0750 -o root -g haproxy "${CERT_DIR}" 2>/dev/null \
  || install -d -m 0750 -o root -g root "${CERT_DIR}"

echo "==> Installing HAProxy cert installer at ${INSTALLER}"
cat > "${INSTALLER}" <<'EOF'
#!/usr/bin/env bash
# Install a PEM staged at /tmp/mail.solace.onl.pem and reload HAProxy.
set -euo pipefail
PEM_SRC="${1:-/tmp/mail.solace.onl.pem}"
PEM_DST="${HAPROXY_CERT_PATH:-/etc/haproxy/certs/mail.solace.onl.pem}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi
if [[ ! -f "$PEM_SRC" ]]; then
  echo "missing PEM: $PEM_SRC" >&2
  exit 1
fi

openssl x509 -in "$PEM_SRC" -noout -dates -subject >/dev/null
openssl pkey -in "$PEM_SRC" -noout -check >/dev/null

install -d -m 0750 /etc/haproxy/certs
install -m 0640 "$PEM_SRC" "$PEM_DST"
if getent group haproxy >/dev/null 2>&1; then
  chown root:haproxy "$PEM_DST"
else
  chown root:root "$PEM_DST"
fi

haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl reload haproxy
openssl x509 -in "$PEM_DST" -noout -dates -subject -ext subjectAltName
rm -f "$PEM_SRC"
EOF
chmod 0755 "${INSTALLER}"

echo "==> Preparing SSH directory"
install -d -m 0700 -o "${USER_NAME}" -g "${USER_NAME}" "${SSH_DIR}"

if [[ -f "${KEY_PATH}" ]]; then
  echo "    existing key at ${KEY_PATH} — rotating"
  rm -f "${KEY_PATH}" "${KEY_PATH}.pub"
fi

echo "==> Generating ed25519 keypair"
ssh-keygen -t ed25519 -a 64 -C "github-haproxy-cert-sync@$(hostname -f 2>/dev/null || hostname)" \
  -f "${KEY_PATH}" -N "" >/dev/null

chown "${USER_NAME}:${USER_NAME}" "${KEY_PATH}" "${KEY_PATH}.pub"
chmod 0600 "${KEY_PATH}"
chmod 0644 "${KEY_PATH}.pub"

PUB_KEY="$(cat "${KEY_PATH}.pub")"
# Allow interactive/scp for the Action (scp + ssh bash -s). Still no agent/X11/port fwd.
cat > "${AUTHORIZED_KEYS}" <<EOF
no-port-forwarding,no-X11-forwarding,no-agent-forwarding ${PUB_KEY}
EOF
chown "${USER_NAME}:${USER_NAME}" "${AUTHORIZED_KEYS}"
chmod 0600 "${AUTHORIZED_KEYS}"

echo "==> Writing passwordless sudoers (cert install + haproxy reload only)"
cat > "${SUDOERS_FILE}" <<EOF
# Managed by setup-gh-cert-sync-user.sh — GitHub Action HAProxy cert sync
Cmnd_Alias GH_CERT_SYNC = ${INSTALLER}, /usr/bin/install, /usr/bin/openssl, /usr/sbin/haproxy, /bin/systemctl reload haproxy, /usr/bin/systemctl reload haproxy, /bin/chown, /usr/bin/chown, /bin/rm, /usr/bin/rm
${USER_NAME} ALL=(root) NOPASSWD: GH_CERT_SYNC
EOF
chmod 0440 "${SUDOERS_FILE}"
visudo -cf "${SUDOERS_FILE}"

# Let the user stage the PEM in /tmp (Action scp target).
chmod 1777 /tmp

install -m 0600 "${KEY_PATH}" "${PRIVATE_KEY_OUT}"
chown root:root "${PRIVATE_KEY_OUT}"

echo
echo "================================================================"
echo " GitHub Environment secrets (mail-vps)"
echo "================================================================"
echo " VPS_SSH_USER = ${USER_NAME}"
echo " VPS_SSH_HOST = $(hostname -f 2>/dev/null || hostname)   # or 193.180.211.139 / mail.solace.onl"
echo " VPS_SSH_PRIVATE_KEY = (paste everything between the lines below)"
echo "----------------------------------------------------------------"
cat "${PRIVATE_KEY_OUT}"
echo "----------------------------------------------------------------"
echo
echo "Private key also saved at: ${PRIVATE_KEY_OUT}"
echo "After adding the GitHub secret, delete it:"
echo "  shred -u ${PRIVATE_KEY_OUT} 2>/dev/null || rm -f ${PRIVATE_KEY_OUT}"
echo
echo "Smoke test from your laptop (after saving the private key locally):"
echo "  ssh -i /path/to/private_key ${USER_NAME}@mail.solace.onl 'sudo -n /usr/sbin/haproxy -c -f /etc/haproxy/haproxy.cfg'"
echo "================================================================"
