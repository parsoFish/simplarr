# Simplarr control-plane UI — design

- **Date:** 2026-11-14
- **Status:** approved in brainstorming, awaiting spec review
- **Scope:** milestone 1 (config + visibility). Later milestones are listed under Non-goals so they are not forgotten.

## 1. Goal

Today the `homepage/` container is a static nginx page: a list of links and a `/status` page that pings `/health/*`. Everything simplarr actually *does* to the stack lives in `configure.sh` / `configure.ps1`, which have drifted from each other (see §11).

Milestone 1 replaces the homepage with a **control-plane UI** that:

1. Talks to every service API directly (Radarr, Sonarr, Prowlarr, Overseerr, qBittorrent, Plex, Tautulli).
2. Shows every setting simplarr manages, what it should be, what it is now, and whether they differ.
3. Applies that configuration from the UI (create what is missing, repair drift on request), replacing the wiring logic in the configure scripts.
4. Shows read-only health and summaries for every service.
5. Is tested across mock deployments that stand in for the platforms and topologies simplarr supports: unified and split, Linux distros, Docker Desktop on macOS and Windows, Synology, VPN.

The setup scripts stay as bootstrap: `.env`, directories, `docker compose up`. The configure scripts become a thin call into the UI's backend.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | Go backend + React/TypeScript SPA embedded in the binary | One static binary that cross-compiles for the Pi (arm64). Same language as healarr, so the service clients can be shared. The SPA is needed for a real management UI with drift views and forms. |
| D2 | Service clients live in a new shared module, `github.com/parsoFish/arrkit`, extracted from healarr's `internal/clients` | Both repos import it and version it on its own; healarr and simplarr stay separate repos (healarr ADR-001). The HTTP fakes used by simplarr's mock setups live in the same module, next to the clients they imitate. |
| D3 | The config engine is a desired-state reconciler over *managed resources* (observe, diff, apply), not a port of the script's imperative steps | The drift view falls out of the model, which is what "show all the config simplarr sets" needs. Idempotency becomes structural. A dependency graph enforces the mandatory order Radarr → Sonarr → Prowlarr → Overseerr. |
| D4 | Scripts are bootstrap only. `configure.sh` / `.ps1` become `docker exec simplarr simplarr apply` | The wiring logic exists once. Bash/PowerShell parity becomes trivial. |
| D5 | Built-in login: an admin password set on first run with a one-time setup token from the container logs | The UI holds every API key and can change configuration, so it must not be open to the LAN. The setup token stops whoever loads the page first from taking it over. |
| D6 | No docker socket mounted into the UI container | The socket is root-equivalent on the host. Everything milestone 1 needs is reachable over HTTP or the read-only config mount. |
| D7 | State lives in files under `/data` (no database) | Milestone 1 state is three small documents: the admin hash, secrets and profile overrides. YAGNI on SQLite until history or audit needs it. |
| D8 | The UI runs on the Pi in split mode and on the single host in unified mode. The NAS gets no UI | Matches the current nginx placement and healarr ADR-015 (Pi primary). |
| D9 | Milestone 1 resources match today's `configure.sh` exactly, including the four public indexers | Parity first, then improvements. Roadmap §2 hardening is the first post-parity work (see Non-goals). |

Prior art checked before deciding to build: Buildarr and Flemmarr (declarative arr config) look unmaintained. Configarr is active but limited to custom formats and quality profiles. Homarr and gethomepage are display dashboards with no config management. None is a control plane for wiring a stack.

## 3. Architecture

```
browser ──► nginx (:80) ──► simplarr (:8080) ──► Radarr / Sonarr / Prowlarr / Overseerr / Tautulli   (docker DNS)
              │                 │            └─► Plex, qBittorrent   (unified: docker DNS / host.docker.internal; split: NAS_IP)
              │                 ├─ /config (ro)  = ${DOCKER_CONFIG}          → API keys
              │                 └─ /data   (rw)  = ${DOCKER_CONFIG}/simplarr → admin.json, secrets.json, profile.yaml
              └─ /radarr, /sonarr, … , /health/*  (unchanged)
```

### 3.1 Repository layout (simplarr)

