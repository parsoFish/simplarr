# arrkit extraction — implementation plan (Plan 1 of 8)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish `github.com/parsoFish/arrkit@v0.1.0` containing healarr's seven service clients plus their shared `httpx` package, with their git history, and switch healarr to import it with no behaviour change.

**Architecture:** `git subtree split` of healarr's `internal/clients` gives a history-preserving branch with the client packages at the root. `docker/` and `hostfs/` are host-specific, so they are dropped from arrkit and stay in healarr. arrkit becomes a standalone stdlib-only Go module. healarr then deletes its copies and imports arrkit; its existing tests are the regression gate.

**Tech Stack:** Go 1.25, git subtree, `gh` CLI, GitHub Actions, golangci-lint v2.

**Spec:** [`docs/superpowers/specs/2026-11-14-control-plane-ui-design.md`](../specs/2026-11-14-control-plane-ui-design.md) §2 D2, §3.2, §12 step 1. Index: [`2026-11-14-control-plane-ui-00-index.md`](2026-11-14-control-plane-ui-00-index.md).

## Global Constraints

- Module path `github.com/parsoFish/arrkit`. Go directive `go 1.25.0`, the same as healarr.
- Public repo, MIT licence, the same copyright line as healarr (`Copyright (c) 2026 parsoFish`).
- arrkit has **no third-party dependencies**. The clients are stdlib-only today; keep it that way.
- Packages moved: `httpx`, `radarr`, `sonarr`, `prowlarr`, `overseerr`, `qbittorrent`, `plex`, `tautulli`. Not moved: `docker`, `hostfs`.
- No API changes in this plan. Exported names and signatures are byte-identical to healarr's `internal/clients/*` at `origin/main`.
- No personal data in fixtures. The 2026-11-14 scan of current fixtures **and their history** found only `example.com` emails, `10.0.0.2` and generic `/volume1/*` paths; Task 2 re-runs the scan as a gate.
- Conventional commits, no attribution trailers. `main` in either repo moves only by a merged PR with CI green. Feature branches are created with `--no-track`.
- **Pure refactor exception to TDD:** this plan adds no behaviour, so there is no red step. The existing test suites are the gate: they must pass before the move (baseline) and after it, with the same package count.

## File structure

**arrkit (new repo):**

```
go.mod                      module github.com/parsoFish/arrkit, go 1.25.0, no requires
LICENSE                     MIT (copied from healarr)
README.md                   purpose, packages, usage, fixture rules, stability
.gitignore                  dist/, coverage.out
.golangci.yml               copied from healarr (v2 config)
.github/workflows/ci.yml    vet, test -race -cover, mod tidy diff, golangci-lint
httpx/ radarr/ sonarr/ prowlarr/ overseerr/ qbittorrent/ plex/ tautulli/
                            moved unchanged except import paths + 9 comment rewordings
```

**healarr (changed):**

```
go.mod, go.sum                     + require github.com/parsoFish/arrkit v0.1.0
internal/clients/{httpx,radarr,sonarr,prowlarr,overseerr,qbittorrent,plex,tautulli}/   DELETED
internal/clients/docker/, internal/clients/hostfs/                                     kept; imports rewritten
every other *.go importing the moved packages                                         imports rewritten
docs/architecture.md               package layout + Phase-1 paragraph point at arrkit
docs/tools.md                      three references to internal/clients/* point at arrkit
docs/decisions.md                  + ADR-020 "Service clients extracted to arrkit"
```

Shell variables used throughout. Set them once per session; they are not committed anywhere:

```bash
HEALARR="<path to your healarr checkout>"      # e.g. the healarr folder next to simplarr
ARRKIT="$(dirname "$HEALARR")/arrkit"          # new sibling checkout
```

---

### Task 1: History-preserving arrkit branch

**Files:**
- Create: the `$ARRKIT` checkout (a fresh clone of healarr, rewritten by subtree split)

**Interfaces:**
- Consumes: healarr `origin/main`.
- Produces: local branch `import/healarr-clients` in `$ARRKIT`, with healarr's `internal/clients/*` at the repo root and all commits that touched `internal/clients`.

- [ ] **Step 1: Baseline healarr test run (the regression reference)**

