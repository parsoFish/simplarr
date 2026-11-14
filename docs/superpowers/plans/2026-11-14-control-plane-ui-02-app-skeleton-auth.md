# App skeleton + auth — implementation plan (Plan 2 of 8)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the `app/` Go module and an empty React shell: validated environment config, an atomic file store, `/healthz`, a setup-token → argon2id admin password → session login flow with CSRF and login rate limiting, secret-redacting logs, a distroless non-root image, and CI jobs for Go and the web code.

**Architecture:** One Go module (`app/`) with feature packages under `internal/` (`config`, `logging`, `store`, `auth`, `api`, `webui`) and a thin `cmd/simplarr` entry point (`serve`, `healthcheck`, `version`). The Vite/React/TypeScript SPA lives in `app/web/` and is built into `app/internal/webui/dist`, which the binary embeds when built with the `webdist` tag. The HTTP layer is stdlib `net/http`; the only third-party Go dependency is `golang.org/x/crypto` for argon2id. Sessions, CSRF and the rate limiter are small hand-written stdlib components, because spec §8.2 fixes their semantics (see "Decisions").

**Tech Stack:** Go 1.25, `golang.org/x/crypto` v0.55.0, `log/slog`; Vite 8, React 19, React Router 7, TanStack Query 5, TypeScript 6.0, Vitest 5 + Testing Library + MSW 3, ESLint 10; Docker (distroless), GitHub Actions.

**Spec:** [`docs/superpowers/specs/2026-11-14-control-plane-ui-design.md`](../specs/2026-11-14-control-plane-ui-design.md) §3.1, §3.3, §4, §8.2, §10 (and §8.1 for the endpoints that exist so far, §9.3 for CI). Index: [`2026-11-14-control-plane-ui-00-index.md`](2026-11-14-control-plane-ui-00-index.md), row 2.

## Global Constraints

Every task's requirements include this section. Values are copied from the spec.

- **Module:** `github.com/parsoFish/simplarr/app` (spec §3.1), `go 1.25.0`. The only Go dependency is `golang.org/x/crypto v0.55.0` (plus its indirect `golang.org/x/sys`). v0.56.0 and later require Go 1.26, so do not bump it.
- **Environment (spec §4):** `SIMPLARR_TOPOLOGY` (`unified` default, or `split`), `SIMPLARR_LISTEN` (`:8080`), `SIMPLARR_CONFIG_DIR` (`/config`), `SIMPLARR_DATA_DIR` (`/data`), `<SVC>_HOST` / `<SVC>_PORT` for `RADARR`, `SONARR`, `PROWLARR`, `OVERSEERR`, `TAUTULLI`, `QBITTORRENT`, `PLEX` (defaults are the service names and standard ports; `QBITTORRENT_HOST` defaults to `qbittorrent`, `PLEX_HOST` to `host.docker.internal`, and in split mode both default to `NAS_IP`), `NAS_IP_DASHED`, `PLEX_DIRECT_HASH`, `SUBDOMAIN_TLD` (`local`).
- **Input rules (spec §4):** values are trimmed of trailing `\r`; ports must be 1–65535; hosts must be non-empty and contain no scheme. Invalid input stops the process with a message naming the variable.
- **Admin password (spec §8.2):** at least 12 characters; argon2id with memory 64 MiB, time 3, threads 2, 16-byte salt, 32-byte key; the parameters are stored with the hash so they can be raised later.
- **Setup token (spec §8.2):** 128-bit, generated when `/data/admin.json` is missing, logged once at `WARN` as `First-run setup token: … (enter it at http://<host>/setup)`, held in memory only, invalid after setup succeeds.
- **Sessions (spec §8.2):** random 256-bit ID held in memory, 7-day TTL. Cookie `HttpOnly`, `SameSite=Strict`, and `Secure` when the request came in over HTTPS (`X-Forwarded-Proto`).
- **CSRF (spec §8.2):** double-submit token required on every non-GET request except setup and login.
- **Rate limit (spec §8.2):** login and setup allow 5 failures per 15 minutes per IP, then answer `429`. The IP comes from `X-Real-IP`, which only nginx sets.
- **Errors (spec §8.1):** one shape, `{ "error": { "code": "…", "message": "…", "fix": "…" } }`.
- **Logging (spec §10):** `log/slog` JSON at `INFO`; a redaction handler drops any attribute whose key matches `key|token|password|secret`. Secrets never appear in API responses, logs or errors.
- **Container (spec §3.3):** distroless static, non-root, no curl; the healthcheck is `simplarr healthcheck`, which calls `/healthz`. No docker socket (D6).
- **SPA routes (spec §3.3):** client routes must not start with `/radarr`, `/sonarr`, `/prowlarr`, `/overseerr`, `/torrent`, `/tautulli`, `/plex` or `/health/`.
- **Style:** files under 400 lines; immutability (return new values, never mutate inputs); errors handled explicitly and never swallowed; no hardcoded secrets or personal data (addresses, home paths, account names) in committed files.
- **Git:** conventional commits `<type>: <description>`, no AI attribution line or trailer in a commit or the PR. Never commit on or push `main`, never use `--admin`. Feature branches are created with `--no-track`.
- **Security gate:** run the `security-review` skill before committing auth, input or API code. This plan has two gates (A after Task 8, B after Task 10) and holds the commits of Tasks 1–10 until each gate passes.
- **Testing:** TDD (test first, watch it fail, then implement). Coverage gate: `internal/...` stays at or above 80%.

## Scope

**Delivers (index row 2):** `app/` module; env config validation; atomic file store; `/healthz`; setup-token → admin password → session login; CSRF; rate limit; slog redaction; Dockerfile (distroless, non-root); CI `go` and `web` jobs; an empty SPA shell with setup and login pages. No arrkit dependency.

**Deliberately not in this plan:**

| Not built here | Where it lands |
|---|---|
| `PUT /api/v1/auth/password` (change the admin password) and its UI | Plan 3 gets the endpoint (it is a security-reviewed auth surface and invalidating other sessions is part of it); Plan 6 gets the Settings page |
| `simplarr plan` / `apply` subcommands | Plan 4 |
| Discovery, credentials, services, resources, summaries, deployment (`/api/v1/services`, …) | Plans 3–5 |
| Compose and nginx swap, thin `configure.*`, deleting `homepage/` | Plan 8. It must keep `X-Real-IP` and `X-Forwarded-Proto` on the catch-all `location /`, publish no port (`expose: 8080`), set `user: ${PUID}:${PGID}`, mount `${DOCKER_CONFIG}/simplarr` at `/data` (created by `setup.*`), and use `simplarr healthcheck` as the container healthcheck |
| Playwright e2e, mock profiles | Plan 7 |
| Real UI design (`frontend-design` skill) | Plan 6. The CSP in this plan has no inline-style allowance; revisit there if a component library needs one |

## Decisions made while writing this plan

These resolve points the spec leaves open or that the toolchain forced. The code below follows them.