```
app/
  go.mod                      module github.com/parsoFish/simplarr/app
  cmd/simplarr/               main: serve | apply | plan | healthcheck | version
  internal/
    config/                   env parsing + validation (fail fast, trims stray \r)
    discovery/                topology → service endpoints; API key readers
    credentials/              secrets.json store; Plex PIN flow; qBit verify
    auth/                     admin hash, setup token, sessions, CSRF, rate limit
    profile/                  embedded defaults + profile.yaml overrides, validation
    resources/                one file per managed resource (observe/diff/apply)
    plan/                     dependency graph, plan + apply orchestration
    summary/                  read-only per-service summaries
    api/                      HTTP handlers, JSON shapes, error mapping
    store/                    atomic file writes, permission checks
  web/                        Vite + React + TS + TanStack Query + React Router
  testdata/profiles/          mock deployment profiles (§9)
  e2e/                        Playwright specs + compose harness
  Dockerfile                  node build → go build (embed) → distroless static, nonroot
```

Files stay under 400 lines. Packages are split by feature, not by type.

### 3.2 arrkit (new repo)

```
github.com/parsoFish/arrkit
  httpx/  radarr/  sonarr/  prowlarr/  overseerr/  qbittorrent/  plex/  tautulli/
  fake/   (stateful HTTP fakes, one per service, seeded from fixtures)
  cmd/arrkit-mock/   (serves the fakes for a given profile; image: simplarr-mock)
```

- Extracted from `healarr/internal/clients/*` with history. `docker/` and `hostfs/` stay in healarr because they are host-specific.
- healarr switches its imports to arrkit with no behaviour change (its own PR).
- Simplarr's milestone 1 adds the config endpoints to arrkit (download clients, root folders, Prowlarr applications and indexers, Overseerr settings, qBit preferences).
- MIT licence, same as healarr. Tagged `v0.x`. Local development across repos uses `go.work`.

### 3.3 Container and compose

- `simplarr` replaces `homepage` in `docker-compose-unified.yml` and `docker-compose-pi.yml`.
  - It runs as `${PUID}:${PGID}` and publishes no port (`expose: 8080`).
  - Unified mode adds `extra_hosts: host.docker.internal:host-gateway`, as nginx already has, so Plex on the host network can be reached on native Linux.
- nginx:
  - `location = /` becomes a catch-all `location /` that proxies to simplarr. The existing longer prefixes (`/radarr`, `/sonarr`, `/prowlarr`, `/overseerr`, `/torrent`, `/tautulli`, `/plex`, `/health/`) still win.
  - SPA client routes must not start with any of those prefixes. For example the Radarr summary is `/services/radarr`, not `/radarr`.
  - `location = /status` redirects to `/`.
  - `depends_on: homepage` becomes `simplarr`.
- Healthcheck: `simplarr healthcheck` calls `/healthz`. The distroless image has no curl.
- The existing nginx `/health/*` routes stay because `utility/healthcheck.sh` uses them.

## 4. Configuration inputs

All inputs come from environment variables set in compose. They are the same names `configure.sh` uses today, and are validated at startup. Invalid input stops the process with a message naming the variable.

| Var | Default | Meaning |
|---|---|---|
| `SIMPLARR_TOPOLOGY` | `unified` | `unified` or `split` |
| `SIMPLARR_LISTEN` | `:8080` | listen address |
| `SIMPLARR_CONFIG_DIR` / `SIMPLARR_DATA_DIR` | `/config` / `/data` | mounts |
| `RADARR_HOST`/`_PORT`, `SONARR_*`, `PROWLARR_*`, `OVERSEERR_*`, `TAUTULLI_*` | service names, standard ports | how simplarr reaches each service, and what it writes into other services' payloads |
| `QBITTORRENT_HOST`/`_PORT` | `qbittorrent` / `8080` (split: `NAS_IP`) | as above |
| `PLEX_HOST`/`_PORT` | `host.docker.internal` / `32400` (split: `NAS_IP`) | as above |
| `NAS_IP_DASHED`, `PLEX_DIRECT_HASH` | unset | if both are set, Plex is reached by its `plex.direct` name with full TLS verification |
| `SUBDOMAIN_TLD` | `local` | shown in Deployment only. Service links are derived from the page's hostname, as the homepage does today |

- Values are trimmed of trailing `\r`, because a CRLF `.env` file is a real Windows failure mode.
- Ports must be 1–65535. Hosts must be non-empty and contain no scheme.

## 5. Discovery and credentials

### 5.1 Service state

Each service reports exactly one of the following states, each with a human-readable *reason* and a *fix*:

