# arrkit hardening (v0.1.1): implementation plan (Plan 1b of 8)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Release `github.com/parsoFish/arrkit@v0.1.1`, a patch that fixes what the Plan 1 final review found: a concurrency-safe qBittorrent client and Fakes, URL redaction that covers userinfo passwords and invalid base URLs, a `Resume` that works on qBittorrent 5, scrubbed fixtures with a CI scan, Node 24 CI with pinned lint, and accurate docs with compiled examples.

**Architecture:** Every change stays inside arrkit's existing packages and leaves the exported API as it is, so healarr builds against v0.1.1 unchanged. Each fix lands with a test that failed first; the two races get `-race` tests with concurrent callers. The fixture rules move from README prose into `scripts/scan-fixtures.sh`, which has its own self-test and runs in CI. The release goes through a PR into the protected `main`, then an annotated tag and GitHub Releases.

**Tech Stack:** Go 1.25 (stdlib only), bash 5 with GNU grep, GitHub Actions, golangci-lint v2.15.0, `gh` CLI.

**Spec:** [`docs/superpowers/specs/2026-11-14-control-plane-ui-design.md`](../specs/2026-11-14-control-plane-ui-design.md) §2 D2, §3.2, §5.3, §10. Index: [`2026-11-14-control-plane-ui-00-index.md`](2026-11-14-control-plane-ui-00-index.md), row 1b. Review findings: the Plan 1 SDD ledger (`.superpowers/sdd/2026-11-14-control-plane-ui-01-arrkit-extraction/progress.md`, final review I1, I2, I3, M3–M5 and the deferred minors).

## Global Constraints

- **Scope** is index row 1b's eight items and nothing more. Module `github.com/parsoFish/arrkit`, `go 1.25.0`, both unchanged.
- **Stdlib only, tests included.** `go.mod` gets no `require` line and `go mod tidy -diff` stays clean. Tools run as `go run <pkg>@<version>` (golangci-lint, gorelease, actionlint) are not dependencies and never touch `go.mod`.
- **Patch release.** No exported name is removed, renamed or re-typed, and no signature changes. healarr at `origin/main` must build, vet and pass its tests against this branch with no edits (Task 8 checks it through `go.work`). An unexported field on an exported struct is fine (`Fake.mu`, `HTTPClient.mu`, `HTTPClient.session`).
- **No new exported names.** None of the eight items needs one. A `Fake` caller reads `Calls` after its goroutines finish, and `sync.WaitGroup.Wait` already orders those reads. A locked `CallLog()` accessor would grow the API with nothing that needs it. `gorelease` must report `v0.1.1 is a valid semantic version for this release.` (Task 8).
- **TDD for every code change.** Each fix starts with a test that is run and seen to fail:
  - qBittorrent login race: a `-race` test with concurrent callers (Task 1).
  - each Fake: one concurrent-use test per package, run with `-race` (Task 2).
  - redaction: tests showing that a userinfo password (`http://u:pw@host`) and `New`'s invalid-URL error no longer leak (Task 3).
  - `Resume`: `httptest` servers for both the 5.x and the 4.x path (Task 4).
  - fixture scrub: the scanner fails on the current fixtures first, and the existing tests stay green after (Task 5).
  - Docs, comments, CI config and examples have no behaviour to drive a red step. The examples are the test: `go test` compiles them and checks their `// Output:`.
- **Secrets never reach an error** (spec §5.3, §10). Tests plant the fake secret `s3cr3t-pw` and assert it never appears.
- **Fixture scrub** covers the current files only. No history rewrite (user decision, 2026-11-14).
- **Conventional commits** with no AI attribution trailer. The PR body has no attribution footer either.
- **Workspace.** All code changes happen in the worktree `.worktrees/hardening` on branch `fix/v0.1.1-hardening`, created `--no-track` from `origin/main`. The main checkout at `$ARRKIT` only switches to `main` (Task 1) and fast-forwards it after the merge (Task 8).
- **`main` is protected** by the ruleset "Protect main": PR required, required status check `test`, no force-push, no deletion, no bypass. Nothing is pushed to `main`; it moves only by merging the PR. The CI job id stays exactly `test`.
- **Lint parity.** CI pins golangci-lint `v2.15.0`. The locally installed `golangci-lint` is v2.12.2, which misses findings v2.15.0 reports (that is what broke healarr PR #8). Locally, always run `go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0 run`. It needs Go 1.26, which the `go` command downloads by itself: expect a `switching to go1.26.x` line.
- **Shell scripts:** bash 4.4+, `set -euo pipefail`, snake_case functions, every variable quoted, shellcheck-clean.
- **Files stay under 400 lines.**
- **Deletions are named before they happen:** the local branch `import/healarr-clients` (Task 1); after the merge, the worktree `.worktrees/hardening` and the local and remote branch `fix/v0.1.1-hardening` (Task 8).
- **Copy the code as given.** If a step's output does not match its "Expected", stop and report it. Do not improvise a fix.

## Decisions and evidence

### qBittorrent `Resume` (item 8): fix it, with a 4.x fallback

- **Source:** <https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-5.0)>. The 5.0 API page lists the resume action as `start` (`/api/v2/torrents/start?hashes=...`) and the pause action as `stop`.
- **The change:** PR <https://github.com/qbittorrent/qBittorrent/pull/20532>, "Use Start/Stop instead of Resume/Pause", merged 2024-03-25 as commit `5d1c2496`. It raised the WebAPI version from 2.10.4 to 2.11.0.
- **Source code checked with `gh api` against the release tags:**
  - `src/webui/api/torrentscontroller.h` declares `resumeAction`/`pauseAction` at `release-4.6.7` (WebAPI 2.9.3), and `startAction`/`stopAction` at `release-5.0.0` (2.11.2) and `release-5.2.3` (2.15.1).
  - 5.x keeps no `resume` alias.
  - An action a controller does not have answers 404, in 4.x and 5.x alike: `APIController::run` in `src/webui/api/apicontroller.cpp` throws `APIError(NotFound)` when `invokeMethod` fails, and `webapplication.cpp` maps that to `NotFoundHTTPError`.
- **So:** against simplarr's pinned 5.2.3, arrkit's current `Resume` gets a 404 every time. A 4.x server, which healarr's NAS may run, answers 404 for `/torrents/start`.
- **Decision:** POST `/torrents/start`, and on a 404 POST `/torrents/resume` with the same form. Any other error is returned without a fallback.
  - On 4.x this costs one extra round trip per call. `Resume` is rare, so nothing caches which endpoint worked (YAGNI).
  - Tests cover both paths, the no-fallback-on-500 path, and both endpoints missing (Task 4).

### Healarr-specific wording (item 4): every hit

`git grep -n -i -E 'check engine|phase [0-9]|healarr|the brief|check run|--json' origin/main` returns these hits. Each is fixed in the task that already edits that file:

