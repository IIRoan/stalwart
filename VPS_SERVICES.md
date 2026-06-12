# VPS Services - Stalwart Mail Server

This documents all proxy/relay services running on the public VPS
(`193.180.211.139`) that handle inbound traffic for the Stalwart mail
server deployed on Railway.

## Architecture Overview

```
Internet
    |
    | SMTP (:25)    HTTPS (:443)
    |     |             |
    v     v             v
 +-----------------------------+
 |  HAProxy (TLS termination)  |
 +-----------------------------+
    |         |         |
    |   Proxy   Protocol + TCP
    |         |         |
    v         v         v
 +-------+ +-------+ +-------+
 | frps  | | frps  | | frps  |  <- FRP server (port 7000)
 | 10025 | | 10443 | | 18080 |     for blue/green slots
 +-------+ +-------+ +-------+
    |         |         |
    +---------+---------+
              |
         FRP tunnels
              |
    +---------+---------+
    |                   |
    v                   v
+----------+      +----------+
| Railway  |      | Railway  |
| (green)  |      | (blue)   |
+----------+      +----------+
```

Outbound mail relay uses a separate FRP **STCP** tunnel:

```
Stalwart (Railway)
    |
    | outbound SMTP via 127.0.0.1:12587
    | (frpc STCP visitor in Railway container)
    v
 frps (STCP proxy on VPS port 7000)
    |
    v
 frpc-relay (STCP visitor on VPS, localhost:2525)
    |
    v
 Postfix (localhost:25)
```

## Services

All systemd services are **enabled** (`systemctl enable`) and will start
automatically on boot.

### 1. HAProxy

- **Role:** Public-facing TCP/HTTP reverse proxy with TLS termination.
- **Ports:** 25 (SMTP), 443 (HTTPS/WebAdmin/JMAP)
- **Config path (repo):** `vps/haproxy.cfg`
- **Config path (VPS):** `/etc/haproxy/haproxy.cfg`
- **Admin socket:** `/run/haproxy/admin.sock`
- **Status:** `systemctl status haproxy`
- **Boot enabled:** Yes (`apt install haproxy` enables it by default)

HAProxy routes traffic to blue or green slots based on
`/etc/haproxy/stalwart-active-slot`. It uses **PROXY protocol v2**
for all Railway backends so Stalwart sees the real client IP.

### 2. frps (FRP Server)

- **Role:** Accepts inbound FRP tunnels from Railway containers.
- **Port:** 7000 (control), plus dynamic proxy ports for each tunnel.
- **Config path (repo):** `vps/frps.toml`
- **Config path (VPS):** `/etc/frp/frps.toml`
- **Service file (VPS):** `/etc/systemd/system/frps.service`
- **Status:** `systemctl status frps`
- **Boot enabled:** Yes

The `allowPorts` whitelist only permits the exact ports used by the
blue/green FRP proxies (e.g. `10025`, `11025`, `10443`, `11443`, etc.)
and the STCP relay proxy.

### 3. frpc-relay (Outbound STCP Visitor)

- **Role:** Local FRP client that exposes the outbound mail relay tunnel
  to Postfix on `127.0.0.1:2525`.
- **Config path (repo):** `vps/frpc-relay.toml`
- **Config path (VPS):** `/etc/frp/frpc-relay.toml`
- **Service file (repo):** `vps/frpc-relay.service`
- **Service file (VPS):** `/etc/systemd/system/frpc-relay.service`
- **Status:** `systemctl status frpc-relay`
- **Boot enabled:** Yes

Depends on `frps.service` (After + Requires).

### 4. stalwart-slot-manager

- **Role:** Lightweight Python HTTP API that manages the active blue/green
  slot file and triggers HAProxy runtime reconfiguration.
- **Port:** 127.0.0.1:9081
- **Config path (repo):** `vps/stalwart-slot-manager.py`
- **Config path (VPS):** `/usr/local/bin/stalwart-slot-manager.py`
- **Service file (repo):** `vps/stalwart-slot-manager.service`
- **Service file (VPS):** `/etc/systemd/system/stalwart-slot-manager.service`
- **Status:** `systemctl status stalwart-slot-manager`
- **Boot enabled:** Yes

Environment variables are loaded from `/etc/stalwart-slot-manager.env`.

## Service Installation Summary

| Service | Repo file | VPS path | Boot enabled |
|---------|-----------|----------|--------------|
| HAProxy | `vps/haproxy.cfg` | `/etc/haproxy/haproxy.cfg` | Yes |
| frps | `vps/frps.toml` | `/etc/frp/frps.toml` | Yes |
| frps | — | `/etc/systemd/system/frps.service` | Yes |
| frpc-relay | `vps/frpc-relay.toml` | `/etc/frp/frpc-relay.toml` | Yes |
| frpc-relay | `vps/frpc-relay.service` | `/etc/systemd/system/frpc-relay.service` | Yes |
| slot-manager | `vps/stalwart-slot-manager.py` | `/usr/local/bin/stalwart-slot-manager.py` | Yes |
| slot-manager | `vps/stalwart-slot-manager.service` | `/etc/systemd/system/stalwart-slot-manager.service` | Yes |

## Quick Commands

```bash
# Check all services
systemctl status haproxy frps frpc-relay stalwart-slot-manager

# Reload HAProxy after config changes
sudo haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl reload haproxy

# Restart slot manager
sudo systemctl restart stalwart-slot-manager

# View active slot
cat /etc/haproxy/stalwart-active-slot

# Switch slot manually
sudo /usr/local/bin/stalwart-switch-slot.sh blue
sudo /usr/local/bin/stalwart-switch-slot.sh green
```