| State | Meaning | Example fix text |
|---|---|---|
| `reachable` | health endpoint OK and authenticated | — |
| `unauthorized` | 401/403 with the key we have | "Radarr rejected the API key from config.xml. Restart Radarr or check the config mount." |
| `uninitialized` | service up but not set up (Overseerr not signed in; Plex unclaimed) | "Sign in to Overseerr with Plex at <url>, then refresh." |
| `no-credentials` | credentials cannot be read or have not been entered | "Enter the qBittorrent WebUI password in Settings → Credentials." |
| `unreachable` | connection refused, DNS failure or timeout | "Cannot reach qBittorrent at <NAS_IP>:8080. Is the NAS up?" |
| `config-unreadable` | key file exists but permission denied | "simplarr cannot read radarr/config.xml (permission denied). On SELinux hosts add `:z` to the /config mount." |

Health is polled with a per-service timeout (default 5 s, Plex 8 s). The browser asks the backend and never contacts the services itself.

### 5.2 API keys

These follow CLAUDE.md pattern 1: keys are read from files, never from env.

| Service | Source | Parse |
|---|---|---|
| Radarr, Sonarr, Prowlarr | `/config/<svc>/config.xml` | XML `<ApiKey>` |
| Overseerr | `/config/overseerr/settings.json` | JSON `main.apiKey`. A missing file means `uninitialized` |
| Tautulli | `/config/tautulli/config.ini` | `[General] api_key`. If `api_enabled = 0`, the state is `uninitialized` with the fix "enable the API in Tautulli settings" |
| Plex (unified) | `/config/plex/Library/Application Support/Plex Media Server/Preferences.xml` | attribute `PlexOnlineToken` |

- Keys are re-read when a call returns 401, so a regenerated key is picked up without a restart.
- In split mode, the Pi's `/config` holds only the Pi services. Plex and qBittorrent use the stored credentials below.

### 5.3 Stored credentials (`/data/secrets.json`, mode 0600)

- **Plex token (split mode, or unified with an unreadable `Preferences.xml`).** Settings offers "Sign in with Plex", the plex.tv PIN flow (`POST https://plex.tv/api/v2/pins`, the user approves in a new tab, the backend polls `GET /api/v2/pins/{id}`). This is still a manual browser step, per CLAUDE.md pattern 3. It just happens inside the UI instead of instructions.
- **qBittorrent username and password.** The user enters them once. The UI shows the hint `docker logs qbittorrent` for the first-run temporary password. The backend verifies them with `POST /api/v2/auth/login` before storing. They are needed for the download-client payloads Radarr and Sonarr receive, and for the qBit summary.
- If the file mode is wider than 0600 at load, simplarr logs a warning and runs chmod to 0600. If chmod fails, it refuses to start and names the file. There is no ownership check, because Docker Desktop bind mounts report ownership differently from native Linux.
- Secrets never appear in API responses, logs or errors. The API reports only `{ "set": true, "verifiedAt": "…" }`.

## 6. Managed resources

### 6.1 Model

```go
type Resource interface {
    ID() string                                   // e.g. "radarr.downloadclient.qbittorrent"
    DependsOn() []string
    Observe(ctx context.Context) (Observed, error) // live state from the service API
    Desired(p profile.Profile, d Discovery) (Desired, error)
    Diff(o Observed, d Desired) Diff              // pure function
    Apply(ctx context.Context, d Diff) (Result, error)
}
```

- A resource is identified inside its service by a stable key: the name for download clients, apps and indexers; the path for root folders; hostname + port for Overseerr servers.
- Simplarr only touches objects that match a managed key. It never deletes anything in milestone 1.
- Each resource reports exactly one status:
  - `ok`
  - `missing`: will be created
  - `drift`: field-level diff listed. Fields the API masks, such as passwords, are shown as "not comparable"
  - `blocked`: a dependency is not ok, or the service is not ready. Comes with a reason and a fix
  - `error`: observing failed. Comes with the error

### 6.2 Milestone 1 resources

These are the same as `configure.sh` today. Payload fields come from the current script (`configure.sh:261-297`, `:645`, `:71-76`).

