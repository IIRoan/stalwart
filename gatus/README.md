# Gatus status page (Solace)

[Gatus](https://github.com/TwiN/gatus) monitors Solace and mail from Railway. The image is
built from [CarmJos/gatus](https://github.com/CarmJos/gatus) so each endpoint can show a
**90-day** uptime bar (GitHub-style) instead of a short second/minute window. Deploy as a
**separate Railway service** (root directory `gatus`, volume at `/data`).

UI tokens match Solace light (`#f9f9f9` / warm brown primary) and dark (`#111` / warm cream
primary). Theme follows the browser `prefers-color-scheme` (and the in-page toggle cookie).

## Railway variables

| Variable | Required | Purpose |
|----------|----------|---------|
| `PORT` | auto | Public listen port (proxy + Gatus) |
| `prometheus_user` | yes | Stalwart Prometheus basic auth (WebUI) |
| `prometheus_password` | yes | Stalwart Prometheus basic auth |
| `SLOT_MANAGER_TOKEN` | yes | Bearer token for `/slot-manager/status` |
| `DISCORD_WEBHOOK_URL` | yes | Discord webhook for Gatus downtime and scrape failures |

## Alerting (two layers)

| Layer | Watches | Notifies |
|-------|---------|----------|
| **Gatus** | HTTP endpoints + Prometheus scrape shape | Discord (`DISCORD_WEBHOOK_URL`) after 2 failures / 2 recoveries |
| **Stalwart Enterprise Alerts** | Live metric expressions (S3/store errors, SMTP concurrency, queue backlog, …) | Email to `admin@solace.onl` |

Do not point a Stalwart WebHook at `DISCORD_WEBHOOK_URL`. Discord expects its own JSON body; Stalwart event payloads are a different shape. Discord for this stack is Gatus-only.

## Monitors

| Group | Endpoint | What it proves |
|-------|----------|----------------|
| Application | `solace.onl` | Web frontend |
| Application | `api.solace.onl/api/health` | Backend API |
| Mail | `mail.solace.onl/jmap/session` | End-to-end mail path |
| Mail | `mail.solace.onl/slot-manager/status` | Blue/green tunnels |

### Stalwart Metrics group

All monitors scrape `mail.solace.onl/slot-manager/metrics/prometheus` (URL hidden on the status page).
The slot manager proxies to the **active** Railway slot directly, so deploy cutover does not
round-robin scrapes to a warming container. Conditions use gauges and `# HELP`/`# TYPE` lines
instead of event counters (e.g. `smtp_iprev_pass`) that disappear until traffic hits the new slot.
Enable Prometheus in the Stalwart WebUI and set `prometheus_user` / `prometheus_password` on Gatus.

| Monitor | What it checks |
|---------|----------------|
| `stalwart-exporter` | Prometheus endpoint alive |
| `stalwart-smtp-receive` | Inbound SMTP gauge + request-time histogram registered |
| `stalwart-smtp-antispam` | SMTP + delivery gauge metrics registered |
| `stalwart-delivery` | Outbound delivery connection gauge |
| `stalwart-imap` | IMAP active connection gauge |
| `stalwart-jmap-http` | HTTP/JMAP connection and request metrics |
| `stalwart-store` | User/domain count gauges |
| `stalwart-error-counters` | Store I/O present; fails if unexpected/S3/SMTP-concurrency/calendar error counters appear |

These verify that metric families are being exported. Counter **values** and threshold
expressions are handled by **Stalwart Enterprise Alerts** (email). Gatus Discord-alerts if
those error counters appear on the scrape (`stalwart-error-counters`).
Grafana ([dashboard #23498](https://grafana.com/grafana/dashboards/23498-service-stalwart/))
remains useful for rate graphs.

## Local test

```bash
cd gatus
docker build -t solace-gatus .
docker run --rm -p 8080:8080 \
  -e PORT=8080 \
  -e prometheus_user=prometheus \
  -e prometheus_password=secret \
  -e SLOT_MANAGER_TOKEN=your-token \
  -e DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/... \
  solace-gatus
```

## Optional

- **Status page auth:** `GATUS_ADMIN_USERNAME` / `GATUS_ADMIN_PASSWORD`
- **VPS SSH monitor:** set `VPS_MONITOR_SSH_USERNAME` and `VPS_MONITOR_SSH_PRIVATE_KEY` (or `_B64`);
  install `vps/gatus-monitor.sh` on the VPS and restrict the SSH user with `authorized_keys command=`
