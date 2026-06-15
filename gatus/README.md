# Gatus status page (Solace)

[Gatus](https://github.com/TwiN/gatus) monitors Solace (`solace.onl`, `api.solace.onl`) and the
mail stack (`mail.solace.onl`) from Railway. Deploy as a **separate Railway service** in this
repo — do not reuse the Stalwart mail service.

## Railway setup

1. In the Solace Railway project, **New Service → GitHub Repo** → `IIRoan/stalwart`.
2. Set **Root Directory** to `gatus` (required — otherwise Railway uses the Stalwart
   `railway.toml` at repo root and healthchecks `/healthz/ready` instead of Gatus `/health`).
3. Attach a **volume** mounted at `/data` (SQLite history).
4. Set **custom domain** `status.solace.onl`.
5. Under **Settings → Deploy → Healthcheck Path**, set `/health` (not `/healthz/ready`).
6. Configure variables (see [.env.example](.env.example)):

| Variable | Required | Purpose |
|----------|----------|---------|
| `PORT` | yes | Railway sets this; Gatus listens on `${PORT}` |
| `SLOT_MANAGER_TOKEN` | no | Bearer token for `GET /slot-manager/status` (enables blue/green monitor) |
| `GATUS_ADMIN_USERNAME` | no | HTTP basic auth on the status page |
| `GATUS_ADMIN_PASSWORD` | no | Pair with username above |
| `SLACK_WEBHOOK_URL` | no | Alerts (uncomment `alerting:` in config too) |
| `VPS_MONITOR_SSH_*` | no | VPS internal checks via SSH (see below) |

`GATUS_CONFIG_YAML` overrides the baked-in config on every boot if you need full control.

## Default monitors

| Group | Endpoint | What it proves |
|-------|----------|----------------|
| Application | `solace.onl` | Web frontend |
| Application | `api.solace.onl/api/health` | Backend API |
| Mail | `mail.solace.onl/jmap/session` | HAProxy → frp → Stalwart → DB |
| Mail | `mail.solace.onl/slot-manager/active` | VPS slot API |
| Mail | `mail.solace.onl/slot-manager/status` | Blue/green tunnel occupancy |
| Mail | TCP `:25`, `:993`, STARTTLS `:587` | Public mail ports |

The JMAP check is the most important mail probe — it exercises the same path remote clients use.

## VPS internal monitoring (optional)

Public probes cannot see localhost services (frps dashboard, Postfix queue, systemd). For that:

1. Install the health script on the VPS:

   ```bash
   sudo install -m 0755 vps/gatus-monitor.sh /usr/local/bin/gatus-monitor.sh
   ```

2. Create a `gatus-monitor` user with **no shell**, key-only auth, and `authorized_keys`:

   ```
   command="/usr/local/bin/gatus-monitor.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA...
   ```

3. On the Gatus Railway service, set:

   ```
   VPS_MONITOR_SSH_USERNAME=gatus-monitor
   VPS_MONITOR_SSH_PRIVATE_KEY_B64=<base64-encoded private key>
   ```

The entrypoint decodes the key and appends a `vps-health` SSH endpoint that expects
`[BODY].status == healthy`. See [config.vps-ssh.endpoints.yaml](config.vps-ssh.endpoints.yaml).

## Image layout

Adapted from [gatus-railway](https://github.com/sahilrupani/gatus-railway) patterns:

- Multi-stage build: `twinproduction/gatus:stable` binary on Alpine 3.20
- Entrypoint writes config to `/data/config.yaml` (volume-backed)
- Optional basic-auth injection at boot (bcrypt via `htpasswd`)
- Optional VPS SSH endpoint injection when credentials are present

Unlike the template repo, the default config targets Solace infrastructure instead of demo URLs.

## Local test

```bash
cd gatus
docker build -t solace-gatus .
docker run --rm -p 8080:8080 \
  -e PORT=8080 \
  -e SLOT_MANAGER_TOKEN=your-token \
  solace-gatus
```

Open http://localhost:8080

## Metrics

`metrics: true` exposes Prometheus format at `/metrics` on the Gatus service itself.
Stalwart's own metrics (`/metrics/prometheus`) are a separate concern — enable in Stalwart
telemetry settings if you want mail workload graphs in Grafana.