| ID | Service call | Key managed fields | Depends on |
|---|---|---|---|
| `radarr.downloadclient.qbittorrent` | `GET/POST/PUT /api/v3/downloadclient` | name `qBittorrent`, implementation `QBittorrent`, host, port, username, password, `movieCategory=radarr`, `removeCompletedDownloads`, `removeFailedDownloads`, enable | qBit credentials |
| `sonarr.downloadclient.qbittorrent` | `GET/POST/PUT /api/v3/downloadclient` | same, with `tvCategory=sonarr` | qBit credentials |
| `radarr.rootfolder.movies` | `GET/POST /api/v3/rootfolder` | path `/movies` | — |
| `sonarr.rootfolder.tv` | `GET/POST /api/v3/rootfolder` | path `/tv` | — |
| `prowlarr.app.radarr` | `GET/POST/PUT /api/v1/applications` | `fullSync`, prowlarrUrl, baseUrl, apiKey, syncCategories 2000…2080 | Radarr reachable |
| `prowlarr.app.sonarr` | same | syncCategories 5000…5080 | Sonarr reachable |
| `prowlarr.indexer.<def>` ×4 | `GET/POST /api/v1/indexer` | Cardigann `yts`, `thepiratebay`, `nyaasi` (named "Nyaa.si"), `limetorrents`, priority 25, appProfileId 1 | `prowlarr.app.*` |
| `prowlarr.sync` | `POST /api/v1/command {ApplicationIndexerSync}` | an action, not state; runs after any indexer or app change | indexers |
| `overseerr.radarr` | `GET/POST/PUT /api/v1/settings/radarr` | hostname, port, apiKey, activeProfile (first Radarr profile), activeDirectory (Radarr root), `minimumAvailability=released`, isDefault, syncEnabled | Overseerr initialized, `radarr.rootfolder.movies` |
| `overseerr.sonarr` | `GET/POST/PUT /api/v1/settings/sonarr` | same, plus `enableSeasonFolders` | Overseerr initialized, `sonarr.rootfolder.tv` |
| `overseerr.watchlist` | `POST /api/v1/user/1/settings/main` | `watchlistSyncMovies`, `watchlistSyncTv` | Overseerr initialized |

Indexer defaults, paths and categories can be overridden in `/data/profile.yaml`:

```yaml
version: 1
paths: { movies: /movies, tv: /tv }
categories: { radarr: radarr, sonarr: sonarr }
indexers: [yts, thepiratebay, nyaasi, limetorrents]
```

The profile is validated at load (unknown keys and unknown indexer definitions are errors). In milestone 1 the UI shows it read-only; you edit it as a file.

### 6.3 Plan and apply

- `plan` observes every resource, computes the diffs, and returns them in dependency order. Nothing is written.
- `apply` takes an explicit list of resource IDs.
  - The UI default is "create everything missing".
  - Repairing `drift` must be ticked per resource, because it overwrites a value someone may have changed on purpose.
  - The CLI's `apply --yes` creates missing resources only. `--repair` also fixes drift.
- Resources are applied in topological order. Ties are broken by service rank: Radarr, then Sonarr, then Prowlarr, then Overseerr. This guarantees the mandatory order from CLAUDE.md pattern 2 even where the graph alone would allow another order.
- If one fails, the resources that depend on it become `blocked` and independent ones carry on. The result reports each resource separately.
- Waiting differs by caller:
  - The CLI (`plan`, `apply`) waits for each service it needs to become ready before observing it: 30 attempts, 2 s apart, per CLAUDE.md pattern 4. A service still not ready after that becomes `unreachable`, and its resources become `blocked`.
  - The UI never waits. It shows the current state straight away.
- Re-applying is a no-op when everything is `ok`.
- Applies are serialized: one at a time, guarded by a mutex. A second concurrent apply gets `409`.

## 7. Visibility (read-only)

- **Overview:** one tile per service with its state (§5.1), version and a link. Links use the current homepage logic: subdomain when the page was loaded by name, port when loaded by IP, `app.plex.tv` for Plex. This page replaces the homepage.
- **Deployment:** topology, hosts and ports, container paths, `PUID`/`PGID`/`TZ` as passed to simplarr, and each service's live version next to the version pinned in compose. The pinned image tags are generated at build time (`go generate`) from the `docker-compose-*.yml` files, which are the source of truth. `VERSIONS.md` is known to drift from them (roadmap §4).
- **Configuration:** the resource list grouped by service, with status, diff and apply controls (§6.3).
- **Summaries:** each page degrades to its state message when the service is not `reachable`.