1. **Branch base.** The user chose to merge PR #34 (spec and plans) to `main` first (hub item `i-20261114-c44624`, answer A). This plan document is committed to `feat/control-plane-ui` and ships in #34. The code branch `feat/app-skeleton-auth` starts from `origin/main` after that merge, so the Plan 2 PR shows only code.
2. **Hand-written sessions, CSRF and limiter.** `alexedwards/scs` (sessions) and `justinas/nosurf` / `gorilla/csrf` (CSRF) are maintained, but each brings its own cookie, token-renewal and masking semantics, and spec §8.2 fixes different ones (in-memory 256-bit IDs, absolute 7-day TTL, a CSRF token bound to the session, "5 failures then 429, reset on success"). The three components are about 250 lines of stdlib and are covered by the security-review gates. `golang.org/x/time/rate` is a token bucket and cannot express "N attempts then block, reset on success".
3. **The rate limiter charges before it checks.** `Limiter.Allow` records the attempt and answers in one atomic step, and a successful login resets the count. Recording failures after verification would let a burst of parallel guesses all pass a "not blocked yet" check; the regression test `TestParallelLoginBurstCannotExceedTheLimit` fails against that design (15 of 40 guesses got through during the spike).
4. **Setup does not log the user in.** Spec §8.1 says setup "sets the admin password". The SPA sends the user to `/login` afterwards. Setup therefore needs no cookies.
5. **`x/crypto` v0.55.0, TypeScript 6.0.3.** `x/crypto` v0.56+ needs Go 1.26 (the other repos are on 1.25). `typescript-eslint` 8.72 has a peer range `typescript <6.1`, so TypeScript 7 is out. TS 6 defaults `types` to `[]`, so `tsconfig.json` lists `vite/client`.
6. **MSW 3 renamed the unhandled-request option** to `onUnhandledFrame`. The old name `onUnhandledRequest` is a type error under MSW 3 and, if ignored, would let unhandled requests through. `src/test/setup.ts` uses `onUnhandledFrame: 'error'`, and `tsc` is part of CI.
7. **The UI is embedded behind a build tag.** `internal/webui` embeds `dist/` only with `-tags webdist`. A plain `go build` / `go test` works on a fresh checkout without Node; the container build uses the tag. Without it every UI request answers `503 ui_not_built` with the fix, and the API still works. Vite writes straight to `internal/webui/dist` so no copy step exists.
8. **`web/go.mod` fences off `node_modules`.** npm packages can ship `.go` files (`flatted/golang/…`), and `go vet ./...` would walk into them. A stub module file in `web/` makes the Go tool skip that tree. That is also why the embed package lives in `internal/webui`, not `web/`.
9. **`store.EnforceMode` is applied to `admin.json`.** Spec §5.3 defines the mode check for `secrets.json` (Plan 3); the same mechanism protects the password hash, so Plan 3 reuses it.
10. **New CI jobs are independent of `fast-gate`.** `fast-gate` is a required check, and a skipped required check can count as passing, so wiring `needs:` from it would only look like gating. The jobs `Go (vet, lint, test)`, `Web (lint, typecheck, test, build)` and `App image (build + smoke test)` run on every PR. Whether to make them required is a ruleset change, so it goes to the user as a hub item (Task 12) before the ruleset is touched. An extra `app-image` job (not in the spec's job list) builds the Dockerfile so it cannot rot unseen.
11. **Commits are held until the security gates.** The user's rule is "run the security review before committing the auth, input or API code". Implementers of Tasks 1–10 leave their work uncommitted; the controller stages it, runs `security-review`, fixes findings, then commits one conventional commit per task.
12. **Local environment quirks the implementers will meet:** local Node is 22.21.1 and `jsdom@31` wants 22.22.2+ or 24.15+, so `npm install` prints `EBADENGINE` warnings (tests still pass; CI uses Node 24). `docker build` may fail with `docker-credential-desktop.exe: executable file not found` because the Docker Desktop credential helper is not installed in WSL; prefix Docker commands with `DOCKER_CONFIG=$(mktemp -d)` (public base images need no credentials). Do not edit `~/.docker/config.json`.

## Execution

**Model routing (set the model explicitly on every subagent):**

| Role | Model | Tasks / reason |
|---|---|---|
| Implementer | `haiku` | 1, 2, 3, 4, 6, 9: code is given in full and the checks are mechanical |
| Implementer | `sonnet` | 5, 7, 8, 10, 11, 12: concurrency, HTTP wiring, the real-binary and Docker checks |
| Spec-compliance and code-quality reviewers | `sonnet` | every task |
| Final whole-branch review (before merge) | `opus` | once, after Task 12 |

If a haiku implementer fails a task twice, re-dispatch it on `sonnet`; do not loosen the checks.

**Working rules for implementers:**

- All paths are relative to the worktree root `~/projects/simplarr/.worktrees/app-skeleton-auth`. Run Go commands from `app/`, web commands from `app/web/`.
- Copy the code in this plan **verbatim**. It was written and run end to end before this plan was committed (Go: `go vet`, `golangci-lint`, `go test -race`, 93% coverage on `internal/...`; web: lint, `tsc`, Vitest, `vite build`; the container: build, health, non-root, arm64). If a step's expected output does not match, say so; do not "improve" the code.
- **Tasks 1–10: do not run `git add` or `git commit`.** Leave the files in the working tree. Reviewers read the files named in the task's **Files** list (plain `git diff` does not show untracked files).
- Delete nothing except what a step explicitly names (Task 11 removes the one container and two image tags it creates; `npm ci` in Task 12 reinstalls the git-ignored `app/web/node_modules`). Name each delete in your report before you run it.

## Prerequisites (controller, before Task 1)

- [ ] **P1. Merge PR #34.** This plan is committed on `feat/control-plane-ui` and pushed; CI is green; the user answered A. Merge with a merge commit (the repo's history style), without `--admin`, and without deleting any branch:

```bash
cd ~/projects/simplarr/.worktrees/control-plane-ui
git push
gh pr checks 34 --watch
gh pr merge 34 --merge
```

Expected: the checks `Lint (ShellCheck + PSScriptAnalyzer)` and `Fast Gate (target < 15 min)` pass, and the PR shows as merged.

- [ ] **P2. Create the code worktree from `origin/main` with `--no-track`:**

```bash
cd ~/projects/simplarr
git fetch origin
git worktree add --no-track -b feat/app-skeleton-auth .worktrees/app-skeleton-auth origin/main
cd .worktrees/app-skeleton-auth
git config --get branch.feat/app-skeleton-auth.remote || echo "no upstream (good)"
ls docs/superpowers/plans | grep 02-app-skeleton-auth
```

Expected: `no upstream (good)` and the plan file listed (it arrived with #34). `.worktrees/` is already in `.git/info/exclude`.

- [ ] **P3. Toolchain check:**

```bash
go version          # any 1.24+; go.mod's "go 1.25.0" makes the go command fetch a 1.25 toolchain
node --version      # 22.x or 24.x
golangci-lint --version
docker version --format '{{.Server.Version}}'
```

## File structure

All new, under `app/` unless noted:

```
go.mod  go.sum  .golangci.yml  .dockerignore  Dockerfile  README.md
cmd/simplarr/        main.go serve.go healthcheck.go                      (+ main_test.go)
internal/
  config/            config.go validate.go                                 (+ config_test.go)
  logging/           redact.go                                             (+ redact_test.go)
  store/             store.go                                              (+ store_test.go)
  auth/              password.go tokens.go session.go ratelimit.go service.go
                                                                           (+ one _test.go each, helpers_test.go)
  api/               errors.go jsonbody.go clientip.go cookies.go middleware.go
                     auth_handlers.go spa.go server.go                     (+ tests, helpers_test.go, env_test.go)
  webui/             embed_dist.go (tag webdist)  embed_stub.go (no tag)
web/                 package.json package-lock.json tsconfig.json vite.config.ts eslint.config.js
                     index.html go.mod
  src/               main.tsx App.tsx styles.css
    api/             client.ts auth.ts
    components/      AuthCard.tsx ErrorMessage.tsx RequireAuth.tsx
    pages/           SetupPage.tsx LoginPage.tsx HomePage.tsx NotFoundPage.tsx
    test/            server.ts setup.ts backend.ts render.tsx
```

Modified outside `app/`: `.gitignore` (Task 9), `.github/workflows/ci.yml` (Task 12), `docs/superpowers/plans/…-00-index.md` (final handoff).

---

### Task 1: Module scaffold and environment config

**Files:**
- Create: `app/go.mod`, `app/.golangci.yml`
- Create: `app/internal/config/validate.go`, `app/internal/config/config.go`
- Test: `app/internal/config/config_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces: package `config`:
  - `type Topology string` with `TopologyUnified`, `TopologySplit`
  - `type Endpoint struct{ Host string; Port int }` with `func (Endpoint) Address() string` (host:port, IPv6 bracketed)
  - `type Config struct{ Topology; Listen, ConfigDir, DataDir string; Radarr, Sonarr, Prowlarr, Overseerr, Tautulli, QBittorrent, Plex Endpoint; NASIPDashed, PlexDirectHash, SubdomainTLD string }`
  - `func (Config) PlexDirectHost() (string, bool)`
  - `func Load(getenv func(string) string) (Config, error)`; all problems are returned joined, each naming its variable.

- [ ] **Step 1: Create the module file**

`app/go.mod` (the dependency is added in Task 3):

```go
module github.com/parsoFish/simplarr/app

go 1.25.0
```

- [ ] **Step 2: Create the lint config**

`app/.golangci.yml`

```yaml
version: "2"
linters:
  default: standard
  enable: [errcheck, govet, staticcheck, unused, ineffassign, misspell, gocyclo]
  settings:
    gocyclo:
      min-complexity: 15
    errcheck:
      # Nothing useful can be done when writing CLI output fails or when
      # closing a response body that was already read.
      exclude-functions:
        - fmt.Fprint
        - fmt.Fprintf
        - fmt.Fprintln
        - (io.ReadCloser).Close
```


- [ ] **Step 3: Write the failing test**

`app/internal/config/config_test.go`

```go
package config

import (
	"strings"
	"testing"
)

// env builds a getenv func from a map. Unset names return "".
func env(m map[string]string) func(string) string {
	return func(name string) string { return m[name] }
}

func TestLoadDefaultsUnified(t *testing.T) {
	cfg, err := Load(env(nil))
	if err != nil {
		t.Fatalf("Load with empty env: %v", err)
	}
	if cfg.Topology != TopologyUnified {
		t.Errorf("Topology = %q, want unified", cfg.Topology)
	}
	if cfg.Listen != ":8080" {
		t.Errorf("Listen = %q, want :8080", cfg.Listen)
	}
	if cfg.ConfigDir != "/config" || cfg.DataDir != "/data" {
		t.Errorf("dirs = %q, %q; want /config, /data", cfg.ConfigDir, cfg.DataDir)
	}
	want := map[string]Endpoint{
		"radarr":      {"radarr", 7878},
		"sonarr":      {"sonarr", 8989},
		"prowlarr":    {"prowlarr", 9696},
		"overseerr":   {"overseerr", 5055},
		"tautulli":    {"tautulli", 8181},
		"qbittorrent": {"qbittorrent", 8080},
		"plex":        {"host.docker.internal", 32400},
	}
	got := map[string]Endpoint{
		"radarr": cfg.Radarr, "sonarr": cfg.Sonarr, "prowlarr": cfg.Prowlarr,
		"overseerr": cfg.Overseerr, "tautulli": cfg.Tautulli,
		"qbittorrent": cfg.QBittorrent, "plex": cfg.Plex,
	}
	for name, w := range want {
		if got[name] != w {
			t.Errorf("%s = %+v, want %+v", name, got[name], w)
		}
	}
	if cfg.SubdomainTLD != "local" {
		t.Errorf("SubdomainTLD = %q, want local", cfg.SubdomainTLD)
	}
}

func TestLoadTrimsCarriageReturnsAndSpaces(t *testing.T) {
	cfg, err := Load(env(map[string]string{
		"RADARR_HOST":       "radarr-box\r",
		"RADARR_PORT":       "7878\r",
		"SIMPLARR_TOPOLOGY": "split\r",
		"NAS_IP":            " 10.0.0.2\r",
		"SUBDOMAIN_TLD":     ".home\r",
	}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Radarr != (Endpoint{"radarr-box", 7878}) {
		t.Errorf("Radarr = %+v", cfg.Radarr)
	}
	if cfg.Topology != TopologySplit {
		t.Errorf("Topology = %q", cfg.Topology)
	}
	if cfg.QBittorrent.Host != "10.0.0.2" || cfg.Plex.Host != "10.0.0.2" {
		t.Errorf("split hosts = %q, %q; want 10.0.0.2", cfg.QBittorrent.Host, cfg.Plex.Host)
	}
	if cfg.SubdomainTLD != "home" {
		t.Errorf("SubdomainTLD = %q, want home (leading dot stripped)", cfg.SubdomainTLD)
	}
}

func TestLoadSplitNeedsNASIP(t *testing.T) {
	_, err := Load(env(map[string]string{"SIMPLARR_TOPOLOGY": "split"}))
	if err == nil || !strings.Contains(err.Error(), "NAS_IP") {
		t.Fatalf("err = %v, want error naming NAS_IP", err)
	}
}

func TestLoadSplitExplicitHostsDoNotNeedNASIP(t *testing.T) {
	cfg, err := Load(env(map[string]string{
		"SIMPLARR_TOPOLOGY": "split",
		"QBITTORRENT_HOST":  "nas.lan",
		"QBITTORRENT_PORT":  "8282",
		"PLEX_HOST":         "nas.lan",
	}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.QBittorrent != (Endpoint{"nas.lan", 8282}) {
		t.Errorf("QBittorrent = %+v", cfg.QBittorrent)
	}
}

func TestLoadRejectsBadValuesNamingTheVariable(t *testing.T) {
	tests := []struct {
		name string
		env  map[string]string
		want string
	}{
		{"port zero", map[string]string{"RADARR_PORT": "0"}, "RADARR_PORT"},
		{"port too big", map[string]string{"SONARR_PORT": "65536"}, "SONARR_PORT"},
		{"port text", map[string]string{"PROWLARR_PORT": "abc"}, "PROWLARR_PORT"},
		{"port negative", map[string]string{"OVERSEERR_PORT": "-1"}, "OVERSEERR_PORT"},
		{"port signed", map[string]string{"TAUTULLI_PORT": "+80"}, "TAUTULLI_PORT"},
		{"host scheme", map[string]string{"RADARR_HOST": "http://radarr"}, "RADARR_HOST"},
		{"host path", map[string]string{"SONARR_HOST": "sonarr/api"}, "SONARR_HOST"},
		{"host with port", map[string]string{"PROWLARR_HOST": "prowlarr:9696"}, "PROWLARR_HOST"},
		{"host space", map[string]string{"OVERSEERR_HOST": "over seerr"}, "OVERSEERR_HOST"},
		{"topology", map[string]string{"SIMPLARR_TOPOLOGY": "cluster"}, "SIMPLARR_TOPOLOGY"},
		{"listen no port", map[string]string{"SIMPLARR_LISTEN": "localhost"}, "SIMPLARR_LISTEN"},
		{"listen bad port", map[string]string{"SIMPLARR_LISTEN": ":99999"}, "SIMPLARR_LISTEN"},
		{"config dir relative", map[string]string{"SIMPLARR_CONFIG_DIR": "config"}, "SIMPLARR_CONFIG_DIR"},
		{"data dir relative", map[string]string{"SIMPLARR_DATA_DIR": "./data"}, "SIMPLARR_DATA_DIR"},
		{"tld", map[string]string{"SUBDOMAIN_TLD": "bad tld"}, "SUBDOMAIN_TLD"},
		{"dashed", map[string]string{"NAS_IP_DASHED": "10.0.0.2"}, "NAS_IP_DASHED"},
		{"hash", map[string]string{"PLEX_DIRECT_HASH": "a/b"}, "PLEX_DIRECT_HASH"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Load(env(tc.env))
			if err == nil {
				t.Fatal("Load succeeded, want error")
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error %q does not name %s", err, tc.want)
			}
		})
	}
}

func TestLoadReportsEveryProblemAtOnce(t *testing.T) {
	_, err := Load(env(map[string]string{"RADARR_PORT": "0", "SONARR_HOST": "http://x"}))
	if err == nil {
		t.Fatal("want error")
	}
	for _, name := range []string{"RADARR_PORT", "SONARR_HOST"} {
		if !strings.Contains(err.Error(), name) {
			t.Errorf("error %q missing %s", err, name)
		}
	}
}

func TestLoadAcceptsIPv6AndListenHost(t *testing.T) {
	cfg, err := Load(env(map[string]string{
		"RADARR_HOST":     "fd00::5",
		"SIMPLARR_LISTEN": "127.0.0.1:9000",
	}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Radarr.Host != "fd00::5" {
		t.Errorf("Radarr.Host = %q", cfg.Radarr.Host)
	}
	if got := cfg.Radarr.Address(); got != "[fd00::5]:7878" {
		t.Errorf("Address() = %q, want [fd00::5]:7878", got)
	}
}

func TestPlexDirectHost(t *testing.T) {
	both, err := Load(env(map[string]string{"NAS_IP_DASHED": "10-0-0-2", "PLEX_DIRECT_HASH": "abc123"}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	host, ok := both.PlexDirectHost()
	if !ok || host != "10-0-0-2.abc123.plex.direct" {
		t.Errorf("PlexDirectHost() = %q, %v", host, ok)
	}

	for name, m := range map[string]map[string]string{
		"neither":   {},
		"only hash": {"PLEX_DIRECT_HASH": "abc123"},
		"only ip":   {"NAS_IP_DASHED": "10-0-0-2"},
	} {
		cfg, err := Load(env(m))
		if err != nil {
			t.Fatalf("%s: Load: %v", name, err)
		}
		if host, ok := cfg.PlexDirectHost(); ok {
			t.Errorf("%s: PlexDirectHost() = %q, true; want not ok", name, host)
		}
	}
}
```


- [ ] **Step 4: Run it and watch it fail**

```bash
cd app && go test ./internal/config/
```

Expected: build failure with `undefined: Load`, `undefined: Endpoint`, `undefined: TopologyUnified`.

- [ ] **Step 5: Write the implementation**

`app/internal/config/validate.go`

```go
package config

import (
	"fmt"
	"net"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

var (
	tldPattern   = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$`)
	dashedHostRe = regexp.MustCompile(`^[A-Za-z0-9-]+$`)
)

// parsePort accepts only plain decimal digits in 1-65535 (no sign, no spaces).
func parsePort(s string) (int, error) {
	p, err := strconv.ParseUint(s, 10, 16)
	if err != nil || p == 0 {
		return 0, fmt.Errorf("must be a number between 1 and 65535, got %q", s)
	}
	return int(p), nil
}

// validateHost accepts a bare host name or IP address: no scheme, no path,
// no port. IPv6 literals (two or more colons) are allowed.
func validateHost(h string) error {
	switch {
	case h == "":
		return fmt.Errorf("must not be empty")
	case strings.Contains(h, "://"):
		return fmt.Errorf("must not include a scheme, got %q", h)
	case strings.ContainsAny(h, "/?#@ \t"):
		return fmt.Errorf("must be a bare host name or address, got %q", h)
	case strings.Count(h, ":") == 1:
		return fmt.Errorf("must not include a port (set the matching *_PORT variable), got %q", h)
	}
	return nil
}

// validateListen checks a host:port listen address. The host may be empty.
func validateListen(addr string) error {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("must look like :8080 or 127.0.0.1:8080, got %q", addr)
	}
	if _, err := parsePort(port); err != nil {
		return err
	}
	if host != "" {
		if err := validateHost(host); err != nil {
			return err
		}
	}
	return nil
}

func validateDir(p string) error {
	if !filepath.IsAbs(p) {
		return fmt.Errorf("must be an absolute path, got %q", p)
	}
	return nil
}

func validateTLD(s string) error {
	if !tldPattern.MatchString(s) {
		return fmt.Errorf("must contain only letters, digits, dots and dashes, got %q", s)
	}
	return nil
}

// validateDashed checks the dashed-IP and hash pieces of a plex.direct name.
func validateDashed(s string) error {
	if !dashedHostRe.MatchString(s) {
		return fmt.Errorf("must contain only letters, digits and dashes, got %q", s)
	}
	return nil
}
```


`app/internal/config/config.go`

```go
// Package config reads simplarr's environment configuration (spec §4),
// validates it, and fails fast with messages that name the variable.
package config

import (
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
)

// Topology is how the stack is deployed.
type Topology string

const (
	TopologyUnified Topology = "unified"
	TopologySplit   Topology = "split"
)

// Endpoint is how simplarr reaches one service.
type Endpoint struct {
	Host string
	Port int
}

// Address returns host:port, bracketing IPv6 literals.
func (e Endpoint) Address() string {
	return net.JoinHostPort(e.Host, strconv.Itoa(e.Port))
}

// Config is the validated, immutable process configuration.
type Config struct {
	Topology  Topology
	Listen    string
	ConfigDir string
	DataDir   string

	Radarr      Endpoint
	Sonarr      Endpoint
	Prowlarr    Endpoint
	Overseerr   Endpoint
	Tautulli    Endpoint
	QBittorrent Endpoint
	Plex        Endpoint

	NASIPDashed    string
	PlexDirectHash string
	SubdomainTLD   string
}

// PlexDirectHost returns the plex.direct host name when both NAS_IP_DASHED
// and PLEX_DIRECT_HASH are set. A partial pair is a normal state (the hash is
// only known after Plex is claimed), so it is not an error.
func (c Config) PlexDirectHost() (string, bool) {
	if c.NASIPDashed == "" || c.PlexDirectHash == "" {
		return "", false
	}
	return c.NASIPDashed + "." + c.PlexDirectHash + ".plex.direct", true
}

type serviceSpec struct {
	prefix      string
	defaultHost string
	defaultPort int
	onNAS       bool // in split mode the default host is NAS_IP
}

var (
	radarrSpec      = serviceSpec{"RADARR", "radarr", 7878, false}
	sonarrSpec      = serviceSpec{"SONARR", "sonarr", 8989, false}
	prowlarrSpec    = serviceSpec{"PROWLARR", "prowlarr", 9696, false}
	overseerrSpec   = serviceSpec{"OVERSEERR", "overseerr", 5055, false}
	tautulliSpec    = serviceSpec{"TAUTULLI", "tautulli", 8181, false}
	qbittorrentSpec = serviceSpec{"QBITTORRENT", "qbittorrent", 8080, true}
	plexSpec        = serviceSpec{"PLEX", "host.docker.internal", 32400, true}
)

// loader collects every problem so the operator can fix them in one pass.
type loader struct {
	getenv func(string) string
	errs   []error
}

// get returns the trimmed value; "" means unset. Trimming removes the stray
// \r that a CRLF .env file leaves behind.
func (l *loader) get(name string) string {
	return strings.TrimSpace(l.getenv(name))
}

func (l *loader) fail(name string, err error) {
	l.errs = append(l.errs, fmt.Errorf("%s: %w", name, err))
}

// checked returns the value of name (or def when unset) after validation.
func (l *loader) checked(name, def string, validate func(string) error) string {
	v := l.get(name)
	if v == "" {
		v = def
	}
	if err := validate(v); err != nil {
		l.fail(name, err)
	}
	return v
}

// optional returns the value when set and valid, "" when unset.
func (l *loader) optional(name string, validate func(string) error) string {
	v := l.get(name)
	if v == "" {
		return ""
	}
	if err := validate(v); err != nil {
		l.fail(name, err)
	}
	return v
}

func (l *loader) endpoint(s serviceSpec, nasIP string, topo Topology) Endpoint {
	def := s.defaultHost
	hostVar := s.prefix + "_HOST"
	if s.onNAS && topo == TopologySplit && l.get(hostVar) == "" {
		if nasIP == "" {
			l.fail("NAS_IP", fmt.Errorf("required when SIMPLARR_TOPOLOGY=split and %s is not set", hostVar))
		}
		def = nasIP
	}
	host := l.checked(hostVar, def, validateHost)

	port := s.defaultPort
	if v := l.get(s.prefix + "_PORT"); v != "" {
		p, err := parsePort(v)
		if err != nil {
			l.fail(s.prefix+"_PORT", err)
		} else {
			port = p
		}
	}
	return Endpoint{Host: host, Port: port}
}

// Load builds a Config from getenv (os.Getenv in production). It returns every
// validation problem joined into one error.
func Load(getenv func(string) string) (Config, error) {
	l := &loader{getenv: getenv}

	topo := Topology(l.get("SIMPLARR_TOPOLOGY"))
	switch topo {
	case "":
		topo = TopologyUnified
	case TopologyUnified, TopologySplit:
	default:
		l.fail("SIMPLARR_TOPOLOGY", fmt.Errorf("must be unified or split, got %q", string(topo)))
		topo = TopologyUnified
	}

	nasIP := l.optional("NAS_IP", validateHost)

	cfg := Config{
		Topology:  topo,
		Listen:    l.checked("SIMPLARR_LISTEN", ":8080", validateListen),
		ConfigDir: l.checked("SIMPLARR_CONFIG_DIR", "/config", validateDir),
		DataDir:   l.checked("SIMPLARR_DATA_DIR", "/data", validateDir),

		Radarr:      l.endpoint(radarrSpec, nasIP, topo),
		Sonarr:      l.endpoint(sonarrSpec, nasIP, topo),
		Prowlarr:    l.endpoint(prowlarrSpec, nasIP, topo),
		Overseerr:   l.endpoint(overseerrSpec, nasIP, topo),
		Tautulli:    l.endpoint(tautulliSpec, nasIP, topo),
		QBittorrent: l.endpoint(qbittorrentSpec, nasIP, topo),
		Plex:        l.endpoint(plexSpec, nasIP, topo),

		NASIPDashed:    l.optional("NAS_IP_DASHED", validateDashed),
		PlexDirectHash: l.optional("PLEX_DIRECT_HASH", validateDashed),
	}

	tld := strings.TrimPrefix(l.get("SUBDOMAIN_TLD"), ".")
	if tld == "" {
		tld = "local"
	}
	if err := validateTLD(tld); err != nil {
		l.fail("SUBDOMAIN_TLD", err)
	}
	cfg.SubdomainTLD = tld

	if len(l.errs) > 0 {
		return Config{}, errors.Join(l.errs...)
	}
	return cfg, nil
}
```


- [ ] **Step 6: Run the tests, vet and lint**

```bash
cd app
go test ./internal/config/ -race -cover
gofmt -l .
go vet ./...
golangci-lint run ./...
```

Expected: `ok … coverage: 9x%`, `gofmt -l` prints nothing, vet and lint print nothing / `0 issues.`

- [ ] **Step 7: Leave the work uncommitted** (Gate A commits it). Do not `git add`.

---

### Task 2: Secret-redacting logger and atomic file store

**Files:**
- Create: `app/internal/logging/redact.go`, `app/internal/store/store.go`
- Test: `app/internal/logging/redact_test.go`, `app/internal/store/store_test.go`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `logging.ReplaceAttr(groups []string, a slog.Attr) slog.Attr`: drops attributes whose key or enclosing group name matches `(?i)key|token|password|secret`
  - `logging.New(w io.Writer, level slog.Level) *slog.Logger`: JSON handler with that redaction
  - `store.WriteFileAtomic(path string, data []byte, perm os.FileMode) error`: temp file in the same directory, explicit `chmod`, fsync, rename
  - `store.EnforceMode(path string, want os.FileMode, log *slog.Logger) error`: missing file is fine; a wider mode is logged at WARN and chmodded; a failed chmod returns an error naming the file
  - `store.EnsureDir(dir string) error`: creates the directory and proves it writable

- [ ] **Step 1: Write the failing tests**

`app/internal/logging/redact_test.go`

```go
package logging

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"strings"
	"testing"
)

func logLine(t *testing.T, fn func(*slog.Logger)) map[string]any {
	t.Helper()
	var buf bytes.Buffer
	fn(New(&buf, slog.LevelInfo))
	var out map[string]any
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil {
		t.Fatalf("log output is not one JSON object: %v\n%s", err, buf.String())
	}
	return out
}

func TestSensitiveKeysAreDropped(t *testing.T) {
	keys := []string{
		"password", "Password", "newPassword", "token", "setupToken", "csrf_token",
		"secret", "clientSecret", "key", "apiKey", "api_key", "X-Api-Key",
	}
	for _, k := range keys {
		t.Run(k, func(t *testing.T) {
			out := logLine(t, func(l *slog.Logger) { l.Info("event", k, "hunter2hunter2") })
			if _, found := out[k]; found {
				t.Errorf("attribute %q was logged: %v", k, out)
			}
		})
	}
}

func TestSafeKeysSurvive(t *testing.T) {
	out := logLine(t, func(l *slog.Logger) { l.Info("login failed", "ip", "10.0.0.7", "status", 401) })
	if out["ip"] != "10.0.0.7" || out["status"] != float64(401) || out["msg"] != "login failed" {
		t.Errorf("unexpected output: %v", out)
	}
	if out["level"] != "INFO" || out["time"] == nil {
		t.Errorf("built-in attributes missing: %v", out)
	}
}

func TestGroupsAreChecked(t *testing.T) {
	out := logLine(t, func(l *slog.Logger) {
		l.Info("event",
			slog.Group("req", slog.String("path", "/x"), slog.String("apiKey", "abc")),
			slog.Group("secrets", slog.String("a", "b")),
		)
	})
	req, _ := out["req"].(map[string]any)
	if req["path"] != "/x" {
		t.Errorf("req.path missing: %v", out)
	}
	if _, found := req["apiKey"]; found {
		t.Errorf("nested apiKey logged: %v", out)
	}
	if _, found := out["secrets"]; found {
		t.Errorf("sensitive group logged: %v", out)
	}
}

func TestPreAttachedAttrsAndGroupsAreRedacted(t *testing.T) {
	var buf bytes.Buffer
	l := New(&buf, slog.LevelInfo).With("password", "p").WithGroup("tokens").With("a", "b")
	l.Info("event", "c", "d")
	if strings.Contains(buf.String(), `"p"`) || strings.Contains(buf.String(), `"a"`) || strings.Contains(buf.String(), `"c"`) {
		t.Errorf("pre-attached sensitive data leaked: %s", buf.String())
	}
}

func TestLevelIsHonoured(t *testing.T) {
	var buf bytes.Buffer
	New(&buf, slog.LevelWarn).Info("quiet")
	if buf.Len() != 0 {
		t.Errorf("INFO line written at WARN level: %s", buf.String())
	}
}
```


`app/internal/store/store_test.go`

```go
package store

import (
	"bytes"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteFileAtomicCreatesWithMode(t *testing.T) {
	path := filepath.Join(t.TempDir(), "admin.json")
	if err := WriteFileAtomic(path, []byte(`{"a":1}`), 0o600); err != nil {
		t.Fatalf("WriteFileAtomic: %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil || string(got) != `{"a":1}` {
		t.Fatalf("content = %q, err = %v", got, err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("mode = %o, want 600 regardless of umask", info.Mode().Perm())
	}
}

func TestWriteFileAtomicReplacesAndLeavesNoTempFiles(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "secrets.json")
	for _, content := range []string{"one", "two-longer", "3"} {
		if err := WriteFileAtomic(path, []byte(content), 0o600); err != nil {
			t.Fatalf("WriteFileAtomic(%q): %v", content, err)
		}
		got, _ := os.ReadFile(path)
		if string(got) != content {
			t.Fatalf("content = %q, want %q", got, content)
		}
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "secrets.json" {
		names := []string{}
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("dir contains %v, want only secrets.json", names)
	}
}

func TestWriteFileAtomicMissingDirFailsCleanly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nope", "file.json")
	err := WriteFileAtomic(path, []byte("x"), 0o600)
	if err == nil || !strings.Contains(err.Error(), "nope") {
		t.Fatalf("err = %v, want error naming the missing directory", err)
	}
}

func TestEnforceModeNarrowsWideFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "secrets.json")
	if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o644); err != nil { // WriteFile is subject to umask, Chmod is not
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if err := EnforceMode(path, 0o600, slog.New(slog.NewTextHandler(&buf, nil))); err != nil {
		t.Fatalf("EnforceMode: %v", err)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o600 {
		t.Errorf("mode = %o, want 600", info.Mode().Perm())
	}
	if !strings.Contains(buf.String(), path) || !strings.Contains(buf.String(), "WARN") {
		t.Errorf("expected a WARN naming the file, got %q", buf.String())
	}
}

func TestEnforceModeLeavesTightFileAndMissingFileAlone(t *testing.T) {
	dir := t.TempDir()
	tight := filepath.Join(dir, "tight.json")
	if err := os.WriteFile(tight, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(tight, 0o400); err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	log := slog.New(slog.NewTextHandler(&buf, nil))
	if err := EnforceMode(tight, 0o600, log); err != nil {
		t.Fatalf("tight file: %v", err)
	}
	if err := EnforceMode(filepath.Join(dir, "missing.json"), 0o600, log); err != nil {
		t.Fatalf("missing file: %v", err)
	}
	if buf.Len() != 0 {
		t.Errorf("unexpected log output: %s", buf.String())
	}
	if info, _ := os.Stat(tight); info.Mode().Perm() != 0o400 {
		t.Errorf("narrower mode was widened to %o", info.Mode().Perm())
	}
}

func TestEnsureDir(t *testing.T) {
	root := t.TempDir()

	created := filepath.Join(root, "a", "b")
	if err := EnsureDir(created); err != nil {
		t.Fatalf("create: %v", err)
	}
	if info, err := os.Stat(created); err != nil || !info.IsDir() {
		t.Fatalf("directory not created: %v", err)
	}
	entries, _ := os.ReadDir(created)
	if len(entries) != 0 {
		t.Errorf("write probe left files behind: %v", entries)
	}

	file := filepath.Join(root, "file")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := EnsureDir(file); err == nil || !strings.Contains(err.Error(), file) {
		t.Errorf("file path: err = %v, want error naming %s", err, file)
	}
}

func TestEnsureDirReportsUnwritable(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores directory permissions")
	}
	dir := filepath.Join(t.TempDir(), "ro")
	if err := os.Mkdir(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	if err := EnsureDir(dir); err == nil || !strings.Contains(err.Error(), dir) {
		t.Errorf("err = %v, want error naming %s", err, dir)
	}
}
```


- [ ] **Step 2: Run them and watch them fail**

```bash
cd app && go test ./internal/logging/ ./internal/store/
```

Expected: build failures: `undefined: New` (logging) and `undefined: WriteFileAtomic`, `EnforceMode`, `EnsureDir` (store).

- [ ] **Step 3: Write the implementations**

`app/internal/logging/redact.go`

```go
// Package logging builds the process logger: slog JSON with secret redaction
// (spec §10).
package logging

import (
	"io"
	"log/slog"
	"regexp"
)

// sensitiveKey matches attribute and group names that may carry a secret.
// It deliberately over-matches (for example "monkey"): a dropped harmless
// attribute costs nothing, a leaked credential costs a lot.
var sensitiveKey = regexp.MustCompile(`(?i)key|token|password|secret`)

// ReplaceAttr drops any attribute whose key, or whose enclosing group name,
// looks sensitive. Use it as slog.HandlerOptions.ReplaceAttr. It also covers
// attributes attached with With and WithGroup.
//
// It does not inspect message text or values: callers must never put a secret
// in either. The one deliberate exception is the first-run setup token, which
// auth.AnnounceSetupToken writes into the message so the operator can read it.
func ReplaceAttr(groups []string, a slog.Attr) slog.Attr {
	for _, g := range groups {
		if sensitiveKey.MatchString(g) {
			return slog.Attr{}
		}
	}
	if sensitiveKey.MatchString(a.Key) {
		return slog.Attr{}
	}
	return a
}

// New returns a JSON logger that writes to w at the given level with
// redaction applied.
func New(w io.Writer, level slog.Level) *slog.Logger {
	return slog.New(slog.NewJSONHandler(w, &slog.HandlerOptions{
		Level:       level,
		ReplaceAttr: ReplaceAttr,
	}))
}
```


`app/internal/store/store.go`

```go
// Package store holds simplarr's file-system primitives: atomic writes,
// permission enforcement and the data-directory check (spec §3.1, §5.3, D7).
package store

import (
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"syscall"
)

// WriteFileAtomic writes data to path so that readers see either the old file
// or the complete new one, never a partial write. It writes a temp file in the
// same directory, applies perm explicitly (umask does not apply), fsyncs, then
// renames over the target.
func WriteFileAtomic(path string, data []byte, perm os.FileMode) (err error) {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return fmt.Errorf("store: create temp file in %s: %w", dir, err)
	}
	tmpName := tmp.Name()
	renamed := false
	defer func() {
		if renamed {
			return
		}
		// Only our own temp file is removed; a failed removal is reported.
		if rmErr := os.Remove(tmpName); rmErr != nil && !errors.Is(rmErr, fs.ErrNotExist) {
			err = errors.Join(err, fmt.Errorf("store: remove temp file %s: %w", tmpName, rmErr))
		}
	}()

	if err := tmp.Chmod(perm); err != nil {
		return errors.Join(fmt.Errorf("store: chmod %s: %w", tmpName, err), tmp.Close())
	}
	if _, err := tmp.Write(data); err != nil {
		return errors.Join(fmt.Errorf("store: write %s: %w", tmpName, err), tmp.Close())
	}
	if err := tmp.Sync(); err != nil {
		return errors.Join(fmt.Errorf("store: sync %s: %w", tmpName, err), tmp.Close())
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("store: close %s: %w", tmpName, err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("store: rename %s to %s: %w", tmpName, path, err)
	}
	renamed = true
	return syncDir(dir)
}

// syncDir makes the rename durable. Some bind-mount file systems reject fsync
// on a directory with EINVAL or ENOTSUP; the rename has already happened, so
// only those two "not supported" answers are tolerated.
func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return fmt.Errorf("store: open dir %s: %w", dir, err)
	}
	syncErr := d.Sync()
	closeErr := d.Close()
	if syncErr != nil && !errors.Is(syncErr, syscall.EINVAL) && !errors.Is(syncErr, syscall.ENOTSUP) {
		return fmt.Errorf("store: sync dir %s: %w", dir, syncErr)
	}
	if closeErr != nil {
		return fmt.Errorf("store: close dir %s: %w", dir, closeErr)
	}
	return nil
}

// EnforceMode makes sure the file at path is no more permissive than want
// (spec §5.3). A file that is already tighter is left alone, and a missing
// file is not an error. A wider file is logged at WARN and chmodded to want;
// if the chmod fails the error names the file so the caller can refuse to
// start. There is deliberately no ownership check: Docker Desktop bind mounts
// report ownership differently from native Linux.
func EnforceMode(path string, want os.FileMode, log *slog.Logger) error {
	info, err := os.Stat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("store: stat %s: %w", path, err)
	}
	have := info.Mode().Perm()
	if have&^want == 0 {
		return nil
	}
	log.Warn("file permissions too wide, tightening", "path", path, "have", fmt.Sprintf("%04o", have), "want", fmt.Sprintf("%04o", want))
	if err := os.Chmod(path, want); err != nil {
		return fmt.Errorf("store: %s has mode %04o, wider than %04o, and chmod failed: %w", path, have, want, err)
	}
	return nil
}

// EnsureDir creates dir if needed and proves it is writable by creating and
// removing a probe file. It fails fast with a message naming the directory.
func EnsureDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("store: data directory %s: %w", dir, err)
	}
	probe, err := os.CreateTemp(dir, ".write-check-*")
	if err != nil {
		return fmt.Errorf("store: data directory %s is not writable: %w", dir, err)
	}
	name := probe.Name()
	closeErr := probe.Close()
	rmErr := os.Remove(name)
	if err := errors.Join(closeErr, rmErr); err != nil {
		return fmt.Errorf("store: data directory %s write probe: %w", dir, err)
	}
	return nil
}
```


- [ ] **Step 4: Run the tests, vet and lint**

```bash
cd app
go test ./internal/logging/ ./internal/store/ -race -cover
gofmt -l .
go vet ./...
golangci-lint run ./...
```

Expected: logging `coverage: 100.0%`; store `coverage: 7x%` (its remaining branches are I/O failures that cannot be triggered as a normal user; the 80% gate is on `internal/...` as a whole); no gofmt/vet/lint output.

- [ ] **Step 5: Leave the work uncommitted.**

---

### Task 3: Password hashing (argon2id)

**Files:**
- Create: `app/internal/auth/password.go`
- Test: `app/internal/auth/password_test.go`, `app/internal/auth/helpers_test.go`
- Modify: `app/go.mod`, create `app/go.sum` (by `go get` / `go mod tidy`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: package `auth`:
  - `type Params struct{ Memory uint32; Time uint32; Threads uint8; SaltLen, KeyLen uint32 }` and `var DefaultParams` (64 MiB = 65536 KiB, time 3, threads 2, salt 16, key 32)
  - `var ErrMalformedHash error`
  - `type Hasher`; `NewHasher(p Params, maxConcurrent int) *Hasher`
  - `(*Hasher).Hash(ctx context.Context, password string) (string, error)`: PHC string `$argon2id$v=19$m=…,t=…,p=…$salt$key`
  - `(*Hasher).Verify(ctx context.Context, encoded, password string) (bool, error)`: uses the parameters stored in `encoded`; `ErrMalformedHash` when it cannot parse; honours `ctx` while waiting for a concurrency slot
  - Test-only helpers in package `auth` (used by Tasks 4–5): `testParams`, `newTestHasher()`, `fakeClock` with `newFakeClock()`, `Now()`, `Advance(d)`, and `mustNoErr(t, err)`.

- [ ] **Step 1: Write the test helpers and the failing tests**

`app/internal/auth/helpers_test.go`

```go
package auth

import (
	"sync"
	"testing"
	"time"
)

// testParams are cheap argon2 parameters so unit tests run fast. The real
// parameters are asserted separately in TestDefaultParamsMatchSpec.
var testParams = Params{Memory: 64, Time: 1, Threads: 1, SaltLen: 16, KeyLen: 32}

func newTestHasher() *Hasher { return NewHasher(testParams, 2) }

// fakeClock is a manually advanced clock, safe for concurrent reads.
type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{t: time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

func mustNoErr(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
```


`app/internal/auth/password_test.go`

```go
package auth

import (
	"context"
	"encoding/base64"
	"errors"
	"strings"
	"sync"
	"testing"
)

func TestDefaultParamsMatchSpec(t *testing.T) {
	// Spec §8.2: memory 64 MiB, time 3, threads 2, 16-byte salt, 32-byte key.
	want := Params{Memory: 64 * 1024, Time: 3, Threads: 2, SaltLen: 16, KeyLen: 32}
	if DefaultParams != want {
		t.Errorf("DefaultParams = %+v, want %+v", DefaultParams, want)
	}
}

func TestHashAndVerify(t *testing.T) {
	h := newTestHasher()
	ctx := context.Background()
	enc, err := h.Hash(ctx, "correct horse battery")
	mustNoErr(t, err)

	ok, err := h.Verify(ctx, enc, "correct horse battery")
	if err != nil || !ok {
		t.Fatalf("Verify(correct) = %v, %v; want true, nil", ok, err)
	}
	ok, err = h.Verify(ctx, enc, "wrong horse battery")
	if err != nil || ok {
		t.Fatalf("Verify(wrong) = %v, %v; want false, nil", ok, err)
	}
}

func TestHashesAreSalted(t *testing.T) {
	h := newTestHasher()
	a, err := h.Hash(context.Background(), "same password 123")
	mustNoErr(t, err)
	b, err := h.Hash(context.Background(), "same password 123")
	mustNoErr(t, err)
	if a == b {
		t.Error("two hashes of the same password are identical: salt is not random")
	}
}

func TestEncodedHashRecordsParameters(t *testing.T) {
	enc, err := NewHasher(DefaultParams, 1).Hash(context.Background(), "a long enough password")
	mustNoErr(t, err)
	if !strings.HasPrefix(enc, "$argon2id$v=19$m=65536,t=3,p=2$") {
		t.Fatalf("encoded = %q", enc)
	}
	parts := strings.Split(enc, "$")
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	mustNoErr(t, err)
	key, err := base64.RawStdEncoding.DecodeString(parts[5])
	mustNoErr(t, err)
	if len(salt) != 16 || len(key) != 32 {
		t.Errorf("salt/key lengths = %d/%d, want 16/32", len(salt), len(key))
	}
}

func TestVerifyUsesParametersStoredWithTheHash(t *testing.T) {
	old := NewHasher(Params{Memory: 64, Time: 1, Threads: 1, SaltLen: 16, KeyLen: 32}, 1)
	enc, err := old.Hash(context.Background(), "an older password hash")
	mustNoErr(t, err)

	raised := NewHasher(Params{Memory: 128, Time: 2, Threads: 2, SaltLen: 16, KeyLen: 32}, 1)
	ok, err := raised.Verify(context.Background(), enc, "an older password hash")
	if err != nil || !ok {
		t.Fatalf("Verify with raised params = %v, %v; want true, nil", ok, err)
	}
}

func TestVerifyRejectsMalformedHashes(t *testing.T) {
	good, err := newTestHasher().Hash(context.Background(), "a long enough password")
	mustNoErr(t, err)
	parts := strings.Split(good, "$") // "", argon2id, v=19, params, salt, key

	with := func(i int, v string) string {
		c := append([]string(nil), parts...)
		c[i] = v
		return strings.Join(c, "$")
	}
	tests := map[string]string{
		"empty":           "",
		"plain text":      "not-a-hash",
		"wrong algorithm": with(1, "argon2i"),
		"wrong version":   with(2, "v=18"),
		"no params":       with(3, ""),
		"param order":     with(3, "t=1,m=64,p=1"),
		"zero time":       with(3, "m=64,t=0,p=1"),
		"zero threads":    with(3, "m=64,t=1,p=0"),
		"memory too low":  with(3, "m=4,t=1,p=1"),
		"memory absurd":   with(3, "m=4294967295,t=1,p=1"),
		"time absurd":     with(3, "m=64,t=1000,p=1"),
		"salt not b64":    with(4, "!!!"),
		"salt empty":      with(4, ""),
		"key not b64":     with(5, "!!!"),
		"key too short":   with(5, "AAAA"),
		"extra field":     good + "$extra",
	}
	for name, enc := range tests {
		t.Run(name, func(t *testing.T) {
			ok, err := newTestHasher().Verify(context.Background(), enc, "a long enough password")
			if ok || !errors.Is(err, ErrMalformedHash) {
				t.Errorf("Verify = %v, %v; want false, ErrMalformedHash", ok, err)
			}
		})
	}
}

func TestHasherBoundsConcurrencyAndStaysCorrect(t *testing.T) {
	h := NewHasher(testParams, 2)
	enc, err := h.Hash(context.Background(), "concurrent password")
	mustNoErr(t, err)

	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ok, err := h.Verify(context.Background(), enc, "concurrent password")
			if err != nil || !ok {
				t.Errorf("Verify = %v, %v", ok, err)
			}
		}()
	}
	wg.Wait()
}

func TestHasherWaitHonoursContext(t *testing.T) {
	h := NewHasher(testParams, 1)
	h.sem <- struct{}{} // occupy the only slot
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := h.Hash(ctx, "whatever password"); !errors.Is(err, context.Canceled) {
		t.Errorf("Hash err = %v, want context.Canceled", err)
	}
	if _, err := h.Verify(ctx, "$argon2id$v=19$m=64,t=1,p=1$c2FsdHNhbHRzYWx0$a2V5a2V5a2V5a2V5a2V5a2V5a2V5a2V5", "x"); !errors.Is(err, context.Canceled) {
		t.Errorf("Verify err = %v, want context.Canceled", err)
	}
}
```


- [ ] **Step 2: Run them and watch them fail**

```bash
cd app && go test ./internal/auth/
```

Expected: build failure: `undefined: Params`, `undefined: Hasher`, `undefined: NewHasher`.

- [ ] **Step 3: Add the dependency and write the implementation**

```bash
cd app && go get golang.org/x/crypto@v0.55.0
```

`app/internal/auth/password.go`

```go
// Package auth implements the admin password, first-run setup token, sessions,
// CSRF tokens and login rate limiting (spec §8.2).
package auth

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"golang.org/x/crypto/argon2"
)

// Params are the argon2id cost parameters. Memory is in KiB.
type Params struct {
	Memory  uint32
	Time    uint32
	Threads uint8
	SaltLen uint32
	KeyLen  uint32
}

// DefaultParams are the spec §8.2 values: 64 MiB, time 3, 2 threads,
// 16-byte salt, 32-byte key.
var DefaultParams = Params{Memory: 64 * 1024, Time: 3, Threads: 2, SaltLen: 16, KeyLen: 32}

// ErrMalformedHash means a stored password hash could not be parsed.
var ErrMalformedHash = errors.New("auth: malformed password hash")

// Limits applied when parsing a stored hash, so a corrupt admin.json cannot
// make Verify allocate gigabytes or spin for minutes.
const (
	maxMemoryKiB = 1 << 20 // 1 GiB
	maxTime      = 20
	minKeyLen    = 16
	maxFieldLen  = 1024
)

// Hasher hashes and verifies passwords with argon2id. Each hash needs
// Params.Memory of RAM, so at most maxConcurrent run at once; the rest wait,
// or give up when their context ends. That keeps a flood of login attempts
// from exhausting memory.
type Hasher struct {
	params Params
	sem    chan struct{}
}

// NewHasher returns a Hasher. maxConcurrent below 1 is treated as 1.
func NewHasher(p Params, maxConcurrent int) *Hasher {
	if maxConcurrent < 1 {
		maxConcurrent = 1
	}
	return &Hasher{params: p, sem: make(chan struct{}, maxConcurrent)}
}

func (h *Hasher) acquire(ctx context.Context) error {
	select {
	case h.sem <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (h *Hasher) release() { <-h.sem }

// Hash returns a PHC-format argon2id string that records its own parameters:
//
//	$argon2id$v=19$m=65536,t=3,p=2$<salt>$<key>
//
// so the parameters can be raised later without invalidating existing hashes.
func (h *Hasher) Hash(ctx context.Context, password string) (string, error) {
	if err := h.acquire(ctx); err != nil {
		return "", err
	}
	defer h.release()

	salt := make([]byte, h.params.SaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("auth: generate salt: %w", err)
	}
	key := argon2.IDKey([]byte(password), salt, h.params.Time, h.params.Memory, h.params.Threads, h.params.KeyLen)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, h.params.Memory, h.params.Time, h.params.Threads,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key)), nil
}

// Verify reports whether password matches encoded, using the parameters stored
// in encoded (not the Hasher's). It returns ErrMalformedHash when encoded
// cannot be parsed.
func (h *Hasher) Verify(ctx context.Context, encoded, password string) (bool, error) {
	if err := h.acquire(ctx); err != nil {
		return false, err
	}
	defer h.release()

	p, salt, want, err := decodeHash(encoded)
	if err != nil {
		return false, err
	}
	got := argon2.IDKey([]byte(password), salt, p.Time, p.Memory, p.Threads, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1, nil
}

// decodeHash parses and range-checks a PHC argon2id string.
func decodeHash(encoded string) (Params, []byte, []byte, error) {
	parts := strings.Split(encoded, "$")
	switch {
	case len(parts) != 6 || parts[0] != "":
		return malformed("expected $argon2id$v=..$m=..,t=..,p=..$salt$key")
	case parts[1] != "argon2id":
		return malformed("algorithm is not argon2id")
	case parts[2] != "v="+strconv.Itoa(argon2.Version):
		return malformed("unsupported argon2 version " + parts[2])
	}
	p, err := parseParams(parts[3])
	if err != nil {
		return Params{}, nil, nil, err
	}
	salt, err := decodeField(parts[4], 1)
	if err != nil {
		return Params{}, nil, nil, fmt.Errorf("%w: salt is not valid", ErrMalformedHash)
	}
	key, err := decodeField(parts[5], minKeyLen)
	if err != nil {
		return Params{}, nil, nil, fmt.Errorf("%w: key is not valid", ErrMalformedHash)
	}
	return p, salt, key, nil
}

func malformed(why string) (Params, []byte, []byte, error) {
	return Params{}, nil, nil, fmt.Errorf("%w: %s", ErrMalformedHash, why)
}

// parseParams reads "m=..,t=..,p=.." and range-checks the numbers.
func parseParams(s string) (Params, error) {
	bad := func(why string) (Params, error) {
		return Params{}, fmt.Errorf("%w: %s", ErrMalformedHash, why)
	}
	fields := strings.Split(s, ",")
	if len(fields) != 3 {
		return bad("parameters must be m=..,t=..,p=..")
	}
	var nums [3]uint64
	for i, name := range []string{"m", "t", "p"} {
		v, ok := strings.CutPrefix(fields[i], name+"=")
		if !ok {
			return bad("parameters must be m=..,t=..,p=..")
		}
		bits := 32
		if name == "p" {
			bits = 8
		}
		n, err := strconv.ParseUint(v, 10, bits)
		if err != nil {
			return bad("parameter " + name + " is not a valid number")
		}
		nums[i] = n
	}
	p := Params{Memory: uint32(nums[0]), Time: uint32(nums[1]), Threads: uint8(nums[2])}
	if p.Time < 1 || p.Time > maxTime || p.Threads < 1 || p.Memory < 8*uint32(p.Threads) || p.Memory > maxMemoryKiB {
		return bad("parameters out of range")
	}
	return p, nil
}

// decodeField decodes unpadded base64 and enforces minLen <= len <= maxFieldLen.
func decodeField(s string, minLen int) ([]byte, error) {
	b, err := base64.RawStdEncoding.DecodeString(s)
	if err != nil {
		return nil, err
	}
	if len(b) < minLen || len(b) > maxFieldLen {
		return nil, fmt.Errorf("length %d outside %d..%d", len(b), minLen, maxFieldLen)
	}
	return b, nil
}
```


```bash
cd app && go mod tidy
```

Expected: `go.mod` now requires `golang.org/x/crypto v0.55.0` and lists `golang.org/x/sys` as indirect; `go.sum` exists. If `go get` upgrades to a version that needs Go 1.26, you ran it without the `@v0.55.0` suffix.

- [ ] **Step 4: Run the tests and vet**

```bash
cd app
go test ./internal/auth/ -race -cover
gofmt -l .
go vet ./...
```

Expected: `ok … coverage: 9x%`; no other output. Skip `golangci-lint` for this task: the shared helpers in `helpers_test.go` are first used by Task 4, so `unused` would flag them here.

- [ ] **Step 5: Leave the work uncommitted.**

---

### Task 4: Setup tokens, sessions, CSRF match and the login rate limiter

**Files:**
- Create: `app/internal/auth/tokens.go`, `app/internal/auth/session.go`, `app/internal/auth/ratelimit.go`
- Test: `app/internal/auth/tokens_test.go`, `app/internal/auth/session_test.go`, `app/internal/auth/ratelimit_test.go`

**Interfaces:**
- Consumes: Task 2 `logging.New` (used by `tokens_test.go`); Task 3 test helpers `fakeClock`, `mustNoErr`.
- Produces:
  - `auth.GenerateToken() (string, error)`: 256 random bits, unpadded base64url (43 characters)
  - `auth.NewSetupToken() (string, error)`: 128 random bits, 32 hex characters
  - `auth.TokensMatch(session, cookie, header string) bool`: all three present and equal, constant time
  - `auth.AnnounceSetupToken(log *slog.Logger, token string)`: WARN, the token in the **message** (attributes named `token` are redacted)
  - `type Session struct{ ID, CSRF string; Expires time.Time }`
  - `auth.NewSessions(ttl time.Duration, now func() time.Time) *Sessions`; methods `TTL() time.Duration`, `Create() (Session, error)`, `Get(id string) (Session, bool)`, `Delete(id string)`
  - `auth.NewLimiter(max int, window time.Duration, now func() time.Time) *Limiter`; methods `Allow(key string) (ok bool, retryAfter time.Duration)` (atomic check + charge; refused attempts are not recorded) and `Reset(key string)`

- [ ] **Step 1: Write the failing tests**

`app/internal/auth/tokens_test.go`

```go
package auth

import (
	"bytes"
	"encoding/hex"
	"log/slog"
	"strings"
	"testing"

	"github.com/parsoFish/simplarr/app/internal/logging"
)

func TestGenerateTokenIsRandomAndURLSafe(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 50; i++ {
		tok, err := GenerateToken()
		mustNoErr(t, err)
		if len(tok) != 43 { // 32 bytes, unpadded base64url
			t.Fatalf("len(token) = %d, want 43 (256 bits)", len(tok))
		}
		if strings.ContainsAny(tok, "+/=") {
			t.Fatalf("token %q is not URL-safe", tok)
		}
		if seen[tok] {
			t.Fatalf("duplicate token %q", tok)
		}
		seen[tok] = true
	}
}

func TestNewSetupTokenIs128BitHex(t *testing.T) {
	tok, err := NewSetupToken()
	mustNoErr(t, err)
	raw, err := hex.DecodeString(tok)
	if err != nil || len(raw) != 16 {
		t.Errorf("token %q: want 32 hex chars (128 bits), decode err %v, %d bytes", tok, err, len(raw))
	}
}

func TestTokensMatch(t *testing.T) {
	tests := []struct {
		name                  string
		session, cookie, head string
		want                  bool
	}{
		{"all equal", "abc", "abc", "abc", true},
		{"header differs", "abc", "abc", "abd", false},
		{"cookie differs", "abc", "abd", "abc", false},
		{"session differs", "abd", "abc", "abc", false},
		{"cookie and header equal but not session", "xyz", "abc", "abc", false},
		{"header missing", "abc", "abc", "", false},
		{"cookie missing", "abc", "", "abc", false},
		{"all empty", "", "", "", false},
		{"length differs", "abc", "abc", "abcd", false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := TokensMatch(tc.session, tc.cookie, tc.head); got != tc.want {
				t.Errorf("TokensMatch = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestAnnounceSetupTokenWritesTheTokenToTheMessage(t *testing.T) {
	var buf bytes.Buffer
	AnnounceSetupToken(logging.New(&buf, slog.LevelInfo), "0123456789abcdef0123456789abcdef")
	out := buf.String()
	for _, want := range []string{`"level":"WARN"`, "First-run setup token: 0123456789abcdef0123456789abcdef", "/setup"} {
		if !strings.Contains(out, want) {
			t.Errorf("output %q missing %q", out, want)
		}
	}
}

func TestSetupTokenAsAttributeIsRedacted(t *testing.T) {
	var buf bytes.Buffer
	logging.New(&buf, slog.LevelInfo).Warn("setup", "setupToken", "0123456789abcdef0123456789abcdef")
	if strings.Contains(buf.String(), "0123456789abcdef") {
		t.Errorf("token leaked through an attribute: %s", buf.String())
	}
}
```


`app/internal/auth/session_test.go`

```go
package auth

import (
	"sync"
	"testing"
	"time"
)

const testTTL = 7 * 24 * time.Hour

func TestSessionCreateAndGet(t *testing.T) {
	clock := newFakeClock()
	s := NewSessions(testTTL, clock.Now)

	a, err := s.Create()
	mustNoErr(t, err)
	b, err := s.Create()
	mustNoErr(t, err)

	if a.ID == b.ID || a.CSRF == b.CSRF || a.ID == a.CSRF {
		t.Errorf("sessions must have distinct random IDs and CSRF tokens: %+v %+v", a, b)
	}
	if !a.Expires.Equal(clock.Now().Add(testTTL)) {
		t.Errorf("Expires = %v, want now+7d", a.Expires)
	}
	got, ok := s.Get(a.ID)
	if !ok || got != a {
		t.Errorf("Get = %+v, %v; want %+v, true", got, ok, a)
	}
	if _, ok := s.Get("unknown"); ok {
		t.Error("Get(unknown) = true")
	}
	if _, ok := s.Get(""); ok {
		t.Error("Get(\"\") = true")
	}
}

func TestSessionExpires(t *testing.T) {
	clock := newFakeClock()
	s := NewSessions(testTTL, clock.Now)
	sess, err := s.Create()
	mustNoErr(t, err)

	clock.Advance(testTTL - time.Second)
	if _, ok := s.Get(sess.ID); !ok {
		t.Fatal("session expired early")
	}
	clock.Advance(time.Second)
	if _, ok := s.Get(sess.ID); ok {
		t.Fatal("session still valid at its expiry time")
	}
	if len(s.m) != 0 {
		t.Errorf("expired session was not removed: %d entries", len(s.m))
	}
}

func TestSessionDelete(t *testing.T) {
	s := NewSessions(testTTL, newFakeClock().Now)
	sess, err := s.Create()
	mustNoErr(t, err)
	s.Delete(sess.ID)
	if _, ok := s.Get(sess.ID); ok {
		t.Error("session survived Delete")
	}
	s.Delete("never existed") // must not panic
}

func TestSessionCreateSweepsExpired(t *testing.T) {
	clock := newFakeClock()
	s := NewSessions(time.Hour, clock.Now)
	for i := 0; i < 5; i++ {
		_, err := s.Create()
		mustNoErr(t, err)
	}
	clock.Advance(2 * time.Hour)
	_, err := s.Create()
	mustNoErr(t, err)
	if len(s.m) != 1 {
		t.Errorf("entries = %d, want 1 after sweep", len(s.m))
	}
}

func TestSessionsAreSafeForConcurrentUse(t *testing.T) {
	s := NewSessions(testTTL, newFakeClock().Now)
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			sess, err := s.Create()
			if err != nil {
				t.Error(err)
				return
			}
			if _, ok := s.Get(sess.ID); !ok {
				t.Error("own session not found")
			}
			s.Delete(sess.ID)
		}()
	}
	wg.Wait()
}
```


`app/internal/auth/ratelimit_test.go`

```go
package auth

import (
	"sync"
	"testing"
	"time"
)

const (
	testMaxAttempts = 5
	testWindow      = 15 * time.Minute
)

func newTestLimiter(clock *fakeClock) *Limiter {
	return NewLimiter(testMaxAttempts, testWindow, clock.Now)
}

func TestLimiterRefusesTheAttemptAfterMax(t *testing.T) {
	l := newTestLimiter(newFakeClock())

	for i := 1; i <= testMaxAttempts; i++ {
		if ok, _ := l.Allow("10.0.0.1"); !ok {
			t.Fatalf("attempt %d refused, want it allowed", i)
		}
	}
	ok, retry := l.Allow("10.0.0.1")
	if ok {
		t.Fatal("attempt 6 allowed, want it refused")
	}
	if retry <= 0 || retry > testWindow {
		t.Errorf("retryAfter = %v, want in (0, 15m]", retry)
	}
}

func TestLimiterTracksEachKeySeparately(t *testing.T) {
	l := newTestLimiter(newFakeClock())
	for i := 0; i < testMaxAttempts; i++ {
		l.Allow("10.0.0.1")
	}
	if ok, _ := l.Allow("10.0.0.2"); !ok {
		t.Error("a different IP was refused")
	}
}

func TestLimiterAttemptsExpire(t *testing.T) {
	clock := newFakeClock()
	l := newTestLimiter(clock)
	for i := 0; i < testMaxAttempts; i++ {
		l.Allow("10.0.0.1")
	}
	clock.Advance(testWindow - time.Second)
	if ok, retry := l.Allow("10.0.0.1"); ok || retry != time.Second {
		t.Errorf("Allow = %v, %v; want false, 1s", ok, retry)
	}
	clock.Advance(time.Second)
	if ok, _ := l.Allow("10.0.0.1"); !ok {
		t.Error("still refused after the window")
	}
}

func TestLimiterRefusedAttemptsDoNotExtendTheBlock(t *testing.T) {
	clock := newFakeClock()
	l := newTestLimiter(clock)
	for i := 0; i < testMaxAttempts; i++ {
		l.Allow("ip")
	}
	clock.Advance(10 * time.Minute)
	for i := 0; i < 20; i++ { // hammering while blocked
		l.Allow("ip")
	}
	clock.Advance(5*time.Minute + time.Second) // the first five have now left the window
	if ok, _ := l.Allow("ip"); !ok {
		t.Error("refused attempts extended the block")
	}
}

func TestLimiterWindowSlides(t *testing.T) {
	clock := newFakeClock()
	l := newTestLimiter(clock)
	for i := 0; i < testMaxAttempts-1; i++ { // 4 attempts at t=0
		l.Allow("ip")
	}
	clock.Advance(10 * time.Minute)
	if ok, _ := l.Allow("ip"); !ok { // 5th at t=10m
		t.Fatal("5th attempt refused")
	}
	if ok, _ := l.Allow("ip"); ok {
		t.Fatal("6th attempt allowed")
	}
	clock.Advance(5*time.Minute + time.Second) // t=15m01s: the four old ones expired
	for i := 0; i < testMaxAttempts-1; i++ {
		if ok, _ := l.Allow("ip"); !ok {
			t.Fatalf("attempt %d after the window slid was refused", i+1)
		}
	}
	if ok, _ := l.Allow("ip"); ok {
		t.Error("allowed more than max inside the window")
	}
}

func TestLimiterResetClearsAttempts(t *testing.T) {
	l := newTestLimiter(newFakeClock())
	for i := 0; i < testMaxAttempts; i++ {
		l.Allow("ip")
	}
	l.Reset("ip")
	if ok, _ := l.Allow("ip"); !ok {
		t.Error("refused after Reset")
	}
	l.Reset("never seen") // must not panic
}

func TestLimiterIsAtomicUnderConcurrency(t *testing.T) {
	l := newTestLimiter(newFakeClock())
	const callers = 64
	var wg sync.WaitGroup
	var mu sync.Mutex
	allowed := 0
	for i := 0; i < callers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if ok, _ := l.Allow("ip"); ok {
				mu.Lock()
				allowed++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if allowed != testMaxAttempts {
		t.Errorf("allowed = %d, want exactly %d", allowed, testMaxAttempts)
	}
}

func TestLimiterCapsTrackedKeys(t *testing.T) {
	clock := newFakeClock()
	l := newTestLimiter(clock)
	l.maxKeys = 3

	l.Allow("a")
	clock.Advance(time.Second)
	l.Allow("b")
	clock.Advance(time.Second)
	l.Allow("c")
	clock.Advance(time.Second)
	l.Allow("d") // at the cap: evicts the key with the oldest attempt ("a")

	if len(l.attempts) != 3 {
		t.Fatalf("tracked keys = %d, want 3", len(l.attempts))
	}
	if _, ok := l.attempts["a"]; ok {
		t.Error("oldest key was not evicted")
	}
	if _, ok := l.attempts["d"]; !ok {
		t.Error("new key was not tracked")
	}
}

func TestLimiterCapEvictionDropsExpiredFirst(t *testing.T) {
	clock := newFakeClock()
	l := newTestLimiter(clock)
	l.maxKeys = 2
	l.Allow("old1")
	l.Allow("old2")
	clock.Advance(testWindow + time.Second)
	l.Allow("fresh")
	if len(l.attempts) != 1 {
		t.Errorf("tracked keys = %d, want 1 (both expired keys swept)", len(l.attempts))
	}
}
```


- [ ] **Step 2: Run them and watch them fail**

```bash
cd app && go test ./internal/auth/
```

Expected: build failure: `undefined: GenerateToken`, `undefined: NewSessions`, `undefined: NewLimiter`, and so on.

- [ ] **Step 3: Write the implementations**

`app/internal/auth/tokens.go`

```go
package auth

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"log/slog"
)

// GenerateToken returns 256 random bits as unpadded base64url. It is used for
// session IDs and CSRF tokens.
func GenerateToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("auth: generate token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// NewSetupToken returns the 128-bit first-run setup token as 32 hex characters.
func NewSetupToken() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("auth: generate setup token: %w", err)
	}
	return hex.EncodeToString(b), nil
}

// TokensMatch implements the double-submit CSRF check, bound to the session:
// the token stored in the session, the one in the CSRF cookie and the one in
// the X-CSRF-Token header must all be present and equal.
func TokensMatch(session, cookie, header string) bool {
	if session == "" {
		return false
	}
	a := subtle.ConstantTimeCompare([]byte(session), []byte(cookie))
	b := subtle.ConstantTimeCompare([]byte(session), []byte(header))
	return a&b == 1
}

// AnnounceSetupToken logs the setup token once at WARN so the operator can
// read it from `docker logs`. The token goes in the message text on purpose:
// the logging package redacts attributes named like secrets, so it would
// vanish from an attribute. This is the only place a secret is logged.
func AnnounceSetupToken(log *slog.Logger, token string) {
	log.Warn("First-run setup token: " + token + " (enter it at http://<host>/setup)")
}
```


`app/internal/auth/session.go`

```go
package auth

import (
	"crypto/sha256"
	"sync"
	"time"
)

// Session is one logged-in browser. CSRF is the token that the csrf cookie and
// the X-CSRF-Token header must both equal.
type Session struct {
	ID      string
	CSRF    string
	Expires time.Time
}

// Sessions is an in-memory session store with an absolute TTL. A restart logs
// everyone out, which is acceptable in milestone 1 (spec §8.2). IDs are
// stored as SHA-256 digests so the map never holds a usable credential.
type Sessions struct {
	mu  sync.Mutex
	ttl time.Duration
	now func() time.Time
	m   map[[32]byte]Session
}

// NewSessions returns an empty store. now is injected so tests control time.
func NewSessions(ttl time.Duration, now func() time.Time) *Sessions {
	return &Sessions{ttl: ttl, now: now, m: make(map[[32]byte]Session)}
}

// TTL is how long a session lives, for cookie lifetimes.
func (s *Sessions) TTL() time.Duration { return s.ttl }

func sessionKey(id string) [32]byte { return sha256.Sum256([]byte(id)) }

// Create starts a session with a fresh 256-bit ID and CSRF token. A new ID on
// every login means a pre-login session ID is never reused (no fixation).
func (s *Sessions) Create() (Session, error) {
	id, err := GenerateToken()
	if err != nil {
		return Session{}, err
	}
	csrf, err := GenerateToken()
	if err != nil {
		return Session{}, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	s.sweepLocked(now)
	sess := Session{ID: id, CSRF: csrf, Expires: now.Add(s.ttl)}
	s.m[sessionKey(id)] = sess
	return sess, nil
}

// Get returns the live session for id. An expired session is removed.
func (s *Sessions) Get(id string) (Session, bool) {
	if id == "" {
		return Session{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	key := sessionKey(id)
	sess, ok := s.m[key]
	if !ok {
		return Session{}, false
	}
	if !s.now().Before(sess.Expires) {
		delete(s.m, key)
		return Session{}, false
	}
	return sess, true
}

// Delete ends a session. Deleting an unknown ID is a no-op.
func (s *Sessions) Delete(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.m, sessionKey(id))
}

func (s *Sessions) sweepLocked(now time.Time) {
	for k, sess := range s.m {
		if !now.Before(sess.Expires) {
			delete(s.m, k)
		}
	}
}
```


`app/internal/auth/ratelimit.go`

```go
package auth

import (
	"sync"
	"time"
)

const defaultMaxTrackedKeys = 10_000

// Limiter allows each key (a client IP) at most max attempts inside a sliding
// window (spec §8.2: 5 failures per 15 minutes). golang.org/x/time/rate is a
// token bucket and cannot express "block after N attempts, reset on success";
// this is a fixed rule in about 70 lines.
//
// Allow checks and charges in one step, before the password is verified.
// Recording failures afterwards would leave a gap in which a burst of parallel
// requests all pass a "not blocked yet" check; charging first closes it. A
// successful login calls Reset, so honest users never accumulate attempts.
type Limiter struct {
	mu       sync.Mutex
	max      int
	window   time.Duration
	now      func() time.Time
	maxKeys  int
	attempts map[string][]time.Time // ascending attempt times per key
}

// NewLimiter returns a Limiter. now is injected so tests control time.
func NewLimiter(max int, window time.Duration, now func() time.Time) *Limiter {
	return &Limiter{
		max: max, window: window, now: now,
		maxKeys:  defaultMaxTrackedKeys,
		attempts: make(map[string][]time.Time),
	}
}

// Allow records an attempt for key and reports whether it may proceed. When
// it may not, retryAfter is how long until the oldest attempt leaves the
// window. A refused attempt is not recorded, so a block never extends itself.
func (l *Limiter) Allow(key string) (ok bool, retryAfter time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	recent := l.pruneLocked(key, now)
	if len(recent) >= l.max {
		return false, recent[0].Add(l.window).Sub(now)
	}
	if _, tracked := l.attempts[key]; !tracked && len(l.attempts) >= l.maxKeys {
		l.makeRoomLocked(now)
	}
	l.attempts[key] = append(recent, now)
	return true, 0
}

// Reset forgets key's attempts, after a successful login or setup.
func (l *Limiter) Reset(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.attempts, key)
}

// pruneLocked drops attempts that left the window and returns what remains.
func (l *Limiter) pruneLocked(key string, now time.Time) []time.Time {
	ts, ok := l.attempts[key]
	if !ok {
		return nil
	}
	cutoff := now.Add(-l.window)
	i := 0
	for i < len(ts) && !ts[i].After(cutoff) {
		i++
	}
	if i == len(ts) {
		delete(l.attempts, key)
		return nil
	}
	kept := append([]time.Time(nil), ts[i:]...)
	l.attempts[key] = kept
	return kept
}

// makeRoomLocked frees one slot: expired keys first, otherwise the key whose
// newest attempt is oldest. That bounds memory even if a client can vary the
// key it presents.
func (l *Limiter) makeRoomLocked(now time.Time) {
	for k := range l.attempts {
		l.pruneLocked(k, now)
	}
	if len(l.attempts) < l.maxKeys {
		return
	}
	var oldestKey string
	var oldest time.Time
	first := true
	for k, ts := range l.attempts {
		newest := ts[len(ts)-1]
		if first || newest.Before(oldest) {
			oldestKey, oldest, first = k, newest, false
		}
	}
	delete(l.attempts, oldestKey)
}
```


- [ ] **Step 4: Run the tests, vet and lint**

```bash
cd app
go test ./internal/auth/ -race -cover
gofmt -l .
go vet ./...
golangci-lint run ./...
```

Expected: `ok … coverage: 9x%`; no other output.

- [ ] **Step 5: Leave the work uncommitted.**

---

### Task 5: Admin service (setup, login, logout)

**Files:**
- Create: `app/internal/auth/service.go`
- Test: `app/internal/auth/service_test.go`

**Interfaces:**
- Consumes: Task 2 `store.EnforceMode`, `store.WriteFileAtomic`; Task 3 `Hasher`, `decodeHash`; Task 4 `NewSetupToken`, `Sessions`, `Session`.
- Produces:
  - errors `ErrSetupRequired`, `ErrSetupComplete`, `ErrInvalidSetupToken`, `ErrInvalidCredentials`, `ErrWeakPassword` (use `errors.Is`)
  - `type ServiceConfig struct{ DataDir string; Hasher *Hasher; Sessions *Sessions; Logger *slog.Logger }`
  - `auth.NewService(c ServiceConfig) (*Service, error)`: reads `<DataDir>/admin.json`; missing → setup mode with a new token; unparseable → error naming the file (it must never silently re-open setup)
  - `(*Service)` methods: `SetupRequired() bool`, `PendingSetupToken() (string, bool)`, `SessionTTL() time.Duration`, `Setup(ctx, token, password string) error`, `Login(ctx, password string) (Session, error)`, `Session(id string) (Session, bool)`, `Logout(id string)`
  - `auth.ValidatePassword(p string) error`: at least 12 characters (runes), at most 1024 bytes; wraps `ErrWeakPassword`
  - `admin.json` shape: `{"version": 1, "passwordHash": "$argon2id$…"}`, mode 0600, written atomically

- [ ] **Step 1: Write the failing test**

`app/internal/auth/service_test.go`

```go
package auth

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

const goodPassword = "a perfectly good password"

func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func newTestService(t *testing.T, dir string) (*Service, *fakeClock) {
	t.Helper()
	clock := newFakeClock()
	svc, err := NewService(ServiceConfig{
		DataDir:  dir,
		Hasher:   newTestHasher(),
		Sessions: NewSessions(testTTL, clock.Now),
		Logger:   quietLogger(),
	})
	if err != nil {
		t.Fatalf("NewService: %v", err)
	}
	return svc, clock
}

func completeSetup(t *testing.T, svc *Service) {
	t.Helper()
	tok, ok := svc.PendingSetupToken()
	if !ok {
		t.Fatal("no pending setup token")
	}
	mustNoErr(t, svc.Setup(context.Background(), tok, goodPassword))
}

func TestFreshServiceNeedsSetup(t *testing.T) {
	svc, _ := newTestService(t, t.TempDir())
	if !svc.SetupRequired() {
		t.Error("SetupRequired = false on an empty data dir")
	}
	tok, ok := svc.PendingSetupToken()
	if !ok || len(tok) != 32 {
		t.Errorf("PendingSetupToken = %q, %v; want 32 hex chars", tok, ok)
	}
	if _, err := svc.Login(context.Background(), goodPassword); !errors.Is(err, ErrSetupRequired) {
		t.Errorf("Login before setup: err = %v, want ErrSetupRequired", err)
	}
}

func TestSetupRejectsWrongTokenAndWeakPasswords(t *testing.T) {
	dir := t.TempDir()
	svc, _ := newTestService(t, dir)
	tok, _ := svc.PendingSetupToken()
	ctx := context.Background()

	for _, bad := range []string{"", "wrong", strings.ToUpper(tok), tok + "0"} {
		if err := svc.Setup(ctx, bad, goodPassword); !errors.Is(err, ErrInvalidSetupToken) {
			t.Errorf("token %q: err = %v, want ErrInvalidSetupToken", bad, err)
		}
	}
	for name, pw := range map[string]string{
		"empty":      "",
		"short":      "elevenchars",
		"too long":   strings.Repeat("x", maxPasswordBytes+1),
		"11 unicode": "ééééééééééé",
		"11 spaces":  "           ",
	} {
		if err := svc.Setup(ctx, tok, pw); !errors.Is(err, ErrWeakPassword) {
			t.Errorf("%s: err = %v, want ErrWeakPassword", name, err)
		}
	}
	if !svc.SetupRequired() {
		t.Error("failed attempts completed setup")
	}
	if _, err := os.Stat(filepath.Join(dir, "admin.json")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("admin.json exists after failed setup: %v", err)
	}
}

func TestPasswordPolicyCountsCharactersNotBytes(t *testing.T) {
	if err := ValidatePassword("ééééééééééé"); err == nil { // 11 runes, 22 bytes
		t.Error("11 characters accepted")
	}
	if err := ValidatePassword("éééééééééééé"); err != nil { // 12 runes
		t.Errorf("12 characters rejected: %v", err)
	}
	if err := ValidatePassword(strings.Repeat("x", maxPasswordBytes)); err != nil {
		t.Errorf("max length rejected: %v", err)
	}
}

func TestSetupWritesAdminFileAndIsOneShot(t *testing.T) {
	dir := t.TempDir()
	svc, _ := newTestService(t, dir)
	tok, _ := svc.PendingSetupToken()
	mustNoErr(t, svc.Setup(context.Background(), tok, goodPassword))

	path := filepath.Join(dir, "admin.json")
	info, err := os.Stat(path)
	mustNoErr(t, err)
	if info.Mode().Perm() != 0o600 {
		t.Errorf("admin.json mode = %o, want 600", info.Mode().Perm())
	}
	raw, _ := os.ReadFile(path)
	if !strings.Contains(string(raw), `"version": 1`) {
		t.Errorf("admin.json has no version: %s", raw)
	}
	if !strings.Contains(string(raw), "$argon2id$") || strings.Contains(string(raw), goodPassword) {
		t.Errorf("admin.json must hold an argon2id hash and never the password: %s", raw)
	}

	if svc.SetupRequired() {
		t.Error("SetupRequired = true after setup")
	}
	if _, ok := svc.PendingSetupToken(); ok {
		t.Error("setup token still valid after setup")
	}
	if err := svc.Setup(context.Background(), tok, "another good password"); !errors.Is(err, ErrSetupComplete) {
		t.Errorf("second Setup: err = %v, want ErrSetupComplete", err)
	}
}

func TestConcurrentSetupHasExactlyOneWinner(t *testing.T) {
	svc, _ := newTestService(t, t.TempDir())
	tok, _ := svc.PendingSetupToken()

	var wg sync.WaitGroup
	results := make(chan error, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results <- svc.Setup(context.Background(), tok, goodPassword)
		}()
	}
	wg.Wait()
	close(results)

	wins, complete := 0, 0
	for err := range results {
		switch {
		case err == nil:
			wins++
		case errors.Is(err, ErrSetupComplete):
			complete++
		default:
			t.Errorf("unexpected error: %v", err)
		}
	}
	if wins != 1 || complete != 7 {
		t.Errorf("wins = %d, complete = %d; want 1 and 7", wins, complete)
	}
}

func TestLoginLogoutAndSessionLookup(t *testing.T) {
	svc, _ := newTestService(t, t.TempDir())
	completeSetup(t, svc)
	ctx := context.Background()

	if _, err := svc.Login(ctx, "the wrong password"); !errors.Is(err, ErrInvalidCredentials) {
		t.Errorf("wrong password: err = %v, want ErrInvalidCredentials", err)
	}
	sess, err := svc.Login(ctx, goodPassword)
	mustNoErr(t, err)
	got, ok := svc.Session(sess.ID)
	if !ok || got != sess {
		t.Errorf("Session = %+v, %v; want %+v, true", got, ok, sess)
	}
	svc.Logout(sess.ID)
	if _, ok := svc.Session(sess.ID); ok {
		t.Error("session survived Logout")
	}
	if svc.SessionTTL() != testTTL {
		t.Errorf("SessionTTL = %v", svc.SessionTTL())
	}
}

func TestAdminHashSurvivesRestart(t *testing.T) {
	dir := t.TempDir()
	first, _ := newTestService(t, dir)
	completeSetup(t, first)

	second, _ := newTestService(t, dir)
	if second.SetupRequired() {
		t.Fatal("SetupRequired = true after restart with admin.json present")
	}
	if _, ok := second.PendingSetupToken(); ok {
		t.Error("a setup token was issued although an admin exists")
	}
	if _, err := second.Login(context.Background(), goodPassword); err != nil {
		t.Errorf("Login after restart: %v", err)
	}
}

func TestCorruptAdminFileFailsFastAndNamesTheFile(t *testing.T) {
	good, err := newTestHasher().Hash(context.Background(), goodPassword)
	mustNoErr(t, err)
	cases := map[string]string{
		"not json":     "{{{",
		"empty object": "{}",
		"wrong ver":    `{"version":2,"passwordHash":"` + good + `"}`,
		"empty hash":   `{"version":1,"passwordHash":""}`,
		"bad hash":     `{"version":1,"passwordHash":"plaintext"}`,
		"unknown key":  `{"version":1,"passwordHash":"` + good + `","extra":true}`,
	}
	for name, content := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "admin.json")
			mustNoErr(t, os.WriteFile(path, []byte(content), 0o600))
			_, err := NewService(ServiceConfig{
				DataDir: dir, Hasher: newTestHasher(),
				Sessions: NewSessions(testTTL, newFakeClock().Now), Logger: quietLogger(),
			})
			if err == nil || !strings.Contains(err.Error(), path) {
				t.Errorf("err = %v, want error naming %s", err, path)
			}
		})
	}
}

func TestWideAdminFileIsTightenedAtStartup(t *testing.T) {
	dir := t.TempDir()
	first, _ := newTestService(t, dir)
	completeSetup(t, first)
	path := filepath.Join(dir, "admin.json")
	mustNoErr(t, os.Chmod(path, 0o644))

	newTestService(t, dir)
	info, err := os.Stat(path)
	mustNoErr(t, err)
	if info.Mode().Perm() != 0o600 {
		t.Errorf("mode = %o, want 600", info.Mode().Perm())
	}
}

func TestNewServiceUnreadableAdminFile(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read anything")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "admin.json")
	mustNoErr(t, os.WriteFile(path, []byte("{}"), 0o000))
	_, err := NewService(ServiceConfig{
		DataDir: dir, Hasher: newTestHasher(),
		Sessions: NewSessions(testTTL, newFakeClock().Now), Logger: quietLogger(),
	})
	if err == nil || !strings.Contains(err.Error(), path) {
		t.Errorf("err = %v, want error naming %s", err, path)
	}
}
```


- [ ] **Step 2: Run it and watch it fail**

```bash
cd app && go test ./internal/auth/
```

Expected: build failure: `undefined: Service`, `undefined: ServiceConfig`, `undefined: NewService`, `undefined: ErrSetupRequired`, `undefined: ValidatePassword`.

- [ ] **Step 3: Write the implementation**

`app/internal/auth/service.go`

```go
package auth

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/parsoFish/simplarr/app/internal/store"
)

const (
	adminFileName    = "admin.json"
	adminFileVersion = 1
	adminFileMode    = os.FileMode(0o600)

	minPasswordRunes = 12
	maxPasswordBytes = 1024
)

// Errors the API layer maps to responses.
var (
	ErrSetupRequired      = errors.New("auth: first-run setup has not been completed")
	ErrSetupComplete      = errors.New("auth: first-run setup is already complete")
	ErrInvalidSetupToken  = errors.New("auth: invalid setup token")
	ErrInvalidCredentials = errors.New("auth: invalid password")
	ErrWeakPassword       = errors.New("auth: password does not meet the policy")
)

// adminFile is the on-disk shape of /data/admin.json.
type adminFile struct {
	Version      int    `json:"version"`
	PasswordHash string `json:"passwordHash"`
}

// ServiceConfig carries Service's dependencies.
type ServiceConfig struct {
	DataDir  string
	Hasher   *Hasher
	Sessions *Sessions
	Logger   *slog.Logger
}

// Service owns the single admin account: the first-run setup token, the
// password hash on disk, and login/logout.
type Service struct {
	adminPath string
	hasher    *Hasher
	sessions  *Sessions

	setupMu sync.Mutex // serialises Setup so two callers cannot both win

	mu         sync.RWMutex
	hash       string // empty until setup is complete
	setupToken string // empty once setup is complete; memory only
}

// NewService loads /data/admin.json. If it is missing the service starts in
// setup mode with a new random setup token. A file that exists but cannot be
// parsed is a fatal error (it must never silently re-open setup).
func NewService(c ServiceConfig) (*Service, error) {
	s := &Service{
		adminPath: filepath.Join(c.DataDir, adminFileName),
		hasher:    c.Hasher,
		sessions:  c.Sessions,
	}
	if err := store.EnforceMode(s.adminPath, adminFileMode, c.Logger); err != nil {
		return nil, err
	}

	data, err := os.ReadFile(s.adminPath)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		tok, err := NewSetupToken()
		if err != nil {
			return nil, err
		}
		s.setupToken = tok
	case err != nil:
		return nil, fmt.Errorf("auth: read %s: %w", s.adminPath, err)
	default:
		hash, err := parseAdminFile(data)
		if err != nil {
			return nil, fmt.Errorf("auth: %s is not a valid admin file: %w", s.adminPath, err)
		}
		s.hash = hash
	}
	return s, nil
}

func parseAdminFile(data []byte) (string, error) {
	var f adminFile
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&f); err != nil {
		return "", err
	}
	if f.Version != adminFileVersion {
		return "", fmt.Errorf("unsupported version %d", f.Version)
	}
	if _, _, _, err := decodeHash(f.PasswordHash); err != nil {
		return "", err
	}
	return f.PasswordHash, nil
}

// SetupRequired reports whether no admin password has been set yet.
func (s *Service) SetupRequired() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.hash == ""
}

// PendingSetupToken returns the token to announce in the logs, if setup is
// still pending.
func (s *Service) PendingSetupToken() (string, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.setupToken, s.setupToken != ""
}

// SessionTTL is the session lifetime, for cookie expiry.
func (s *Service) SessionTTL() time.Duration { return s.sessions.TTL() }

// ValidatePassword enforces the admin password policy: at least 12
// characters (not bytes), at most 1024 bytes.
func ValidatePassword(p string) error {
	if utf8.RuneCountInString(p) < minPasswordRunes {
		return fmt.Errorf("%w: use at least %d characters", ErrWeakPassword, minPasswordRunes)
	}
	if len(p) > maxPasswordBytes {
		return fmt.Errorf("%w: use at most %d bytes", ErrWeakPassword, maxPasswordBytes)
	}
	return nil
}

// Setup completes first-run setup: it checks the setup token, applies the
// password policy, writes admin.json atomically with mode 0600, and
// invalidates the token. It does not log the user in.
func (s *Service) Setup(ctx context.Context, token, password string) error {
	s.setupMu.Lock()
	defer s.setupMu.Unlock()

	s.mu.RLock()
	complete, want := s.hash != "", s.setupToken
	s.mu.RUnlock()
	if complete {
		return ErrSetupComplete
	}
	if token == "" || subtle.ConstantTimeCompare([]byte(token), []byte(want)) != 1 {
		return ErrInvalidSetupToken
	}
	if err := ValidatePassword(password); err != nil {
		return err
	}

	hash, err := s.hasher.Hash(ctx, password)
	if err != nil {
		return fmt.Errorf("auth: hash admin password: %w", err)
	}
	data, err := json.MarshalIndent(adminFile{Version: adminFileVersion, PasswordHash: hash}, "", "  ")
	if err != nil {
		return fmt.Errorf("auth: encode admin file: %w", err)
	}
	if err := store.WriteFileAtomic(s.adminPath, data, adminFileMode); err != nil {
		return err
	}

	s.mu.Lock()
	s.hash, s.setupToken = hash, ""
	s.mu.Unlock()
	return nil
}

// Login checks the admin password and starts a session.
func (s *Service) Login(ctx context.Context, password string) (Session, error) {
	s.mu.RLock()
	hash := s.hash
	s.mu.RUnlock()
	if hash == "" {
		return Session{}, ErrSetupRequired
	}
	ok, err := s.hasher.Verify(ctx, hash, password)
	if err != nil {
		return Session{}, fmt.Errorf("auth: verify password: %w", err)
	}
	if !ok {
		return Session{}, ErrInvalidCredentials
	}
	return s.sessions.Create()
}

// Session returns the live session for id.
func (s *Service) Session(id string) (Session, bool) { return s.sessions.Get(id) }

// Logout ends a session.
func (s *Service) Logout(id string) { s.sessions.Delete(id) }
```


- [ ] **Step 4: Run the tests, vet and lint**

```bash
cd app
go test ./internal/auth/ -race -cover -count=1
gofmt -l .
go vet ./...
golangci-lint run ./...
```

Expected: `ok … coverage: 9x%`; no other output. `TestConcurrentSetupHasExactlyOneWinner` must pass under `-race`.

- [ ] **Step 5: Leave the work uncommitted.**

---

### Task 6: API foundation: error shape, SPA handler and the embedded-UI hook

**Files:**
- Create: `app/internal/api/errors.go`, `app/internal/api/spa.go`
- Create: `app/internal/webui/embed_dist.go`, `app/internal/webui/embed_stub.go`
- Test: `app/internal/api/helpers_test.go`, `app/internal/api/spa_test.go`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces (package `api`, unexported unless noted):
  - `writeJSON(w http.ResponseWriter, status int, v any)`, `writeError(w, status int, code, message, fix string)`: the spec §8.1 error envelope
  - `spaHandler(fsys fs.FS) http.Handler`: files as themselves; extension-less paths and `/index.html` get `index.html` (`Cache-Control: no-cache`); anything under `assets/` gets `immutable` caching; a missing file with an extension, or anything under `assets/`, is `404`; only GET and HEAD; a nil FS or one without `index.html` answers `503` with code `ui_not_built`
  - test helper `wantError(t, resp, body, status, code)` (used again in Task 7)
- Produces (package `webui`): `webui.Dist() fs.FS`: the built UI when compiled with `-tags webdist`, otherwise `nil`.

- [ ] **Step 1: Write the failing tests**

`app/internal/api/helpers_test.go`

```go
package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// wantError asserts the response is the standard error envelope with code.
func wantError(t *testing.T, resp *http.Response, body []byte, status int, code string) {
	t.Helper()
	if resp.StatusCode != status {
		t.Fatalf("status = %d, want %d; body %s", resp.StatusCode, status, body)
	}
	var env struct {
		Error struct{ Code, Message, Fix string } `json:"error"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		t.Fatalf("body is not the error envelope: %v\n%s", err, body)
	}
	if env.Error.Code != code {
		t.Errorf("error code = %q, want %q (body %s)", env.Error.Code, code, body)
	}
	if strings.TrimSpace(env.Error.Message) == "" {
		t.Errorf("error message is empty: %s", body)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}
}
```


`app/internal/api/spa_test.go`

```go
package api

import (
	"io/fs"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

func testUI() fstest.MapFS {
	return fstest.MapFS{
		"index.html":           {Data: []byte("<html><body>simplarr-shell</body></html>")},
		"assets/app-abc123.js": {Data: []byte("console.log('hi')")},
		"favicon.svg":          {Data: []byte("<svg/>")},
	}
}

func serve(h http.Handler, method, path string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(method, path, nil))
	return rec
}

func TestSPAServesIndexForClientRoutes(t *testing.T) {
	h := spaHandler(testUI())
	for _, path := range []string{"/", "/index.html", "/login", "/setup", "/services/radarr", "/deep/client/route"} {
		rec := serve(h, "GET", path)
		if rec.Code != 200 || !strings.Contains(rec.Body.String(), "simplarr-shell") {
			t.Errorf("%s: %d %q", path, rec.Code, rec.Body.String())
		}
		if got := rec.Header().Get("Cache-Control"); got != "no-cache" {
			t.Errorf("%s: Cache-Control = %q, want no-cache", path, got)
		}
		if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
			t.Errorf("%s: Content-Type = %q", path, ct)
		}
	}
}

func TestSPAServesAssetsWithLongCache(t *testing.T) {
	h := spaHandler(testUI())

	rec := serve(h, "GET", "/assets/app-abc123.js")
	if rec.Code != 200 || rec.Body.String() != "console.log('hi')" {
		t.Fatalf("asset: %d %q", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "javascript") {
		t.Errorf("Content-Type = %q", ct)
	}
	if cc := rec.Header().Get("Cache-Control"); !strings.Contains(cc, "immutable") || !strings.Contains(cc, "max-age=31536000") {
		t.Errorf("Cache-Control = %q", cc)
	}

	rec = serve(h, "GET", "/favicon.svg")
	if rec.Code != 200 || rec.Header().Get("Cache-Control") != "" {
		t.Errorf("non-assets file: %d, Cache-Control %q", rec.Code, rec.Header().Get("Cache-Control"))
	}
}

func TestSPAMissingFileIs404NotHTML(t *testing.T) {
	h := spaHandler(testUI())
	for _, path := range []string{"/assets/missing.js", "/nothing.png", "/assets/", "/assets", "/assets/sub/dir"} {
		rec := serve(h, "GET", path)
		if rec.Code != 404 {
			t.Errorf("%s: status %d, want 404", path, rec.Code)
		}
		if strings.Contains(rec.Body.String(), "simplarr-shell") {
			t.Errorf("%s returned the HTML shell", path)
		}
	}
}

func TestSPAPathTraversalStaysInsideTheFS(t *testing.T) {
	h := spaHandler(testUI())
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/", nil)
	req.URL.Path = "/../../etc/passwd" // bypasses the mux's own cleaning
	h.ServeHTTP(rec, req)
	if strings.Contains(rec.Body.String(), "root:") {
		t.Fatal("served a file outside the UI")
	}
}

func TestSPAOnlyAllowsGetAndHead(t *testing.T) {
	h := spaHandler(testUI())
	if rec := serve(h, "HEAD", "/login"); rec.Code != 200 || rec.Body.Len() != 0 {
		t.Errorf("HEAD: %d, body %d bytes", rec.Code, rec.Body.Len())
	}
	rec := serve(h, "POST", "/")
	wantError(t, rec.Result(), rec.Body.Bytes(), 405, "method_not_allowed")
	if rec.Header().Get("Allow") != "GET, HEAD" {
		t.Errorf("Allow = %q", rec.Header().Get("Allow"))
	}
}

func TestSPAWithoutBuiltUIExplainsHowToBuildIt(t *testing.T) {
	cases := map[string]fs.FS{
		"nil":      nil,
		"no index": fstest.MapFS{"assets/x.js": {Data: []byte("x")}},
	}
	for name, fsys := range cases {
		t.Run(name, func(t *testing.T) {
			rec := serve(spaHandler(fsys), "GET", "/")
			wantError(t, rec.Result(), rec.Body.Bytes(), 503, "ui_not_built")
			if !strings.Contains(rec.Body.String(), "webdist") {
				t.Errorf("fix text should mention the webdist build tag: %s", rec.Body.String())
			}
		})
	}
}
```


- [ ] **Step 2: Run them and watch them fail**

```bash
cd app && go test ./internal/api/
```

Expected: build failure: `undefined: spaHandler`.

- [ ] **Step 3: Write the implementations**

`app/internal/api/errors.go`

```go
// Package api holds simplarr's HTTP handlers, JSON shapes and error mapping
// (spec §8).
package api

import (
	"encoding/json"
	"net/http"
)

// apiError is the one error shape every endpoint uses (spec §8.1):
// {"error":{"code":"…","message":"…","fix":"…"}}.
type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Fix     string `json:"fix,omitempty"`
}

type errorEnvelope struct {
	Error apiError `json:"error"`
}

// writeJSON sends v as JSON. A failed write means the client went away, so
// there is nobody to report it to.
func writeJSON(w http.ResponseWriter, status int, v any) {
	body, err := json.Marshal(v)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":{"code":"internal","message":"Could not encode the response."}}`))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func writeError(w http.ResponseWriter, status int, code, message, fix string) {
	writeJSON(w, status, errorEnvelope{Error: apiError{Code: code, Message: message, Fix: fix}})
}
```


`app/internal/api/spa.go`

```go
package api

import (
	"bytes"
	"io/fs"
	"net/http"
	"path"
	"strings"
	"time"
)

const uiNotBuiltFix = "Build the UI first: cd app/web && npm ci && npm run build, then " +
	"go build -tags webdist ./cmd/simplarr. The official container image already includes the UI."

// spaHandler serves the built React app from fsys: real files as themselves,
// and every other extension-less path as index.html so client-side routes
// (/login, /services/radarr) survive a reload. A missing file with an
// extension, or anything under assets/, is a 404 and never the HTML shell, so
// a broken asset URL fails loudly.
//
// fsys is nil, or has no index.html, when the binary was built without the
// webdist tag; every request then gets a 503 that says how to fix it.
func spaHandler(fsys fs.FS) http.Handler {
	var index []byte
	if fsys != nil {
		if b, err := fs.ReadFile(fsys, "index.html"); err == nil {
			index = b
		}
	}
	if index == nil {
		return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			writeError(w, http.StatusServiceUnavailable, "ui_not_built",
				"The web UI is not built into this binary.", uiNotBuiltFix)
		})
	}

	serveIndex := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		http.ServeContent(w, r, "index.html", time.Time{}, bytes.NewReader(index))
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "Only GET and HEAD are allowed here.", "")
			return
		}
		// Clean against a rooted path so ".." can never leave the FS.
		name := strings.TrimPrefix(path.Clean("/"+r.URL.Path), "/")
		if name == "" || name == "index.html" {
			serveIndex(w, r)
			return
		}
		if info, err := fs.Stat(fsys, name); err == nil && !info.IsDir() {
			if strings.HasPrefix(name, "assets/") {
				// Vite content-hashes everything under assets/.
				w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
			}
			http.ServeFileFS(w, r, fsys, name)
			return
		}
		if path.Ext(name) != "" || name == "assets" || strings.HasPrefix(name, "assets/") {
			writeError(w, http.StatusNotFound, "not_found", "No such file.", "")
			return
		}
		serveIndex(w, r)
	})
}
```


`app/internal/webui/embed_stub.go`

```go
//go:build !webdist

// Package webui exposes the built single-page app to the Go binary.
package webui

import "io/fs"

// Dist returns nil: this binary was built without the webdist tag, so it has
// no UI. The API still works, and the HTTP handler answers every UI request
// with a 503 that explains how to build the UI.
func Dist() fs.FS { return nil }
```


`app/internal/webui/embed_dist.go`

```go
//go:build webdist

// Package webui exposes the built single-page app to the Go binary.
package webui

import (
	"embed"
	"io/fs"
)

// The dist directory is produced by `npm run build` and is not committed.
// The webdist build tag opts in, so `go build` and `go test` work on a fresh
// checkout without Node.
//
//go:embed all:dist
var dist embed.FS

// Dist returns the built UI rooted at index.html.
func Dist() fs.FS {
	sub, err := fs.Sub(dist, "dist")
	if err != nil {
		// Unreachable: "dist" is a literal that embed already validated.
		panic("webui: " + err.Error())
	}
	return sub
}
```


- [ ] **Step 4: Run the tests, vet and lint, and check both build modes**

```bash
cd app
go test ./internal/api/ -race -cover
gofmt -l .
go vet ./...
golangci-lint run ./...
go build ./internal/webui/ && echo "plain build ok"
go build -tags webdist ./internal/webui/ 2>&1 | head -2
```

Expected: tests pass; no gofmt/vet/lint output; `plain build ok`; the tagged build fails with `pattern all:dist: no matching files found` (the UI is built in Task 10, and that failure is the intended guard).

- [ ] **Step 5: Leave the work uncommitted.**

---

### Task 7: Auth API: JSON bodies, cookies, CSRF, handlers and routing

**Files:**
- Create: `app/internal/api/jsonbody.go`, `clientip.go`, `cookies.go`, `middleware.go`, `auth_handlers.go`, `server.go` (all under `app/internal/api/`)
- Test: `app/internal/api/env_test.go`, `app/internal/api/auth_handlers_test.go`, `app/internal/api/middleware_test.go`

**Interfaces:**
- Consumes: Task 5 `auth.Service`, `auth.Limiter` (`Allow`, `Reset`), `auth.TokensMatch`, `auth.Session`, error sentinels; Task 6 `writeJSON`, `writeError`, `spaHandler`, test helper `wantError`.
- Produces:
  - `api.Deps{Auth *auth.Service; Limiter *auth.Limiter; Logger *slog.Logger; Static fs.FS}` and `api.NewHandler(d Deps) http.Handler`
  - routes: `GET /healthz`, `GET /api/v1/auth/state`, `POST /api/v1/auth/setup`, `POST /api/v1/auth/login`, `POST /api/v1/auth/logout` (session + CSRF), `/api/` (JSON 404), `/` (SPA)
  - `(*server).protected(next http.Handler) http.Handler`: the gate every later session-only route uses (session required; CSRF required for every method except GET, HEAD, OPTIONS)
  - cookie names `simplarr_session` (HttpOnly) and `simplarr_csrf` (readable by the SPA); header `X-CSRF-Token`
  - response bodies: auth endpoints return `{"setupRequired": bool, "authenticated": bool}`; errors use the envelope with codes `invalid_request`, `unsupported_media_type`, `request_too_large`, `unauthorized`, `csrf_failed`, `setup_required`, `setup_complete`, `invalid_setup_token`, `weak_password`, `invalid_credentials`, `rate_limited` (429 with `Retry-After`), `not_found`, `internal`

- [ ] **Step 1: Write the failing tests**

`app/internal/api/env_test.go`

```go
package api

import (
	"bytes"
	"encoding/json"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"sync"
	"testing"
	"time"

	"github.com/parsoFish/simplarr/app/internal/auth"
	"github.com/parsoFish/simplarr/app/internal/logging"
)

const (
	testPassword = "a perfectly good password"
	maxFailures  = 5
)

// syncBuffer is a bytes.Buffer that the server goroutines and the test can
// touch concurrently.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// env is a running server plus a cookie-keeping client.
type env struct {
	t      *testing.T
	srv    *httptest.Server
	client *http.Client
	svc    *auth.Service
	token  string
	logs   *syncBuffer
}

func newEnv(t *testing.T, static fs.FS) *env {
	t.Helper()
	logs := &syncBuffer{}
	logger := logging.New(logs, slog.LevelDebug)

	hasher := auth.NewHasher(auth.Params{Memory: 64, Time: 1, Threads: 1, SaltLen: 16, KeyLen: 32}, 2)
	svc, err := auth.NewService(auth.ServiceConfig{
		DataDir:  t.TempDir(),
		Hasher:   hasher,
		Sessions: auth.NewSessions(7*24*time.Hour, time.Now),
		Logger:   logger,
	})
	if err != nil {
		t.Fatalf("NewService: %v", err)
	}
	token, _ := svc.PendingSetupToken()

	srv := httptest.NewServer(NewHandler(Deps{
		Auth:    svc,
		Limiter: auth.NewLimiter(maxFailures, 15*time.Minute, time.Now),
		Static:  static,
		Logger:  logger,
	}))
	t.Cleanup(srv.Close)

	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	return &env{
		t: t, srv: srv, svc: svc, token: token, logs: logs,
		client: &http.Client{
			Jar:           jar,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}
}

// do sends a request. body, when non-nil, is sent as JSON. headers are
// key, value pairs.
func (e *env) do(method, path string, body any, headers ...string) (*http.Response, []byte) {
	e.t.Helper()
	var rdr io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			e.t.Fatal(err)
		}
		rdr = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, e.srv.URL+path, rdr)
	if err != nil {
		e.t.Fatal(err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Set(headers[i], headers[i+1])
	}
	resp, err := e.client.Do(req)
	if err != nil {
		e.t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	out, err := io.ReadAll(resp.Body)
	if err != nil {
		e.t.Fatal(err)
	}
	return resp, out
}

func (e *env) cookie(name string) *http.Cookie {
	e.t.Helper()
	u, err := url.Parse(e.srv.URL)
	if err != nil {
		e.t.Fatal(err)
	}
	for _, c := range e.client.Jar.Cookies(u) {
		if c.Name == name {
			return c
		}
	}
	return nil
}

func (e *env) completeSetup() {
	e.t.Helper()
	resp, body := e.do("POST", "/api/v1/auth/setup", map[string]string{"token": e.token, "password": testPassword})
	if resp.StatusCode != http.StatusOK {
		e.t.Fatalf("setup: %d %s", resp.StatusCode, body)
	}
}

// login completes setup if needed, logs in, and returns the CSRF token.
func (e *env) login() string {
	e.t.Helper()
	if e.svc.SetupRequired() {
		e.completeSetup()
	}
	resp, body := e.do("POST", "/api/v1/auth/login", map[string]string{"password": testPassword})
	if resp.StatusCode != http.StatusOK {
		e.t.Fatalf("login: %d %s", resp.StatusCode, body)
	}
	c := e.cookie(csrfCookieName)
	if c == nil {
		e.t.Fatal("no csrf cookie after login")
	}
	return c.Value
}
```


`app/internal/api/auth_handlers_test.go`

```go
package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
)

const (
	setupPath  = "/api/v1/auth/setup"
	loginPath  = "/api/v1/auth/login"
	logoutPath = "/api/v1/auth/logout"
	statePath  = "/api/v1/auth/state"
)

type stateBody struct {
	SetupRequired bool `json:"setupRequired"`
	Authenticated bool `json:"authenticated"`
}

func getState(t *testing.T, e *env) stateBody {
	t.Helper()
	resp, body := e.do("GET", statePath, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("state: %d %s", resp.StatusCode, body)
	}
	var s stateBody
	if err := json.Unmarshal(body, &s); err != nil {
		t.Fatalf("state body: %v\n%s", err, body)
	}
	return s
}

func TestHealthz(t *testing.T) {
	e := newEnv(t, nil)
	resp, body := e.do("GET", "/healthz", nil)
	if resp.StatusCode != 200 || strings.TrimSpace(string(body)) != `{"ok":true}` {
		t.Errorf("healthz = %d %s", resp.StatusCode, body)
	}
}

func TestStateAcrossTheLifecycle(t *testing.T) {
	e := newEnv(t, nil)
	if s := getState(t, e); !s.SetupRequired || s.Authenticated {
		t.Errorf("fresh state = %+v", s)
	}
	e.completeSetup()
	if s := getState(t, e); s.SetupRequired || s.Authenticated {
		t.Errorf("after setup (not logged in) = %+v", s)
	}
	csrf := e.login()
	if s := getState(t, e); s.SetupRequired || !s.Authenticated {
		t.Errorf("after login = %+v", s)
	}
	e.do("POST", logoutPath, nil, "X-CSRF-Token", csrf)
	if s := getState(t, e); s.Authenticated {
		t.Errorf("after logout = %+v", s)
	}
}

func TestSetupErrors(t *testing.T) {
	e := newEnv(t, nil)

	resp, body := e.do("POST", setupPath, map[string]string{"token": "wrong-token", "password": testPassword})
	wantError(t, resp, body, 403, "invalid_setup_token")

	resp, body = e.do("POST", setupPath, map[string]string{"token": e.token, "password": "short"})
	wantError(t, resp, body, 400, "weak_password")

	if !getState(t, e).SetupRequired {
		t.Fatal("failed attempts completed setup")
	}

	e.completeSetup()
	resp, body = e.do("POST", setupPath, map[string]string{"token": e.token, "password": testPassword})
	wantError(t, resp, body, 409, "setup_complete")
}

func TestJSONBodyValidation(t *testing.T) {
	e := newEnv(t, nil)
	good := map[string]string{"token": e.token, "password": testPassword}

	resp, body := e.do("POST", setupPath, good, "Content-Type", "text/plain")
	wantError(t, resp, body, 415, "unsupported_media_type")

	resp, body = e.do("POST", setupPath, map[string]any{"token": e.token, "password": testPassword, "extra": 1})
	wantError(t, resp, body, 400, "invalid_request")

	resp, body = e.do("POST", setupPath, map[string]string{"password": strings.Repeat("x", 70<<10)})
	wantError(t, resp, body, 413, "request_too_large")

	raw, err := http.Post(e.srv.URL+setupPath, "application/json", bytes.NewReader([]byte(`{"token":"a","password":"b"} {}`)))
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Body.Close()
	if raw.StatusCode != 400 {
		t.Errorf("trailing data: status = %d, want 400", raw.StatusCode)
	}

	if !getState(t, e).SetupRequired {
		t.Error("rejected requests completed setup")
	}
}

func TestLoginBeforeSetupAndWithWrongPassword(t *testing.T) {
	e := newEnv(t, nil)
	resp, body := e.do("POST", loginPath, map[string]string{"password": testPassword})
	wantError(t, resp, body, 409, "setup_required")

	e.completeSetup()
	resp, body = e.do("POST", loginPath, map[string]string{"password": "not the password"})
	wantError(t, resp, body, 401, "invalid_credentials")
}

func TestLoginSetsHardenedCookies(t *testing.T) {
	e := newEnv(t, nil)
	e.completeSetup()
	resp, body := e.do("POST", loginPath, map[string]string{"password": testPassword})
	if resp.StatusCode != 200 {
		t.Fatalf("login: %d %s", resp.StatusCode, body)
	}

	cookies := map[string]*http.Cookie{}
	for _, c := range resp.Cookies() {
		cookies[c.Name] = c
	}
	sess, csrf := cookies[sessionCookieName], cookies[csrfCookieName]
	if sess == nil || csrf == nil {
		t.Fatalf("cookies = %v, want session and csrf", resp.Cookies())
	}
	for _, c := range []*http.Cookie{sess, csrf} {
		if c.Path != "/" || c.SameSite != http.SameSiteStrictMode || c.MaxAge != 7*24*3600 {
			t.Errorf("%s: path=%q samesite=%v maxage=%d", c.Name, c.Path, c.SameSite, c.MaxAge)
		}
		if c.Secure {
			t.Errorf("%s is Secure on a plain-HTTP request", c.Name)
		}
	}
	if !sess.HttpOnly {
		t.Error("session cookie must be HttpOnly")
	}
	if csrf.HttpOnly {
		t.Error("csrf cookie must be readable by the SPA (not HttpOnly)")
	}
	if len(sess.Value) < 43 || sess.Value == csrf.Value {
		t.Errorf("session id %q / csrf %q look wrong", sess.Value, csrf.Value)
	}
}

func TestCookiesAreSecureBehindHTTPSProxy(t *testing.T) {
	e := newEnv(t, nil)
	e.completeSetup()
	resp, _ := e.do("POST", loginPath, map[string]string{"password": testPassword}, "X-Forwarded-Proto", "https")
	if len(resp.Cookies()) != 2 {
		t.Fatalf("cookies = %v", resp.Cookies())
	}
	for _, c := range resp.Cookies() {
		if !c.Secure {
			t.Errorf("%s is not Secure behind X-Forwarded-Proto: https", c.Name)
		}
	}
}

func TestLogoutRequiresSessionAndCSRF(t *testing.T) {
	e := newEnv(t, nil)

	resp, body := e.do("POST", logoutPath, nil)
	wantError(t, resp, body, 401, "unauthorized")

	csrf := e.login()
	resp, body = e.do("POST", logoutPath, nil)
	wantError(t, resp, body, 403, "csrf_failed")
	resp, body = e.do("POST", logoutPath, nil, "X-CSRF-Token", "not-the-token")
	wantError(t, resp, body, 403, "csrf_failed")
	if !getState(t, e).Authenticated {
		t.Fatal("a rejected logout ended the session")
	}

	resp, body = e.do("POST", logoutPath, nil, "X-CSRF-Token", csrf)
	if resp.StatusCode != 200 {
		t.Fatalf("logout: %d %s", resp.StatusCode, body)
	}
	for _, c := range resp.Cookies() {
		if c.MaxAge >= 0 || c.Value != "" {
			t.Errorf("cookie %s not cleared: %+v", c.Name, c)
		}
	}
}

func TestCSRFTokenIsBoundToTheSession(t *testing.T) {
	e := newEnv(t, nil)
	e.login()
	session := e.cookie(sessionCookieName).Value

	// An attacker who plants their own csrf cookie and sends the same value in
	// the header still fails: it does not equal the token stored in the session.
	req, err := http.NewRequest("POST", e.srv.URL+logoutPath, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Cookie", sessionCookieName+"="+session+"; "+csrfCookieName+"=attacker-token")
	req.Header.Set("X-CSRF-Token", "attacker-token")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Errorf("status = %d, want 403", resp.StatusCode)
	}
}

func TestLogoutInvalidatesTheSessionServerSide(t *testing.T) {
	e := newEnv(t, nil)
	csrf := e.login()
	session := e.cookie(sessionCookieName).Value
	e.do("POST", logoutPath, nil, "X-CSRF-Token", csrf)

	req, err := http.NewRequest("POST", e.srv.URL+logoutPath, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Cookie", sessionCookieName+"="+session+"; "+csrfCookieName+"="+csrf)
	req.Header.Set("X-CSRF-Token", csrf)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Errorf("replayed session: status = %d, want 401", resp.StatusCode)
	}
}

func TestSetupIsRateLimitedPerIP(t *testing.T) {
	e := newEnv(t, nil)
	for i := 0; i < maxFailures; i++ {
		resp, body := e.do("POST", setupPath, map[string]string{"token": "wrong", "password": testPassword})
		wantError(t, resp, body, 403, "invalid_setup_token")
	}
	// Blocked: even the correct token is refused.
	resp, body := e.do("POST", setupPath, map[string]string{"token": e.token, "password": testPassword})
	wantError(t, resp, body, 429, "rate_limited")
	if secs, err := strconv.Atoi(resp.Header.Get("Retry-After")); err != nil || secs <= 0 {
		t.Errorf("Retry-After = %q, want positive seconds", resp.Header.Get("Retry-After"))
	}
	// Another client address is unaffected.
	resp, body = e.do("POST", setupPath, map[string]string{"token": e.token, "password": testPassword}, "X-Real-IP", "203.0.113.9")
	if resp.StatusCode != 200 {
		t.Errorf("other IP: %d %s", resp.StatusCode, body)
	}
}

func TestLoginIsRateLimitedPerIP(t *testing.T) {
	e := newEnv(t, nil)
	e.completeSetup()
	for i := 0; i < maxFailures; i++ {
		resp, body := e.do("POST", loginPath, map[string]string{"password": "wrong password!"})
		wantError(t, resp, body, 401, "invalid_credentials")
	}
	resp, body := e.do("POST", loginPath, map[string]string{"password": testPassword})
	wantError(t, resp, body, 429, "rate_limited")

	resp, body = e.do("POST", loginPath, map[string]string{"password": testPassword}, "X-Real-IP", "203.0.113.9")
	if resp.StatusCode != 200 {
		t.Errorf("other IP: %d %s", resp.StatusCode, body)
	}
}

func TestSuccessfulLoginResetsTheFailureCount(t *testing.T) {
	e := newEnv(t, nil)
	e.completeSetup()
	wrong := map[string]string{"password": "wrong password!"}
	for i := 0; i < maxFailures-1; i++ {
		e.do("POST", loginPath, wrong)
	}
	if resp, body := e.do("POST", loginPath, map[string]string{"password": testPassword}); resp.StatusCode != 200 {
		t.Fatalf("login: %d %s", resp.StatusCode, body)
	}
	for i := 0; i < maxFailures; i++ {
		resp, body := e.do("POST", loginPath, wrong)
		wantError(t, resp, body, 401, "invalid_credentials")
	}
	resp, body := e.do("POST", loginPath, wrong)
	wantError(t, resp, body, 429, "rate_limited")
}

func TestLogsNeverContainSecrets(t *testing.T) {
	e := newEnv(t, nil)
	e.do("POST", setupPath, map[string]string{"token": "guessed-token-value", "password": "hunter2hunter2"})
	e.completeSetup()
	e.do("POST", loginPath, map[string]string{"password": "hunter3hunter3"})
	e.login()

	logs := e.logs.String()
	for _, secret := range []string{"hunter2", "hunter3", "guessed-token-value", e.token, testPassword} {
		if strings.Contains(logs, secret) {
			t.Errorf("logs contain %q:\n%s", secret, logs)
		}
	}
	for _, event := range []string{"setup token rejected", "admin password set", "login failed", "login succeeded"} {
		if !strings.Contains(logs, event) {
			t.Errorf("logs missing event %q:\n%s", event, logs)
		}
	}
}

// A burst of parallel guesses must not get more than maxFailures attempts: the
// limiter charges each attempt before the password is checked, so requests that
// are already in flight cannot all slip past a "not blocked yet" check.
func TestParallelLoginBurstCannotExceedTheLimit(t *testing.T) {
	e := newEnv(t, nil)
	e.completeSetup()

	const burst = 40
	codes := make(chan int, burst)
	var wg sync.WaitGroup
	for i := 0; i < burst; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp, _ := e.do("POST", loginPath, map[string]string{"password": "wrong password!"})
			codes <- resp.StatusCode
		}()
	}
	wg.Wait()
	close(codes)

	got := map[int]int{}
	for c := range codes {
		got[c]++
	}
	if got[401] != maxFailures || got[429] != burst-maxFailures {
		t.Errorf("status counts = %v, want %d x 401 and %d x 429", got, maxFailures, burst-maxFailures)
	}
}
```


`app/internal/api/middleware_test.go`

```go
package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

func TestSecurityHeadersOnEveryResponse(t *testing.T) {
	e := newEnv(t, fstest.MapFS{"index.html": {Data: []byte("<html></html>")}})
	for _, path := range []string{"/healthz", statePath, "/api/v1/nope", "/", "/login"} {
		resp, _ := e.do("GET", path, nil)
		want := map[string]string{
			"X-Content-Type-Options": "nosniff",
			"X-Frame-Options":        "DENY",
			"Referrer-Policy":        "no-referrer",
		}
		for h, v := range want {
			if got := resp.Header.Get(h); got != v {
				t.Errorf("%s: %s = %q, want %q", path, h, got, v)
			}
		}
		csp := resp.Header.Get("Content-Security-Policy")
		if !strings.Contains(csp, "default-src 'self'") || !strings.Contains(csp, "frame-ancestors 'none'") {
			t.Errorf("%s: CSP = %q", path, csp)
		}
	}
	for _, path := range []string{"/healthz", statePath, "/api/v1/nope"} {
		resp, _ := e.do("GET", path, nil)
		if got := resp.Header.Get("Cache-Control"); got != "no-store" {
			t.Errorf("%s: Cache-Control = %q, want no-store", path, got)
		}
	}
}

func TestUnknownAPIPathIsJSON404(t *testing.T) {
	e := newEnv(t, fstest.MapFS{"index.html": {Data: []byte("<html></html>")}})
	resp, body := e.do("GET", "/api/v1/nope", nil)
	wantError(t, resp, body, 404, "not_found")
}

// protected is the gate every later session-only route will use. Logout is the
// only POST route in this plan, so the GET behaviour is tested directly.
func TestProtectedChecksCSRFOnlyForUnsafeMethods(t *testing.T) {
	e := newEnv(t, nil)
	e.completeSetup()
	sess, err := e.svc.Login(t.Context(), testPassword)
	if err != nil {
		t.Fatal(err)
	}
	s := &server{auth: e.svc}
	handler := s.protected(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got, ok := sessionFrom(r.Context())
		if !ok || got.ID != sess.ID {
			t.Errorf("session not in context: %+v, %v", got, ok)
		}
		w.WriteHeader(http.StatusNoContent)
	}))

	call := func(method string, withSession bool, csrfHeader string) int {
		req := httptest.NewRequest(method, "/x", nil)
		if withSession {
			req.AddCookie(&http.Cookie{Name: sessionCookieName, Value: sess.ID})
			req.AddCookie(&http.Cookie{Name: csrfCookieName, Value: sess.CSRF})
		}
		if csrfHeader != "" {
			req.Header.Set(csrfHeaderName, csrfHeader)
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec.Code
	}

	tests := []struct {
		name        string
		method      string
		withSession bool
		header      string
		want        int
	}{
		{"GET with session, no csrf", "GET", true, "", 204},
		{"HEAD with session, no csrf", "HEAD", true, "", 204},
		{"GET without session", "GET", false, "", 401},
		{"POST with session and csrf", "POST", true, sess.CSRF, 204},
		{"POST without csrf header", "POST", true, "", 403},
		{"POST with wrong csrf", "POST", true, "nope", 403},
		{"PUT without csrf header", "PUT", true, "", 403},
		{"DELETE without csrf header", "DELETE", true, "", 403},
		{"POST without session", "POST", false, sess.CSRF, 401},
	}
	for _, tc := range tests {
		if got := call(tc.method, tc.withSession, tc.header); got != tc.want {
			t.Errorf("%s: status = %d, want %d", tc.name, got, tc.want)
		}
	}
}