```bash
cd "$(mktemp -d)" && git clone -q https://github.com/parsoFish/healarr.git baseline && cd baseline
go test ./... -race -cover 2>&1 | tee /tmp/healarr-baseline.txt | tail -5
grep -c '^ok' /tmp/healarr-baseline.txt
```

Expected: every line is `ok` or `?` (no test files). Record the `ok` count. Task 5 must match it minus the 8 deleted client packages.

The baseline is cloned from GitHub so it is exactly `origin/main`, whatever branch the local checkout is on.

- [ ] **Step 2: Fresh clone and subtree split**

```bash
git clone -q https://github.com/parsoFish/healarr.git "$ARRKIT"
cd "$ARRKIT"
git subtree split --prefix=internal/clients -b import/healarr-clients
git checkout -q import/healarr-clients
git branch -D main
git remote remove origin
```

- [ ] **Step 3: Verify the split**

```bash
ls
git log --oneline | wc -l
git -C "$HEALARR" log --oneline origin/main -- internal/clients | wc -l
```

Expected:
- `ls` prints exactly `docker  hostfs  httpx  overseerr  plex  prowlarr  qbittorrent  radarr  sonarr  tautulli`.
- The two commit counts are equal (21 at the time of writing).

No commit in this task: the branch *is* the deliverable.

---

### Task 2: Standalone module

**Files:**
- Delete (in `$ARRKIT`): `docker/`, `hostfs/`
- Create: `go.mod`
- Modify: every `*.go` importing `github.com/parsoFish/healarr/internal/clients/…`
- Modify (comments only):
  - `overseerr/types.go:28`, `tautulli/types.go:25`, `prowlarr/types.go:42`, `plex/types.go:35`, `radarr/types.go:58`, `sonarr/types.go:60`, `qbittorrent/types.go:56`: "Client is the behaviour the rest of healarr depends on."
  - `qbittorrent/types.go:43`: "Preferences is the subset … healarr cares about."
  - `prowlarr/client.go:76`: "… which healarr never inspects …"

**Interfaces:**
- Consumes: branch `import/healarr-clients` from Task 1.
- Produces: importable packages `github.com/parsoFish/arrkit/{httpx,radarr,sonarr,prowlarr,overseerr,qbittorrent,plex,tautulli}` with unchanged APIs. The constructors later plans rely on:
  - `httpx.New(baseURL string, opts ...httpx.Option) (*httpx.Client, error)`
  - `radarr.New(baseURL, apiKey string, opts ...httpx.Option) (*radarr.HTTPClient, error)`
  - `sonarr.New(baseURL, apiKey string, opts ...httpx.Option) (*sonarr.HTTPClient, error)`
  - `prowlarr.New(baseURL, apiKey string, opts ...httpx.Option) (*prowlarr.HTTPClient, error)`
  - `overseerr.New(baseURL, apiKey string, opts ...httpx.Option) (*overseerr.HTTPClient, error)`
  - `qbittorrent.New(baseURL, user, pass string, opts ...httpx.Option) (*qbittorrent.HTTPClient, error)`
  - `plex.New(baseURL, token string, opts ...httpx.Option) (*plex.HTTPClient, error)`
  - `tautulli.New(baseURL, apiKey string, opts ...httpx.Option) (*tautulli.HTTPClient, error)`
  - Each package also exports a `Client` interface and an in-memory `Fake` that implements it.

- [ ] **Step 1: Confirm it does not build yet**

Run: `cd "$ARRKIT" && go test ./... 2>&1 | head -3`
Expected: FAIL with `go: cannot find main module` (or `go.mod file not found`).

- [ ] **Step 2: Drop the host-specific packages**

These two directories are deleted from arrkit only. healarr keeps its copies.

```bash
git rm -r -q docker hostfs
```

- [ ] **Step 3: Create the module**

```bash
go mod init github.com/parsoFish/arrkit
go mod edit -go=1.25.0
```

- [ ] **Step 4: Rewrite import paths**

```bash
grep -rl 'github.com/parsoFish/healarr/internal/clients/' --include='*.go' . \
  | xargs sed -i 's#github.com/parsoFish/healarr/internal/clients/#github.com/parsoFish/arrkit/#g'
grep -rn 'parsoFish/healarr' --include='*.go' . ; echo "exit=$?"
```

Expected: no matches; `exit=1`.

- [ ] **Step 5: Reword comments that describe healarr as the caller**