| Service | Shows |
|---|---|
| Radarr / Sonarr | queue count by status, wanted-missing count, root folder free space, health warnings |
| Prowlarr | indexers with enabled flag and failure status |
| qBittorrent | torrent counts by state, global speeds, version |
| Overseerr | pending and processing request counts, last 10 requests |
| Plex | libraries with item counts, the last 10 items added |
| Tautulli | current streams |

- **Settings:** credentials (Plex sign-in, qBit password), admin password change, and the profile (read-only).

## 8. HTTP API and auth

### 8.1 Endpoints

Everything is under `/api/v1` and returns JSON.

| Method + path | Auth | Purpose |
|---|---|---|
| `GET /healthz` | none | liveness only (`{"ok":true}`) |
| `GET /api/v1/auth/state` | none | `{setupRequired, authenticated}` |
| `POST /api/v1/auth/setup` | setup token | sets the admin password (first run only) |
| `POST /api/v1/auth/login`, `/logout` | — / session | |
| `PUT /api/v1/auth/password` | session + CSRF | change the admin password |
| `GET /api/v1/deployment` | session | §7 Deployment |
| `GET /api/v1/services` | session | state for each service |
| `GET /api/v1/resources` | session | the latest plan (cached for 15 s) |
| `POST /api/v1/plan` | session + CSRF | fresh plan |
| `POST /api/v1/apply` | session + CSRF | `{ids:[…], repair:bool}` → results per resource |
| `GET /api/v1/summary/{svc}` | session | §7 Summaries |
| `PUT /api/v1/credentials/qbittorrent` | session + CSRF | verify + store |
| `POST /api/v1/credentials/plex/pin`, `GET …/pin/{id}` | session + CSRF | PIN flow |
| `GET /api/v1/credentials` | session | which credentials are set, never values |

Errors use one shape: `{ "error": { "code": "service_unreachable", "message": "…", "fix": "…" } }`.

### 8.2 Auth

- **First run.** If `/data/admin.json` is missing, the server generates a 128-bit setup token and logs it once at `WARN` level: `First-run setup token: … (enter it at http://<host>/setup)`. The token is held in memory only and is invalid after setup succeeds.
- **Admin password.** At least 12 characters. Hashed with argon2id (`golang.org/x/crypto/argon2`): memory 64 MiB, time 3, threads 2, 16-byte salt, 32-byte key. The parameters are stored with the hash, so they can be raised later without invalidating existing passwords.
- **Sessions.** A random 256-bit ID in memory, with a 7-day TTL. A restart means logging in again; that is acceptable in milestone 1. The cookie is `HttpOnly`, `SameSite=Strict`, and `Secure` when the request came in over HTTPS (via `X-Forwarded-Proto`).
- **CSRF.** The double-submit token is required on every non-GET request except setup and login.
- **Rate limiting.** Login and setup allow 5 failures per 15 minutes per IP, then answer `429`. The IP comes from `X-Real-IP`, which only nginx sets.
- **CLI.** `simplarr apply` and `simplarr plan` run inside the container through `docker exec`. They call the same in-process plan/apply code with no HTTP. Anyone who can run `docker exec` on the host already has more access than the UI grants.

Run the `security-review` skill before committing the auth, credentials and API packages, per the project rules.

## 9. Mock setups and testing

### 9.1 Profiles

A profile is one simulated deployment: a topology, platform quirks and a lifecycle state. Profiles live in `app/testdata/profiles/<name>.yaml`.

```yaml
name: split-pi-synology
topology: split
platform: { os: linux, arch: arm64, host: synology-dsm7, dockerDesktop: false, hostGateway: true, envLineEndings: lf }
lifecycle: configured            # fresh | configured | drifted
services:
  radarr:    { version: "6.3.0.10514" }
  plex:      { location: nas, tls: plex-direct }
  qbittorrent: { location: nas, auth: password }
  overseerr: { initialized: true }
configFiles:
  radarr/config.xml: { mode: "0644" }
faults: []                       # e.g. [nas-unreachable, radarr-401, config-eacces, plex-host-network-missing]
```

`arrkit-mock seed --profile X --out <dir>` writes the config tree the profile describes: the arr `config.xml` files, Overseerr `settings.json`, Tautulli `config.ini`, and Plex `Preferences.xml` where the Plex config lives on the simplarr host. It applies the file modes, and adds CRLF to the env file where the profile says so. `arrkit-mock serve --profile X` serves stateful fakes seeded to the lifecycle state, with the faults applied.

