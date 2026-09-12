# Reverse proxy and public access

Home Assistant listens on `HA_PORT` (8123 by default) on the host, because the unit uses
`Network=host`. Do not publish that port to the internet directly. Put a reverse proxy or a
Cloudflare tunnel on the same host in front of it and let Home Assistant trust only loopback.

Back to [README](../README.md).

## Why host networking

`Network=host` is not a convenience here, it is a requirement:

- mDNS and SSDP discovery need to send and receive on the real interfaces (UDP 5353, 1900).
- The HomeKit bridge advertises itself over mDNS and serves TCP 21064.
- Matter commissioning needs the host's IPv6 link-local addresses.
- A same-host proxy reaches Home Assistant over loopback, which keeps `trusted_proxies` to
  `127.0.0.1` and `::1`.

A bridge network would break discovery and HomeKit, so this repo does not offer one for Home
Assistant itself. Only the optional database sits on `homeassistant.network`.

## Tell Home Assistant about the proxy

Without this, Home Assistant rejects proxied requests with **HTTP 400** and logs
`A request from a reverse proxy was received from 127.0.0.1, but your HTTP integration is not
set-up for reverse proxies`.

Add to `<HA_CONFIG_DIR>/configuration.yaml`:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
    - ::1
```

Then restart: `systemctl --user restart homeassistant.service`.

Add the proxy's container subnet as well when the proxy runs in a podman bridge network rather
than on the host, because the request then arrives from that subnet:

```yaml
    - 172.30.33.0/24
```

List only the proxy addresses. Anything in `trusted_proxies` is allowed to set the client IP that
Home Assistant records and rate-limits on.

## Cloudflare tunnel on the same host

Point the public hostname at `http://localhost:8123`. The tunnel runs on the host, so the request
reaches Home Assistant from `127.0.0.1` and the `trusted_proxies` block above is enough. Nothing
has to be published on the LAN.

Keep the tunnel's own access controls (Cloudflare Access) in front of the hostname if the instance
should not be world-reachable.

## Nginx Proxy Manager

Create a proxy host for the public name with:

- Scheme `http`, forward host `127.0.0.1`, forward port `8123`
- **Websockets support on** - the frontend uses a WebSocket for all state updates; without it the
  UI loads and then hangs on "Connection lost"
- Block Common Exploits is fine; do not add a path rewrite

If Nginx Proxy Manager runs in a bridge network, add its subnet to `trusted_proxies` as above.

## Verify

Two requests tell you whether the proxy chain and `trusted_proxies` are both right:

```bash
PUB=https://ha.example.com
curl -s -o /dev/null -w '%{http_code}\n' "$PUB/manifest.json"   # expect 200
curl -s -o /dev/null -w '%{http_code}\n' "$PUB/api/"            # expect 401
```

- `manifest.json` **200** - the route reaches Home Assistant.
- `/api/` **401** - Home Assistant accepted the proxied request and is only asking for a token.
- `/api/` **400** - `trusted_proxies` is missing or does not contain the address the request
  arrives from. This is the single most common misconfiguration.
- `manifest.json` 502 or 504 - the proxy cannot reach `127.0.0.1:8123`; check the unit first.

The same pair runs as part of the smoke checks:

```bash
tests/smoke.sh --public-url https://ha.example.com
```

and, because the public route is part of the comparison, it is also worth passing to
`scripts/migrate-legacy.sh --public-url` during a migration.

## See also

- [docs/hardware.md](hardware.md) - radios, Bluetooth, time zone
- [docs/matter.md](matter.md) - the optional Matter server
- [docs/migrating.md](migrating.md) - adopting an existing hand-made deployment
