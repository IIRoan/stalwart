# Stalwart on Railway (Solace mail)

Stalwart mail server runs on [Railway](https://railway.app). A public VPS
(`mail.solace.onl` / `193.180.211.139`) owns the MX, TLS certificates, and
inbound ports. Railway containers connect **outbound** to the VPS over frp — no
inbound connections to Railway are required.

## System overview

```mermaid
flowchart TB
    subgraph Internet
        MTA[Remote MTAs / mail clients]
        RCPT[Recipient mail servers]
    end

    subgraph VPS["VPS (193.180.211.139)"]
        HAP[HAProxy<br/>:25 :465 :993 :443]
        FRPS[frps :7000]
        PF[Postfix<br/>127.0.0.1:2525]
        FREL[frpc-relay<br/>STCP proxy]
        SLOT[stalwart-slot-manager<br/>stalwart-slot-watcher]
        HAP --> FRPS
        FREL --> PF
        PF --> RCPT
        SLOT --> HAP
    end

    subgraph Railway["Railway container"]
        SW[Stalwart<br/>:25 :587 :993 :8080]
        FRPC[frpc<br/>TCP proxies]
        REL[frpc relay visitor<br/>STCP :2525]
        HEALTH[Health server<br/>:8090]
        SW --> REL
        FRPC --> SW
    end

    MTA --> HAP
    FRPS <-->|"TCP tunnels<br/>PROXY v2 on mail"| FRPC
    FRPS <-->|"STCP tunnel"| REL
    REL -->|"SMTP + SASL"| FREL
    SW -->|"JMAP / SMTP submit"| SW
```

## Inbound mail (Internet → Stalwart)

```mermaid
sequenceDiagram
    participant C as Mail client / MTA
    participant H as HAProxy (VPS)
    participant F as frps → frpc tunnel
    participant S as Stalwart (Railway)

    C->>H: SMTP :25 / IMAPS :993 / HTTPS :443
    Note over H: TLS termination on :443<br/>PROXY protocol v2 on mail ports
    H->>F: Forward to localhost frps port<br/>(blue or green slot)
    F->>S: frpc TCP proxy → Stalwart listener
    S-->>C: Mail delivery / JMAP / IMAP
```

HAProxy routes to **blue** or **green** frps ports based on
`/etc/haproxy/stalwart-active-slot`. Only one slot receives traffic at a time.
The VPS slot watcher promotes a slot when its frp tunnel is healthy.

| Slot  | SMTP frps port | HTTPS frps port |
|-------|----------------|-----------------|
| blue  | 10025          | 10443           |
| green | 11025          | 11443           |

Railway's `FRPC_SLOT=auto` picks the **inactive** side so a new deploy tunnels
up before the VPS switches traffic.

## Outbound mail (Solace / JMAP → Internet)

Railway **blocks outbound SMTP ports** (25, 587, 465). Outbound mail uses an
frp **STCP** tunnel instead of connecting to the VPS public IP.

```mermaid
sequenceDiagram
    participant App as Solace / JMAP client
    participant S as Stalwart (Railway)
    participant V as STCP visitor :2525
    participant F as frps / frpc-relay (VPS)
    participant P as Postfix :2525
    participant R as Recipient (e.g. Proton)

    App->>S: EmailSubmission/set (JMAP)
    S->>V: SMTP + STARTTLS + SASL<br/>to container-ip:2525
    Note over S,V: Stalwart rejects 127.0.0.1<br/>as a relay target
    V->>F: STCP through frps :7000
    F->>P: localhost:2525
    P->>R: Deliver from VPS public IP
```

At container startup, `railway-entrypoint.sh`:

1. Starts the STCP visitor on `0.0.0.0:2525`
2. Detects the container private IP
3. Updates the Stalwart `relay-vps` MtaRoute via `stalwart-cli`
4. Reloads Stalwart settings

See [vps/OUTBOUND_RELAY.md](vps/OUTBOUND_RELAY.md) for credentials and
troubleshooting.

## Blue/green deploys

```mermaid
sequenceDiagram
    participant R as Railway new container
    participant H as Health :8090
    participant V as VPS slot-manager
    participant X as HAProxy

    R->>R: Start Stalwart + frpc (inactive slot)
    H-->>R: 503 until all checks pass
    R->>R: smtp + https proxies online, relay up
    H-->>R: 200 OK
    Note over R: Railway marks deploy healthy
    R->>V: POST /activate {slot}
    V->>X: Gradual switch + drain old slot
    Note over X: slot-watcher only fails over if active tunnel dies
```

Railway returns **503** on `/healthz/ready` until Stalwart, frpc mail proxies,
and the outbound relay are all running. Only then does Railway mark the deploy
healthy and the container requests VPS promotion via `POST /slot-manager/activate`.

The VPS `stalwart-slot-watcher` is **failover-only** — it promotes the other
slot when the active tunnel goes down, not when both slots are up during overlap.

## Repository layout

| Path | Purpose |
|------|---------|
| `railway-entrypoint.sh` | Stalwart + health server + frpc + relay setup |
| `railway.toml` | Railway healthcheck config |
| `Dockerfile` | Stalwart image + frpc + stalwart-cli |
| `vps/haproxy.cfg` | Public edge proxy (install on VPS) |
| `vps/frps.toml` | frp server for inbound tunnels |
| `vps/frpc-relay.toml` | STCP proxy for outbound Postfix |
| `vps/postfix-*.cf` | Outbound relay Postfix config |
| `vps/stalwart-slot-*.py` | Slot manager API and auto-promotion |
| `VPS_SERVICES.md` | VPS service reference and ops commands |

## Railway environment variables

| Variable | Required | Purpose |
|----------|----------|---------|
| `FRPS_ADDR` | yes | VPS IP or hostname |
| `FRPC_TOKEN` | yes | frp auth token (must match `vps/frps.toml`) |
| `STALWART_ADMIN_TOKEN` | yes | Updates relay route at startup |
| `SLOT_MANAGER_TOKEN` | yes | Promotes this container's slot after health gate opens |
| `PORT` | yes | Set to `8090` — Railway healthcheck port |
| `PGHOST`, `PGPASSWORD`, etc. | yes | PostgreSQL (Railway plugin) |
| `FRPC_SLOT` | no | `blue`, `green`, or `auto` (default) |
| `STALWART_HTTP_PORT` | no | Stalwart HTTP/JMAP port (default `8080`) |
| `RELAY_ROUTE_ID` | no | Stalwart MtaRoute id (default `ivnbzc1aaba9`) |
| `RELAY_BIND_ADDR` | no | Override container private IP for relay route |

Relay route targets and Stalwart management API calls both use the container's
**private IP** on ports 2525 / 8080. Loopback (`127.0.0.1`) is not reachable
for HTTP inside the Railway container. The service has no public URL;
`mail.solace.onl` is the VPS edge only.

## Healthchecks

Railway probes `GET /healthz/ready` on `PORT` (8090) **before** marking a deploy
healthy. The endpoint returns **503** until all of the following are true:

- Stalwart process alive and listening on `:25` and `:8080`
- frpc process alive with `smtp-{slot}` and `https-{slot}` proxies online
- Outbound relay STCP visitor listening on `:2525`

Stalwart's real HTTP listener on `:8080` only works through HAProxy with PROXY
protocol, so it cannot be used as the Railway healthcheck target directly.

## VPS quick start

Copy configs from `vps/` to the VPS, enable services, and open firewall ports
22, 25, 465, 587, 993, 443, 7000. Full service reference:
[VPS_SERVICES.md](VPS_SERVICES.md).