Every axis is covered at least once. The set is not a full cartesian product.

| Profile | Covers |
|---|---|
| `unified-ubuntu-fresh` | nothing configured; Overseerr uninitialized; qBit credentials unset |
| `unified-ubuntu-configured` | all `ok`; apply is a no-op |
| `unified-ubuntu-drifted` | the user changed the download-client port and removed one indexer |
| `unified-mac-docker-desktop` | arm64; `host.docker.internal` native; `PUID` ignored by bind mounts; Plex unreachable without Docker Desktop host networking (state `unreachable` with that fix text) |
| `unified-windows-wsl2` | CRLF env values; config tree created from a Windows-path `DOCKER_CONFIG` |
| `unified-fedora-selinux` | config files return EACCES (`config-unreadable` with the `:z` fix) |
| `split-pi-synology` | Plex and qBit on the NAS; `plex.direct` TLS; NAS ports remapped (8282) |
| `split-nas-down` | NAS unreachable: Plex and qBit are `unreachable`, and the Radarr/Sonarr download clients are `blocked` |
| `unified-vpn-gluetun` | qBit reached through the gluetun alias |
| `unified-radarr-401` | stale key, then re-read and recovery |

### 9.2 Test layers

| Layer | Tooling | Runs |
|---|---|---|
| 1. Unit | Go `testing` + arrkit in-process fakes; table-driven resource diff/apply; config and profile validation; auth | every PR (`-race`, 80% coverage gate on `internal/…`) |
| 2. Profile integration | backend against `arrkit-mock` for **every** profile; golden `plan.json`, `services.json`, `deployment.json`; apply then re-plan must be all `ok` | every PR |
| 3. Web unit | Vitest + Testing Library + MSW | every PR |
| 4. E2E | `app/e2e/compose.yml` (simplarr image + simplarr-mock image) + Playwright: setup token → login → configure → apply → all ok | PR: `unified-ubuntu-fresh`, `split-pi-synology`, `unified-ubuntu-drifted`. Nightly: all profiles, plus the arm64 image on `ubuntu-24.04-arm` |
| 5. Contract | the arrkit client suite (`go test -tags contract`, which lives in arrkit) run against **real** images: Radarr, Sonarr, Prowlarr, qBittorrent, Tautulli, and Overseerr with a pre-seeded initialized `settings.json`. Simplarr runs it against the tags pinned in its own compose files; arrkit's CI runs it against the latest pins. It fails if a fake's response shape differs from the real one, and `-update` re-records the fixtures. Plex is excluded because it needs a claim token | simplarr: nightly, and on PRs that change a compose image pin. arrkit: on PRs that touch clients or fakes |
| 6. Bootstrap scripts | `setup.sh` / `preflight.sh` driven by scripted stdin answers: natively on `ubuntu-latest` and `macos-latest` (BSD `sed` and `grep`), and inside `debian`, `fedora`, `alpine` (busybox) and `archlinux` containers on the Ubuntu runner, so each distro's userland is covered. `setup.ps1` / `preflight.ps1` run under Pester on `windows-latest`. The test asserts the `.env` written and the directory tree | every PR |

**Honest limit.** GitHub's macOS runners cannot run Docker, and its Windows runners cannot run Linux containers. Platform behaviour inside Docker Desktop is covered by the profiles above, and the host-side scripts are run natively. Real Docker Desktop runs stay a manual check, listed in the README.

Layer 6 must fix the known macOS breakages it will hit: GNU-only `sed -i` in `setup.sh`, and `grep -P` in `configure.sh`. The second disappears with the thinned script.

### 9.3 CI changes

- New jobs: `go` (vet, golangci-lint, test), `web` (eslint, `tsc --noEmit`, vitest), `profiles`, `e2e`, `scripts-native` (os matrix).
- Nightly workflow: `e2e-all`, `e2e-arm64`.
- Existing `lint` and `fast-gate` stay. `eslint-homepage` is removed along with the homepage.
- The `full-suite` stub is replaced.

## 10. Error handling