| Hit | Fixed in |
|---|---|
| `{overseerr,plex,prowlarr,qbittorrent}/fake.go:8` and `{radarr,sonarr,tautulli}/fake.go:9`: "for tests and the check engine's table tests" | Task 2 |
| `qbittorrent/client.go:22-23`: "in Phase 1 (one check run drives one client at a time)" | Task 1 |
| `qbittorrent/client.go:214` and `qbittorrent/types.go:44`: "camelCase json tags for --json output" (healarr's CLI flag) | Task 7 |
| `{prowlarr,radarr,sonarr}/client_extra_test.go:12` and `qbittorrent/client_extra_test.go:13`: "supplement the brief's verbatim client_test.go" (Plan 1 wording) | Task 7 |
| `README.md:14`: "extracted from healarr, and is used by healarr and simplarr" | Task 7 (rewritten as "used by" wording; the provenance link stays) |

### CI action versions (item 5)

Looked up on 2026-11-14 with `gh api repos/<owner>/<repo>/releases/latest --jq .tag_name`. Each tag's `action.yml` says `using: node24`:

| Action | v0.1.0 used | Pinned to (exact release tag) | Same commit as the major tag |
|---|---|---|---|
| `actions/checkout` | `v4` | `v7.0.1` | `v7` → `3d3c42e` |
| `actions/setup-go` | `v5` | `v7.0.0` | `v7` → `b7ad1da` |
| `golangci/golangci-lint-action` | `v8` | `v9.3.0` | `v9` → `ba0d7d2` |
| golangci-lint itself | `latest` | `v2.15.0` (2026-10-16) | — |

Exact release tags give the same reproducibility as the pinned lint version. Bumping them is a deliberate PR.

## File structure

```
qbittorrent/client.go              login serialised behind a mutex; Resume tries start, then resume on 404
qbittorrent/concurrency_test.go    NEW: -race tests, concurrent callers share one login and one renewal
qbittorrent/resume_test.go         NEW: 5.x (start) and 4.x (resume fallback) paths
qbittorrent/client_extra_test.go   existing Resume assertion moves to /torrents/start; comment wording
qbittorrent/types.go               comment wording
*/fake.go (7 packages)             mu guards Calls in record(); doc comment wording
*/fake_concurrency_test.go (7)     NEW: one concurrent-use test per Fake
httpx/client.go                    redactURL masks userinfo passwords and unparsable URLs; New stops echoing its input
httpx/redact_test.go               NEW: userinfo, unparsable-URL and New error tests
scripts/scan-fixtures.sh           NEW: fixture/secret scanner, exit 0 clean / 1 hits / 2 error
scripts/scan-fixtures_test.sh      NEW: scanner self-check, one planted sample per rule
sonarr/testdata/{queue,history,series}.json
radarr/testdata/{history,movie,wanted_missing}.json
                                   real infohashes, release names, library paths -> obvious fakes
.github/workflows/ci.yml           Node 24 actions, lint v2.15.0, read-only token, no cache, scanner + shellcheck steps
radarr/example_test.go             NEW: ExampleNew, ExampleFake (compiled by go test)
README.md                          compiled usage, Fake section, go.work, exact redaction scope, used-by, scrub rule
{prowlarr,radarr,sonarr}/client_extra_test.go   comment wording
```

## Shell variables

Agent shells keep no variables between calls, so start every command block with these two lines. They are not committed anywhere:

```bash
ARRKIT="<path to your arrkit checkout>"   # the arrkit folder next to simplarr and healarr
WT="$ARRKIT/.worktrees/hardening"
```

---

### Task 1: Workspace and the qBittorrent login race

**Files:**
- Workspace: local branches and the worktree in `$ARRKIT`. No repository file changes.
- Create: `qbittorrent/concurrency_test.go`
- Modify: `qbittorrent/client.go:3-16` (import `sync`), `:20-30` (`HTTPClient` doc and fields), `:53-89` (`login` doc, `login`, `withAuth`)

**Interfaces:**
- Consumes: arrkit `origin/main` at `ccd803b` (tag v0.1.0).
- Produces:
  - Branch `fix/v0.1.1-hardening`, checked out at `$WT`. Every later task commits there.
  - In package `qbittorrent`, all unexported:
    - fields `HTTPClient.mu sync.Mutex` and `HTTPClient.session uint64`,
    - `(*HTTPClient).ensureSession(ctx context.Context) (uint64, error)`,
    - `(*HTTPClient).renewSession(ctx context.Context, failed uint64) error`.
  - `withAuth(ctx context.Context, fn func() error) error` keeps its signature.
  - Test helpers `sessionServer` and `callVersionConcurrently` (in `concurrency_test.go`). Later tasks must not reuse those names.

- [ ] **Step 1: Set up the workspace**

```bash
cd "$ARRKIT"
git status --porcelain                     # expect no output; stop if there is any
git fetch --prune origin
git switch --create main --track origin/main
grep -qxF '.worktrees/' .git/info/exclude || echo '.worktrees/' >> .git/info/exclude
git worktree add --no-track -b fix/v0.1.1-hardening .worktrees/hardening origin/main
```

Expected:
- `git fetch --prune` reports `[deleted] (none) -> origin/import/healarr-clients`. PR #1 deleted that remote branch when it merged.
- `git switch` reports `branch 'main' set up to track 'origin/main'`.
- The worktree is created at `ccd803b`.

- [ ] **Step 2: Delete the stale local branch `import/healarr-clients`**

Announce this deletion before running it. The branch is at `8f2c4fd`. Its commits are on `main` through the PR #1 merge `ccd803b`, and its remote branch is already gone.

```bash
cd "$ARRKIT"
git merge-base --is-ancestor import/healarr-clients origin/main && echo "on main"
git branch -d import/healarr-clients
git branch -vv
git worktree list
```

Expected:
- `on main`, then `Deleted branch import/healarr-clients (was 8f2c4fd).`
- `git branch -vv` lists only `* main ... [origin/main]` and `+ fix/v0.1.1-hardening`.
- `git worktree list` shows `.worktrees/hardening  ccd803b [fix/v0.1.1-hardening]`.

- [ ] **Step 3: Baseline**

Run: `cd "$WT" && go test ./... -race`
Expected: 8 `ok` lines: `httpx`, `overseerr`, `plex`, `prowlarr`, `qbittorrent`, `radarr`, `sonarr`, `tautulli`.

- [ ] **Step 4: Write the failing test**

Create `qbittorrent/concurrency_test.go`:

```go
package qbittorrent

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// sessionServer is a qBittorrent stand-in that is safe for concurrent
// requests. Each login issues a new SID ("s1", "s2", ...) and takes
// loginDelay, so concurrent callers that are not serialised overlap inside
// login. /app/version answers 200 only for the current SID and 403 for any
// other, the way a real server treats an expired session.
type sessionServer struct {
	logins     atomic.Int64
	loginDelay time.Duration

	mu    sync.Mutex
	valid string // SID /app/version accepts; "" accepts none
}

func (s *sessionServer) expire() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.valid = ""
}

func (s *sessionServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/api/v2/auth/login":
		n := s.logins.Add(1)
		time.Sleep(s.loginDelay)
		sid := "s" + strconv.FormatInt(n, 10)
		s.mu.Lock()
		s.valid = sid
		s.mu.Unlock()
		http.SetCookie(w, &http.Cookie{Name: "SID", Value: sid, Path: "/"})
		_, _ = w.Write([]byte("Ok."))
	case "/api/v2/app/version":
		c, err := r.Cookie("SID")
		s.mu.Lock()
		ok := err == nil && c.Value == s.valid
		s.mu.Unlock()
		if !ok {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		_, _ = w.Write([]byte("v5.2.3"))
	default:
		http.NotFound(w, r)
	}
}

// callVersionConcurrently releases n goroutines at once, each calling
// Version, and fails the test if any call errors.
func callVersionConcurrently(t *testing.T, c *HTTPClient, n int) {
	t.Helper()
	start := make(chan struct{})
	errs := make(chan error, n)
	var wg sync.WaitGroup
	for range n {
		wg.Go(func() {
			<-start
			_, err := c.Version(context.Background())
			errs <- err
		})
	}
	close(start)
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Errorf("Version: %v", err)
		}
	}
}

func TestConcurrentCallersShareOneLogin(t *testing.T) {
	qb := &sessionServer{loginDelay: 50 * time.Millisecond}
	srv := httptest.NewServer(qb)
	defer srv.Close()
	c, err := New(srv.URL, "admin", "adminadmin")
	if err != nil {
		t.Fatal(err)
	}

	callVersionConcurrently(t, c, 8)

	if got := qb.logins.Load(); got != 1 {
		t.Fatalf("logins = %d, want 1 shared by 8 concurrent callers", got)
	}
}

func TestConcurrentCallersRenewExpiredSessionOnce(t *testing.T) {
	qb := &sessionServer{loginDelay: 50 * time.Millisecond}
	srv := httptest.NewServer(qb)
	defer srv.Close()
	c, err := New(srv.URL, "admin", "adminadmin")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Version(context.Background()); err != nil {
		t.Fatalf("first Version: %v", err)
	}
	qb.expire() // every caller's next request carries a dead SID

	callVersionConcurrently(t, c, 8)

	if got := qb.logins.Load(); got != 2 {
		t.Fatalf("logins = %d, want 2 (first login + one renewal shared by 8 callers)", got)
	}
}
```

Why the test is built this way:
- **The count assertion is the reliable signal, not the race detector alone.** Under `-race`, every socket read and write is a synchronisation point (`syscall` annotates them), so the detector can miss the `loggedIn` race between goroutines that do network I/O.
- **The 50 ms login delay** makes unserialised callers overlap inside `login`.
- **The server accepts only the newest SID**, so overlapping logins also produce 403s and extra re-logins.

- [ ] **Step 5: Run it and watch it fail**

Run: `cd "$WT" && go test -race -count=1 -run TestConcurrentCallers ./qbittorrent/`
Expected: FAIL. Both tests fail on their count, for example `logins = 16, want 1 shared by 8 concurrent callers` and `logins = 9, want 2 (...)`; the numbers vary from run to run. `WARNING: DATA RACE` reports on `loggedIn` usually appear as well.

- [ ] **Step 6: Serialise login**

In `qbittorrent/client.go`, add `"sync"` to the imports, between `"strings"` and `"time"`:

```go
	"strconv"
	"strings"
	"sync"
	"time"
```

Replace the `HTTPClient` doc comment and struct (lines 20–30):

```go
// HTTPClient talks to a real qBittorrent WebUI.
//
// loggedIn is read and written from a single goroutine at a time in Phase 1
// (one check run drives one client at a time); it is not safe for concurrent
// use without external synchronisation.
type HTTPClient struct {
	h        *httpx.Client
	user     string
	pass     string
	loggedIn bool
}
```

with:

```go
// HTTPClient talks to a real qBittorrent WebUI. It is safe for concurrent
// use: logins are serialised, so concurrent callers share one session, and a
// session that expires (403) is renewed once however many callers see it.
type HTTPClient struct {
	h    *httpx.Client
	user string
	pass string

	mu       sync.Mutex // serialises login; guards loggedIn and session
	loggedIn bool
	session  uint64 // bumped by every successful login
}
```

Replace everything from the `login` doc comment through the end of `withAuth` (lines 53–89):

```go
// login authenticates and stores the SID cookie in the shared cookie jar. An
// empty user and pass means the caller relies on qBittorrent's subnet
// whitelist, so login is skipped entirely.
func (c *HTTPClient) login(ctx context.Context) error {
	if c.user == "" && c.pass == "" {
		return nil
	}
	var body string
	form := url.Values{"username": {c.user}, "password": {c.pass}}
	if err := c.h.PostForm(ctx, apiBase+"/auth/login", form, &body); err != nil {
		return fmt.Errorf("qbittorrent login: %w", err)
	}
	if strings.TrimSpace(body) != "Ok." {
		return errors.New("qbittorrent login: invalid credentials")
	}
	c.loggedIn = true
	return nil
}

// withAuth runs fn, logging in first if needed and once more after a 403
// (the session expired between calls).
func (c *HTTPClient) withAuth(ctx context.Context, fn func() error) error {
	if !c.loggedIn {
		if err := c.login(ctx); err != nil {
			return err
		}
	}
	err := fn()
	if httpx.IsStatus(err, http.StatusForbidden) {
		c.loggedIn = false
		if lerr := c.login(ctx); lerr != nil {
			return lerr
		}
		return fn()
	}
	return err
}
```

with:

```go
// login authenticates and stores the SID cookie in the shared cookie jar.
// The caller must hold c.mu. An empty user and pass means the caller relies
// on qBittorrent's subnet whitelist, so login is skipped entirely.
func (c *HTTPClient) login(ctx context.Context) error {
	if c.user == "" && c.pass == "" {
		return nil
	}
	var body string
	form := url.Values{"username": {c.user}, "password": {c.pass}}
	if err := c.h.PostForm(ctx, apiBase+"/auth/login", form, &body); err != nil {
		return fmt.Errorf("qbittorrent login: %w", err)
	}
	if strings.TrimSpace(body) != "Ok." {
		return errors.New("qbittorrent login: invalid credentials")
	}
	c.loggedIn = true
	c.session++
	return nil
}

// ensureSession logs in unless a session already exists, and returns the
// session generation the caller's request runs under.
func (c *HTTPClient) ensureSession(ctx context.Context) (uint64, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.loggedIn {
		if err := c.login(ctx); err != nil {
			return 0, err
		}
	}
	return c.session, nil
}

// renewSession logs in again after a request made under session generation
// failed got a 403. If another caller has already renewed that session, it
// does nothing.
func (c *HTTPClient) renewSession(ctx context.Context, failed uint64) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.loggedIn && c.session != failed {
		return nil
	}
	c.loggedIn = false
	return c.login(ctx)
}

// withAuth runs fn, logging in first if needed and once more after a 403
// (the session expired between calls).
func (c *HTTPClient) withAuth(ctx context.Context, fn func() error) error {
	session, err := c.ensureSession(ctx)
	if err != nil {
		return err
	}
	err = fn()
	if httpx.IsStatus(err, http.StatusForbidden) {
		if lerr := c.renewSession(ctx, session); lerr != nil {
			return lerr
		}
		return fn()
	}
	return err
}
```

`fn` runs outside the lock, so requests still go out in parallel. Only logging in is serialised.

- [ ] **Step 7: Run the tests and watch them pass**

```bash
cd "$WT"
go test -race -count=20 -run TestConcurrentCallers ./qbittorrent/
go test -race -count=1 ./qbittorrent/
gofmt -l . ; go vet ./...
go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0 run
```

Expected:
- Both `go test` runs print `ok`. The 20 repeats show the counts are deterministic once login is serialised.
- The existing `TestVersionRetriesAfterSessionExpiry`, `TestVersionFailsAfterSingleRetry`, `TestReloginFailureAfter403IsReturned` and `TestNoCredsSkipsLogin` still pass.
- `gofmt` and `vet` print nothing. Lint prints `0 issues.`

- [ ] **Step 8: Commit**

```bash
cd "$WT"
git add qbittorrent/client.go qbittorrent/concurrency_test.go
git commit -m "fix: serialise qBittorrent login for concurrent callers" \
  -m "HTTPClient read and wrote loggedIn without a lock, so concurrent callers raced and each logged in. Login now runs under a mutex: concurrent callers share one session, and a 403 renews the session once, keyed by a session generation. Adds -race tests with 8 concurrent callers for both paths."
```

---

### Task 2: Concurrency-safe Fakes

**Files:**
- Create: `radarr/fake_concurrency_test.go`, `sonarr/fake_concurrency_test.go`, `prowlarr/fake_concurrency_test.go`, `overseerr/fake_concurrency_test.go`, `qbittorrent/fake_concurrency_test.go`, `plex/fake_concurrency_test.go`, `tautulli/fake_concurrency_test.go`
- Modify: the same four places in each of the 7 `fake.go` files:
  - the doc comment (line 8; line 9 in `radarr`, `sonarr` and `tautulli`),
  - the `"fmt"` import,
  - the end of the `Fake` struct,
  - `record`.

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - In every package, an unexported field `Fake.mu sync.Mutex`, taken inside `record`.
  - `Fake`'s exported fields and methods are unchanged.
  - Each package gets a test named `TestFakeIsSafeForConcurrentUse`.

healarr compatibility, checked against healarr `origin/main` (`a0d5b6d`):
- healarr builds every Fake as `&pkg.Fake{...}` with keyed fields, or embeds `*pkg.Fake`. It never copies one by value, so `go vet`'s copylocks check stays quiet.
- Its wrapper methods that append to `f.Calls` directly run on one goroutine, as before.

- [ ] **Step 1: Write the 7 failing tests**

Create `radarr/fake_concurrency_test.go`:

```go
package radarr

import (
	"context"
	"sync"
	"testing"
)

// TestFakeIsSafeForConcurrentUse calls the Fake from 16 goroutines at once.
// Without the lock in record, -race reports the Calls append and calls can
// be lost.
func TestFakeIsSafeForConcurrentUse(t *testing.T) {
	f := &Fake{}
	ctx := context.Background()
	const goroutines, rounds = 16, 25
	var wg sync.WaitGroup
	for range goroutines {
		wg.Go(func() {
			for range rounds {
				_, _ = f.Health(ctx)
				_ = f.DeleteQueueItem(ctx, 1, false, false)
			}
		})
	}
	wg.Wait()
	if got, want := len(f.Calls), goroutines*rounds*2; got != want {
		t.Fatalf("len(Calls) = %d, want %d", got, want)
	}
}
```

Create `sonarr/fake_concurrency_test.go`:

```go
package sonarr

import (
	"context"
	"sync"
	"testing"
)

// TestFakeIsSafeForConcurrentUse calls the Fake from 16 goroutines at once.
// Without the lock in record, -race reports the Calls append and calls can
// be lost.
func TestFakeIsSafeForConcurrentUse(t *testing.T) {
	f := &Fake{}
	ctx := context.Background()
	const goroutines, rounds = 16, 25
	var wg sync.WaitGroup
	for range goroutines {
		wg.Go(func() {
			for range rounds {
				_, _ = f.Health(ctx)
				_ = f.DeleteQueueItem(ctx, 1, false, false)
			}
		})
	}
	wg.Wait()
	if got, want := len(f.Calls), goroutines*rounds*2; got != want {
		t.Fatalf("len(Calls) = %d, want %d", got, want)
	}
}
```

Create `prowlarr/fake_concurrency_test.go`:

```go
package prowlarr

import (
	"context"
	"sync"
	"testing"
)

// TestFakeIsSafeForConcurrentUse calls the Fake from 16 goroutines at once.
// Without the lock in record, -race reports the Calls append and calls can
// be lost.
func TestFakeIsSafeForConcurrentUse(t *testing.T) {
	f := &Fake{}
	ctx := context.Background()
	const goroutines, rounds = 16, 25
	var wg sync.WaitGroup
	for range goroutines {
		wg.Go(func() {
			for range rounds {
				_, _ = f.Health(ctx)
				_ = f.DeleteIndexer(ctx, 1)
			}
		})
	}
	wg.Wait()
	if got, want := len(f.Calls), goroutines*rounds*2; got != want {
		t.Fatalf("len(Calls) = %d, want %d", got, want)
	}
}
```

Create `overseerr/fake_concurrency_test.go`:

```go
package overseerr

import (
	"context"
	"sync"
	"testing"
)

// TestFakeIsSafeForConcurrentUse calls the Fake from 16 goroutines at once.
// Without the lock in record, -race reports the Calls append and calls can
// be lost.
func TestFakeIsSafeForConcurrentUse(t *testing.T) {
	f := &Fake{}
	ctx := context.Background()
	const goroutines, rounds = 16, 25
	var wg sync.WaitGroup
	for range goroutines {
		wg.Go(func() {
			for range rounds {
				_, _ = f.Status(ctx)
				_ = f.DeclineRequest(ctx, 1)
			}
		})
	}
	wg.Wait()
	if got, want := len(f.Calls), goroutines*rounds*2; got != want {
		t.Fatalf("len(Calls) = %d, want %d", got, want)
	}
}
```

Create `qbittorrent/fake_concurrency_test.go`:

```go
package qbittorrent

import (
	"context"
	"sync"
	"testing"
)

// TestFakeIsSafeForConcurrentUse calls the Fake from 16 goroutines at once.
// Without the lock in record, -race reports the Calls append and calls can
// be lost.
func TestFakeIsSafeForConcurrentUse(t *testing.T) {
	f := &Fake{}
	ctx := context.Background()
	const goroutines, rounds = 16, 25
	var wg sync.WaitGroup
	for range goroutines {
		wg.Go(func() {
			for range rounds {
				_, _ = f.Torrents(ctx, "", "")
				_ = f.Delete(ctx, []string{"a"}, false)
			}
		})
	}
	wg.Wait()
	if got, want := len(f.Calls), goroutines*rounds*2; got != want {
		t.Fatalf("len(Calls) = %d, want %d", got, want)
	}
}
```

Create `plex/fake_concurrency_test.go`:

```go
package plex

import (
	"context"
	"sync"
	"testing"
)

// TestFakeIsSafeForConcurrentUse calls the Fake from 16 goroutines at once.
// Without the lock in record, -race reports the Calls append and calls can
// be lost.
func TestFakeIsSafeForConcurrentUse(t *testing.T) {
	f := &Fake{}
	ctx := context.Background()
	const goroutines, rounds = 16, 25
	var wg sync.WaitGroup
	for range goroutines {
		wg.Go(func() {
			for range rounds {
				_, _ = f.Libraries(ctx)
				_ = f.RefreshLibrary(ctx, "1")
			}
		})
	}
	wg.Wait()
	if got, want := len(f.Calls), goroutines*rounds*2; got != want {
		t.Fatalf("len(Calls) = %d, want %d", got, want)
	}
}
```

Create `tautulli/fake_concurrency_test.go`:

```go
package tautulli

import (
	"context"
	"sync"
	"testing"
)

// TestFakeIsSafeForConcurrentUse calls the Fake from 16 goroutines at once.
// Without the lock in record, -race reports the Calls append and calls can
// be lost.
func TestFakeIsSafeForConcurrentUse(t *testing.T) {
	f := &Fake{}
	ctx := context.Background()
	const goroutines, rounds = 16, 25
	var wg sync.WaitGroup
	for range goroutines {
		wg.Go(func() {
			for range rounds {
				_ = f.Ping(ctx)
				_, _ = f.ActivityCount(ctx)
			}
		})
	}
	wg.Wait()
	if got, want := len(f.Calls), goroutines*rounds*2; got != want {
		t.Fatalf("len(Calls) = %d, want %d", got, want)
	}
}
```

- [ ] **Step 2: Run them and watch all 7 fail**

Run: `cd "$WT" && go test -race -count=1 -run TestFakeIsSafeForConcurrentUse ./...`
Expected: `FAIL` for `overseerr`, `plex`, `prowlarr`, `qbittorrent`, `radarr`, `sonarr` and `tautulli`, each with `WARNING: DATA RACE` in `record` and `testing.go: race detected during execution of test`. A lost-append count line (`len(Calls) = 7xx, want 800`) may also appear. `httpx` prints `ok ... [no tests to run]`. This was checked against v0.1.0: all 7 fail on every run.

- [ ] **Step 3: Guard `Calls` in all 7 Fakes**

The four edits are byte-identical in all 7 files:

| Edit | Old | New |
|---|---|---|
| doc comment | `// Fake is an in-memory Client for tests and the check engine's table tests.` | `// Fake is an in-memory Client for callers' unit tests. Its methods are safe`<br>`// for concurrent use; read Calls only after the calls under test return.` |
| import | `"fmt"` | `"fmt"` then `"sync"` on the next line |
| struct end | the struct's closing `}` just before `var _ Client = (*Fake)(nil)` | a blank line, `mu sync.Mutex // guards Calls`, then `}` |
| `record` body | `f.Calls = append(f.Calls, fmt.Sprintf(format, args...))` | four lines: `call := fmt.Sprintf(format, args...)`, `f.mu.Lock()`, `defer f.mu.Unlock()`, `f.Calls = append(f.Calls, call)` |

Apply them with this block. It writes a small perl script into a scratch directory outside the repository and runs it on each file. If any anchor is missing, the script stops with a message and leaves that file as it was. Running it a second time also stops, at the doc comment.

```bash
cd "$WT"
SCRATCH="$(mktemp -d)"
cat >"$SCRATCH/fake-mutex.pl" <<'PERL'
s#// Fake is an in-memory Client for tests and the check engine's table tests\.\n#// Fake is an in-memory Client for callers' unit tests. Its methods are safe\n// for concurrent use; read Calls only after the calls under test return.\n# or die "doc comment not found in $ARGV\n";
s#\t"fmt"\n#\t"fmt"\n\t"sync"\n# or die "fmt import not found in $ARGV\n";
s#\n\}\n\nvar _ Client = \(\*Fake\)\(nil\)\n#\n\n\tmu sync.Mutex // guards Calls\n}\n\nvar _ Client = (*Fake)(nil)\n# or die "struct end not found in $ARGV\n";
s#\tf\.Calls = append\(f\.Calls, fmt\.Sprintf\(format, args\.\.\.\)\)\n#\tcall := fmt.Sprintf(format, args...)\n\tf.mu.Lock()\n\tdefer f.mu.Unlock()\n\tf.Calls = append(f.Calls, call)\n# or die "record body not found in $ARGV\n";
PERL
for p in radarr sonarr prowlarr overseerr qbittorrent plex tautulli; do
  perl -0pi "$SCRATCH/fake-mutex.pl" "$p/fake.go" || echo "FAILED $p"
done
gofmt -l .
rm -rf "$SCRATCH"   # deletes only the scratch directory made above
```

Expected: no `FAILED` line and no `gofmt` output. The block's last line deletes its own scratch directory; say so before running it.

After the script, `radarr/fake.go` begins like this. The other six differ only in package name, imports and fields:

```go
package radarr

import (
	"context"
	"fmt"
	"sync"
	"time"
)

// Fake is an in-memory Client for callers' unit tests. Its methods are safe
// for concurrent use; read Calls only after the calls under test return.
type Fake struct {
	HealthItems    []HealthItem
	QueueItems     []QueueItem
	MovieList      []Movie
	Roots          []RootFolder
	Missing        int
	HistoryRecords []HistoryRecord
	Calls          []string
	Err            error

	mu sync.Mutex // guards Calls
}

var _ Client = (*Fake)(nil)

func (f *Fake) record(format string, args ...any) error {
	call := fmt.Sprintf(format, args...)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.Calls = append(f.Calls, call)
	return f.Err
}
```

`fmt.Sprintf` runs before the lock is taken, so the critical section is only the append and the read of `Err`.

- [ ] **Step 4: Run the tests and watch them pass**

```bash
cd "$WT"
go test -race -count=5 -run TestFakeIsSafeForConcurrentUse ./...
go test -race -count=1 ./...
grep -c 'mu sync.Mutex // guards Calls' */fake.go
git grep -n "check engine" ; echo "exit=$?"
go vet ./...
go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0 run
```

Expected:
- Every package prints `ok`.
- The `grep -c` prints `:1` for each of the 7 `fake.go` files.
- The `git grep` prints nothing and `exit=1`.
- `vet` is silent and lint prints `0 issues.`

- [ ] **Step 5: Commit**

```bash
cd "$WT"
git add */fake.go */fake_concurrency_test.go
git commit -m "fix: make every Fake safe for concurrent use" \
  -m "record appended to Calls with no lock, so concurrent callers raced. Each of the 7 Fakes now guards Calls with an unexported mutex; exported fields and methods are unchanged. Adds a -race concurrent-use test per package and drops the healarr 'check engine' wording from the doc comments."
```

---

### Task 3: httpx redaction of userinfo and invalid base URLs

**Files:**
- Create: `httpx/redact_test.go`
- Modify: `httpx/client.go:32-53` (`redactURL` and its doc), `:62-66` (`redactTransportError` doc), `:148-156` (`New`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - unexported `const redactedUnparsable = "(unparsable URL, redacted)"`.
  - `redactURL(rawURL string) string`, same signature, now also:
    - masks the userinfo password with `url.URL.Redacted` (`u:pw@` becomes `u:xxxxx@`),
    - replaces input that does not parse with `redactedUnparsable`.
  - `New`'s errors:
    - parse failure: `httpx: invalid base URL: <redacted *url.Error>`,
    - missing scheme or host: `httpx: invalid base URL: want scheme://host`.
  - The test constant `secret` is defined in `httpx/redact_test.go`.

What the change covers: `redactURL` is the single choke point for:
- `APIError.URL` and its message,
- the `httpx: <method> <url>` prefix on transport, build and read errors,
- the `*url.Error` inside transport errors (through `redactTransportError`).

Before this fix, a URL with userinfo but no query came back unchanged, and `u.String()` kept the password when there was a query. `New` echoed its input with `%q`, both in the parse-error message and through the wrapped `url.Parse` error.

- [ ] **Step 1: Write the failing tests**

Create `httpx/redact_test.go`:

```go
package httpx

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// secret is the password every test below plants; no error may contain it.
const secret = "s3cr3t-pw"

func TestRedactURLMasksUserinfoPasswordAndQuery(t *testing.T) {
	got := redactURL("http://admin:" + secret + "@example.com/api?apikey=" + secret)
	if want := "http://admin:xxxxx@example.com/api?apikey=REDACTED"; got != want {
		t.Fatalf("redactURL = %q, want %q", got, want)
	}
}

func TestRedactURLMasksUserinfoPasswordWithoutQuery(t *testing.T) {
	got := redactURL("http://admin:" + secret + "@example.com/api")
	if want := "http://admin:xxxxx@example.com/api"; got != want {
		t.Fatalf("redactURL = %q, want %q", got, want)
	}
}

func TestRedactURLReplacesUnparsableInput(t *testing.T) {
	got := redactURL("http://admin:" + secret + "@exa mple.com/")
	if want := "(unparsable URL, redacted)"; got != want {
		t.Fatalf("redactURL = %q, want %q", got, want)
	}
}

func TestAPIErrorRedactsUserinfoPassword(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "nope", http.StatusInternalServerError)
	}))
	defer srv.Close()
	base, err := url.Parse(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	base.User = url.UserPassword("admin", secret)
	c, err := New(base.String())
	if err != nil {
		t.Fatal(err)
	}
	err = c.GetJSON(context.Background(), "/status", nil, nil)
	var ae *APIError
	if !errors.As(err, &ae) {
		t.Fatalf("expected *APIError, got %T: %v", err, err)
	}
	if strings.Contains(err.Error(), secret) || strings.Contains(ae.URL, secret) {
		t.Fatalf("APIError leaked the userinfo password: %v", err)
	}
}

func TestTransportErrorRedactsUserinfoPassword(t *testing.T) {
	// Port 1 is privileged and unlikely to have a listener, so the dial
	// fails at once with a transport error.
	c, err := New("http://admin:" + secret + "@127.0.0.1:1")
	if err != nil {
		t.Fatal(err)
	}
	err = c.GetJSON(context.Background(), "/x", nil, nil)
	if err == nil {
		t.Fatal("expected a transport error connecting to a closed port")
	}
	if strings.Contains(err.Error(), secret) {
		t.Fatalf("transport error leaked the userinfo password: %v", err)
	}
}

func TestNewInvalidBaseURLDoesNotLeakSecrets(t *testing.T) {
	cases := map[string]string{
		"parse error in host":       "http://admin:" + secret + "@exa mple.com",
		"parse error, control byte": "http://admin:" + secret + "@example.com/\x7f",
		"no scheme, userinfo":       "admin:" + secret + "@nas:8080",
		"no host, query":            "/radarr?apikey=" + secret,
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := New(raw)
			if err == nil {
				t.Fatal("expected an error")
			}
			if !strings.Contains(err.Error(), "invalid base URL") {
				t.Errorf("error %q does not say invalid base URL", err)
			}
			if strings.Contains(err.Error(), secret) {
				t.Errorf("error leaked the secret: %q", err)
			}
		})
	}
}
```

The `no scheme, userinfo` case is the subtle one. `url.Parse("admin:pw@nas:8080")` succeeds, with scheme `admin` and the password in the opaque part, so redaction cannot help there. `New` must stop echoing its input altogether.

- [ ] **Step 2: Run them and watch them fail**

Run: `cd "$WT" && go test -count=1 ./httpx/`
Expected: FAIL, with every new test failing. For example:
- `redactURL = "http://admin:s3cr3t-pw@example.com/api?apikey=REDACTED", want "http://admin:xxxxx@..."`
- `APIError leaked the userinfo password: GET http://admin:s3cr3t-pw@127.0.0.1:<port>/status: HTTP 500: nope`
- `transport error leaked ...: httpx: GET http://admin:s3cr3t-pw@127.0.0.1:1/x: ...`
- 4 `error leaked the secret` subtests.

All the existing httpx tests still pass.

- [ ] **Step 3: Redact userinfo and unparsable URLs**

In `httpx/client.go`, replace `redactURL` and its doc comment (lines 32–53):

```go
// redactURL returns a copy of rawURL with every query parameter value
// replaced by "REDACTED" (parameter names are preserved). It is the single
// choke point every error path in this package must send a request URL
// through before it can appear in an error message, since query strings
// routinely carry secrets (e.g. Tautulli's apikey parameter). Unparsable
// input is returned unchanged, since it cannot contain a decodable query.
func redactURL(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil || u.RawQuery == "" {
		return rawURL
	}
	q := u.Query()
	for k, vs := range q {
		redacted := make([]string, len(vs))
		for i := range vs {
			redacted[i] = "REDACTED"
		}
		q[k] = redacted
	}
	u.RawQuery = q.Encode()
	return u.String()
}
```

with:

```go
// redactedUnparsable stands in for a URL that does not parse. Such a URL
// cannot be redacted piece by piece, so none of it is shown.
const redactedUnparsable = "(unparsable URL, redacted)"

// redactURL returns a copy of rawURL that is safe to put in an error: every
// query parameter value becomes "REDACTED" (names are kept) and a userinfo
// password becomes "xxxxx" (url.URL.Redacted; the username is kept). It is
// the single choke point every error path in this package must send a URL
// through, since query strings routinely carry secrets (e.g. Tautulli's
// apikey parameter) and a base URL can carry credentials. Input that does
// not parse is replaced whole by redactedUnparsable.
func redactURL(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil {
		return redactedUnparsable
	}
	if u.RawQuery == "" && u.User == nil {
		return rawURL
	}
	if u.RawQuery != "" {
		q := u.Query()
		for k, vs := range q {
			redacted := make([]string, len(vs))
			for i := range vs {
				redacted[i] = "REDACTED"
			}
			q[k] = redacted
		}
		u.RawQuery = q.Encode()
	}
	return u.Redacted()
}
```

A URL with no query and no userinfo still comes back byte-for-byte, so `TestRedactURLLeavesQuerylessURLUnchanged` keeps passing.

In the `redactTransportError` doc comment, replace these lines:

```go
// a *url.Error whose Error() method embeds the full request URL verbatim
// (e.g. `Get "http://host/x?apikey=...": dial tcp ...`), bypassing
// redactURL on our own wrapping text entirely. It returns a copy of err with
```

with:

```go
// a *url.Error whose Error() method embeds the full URL verbatim
// (e.g. `Get "http://host/x?apikey=...": dial tcp ...`, or url.Parse's
// `parse "http://u:pw@host": ...` in New), bypassing redactURL on our own
// wrapping text entirely. It returns a copy of err with
```

Replace the start of `New` (lines 148–156):

```go
// New builds a client for baseURL.
func New(baseURL string, opts ...Option) (*Client, error) {
	u, err := url.Parse(baseURL)
	if err != nil {
		return nil, fmt.Errorf("httpx: invalid base URL %q: %w", baseURL, err)
	}
	if u.Scheme == "" || u.Host == "" {
		return nil, fmt.Errorf("httpx: invalid base URL %q", baseURL)
	}
```

with:

```go
// New builds a client for baseURL. Its errors do not echo baseURL, which can
// carry credentials.
func New(baseURL string, opts ...Option) (*Client, error) {
	u, err := url.Parse(baseURL)
	if err != nil {
		return nil, fmt.Errorf("httpx: invalid base URL: %w", redactTransportError(err))
	}
	if u.Scheme == "" || u.Host == "" {
		// The input is not echoed: without a scheme, "user:pass@host" parses
		// as scheme "user" with the password in the opaque part.
		return nil, errors.New("httpx: invalid base URL: want scheme://host")
	}
```

`errors` is already imported. A parse failure now reads, for example, `httpx: invalid base URL: parse "(unparsable URL, redacted)": invalid character " " in host name`. The wrapped `*url.Error` is kept, so `errors.As` still works.

- [ ] **Step 4: Run the tests and watch them pass**

```bash
cd "$WT"
go test -count=1 -v -run 'Redact|TestNew|Transport|APIError' ./httpx/ | grep -E '^(--- |ok|FAIL)'
go test -race -count=1 ./...
gofmt -l . ; go vet ./...
go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0 run
```

Expected:
- Every listed test shows `--- PASS`, including the unchanged `TestNewRejectsBadURL`, `TestNewWrapsURLParseError` (it checks for `invalid base URL`), `TestNon2xxRedactsQueryValuesAndOmitsBody`, `TestTransportErrorRedactsQueryValues` and `TestRedactURLLeavesQuerylessURLUnchanged`.
- The full suite prints 8 `ok` lines.
- Lint prints `0 issues.`

- [ ] **Step 5: Commit**

```bash
cd "$WT"
git add httpx/client.go httpx/redact_test.go
git commit -m "fix: redact userinfo passwords and invalid base URLs in httpx errors" \
  -m "redactURL returned a URL with userinfo unchanged when it had no query, and u.String() kept the password when it did. It now masks the password with url.URL.Redacted and replaces an unparsable URL whole. New no longer echoes its input: a parse error carries the redacted *url.Error, and a missing scheme or host says so without the URL."
```

---

### Task 4: qBittorrent `Resume` on 4.x and 5.x

**Files:**
- Create: `qbittorrent/resume_test.go`
- Modify:
  - `qbittorrent/client.go`: `Resume` and its doc (line 201 on `main`, about line 227 after Task 1),
  - `qbittorrent/client_extra_test.go:281-284`, the `Resume` assertion in `TestReannounceAndResumeJoinHashes`.

**Interfaces:**
- Consumes: Task 1's `withAuth` (unchanged signature).
- Produces:
  - `(*HTTPClient).Resume(ctx context.Context, hashes []string) error`, same signature. It POSTs `/api/v2/torrents/start`, and on a 404 POSTs `/api/v2/torrents/resume`.
  - Test helpers `resumeServer` and `newResumeClient` (in `resume_test.go`).

Evidence and decision: see "qBittorrent `Resume`" under Decisions and evidence above.

- [ ] **Step 1: Write the failing tests**

Create `qbittorrent/resume_test.go`:

```go
package qbittorrent

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/parsoFish/arrkit/httpx"
)

// resumeServer answers torrents/start and torrents/resume with the given
// status codes, the way a qBittorrent 5.x server (start 200, resume 404) or
// 4.x server (start 404, resume 200) does, and records the hashes each
// endpoint receives. Login always succeeds.
type resumeServer struct {
	startStatus, resumeStatus int

	mu     sync.Mutex
	hashes map[string][]string // path -> hashes form values, in order
}

func (s *resumeServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/api/v2/auth/login":
		http.SetCookie(w, &http.Cookie{Name: "SID", Value: "abc", Path: "/"})
		_, _ = w.Write([]byte("Ok."))
	case "/api/v2/torrents/start", "/api/v2/torrents/resume":
		if err := r.ParseForm(); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		s.mu.Lock()
		s.hashes[r.URL.Path] = append(s.hashes[r.URL.Path], r.FormValue("hashes"))
		s.mu.Unlock()
		status := s.startStatus
		if r.URL.Path == "/api/v2/torrents/resume" {
			status = s.resumeStatus
		}
		w.WriteHeader(status)
	default:
		http.NotFound(w, r)
	}
}

func (s *resumeServer) seen(path string) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.hashes[path]...)
}

func newResumeClient(t *testing.T, startStatus, resumeStatus int) (*HTTPClient, *resumeServer) {
	t.Helper()
	qb := &resumeServer{startStatus: startStatus, resumeStatus: resumeStatus, hashes: map[string][]string{}}
	srv := httptest.NewServer(qb)
	t.Cleanup(srv.Close)
	c, err := New(srv.URL, "admin", "adminadmin")
	if err != nil {
		t.Fatal(err)
	}
	return c, qb
}

func TestResumeUsesStartOnQBittorrent5(t *testing.T) {
	c, qb := newResumeClient(t, http.StatusOK, http.StatusNotFound)
	if err := c.Resume(context.Background(), []string{"a", "b"}); err != nil {
		t.Fatal(err)
	}
	if got := qb.seen("/api/v2/torrents/start"); len(got) != 1 || got[0] != "a|b" {
		t.Errorf("torrents/start hashes = %q, want one call with a|b", got)
	}
	if got := qb.seen("/api/v2/torrents/resume"); len(got) != 0 {
		t.Errorf("torrents/resume called %d times, want 0 when start succeeds", len(got))
	}
}

func TestResumeFallsBackToResumeOnQBittorrent4(t *testing.T) {
	c, qb := newResumeClient(t, http.StatusNotFound, http.StatusOK)
	if err := c.Resume(context.Background(), []string{"a", "b"}); err != nil {
		t.Fatal(err)
	}
	if got := qb.seen("/api/v2/torrents/start"); len(got) != 1 {
		t.Errorf("torrents/start called %d times, want 1 (tried first)", len(got))
	}
	if got := qb.seen("/api/v2/torrents/resume"); len(got) != 1 || got[0] != "a|b" {
		t.Errorf("torrents/resume hashes = %q, want one call with a|b", got)
	}
}

func TestResumeDoesNotFallBackOnOtherErrors(t *testing.T) {
	c, qb := newResumeClient(t, http.StatusInternalServerError, http.StatusOK)
	err := c.Resume(context.Background(), []string{"a"})
	if !httpx.IsStatus(err, http.StatusInternalServerError) {
		t.Fatalf("Resume error = %v, want the start endpoint's HTTP 500", err)
	}
	if got := qb.seen("/api/v2/torrents/resume"); len(got) != 0 {
		t.Errorf("torrents/resume called %d times, want 0 after a non-404 error", len(got))
	}
}

func TestResumeFailsWhenNeitherEndpointExists(t *testing.T) {
	c, _ := newResumeClient(t, http.StatusNotFound, http.StatusNotFound)
	err := c.Resume(context.Background(), []string{"a"})
	if !httpx.IsStatus(err, http.StatusNotFound) {
		t.Fatalf("Resume error = %v, want HTTP 404", err)
	}
}
```

In `qbittorrent/client_extra_test.go`, in `TestReannounceAndResumeJoinHashes`, replace:

```go
	resume := findRequest(seen, "/api/v2/torrents/resume")
	if resume == nil || resume.FormValue("hashes") != "c" {
		t.Fatalf("resume request: %+v", resume)
	}
```

with:

```go
	start := findRequest(seen, "/api/v2/torrents/start")
	if start == nil || start.FormValue("hashes") != "c" {
		t.Fatalf("start request: %+v", start)
	}
```

`newQB`'s default case answers 200 for any unlisted path, `/torrents/start` included. So once the fix is in, this test sees a `start` request and no `resume`.

- [ ] **Step 2: Run them and watch them fail**

Run: `cd "$WT" && go test -count=1 -run Resume ./qbittorrent/`
Expected: FAIL in 4 tests:
- `TestReannounceAndResumeJoinHashes`: `start request: <nil>`.
- `TestResumeUsesStartOnQBittorrent5`: `qbittorrent resume: POST http://127.0.0.1:<port>/api/v2/torrents/resume: HTTP 404:`. This is the bug simplarr's pinned 5.2.3 would hit.
- `TestResumeFallsBackToResumeOnQBittorrent4`: `torrents/start called 0 times, want 1 (tried first)`.
- `TestResumeDoesNotFallBackOnOtherErrors`: `Resume error = <nil>, want the start endpoint's HTTP 500`.

`TestResumeFailsWhenNeitherEndpointExists` already passes, because today's code posts only to `resume`, which this server answers with 404. It pins the both-missing behaviour the fix must keep.

- [ ] **Step 3: Try `start`, fall back to `resume` on 404**

In `qbittorrent/client.go`, replace:

```go
// Resume resumes the given torrents.
func (c *HTTPClient) Resume(ctx context.Context, hashes []string) error {
	form := url.Values{"hashes": {strings.Join(hashes, "|")}}
	err := c.withAuth(ctx, func() error {
		return c.h.PostForm(ctx, apiBase+"/torrents/resume", form, nil)
	})
	if err != nil {
		return fmt.Errorf("qbittorrent resume: %w", err)
	}
	return nil
}
```

with:

```go
// Resume resumes the given torrents. qBittorrent 5.0 (WebAPI 2.11.0) renamed
// torrents/resume to torrents/start, and an endpoint a server does not have
// answers 404. Resume posts to start first and falls back to resume on a 404,
// so it works against 4.x and 5.x servers alike.
func (c *HTTPClient) Resume(ctx context.Context, hashes []string) error {
	form := url.Values{"hashes": {strings.Join(hashes, "|")}}
	err := c.withAuth(ctx, func() error {
		err := c.h.PostForm(ctx, apiBase+"/torrents/start", form, nil)
		if httpx.IsStatus(err, http.StatusNotFound) {
			return c.h.PostForm(ctx, apiBase+"/torrents/resume", form, nil)
		}
		return err
	})
	if err != nil {
		return fmt.Errorf("qbittorrent resume: %w", err)
	}
	return nil
}
```

The fallback sits inside `fn`, so a 403 on either endpoint still gets `withAuth`'s single session renewal and retry.

- [ ] **Step 4: Run the tests and watch them pass**

```bash
cd "$WT"
go test -count=1 -run Resume -v ./qbittorrent/ | grep -E '^(--- |ok|FAIL)'
go test -race -count=1 ./...
gofmt -l . ; go vet ./...
go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0 run
```

Expected: the 5 Resume tests show `--- PASS`, the full suite prints 8 `ok` lines, and lint prints `0 issues.` The Fake's `Resume` still records `Resume([a])`, so `TestFakeRecordsAllCallsAndPropagatesErr` is unchanged.

- [ ] **Step 5: Commit**

```bash
cd "$WT"
git add qbittorrent/client.go qbittorrent/resume_test.go qbittorrent/client_extra_test.go
git commit -m "fix: resume torrents via torrents/start with a 4.x fallback" \
  -m "qBittorrent 5.0 (WebAPI 2.11.0, qBittorrent PR #20532) renamed torrents/resume to torrents/start; an endpoint a server lacks answers 404, so Resume failed against 5.x (simplarr pins 5.2.3). Resume now posts to start and falls back to resume only on a 404, keeping 4.x servers working. Tests cover both paths, no fallback on other errors, and both endpoints missing."
```

---

### Task 5: Fixture scrub and a fixture scanner

**Files:**
- Create: `scripts/scan-fixtures.sh`, `scripts/scan-fixtures_test.sh` (both mode 100755)
- Modify: `sonarr/testdata/queue.json`, `sonarr/testdata/history.json`, `sonarr/testdata/series.json`, `radarr/testdata/history.json`, `radarr/testdata/movie.json`, `radarr/testdata/wanted_missing.json`
- Modify: `README.md:45`, the `Fixture rule:` paragraph

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `scripts/scan-fixtures.sh [ROOT]`. It scans every file under `*/testdata/*` below ROOT (default `.`, skipping `.git`). Exit 0: clean, and it prints `scan-fixtures: N fixture files clean`. Exit 1: hits, one `rule: file:line:match` line each, plus a count on stderr. Exit 2: usage error, no fixtures found, or a grep failure.
  - `scripts/scan-fixtures_test.sh`: exit 0 when every case passes, 1 otherwise.
  - Task 6 runs both in CI.

Plan 1's history scan ended in `sort -u`, so its exit code was always 0 and only the printed output showed a hit. These scripts set their exit codes themselves, and the self-test checks them.

- [ ] **Step 1: Write the scanner's self-test**

Create `scripts/scan-fixtures_test.sh`:

```bash
#!/usr/bin/env bash
# scan-fixtures_test.sh: self-check for scan-fixtures.sh. Each case builds a
# throwaway tree, runs the scanner on it and checks the exit code and output.
# Exit 0 when every case passes, 1 otherwise.
set -uo pipefail

SCAN="$(cd "$(dirname "$0")" && pwd)/scan-fixtures.sh"
WORK="$(mktemp -d)"
trap 'chmod -R u+rwX "$WORK"; rm -rf "$WORK"' EXIT
FAILS=0

# check NAME WANT_EXIT WANT_OUTPUT [ARG...]: run the scanner with ARGs and
# compare its exit code, and its combined output when WANT_OUTPUT is set.
check() {
  local name="$1" want_exit="$2" want_out="$3" out rc=0
  shift 3
  out="$("$SCAN" "$@" 2>&1)" || rc=$?
  if [ "$rc" -ne "$want_exit" ]; then
    echo "FAIL $name: exit $rc, want $want_exit; output: $out"
    FAILS=$((FAILS + 1))
  elif [ -n "$want_out" ] && [[ "$out" != *"$want_out"* ]]; then
    echo "FAIL $name: output lacks \"$want_out\": $out"
    FAILS=$((FAILS + 1))
  else
    echo "ok   $name"
  fi
}

# fixture NAME CONTENT: create $WORK/NAME/pkg/testdata/f.json holding CONTENT
# and print the tree's root.
fixture() {
  local root="$WORK/$1"
  mkdir -p "$root/pkg/testdata"
  printf '%s\n' "$2" >"$root/pkg/testdata/f.json"
  printf '%s' "$root"
}

# Built at run time so no hex run of the scanned lengths sits in this file.
HEX40="$(printf 'ab%.0s' {1..20})"
HEX32="$(printf 'cd%.0s' {1..16})"

check clean 0 "1 fixture files clean" "$(fixture clean '{"downloadId": "0000000000000000000000000000000000000001", "ip": "10.0.0.2", "email": "user1@example.com", "title": "Example.Show.S01E01.1080p-GROUP", "path": "/tv/Example Show/Season 01", "root": "/movies/#recycle"}')"
check infohash 1 "infohash: " "$(fixture infohash "{\"downloadId\": \"$HEX40\"}")"
check hex32 1 "hex32: " "$(fixture hex32 "{\"apiKey\": \"$HEX32\"}")"
check private-ip 1 "private-ip: " "$(fixture private-ip '{"host": "192.168.1.20"}')"
check email 1 "email: " "$(fixture email '{"email": "someone@mail.invalid"}')"
check home-path 1 "home-path: " "$(fixture home-path '{"path": "/home/someone/media"}')"
check release-name 1 "release-name: " "$(fixture release-name '{"title": "Some.Show.S01E01.1080p.WEB.h264-CREW"}')"
check fansub-release 1 "fansub-release: " "$(fixture fansub-release '{"title": "[SubGroup] Some Show - 01 (1080p)"}')"
check library-path 1 "library-path: " "$(fixture library-path '{"path": "/movies/Some Movie (2020)"}')"
check hit-count 1 "2 hit(s)" "$(fixture hit-count '{"a": "192.168.1.20", "b": "/tv/Some Show"}')"

mkdir -p "$WORK/empty/pkg"
check no-fixtures 2 "no files under" "$WORK/empty"
check not-a-directory 2 "not a directory" "$WORK/missing"
check too-many-args 2 "usage:" "$WORK/empty" "$WORK/empty"

if [ "$(id -u)" -ne 0 ]; then
  unreadable="$(fixture unreadable '{}')"
  chmod 000 "$unreadable/pkg/testdata/f.json"
  check unreadable-file 2 "grep failed" "$unreadable"
else
  echo "skip unreadable-file (root can read any file)"
fi

if [ "$FAILS" -ne 0 ]; then
  echo "scan-fixtures_test: $FAILS case(s) failed"
  exit 1
fi
echo "scan-fixtures_test: all cases passed"
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd "$WT"
chmod +x scripts/scan-fixtures_test.sh
scripts/scan-fixtures_test.sh; echo "exit=$?"
```

Expected: every case prints `FAIL <name>: exit 127, want ...` because the scanner does not exist yet. The last line is `scan-fixtures_test: 14 case(s) failed`, then `exit=1`.

- [ ] **Step 3: Write the scanner**

Create `scripts/scan-fixtures.sh`:

```bash
#!/usr/bin/env bash
# scan-fixtures.sh: fail when a fixture under */testdata/* carries data the
# README's fixture rule forbids. Needs bash 4.4+ (mapfile -d) and GNU grep.
#
# Usage: scripts/scan-fixtures.sh [ROOT]   (ROOT defaults to .)
# Exit:  0 clean; 1 hits found (one "rule: file:line:match" line each, on
#        stdout); 2 usage error, no fixtures found, or a grep failure.
set -euo pipefail

usage() {
  echo "usage: $0 [ROOT]" >&2
  exit 2
}
[ "$#" -le 1 ] || usage
ROOT="${1:-.}"
[ -d "$ROOT" ] || { echo "scan-fixtures: not a directory: $ROOT" >&2; exit 2; }

LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT
find "$ROOT" -name .git -prune -o -type f -path '*/testdata/*' -print0 >"$LIST"
mapfile -d '' FILES <"$LIST"
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "scan-fixtures: no files under */testdata/ in $ROOT" >&2
  exit 2
fi

HITS=0

# rule NAME PATTERN [ALLOW]: report every match of the extended regex PATTERN
# in the fixtures, except matches that also match the extended regex ALLOW.
rule() {
  local name="$1" pattern="$2" allow="${3:-}" out rc=0 line match
  out="$(grep -HnoE -e "$pattern" -- "${FILES[@]}")" || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "scan-fixtures: grep failed for rule $name (exit $rc)" >&2
    exit 2
  fi
  [ -n "$out" ] || return 0
  while IFS= read -r line; do
    match="${line#*:*:}"
    if [ -n "$allow" ] && [[ "$match" =~ $allow ]]; then
      continue
    fi
    printf '%s: %s\n' "$name" "$line"
    HITS=$((HITS + 1))
  done <<<"$out"
}

# Real torrent infohashes (v1 40-hex, v2 64-hex). Fakes are zero-padded.
rule infohash '\b([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})\b' '^0{30}'
# Real API keys and plex.direct certificate hashes (32-hex).
rule hex32 '\b[0-9A-Fa-f]{32}\b' '^0{24}'
# Private-network addresses other than the documented 10.0.0.x.
rule private-ip '\b(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}\b' '^10\.0\.0\.'
# Emails anywhere but the example domains.
rule email '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' '@example\.(com|net|org)$'
# Home directories.
rule home-path '/(home|Users)/[A-Za-z0-9._-]+'
# Scene release names: dotted name, resolution, -GROUP.
rule release-name '[A-Za-z0-9]+(\.[A-Za-z0-9]+)*\.(480p|576p|720p|1080p|2160p)(\.[A-Za-z0-9]+)*-[A-Za-z0-9]+' '^Example\.'
# Fansub release names: [Group] title ... resolution.
rule fansub-release '\[[^]"]+\] [^"]*(480p|576p|720p|1080p|2160p)'
# Library paths: a JSON string starting /tv/ or /movies/ with a title in it.
rule library-path '"/(tv|movies)/[^"/#][^"/]*' '^"/(tv|movies)/Example( |$)'

if [ "$HITS" -gt 0 ]; then
  echo "scan-fixtures: $HITS hit(s) in ${#FILES[@]} fixture files; scrub them (README, Fixture rule)" >&2
  exit 1
fi
echo "scan-fixtures: ${#FILES[@]} fixture files clean"
```

The rules are calibrated against every fixture on `main`. Only the six sonarr/radarr files below hit; the other 21 pass. qBittorrent's `A.Knight.S01E06.720p` is a deliberately synthetic name with no group, modelling a malware `.exe`, and passes the release-name rule. Plex's zero-padded `machineIdentifier` passes the infohash rule.

- [ ] **Step 4: Run the self-test and watch it pass**

```bash
cd "$WT"
chmod +x scripts/scan-fixtures.sh
scripts/scan-fixtures_test.sh; echo "exit=$?"
shellcheck scripts/*.sh; echo "shellcheck exit=$?"
```

Expected: 14 `ok` lines (or 13 plus `skip unreadable-file` when run as root), `scan-fixtures_test: all cases passed`, `exit=0` and `shellcheck exit=0`.

- [ ] **Step 5: Scan the real fixtures and watch them fail**

Run: `cd "$WT" && scripts/scan-fixtures.sh; echo "exit=$?"`
Expected: 35 hits, then `scan-fixtures: 35 hit(s) in 27 fixture files; ...` and `exit=1`:
- `infohash`: 6, in `sonarr/testdata/queue.json:41,83,125` and `sonarr/testdata/history.json:35,78,121`.
- `release-name`: 9, in `sonarr/testdata/history.json:11,39,54,82,97,125` (`The.Office.US...x265-RARBG`).
- `fansub-release`: 3, in `sonarr/testdata/queue.json:34,76,118` (`[HorribleSubs]`, `[KaiDubs]`).
- `library-path`: 17:
  - `sonarr/testdata/history.json:40,83,126`,
  - `sonarr/testdata/series.json:118,440,562`,
  - `radarr/testdata/movie.json:264,271,498,505,648,655`,
  - `radarr/testdata/history.json:10,46,86`,
  - `radarr/testdata/wanted_missing.json:41,48`.

- [ ] **Step 6: Confirm no test asserts on the values being replaced**

```bash
cd "$WT"
git grep -n -F \
 -e 937D86960C7200B30A1FAD02338B54813A07336A -e BD23C00251A6DBF500E77DFA5E40BD2642EA9D5E \
 -e 51C73AB200889665D58ADE2EA619930BE89C4DCE -e 505687740A6466441C1ACDA208790D8F5DEBB4C2 \
 -e HorribleSubs -e KaiDubs -e The.Office.US -e 'The Office (US)' -e RARBG -e YTS.MX -e MIRCrew \
 -e 'Hot Girl' -e Basketball -e 'The Alliance' \
 -e '/movies/American Psycho' -e '/movies/Get Out' -e '/movies/Peaky Blinders' -e '/movies/Inside Out 2' \
 -e '/movies/The Dark Knight' -e '/movies/The Greatest Beer Run Ever' -e '/movies/Zodiac' \
 -e '/tv/Breaking Bad' -e '/tv/King of the Hill' -e '/tv/Adolescence' \
 -- . ':(exclude)*/testdata/*'; echo "exit=$?"
```

Expected: no output and `exit=1`. No file outside `testdata/` mentions any replaced value. This was checked on `origin/main` while planning.

The tests that load these fixtures assert only shape:
- `sonarr`: `TestQueueFlattensMessages` (`items[0].DownloadID != ""`), `TestHistoryFiltersSince` (`len > 0`, and the since filter), `TestSeriesStatistics` (`EpisodeCount`).
- `radarr`: `TestHistoryFiltersSince`, `TestMovies` (`Title != ""`), `TestWantedMissingCount`.

No expected value changes. If the grep prints anything, update that test's expected value in this same step, to the replacement in Step 7.

- [ ] **Step 7: Scrub the six fixtures**

Only string values change: no keys, numbers, dates or record counts.
- The three season-pack history records keep one shared `downloadId`.
- Titles stay. They are public catalogue metadata and are not one of the three kinds being scrubbed.
- Every replacement is an obviously fake value of the user's choosing: `0000…000N`, `Example.Show.S01E06.1080p-GROUP`, `/tv/Example Show/Season 01`, `/movies/Example Movie N (year)`.

```bash
cd "$WT"
sed -i \
 -e 's/937D86960C7200B30A1FAD02338B54813A07336A/0000000000000000000000000000000000000001/' \
 -e 's/BD23C00251A6DBF500E77DFA5E40BD2642EA9D5E/0000000000000000000000000000000000000002/' \
 -e 's/51C73AB200889665D58ADE2EA619930BE89C4DCE/0000000000000000000000000000000000000003/' \
 -e 's/"\[HorribleSubs\] Kimetsu no Yaiba - 20 (1080p)"/"Example.Show.S01E20.1080p-GROUP"/' \
 -e 's/"\[KaiDubs\] Demon Slayer (Kimetsu no Yaiba) - 21 \[1080p\] \[English Dub\] \[CC\] \[AS-DL\] \[CE08D4AA\]"/"Example.Show.S01E21.1080p-GROUP"/' \
 -e 's/"\[KaiDubs\] Demon Slayer (Kimetsu no Yaiba) - 09 \[1080p\] \[English Dub\] \[CC\] \[AS-DL\] \[515E3422\]"/"Example.Show.S01E09.1080p-GROUP"/' \
 sonarr/testdata/queue.json
sed -i \
 -e 's/505687740A6466441C1ACDA208790D8F5DEBB4C2/0000000000000000000000000000000000000004/' \
 -e 's/The\.Office\.US\./Example.Show./g' \
 -e 's/\.BluRay\.x265-RARBG/-GROUP/g' \
 -e 's#/tv/The Office (US)/Season 1/The Office (US) - #/tv/Example Show/Season 01/Example Show - #' \
 -e 's/ - Hot Girl / - Episode Six /' -e 's/ - Basketball / - Episode Five /' -e 's/ - The Alliance / - Episode Four /' \
 -e 's/"releaseGroup": "RARBG"/"releaseGroup": "GROUP"/' \
 sonarr/testdata/history.json
sed -i \
 -e 's#"/tv/Breaking Bad"#"/tv/Example Show 1"#' \
 -e 's#"/tv/King of the Hill"#"/tv/Example Show 2"#' \
 -e 's#"/tv/Adolescence"#"/tv/Example Show 3"#' \
 sonarr/testdata/series.json
sed -i \
 -e 's#"/movies/American Psycho (2000)/American Psycho (2000) #"/movies/Example Movie 5 (2000)/Example Movie 5 (2000) #' \
 -e 's#"/movies/Get Out (2017)/Get Out (2017) #"/movies/Example Movie 6 (2017)/Example Movie 6 (2017) #' \
 -e 's#"/movies/Peaky Blinders - The Immortal Man (2026)/Peaky Blinders - The Immortal Man (2026) #"/movies/Example Movie 7 (2026)/Example Movie 7 (2026) #' \
 -e 's/"releaseGroup": "YTS\.MX"/"releaseGroup": "GROUP"/' \
 -e 's/"releaseGroup": "MIRCrew"/"releaseGroup": "GROUP"/' \
 radarr/testdata/history.json
sed -i \
 -e 's#"/movies/Inside Out 2 (2024)"#"/movies/Example Movie 1 (2024)"#' \
 -e 's#"/movies/The Dark Knight (2008)"#"/movies/Example Movie 2 (2008)"#' \
 -e 's#"/movies/The Greatest Beer Run Ever (2022)"#"/movies/Example Movie 3 (2022)"#' \
 radarr/testdata/movie.json
sed -i -e 's#"/movies/Zodiac (2007)"#"/movies/Example Movie 4 (2007)"#' radarr/testdata/wanted_missing.json
git diff --stat
```

Expected `git diff --stat`, 38 insertions and 38 deletions in total:

```
 radarr/testdata/history.json        | 12 ++++++------
 radarr/testdata/movie.json          | 12 ++++++------
 radarr/testdata/wanted_missing.json |  4 ++--
 sonarr/testdata/history.json        | 30 +++++++++++++++---------------
 sonarr/testdata/queue.json          | 12 ++++++------
 sonarr/testdata/series.json         |  6 +++---
```

For example, a sonarr history record now reads `"sourceTitle": "Example.Show.S01E06.1080p-GROUP"`, `"downloadId": "0000000000000000000000000000000000000004"`, `"droppedPath": "/downloads/tv/Example.Show.S01.1080p-GROUP/Example.Show.S01E06.1080p-GROUP.mp4"` and `"importedPath": "/tv/Example Show/Season 01/Example Show - S01E06 - Episode Six Bluray-1080p.mp4"`.

- [ ] **Step 8: Rescan and rerun the tests**

```bash
cd "$WT"
for f in $(git diff --name-only -- '*/testdata/*'); do jq empty "$f" || echo "BAD JSON $f"; done
scripts/scan-fixtures.sh; echo "exit=$?"
go test -race -count=1 ./...
```

Expected:
- No `BAD JSON` line. If `jq` is missing, use `python3 -m json.tool "$f" >/dev/null` instead.
- `scan-fixtures: 27 fixture files clean` and `exit=0`.
- 8 `ok` lines.

- [ ] **Step 9: Add the new kinds to the README's fixture rule**

In `README.md`, replace the paragraph:

```markdown
Fixture rule: anything added under `testdata/` must be scrubbed before you commit it. That means no real hostnames, addresses, emails, API keys, tokens or `plex.direct` hashes. Use `example.com`, `10.0.0.x` or `192.0.2.x` and obviously fake IDs instead.
```

with:

```markdown
Fixture rule: anything added under `testdata/` must be scrubbed before you commit it. That means no real hostnames, addresses, emails, API keys, tokens, `plex.direct` hashes, torrent infohashes, release names or library paths. Use `example.com`, `10.0.0.x` or `192.0.2.x`, zero-padded hashes (`0000000000000000000000000000000000000001`), `Example.Show.S01E01.1080p-GROUP` and `/tv/Example Show/Season 01` instead. `scripts/scan-fixtures.sh` checks fixtures for infohashes, 32-hex keys, private addresses, emails, home paths, release names and library paths.
```

- [ ] **Step 10: Commit**

```bash
cd "$WT"
git add scripts/scan-fixtures.sh scripts/scan-fixtures_test.sh README.md \
  sonarr/testdata/queue.json sonarr/testdata/history.json sonarr/testdata/series.json \
  radarr/testdata/history.json radarr/testdata/movie.json radarr/testdata/wanted_missing.json
git ls-files -s scripts/
git commit -m "test: scrub real release data from fixtures and add a fixture scanner" \
  -m "Replaces the real torrent infohashes, release names and library paths in the sonarr and radarr fixtures with obviously fake values (current files only; no history rewrite). No test asserted on them. Adds scripts/scan-fixtures.sh, which fails with exit 1 when a fixture carries such data, and a self-test that checks every rule and exit code. The README fixture rule names the new kinds."
```

Expected: `git ls-files -s scripts/` shows mode `100755` for both scripts. If it shows `100644`, run `git update-index --chmod=+x scripts/*.sh` and amend before going on.

---

### Task 6: CI on Node 24, pinned lint, read-only token, fixture scan

**Files:**
- Modify: `.github/workflows/ci.yml` (whole file)

**Interfaces:**
- Consumes: `scripts/scan-fixtures.sh` and `scripts/scan-fixtures_test.sh` from Task 5 (exit 0 means pass).
- Produces: job id `test`, the required status check on `main`. Task 8's PR must pass it.

There is no red step: this is configuration. `actionlint` checks it locally and the PR run in Task 8 is its test.

- [ ] **Step 1: Write the workflow**

Replace `.github/workflows/ci.yml` with:

```yaml
name: ci
on:
  push: { branches: [main] }
  pull_request:
permissions:
  contents: read
jobs:
  # The job name is the required status check on main's ruleset: keep it "test".
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7.0.1
      - uses: actions/setup-go@v7.0.0
        with:
          go-version: "1.25"
          # arrkit is stdlib-only, so there is no go.sum to key a module cache on.
          cache: false
      - name: go.mod is tidy
        run: go mod tidy -diff
      - run: go vet ./...
      - run: go test ./... -race -cover
      - name: Shell scripts pass shellcheck
        run: shellcheck scripts/*.sh
      - name: Fixture scanner self-check
        run: scripts/scan-fixtures_test.sh
      - name: Fixtures are scrubbed
        run: scripts/scan-fixtures.sh
      - uses: golangci/golangci-lint-action@v9.3.0
        with:
          version: v2.15.0
```

`shellcheck` comes preinstalled on the `ubuntu-latest` image (Ubuntu 24.04 image `20261111.370.1` lists shellcheck 0.9.0). The tags are explained under "CI action versions" above.

- [ ] **Step 2: Lint the workflow and run each step locally**

```bash
cd "$WT"
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12 .github/workflows/ci.yml; echo "actionlint exit=$?"
grep -n -E '^  test:$' .github/workflows/ci.yml
go mod tidy -diff; echo "tidy exit=$?"
go vet ./... && go test ./... -race -cover
shellcheck scripts/*.sh && scripts/scan-fixtures_test.sh && scripts/scan-fixtures.sh
go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0 run
git status --short
```

Expected:
- `actionlint exit=0` with no findings.
- The `grep` prints `9:  test:`.
- `tidy exit=0`. 8 `ok` lines with coverage.
- The scanner lines end `all cases passed` and `27 fixture files clean`.
- Lint prints `0 issues.`
- `git status --short` lists only `M .github/workflows/ci.yml`: none of the `go run` tools touched `go.mod`.

- [ ] **Step 3: Commit**

```bash
cd "$WT"
git add .github/workflows/ci.yml
git commit -m "ci: pin golangci-lint, move actions to Node 24, scan fixtures" \
  -m "Pins golangci-lint to v2.15.0 (was latest) and moves to Node 24 action releases: checkout v7.0.1, setup-go v7.0.0, golangci-lint-action v9.3.0. Adds permissions: contents: read, turns off setup-go's module cache (no go.sum to key it on), and runs shellcheck, the fixture scanner's self-check and the scanner itself. The job stays named test, the required check on main."
```

---

### Task 7: README, wording and compiled examples

**Files:**
- Create: `radarr/example_test.go`
- Modify:
  - `README.md` (whole file),
  - `qbittorrent/client.go`: the `rawPreferences` doc comment,
  - `qbittorrent/types.go:43-46`,
  - the header comments in `prowlarr/client_extra_test.go:12`, `qbittorrent/client_extra_test.go:13`, `radarr/client_extra_test.go:12` and `sonarr/client_extra_test.go:12`.

**Interfaces:**
- Consumes:
  - `radarr.New(baseURL, apiKey string, opts ...httpx.Option) (*radarr.HTTPClient, error)`,
  - `(*radarr.HTTPClient).Health(ctx) ([]radarr.HealthItem, error)`, where `HealthItem` has `Type`, `Source` and `Message`,
  - `radarr.Fake{Missing int; Calls []string}` and `(*radarr.Fake).WantedMissingCount`.
  - Task 3's redaction semantics, Task 4's Resume behaviour, Task 5's fixture-rule paragraph, and Task 6's lint pin and CI scan.
- Produces: `ExampleNew` and `ExampleFake` in package `radarr_test`.

There is no red step: this task is docs. The examples are executable, `go test` checks their output, and Step 5 compiles the README's Go blocks.

- [ ] **Step 1: Fix the remaining healarr wording**

In `prowlarr/client_extra_test.go`, `qbittorrent/client_extra_test.go`, `radarr/client_extra_test.go` and `sonarr/client_extra_test.go`, replace:

```go
// These tests supplement the brief's verbatim client_test.go to reach the
```

with:

```go
// These tests supplement client_test.go to reach the
```

In `qbittorrent/types.go`, replace:

```go
// Its fields carry camelCase json tags for --json output; qBittorrent's own
// wire format uses snake_case, so decoding goes through rawPreferences (see
// client.go) instead of these tags.
```

with:

```go
// Its fields carry camelCase json tags for callers' JSON output;
// qBittorrent's own wire format uses snake_case, so decoding goes through
// rawPreferences (see client.go) instead of these tags.
```

In `qbittorrent/client.go`, replace:

```go
// Preferences itself carries camelCase json tags for --json output, so
// decoding goes through this private type instead.
```

with:

```go
// Preferences itself carries camelCase json tags for callers' JSON output,
// so decoding goes through this private type instead.
```

- [ ] **Step 2: Write the compiled examples**

Create `radarr/example_test.go`:

```go
package radarr_test

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"net/http/httptest"

	"github.com/parsoFish/arrkit/radarr"
)

// ExampleNew lists Radarr's health warnings. The httptest server stands in
// for a real Radarr; in your code the base URL is e.g. http://radarr:7878.
func ExampleNew() {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`[{"source":"IndexerStatusCheck","type":"warning","message":"Indexers unavailable"}]`))
	}))
	defer srv.Close()

	c, err := radarr.New(srv.URL, "your-api-key")
	if err != nil {
		log.Fatal(err)
	}
	items, err := c.Health(context.Background())
	if err != nil {
		log.Fatal(err)
	}
	for _, it := range items {
		fmt.Printf("%s %s: %s\n", it.Type, it.Source, it.Message)
	}
	// Output: warning IndexerStatusCheck: Indexers unavailable
}

// ExampleFake stands in for Radarr in a caller's unit test: seed the fields
// the code under test reads, pass the Fake as a radarr.Client, then check
// Calls.
func ExampleFake() {
	f := &radarr.Fake{Missing: 3}
	var c radarr.Client = f

	n, err := c.WantedMissingCount(context.Background())
	fmt.Println(n, err)
	fmt.Println(f.Calls)
	// Output:
	// 3 <nil>
	// [WantedMissingCount()]
}
```

- [ ] **Step 3: Run the examples**

Run: `cd "$WT" && go test -count=1 -run Example -v ./radarr/ | grep -E '^(--- |ok|FAIL)'`
Expected: `--- PASS: ExampleNew`, `--- PASS: ExampleFake`, `ok`.

- [ ] **Step 4: Rewrite the README**

Replace `README.md` with exactly this content. The `Fixture rule:` paragraph is Task 5's, with one clause added about CI:

````markdown
# arrkit

Go clients for the services in a Plex + *arr media stack: Radarr, Sonarr, Prowlarr, Overseerr, qBittorrent, Plex and Tautulli.

Each package gives you:

- a `Client` interface with the package's own request and response types,
- an `HTTPClient` that talks to the real service over the shared `httpx` client,
- an in-memory `Fake` that implements `Client`, for callers' unit tests,
- golden JSON fixtures in `testdata/`, captured from live services and scrubbed.

arrkit has no third-party dependencies.

It was extracted from [healarr](https://github.com/parsoFish/healarr), which uses it. [simplarr](https://github.com/parsoFish/simplarr) will use it for its control-plane UI.

## Packages

| Package | Service | Auth |
|---|---|---|
| `httpx` | shared JSON/form HTTP client: URL redaction in errors (see [Errors](#errors)), timeouts, TLS server name | — |
| `radarr`, `sonarr` | Radarr v3 API, Sonarr v3 API | `X-Api-Key` |
| `prowlarr` | Prowlarr v1 API | `X-Api-Key` |
| `overseerr` | Overseerr v1 API | `X-Api-Key` |
| `qbittorrent` | qBittorrent WebUI v2 API, 4.x and 5.x | username + password, cookie session |
| `plex` | Plex Media Server | `X-Plex-Token` |
| `tautulli` | Tautulli v2 API | `apikey` query parameter, redacted in errors |

Every `HTTPClient` is safe for concurrent use, and so is every `Fake`.

qBittorrent 5.0 renamed `torrents/resume` to `torrents/start`. `Resume` tries `start` and falls back to `resume` on a 404, so it works on 4.x and 5.x. Torrent `State` values are passed through as the server sends them: 5.x reports `stoppedUP` where 4.x reported `pausedUP`.

## Usage

```go
package main

import (
	"context"
	"fmt"
	"log"
	"os"

	"github.com/parsoFish/arrkit/radarr"
)

func main() {
	c, err := radarr.New("http://radarr:7878", os.Getenv("RADARR_API_KEY"))
	if err != nil {
		log.Fatal(err)
	}
	items, err := c.Health(context.Background())
	if err != nil {
		log.Fatal(err)
	}
	for _, it := range items {
		fmt.Printf("%s %s: %s\n", it.Type, it.Source, it.Message)
	}
}
```

`radarr/example_test.go` runs the same code against a test server, so `go test` keeps it compiling.

## Fakes in your tests

Hand a `Fake` to the code under test wherever it takes a `Client`. Seed the fields it reads, set `Err` to make every method fail, and check `Calls` afterwards:

```go
package mycheck_test

import (
	"context"
	"testing"

	"github.com/parsoFish/arrkit/radarr"
)

func TestMissingCount(t *testing.T) {
	f := &radarr.Fake{Missing: 3}
	var c radarr.Client = f // what the code under test receives

	n, err := c.WantedMissingCount(context.Background())
	if err != nil || n != 3 {
		t.Fatalf("WantedMissingCount = %d, %v", n, err)
	}
	if len(f.Calls) != 1 || f.Calls[0] != "WantedMissingCount()" {
		t.Fatalf("Calls = %v", f.Calls)
	}
}
```

A `Fake`'s methods can be called from many goroutines at once. Read `Calls` only after those calls have returned.

## Errors

`httpx` puts every URL through one redaction step before it reaches an error:

- query parameter values become `REDACTED` (the names are kept),
- a userinfo password becomes `xxxxx` (the username is kept),
- a URL that does not parse is replaced whole.

That covers the `URL` field and message of `*httpx.APIError`, transport errors (including the `*url.Error` the standard library wraps), and `httpx.New`'s invalid-base-URL errors, which never echo the input. When a failed request carried a query string, `APIError.Body` is a placeholder, because a server may echo its query back.

Not redacted: the body of a failed request without a query string (`APIError.Body`; the message shows its first 200 bytes) and the first 200 bytes of a response that fails to decode. Header values, including `X-Api-Key`, `X-Plex-Token` and the qBittorrent session cookie, are never put in an error.

## Working across repositories

To try an arrkit change in healarr or simplarr before it is tagged, put both checkouts in a Go workspace. From the folder that holds them:

```bash
go work init ./healarr ./arrkit        # simplarr: go work init ./simplarr/app ./arrkit
cd healarr && go test ./...            # builds against ../arrkit, not the pinned tag
```

`go env GOWORK` shows the workspace in use, and `GOWORK=off` ignores it. The `go.work` file sits outside both repositories, so nothing is committed. Once the arrkit change is tagged, bump the dependency with `go get github.com/parsoFish/arrkit@<tag>` and delete `go.work`.

## Tests

```bash
go test ./... -race -cover
go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0 run   # the version CI pins
scripts/scan-fixtures_test.sh && scripts/scan-fixtures.sh
```

Fixture rule: anything added under `testdata/` must be scrubbed before you commit it. That means no real hostnames, addresses, emails, API keys, tokens, `plex.direct` hashes, torrent infohashes, release names or library paths. Use `example.com`, `10.0.0.x` or `192.0.2.x`, zero-padded hashes (`0000000000000000000000000000000000000001`), `Example.Show.S01E01.1080p-GROUP` and `/tv/Example Show/Season 01` instead. `scripts/scan-fixtures.sh` checks fixtures for infohashes, 32-hex keys, private addresses, emails, home paths, release names and library paths, and CI runs it on every push and pull request.

## Stability

arrkit is pre-1.0. Breaking changes can land in minor versions, and each one is called out in the [release notes](https://github.com/parsoFish/arrkit/releases).
````

Each README claim was checked against the code while planning:
- Every other `HTTPClient` holds only an immutable `*httpx.Client`, plus Tautulli's API key.
- Plex and the arr apps send their keys as headers.
- `APIError.Error()` truncates the body to 200 bytes, and `decode` quotes 200.

- [ ] **Step 5: Compile the README's Go blocks against this branch**

```bash
cd "$WT"
CHK="$(mktemp -d)"
mkdir -p "$CHK/mycheck"
awk '/^```go$/{n++; f=1; next} /^```$/{f=0} f && n==1' README.md >"$CHK/main.go"
awk '/^```go$/{n++; f=1; next} /^```$/{f=0} f && n==2' README.md >"$CHK/mycheck/mycheck_test.go"
printf 'package mycheck\n' >"$CHK/mycheck/doc.go"
(cd "$CHK" && go mod init example.com/readme && go work init . "$WT" && go vet ./... && go test ./...)
echo "exit=$?"
rm -rf "$CHK"   # deletes only the scratch module made above
```

Expected:
- `ok  example.com/readme/mycheck` and `exit=0`.
- `example.com/readme` prints `[no test files]`.

This also exercises the README's `go.work` advice. The block's last line deletes its own scratch module; say so before running it.

- [ ] **Step 6: Final wording and gate check**

```bash
cd "$WT"
git grep -n -i -E 'check engine|phase [0-9]|the brief|check run|--json' ; echo "exit=$?"
git grep -n -i 'healarr' -- ':!README.md' ; echo "exit=$?"
git grep -n -i 'healarr' -- README.md
gofmt -l . ; go vet ./... && go test ./... -race -count=1
scripts/scan-fixtures.sh
go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0 run
```

Expected:
- The first two greps print nothing and `exit=1`.
- The README grep prints only these lines:
  - line 14: the provenance and used-by sentence,
  - the "Working across repositories" paragraph, which mentions healarr,
  - the two `go work` command lines.
- 8 `ok` lines, `27 fixture files clean`, lint `0 issues.`

- [ ] **Step 7: Commit**

```bash
cd "$WT"
git add README.md radarr/example_test.go qbittorrent/client.go qbittorrent/types.go \
  prowlarr/client_extra_test.go qbittorrent/client_extra_test.go radarr/client_extra_test.go sonarr/client_extra_test.go
git commit -m "docs: compiled examples, go.work and exact redaction scope in README" \
  -m "The README usage snippet is now a complete program, mirrored by radarr/example_test.go (ExampleNew, ExampleFake) so go test compiles it. Adds a Fake section, a go.work section and an Errors section that states exactly what httpx redacts and what it does not. 'Used by' now says healarr uses arrkit and simplarr will. Drops the remaining healarr-specific wording (--json output, the brief's verbatim) from comments."
```

---

### Task 8: Release v0.1.1

**Files:**
- None in the repository. This task is GitHub: a PR into `main`, the tag `v0.1.1`, and the GitHub Releases `v0.1.0` and `v0.1.1`. The user approved this merge and tag on 2026-11-14.

Steps 5–8 use `PR` and `MERGE`. If your shell does not keep variables between calls, set them again at the top of each block:

```bash
PR="$(gh pr view fix/v0.1.1-hardening --repo parsoFish/arrkit --json number --jq .number)"
MERGE="$(gh pr view "$PR" --repo parsoFish/arrkit --json mergeCommit --jq .mergeCommit.oid)"   # after Step 6
```

**Interfaces:**
- Consumes: branch `fix/v0.1.1-hardening` holding Tasks 1–7 (7 commits on top of `ccd803b`).
- Produces: `github.com/parsoFish/arrkit@v0.1.1`, resolvable through `proxy.golang.org`, with GitHub Releases for v0.1.0 and v0.1.1. Plan 3 pins this tag.

- [ ] **Step 1: Final local gate**

```bash
cd "$WT"
git status --short ; git log --oneline origin/main..HEAD
go mod tidy -diff && go vet ./... && go test ./... -race -cover
shellcheck scripts/*.sh && scripts/scan-fixtures_test.sh && scripts/scan-fixtures.sh
go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0 run
```

Expected:
- A clean status and 7 commits: `fix:` ×4, `test:`, `ci:`, `docs:`.
- 8 `ok` lines. The scanner lines are clean. Lint prints `0 issues.`

- [ ] **Step 2: healarr still builds and passes against this branch, unchanged**

This uses a throwaway clone; the healarr checkout is never touched. `go.work` points healarr's import of arrkit at this worktree.

```bash
CHK="$(mktemp -d)"
git clone -q https://github.com/parsoFish/healarr.git "$CHK/healarr"
(cd "$CHK/healarr" && GOWORK=off go test ./... -race 2>&1 | tee "$CHK/before.txt" | grep -v -E '^(ok|\?)')
(cd "$CHK" && go work init ./healarr "$WT")
(cd "$CHK/healarr" && go env GOWORK && go vet ./... && go test ./... -race 2>&1 | tee "$CHK/after.txt" | grep -v -E '^(ok|\?)')
grep -c '^ok' "$CHK/before.txt" "$CHK/after.txt"
rm -rf "$CHK"   # deletes only the scratch clone made above
```

Expected:
- Neither test run prints a non-`ok` line.
- `go env GOWORK` prints `$CHK/go.work`. `go vet` is silent; that includes copylocks, so no healarr code copies a `Fake`.
- Both files show the same `ok` count (21 at healarr `a0d5b6d`).

If anything fails, stop: v0.1.1 would break healarr, so it is not a patch. The block's last line deletes its own scratch clone; say so before running it.

- [ ] **Step 3: The API is unchanged (gorelease)**

```bash
cd "$WT"
go run golang.org/x/exp/cmd/gorelease@v0.0.0-20261113113407-e3970619a1a4 -base=v0.1.0 -version=v0.1.1
```

Expected:
- The output ends `# summary` / `v0.1.1 is a valid semantic version for this release.`
- There is no `Incompatible changes` section and no `Compatible changes` section. Either would mean the API changed: stop and report it.
- The tool needs Go 1.26 and downloads it itself. It needs a clean worktree.

- [ ] **Step 4: Push the branch and open the PR**

```bash
cd "$WT"
git push -u origin fix/v0.1.1-hardening
gh pr create --repo parsoFish/arrkit --base main --head fix/v0.1.1-hardening \
  --title "fix: v0.1.1 hardening (concurrency, redaction, qBittorrent 5 resume, fixture scrub)" \
  --body "$(cat <<'EOF'
Patch release v0.1.1. It fixes what the arrkit v0.1.0 final review found. No API changes: gorelease against v0.1.0 reports v0.1.1 as a valid patch, and healarr main builds and passes its suite against this branch unchanged (checked through go.work).

- **qbittorrent:** `HTTPClient` is safe for concurrent use. Login is serialised, concurrent callers share one session, and a 403 renews the session once. Covered by `-race` tests with 8 concurrent callers.
- **qbittorrent:** `Resume` posts to `torrents/start`, which qBittorrent 5.0 renamed it to (WebAPI 2.11.0, qBittorrent PR #20532). On a 404 it falls back to `torrents/resume`, for 4.x. simplarr pins 5.2.3, where the old endpoint answers 404.
- **Fakes (all 7):** `Calls` is guarded by an unexported mutex. There is a `-race` concurrent-use test per package.
- **httpx:** error URLs mask userinfo passwords (`xxxxx`) as well as query values. A URL that does not parse is replaced whole, and `New` no longer echoes its input.
- **Fixtures:** the real torrent infohashes, release names and library paths in the sonarr and radarr fixtures are replaced with obviously fake values. This covers current files only; history is not rewritten. No test asserted on them.
- **scripts/scan-fixtures.sh:** new, with a self-test. It fails CI with exit 1 on such data. Plan 1's scan exited 0 even on hits.
- **CI:**
  - golangci-lint pinned to v2.15.0.
  - Node 24 actions: checkout v7.0.1, setup-go v7.0.0, golangci-lint-action v9.3.0.
  - `permissions: contents: read`, and no setup-go module cache.
  - New steps: shellcheck and the fixture scan. The job is still named `test`.
- **README:** a compiled usage example and a Fake example (`radarr/example_test.go`), a `go.work` section, the exact redaction scope, accurate "used by" wording, and the wider fixture rule.
- **Wording:** the healarr-specific phrases are gone from the comments.

Deletions: none in the tree. After the merge, the branch `fix/v0.1.1-hardening` is deleted.

Design: simplarr `docs/superpowers/plans/2026-11-14-control-plane-ui-01b-arrkit-hardening.md`.
EOF
)"
PR="$(gh pr view fix/v0.1.1-hardening --repo parsoFish/arrkit --json number --jq .number)"; echo "PR=$PR"
```

The body has no attribution footer, per the user's rule.

- [ ] **Step 5: Wait for CI**

```bash
gh pr checks "$PR" --repo parsoFish/arrkit --watch
PRRUN="$(gh run list --repo parsoFish/arrkit --branch fix/v0.1.1-hardening --event pull_request --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run view "$PRRUN" --repo parsoFish/arrkit
```

Expected:
- `test` passes.
- `gh run view` lists no annotations. v0.1.0's run had warnings for the Node 20 deprecation and the setup-go cache, and both should be gone.
- If `test` fails, fix it on the branch with a new commit, push, and watch again. Never merge on red.

- [ ] **Step 6: Merge with a merge commit**

```bash
gh pr merge "$PR" --repo parsoFish/arrkit --merge
gh pr view "$PR" --repo parsoFish/arrkit --json state,mergeCommit --jq '.state + " " + .mergeCommit.oid'
```

Expected: `MERGED <sha>`.
- `--delete-branch` is left off on purpose. The branch is still checked out in the worktree, so `gh`'s local branch deletion would fail and could stop before the remote branch is deleted. Step 11 removes both explicitly.
- If GitHub refuses the merge under the ruleset, stop and report its exact message. There is no bypass, and `--admin` must not be used.

- [ ] **Step 7: Wait for `main`'s CI on the merge commit**

```bash
MERGE="$(gh pr view "$PR" --repo parsoFish/arrkit --json mergeCommit --jq .mergeCommit.oid)"
RUN="$(gh run list --repo parsoFish/arrkit --commit "$MERGE" --event push --json databaseId --jq '.[0].databaseId')"; echo "RUN=$RUN"
gh run watch "$RUN" --repo parsoFish/arrkit --exit-status
```

Expected: the run succeeds. If `RUN` prints empty, the push run has not been queued yet: run the `gh run list` line again until it prints an id.

- [ ] **Step 8: Tag v0.1.1 on the merge commit**

```bash
cd "$ARRKIT"
git fetch -q origin
[ "$(git rev-parse origin/main)" = "$MERGE" ] && echo "origin/main is the merge commit"
git cat-file -p "$MERGE" | grep -c '^parent'
git tag -a v0.1.1 "$MERGE" -m "arrkit v0.1.1: concurrency-safe qBittorrent client and Fakes, URL redaction, qBittorrent 5 resume, scrubbed fixtures"
git push origin v0.1.1
git ls-remote --tags origin 'v0.1.*'
```

Expected:
- `origin/main is the merge commit`, and the parent count is `2`.
- The tag push succeeds; the ruleset covers `refs/heads/main` only.
- `ls-remote` lists `v0.1.0`, `v0.1.0^{}`, `v0.1.1` and `v0.1.1^{}`, with `v0.1.1^{}` equal to `$MERGE`.

- [ ] **Step 9: GitHub Releases for v0.1.0 and v0.1.1**

```bash
gh release create v0.1.0 --repo parsoFish/arrkit --verify-tag --title "v0.1.0" --latest=false --notes-file - <<'EOF'
First release: the service clients extracted from healarr's `internal/clients`, with their git history.

- Packages: `httpx`, `radarr`, `sonarr`, `prowlarr`, `overseerr`, `qbittorrent`, `plex`, `tautulli`.
- Each service package has a `Client` interface, an `HTTPClient` and an in-memory `Fake`, with golden JSON fixtures.
- Standard library only. MIT licence.

Known issues, all fixed in v0.1.1:
- `qbittorrent.HTTPClient` and the `Fake`s were not safe for concurrent use.
- `httpx` errors could show a userinfo password or an invalid base URL.
- `qbittorrent` `Resume` called `torrents/resume`, which qBittorrent 5.x answers with 404.
EOF
gh release create v0.1.1 --repo parsoFish/arrkit --verify-tag --title "v0.1.1" --latest --notes-file - <<'EOF'
Patch release. No API changes: every exported name and signature is the same as in v0.1.0 (checked with gorelease), and healarr builds against it unchanged.

Fixes
- `qbittorrent`: `HTTPClient` is safe for concurrent use. Login is serialised, concurrent callers share one session, and an expired session is renewed once.
- `qbittorrent`: `Resume` posts to `torrents/start` (qBittorrent 5.0+, WebAPI 2.11.0) and falls back to `torrents/resume` on a 404 (4.x).
- All packages: `Fake` is safe for concurrent use; `Calls` is guarded by a mutex.
- `httpx`: error URLs mask userinfo passwords (`xxxxx`) as well as query values. A URL that does not parse is replaced whole, and `New`'s invalid-base-URL errors no longer echo the input.

Fixtures and tooling
- sonarr and radarr fixtures: real torrent infohashes, release names and library paths are replaced with obviously fake values.
- `scripts/scan-fixtures.sh` (with a self-test) fails CI when a fixture carries such data.
- CI:
  - golangci-lint pinned to v2.15.0.
  - Actions on Node 24: checkout v7.0.1, setup-go v7.0.0, golangci-lint-action v9.3.0.
  - Read-only token, and no module cache.

Docs
- README: compiled usage and Fake examples (`radarr/example_test.go`), a `go.work` section, the exact scope of error redaction, and the wider fixture rule.
EOF
gh release list --repo parsoFish/arrkit
```

Expected: `gh release list` shows `v0.1.1  Latest` and `v0.1.0`. `--verify-tag` makes `gh` fail rather than create a tag that does not exist.

- [ ] **Step 10: Proxy check**

Run: `GOPROXY=https://proxy.golang.org go list -m github.com/parsoFish/arrkit@v0.1.1`
Expected: `github.com/parsoFish/arrkit v0.1.1`. The proxy can take a minute to see a new tag; if it says `not found`, run it again once.

- [ ] **Step 11: Clean up the merged branch and worktree**

Announce these three deletions before running them:
- the worktree `.worktrees/hardening`,
- the local branch `fix/v0.1.1-hardening`,
- the remote branch `fix/v0.1.1-hardening`.

All three are merged into `main` by now.

```bash
cd "$ARRKIT"
git merge --ff-only origin/main
git worktree remove .worktrees/hardening
git branch -d fix/v0.1.1-hardening
git push origin --delete fix/v0.1.1-hardening
git branch -vv ; git worktree list ; git status --short
```

Expected:
- `main` fast-forwards to `$MERGE`.
- The worktree and branches are removed, and `git branch -vv` shows only `* main ... [origin/main]`.
- The status is clean.
- If `git worktree remove` refuses because of untracked files, list them with `git -C .worktrees/hardening status --porcelain --ignored` and report them. Do not use `--force`.

---

## Not in scope (observed while planning)

- **qBittorrent 5.0 renamed torrent states and filters as well:**
  - States: `pausedUP`/`pausedDL` became `stoppedUP`/`stoppedDL` (`src/webui/api/serialize/serialize_torrent.cpp`).
  - `torrents/info` filters: `paused`/`resumed` became `stopped`/`running` (`src/base/torrentfilter.cpp`), both at `release-5.0.0`.
  - arrkit passes these strings through untouched, so arrkit's code is not wrong. Callers that compare them (healarr's checks, simplarr's summaries) must handle both.
  - The README now says so. Whether arrkit should normalise them is listed below as a question for the user. Plan 7's contract suite against the pinned image is where this gets caught.
- **Repeated bad-credential logins.** With wrong credentials, every call still retries login, now one at a time, as v0.1.0 did. qBittorrent bans an IP after repeated failures. Plan 3 adds the typed `ErrInvalidCredentials`, which is the natural place to stop retrying.
- **Titles in fixtures stay real.** Show and movie titles in sonarr/radarr fixtures, Tautulli watch-history titles, Plex's recently-added title and Overseerr slugs are public catalogue metadata, not one of the three kinds the user chose to scrub.
- **healarr is not bumped to v0.1.1 here.** healarr's `main` belongs to the user, and nothing in healarr needs the fixes yet.

## Done when

- `github.com/parsoFish/arrkit@v0.1.1` resolves through `proxy.golang.org`, its tag is on the merge commit, and `main`'s CI run on that commit is green.
- GitHub Releases exist for v0.1.0 and v0.1.1, with v0.1.1 as Latest.
- `gorelease` reported v0.1.1 as a valid patch, and healarr `origin/main` passed against the branch unchanged.
- The worktree and the feature branch, local and remote, are gone. Local `main` tracks `origin/main`.
- The controller marks index row 1b `done` in simplarr. Plan 2 may already be running, and Plan 3 starts from arrkit v0.1.1.
