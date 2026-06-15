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

### Stalwart Metrics group

All monitors scrape `mail.solace.onl/metrics/prometheus` (URL hidden on the status page).
Enable Prometheus in the Stalwart WebUI and set `prometheus_user` / `prometheus_password` on Gatus.

| Monitor | What it checks |
|---------|----------------|
| `stalwart-exporter` | Prometheus endpoint alive |
| `stalwart-smtp-receive` | Inbound SMTP connections, request timing, IPREV |
| `stalwart-smtp-antispam` | SPF pass/temp/perm counters |
| `stalwart-delivery` | Outbound delivery connection gauge |
| `stalwart-imap` | IMAP connections and session starts |
| `stalwart-jmap-http` | HTTP/JMAP connection and request metrics |
| `stalwart-store` | Store iteration, user/domain counts |
| `stalwart-error-counters` | Store errors, SMTP concurrency limit, calendar expansion errors |

These verify that metric families are being exported. Counter **values** are cumulative —
use Grafana ([dashboard #23498](https://grafana.com/grafana/dashboards/23498-service-stalwart/))
for rate graphs and threshold alerts on rising error counts.

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
