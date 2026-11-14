# simplarr app

The control-plane UI and API for a simplarr stack: a Go backend with the React single-page app embedded in the binary. Design: [`docs/superpowers/specs/2026-11-14-control-plane-ui-design.md`](../docs/superpowers/specs/2026-11-14-control-plane-ui-design.md).

What exists so far (Plan 2 of 8): environment validation, `/healthz`, first-run setup, login, sessions, CSRF protection and login rate limiting, and an empty web shell with the setup and login pages. Service discovery, configuration, summaries and the real UI arrive in later plans.

## First run

1. Start the app. It prints the one-time setup token at `WARN` level:
   `First-run setup token: <token> (enter it at http://<host>/setup)`.
   In a container: `docker logs simplarr`.
2. Open `/setup`, enter the token and choose an admin password (at least 12 characters).
3. Sign in at `/login`.

The token lives in memory only and stops working once the password is set. The password hash is stored in `$SIMPLARR_DATA_DIR/admin.json` (mode 0600).

## Develop

```bash
# Backend (the UI answers 503 until it is built and embedded, the API works)
cd app
SIMPLARR_LISTEN=127.0.0.1:8080 SIMPLARR_DATA_DIR=/tmp/simplarr-data SIMPLARR_CONFIG_DIR=/tmp/simplarr-config \
  go run ./cmd/simplarr serve

# Frontend with hot reload; proxies /api to 127.0.0.1:8080
cd app/web
npm ci
npm run dev
```

## Test

```bash
cd app && go vet ./... && go test ./... -race
cd app && golangci-lint run ./...
cd app/web && npm run lint && npm run typecheck && npm test
```

## Build

```bash
# One binary with the UI embedded
cd app/web && npm ci && npm run build        # writes ../internal/webui/dist
cd app && go build -tags webdist -o /tmp/simplarr ./cmd/simplarr

# Container image (distroless, non-root); the context is the app/ directory
docker build -t simplarr app/
docker buildx build --platform linux/arm64 -t simplarr app/    # Raspberry Pi, no emulation needed
```

Without the `webdist` build tag the binary has no UI; every UI request answers `503 ui_not_built` with the fix, and the API still works.

## Configuration

All configuration is environment variables, validated at startup. A bad value stops the process with a message naming the variable. Values are trimmed, so a stray `\r` from a CRLF `.env` file is harmless.

| Variable | Default | Meaning |
|---|---|---|
| `SIMPLARR_TOPOLOGY` | `unified` | `unified` or `split` |
| `SIMPLARR_LISTEN` | `:8080` | listen address |
| `SIMPLARR_CONFIG_DIR` | `/config` | read-only mount holding the other services' config (absolute path) |
| `SIMPLARR_DATA_DIR` | `/data` | writable state: `admin.json` (absolute path) |
| `RADARR_HOST` / `_PORT` | `radarr` / `7878` | how to reach Radarr |
| `SONARR_HOST` / `_PORT` | `sonarr` / `8989` | Sonarr |
| `PROWLARR_HOST` / `_PORT` | `prowlarr` / `9696` | Prowlarr |
| `OVERSEERR_HOST` / `_PORT` | `overseerr` / `5055` | Overseerr |
| `TAUTULLI_HOST` / `_PORT` | `tautulli` / `8181` | Tautulli |
| `QBITTORRENT_HOST` / `_PORT` | `qbittorrent` / `8080` | qBittorrent (split: `NAS_IP`) |
| `PLEX_HOST` / `_PORT` | `host.docker.internal` / `32400` | Plex (split: `NAS_IP`) |
| `NAS_IP` | unset | required in split mode unless both hosts above are set |
| `NAS_IP_DASHED`, `PLEX_DIRECT_HASH` | unset | when both are set, Plex is reached by its `plex.direct` name |
| `SUBDOMAIN_TLD` | `local` | shown in the Deployment page; links come from the page's hostname |

Hosts are bare names or addresses: no scheme, no path, no port.

## Security notes

- The app publishes no port in compose. Only nginx can reach it, and nginx sets `X-Real-IP` (login rate limiting) and `X-Forwarded-Proto` (the cookie `Secure` flag). Do not expose the app's port directly: a client could then choose its own `X-Real-IP`.
- Sessions live in memory, so a restart signs everyone out.
- Secrets never appear in logs. The setup token is the one deliberate exception, printed once so the operator can read it.