- Every outbound call has a context timeout. Errors are wrapped with the service and operation (`radarr: POST /api/v3/downloadclient: 400: …`).
- Service error bodies are parsed for their validation messages. Arr apps return `[{propertyName, errorMessage}]`, and those reach the UI verbatim.
- No error is swallowed: every failure becomes a service state (§5.1), a resource status (§6.1) or an API error (§8.1). Each comes with a fix line wherever the cause is known.
- Logging uses `log/slog` JSON at `INFO`. A redaction handler drops any attribute whose key matches `key|token|password|secret`.

## 11. Script retirement and cleanup (milestone 1)

- **`configure.sh` / `configure.ps1`** shrink to: check that the `simplarr` container is running, `docker exec simplarr simplarr plan`, then `apply --yes` (with `--repair` passed through). The output is identical across shells by construction.
  - The divergences recorded on 2026-11-14 disappear with the old code: ps1 has no GET-before-POST, ignores `QB_*`/`*_HOST` env, uses `Nyaa.si` vs `Nyaa`, has no `enable:false` fallback, and does not check Overseerr `initialized`.
- **Deleted:**
  - `homepage/`
  - `dev-testing/test_homepage_static_content.sh`, `test_homepage_config_injection.sh`, `Test-HomepageConfigInjection.Tests.ps1`
  - the configure-wiring tests that only exercise the removed shell logic
  - Each deletion is listed in its PR.
- **`setup.sh` / `.ps1`** keep bootstrap. They additionally create `${DOCKER_CONFIG}/simplarr` owned by `PUID:PGID`, and their "Next steps" print the setup-token command. Fix GNU-only `sed -i` (layer 6).
- **README:** the manual steps stated plainly. They are Plex setup, the Overseerr Plex sign-in, the qBittorrent password, and the setup token. Nothing called "fully automated" that is not.
- **CLAUDE.md:** update the PowerShell/Bash parity section and the configure-order section to point at `app/internal/plan`.

## 12. Delivery order

Each step is one or more PRs, and the implementation plan chunks them further.

1. **arrkit extraction.** New repo, clients and fixtures moved from healarr with history; healarr switches its imports; healarr CI green.
2. **App skeleton.** `config`, `store`, `/healthz`, Dockerfile, CI `go` + `web` jobs.
3. **Auth** (setup token, login, sessions, CSRF, rate limit), with a security review.
4. **Discovery + credentials** (§5), with a security review.
5. **arrkit config endpoints + fakes**, then the resources, plan and apply (§6), plus the CLI.
6. **Summaries** (§7).
7. **Web UI:** overview, deployment, configuration, summaries, settings. Use the `frontend-design` skill here.
8. **`arrkit-mock` profiles + layers 2/4/5 + the nightly workflow.**
9. **Compose and nginx swap, script thinning, homepage removal, layer 6 + the macOS fixes.**
10. **Docs:** README, CLAUDE.md, VERSIONS.md.

## 13. Non-goals for milestone 1 (candidates for milestone 2+)

- **Operations:** queue item removal or blocklisting, request approve/decline, Plex library creation, indexer add/remove/test from the UI, editing the profile in the UI.
- **Roadmap §2 hardening as resources:** qBit `excluded_file_names`, seed and ratio limits, a recommended private-indexer set.
- **A background reconcile loop or drift alerts.**
- **Editing `.env` or compose from the UI, and any docker control** (D6).
- **Multi-user or roles, OIDC or proxy-header auth.**
- **Healarr status tile** (roadmap §3), Bazarr, Lidarr, Readarr.
- **UI on the NAS.**

## 14. Risks

| Risk | Mitigation |
|---|---|
| Fakes drift from real APIs | Layer 5 contract suite against pinned images; fixtures re-recorded |
| Arr API changes on image bumps | Contract suite runs on any compose pin change; versions shown in Deployment |
| qBit Host-header validation and CSRF reject requests from the docker network | The arrkit client sends matching `Referer`/`Origin`; covered by the contract layer |
| Config mount unreadable (SELinux, rootless Podman, NAS ACLs) | The `config-unreadable` state with a specific fix; the `unified-fedora-selinux` profile |
| Plex on Docker Desktop has no host network | `unreachable` with the fix text; documented; the `unified-mac-docker-desktop` profile |
| A cross-repo change (arrkit) slows delivery | arrkit is step 1 and is small; `go.work` for local iteration; simplarr pins an arrkit tag |
| Setup token visible to anyone who can read the container logs | Same trust level as `docker exec`; the token is single-use and only exists until setup |