func TestClientIP(t *testing.T) {
	tests := []struct {
		name       string
		realIP     string
		remoteAddr string
		want       string
	}{
		{"header wins", "203.0.113.7", "172.18.0.2:5555", "203.0.113.7"},
		{"header trimmed", " 203.0.113.7 ", "172.18.0.2:5555", "203.0.113.7"},
		{"ipv6 header", "2001:db8::1", "172.18.0.2:5555", "2001:db8::1"},
		{"invalid header falls back", "not-an-ip", "172.18.0.2:5555", "172.18.0.2"},
		{"no header", "", "172.18.0.2:5555", "172.18.0.2"},
		{"ipv6 remote", "", "[2001:db8::2]:5555", "2001:db8::2"},
		{"remote without port", "", "172.18.0.2", "172.18.0.2"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest("GET", "/", nil)
			req.RemoteAddr = tc.remoteAddr
			if tc.realIP != "" {
				req.Header.Set("X-Real-IP", tc.realIP)
			}
			if got := clientIP(req); got != tc.want {
				t.Errorf("clientIP = %q, want %q", got, tc.want)
			}
		})
	}
}
```


- [ ] **Step 2: Run them and watch them fail**

```bash
cd app && go test ./internal/api/
```

Expected: build failure: `undefined: NewHandler`, `undefined: Deps`, `undefined: clientIP`, `undefined: sessionCookieName`, `undefined: server`.

- [ ] **Step 3: Write the implementations**

`app/internal/api/jsonbody.go`

```go
package api