```bash
sed -i 's#Client is the behaviour the rest of healarr depends on\.#Client is the behaviour callers depend on.#' \
  overseerr/types.go tautulli/types.go prowlarr/types.go plex/types.go radarr/types.go sonarr/types.go qbittorrent/types.go
sed -i 's#/api/v2/app/preferences healarr cares about#/api/v2/app/preferences arrkit exposes#' qbittorrent/types.go
sed -i 's#which healarr never inspects#which arrkit never inspects#' prowlarr/client.go
grep -rn -i 'healarr' --include='*.go' .
```

Expected: the final grep prints nothing. If any line still mentions healarr, reword it by hand so that it describes arrkit or "callers", then re-run the grep.

- [ ] **Step 6: Format, vet, test**

```bash
gofmt -l .
go vet ./...
go test ./... -race -cover
```

Expected:
- `gofmt -l` prints nothing.
- `go vet` prints nothing.
- `go test` prints 8 `ok` lines: `httpx`, `overseerr`, `plex`, `prowlarr`, `qbittorrent`, `radarr`, `sonarr`, `tautulli`.

- [ ] **Step 7: Personal-data gate over files and history**

```bash
PATTERN='\b(192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]+\.[0-9]+\b|[a-f0-9]{32}\.plex\.direct|/home/[a-z]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}'
grep -rnoE "$PATTERN" . --exclude-dir=.git | grep -v '@example\.com' ; echo "files exit=$?"
HITS=$(git log -p | grep -E '^\+' | grep -oE "$PATTERN" | grep -v '@example\.com' | sort -u); [ -z "$HITS" ] && echo "history clean" || printf '%s\nhistory HITS\n' "$HITS"
```

Expected: the files check prints `files exit=1` and the history check prints `history clean`. If anything is found, **stop** and report it before publishing. Scrubbing history is a separate decision for the user.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: standalone arrkit module from healarr internal/clients" \
  -m "Moves httpx and the radarr, sonarr, prowlarr, overseerr, qbittorrent, plex and tautulli clients out of healarr with their history. docker and hostfs are host-specific and stay in healarr. Import paths are rewritten and comments no longer name healarr as the caller; no API changes."
```

---

### Task 3: Repo scaffolding (licence, lint, CI, README)

**Files:**
- Create: `$ARRKIT/LICENSE` (copied), `$ARRKIT/.golangci.yml` (copied), `$ARRKIT/.gitignore`, `$ARRKIT/.github/workflows/ci.yml`, `$ARRKIT/README.md`

**Interfaces:**
- Consumes: the module from Task 2.
- Produces: the CI job named `test`, which later plans' arrkit PRs must pass.

- [ ] **Step 1: Copy licence and lint config**

```bash
cp "$HEALARR/LICENSE" "$ARRKIT/LICENSE"
cp "$HEALARR/.golangci.yml" "$ARRKIT/.golangci.yml"
```

- [ ] **Step 2: Lint locally**

Run: `cd "$ARRKIT" && golangci-lint run`
Expected: `0 issues.` This is the same config healarr passes with, run on the same code.

- [ ] **Step 3: Write `.gitignore`**

```gitignore
/dist/
coverage.out
```

- [ ] **Step 4: Write `.github/workflows/ci.yml`**

```yaml
name: ci
on:
  push: { branches: [main] }
  pull_request:
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: "1.25" }
      - name: go.mod is tidy
        run: go mod tidy -diff
      - run: go vet ./...
      - run: go test ./... -race -cover
      - uses: golangci/golangci-lint-action@v8
        with: { version: latest }
