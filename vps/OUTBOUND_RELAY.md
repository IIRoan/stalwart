# Outbound mail relay (`mailsend.solace.onl`)

Outbound mail uses a **public VPS submission endpoint**, not an frp tunnel or
container hostname. Railway connects over the internet to Postfix on port **587**
with SASL authentication.

```
Stalwart (Railway)
    |  SMTP + STARTTLS + SASL
    v
mailsend.solace.onl:587  (VPS public IP, Postfix submission)
    |
    v
Internet (from VPS public IP / PTR)
```

## DNS (required)

Create an **A record**:

| Name | Type | Value |
|------|------|-------|
| `mailsend.solace.onl` | A | `193.180.211.139` |

Until DNS propagates, set on Railway:

```bash
RELAY_ROUTE_ADDRESS=193.180.211.139
RELAY_ROUTE_PORT=587
```

## Stalwart relay route

| Field | Value |
|-------|-------|
| Address | `mailsend.solace.onl` |
| Port | `587` |
| Protocol | SMTP |
| Implicit TLS | No (use STARTTLS) |
| Allow invalid certs | Yes (until a cert is issued for `mailsend.solace.onl`) |
| Username | `relay-client@mail.solace.onl` |
| Password | Stored in Stalwart + Postfix `sasldb` (must match) |

At container startup, `railway-entrypoint.sh` sets address/port via
`stalwart-cli` when `STALWART_ADMIN_TOKEN` is set.

## Postfix (VPS)

- Listens on **`0.0.0.0:587`** (submission, STARTTLS + SASL)
- SASL user: `relay-client@mail.solace.onl`
- Config: `vps/postfix-main.cf`, `vps/postfix-master.cf`

## Sync relay password

If auth fails (`lost connection after AUTH` in `/var/log/mail.log`):

```bash
# On VPS — set Postfix SASL password
printf '%s' 'YOUR_NEW_PASSWORD' | sudo saslpasswd2 -p -c -u mail.solace.onl relay-client

# Update Stalwart relay route secret (admin API token required)
stalwart-cli --url https://mail.solace.onl --api-key "$STALWART_ADMIN_TOKEN" \
  update MtaRoute ivnbzc1aaba9 \
  --json '{"authSecret":{"@type":"Value","secret":"YOUR_NEW_PASSWORD"}}'
```

## Optional TLS certificate

Issue a cert that includes `mailsend.solace.onl`, then point Postfix at it:

```bash
sudo certbot certonly --standalone -d mailsend.solace.onl
sudo cp /etc/letsencrypt/live/mailsend.solace.onl/fullchain.pem /etc/postfix/relay.pem
sudo cp /etc/letsencrypt/live/mailsend.solace.onl/privkey.pem /etc/postfix/relay.pem
sudo postfix reload
```

## Deprecated: STCP tunnel (`frpc-relay`, port 2525)

The previous design (STCP visitor in Railway → `127.0.0.1:2525` on VPS) is
no longer used. `frpc-relay` may be disabled:

```bash
sudo systemctl disable --now frpc-relay
```