import (
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
)

// maxBodyBytes caps request bodies. Every body in this API is a small JSON
// document.
const maxBodyBytes = 64 << 10

// decodeJSON reads one JSON object from the request into dst. It requires
// Content-Type: application/json (a cross-site HTML form cannot send that),
// caps the body size, and rejects unknown fields and trailing data. On
// failure it has already written the error response and returns false.
func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		writeError(w, http.StatusUnsupportedMediaType, "unsupported_media_type",
			"The request body must be JSON.", "Send the header Content-Type: application/json.")
		return false
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeError(w, http.StatusRequestEntityTooLarge, "request_too_large",
				"The request body is too large.", "")
			return false
		}
		writeError(w, http.StatusBadRequest, "invalid_request",
			"The request body is not valid for this endpoint.", "Check the field names and types.")
		return false
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "invalid_request",
			"The request body must contain exactly one JSON object.", "")
		return false
	}
	return true
}
```


`app/internal/api/clientip.go`

```go
package api

import (
	"net"
	"net/http"
	"net/netip"
	"strings"
)

// clientIP returns the address used to rate-limit a request.
//
// simplarr publishes no port: the only thing that can reach it is nginx, which
// sets X-Real-IP from the TCP peer (spec §8.2). A direct connection (tests,
// `docker exec`) has no header and falls back to the peer address. The header
// is only trusted because of that network layout; if simplarr is ever exposed
// directly, a client could vary it to dodge the limiter.
func clientIP(r *http.Request) string {
	if v := strings.TrimSpace(r.Header.Get("X-Real-IP")); v != "" {
		if addr, err := netip.ParseAddr(v); err == nil {
			return addr.Unmap().String()
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
```


`app/internal/api/cookies.go`

```go
package api

import (
	"net/http"
	"strings"
	"time"

	"github.com/parsoFish/simplarr/app/internal/auth"
)

const (
	sessionCookieName = "simplarr_session"
	csrfCookieName    = "simplarr_csrf"
	csrfHeaderName    = "X-CSRF-Token"
)

// isHTTPS reports whether the browser reached nginx over HTTPS. nginx sets
// X-Forwarded-Proto; the Secure flag is only added then, so plain-HTTP LAN
// use keeps working.
func isHTTPS(r *http.Request) bool {
	return strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")
}

func newCookie(name, value string, maxAge int, httpOnly, secure bool) *http.Cookie {
	return &http.Cookie{
		Name:     name,
		Value:    value,
		Path:     "/",
		MaxAge:   maxAge,
		HttpOnly: httpOnly,
		Secure:   secure,
		SameSite: http.SameSiteStrictMode,
	}
}

// setSessionCookies sets the HttpOnly session cookie and the CSRF cookie. The
// CSRF cookie must stay readable by the SPA so it can echo the value in the
// X-CSRF-Token header.
func setSessionCookies(w http.ResponseWriter, r *http.Request, s auth.Session, ttl time.Duration) {
	maxAge := int(ttl.Seconds())
	secure := isHTTPS(r)
	http.SetCookie(w, newCookie(sessionCookieName, s.ID, maxAge, true, secure))
	http.SetCookie(w, newCookie(csrfCookieName, s.CSRF, maxAge, false, secure))
}

func clearSessionCookies(w http.ResponseWriter, r *http.Request) {
	secure := isHTTPS(r)
	http.SetCookie(w, newCookie(sessionCookieName, "", -1, true, secure))
	http.SetCookie(w, newCookie(csrfCookieName, "", -1, false, secure))
}

// cookieValue returns the named cookie's value, or "" when it is absent.
func cookieValue(r *http.Request, name string) string {
	c, err := r.Cookie(name)
	if err != nil { // the only error is http.ErrNoCookie
		return ""
	}
	return c.Value
}
```


`app/internal/api/middleware.go`

```go
package api

import (
	"context"
	"net/http"
	"strings"

	"github.com/parsoFish/simplarr/app/internal/auth"
)

type ctxKey struct{}

// sessionFrom returns the session that protected stored on the request.
func sessionFrom(ctx context.Context) (auth.Session, bool) {
	s, ok := ctx.Value(ctxKey{}).(auth.Session)
	return s, ok
}

// contentSecurityPolicy lets the page load only its own scripts, styles and
// images. It has no inline allowance: the SPA must not rely on inline styles
// or scripts (revisit in the web UI plan if a component library needs them).
const contentSecurityPolicy = "default-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

// securityHeaders adds the baseline response headers and marks API and health
// responses uncacheable.
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Content-Security-Policy", contentSecurityPolicy)
		if r.URL.Path == "/healthz" || strings.HasPrefix(r.URL.Path, "/api/") {
			h.Set("Cache-Control", "no-store")
		}
		next.ServeHTTP(w, r)
	})
}