```

- [ ] **Step 5: Verify the tidy check passes locally**

Run: `go mod tidy -diff; echo "exit=$?"`
Expected: no diff, `exit=0`.

- [ ] **Step 6: Write `README.md`**

````markdown
# arrkit

Go clients for the services in a Plex + *arr media stack: Radarr, Sonarr, Prowlarr, Overseerr, qBittorrent, Plex and Tautulli.

Each package gives you:

- a `Client` interface with the package's own request and response types,
- an `HTTPClient` that talks to the real service over the shared `httpx` client,
- an in-memory `Fake` that implements `Client`, for callers' unit tests,
- golden JSON fixtures in `testdata/`, captured from live services and scrubbed.

arrkit has no third-party dependencies.

It was extracted from [healarr](https://github.com/parsoFish/healarr), and is used by healarr and [simplarr](https://github.com/parsoFish/simplarr).

## Packages

| Package | Service | Auth |
|---|---|---|
| `httpx` | shared JSON/form HTTP client: secret-redacting errors, timeouts, TLS server name | — |
| `radarr`, `sonarr` | Radarr v3 API, Sonarr v3 API | `X-Api-Key` |
| `prowlarr` | Prowlarr v1 API | `X-Api-Key` |
| `overseerr` | Overseerr v1 API | `X-Api-Key` |
| `qbittorrent` | qBittorrent WebUI v2 API | username + password, cookie session |
| `plex` | Plex Media Server | `X-Plex-Token` |
| `tautulli` | Tautulli v2 API | `apikey` query parameter, redacted in errors |

## Usage

```go
c, err := radarr.New("http://radarr:7878", apiKey)
if err != nil {
    return err
}
items, err := c.Health(ctx)
```

## Tests

```bash
go test ./... -race -cover
golangci-lint run
```

Fixture rule: anything added under `testdata/` must be scrubbed before you commit it. That means no real hostnames, addresses, emails, API keys, tokens or `plex.direct` hashes. Use `example.com`, `10.0.0.x` or `192.0.2.x` and obviously fake IDs instead.

## Stability

arrkit is pre-1.0. Breaking changes can land in minor versions, and each one is called out in the release notes.
````

- [ ] **Step 7: Commit**

```bash
git add LICENSE .golangci.yml .gitignore .github/workflows/ci.yml README.md
git commit -m "chore: licence, lint config, CI and README"
```

---

### Task 4: Publish arrkit and tag v0.1.0

**Files:**
- Create: GitHub repo `parsoFish/arrkit` (public; approved by the user on 2026-11-14)

**Interfaces:**
- Consumes: branch `import/healarr-clients` from Task 3.
- Produces: `github.com/parsoFish/arrkit@v0.1.0`, resolvable through `proxy.golang.org`.

- [ ] **Step 1: Create the repo with a server-side initial commit**

`main` then exists without a local push to it; the deny list forbids pushing to `main`.

```bash
gh repo create parsoFish/arrkit --public --add-readme \
  --description "Go clients for the Plex + *arr media stack: Radarr, Sonarr, Prowlarr, Overseerr, qBittorrent, Plex, Tautulli"
```

- [ ] **Step 2: Join the histories on the feature branch**

```bash
cd "$ARRKIT"
git remote add origin https://github.com/parsoFish/arrkit.git
git fetch -q origin
git merge --allow-unrelated-histories origin/main -m "chore: join GitHub-initialised main" || true
git checkout --ours README.md && git add README.md
git -c core.editor=true merge --continue 2>/dev/null || git commit --no-edit
git log --oneline -3
```

Expected: the top commit is the merge; `README.md` is ours (`head -1 README.md` prints `# arrkit`).

- [ ] **Step 3: Push the feature branch and open the PR**

```bash
git push -u origin import/healarr-clients
gh pr create --repo parsoFish/arrkit --base main --head import/healarr-clients \
  --title "feat: initial arrkit module extracted from healarr" \
  --body "$(cat <<'EOF'
Extracts healarr's service clients into a standalone module so healarr and simplarr can share them.

- `git subtree split` of healarr `internal/clients`, so history is preserved.
- Moved: `httpx`, `radarr`, `sonarr`, `prowlarr`, `overseerr`, `qbittorrent`, `plex`, `tautulli`.
- **Deleted from this repo (stay in healarr):** `docker/`, `hostfs/`. They are host-specific.
- Import paths rewritten; 9 comments no longer name healarr as the caller. No API changes.
- Adds the licence (MIT), golangci config, CI and README.
- Fixtures and their history were scanned for personal data: only example.com emails and documentation addresses.

Design: simplarr `docs/superpowers/specs/2026-11-14-control-plane-ui-design.md` (§3.2).
EOF
)"
```

No attribution footer, per the user's rule: no AI attribution in commits or PRs.

- [ ] **Step 4: Wait for CI**

Run: `gh pr checks --repo parsoFish/arrkit --watch`
Expected: `test` passes.

- [ ] **Step 5: Merge with a merge commit**

A merge commit keeps the imported history on `main`; squash would flatten it.

