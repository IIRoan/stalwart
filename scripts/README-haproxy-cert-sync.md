# HAProxy TLS cert sync

HAProxy on the VPS terminates `https://mail.solace.onl` with:

```text
/etc/haproxy/certs/mail.solace.onl.pem
```

Stalwart renews certificates on its own (ACME `Dns01` + Cloudflare). That
renewal does **not** update the HAProxy PEM. `scripts/sync-haproxy-cert.py`
copies the newest Stalwart cert+key onto the VPS and reloads HAProxy.

## GitHub Action

Workflow: [`.github/workflows/sync-haproxy-cert.yml`](../.github/workflows/sync-haproxy-cert.yml)

| Trigger | Behavior |
|---------|----------|
| Cron (Mondays 06:17 UTC) | Sync only if live HTTPS cert expires within **14 days** |
| `workflow_dispatch` on `main` | Defaults to `--force` (sync now) |

### Use Environment secrets (not repository secrets)

Create a GitHub Environment named **`mail-vps`**:

1. Repo → **Settings → Environments → New environment** → `mail-vps`
2. **Deployment branches**: selected branches → allow only `main`
3. (Optional but recommended) enable **Required reviewers** for manual runs
4. Add these **Environment** secrets on `mail-vps` (not Repository secrets):

| Secret | Purpose |
|--------|---------|
| `STALWART_DATABASE_URL` | Public Postgres URL for the Stalwart store (`DATABASE_PUBLIC_URL` from Railway `Postgres-stalwart`) |
| `VPS_SSH_PRIVATE_KEY` | Private key that can SSH to the mail VPS and install the PEM |

Optional Environment secrets:

| Secret | Default |
|--------|---------|
| `VPS_SSH_HOST` | `mail.solace.onl` |
| `VPS_SSH_USER` | `root` |
| `VPS_SSH_PORT` | `22` |

**Why Environment secrets?** Repository secrets are available to any workflow on any branch that references them. Environment secrets for `mail-vps` are only injected when the job uses `environment: mail-vps`, and that Environment is restricted to `main`. The workflow also refuses forks, non-`main` refs, and has no `pull_request` trigger.

## Manual run

```bash
export STALWART_DATABASE_URL='postgresql://…'
export VPS_SSH_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)"
export VPS_SSH_HOST=193.180.211.139
export VPS_SSH_USER=root

pip install 'psycopg[binary]'
python3 scripts/sync-haproxy-cert.py --force
```

Dry-run (export only):

```bash
python3 scripts/sync-haproxy-cert.py --force --dry-run --output /tmp/mail.solace.onl.pem
```

Check live expiry only:

```bash
python3 scripts/sync-haproxy-cert.py --check-only
```

## One-shot install on the VPS

If you already have a PEM locally:

```bash
sudo ./vps/install-haproxy-cert.sh /path/to/mail.solace.onl.pem
```