func isSafeMethod(m string) bool {
	return m == http.MethodGet || m == http.MethodHead || m == http.MethodOptions
}

// sessionFromRequest looks up the session named by the session cookie.
func (s *server) sessionFromRequest(r *http.Request) (auth.Session, bool) {
	return s.auth.Session(cookieValue(r, sessionCookieName))
}

// protected requires a valid session, and for every non-GET request also a
// CSRF token (spec §8.2). The token in the csrf cookie, the one in the
// X-CSRF-Token header and the one stored in the session must all match, so a
// cookie planted by an attacker is not enough. Every future session-only
// route is wrapped with this.
func (s *server) protected(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sess, ok := s.sessionFromRequest(r)
		if !ok {
			writeError(w, http.StatusUnauthorized, "unauthorized",
				"You are not signed in.", "Open /login and sign in with the admin password.")
			return
		}
		if !isSafeMethod(r.Method) &&
			!auth.TokensMatch(sess.CSRF, cookieValue(r, csrfCookieName), r.Header.Get(csrfHeaderName)) {
			writeError(w, http.StatusForbidden, "csrf_failed",
				"The request was missing a valid CSRF token.", "Reload the page and try again.")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, sess)))
	})
}
```


`app/internal/api/auth_handlers.go`

```go
package api

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"strings"

	"github.com/parsoFish/simplarr/app/internal/auth"
)

type stateResponse struct {
	SetupRequired bool `json:"setupRequired"`
	Authenticated bool `json:"authenticated"`
}