```bash
gh pr merge --repo parsoFish/arrkit --merge --delete-branch
```

- [ ] **Step 6: Tag v0.1.0 and warm the proxy**

```bash
git fetch -q origin
git tag -a v0.1.0 origin/main -m "arrkit v0.1.0: clients extracted from healarr"
git push origin v0.1.0
GOPROXY=https://proxy.golang.org go list -m github.com/parsoFish/arrkit@v0.1.0
```

Expected: the last command prints `github.com/parsoFish/arrkit v0.1.0`. The proxy can take a minute; retry once if it errors with `not found`.

---

### Task 5: healarr imports arrkit

**Files:**
- Modify: `$HEALARR` `go.mod`, `go.sum`
- Delete: `internal/clients/{httpx,radarr,sonarr,prowlarr,overseerr,qbittorrent,plex,tautulli}/`
- Modify: every `*.go` importing those packages, including `internal/clients/docker/*.go` and `internal/peer/client.go`, which import `httpx`
- Modify: `docs/architecture.md:66-69` and `:93`, `docs/tools.md:7,151,153`, `docs/decisions.md` (append ADR-020)

**Interfaces:**
- Consumes: `github.com/parsoFish/arrkit@v0.1.0` from Task 4.
- Produces: healarr on arrkit. Any later arrkit change reaches healarr by a version bump.

- [ ] **Step 1: Worktree on a no-track branch**

```bash
cd "$HEALARR"
grep -qxF '.worktrees/' .git/info/exclude || echo '.worktrees/' >> .git/info/exclude
git fetch -q origin
git worktree add --no-track -b refactor/use-arrkit .worktrees/use-arrkit origin/main
cd .worktrees/use-arrkit
```

- [ ] **Step 2: Add the dependency**

```bash
go get github.com/parsoFish/arrkit@v0.1.0
```

- [ ] **Step 3: Delete healarr's copies of the moved packages**

These 8 directories are deleted; announce the list before running.

```bash
git rm -r -q internal/clients/{httpx,radarr,sonarr,prowlarr,overseerr,qbittorrent,plex,tautulli}
ls internal/clients
```

Expected: `docker  hostfs`.

- [ ] **Step 4: Rewrite imports**

```bash
PKGS='httpx|radarr|sonarr|prowlarr|overseerr|qbittorrent|plex|tautulli'
grep -rlE "github.com/parsoFish/healarr/internal/clients/($PKGS)\"" --include='*.go' . \
  | xargs sed -i -E "s#github.com/parsoFish/healarr/internal/clients/($PKGS)\"#github.com/parsoFish/arrkit/\1\"#g"
grep -rnE "healarr/internal/clients/($PKGS)\"" --include='*.go' . ; echo "exit=$?"
```

Expected: no matches; `exit=1`.

- [ ] **Step 5: Tidy, format, vet, test, lint, cross-build**

```bash
go mod tidy
gofmt -l .
go vet ./...
go test ./... -race -cover 2>&1 | tee /tmp/healarr-after.txt | tail -5
grep -c '^ok' /tmp/healarr-after.txt
golangci-lint run
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o /dev/null ./cmd/healarr
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /dev/null ./cmd/healarr
```

Expected:
- `gofmt` and `vet` print nothing.
- No `FAIL` lines in the test output.
- The `ok` count equals the Task 1 baseline count **minus 8**, because the 8 client packages' tests now run in arrkit.
- `golangci-lint` reports `0 issues.`
- Both builds succeed.

If the count is off by anything other than 8, diff the package lists (`grep '^ok' /tmp/healarr-baseline.txt` against `/tmp/healarr-after.txt`) and explain the difference before going on.

- [ ] **Step 6: Update `docs/architecture.md`**

Replace lines 67–69 of the package-layout block:

```
internal/clients/{sonarr,radarr,prowlarr,
  qbittorrent,plex,tautulli,overseerr,
  docker,hostfs}/                         Client interface + adapter + httptest fake + golden fixtures (Tasks 4-10)
```

with:

```
github.com/parsoFish/arrkit/{sonarr,radarr,prowlarr,
  qbittorrent,plex,tautulli,overseerr,httpx}  service clients, in their own module since ADR-020
internal/clients/{docker,hostfs}/         host-specific clients: interface + adapter + fake + golden fixtures
```

