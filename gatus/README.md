# Gatus status page (Solace)

[Gatus](https://github.com/TwiN/gatus) monitors Solace and mail from Railway. Deploy as a
**separate Railway service** (root directory `gatus`, volume at `/data`).

## Railway variables

| Variable | Required | Purpose |
|----------|----------|---------|
| `PORT` | auto | Set by Railway |
| `prometheus_user` | yes | Stalwart Prometheus basic auth (WebUI) |
| `prometheus_password` | yes | Stalwart Prometheus basic auth |
| `SLOT_MANAGER_TOKEN` | yes | Bearer token for `/slot-manager/status` |

## Monitors

| Group | Endpoint | What it proves |
|-------|----------|----------------|
| Application | `solace.onl` | Web frontend |
| Application | `api.solace.onl/api/health` | Backend API |
| Mail | `mail.solace.onl/jmap/session` | End-to-end mail path |
| Mail | `mail.solace.onl/slot-manager/status` | Blue/green tunnels |
| Mail | `mail.solace.onl/metrics/prometheus` | Stalwart send/receive metrics |

The metrics monitor checks `queue_count`, `smtp_active_connections`, and
`delivery_active_connections`. Enable Prometheus in the Stalwart WebUI
(Settings → Telemetry → Metrics → Prometheus).

## Local test

```bash
cd gatus
docker build -t solace-gatus .
docker run --rm -p 8080:8080 \
  -e PORT=8080 \
  -e prometheus_user=prometheus \
  -e prometheus_password=secret \
  -e SLOT_MANAGER_TOKEN=your-token \
  solace-gatus
```

## Optional

- **Status page auth:** `GATUS_ADMIN_USERNAME` / `GATUS_ADMIN_PASSWORD`
- **VPS SSH monitor:** see `vps/gatus-monitor.sh` and `config.vps-ssh.endpoints.yaml`