func (s *server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// authState tells the SPA which screen to show. It is open to anyone: it
// reveals only whether setup is pending and whether the caller is signed in.
func (s *server) authState(w http.ResponseWriter, r *http.Request) {
	_, authed := s.sessionFromRequest(r)
	writeJSON(w, http.StatusOK, stateResponse{SetupRequired: s.auth.SetupRequired(), Authenticated: authed})
}

// rejectIfLimited charges one attempt against ip and answers 429 (returning
// true) when ip has used up its attempts. It runs after the body is parsed and
// before any password work, so a limited client cannot burn CPU, cannot learn
// whether a guess was right, and cannot beat the limit with a parallel burst
// (see auth.Limiter).
func (s *server) rejectIfLimited(w http.ResponseWriter, ip string) bool {
	ok, retry := s.limiter.Allow(ip)
	if ok {
		return false
	}
	seconds := int(math.Ceil(retry.Seconds()))
	minutes := int(math.Ceil(float64(seconds) / 60))
	w.Header().Set("Retry-After", strconv.Itoa(seconds))
	s.log.Warn("rate limited", "ip", ip, "retryAfterSeconds", seconds)
	writeError(w, http.StatusTooManyRequests, "rate_limited",
		"Too many failed attempts.", fmt.Sprintf("Wait %d minute(s) and try again.", minutes))
	return true
}

func (s *server) internalError(w http.ResponseWriter, r *http.Request, what string, err error) {
	s.log.Error(what, "path", r.URL.Path, "err", err)
	writeError(w, http.StatusInternalServerError, "internal",
		"Something went wrong on the server.", "Check the simplarr container logs.")
}

func (s *server) authSetup(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Token    string `json:"token"`
		Password string `json:"password"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	ip := clientIP(r)
	if s.rejectIfLimited(w, ip) {
		return
	}

	err := s.auth.Setup(r.Context(), req.Token, req.Password)
	switch {
	case err == nil:
		s.limiter.Reset(ip)
		s.log.Info("admin password set", "ip", ip)
		writeJSON(w, http.StatusOK, stateResponse{})
	case errors.Is(err, auth.ErrSetupComplete):
		writeError(w, http.StatusConflict, "setup_complete",
			"Setup has already been completed.", "Sign in at /login.")
	case errors.Is(err, auth.ErrInvalidSetupToken):
		s.log.Warn("setup token rejected", "ip", ip)
		writeError(w, http.StatusForbidden, "invalid_setup_token",
			"The setup token is wrong.", "Copy it from the container logs: docker logs simplarr")
	case errors.Is(err, auth.ErrWeakPassword):
		reason := strings.TrimPrefix(err.Error(), auth.ErrWeakPassword.Error()+": ")
		writeError(w, http.StatusBadRequest, "weak_password", "Password rejected: "+reason+".", "")
	case errors.Is(err, context.Canceled):
		// The client went away; nothing to answer.
	default:
		s.internalError(w, r, "setup failed", err)
	}
}

func (s *server) authLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Password string `json:"password"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	ip := clientIP(r)
	if s.rejectIfLimited(w, ip) {
		return
	}

	sess, err := s.auth.Login(r.Context(), req.Password)
	switch {
	case err == nil:
		s.limiter.Reset(ip)
		setSessionCookies(w, r, sess, s.auth.SessionTTL())
		s.log.Info("login succeeded", "ip", ip)
		writeJSON(w, http.StatusOK, stateResponse{Authenticated: true})
	case errors.Is(err, auth.ErrSetupRequired):
		writeError(w, http.StatusConflict, "setup_required",
			"No admin password has been set yet.", "Open /setup and enter the setup token from the container logs.")
	case errors.Is(err, auth.ErrInvalidCredentials):
		s.log.Warn("login failed", "ip", ip)
		writeError(w, http.StatusUnauthorized, "invalid_credentials", "Incorrect password.", "")
	case errors.Is(err, context.Canceled):
		// The client went away; nothing to answer.
	default:
		s.internalError(w, r, "login failed unexpectedly", err)
	}
}

func (s *server) authLogout(w http.ResponseWriter, r *http.Request) {
	if sess, ok := sessionFrom(r.Context()); ok {
		s.auth.Logout(sess.ID)
	}
	clearSessionCookies(w, r)
	writeJSON(w, http.StatusOK, stateResponse{})
}
```


`app/internal/api/server.go`

```go
package api

import (
	"io/fs"
	"log/slog"
	"net/http"

	"github.com/parsoFish/simplarr/app/internal/auth"
)

// Deps are everything the handlers need. All fields except Static are required.
type Deps struct {
	Auth    *auth.Service
	Limiter *auth.Limiter
	Logger  *slog.Logger
	// Static is the built SPA, or nil when the binary has no UI.
	Static fs.FS
}

type server struct {
	auth    *auth.Service
	limiter *auth.Limiter
	log     *slog.Logger
}

// NewHandler returns the complete HTTP handler: the API under /api/v1,
// /healthz, and the SPA for everything else.
//
// Client routes of the SPA must not start with a prefix nginx routes to
// another service (/radarr, /sonarr, /prowlarr, /overseerr, /torrent,
// /tautulli, /plex, /health/): spec §3.3.
func NewHandler(d Deps) http.Handler {
	s := &server{auth: d.Auth, limiter: d.Limiter, log: d.Logger}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /api/v1/auth/state", s.authState)
	mux.HandleFunc("POST /api/v1/auth/setup", s.authSetup)
	mux.HandleFunc("POST /api/v1/auth/login", s.authLogin)
	mux.Handle("POST /api/v1/auth/logout", s.protected(http.HandlerFunc(s.authLogout)))
	mux.HandleFunc("/api/", func(w http.ResponseWriter, _ *http.Request) {
		writeError(w, http.StatusNotFound, "not_found", "No such API endpoint.", "")
	})
	mux.Handle("/", spaHandler(d.Static))
	return securityHeaders(mux)
}
```


- [ ] **Step 4: Run the tests (repeat the race run), vet and lint**

```bash
cd app
go test ./internal/api/ -race -cover -count=1
for i in 1 2 3; do go test ./internal/api/ -race -count=1 >/dev/null && echo "race run $i ok"; done
gofmt -l .
go vet ./...
golangci-lint run ./...
```

Expected: `ok … coverage: 9x%`; three `race run N ok` lines; no other output. `TestParallelLoginBurstCannotExceedTheLimit` must report exactly 5 × 401 and the rest 429 every time.

- [ ] **Step 5: Leave the work uncommitted.**

---

### Task 8: The `simplarr` command: serve, healthcheck, version

**Files:**
- Create: `app/cmd/simplarr/main.go`, `app/cmd/simplarr/serve.go`, `app/cmd/simplarr/healthcheck.go`
- Test: `app/cmd/simplarr/main_test.go`

**Interfaces:**
- Consumes: Tasks 1–7 (`config.Load`, `logging.New`, `store.EnsureDir`, `auth.NewService` / `NewHasher` / `NewSessions` / `NewLimiter` / `AnnounceSetupToken`, `api.NewHandler`, `webui.Dist`).
- Produces:
  - `simplarr serve` (default), `simplarr healthcheck`, `simplarr version`, `simplarr help`; exit codes 0, 1 (runtime/config), 2 (usage)
  - `run(args []string, stdout, stderr io.Writer, getenv func(string) string) int`
  - `buildHandler(cfg config.Config, logger *slog.Logger, static fs.FS) (http.Handler, error)`: ensures `/data`, loads the admin state, announces the setup token if pending, returns the handler. Fails before binding a port.
  - `serveHTTP(ctx context.Context, ln net.Listener, handler http.Handler, logger *slog.Logger) error`: graceful shutdown on `ctx` end (10 s)
  - `probeURL(listen string) (string, error)`, `probe(client *http.Client, url string) error`
  - the `-X main.version=…` build variable `version` (default `dev`)

- [ ] **Step 1: Write the failing test**

`app/cmd/simplarr/main_test.go`

```go
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/parsoFish/simplarr/app/internal/config"
	"github.com/parsoFish/simplarr/app/internal/logging"
)

func envMap(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestRunDispatch(t *testing.T) {
	tests := []struct {
		name     string
		args     []string
		env      map[string]string
		wantCode int
		wantOut  string
		wantErr  string
	}{
		{"version", []string{"version"}, nil, 0, version + "\n", ""},
		{"help", []string{"help"}, nil, 0, "usage: simplarr", ""},
		{"unknown command", []string{"frobnicate"}, nil, 2, "", `unknown command "frobnicate"`},
		{"extra args", []string{"version", "now"}, nil, 2, "", "takes no arguments"},
		{"serve with bad config", []string{"serve"}, map[string]string{"SIMPLARR_LISTEN": "nonsense"}, 1, "", "SIMPLARR_LISTEN"},
		{"default command is serve", nil, map[string]string{"RADARR_PORT": "0"}, 1, "", "RADARR_PORT"},
		{"healthcheck with bad config", []string{"healthcheck"}, map[string]string{"SIMPLARR_LISTEN": "nonsense"}, 1, "", "SIMPLARR_LISTEN"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var out, errOut bytes.Buffer
			code := run(tc.args, &out, &errOut, envMap(tc.env))
			if code != tc.wantCode {
				t.Errorf("exit code = %d, want %d (stderr %q)", code, tc.wantCode, errOut.String())
			}
			if !strings.Contains(out.String(), tc.wantOut) {
				t.Errorf("stdout = %q, want it to contain %q", out.String(), tc.wantOut)
			}
			if !strings.Contains(errOut.String(), tc.wantErr) {
				t.Errorf("stderr = %q, want it to contain %q", errOut.String(), tc.wantErr)
			}
		})
	}
}

func testConfig(t *testing.T) config.Config {
	t.Helper()
	cfg, err := config.Load(envMap(map[string]string{"SIMPLARR_DATA_DIR": t.TempDir()}))
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

func TestServeEndToEndAndGracefulShutdown(t *testing.T) {
	cfg := testConfig(t)
	var logs bytes.Buffer
	logger := logging.New(&logs, slog.LevelInfo)

	handler, err := buildHandler(cfg, logger, nil)
	if err != nil {
		t.Fatalf("buildHandler: %v", err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- serveHTTP(ctx, ln, handler, logger) }()

	base := "http://" + ln.Addr().String()
	var state struct{ SetupRequired, Authenticated bool }
	for path, into := range map[string]any{"/healthz": &map[string]bool{}, "/api/v1/auth/state": &state} {
		resp, err := http.Get(base + path)
		if err != nil {
			t.Fatalf("GET %s: %v", path, err)
		}
		if err := json.NewDecoder(resp.Body).Decode(into); err != nil || resp.StatusCode != 200 {
			t.Fatalf("GET %s: %d, decode err %v", path, resp.StatusCode, err)
		}
		resp.Body.Close()
	}
	if !state.SetupRequired || state.Authenticated {
		t.Errorf("state = %+v, want setupRequired on a fresh data dir", state)
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("serveHTTP returned %v after shutdown", err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("server did not shut down")
	}

	if n := strings.Count(logs.String(), "First-run setup token: "); n != 1 {
		t.Errorf("setup token announced %d times, want exactly once:\n%s", n, logs.String())
	}
}

func TestBuildHandlerDoesNotAnnounceTokenWhenAdminExists(t *testing.T) {
	cfg := testConfig(t)
	// A valid admin.json from a first run: build once, complete setup via the
	// service is covered elsewhere, so write the file through the API.
	var logs bytes.Buffer
	logger := logging.New(&logs, slog.LevelInfo)
	handler, err := buildHandler(cfg, logger, nil)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	token := between(logs.String(), "First-run setup token: ", " ")
	body := `{"token":"` + token + `","password":"a perfectly good password"}`
	resp, err := http.Post(srv.URL+"/api/v1/auth/setup", "application/json", strings.NewReader(body))
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("setup: %v %v", resp, err)
	}
	resp.Body.Close()

	logs.Reset()
	if _, err := buildHandler(cfg, logger, nil); err != nil {
		t.Fatalf("second buildHandler: %v", err)
	}
	if strings.Contains(logs.String(), "First-run setup token") {
		t.Errorf("token announced although an admin exists:\n%s", logs.String())
	}
}

func between(s, after, until string) string {
	i := strings.Index(s, after)
	if i < 0 {
		return ""
	}
	s = s[i+len(after):]
	if j := strings.Index(s, until); j >= 0 {
		return s[:j]
	}
	return s
}

func TestBuildHandlerFailsFast(t *testing.T) {
	t.Run("corrupt admin.json", func(t *testing.T) {
		cfg := testConfig(t)
		path := filepath.Join(cfg.DataDir, "admin.json")
		if err := os.WriteFile(path, []byte("{{{"), 0o600); err != nil {
			t.Fatal(err)
		}
		_, err := buildHandler(cfg, logging.New(io.Discard, slog.LevelInfo), nil)
		if err == nil || !strings.Contains(err.Error(), path) {
			t.Errorf("err = %v, want error naming %s", err, path)
		}
	})
	t.Run("data dir is a file", func(t *testing.T) {
		cfg := testConfig(t)
		file := filepath.Join(cfg.DataDir, "afile")
		if err := os.WriteFile(file, nil, 0o600); err != nil {
			t.Fatal(err)
		}
		cfg.DataDir = file
		_, err := buildHandler(cfg, logging.New(io.Discard, slog.LevelInfo), nil)
		if err == nil || !strings.Contains(err.Error(), file) {
			t.Errorf("err = %v, want error naming %s", err, file)
		}
	})
}

func TestProbeURL(t *testing.T) {
	tests := map[string]string{
		":8080":          "http://127.0.0.1:8080/healthz",
		"0.0.0.0:9000":   "http://127.0.0.1:9000/healthz",
		"[::]:9000":      "http://127.0.0.1:9000/healthz",
		"127.0.0.1:8081": "http://127.0.0.1:8081/healthz",
		"10.0.0.5:8080":  "http://10.0.0.5:8080/healthz",
	}
	for listen, want := range tests {
		got, err := probeURL(listen)
		if err != nil || got != want {
			t.Errorf("probeURL(%q) = %q, %v; want %q", listen, got, err, want)
		}
	}
	if _, err := probeURL("nonsense"); err == nil {
		t.Error("probeURL(nonsense) succeeded")
	}
}

func TestProbe(t *testing.T) {
	ok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) }))
	defer ok.Close()
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(503) }))
	defer bad.Close()
	client := &http.Client{Timeout: time.Second}

	if err := probe(client, ok.URL); err != nil {
		t.Errorf("healthy server: %v", err)
	}
	if err := probe(client, bad.URL); err == nil || !strings.Contains(err.Error(), "503") {
		t.Errorf("unhealthy server: err = %v, want one naming 503", err)
	}
	closed := httptest.NewServer(http.NotFoundHandler())
	url := closed.URL
	closed.Close()
	if err := probe(client, url); err == nil {
		t.Error("closed server: want error")
	}
}
```


- [ ] **Step 2: Run it and watch it fail**

```bash
cd app && go test ./cmd/simplarr/
```

Expected: build failure: `undefined: run`, `undefined: version`, `undefined: buildHandler`, `undefined: serveHTTP`, `undefined: probeURL`.

- [ ] **Step 3: Write the implementation**

`app/cmd/simplarr/main.go`

```go
// Command simplarr is the control-plane UI and API for a simplarr stack.
package main

import (
	"fmt"
	"io"
	"os"
)

// version is set at build time: -ldflags "-X main.version=1.2.3".
var version = "dev"

const usage = `usage: simplarr [command]

commands:
  serve        run the web UI and API (the default)
  healthcheck  exit 0 if the local server answers /healthz
  version      print the version
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr, os.Getenv))
}

// run is main with its inputs injected, so tests can drive it. It returns the
// process exit code.
func run(args []string, stdout, stderr io.Writer, getenv func(string) string) int {
	cmd := "serve"
	if len(args) > 0 {
		cmd = args[0]
	}
	if len(args) > 1 {
		fmt.Fprintf(stderr, "simplarr: %s takes no arguments\n\n%s", cmd, usage)
		return 2
	}

	switch cmd {
	case "serve":
		return cmdServe(stdout, stderr, getenv)
	case "healthcheck":
		return cmdHealthcheck(stderr, getenv)
	case "version":
		fmt.Fprintln(stdout, version)
		return 0
	case "help", "-h", "--help":
		fmt.Fprint(stdout, usage)
		return 0
	default:
		fmt.Fprintf(stderr, "simplarr: unknown command %q\n\n%s", cmd, usage)
		return 2
	}
}
```


`app/cmd/simplarr/serve.go`

```go
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/parsoFish/simplarr/app/internal/api"
	"github.com/parsoFish/simplarr/app/internal/auth"
	"github.com/parsoFish/simplarr/app/internal/config"
	"github.com/parsoFish/simplarr/app/internal/logging"
	"github.com/parsoFish/simplarr/app/internal/store"
	"github.com/parsoFish/simplarr/app/internal/webui"
)

const (
	sessionTTL      = 7 * 24 * time.Hour // spec §8.2
	loginMaxFails   = 5                  // spec §8.2: 5 failures ...
	loginFailWindow = 15 * time.Minute   // ... per 15 minutes per IP
	hashConcurrency = 2                  // argon2id uses 64 MiB per hash
	shutdownTimeout = 10 * time.Second
)

// cmdServe loads configuration, prepares state, then serves until SIGINT or
// SIGTERM. Anything wrong with the configuration or the data directory stops
// the process before it binds a port.
func cmdServe(stdout, stderr io.Writer, getenv func(string) string) int {
	cfg, err := config.Load(getenv)
	if err != nil {
		fmt.Fprintf(stderr, "simplarr: invalid configuration:\n%v\n", err)
		return 1
	}
	logger := logging.New(stdout, slog.LevelInfo)

	handler, err := buildHandler(cfg, logger, webui.Dist())
	if err != nil {
		logger.Error("startup failed", "err", err)
		return 1
	}
	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		logger.Error("cannot listen", "addr", cfg.Listen, "err", err)
		return 1
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	logger.Info("simplarr listening", "addr", ln.Addr().String(), "version", version, "topology", string(cfg.Topology))
	if err := serveHTTP(ctx, ln, handler, logger); err != nil {
		logger.Error("server stopped", "err", err)
		return 1
	}
	return 0
}

// buildHandler prepares /data, loads the admin state, prints the setup token
// when first-run setup is pending, and returns the HTTP handler.
func buildHandler(cfg config.Config, logger *slog.Logger, static fs.FS) (http.Handler, error) {
	if err := store.EnsureDir(cfg.DataDir); err != nil {
		return nil, err
	}
	svc, err := auth.NewService(auth.ServiceConfig{
		DataDir:  cfg.DataDir,
		Hasher:   auth.NewHasher(auth.DefaultParams, hashConcurrency),
		Sessions: auth.NewSessions(sessionTTL, time.Now),
		Logger:   logger,
	})
	if err != nil {
		return nil, err
	}
	if token, pending := svc.PendingSetupToken(); pending {
		auth.AnnounceSetupToken(logger, token)
	}
	return api.NewHandler(api.Deps{
		Auth:    svc,
		Limiter: auth.NewLimiter(loginMaxFails, loginFailWindow, time.Now),
		Logger:  logger,
		Static:  static,
	}), nil
}

// serveHTTP serves on ln until ctx ends, then drains in-flight requests.
func serveHTTP(ctx context.Context, ln net.Listener, handler http.Handler, logger *slog.Logger) error {
	srv := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       2 * time.Minute,
		ErrorLog:          slog.NewLogLogger(logger.Handler(), slog.LevelError),
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()

	select {
	case err := <-errc:
		return err // Serve only returns a non-nil error
	case <-ctx.Done():
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("shutdown: %w", err)
	}
	if err := <-errc; !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
```


`app/cmd/simplarr/healthcheck.go`

```go
package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"time"

	"github.com/parsoFish/simplarr/app/internal/config"
)

const healthcheckTimeout = 3 * time.Second

// cmdHealthcheck is the container HEALTHCHECK: the distroless image has no
// curl, so the binary probes itself. It exits 0 only if /healthz answers 200.
func cmdHealthcheck(stderr io.Writer, getenv func(string) string) int {
	cfg, err := config.Load(getenv)
	if err != nil {
		fmt.Fprintf(stderr, "healthcheck: invalid configuration:\n%v\n", err)
		return 1
	}
	url, err := probeURL(cfg.Listen)
	if err != nil {
		fmt.Fprintf(stderr, "healthcheck: %v\n", err)
		return 1
	}
	if err := probe(&http.Client{Timeout: healthcheckTimeout}, url); err != nil {
		fmt.Fprintf(stderr, "healthcheck: %v\n", err)
		return 1
	}
	return 0
}

// probeURL turns the listen address into a loopback URL: a wildcard bind
// (":8080", "0.0.0.0:8080", "[::]:8080") is reached through 127.0.0.1.
func probeURL(listen string) (string, error) {
	host, port, err := net.SplitHostPort(listen)
	if err != nil {
		return "", fmt.Errorf("listen address %q: %w", listen, err)
	}
	if ip := net.ParseIP(host); host == "" || (ip != nil && ip.IsUnspecified()) {
		host = "127.0.0.1"
	}
	return "http://" + net.JoinHostPort(host, port) + "/healthz", nil
}

func probe(client *http.Client, url string) error {
	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("GET %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: status %d", url, resp.StatusCode)
	}
	return nil
}
```


- [ ] **Step 4: Whole-backend verification**

```bash
cd app
gofmt -l .
go vet ./...
go test ./... -race -count=1
golangci-lint run ./...
go test ./internal/... -race -coverprofile=coverage.out >/dev/null
go tool cover -func=coverage.out | tail -1
go mod tidy -diff && echo "go.mod tidy"
```

Expected: no gofmt/vet/lint output; every package `ok`; the coverage line shows `total: … 9x.x%` (must be at least 80.0%; the spike measured 93.0%); `go.mod tidy`. `coverage.out` is git-ignored (Task 9 adds the rule); leave it.

- [ ] **Step 5: Smoke-test the real binary (no UI yet)**

This builds without the `webdist` tag, so `/` answers 503 `ui_not_built`; the API is fully usable. It uses throwaway files under `/tmp/simplarr-plan2*`; leave them in place.

```bash
cd app
go build -o /tmp/simplarr-plan2 ./cmd/simplarr
mkdir -p /tmp/simplarr-plan2-data
export SIMPLARR_LISTEN=127.0.0.1:18080 SIMPLARR_DATA_DIR=/tmp/simplarr-plan2-data SIMPLARR_CONFIG_DIR=/tmp/simplarr-plan2-data
/tmp/simplarr-plan2 serve > /tmp/simplarr-plan2.log 2>&1 &
SERVER=$!
for _ in $(seq 1 30); do curl -fsS http://127.0.0.1:18080/healthz >/dev/null 2>&1 && break; sleep 0.2; done
B=http://127.0.0.1:18080; J='Content-Type: application/json'
TOKEN=$(grep -o 'First-run setup token: [0-9a-f]*' /tmp/simplarr-plan2.log | awk '{print $4}')
echo "healthz: $(curl -s $B/healthz)"
echo "root:    $(curl -s $B/ | head -c 90)"
echo "state:   $(curl -s $B/api/v1/auth/state)"
curl -s -X POST -H "$J" -d "{\"token\":\"$TOKEN\",\"password\":\"a perfectly good password\"}" $B/api/v1/auth/setup; echo
curl -s -c /tmp/simplarr-plan2.jar -X POST -H "$J" -d '{"password":"a perfectly good password"}' $B/api/v1/auth/login; echo
CSRF=$(grep simplarr_csrf /tmp/simplarr-plan2.jar | awk '{print $7}')
echo "logout without csrf: $(curl -s -b /tmp/simplarr-plan2.jar -X POST $B/api/v1/auth/logout | head -c 80)"
echo "logout with csrf:    $(curl -s -b /tmp/simplarr-plan2.jar -X POST -H "X-CSRF-Token: $CSRF" $B/api/v1/auth/logout)"
ls -l /tmp/simplarr-plan2-data/admin.json
/tmp/simplarr-plan2 healthcheck; echo "healthcheck exit: $?"
kill -TERM "$SERVER"; wait "$SERVER"; echo "server exit: $?"
unset SIMPLARR_LISTEN SIMPLARR_DATA_DIR SIMPLARR_CONFIG_DIR
```

Expected: `healthz: {"ok":true}`; `root:` shows the `ui_not_built` error JSON; `state:` `{"setupRequired":true,"authenticated":false}`; setup answers `{"setupRequired":false,"authenticated":false}`; login answers `{"setupRequired":false,"authenticated":true}`; logout without the CSRF header shows `csrf_failed`; with it `{"setupRequired":false,"authenticated":false}`; `admin.json` is `-rw-------`; `healthcheck exit: 0`; `server exit: 0`.

- [ ] **Step 6: Leave the work uncommitted.** Report the output of Steps 4 and 5.

---

## Gate A: security review of the Go backend, then commit Tasks 1–8 (controller)

Tasks 1–8 are the auth, input-handling and API code. Nothing is committed until this gate passes.

- [ ] **A1. Stage everything so the review sees it** (staging is not committing; `git diff --cached` now shows the new files):

```bash
cd ~/projects/simplarr/.worktrees/app-skeleton-auth
git add -A app
git status --short | head -60
```

- [ ] **A2. Run the `security-review` skill** on the pending changes. Brief it on what to check, because these are the places a mistake would hurt:
  - **Setup token:** only in the log message; compared in constant time; cleared after setup; two concurrent setups cannot both win; a corrupt `admin.json` never re-opens setup.
  - **Password handling:** argon2id parameters and the stored-parameters rule; bounded concurrency (memory DoS); the password never reaches a log, an error or a response; length limits.
  - **Sessions and cookies:** 256-bit IDs, SHA-256-keyed map, absolute 7-day TTL, `HttpOnly` + `SameSite=Strict` + `Secure` behind HTTPS, new ID per login, server-side invalidation on logout.
  - **CSRF:** the cookie, header and session token must all match; every non-GET route goes through `protected`; login and setup are the only exempt routes.
  - **Rate limiting:** atomic charge-before-check; `X-Real-IP` is trusted only because nginx is the sole route in (state this as a deployment assumption in the findings, not as a bug); memory cap on tracked IPs.
  - **Input handling:** `Content-Type: application/json` enforced, 64 KiB body cap, unknown fields and trailing data rejected, env values validated, path traversal in the SPA handler.
  - **Response headers:** CSP, `nosniff`, `X-Frame-Options`, `Cache-Control: no-store` on `/api/` and `/healthz`.
  - **Files:** `admin.json` mode 0600, atomic write, `EnforceMode` behaviour.

- [ ] **A3. Fix every High and Medium finding test-first** (add a failing test, then the fix, then rerun Task 8 Step 4). Record Low findings and any accepted risk in the PR description. Re-stage with `git add -A app`.

- [ ] **A4. Commit one conventional commit per task.** `git commit -- <paths>` commits only those paths, so the staged remainder stays staged for the next commit. `go.mod`/`go.sum` go in the first commit: the module file already lists `x/crypto`, and intermediate commits are not built by CI (it runs on the branch tip).

```bash
cd ~/projects/simplarr/.worktrees/app-skeleton-auth
git commit -m "feat: add app module with validated environment config" \
  -- app/go.mod app/go.sum app/.golangci.yml app/internal/config
git commit -m "feat: add slog secret redaction and atomic file store" \
  -- app/internal/logging app/internal/store
git commit -m "feat: add argon2id password hasher with bounded concurrency" \
  -- app/internal/auth/password.go app/internal/auth/password_test.go app/internal/auth/helpers_test.go
git commit -m "feat: add setup tokens, sessions, csrf matching and login rate limiter" \
  -- app/internal/auth/tokens.go app/internal/auth/tokens_test.go app/internal/auth/session.go app/internal/auth/session_test.go app/internal/auth/ratelimit.go app/internal/auth/ratelimit_test.go
git commit -m "feat: add admin service with setup token and session login" \
  -- app/internal/auth/service.go app/internal/auth/service_test.go
git commit -m "feat: add api error shape, SPA handler and embedded UI hook" \
  -- app/internal/api/errors.go app/internal/api/spa.go app/internal/api/helpers_test.go app/internal/api/spa_test.go app/internal/webui
git commit -m "feat: add auth api with cookies, csrf and rate limiting" \
  -- app/internal/api
git commit -m "feat: add simplarr serve, healthcheck and version commands" \
  -- app/cmd
git status --short
git log --oneline origin/main..HEAD
```

Expected: `git status --short` prints nothing (if a path was missed, add it to the matching commit with `git commit --amend` only if that commit is still the latest; otherwise make a `fix:` commit), and eight commits are listed. The path list for `app/internal/api` in the seventh commit also covers files already committed in the sixth; that is fine because `git commit -- <dir>` only commits what differs.

---

### Task 9: Web toolchain and API client

**Files:**
- Create: `app/web/go.mod`, `app/web/package.json`, `app/web/package-lock.json` (generated), `app/web/tsconfig.json`, `app/web/vite.config.ts`, `app/web/eslint.config.js`, `app/web/index.html`
- Create: `app/web/src/api/client.ts`, `app/web/src/test/server.ts`, `app/web/src/test/setup.ts`
- Test: `app/web/src/api/client.test.ts`
- Modify: `.gitignore` (repo root)