At line 93, replace the opening `` `internal/clients/*` and `internal/cli/*` are what Phase 1 (this repo state) delivers: `` with:

`` The service clients (now in `github.com/parsoFish/arrkit`, ADR-020), `internal/clients/{docker,hostfs}` and `internal/cli/*` are what Phase 1 delivered: ``

Leave the rest of that paragraph unchanged.

- [ ] **Step 7: Update `docs/tools.md`**

```bash
sed -i 's#`internal/clients/\*` service clients#service clients (`github.com/parsoFish/arrkit`, plus `internal/clients/{docker,hostfs}`)#; s#each `internal/clients/\*` `Client` method#each service client'"'"'s `Client` method#; s#the relevant `internal/clients/\*` `Client` method#the relevant service client'"'"'s `Client` method#; s#the `internal/clients/\*` package already ships#each arrkit package (and `internal/clients/{docker,hostfs}`) already ships#' docs/tools.md
grep -n 'internal/clients' docs/tools.md
```

Expected: the only remaining matches mention `internal/clients/{docker,hostfs}`.

- [ ] **Step 8: Append ADR-020 to `docs/decisions.md`**

```markdown

---

## ADR-020 — Service clients extracted to arrkit

**Context.** simplarr's control-plane UI (simplarr `docs/superpowers/specs/2026-11-14-control-plane-ui-design.md`) needs the same Radarr, Sonarr, Prowlarr, Overseerr, qBittorrent, Plex and Tautulli clients healarr built in Phase 1. Go's `internal/` rule stops another module from importing them. Copying them would give two drifting implementations of the same request and response shapes.

**Decision.** Move `internal/clients/{httpx,radarr,sonarr,prowlarr,overseerr,qbittorrent,plex,tautulli}` to the new module `github.com/parsoFish/arrkit`, with history (`git subtree split`). healarr imports it at a tagged version. `docker` and `hostfs` stay here, because they are host-specific and simplarr deliberately has no docker socket. ADR-013's reasoning still holds inside arrkit: hand-rolled clients on a shared `httpx`, fixture-tested, with no third-party client libraries.

**Consequences.** A client change is now an arrkit PR plus a version bump here, with `go.work` for local iteration across both. healarr's own test count drops by the 8 moved packages, whose tests now run in arrkit's CI. The repos stay separate, per ADR-001.
```

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: import service clients from arrkit" \
  -m "Deletes internal/clients/{httpx,radarr,sonarr,prowlarr,overseerr,qbittorrent,plex,tautulli} in favour of github.com/parsoFish/arrkit v0.1.0 (ADR-020). docker and hostfs stay. No behaviour change: the full suite passes with the 8 moved packages' tests now running in arrkit."
```

- [ ] **Step 10: Push and open the PR**

```bash
git push -u origin refactor/use-arrkit
gh pr create --repo parsoFish/healarr --base main --head refactor/use-arrkit \
  --title "refactor: import service clients from arrkit" \
  --body "$(cat <<'EOF'
Moves the seven service clients and `httpx` into [arrkit](https://github.com/parsoFish/arrkit) (v0.1.0) so simplarr's control-plane UI can share them (ADR-020).

- **Deleted:** `internal/clients/{httpx,radarr,sonarr,prowlarr,overseerr,qbittorrent,plex,tautulli}/`. Same code, now in arrkit with its history.
- **Kept:** `internal/clients/docker`, `internal/clients/hostfs`, which are host-specific.
- Imports rewritten. `docs/architecture.md` and `docs/tools.md` updated; ADR-020 added.
- No behaviour change. `go test ./... -race` passes; the package count is down by exactly the 8 moved packages. Lint is clean, and the arm64 and amd64 builds pass.
EOF
)"
gh pr checks --repo parsoFish/healarr --watch
```

Expected: the `test` and both `build` matrix jobs pass. Leave the merge to the user, or merge with `gh pr merge --merge` once they say so.

---

## Done when

- `github.com/parsoFish/arrkit@v0.1.0` resolves through `proxy.golang.org`, and arrkit `main` CI is green.
- The healarr PR is open with green CI. Its test package count is the baseline minus 8, and it carries no API changes.
- Plan index row 1 is marked `done`, and Plan 1b (arrkit hardening) and Plan 2 are written next; Plan 3 is the first plan built on the real arrkit module.
