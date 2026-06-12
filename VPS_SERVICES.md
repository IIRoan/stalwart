# VPS Services - Stalwart Mail Server

This documents all proxy/relay services running on the public VPS
(`193.180.211.139`) that handle inbound traffic for the Stalwart mail
server deployed on Railway.

## Architecture Overview

### Inbound (public edge)

Railway cannot be the public MX. The VPS owns the public mail identity
(MX, A/AAAA, PTR, ports 25/465/587/993/443) and forwards traffic to
Stalwart over an outbound frp TCP tunnel.

```
Internet MTAs / mail clients
        |
        v
VPS public IP (mail.solace.onl)
  HAProxy :25, :465, :587, :993, :443
        |
        v
frps localhost ports (blue/green slots)
        |
        v
frpc TCP tunnel (Railway dials out to frps:7000)
        |
        v
Railway Stalwart
```

HAProxy sends PROXY protocol v2 to frps. Railway frpc enables
`transport.proxyProtocolVersion = "v2"` on mail proxies (SMTP/IMAP) so
Stalwart sees the real client IP for SPF, DMARC, rate limiting, and
logging. HTTP/JMAP proxies omit PROXY protocol because Stalwart's HTTP
listener rejects it.

### Outbound (VPS relay via STCP)

Railway blocks direct outbound SMTP connections. Outbound mail therefore
uses Stalwart's documented relay-route feature over a private frp STCP
tunnel, not a public SMTP hop from Railway to the VPS.

```
Stalwart (Railway)
    |
    | relay route -> relay.internal:2525
    v
frpc STCP visitor (single frpc process, binds 0.0.0.0:2525 in Railway container)
    |
    v
frps STCP proxy (VPS frpc-relay service)
    |
    v
Postfix on 127.0.0.1:2525 (SASL-authenticated submission relay)
    |
    v
Internet (from VPS public IP / PTR)
```

At container startup, `railway-entrypoint.sh` maps `relay.internal` to the
container private IP in `/etc/hosts`, runs the STCP visitor in the same
`frpc` process, and uses `stalwart-cli` to point the relay route at
`relay.internal:2525`. Stalwart refuses loopback relay targets, so
`127.0.0.1` cannot be used.

Required Railway environment variables:

| Variable | Purpose |
|----------|---------|
| `STALWART_ADMIN_TOKEN` | API token for relay-route updates at startup |
| `RELAY_ROUTE_ID` | MtaRoute id (default: `ivnbzc1aaba9`) |
| `FRPS_ADDR` / `FRPC_TOKEN` | frp control plane |
| `SLOT_MANAGER_TOKEN` | Blue/green slot activation |

## Services

All systemd services are **enabled** (`systemctl enable`) and will start
automatically on boot.

### 1. HAProxy

- **Role:** Public-facing TCP/HTTP reverse proxy with TLS termination.
- **Ports:** 25 (SMTP), 465 (SMTPS), 993 (IMAPS), 443 (HTTPS/WebAdmin/JMAP)
- **Config path (repo):** `vps/haproxy.cfg`
- **Config path (VPS):** `/etc/haproxy/haproxy.cfg`
- **Admin socket:** `/run/haproxy/admin.sock`
- **Status:** `systemctl status haproxy`

HAProxy routes traffic to blue or green slots based on
`/etc/haproxy/stalwart-active-slot`. It uses **PROXY protocol v2**
for all Railway backends so Stalwart sees the real client IP.

### 2. frps (FRP Server)

- **Role:** Accepts inbound FRP tunnels from Railway containers.
- **Port:** 7000 (control), plus dynamic proxy ports for each tunnel.
- **Config path (repo):** `vps/frps.toml`
- **Config path (VPS):** `/etc/frp/frps.toml`
- **Status:** `systemctl status frps`

The `allowPorts` whitelist only permits the exact ports used by the
blue/green FRP proxies (e.g. `10025`, `11025`, `10443`, `11443`, etc.).

### 3. frpc-relay (Outbound STCP Proxy)

- **Role:** STCP proxy that exposes Postfix to authorized Railway visitors.
- **Config path (repo):** `vps/frpc-relay.toml`
- **Config path (VPS):** `/etc/frp/frpc-relay.toml`
- **Status:** `systemctl status frpc-relay`

Forwards STCP connections to `127.0.0.1:2525` where Postfix listens for
authenticated relay traffic from Railway.

### 4. Postfix (Outbound Relay)

- **Role:** Authenticated SMTP submission relay for Railway-originated mail.
- **Listen:** `127.0.0.1:2525` only (not public)
- **Config paths (repo):** `vps/postfix-main.cf`, `vps/postfix-master.cf`
- **SASL user:** `relay-client@mail.solace.onl`
- **Status:** `systemctl status postfix`

### 5. stalwart-slot-manager

- **Role:** Lightweight Python HTTP API that manages the active blue/green
  slot file and triggers HAProxy runtime reconfiguration.
- **Port:** 127.0.0.1:9081 (exposed publicly via HAProxy `/slot-manager/`)
- **Config path (repo):** `vps/stalwart-slot-manager.py`
- **Status:** `systemctl status stalwart-slot-manager`

## Quick Commands

```bash
# Check all services
systemctl status haproxy frps frpc-relay postfix stalwart-slot-manager

# Reload HAProxy after config changes
sudo haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl reload haproxy

# Reload Postfix after config changes
sudo postfix check && sudo systemctl reload postfix

# View active slot
cat /etc/haproxy/stalwart-active-slot

# Switch slot manually
sudo /usr/local/bin/stalwart-switch-slot.sh blue
sudo /usr/local/bin/stalwart-switch-slot.sh green
```

## Long-term recommendation

If deliverability and operational simplicity matter more than keeping
Stalwart on Railway, move the full Stalwart instance to the VPS. That
removes the tunnel as a failure domain and aligns SMTP banner, EHLO,
PTR, MX, and listening ports on one machine.