**Interfaces:**
- Consumes: nothing from earlier tasks (the backend contract: cookie `simplarr_csrf`, header `X-CSRF-Token`, error envelope).
- Produces (package `src/api/client.ts`):
  - `class ApiError extends Error { status: number; code: string; fix: string | undefined }`
  - `readCookie(name: string, cookies?: string): string | undefined`
  - `apiFetch<T>(path: string, options?: { method?: string; body?: unknown }): Promise<T>`: sends the CSRF header from the cookie on every non-GET/HEAD request, JSON in and out, same-origin credentials; failures throw `ApiError` (`network_error`, `invalid_response`, `http_<status>`, or the server's own code)
  - test support: `server` (MSW `setupServer()`), and a global setup that fails any request without a handler.

- [ ] **Step 1: Create the Go fence, the package file and install**

`app/web/go.mod` stops `go vet ./...` in `app/` from walking into `node_modules` (npm packages can ship `.go` files):

`app/web/go.mod`

```text
// This file makes web/ a separate Go module with no packages. Without it,
// `go vet ./...` and `go test ./...` in app/ descend into web/node_modules and
// pick up .go files that some npm packages ship (for example flatted/golang).
module github.com/parsoFish/simplarr/app/web

go 1.25.0
```


All versions are pinned exactly. TypeScript is 6.0.3 on purpose (see "Decisions" 5):

`app/web/package.json`

```json
{
  "name": "simplarr-web",
  "private": true,
  "version": "0.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc --noEmit && vite build",
    "lint": "eslint .",
    "typecheck": "tsc --noEmit",
    "test": "vitest run"
  },
  "dependencies": {
    "@tanstack/react-query": "5.107.1",
    "react": "19.3.1",
    "react-dom": "19.3.1",
    "react-router-dom": "7.18.5"
  },
  "devDependencies": {
    "@eslint/js": "10.0.1",
    "@testing-library/jest-dom": "7.0.1",
    "@testing-library/react": "16.3.3",
    "@testing-library/user-event": "14.6.10",
    "@types/react": "19.3.0",
    "@types/react-dom": "19.3.0",
    "@vitejs/plugin-react": "6.3.0",
    "eslint": "10.15.0",
    "eslint-plugin-react-hooks": "7.1.1",
    "globals": "17.14.0",
    "jsdom": "31.0.1",
    "msw": "3.0.5",
    "typescript": "6.0.3",
    "typescript-eslint": "8.72.2",
    "vite": "8.3.8",
    "vitest": "5.1.0"
  }
}
```


```bash
cd app/web && npm install --no-audit --no-fund
```

Expected: `added ~270 packages`, a new `package-lock.json`, and `EBADENGINE` warnings for `jsdom@31` / `w3c-xmlserializer` on Node 22.21.1 (harmless; see "Decisions" 12). No `ERESOLVE` error: if you see one, `typescript` is not `6.0.3`.

- [ ] **Step 2: Create the tool configuration**

`app/web/tsconfig.json`

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "moduleResolution": "bundler",
    "jsx": "react-jsx",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true,
    "isolatedModules": true,
    "verbatimModuleSyntax": true,
    "skipLibCheck": true,
    "noEmit": true,
    "types": ["vite/client"]
  },
  "include": ["src", "vite.config.ts"]
}
```


`app/web/vite.config.ts`

```ts
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vitest/config'

// In development the SPA runs on Vite's server and talks to a locally running
// `simplarr serve` on :8080. In production the Go binary serves the built files.
const backend = 'http://127.0.0.1:8080'

export default defineConfig({
  plugins: [react()],
  server: { proxy: { '/api': backend, '/healthz': backend } },
  // The Go binary embeds this directory (internal/webui, build tag webdist).
  // It sits outside the Vite root, so emptyOutDir must be explicit.
  build: { outDir: '../internal/webui/dist', emptyOutDir: true },
  test: {
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    restoreMocks: true,
  },
})
```


`app/web/eslint.config.js`

```js
import js from '@eslint/js'
import reactHooks from 'eslint-plugin-react-hooks'
import globals from 'globals'
import tseslint from 'typescript-eslint'

export default tseslint.config(
  { ignores: ['dist', 'node_modules'] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  reactHooks.configs.flat.recommended,
  {
    files: ['**/*.{ts,tsx}'],
    languageOptions: { globals: globals.browser },
  },
  {
    files: ['*.config.{js,ts}'],
    languageOptions: { globals: globals.node },
  },
)
```


`app/web/index.html`

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta name="color-scheme" content="light dark" />
    <title>Simplarr</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
```


- [ ] **Step 3: Write the test support and the failing test**

`app/web/src/test/server.ts`

```ts
import { setupServer } from 'msw/node'

// One MSW server for the whole test run. Tests add handlers with server.use or
// installBackend; any request without a handler fails the test.
export const server = setupServer()
```


`app/web/src/test/setup.ts`

```ts
import '@testing-library/jest-dom/vitest'
import { cleanup } from '@testing-library/react'
import { afterAll, afterEach, beforeAll } from 'vitest'
import { server } from './server'

beforeAll(() => server.listen({ onUnhandledFrame: 'error' }))

afterEach(() => {
  cleanup()
  server.resetHandlers()
  document.cookie = 'simplarr_csrf=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/'
})

afterAll(() => server.close())
```


`app/web/src/api/client.test.ts`

```ts
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import { server } from '../test/server'
import { ApiError, apiFetch, readCookie } from './client'

describe('readCookie', () => {
  it('finds a cookie among several', () => {
    expect(readCookie('b', 'a=1; b=two; c=3')).toBe('two')
  })
  it('keeps = signs inside the value and decodes it', () => {
    expect(readCookie('t', 't=abc%20def=; x=1')).toBe('abc def=')
  })
  it('returns undefined when absent', () => {
    expect(readCookie('missing', 'a=1')).toBeUndefined()
    expect(readCookie('missing', '')).toBeUndefined()
  })
})

describe('apiFetch', () => {
  it('sends no CSRF header on GET, even when the cookie exists', async () => {
    document.cookie = 'simplarr_csrf=abc; path=/'
    let seen: string | null = 'unset'
    server.use(
      http.get('/api/v1/thing', ({ request }) => {
        seen = request.headers.get('x-csrf-token')
        return HttpResponse.json({ ok: true })
      }),
    )
    await expect(apiFetch('/api/v1/thing')).resolves.toEqual({ ok: true })
    expect(seen).toBeNull()
  })

  it('echoes the CSRF cookie on POST and sends the body as JSON', async () => {
    document.cookie = 'simplarr_csrf=abc123; path=/'
    let seen: { csrf: string | null; contentType: string | null; body: unknown } | undefined
    server.use(
      http.post('/api/v1/thing', async ({ request }) => {
        seen = {
          csrf: request.headers.get('x-csrf-token'),
          contentType: request.headers.get('content-type'),
          body: await request.json(),
        }
        return HttpResponse.json({ ok: true })
      }),
    )
    await apiFetch('/api/v1/thing', { method: 'POST', body: { a: 1 } })
    expect(seen).toEqual({ csrf: 'abc123', contentType: 'application/json', body: { a: 1 } })
  })

  it('omits the CSRF header when there is no cookie', async () => {
    let seen: string | null = 'unset'
    server.use(
      http.post('/api/v1/thing', ({ request }) => {
        seen = request.headers.get('x-csrf-token')
        return HttpResponse.json({ ok: true })
      }),
    )
    await apiFetch('/api/v1/thing', { method: 'POST' })
    expect(seen).toBeNull()
  })

  it('turns the server error envelope into an ApiError', async () => {
    server.use(
      http.get('/api/v1/thing', () =>
        HttpResponse.json(
          { error: { code: 'rate_limited', message: 'Too many failed attempts.', fix: 'Wait 15 minute(s).' } },
          { status: 429 },
        ),
      ),
    )
    const error = await apiFetch('/api/v1/thing').catch((e: unknown) => e)
    expect(error).toBeInstanceOf(ApiError)
    expect(error).toMatchObject({
      status: 429,
      code: 'rate_limited',
      message: 'Too many failed attempts.',
      fix: 'Wait 15 minute(s).',
    })
  })

  it('falls back to a generic ApiError for non-JSON failures', async () => {
    server.use(http.get('/api/v1/thing', () => new HttpResponse('<h1>Bad gateway</h1>', { status: 502 })))
    await expect(apiFetch('/api/v1/thing')).rejects.toMatchObject({ status: 502, code: 'http_502' })
  })

  it('reports a network failure with a fix', async () => {
    server.use(http.get('/api/v1/thing', () => HttpResponse.error()))
    await expect(apiFetch('/api/v1/thing')).rejects.toMatchObject({ code: 'network_error', status: 0 })
  })

  it('rejects a successful response that is not JSON', async () => {
    server.use(http.get('/api/v1/thing', () => new HttpResponse('plain text', { status: 200 })))
    await expect(apiFetch('/api/v1/thing')).rejects.toMatchObject({ code: 'invalid_response' })
  })
})
```


- [ ] **Step 4: Run it and watch it fail**

```bash
cd app/web && npx vitest run
```

Expected: the suite fails to load with `Failed to resolve import "./client"` (the module does not exist yet).

- [ ] **Step 5: Write the implementation**

`app/web/src/api/client.ts`

```ts
// Thin fetch wrapper for the simplarr API. Every non-GET request echoes the
// CSRF cookie in the X-CSRF-Token header (double-submit, spec §8.2), and every
// failure becomes an ApiError that carries the server's code, message and fix.

const CSRF_COOKIE = 'simplarr_csrf'
const CSRF_HEADER = 'X-CSRF-Token'

export class ApiError extends Error {
  readonly status: number
  readonly code: string
  readonly fix: string | undefined

  constructor(status: number, code: string, message: string, fix?: string) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.code = code
    this.fix = fix
  }
}

export function readCookie(name: string, cookies: string = document.cookie): string | undefined {
  for (const part of cookies.split(';')) {
    const [key, ...rest] = part.trim().split('=')
    if (key === name) return decodeURIComponent(rest.join('='))
  }
  return undefined
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function toApiError(status: number, data: unknown): ApiError {
  if (isRecord(data) && isRecord(data.error)) {
    const { code, message, fix } = data.error
    if (typeof code === 'string' && typeof message === 'string') {
      return new ApiError(status, code, message, typeof fix === 'string' ? fix : undefined)
    }
  }
  return new ApiError(status, `http_${status}`, `The server answered ${status}.`)
}

interface RequestOptions {
  method?: string
  body?: unknown
}

export async function apiFetch<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const method = options.method ?? 'GET'
  const headers: Record<string, string> = { Accept: 'application/json' }
  if (options.body !== undefined) headers['Content-Type'] = 'application/json'
  if (method !== 'GET' && method !== 'HEAD') {
    const csrf = readCookie(CSRF_COOKIE)
    if (csrf) headers[CSRF_HEADER] = csrf
  }

  let response: Response
  try {
    response = await fetch(path, {
      method,
      headers,
      credentials: 'same-origin',
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    })
  } catch {
    throw new ApiError(0, 'network_error', 'Cannot reach the Simplarr server.', 'Check that the simplarr container is running.')
  }

  const text = await response.text()
  let data: unknown
  if (text) {
    try {
      data = JSON.parse(text)
    } catch {
      data = undefined
    }
  }
  if (!response.ok) throw toApiError(response.status, data)
  if (data === undefined) {
    throw new ApiError(response.status, 'invalid_response', 'The server sent a response that is not JSON.')
  }
  return data as T
}
```


- [ ] **Step 6: Run the tests, lint and typecheck**

```bash
cd app/web
npm test
npm run lint
npm run typecheck
```

Expected: `Test Files  1 passed`, all tests pass; lint and typecheck print nothing. (`npm run build` is not run yet: `index.html` points at `src/main.tsx`, which Task 10 adds.)

- [ ] **Step 7: Ignore build output.** Append this block to the end of the repo-root `.gitignore`:

`.gitignore (append)`

```text

# =============================================================================
# Control-plane UI (app/)
# =============================================================================
app/web/node_modules/
app/internal/webui/dist/
app/coverage.out
```


```bash
cd ~/projects/simplarr/.worktrees/app-skeleton-auth
git check-ignore -v app/web/node_modules app/internal/webui/dist app/coverage.out
```

Expected: all three paths are reported as ignored.

- [ ] **Step 8: Leave the work uncommitted.**

---

### Task 10: Setup and login pages, route guards, and the embedded-UI check

**Files:**
- Create: `app/web/src/api/auth.ts`
- Create: `app/web/src/components/AuthCard.tsx`, `ErrorMessage.tsx`, `RequireAuth.tsx`
- Create: `app/web/src/pages/SetupPage.tsx`, `LoginPage.tsx`, `HomePage.tsx`, `NotFoundPage.tsx`
- Create: `app/web/src/App.tsx`, `app/web/src/main.tsx`, `app/web/src/styles.css`
- Create: `app/web/src/test/backend.ts`, `app/web/src/test/render.tsx`
- Test: `app/web/src/App.test.tsx`, `app/web/src/pages/LoginPage.test.tsx`, `app/web/src/pages/SetupPage.test.tsx`

**Interfaces:**
- Consumes: Task 9 `apiFetch`, `ApiError`, `server`; Task 7 endpoints `GET /api/v1/auth/state`, `POST /api/v1/auth/{setup,login,logout}`, all answering `{setupRequired, authenticated}`.
- Produces:
  - `useAuthState()`, `useSetup()`, `useLogin()`, `useLogout()` (TanStack Query hooks; a successful mutation writes the returned state into the `['auth','state']` cache so guards react without a refetch)
  - routes `/setup`, `/login`, `/` (behind `RequireAuth`), `*` (not found). No route starts with an nginx-routed prefix.
  - the page contract the tests assert: headings `Set up Simplarr`, `Sign in`, `Page not found`; labels `Setup token`, `Admin password`, `Repeat password`; buttons `Set password`, `Sign in`, `Sign out`; errors in `role="alert"`; client-side password rule of 12 characters
  - test support: `installBackend(initial)` (MSW handlers that behave like the real auth API and record requests), `renderApp(route)`

- [ ] **Step 1: Write the test support and the failing tests**

`app/web/src/test/backend.ts`

```ts
import { http, HttpResponse } from 'msw'
import { server } from './server'

export interface BackendState {
  setupRequired: boolean
  authenticated: boolean
}

export interface RecordedRequest {
  method: string
  path: string
  body: unknown
  csrfHeader: string | null
}

export interface FakeBackend {
  state: BackendState
  requests: RecordedRequest[]
}

export const SETUP_TOKEN = '0123456789abcdef0123456789abcdef'
export const ADMIN_PASSWORD = 'a perfectly good password'
export const CSRF_VALUE = 'csrf-token-from-server'

function apiError(status: number, code: string, message: string, fix?: string) {
  return HttpResponse.json({ error: { code, message, fix } }, { status })
}

// installBackend registers MSW handlers that behave like the real auth API and
// records every request, so tests can assert on what the SPA sent.
export function installBackend(initial: BackendState): FakeBackend {
  const backend: FakeBackend = { state: { ...initial }, requests: [] }

  async function record(request: Request, path: string): Promise<unknown> {
    const text = await request.text()
    const body: unknown = text ? JSON.parse(text) : undefined
    backend.requests.push({
      method: request.method,
      path,
      body,
      csrfHeader: request.headers.get('x-csrf-token'),
    })
    return body
  }

  server.use(
    http.get('/api/v1/auth/state', () => HttpResponse.json(backend.state)),

    http.post('/api/v1/auth/setup', async ({ request }) => {
      const body = (await record(request, '/api/v1/auth/setup')) as { token: string; password: string }
      if (body.token !== SETUP_TOKEN) {
        return apiError(403, 'invalid_setup_token', 'The setup token is wrong.', 'Copy it from the container logs.')
      }
      backend.state = { setupRequired: false, authenticated: false }
      return HttpResponse.json(backend.state)
    }),

    http.post('/api/v1/auth/login', async ({ request }) => {
      const body = (await record(request, '/api/v1/auth/login')) as { password: string }
      if (body.password !== ADMIN_PASSWORD) {
        return apiError(401, 'invalid_credentials', 'Incorrect password.')
      }
      backend.state = { setupRequired: false, authenticated: true }
      document.cookie = `simplarr_csrf=${CSRF_VALUE}; path=/`
      return HttpResponse.json(backend.state)
    }),

    http.post('/api/v1/auth/logout', async ({ request }) => {
      await record(request, '/api/v1/auth/logout')
      if (request.headers.get('x-csrf-token') !== CSRF_VALUE) {
        return apiError(403, 'csrf_failed', 'The request was missing a valid CSRF token.', 'Reload the page and try again.')
      }
      backend.state = { setupRequired: false, authenticated: false }
      return HttpResponse.json(backend.state)
    }),
  )
  return backend
}
```


`app/web/src/test/render.tsx`

```tsx
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { App } from '../App'

// Renders the whole app at a route with a fresh query cache.
export function renderApp(route: string) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={[route]}>
        <App />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}
```


`app/web/src/App.test.tsx`

```tsx
import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { ADMIN_PASSWORD, CSRF_VALUE, installBackend } from './test/backend'
import { renderApp } from './test/render'

describe('route guards', () => {
  it('sends an unauthenticated visitor from / to the login page', async () => {
    installBackend({ setupRequired: false, authenticated: false })
    renderApp('/')
    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
  })

  it('sends everyone to setup on first run', async () => {
    installBackend({ setupRequired: true, authenticated: false })
    renderApp('/')
    expect(await screen.findByRole('heading', { name: 'Set up Simplarr' })).toBeInTheDocument()
  })

  it('shows the home page to a signed-in admin', async () => {
    installBackend({ setupRequired: false, authenticated: true })
    renderApp('/')
    expect(await screen.findByText(/you are signed in/i)).toBeInTheDocument()
  })

  it('keeps a signed-in admin away from the login and setup pages', async () => {
    installBackend({ setupRequired: false, authenticated: true })
    renderApp('/login')
    expect(await screen.findByText(/you are signed in/i)).toBeInTheDocument()
  })

  it('shows a not-found page for unknown routes', async () => {
    installBackend({ setupRequired: false, authenticated: true })
    renderApp('/no/such/page')
    expect(await screen.findByRole('heading', { name: 'Page not found' })).toBeInTheDocument()
  })
})

describe('sign out', () => {
  it('posts the CSRF token from the cookie and returns to the login page', async () => {
    const user = userEvent.setup()
    const backend = installBackend({ setupRequired: false, authenticated: false })

    renderApp('/login')
    await user.type(await screen.findByLabelText('Admin password'), ADMIN_PASSWORD)
    await user.click(screen.getByRole('button', { name: 'Sign in' }))
    await user.click(await screen.findByRole('button', { name: 'Sign out' }))

    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
    const logout = backend.requests.find((r) => r.path === '/api/v1/auth/logout')
    expect(logout?.csrfHeader).toBe(CSRF_VALUE)
  })
})
```


`app/web/src/pages/LoginPage.test.tsx`

```tsx
import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { ADMIN_PASSWORD, installBackend } from '../test/backend'
import { renderApp } from '../test/render'

describe('LoginPage', () => {
  it('signs in with the admin password and lands on the home page', async () => {
    const user = userEvent.setup()
    const backend = installBackend({ setupRequired: false, authenticated: false })

    renderApp('/login')
    await user.type(await screen.findByLabelText('Admin password'), ADMIN_PASSWORD)
    await user.click(screen.getByRole('button', { name: 'Sign in' }))

    expect(await screen.findByText(/you are signed in/i)).toBeInTheDocument()
    expect(backend.requests).toEqual([
      { method: 'POST', path: '/api/v1/auth/login', body: { password: ADMIN_PASSWORD }, csrfHeader: null },
    ])
  })

  it('shows the server message for a wrong password and stays on the page', async () => {
    const user = userEvent.setup()
    installBackend({ setupRequired: false, authenticated: false })

    renderApp('/login')
    await user.type(await screen.findByLabelText('Admin password'), 'not the password')
    await user.click(screen.getByRole('button', { name: 'Sign in' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Incorrect password.')
    expect(screen.getByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
  })

  it('redirects to setup when no admin exists yet', async () => {
    installBackend({ setupRequired: true, authenticated: false })
    renderApp('/login')
    expect(await screen.findByRole('heading', { name: 'Set up Simplarr' })).toBeInTheDocument()
  })
})
```


`app/web/src/pages/SetupPage.test.tsx`

```tsx
import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { ADMIN_PASSWORD, SETUP_TOKEN, installBackend } from '../test/backend'
import { renderApp } from '../test/render'

async function fillForm(user: ReturnType<typeof userEvent.setup>, token: string, password: string, confirm: string) {
  await user.type(await screen.findByLabelText('Setup token'), token)
  await user.type(screen.getByLabelText('Admin password'), password)
  await user.type(screen.getByLabelText('Repeat password'), confirm)
  await user.click(screen.getByRole('button', { name: 'Set password' }))
}

describe('SetupPage', () => {
  it('sets the password and moves on to the login page', async () => {
    const user = userEvent.setup()
    const backend = installBackend({ setupRequired: true, authenticated: false })

    renderApp('/setup')
    await fillForm(user, `  ${SETUP_TOKEN}  `, ADMIN_PASSWORD, ADMIN_PASSWORD)

    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
    expect(backend.requests).toEqual([
      {
        method: 'POST',
        path: '/api/v1/auth/setup',
        body: { token: SETUP_TOKEN, password: ADMIN_PASSWORD },
        csrfHeader: null,
      },
    ])
  })

  it('rejects a short password without calling the server', async () => {
    const user = userEvent.setup()
    const backend = installBackend({ setupRequired: true, authenticated: false })

    renderApp('/setup')
    await fillForm(user, SETUP_TOKEN, 'too short', 'too short')

    expect(await screen.findByRole('alert')).toHaveTextContent('Use at least 12 characters.')
    expect(backend.requests).toEqual([])
  })

  it('rejects mismatched passwords without calling the server', async () => {
    const user = userEvent.setup()
    const backend = installBackend({ setupRequired: true, authenticated: false })

    renderApp('/setup')
    await fillForm(user, SETUP_TOKEN, ADMIN_PASSWORD, `${ADMIN_PASSWORD}!`)

    expect(await screen.findByRole('alert')).toHaveTextContent('do not match')
    expect(backend.requests).toEqual([])
  })

  it('shows the server message and fix for a wrong token', async () => {
    const user = userEvent.setup()
    installBackend({ setupRequired: true, authenticated: false })

    renderApp('/setup')
    await fillForm(user, 'wrong-token', ADMIN_PASSWORD, ADMIN_PASSWORD)

    const alert = await screen.findByRole('alert')
    expect(alert).toHaveTextContent('The setup token is wrong.')
    expect(alert).toHaveTextContent('Copy it from the container logs.')
    expect(screen.getByRole('heading', { name: 'Set up Simplarr' })).toBeInTheDocument()
  })

  it('redirects to the login page once setup is complete', async () => {
    installBackend({ setupRequired: false, authenticated: false })
    renderApp('/setup')
    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
  })
})
```


- [ ] **Step 2: Run them and watch them fail**

```bash
cd app/web && npx vitest run
```

Expected: the new suites fail to load with `Failed to resolve import "../App"`; the Task 9 `client.test.ts` suite still passes.

- [ ] **Step 3: Write the implementation**

`app/web/src/api/auth.ts`

```ts
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { apiFetch } from './client'

export interface AuthState {
  setupRequired: boolean
  authenticated: boolean
}

export const authStateKey = ['auth', 'state'] as const

export function useAuthState() {
  return useQuery({
    queryKey: authStateKey,
    queryFn: () => apiFetch<AuthState>('/api/v1/auth/state'),
  })
}

// Every auth endpoint answers with the new AuthState, so a successful call
// updates the cache directly and the route guards react without a refetch.
function useAuthMutation<Variables>(path: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (variables: Variables) => apiFetch<AuthState>(path, { method: 'POST', body: variables }),
    onSuccess: (state) => {
      queryClient.setQueryData(authStateKey, state)
    },
  })
}

export function useSetup() {
  return useAuthMutation<{ token: string; password: string }>('/api/v1/auth/setup')
}

export function useLogin() {
  return useAuthMutation<{ password: string }>('/api/v1/auth/login')
}

export function useLogout() {
  return useAuthMutation<undefined>('/api/v1/auth/logout')
}
```


`app/web/src/components/AuthCard.tsx`

```tsx
import type { ReactNode } from 'react'

export function AuthCard({ title, children }: { title: string; children: ReactNode }) {
  return (
    <main className="auth-card">
      <h1>{title}</h1>
      {children}
    </main>
  )
}
```


`app/web/src/components/ErrorMessage.tsx`

```tsx
import { ApiError } from '../api/client'

// Shows an error with the server's "fix" line when there is one.
export function ErrorMessage({ error }: { error: unknown }) {
  const message = error instanceof Error ? error.message : 'Something went wrong.'
  const fix = error instanceof ApiError ? error.fix : undefined
  return (
    <div role="alert" className="error">
      <p>{message}</p>
      {fix ? <p className="fix">{fix}</p> : null}
    </div>
  )
}
```


`app/web/src/components/RequireAuth.tsx`

```tsx
import { Navigate, Outlet } from 'react-router-dom'
import { useAuthState } from '../api/auth'
import { AuthCard } from './AuthCard'
import { ErrorMessage } from './ErrorMessage'

// Renders its child routes only for a signed-in admin. Everyone else is sent
// to the setup page (first run) or the login page.
export function RequireAuth() {
  const state = useAuthState()
  if (state.isPending) {
    return (
      <AuthCard title="Simplarr">
        <p>Loading…</p>
      </AuthCard>
    )
  }
  if (state.isError) {
    return (
      <AuthCard title="Simplarr">
        <ErrorMessage error={state.error} />
      </AuthCard>
    )
  }
  if (state.data.setupRequired) return <Navigate to="/setup" replace />
  if (!state.data.authenticated) return <Navigate to="/login" replace />
  return <Outlet />
}
```


`app/web/src/pages/SetupPage.tsx`

```tsx
import { useState, type FormEvent } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuthState, useSetup } from '../api/auth'
import { AuthCard } from '../components/AuthCard'
import { ErrorMessage } from '../components/ErrorMessage'

// Mirrors the server policy (spec §8.2); the server is still the authority.
export const MIN_PASSWORD_LENGTH = 12

export function SetupPage() {
  const state = useAuthState()
  const setup = useSetup()
  const [token, setToken] = useState('')
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [localError, setLocalError] = useState<string | null>(null)

  if (state.isPending) {
    return (
      <AuthCard title="Set up Simplarr">
        <p>Loading…</p>
      </AuthCard>
    )
  }
  if (state.isError) {
    return (
      <AuthCard title="Set up Simplarr">
        <ErrorMessage error={state.error} />
      </AuthCard>
    )
  }
  if (!state.data.setupRequired) {
    return <Navigate to={state.data.authenticated ? '/' : '/login'} replace />
  }

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if ([...password].length < MIN_PASSWORD_LENGTH) {
      setLocalError(`Use at least ${MIN_PASSWORD_LENGTH} characters.`)
      return
    }
    if (password !== confirm) {
      setLocalError('The two passwords do not match.')
      return
    }
    setLocalError(null)
    setup.mutate({ token: token.trim(), password })
  }

  const error = localError ? new Error(localError) : setup.error

  return (
    <AuthCard title="Set up Simplarr">
      <p>
        Choose the admin password. The one-time setup token is in the container log:{' '}
        <code>docker logs simplarr</code>
      </p>
      <form onSubmit={onSubmit}>
        <label>
          Setup token
          <input
            type="text"
            value={token}
            onChange={(e) => setToken(e.target.value)}
            autoComplete="off"
            spellCheck={false}
            required
          />
        </label>
        <label>
          Admin password
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="new-password"
            required
          />
        </label>
        <label>
          Repeat password
          <input
            type="password"
            value={confirm}
            onChange={(e) => setConfirm(e.target.value)}
            autoComplete="new-password"
            required
          />
        </label>
        {error ? <ErrorMessage error={error} /> : null}
        <button type="submit" disabled={setup.isPending}>
          {setup.isPending ? 'Saving…' : 'Set password'}
        </button>
      </form>
    </AuthCard>
  )
}
```


`app/web/src/pages/LoginPage.tsx`

```tsx
import { useState, type FormEvent } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuthState, useLogin } from '../api/auth'
import { AuthCard } from '../components/AuthCard'
import { ErrorMessage } from '../components/ErrorMessage'

export function LoginPage() {
  const state = useAuthState()
  const login = useLogin()
  const [password, setPassword] = useState('')

  if (state.isPending) {
    return (
      <AuthCard title="Sign in">
        <p>Loading…</p>
      </AuthCard>
    )
  }
  if (state.isError) {
    return (
      <AuthCard title="Sign in">
        <ErrorMessage error={state.error} />
      </AuthCard>
    )
  }
  if (state.data.setupRequired) return <Navigate to="/setup" replace />
  if (state.data.authenticated) return <Navigate to="/" replace />

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    login.mutate({ password })
  }

  return (
    <AuthCard title="Sign in">
      <form onSubmit={onSubmit}>
        <label>
          Admin password
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="current-password"
            required
          />
        </label>
        {login.error ? <ErrorMessage error={login.error} /> : null}
        <button type="submit" disabled={login.isPending}>
          {login.isPending ? 'Signing in…' : 'Sign in'}
        </button>
      </form>
    </AuthCard>
  )
}
```


`app/web/src/pages/HomePage.tsx`

```tsx
import { useLogout } from '../api/auth'
import { ErrorMessage } from '../components/ErrorMessage'

// Placeholder: the overview, deployment and configuration pages arrive in the
// web UI plan. For now the shell proves the sign-in round trip.
export function HomePage() {
  const logout = useLogout()
  return (
    <main className="page">
      <h1>Simplarr</h1>
      <p>You are signed in. The control plane pages arrive in a later release.</p>
      {logout.error ? <ErrorMessage error={logout.error} /> : null}
      <button type="button" onClick={() => logout.mutate(undefined)} disabled={logout.isPending}>
        Sign out
      </button>
    </main>
  )
}
```


`app/web/src/pages/NotFoundPage.tsx`

```tsx
import { Link } from 'react-router-dom'
import { AuthCard } from '../components/AuthCard'

export function NotFoundPage() {
  return (
    <AuthCard title="Page not found">
      <p>
        <Link to="/">Back to the start</Link>
      </p>
    </AuthCard>
  )
}
```


`app/web/src/App.tsx`

```tsx
import { Route, Routes } from 'react-router-dom'
import { RequireAuth } from './components/RequireAuth'
import { HomePage } from './pages/HomePage'
import { LoginPage } from './pages/LoginPage'
import { NotFoundPage } from './pages/NotFoundPage'
import { SetupPage } from './pages/SetupPage'

// Client routes must not start with a prefix nginx sends to another service
// (/radarr, /sonarr, /prowlarr, /overseerr, /torrent, /tautulli, /plex,
// /health/): spec §3.3. Later pages live under /services/<name> for that reason.
export function App() {
  return (
    <Routes>
      <Route path="/setup" element={<SetupPage />} />
      <Route path="/login" element={<LoginPage />} />
      <Route element={<RequireAuth />}>
        <Route path="/" element={<HomePage />} />
      </Route>
      <Route path="*" element={<NotFoundPage />} />
    </Routes>
  )
}
```


`app/web/src/main.tsx`

```tsx
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { App } from './App'
import './styles.css'

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: false, refetchOnWindowFocus: true } },
})

const container = document.getElementById('root')
if (!container) throw new Error('index.html has no #root element')

createRoot(container).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </QueryClientProvider>
  </StrictMode>,
)
```


`app/web/src/styles.css`

```css
:root {
  color-scheme: light dark;
  --bg: #f5f6f8;
  --surface: #ffffff;
  --text: #1b1f27;
  --muted: #5b6472;
  --border: #d5d9e0;
  --accent: #5b4bdb;
  --accent-text: #ffffff;
  --danger-bg: #fdecec;
  --danger-text: #8a1c1c;
  font-family: system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif;
  line-height: 1.5;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #14161a;
    --surface: #1e2127;
    --text: #e8eaee;
    --muted: #9aa3b2;
    --border: #353a44;
    --accent: #8f83ff;
    --accent-text: #14161a;
    --danger-bg: #3a1c1c;
    --danger-text: #ffb4b4;
  }
}

body {
  margin: 0;
  min-height: 100vh;
  background: var(--bg);
  color: var(--text);
}

.auth-card,
.page {
  box-sizing: border-box;
  max-width: 26rem;
  margin: 10vh auto 0;
  padding: 2rem;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 0.75rem;
}

h1 {
  margin-top: 0;
  font-size: 1.5rem;
}

form {
  display: grid;
  gap: 1rem;
}

label {
  display: grid;
  gap: 0.25rem;
  font-weight: 600;
}

input {
  padding: 0.6rem 0.75rem;
  font: inherit;
  color: inherit;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: 0.5rem;
}

button {
  padding: 0.65rem 1rem;
  font: inherit;
  font-weight: 600;
  color: var(--accent-text);
  background: var(--accent);
  border: 0;
  border-radius: 0.5rem;
  cursor: pointer;
}

button:disabled {
  opacity: 0.6;
  cursor: progress;
}

code {
  padding: 0.1rem 0.3rem;
  background: var(--bg);
  border-radius: 0.25rem;
}

.error {
  padding: 0.6rem 0.75rem;
  color: var(--danger-text);
  background: var(--danger-bg);
  border-radius: 0.5rem;
}

.error p {
  margin: 0;
}

.error .fix {
  margin-top: 0.25rem;
  color: var(--muted);
}
```


- [ ] **Step 4: Run tests, lint, typecheck and the production build**

```bash
cd app/web
npm test
npm run lint
npm run typecheck
npm run build
ls ../internal/webui/dist ../internal/webui/dist/assets
```

Expected: all test files pass; lint and typecheck print nothing; the build prints `✓ built` and lists `index.html` plus one `.js` and one `.css` under `assets/` in `app/internal/webui/dist` (git-ignored).

- [ ] **Step 5: Prove the embedded UI works end to end**

```bash
cd app
go vet ./...
go build -tags webdist -o /tmp/simplarr-plan2-ui ./cmd/simplarr
mkdir -p /tmp/simplarr-plan2-ui-data
export SIMPLARR_LISTEN=127.0.0.1:18082 SIMPLARR_DATA_DIR=/tmp/simplarr-plan2-ui-data SIMPLARR_CONFIG_DIR=/tmp/simplarr-plan2-ui-data
/tmp/simplarr-plan2-ui serve > /tmp/simplarr-plan2-ui.log 2>&1 &
SERVER=$!
for _ in $(seq 1 30); do curl -fsS http://127.0.0.1:18082/healthz >/dev/null 2>&1 && break; sleep 0.2; done
B=http://127.0.0.1:18082
echo "GET /        -> $(curl -s -o /dev/null -w '%{http_code} %{content_type}' $B/)"
echo "GET /login   -> $(curl -s -o /dev/null -w '%{http_code}' $B/login)   (client route served as the shell)"
ASSET=$(curl -s $B/ | grep -o '/assets/[^"]*\.js' | head -1)
echo "GET $ASSET -> $(curl -s -o /dev/null -w '%{http_code} %{content_type}' $B$ASSET)"
echo "asset cache:  $(curl -sI $B$ASSET | grep -i '^cache-control')"
echo "missing .js   -> $(curl -s -o /dev/null -w '%{http_code}' $B/assets/missing.js)"
kill -TERM "$SERVER"; wait "$SERVER"; echo "server exit: $?"
unset SIMPLARR_LISTEN SIMPLARR_DATA_DIR SIMPLARR_CONFIG_DIR
```

Expected: `/` → `200 text/html; charset=utf-8`; `/login` → `200`; the asset → `200 text/javascript; charset=utf-8` with `Cache-Control: public, max-age=31536000, immutable`; the missing asset → `404`; `server exit: 0`. Also confirm `go vet ./...` ignores `web/node_modules` (it prints nothing).

- [ ] **Step 6: Leave the work uncommitted.**

---

## Gate B: security review of the SPA auth client and pages, then commit Tasks 9–10 (controller)

- [ ] **B1. Stage:**

```bash
cd ~/projects/simplarr/.worktrees/app-skeleton-auth
git add -A .gitignore app
git status --short | head -40
```

- [ ] **B2. Run the `security-review` skill** on the pending changes, briefed on: the CSRF header is read from a cookie and only sent for non-GET; credentials are `same-origin`; passwords live only in component state and are never logged or put in a URL or storage; no `dangerouslySetInnerHTML`; server messages are rendered as text; the route guards cannot be bypassed to reach protected content (the server is still the authority, and the placeholder home page holds nothing sensitive); `package-lock.json` pins exact versions; the CSP-compatible output (no inline script or style).

- [ ] **B3. Fix High and Medium findings test-first; note Low ones for the PR.** Re-stage.

- [ ] **B4. Commit:**

```bash
git commit -m "feat: add web toolchain and API client with CSRF echo" \
  -- .gitignore app/web/go.mod app/web/package.json app/web/package-lock.json app/web/tsconfig.json \
     app/web/vite.config.ts app/web/eslint.config.js app/web/index.html \
     app/web/src/api/client.ts app/web/src/api/client.test.ts app/web/src/test/server.ts app/web/src/test/setup.ts
git commit -m "feat: add setup and login pages with route guards" -- app/web
git status --short
git log --oneline origin/main..HEAD | wc -l
```

Expected: `git status --short` prints nothing; `10` commits.

---

### Task 11: Distroless non-root Dockerfile

**Files:**
- Create: `app/Dockerfile`, `app/.dockerignore`

**Interfaces:**
- Consumes: the whole app: `go.mod`/`go.sum`, `web/package.json` + `package-lock.json`, the `webdist` tag and `-X main.version` variable (Tasks 8, 10).
- Produces: an image whose entrypoint is `/simplarr` with default command `serve`; user `65532:65532`; `EXPOSE 8080`; `HEALTHCHECK … /simplarr healthcheck`; an empty `/data` owned by `65532:65532` for plain `docker run`; build context is the `app/` directory; builds for `linux/amd64` and `linux/arm64` without emulation.

- [ ] **Step 1: Create the Dockerfile and ignore file**

`app/Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1

# Build context is the app/ directory.
#
#   docker build -t simplarr app/
#   docker buildx build --platform linux/arm64 -t simplarr app/    (Raspberry Pi)
#
# Build stages run on the build machine's own architecture and cross-compile,
# so an arm64 image needs no emulation.

# --- 1. Web UI -------------------------------------------------------------
FROM --platform=$BUILDPLATFORM node:24-alpine AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/ ./
# vite.config.ts writes to ../internal/webui/dist, which is /src/internal/webui/dist here.
RUN npm run build

# --- 2. Go binary with the UI embedded -------------------------------------
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
COPY --from=web /src/internal/webui/dist ./internal/webui/dist
ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -tags webdist -trimpath -ldflags="-s -w -X main.version=${VERSION}" \
    -o /out/simplarr ./cmd/simplarr \
 && mkdir -p /out/data

# --- 3. Runtime: distroless, no shell, non-root ----------------------------
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/simplarr /simplarr
# Writable default for `docker run` without a volume. Compose bind-mounts over it.
COPY --from=build --chown=65532:65532 /out/data /data
USER 65532:65532
EXPOSE 8080
# The image has no curl, so the binary probes itself.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD ["/simplarr", "healthcheck"]
ENTRYPOINT ["/simplarr"]
CMD ["serve"]
```


`app/.dockerignore`

```text
# Keep the build context small and the build reproducible.
web/node_modules
internal/webui/dist
coverage.out
Dockerfile
.dockerignore
**/*_test.go
```


- [ ] **Step 2: Build, run and inspect (one script)**

The first line works around the missing Docker Desktop credential helper on this machine (see "Decisions" 12); it points Docker at an empty config for this script only. The script creates one container `simplarr-plan2-check` and image tags `simplarr-plan2-check` and `simplarr-plan2-check-arm64`, and removes exactly those at the end. **Name these three in your report before running it.**

```bash
export DOCKER_CONFIG="$(mktemp -d)"
cd ~/projects/simplarr/.worktrees/app-skeleton-auth
docker build --build-arg VERSION=plan2-check -t simplarr-plan2-check app/
echo "user:       $(docker inspect --format '{{.Config.User}}' simplarr-plan2-check)"
echo "entrypoint: $(docker inspect --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' simplarr-plan2-check)"
echo "size:       $(docker image inspect simplarr-plan2-check --format '{{.Size}}') bytes"

docker run -d --name simplarr-plan2-check -p 127.0.0.1:18083:8080 simplarr-plan2-check >/dev/null
for _ in $(seq 1 40); do
  status=$(docker inspect --format '{{.State.Health.Status}}' simplarr-plan2-check)
  [ "$status" = healthy ] && break
  sleep 1
done
echo "health:     $status"
echo "version:    $(docker exec simplarr-plan2-check /simplarr version)"
echo "GET /       -> $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18083/)"
echo "state:      $(curl -s http://127.0.0.1:18083/api/v1/auth/state)"
echo "token logs: $(docker logs simplarr-plan2-check 2>&1 | grep -c 'First-run setup token')"
echo "--- bad config must fail fast:"
docker run --rm -e SIMPLARR_LISTEN=junk -e RADARR_PORT=0 simplarr-plan2-check serve; echo "exit $?"
echo "--- arm64 cross-build (no emulation):"
docker buildx build --platform linux/arm64 --build-arg VERSION=plan2-check -t simplarr-plan2-check-arm64 app/ 2>&1 | tail -2

docker rm -f simplarr-plan2-check
docker rmi simplarr-plan2-check simplarr-plan2-check-arm64
```

Expected: `user: 65532:65532`; `entrypoint: ["/simplarr"] ["serve"]`; size under about 15 MB (the spike measured 9.5 MB); `health: healthy`; `version: plan2-check`; `GET / -> 200`; `state: {"setupRequired":true,"authenticated":false}`; `token logs: 1`; the bad-config run prints both `SIMPLARR_LISTEN:` and `RADARR_PORT:` lines and `exit 1`; the arm64 build ends with `naming to … done`; the last two commands print the removed names.

- [ ] **Step 3: Commit** (the Dockerfile is not auth, input or API code):

```bash
cd ~/projects/simplarr/.worktrees/app-skeleton-auth
git add app/Dockerfile app/.dockerignore
git commit -m "feat: add distroless nonroot Dockerfile for the app"
```

---

### Task 12: CI jobs, README, pull request

**Files:**
- Modify: `.github/workflows/ci.yml` (insert three jobs before `fast-gate`; change nothing else)
- Create: `app/README.md`

**Interfaces:**
- Consumes: the commands every earlier task verified.
- Produces: CI job names (these are the status-check names): `Go (vet, lint, test)`, `Web (lint, typecheck, test, build)`, `App image (build + smoke test)`. `fast-gate` keeps `needs: [lint, eslint-homepage]`.

- [ ] **Step 1: Insert the jobs**

Open `.github/workflows/ci.yml`. Insert the three jobs below **immediately before the line `  fast-gate:`** (after the `eslint-homepage` job). Do not edit any existing line. The action versions match arrkit's CI, which is known to run on Node 24.

`.github/workflows/ci.yml (insert before "  fast-gate:")`

```yaml
  go:
    name: Go (vet, lint, test)
    runs-on: ubuntu-latest
    permissions:
      contents: read
    defaults:
      run:
        working-directory: app

    steps:
      - name: Checkout repository
        uses: actions/checkout@v7.0.1

      - name: Set up Go
        uses: actions/setup-go@v7.0.0
        with:
          go-version-file: app/go.mod
          cache-dependency-path: app/go.sum

      - name: go.mod is tidy
        run: go mod tidy -diff

      - name: go vet
        run: go vet ./...

      - name: Tests (race detector)
        run: go test ./... -race

      - name: Coverage gate (internal/... must stay at or above 80%)
        run: |
          go test ./internal/... -race -coverprofile=coverage.out
          total=$(go tool cover -func=coverage.out | awk '/^total:/ { sub("%", "", $3); print $3 }')
          echo "internal/... coverage: ${total}%"
          awk -v t="$total" 'BEGIN { exit (t + 0 >= 80) ? 0 : 1 }' \
            || { echo "::error::coverage ${total}% is below the 80% gate"; exit 1; }

      - name: golangci-lint
        uses: golangci/golangci-lint-action@v9.3.0
        with:
          version: v2.15.0
          working-directory: app

  web:
    name: Web (lint, typecheck, test, build)
    runs-on: ubuntu-latest
    permissions:
      contents: read
    defaults:
      run:
        working-directory: app/web

    steps:
      - name: Checkout repository
        uses: actions/checkout@v7.0.1

      - name: Set up Node.js
        uses: actions/setup-node@v7.1.0
        with:
          node-version: "24"
          cache: npm
          cache-dependency-path: app/web/package-lock.json

      - name: Install dependencies
        run: npm ci

      - name: ESLint
        run: npm run lint

      - name: Type check
        run: npm run typecheck

      - name: Unit tests
        run: npm test

      - name: Production build
        run: npm run build

  app-image:
    name: App image (build + smoke test)
    runs-on: ubuntu-latest
    permissions:
      contents: read

    steps:
      - name: Checkout repository
        uses: actions/checkout@v7.0.1

      - name: Build the image
        run: docker build --build-arg VERSION=ci -t simplarr-app:ci app

      - name: Image runs as the non-root user
        run: |
          user=$(docker inspect --format '{{.Config.User}}' simplarr-app:ci)
          echo "image user: ${user}"
          test "${user}" = "65532:65532"

      - name: Smoke test the running container
        run: |
          docker run -d --name simplarr-ci -p 127.0.0.1:18080:8080 simplarr-app:ci
          trap 'docker logs simplarr-ci; docker rm -f simplarr-ci' EXIT
          for _ in $(seq 1 30); do
            status=$(docker inspect --format '{{.State.Health.Status}}' simplarr-ci)
            [ "${status}" = "healthy" ] && break
            sleep 1
          done
          test "${status}" = "healthy"
          curl -fsS http://127.0.0.1:18080/healthz
          curl -fsS http://127.0.0.1:18080/login | grep -q 'id="root"'
          curl -fsS http://127.0.0.1:18080/api/v1/auth/state | grep -q '"setupRequired":true'
          docker logs simplarr-ci 2>&1 | grep -q 'First-run setup token'

      - name: Cross-build for arm64 (Raspberry Pi), no emulation needed
        run: docker buildx build --platform linux/arm64 --build-arg VERSION=ci app

```


- [ ] **Step 2: Lint the workflow**

```bash
cd ~/projects/simplarr/.worktrees/app-skeleton-auth
export GOBIN="$(mktemp -d)"          # throwaway install directory for the linter
go install github.com/rhysd/actionlint/cmd/actionlint@latest
"$GOBIN/actionlint" .github/workflows/ci.yml
git diff --stat .github/workflows/ci.yml
git diff .github/workflows/ci.yml | grep -c '^-[^-]'
```

Expected: `actionlint` prints nothing; the diff only adds lines (the last command prints `0`).

- [ ] **Step 3: Replay each job's commands locally**

```bash
cd ~/projects/simplarr/.worktrees/app-skeleton-auth/app
go mod tidy -diff && go vet ./... && go test ./... -race
go test ./internal/... -race -coverprofile=coverage.out >/dev/null && go tool cover -func=coverage.out | tail -1
golangci-lint run ./...
cd web && npm ci && npm run lint && npm run typecheck && npm test && npm run build
```

Expected: everything passes; coverage at least 80.0%. (`npm ci` removes and reinstalls `app/web/node_modules`, which is git-ignored. The `app-image` job's commands are the Task 11 script.)

- [ ] **Step 4: Write the README**

`app/README.md`

````markdown
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
````


- [ ] **Step 5: Commit**

```bash
cd ~/projects/simplarr/.worktrees/app-skeleton-auth
git add .github/workflows/ci.yml
git commit -m "ci: add go, web and app-image jobs"
git add app/README.md
git commit -m "docs: add app README"
```

- [ ] **Step 6: Update the plan index** (`docs/superpowers/plans/2026-11-14-control-plane-ui-00-index.md`, now on `main` via #34): row 2 status becomes `done (PR #<n>)` once the PR number exists, so do this after Step 7, and row 3 gains `Also PUT /api/v1/auth/password (session + CSRF; deferred from Plan 2) and invalidating the admin's other sessions on change.` Commit as `docs: plan index marks plan 2 done`.

- [ ] **Step 7: Push and open the PR** (no attribution line in the body; no deletions to list in this PR):

```bash
cd ~/projects/simplarr/.worktrees/app-skeleton-auth
git push -u origin HEAD
cat > /tmp/simplarr-plan2-pr.md <<'EOF'
## Summary

Plan 2 of the control-plane UI initiative: the `app/` Go module and an empty React shell. Spec §3.1, §3.3, §4, §8.2, §10.

- Environment config with fail-fast validation that trims stray `\r`
- Atomic file store with permission enforcement
- `/healthz`
- Setup token, then argon2id admin password, then session login
- CSRF double-submit bound to the session; login and setup rate limiting (5 attempts per 15 minutes per IP, charged atomically)
- slog JSON logging with secret redaction
- Distroless non-root image (`HEALTHCHECK` is `simplarr healthcheck`); arm64 builds without emulation
- Vite/React/TypeScript SPA shell with setup and login pages
- CI jobs `Go`, `Web`, `App image`

No arrkit dependency. Compose and nginx are untouched (Plan 8).

## Verification

- `go vet`, `golangci-lint`, `go test -race`: `internal/...` coverage 93%
- Web: ESLint, `tsc`, Vitest, production build
- Real binary and container smoke runs: setup, login, CSRF refusal, logout, healthcheck, graceful shutdown
- Security review run at two gates before the auth, input and API code was committed; findings and their fixes are in the commit history

## Notes for the reviewer

- The new CI jobs are deliberately not wired into `fast-gate`'s `needs:`. Whether to make them required checks is a ruleset change and is raised separately.
- Deployment assumption: only nginx can reach the app, and it sets `X-Real-IP` and `X-Forwarded-Proto`. Plan 8 must keep that.
- Deferred: admin password change (`PUT /api/v1/auth/password`) moves to Plan 3.
EOF
gh pr create --base main --title "feat: app skeleton and auth for the control-plane UI (Plan 2)" --body-file /tmp/simplarr-plan2-pr.md
gh pr checks --watch
```

Expected: the PR opens against `main`; `Lint (ShellCheck + PSScriptAnalyzer)`, `Fast Gate (target < 15 min)`, `Go (vet, lint, test)`, `Web (lint, typecheck, test, build)` and `App image (build + smoke test)` all pass. Add the security-review findings summary (Gates A and B) to the body with `gh pr edit --body-file`.

---

## Final gates (controller)

- [ ] **F1. Whole-branch review by `opus`.** Dispatch one reviewer (model `opus`) over `git diff origin/main...HEAD` with this brief: the spec sections in this plan's header; the Global Constraints; the security areas listed at Gate A and Gate B; whether the tests would catch the regressions they claim to (especially the rate-limit burst test, the CSRF-binding test and the setup race test); CI correctness (`go-version-file`, the coverage gate arithmetic, the smoke script under `bash -e`); and anything in the diff that is personal data or a secret. Findings come back ranked; the controller decides what to fix.
- [ ] **F2. Fix findings test-first**, re-run the full verification from Task 12 Step 3 and the Task 11 script, push.
- [ ] **F3. Verify before claiming done** (`superpowers:verification-before-completion`): CI green on the PR head, local commands re-run, `git status` clean.
- [ ] **F4. Raise a hub item** (`mcp__fabric__raise_item`, one decision per item, with options): **merge the Plan 2 PR** (options: merge now with a merge commit; hold for the user's own review; fold in the review findings first). Merge only after the answer, without `--admin`.
- [ ] **F5. Raise a hub item before touching any ruleset:** **make the new CI jobs required checks on `main`?** State the exact check names (`Go (vet, lint, test)`, `Web (lint, typecheck, test, build)`, `App image (build + smoke test)`), that they currently run on every PR (no path filters, so requiring them cannot leave a docs-only PR pending), and the options: require `Go` and `Web` only (recommended); require all three; keep them advisory. Change the "Protect main" ruleset only after the answer.
- [ ] **F6. After the merge:** update memory (`simplarr-control-plane-ui`: Plan 2 done, PR number, what Plan 3 inherits), and remove the worktree only after naming it to the user (`git worktree remove .worktrees/app-skeleton-auth`; this deletes a directory, so say so first). Plan 3 starts from `main`.

---

## Self-review

**Spec coverage** (each requirement and the task that satisfies it):

| Spec | Requirement | Task |
|---|---|---|
| §3.1 | `app/` module `github.com/parsoFish/simplarr/app`; `cmd/simplarr`; packages `config`, `auth`, `api`, `store`; `web/`; Dockerfile | 1, 2, 3–5, 6–7, 8, 9–10, 11 (`logging` and `webui` are additions, see Decisions 7 and the file structure) |
| §3.1 | Files under 400 lines | all; the largest is `auth_handlers_test.go` at about 340 lines |
| §3.3 | `simplarr healthcheck` calls `/healthz`; distroless image has no curl; runs non-root; no published port (compose, deferred) | 8, 11; compose is Plan 8 |
| §4 | every env var, defaults, split-mode `NAS_IP` defaults, `\r` trimming, port range, host rules, fail fast naming the variable | 1 |
| §4 | `NAS_IP_DASHED` + `PLEX_DIRECT_HASH` → plex.direct host | 1 (`PlexDirectHost`) |
| §8.1 | `GET /healthz`, `GET /auth/state`, `POST /auth/setup`, `POST /auth/login`, `POST /auth/logout`; one error shape | 6, 7 |
| §8.1 | `PUT /auth/password` | deferred to Plan 3 (Scope table) |
| §8.2 | setup token: 128-bit, logged once at WARN, memory only, invalid after setup | 4 (`NewSetupToken`, `AnnounceSetupToken`), 5, 8 |
| §8.2 | argon2id 64 MiB / t3 / p2 / 16 B salt / 32 B key, parameters stored with the hash, ≥ 12 characters | 3, 5 |
| §8.2 | sessions: 256-bit ID, 7-day TTL, memory; cookie `HttpOnly`, `SameSite=Strict`, `Secure` via `X-Forwarded-Proto` | 4, 7, 8 |
| §8.2 | CSRF double-submit on every non-GET except setup and login | 4 (`TokensMatch`), 7 (`protected`) |
| §8.2 | 5 failures per 15 minutes per IP → 429, IP from `X-Real-IP` | 4 (`Limiter`), 7, 8 |
| §10 | slog JSON at INFO; redaction of `key\|token\|password\|secret`; no secret in responses, logs or errors | 2, 7 (`TestLogsNeverContainSecrets`), 8 |
| §10 | errors wrapped with context; none swallowed | all (explicit error returns; the two documented tolerated cases are `syncDir` EINVAL/ENOTSUP and a failed response write) |
| §5.3 | file mode wider than 0600 → warn + chmod; refuse to start if chmod fails | 2 (`EnforceMode`), 5 (applied to `admin.json`) |
| §9.3 | CI `go` (vet, golangci-lint, test) and `web` (eslint, tsc, vitest) jobs | 12 |
| §9.2 | unit layer: `-race` and the 80% gate on `internal/...` | 8, 12 |
| Index row 2 | env config, atomic store, `/healthz`, login flow, CSRF, rate limit, slog redaction, Dockerfile, CI jobs, SPA shell with login/setup | 1–12 |
| Rules | security review before committing; hub items for PR #34, the merge and the ruleset; no `--admin`; `--no-track`; no attribution | Gates A/B, P1–P2, F4–F5 |

**Placeholder scan:** no step says "TBD", "add appropriate error handling" or "similar to Task N"; every code step embeds the full file.

**Type and name consistency:** `Limiter.Allow` / `Reset` (Task 4) are the only limiter methods used in Task 7; `Session{ID, CSRF, Expires}` (Task 4) is what `protected` reads; `ServiceConfig` (Task 5) is what `buildHandler` fills (Task 8); `api.Deps` (Task 7) is what `buildHandler` passes; `webui.Dist` (Task 6) is what `cmdServe` calls; the web `AuthState` shape (Task 10) matches `stateResponse` (Task 7); cookie and header names are identical on both sides (`simplarr_csrf`, `X-CSRF-Token`).
