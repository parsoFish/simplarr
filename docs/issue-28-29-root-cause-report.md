# Issues #28 & #29 — Root Cause Report

- **Date:** 2026-08-14
- **Branch:** `fix-issues-28-29` (PR #30)
- **Issues:** [#28](https://github.com/parsoFish/simplarr/issues/28) nginx crash loop with gluetun VPN · [#29](https://github.com/parsoFish/simplarr/issues/29) configure.sh fails on Prowlarr indexers / Overseerr
- **Status:** Both issues reproduced exactly as reported, root-caused with evidence, fixed, and verified against real service containers.

## TL;DR

After three review rounds the reporter still hit the nginx crash loop. Instead of patching again on theory, this pass **reproduced both failures from scratch in a sandbox** — native-Linux DNS conditions simulated, Plex/OAuth/VPN credentials stubbed out, everything else real. That immediately showed the previous fixes were aimed at the wrong target:

- **#28 was never about qBittorrent.** nginx crashes parsing the **Plex** upstream — `host.docker.internal` at `nginx/unified.conf:48` — which does not resolve on native Linux Docker. The gluetun alias fix from earlier rounds works fine; nginx just never gets that far.
- **#29 is a stack of `set -e` failures.** An unguarded command substitution killed the whole script the moment Overseerr *was* initialized — which is why the reporter observed it "works only if I don't finish the Overseerr wizard". Several downstream paths (Overseerr wiring, watchlist sync) had additionally never worked against real services.

---

## Part 1 — What was wrong, what changed

### #28: nginx crash loop

**Reported symptom** (byte-for-byte reproduced in the sandbox):

```
nginx: [emerg] host not found in upstream "host.docker.internal" in /etc/nginx/conf.d/default.conf:48
```

**Root cause.** `nginx/unified.conf` references `host.docker.internal` for the Plex routes (health check at line 48, `/plex` redirect, plex subdomain proxy). That hostname is provided by **Docker Desktop only**. On native Linux Docker (the reporter's UGREEN NAS) it does not resolve, nginx fails at config-parse time — before serving anything — and restart-loops. This is independent of VPN mode: the reporter had followed the gluetun enablement steps correctly, and the `qbittorrent` network alias resolved fine in the reproduction.

**Why earlier rounds missed it.** The development machine (WSL2) resolves `host.docker.internal` through the Windows DNS chain *even under native docker-ce*, so the exact conf that crash-loops on a real Linux box passes `nginx -t` locally. The reproduction had to actively blackhole that name to see what the reporter sees.

**Fix.**
- `docker-compose-unified.yml`: the nginx service now carries `extra_hosts: ["host.docker.internal:host-gateway"]` — the standard mapping for native Linux (and the fix issue #28 itself proposed). Harmless on Docker Desktop.
- `nginx/unified.conf`: the `/plex` route now redirects to `https://$host:32400/web` instead of `host.docker.internal` — the *browser* follows that redirect, and LAN clients cannot resolve `host.docker.internal` regardless of any container-side mapping.

### #29: configure.sh fails on Prowlarr indexers / Overseerr

**Reported symptoms:** script "fails and exits unsuccessfully" when the Overseerr wizard was completed (works when it wasn't), and "indexers just don't seem to be setup".

**Root causes** (each confirmed by live reproduction):

| # | Failure | Cause |
|---|---------|-------|
| 1 | Script exits 1 immediately after "Overseerr is initialized, configuring services..." | `overseerr_api_key=$(get_overseerr_api_key)` was unguarded under `set -e`; any lookup failure killed the entire script |
| 2 | Key lookup failure mode A | Path built from raw `$DOCKER_CONFIG`, which is unset when running `./configure.sh` per the readme (the script never sources `.env`) → looked in `/overseerr/settings.json` |
| 3 | Key lookup failure mode B | `grep '"apiKey":"…"'` assumed compact JSON; Overseerr pretty-prints `settings.json` (`"apiKey": "…"` with whitespace) — fails even with the path correct |
| 4 | Failure was silent | The function's log messages went to stdout inside the `$( )` capture, so the user saw the script die with no error at all |
| 5 | Indexers never added | Any earlier step returning non-zero (download client, root folder, Prowlarr app wiring) aborted the script under `set -e` before `add_public_indexers` ran |
| 6 | Indexers failing even when reached | TorrentGalaxy's Prowlarr definition was deleted upstream (the site shut down) → guaranteed HTTP 500 for every user; LimeTorrents' pinned `.lol` domain now redirects and fails Prowlarr's on-add validation; remaining sites are frequently geo-blocked (notably by AU ISPs) and Prowlarr validates against the live site on add — `forceSave` does not bypass this |

**Additional defects surfaced while verifying the fix** — same "never live-tested" class:

| # | Failure | Cause |
|---|---------|-------|
| 7 | Overseerr rejected the Radarr/Sonarr wiring with HTTP 400 | Payload was missing the required `activeProfileName` field |
| 8 | "Failed to get Radarr configuration" | Radarr/Sonarr v3+ pretty-print API responses, and the profile-id grep matched a **nested quality id** (`0`) inside `items`, not the profile's own id |
| 9 | "Failed to enable watchlist sync" on every run | The function toggled `autoApproveMovie`/`autoApproveSeries` fields that do not exist on `/api/v1/settings/main`; watchlist sync is a per-user setting. The PowerShell version threw on assigning the nonexistent property — this path had never worked in either script |

**Fixes** (mirrored in `configure.ps1` per the parity rule):
- Guarded every main-level integration step: a single failure now logs a warning and the script continues, instead of silently aborting everything after it.
- `get_overseerr_api_key`: resolves the config dir through the same `CONFIG_DIR → DOCKER_CONFIG → ./configs` chain as the *arr keys, tolerates pretty-printed JSON, logs to stderr so failures are visible, and prints an actionable hint (set `DOCKER_CONFIG` and re-run) instead of a misleading "sign in with Plex first".
- New depth-aware `extract_first_profile()` parser (plain awk, no jq dependency) returns the first quality profile's id *and* name from compact or pretty JSON; `activeProfileName` is now sent to Overseerr.
- Watchlist sync rewritten to the real API: `POST /api/v1/user/1/settings/main` with `watchlistSyncMovies`/`watchlistSyncTv` (the owner auto-approves implicitly as admin).
- TorrentGalaxy removed from `INDEXER_DEFINITIONS`; LimeTorrents URL updated to its current domain; the indexer pass now prints an honest summary (`N added, N already present, N failed`) with a note that failures are usually geo-blocking — route Prowlarr through a VPN or add indexers manually in the UI.

### Re-testing on an affected deployment

1. Pull the branch and `docker compose -f docker-compose-unified.yml up -d` (compose recreates nginx to pick up `extra_hosts`; custom port mappings such as `8282:80` are unaffected).
2. nginx should stay up with no `[emerg] host not found` lines in `docker logs nginx`.
3. Run `DOCKER_CONFIG=/path/to/your/config ./configure.sh`. With Overseerr signed in and initialized, expect Radarr/Sonarr to appear under Overseerr → Settings → Services, watchlist sync enabled, and a per-indexer summary. Re-running is idempotent.

---

## Part 2 — Process: how this was closed out

This pass deliberately restarted from **reproduction, not review**, following a strict evidence-before-fixes loop. Recording it here because the approach — including how the session was prompted and steered — is what actually found the bugs, and it is reusable for future simplarr work.

### How the session was steered

The work ran as an agentic Claude Code session, and the steering mattered as much as the execution. Three deliberate choices in the prompting:

1. **The opening prompt reframed the task away from "fix the PR".** After two review rounds had not landed for the reporter, the instruction was explicitly: *take a step back from what has been done so far, and purely attempt to reproduce the exact behaviour they described yourself — once reproduced, you will effectively be able to actually remediate. Sandbox as much as possible; stub or mock any component that normally needs manual intervention (such as Plex itself), which should be largely irrelevant to the issues.* That framing forbids the failure mode the PR had been stuck in: proposing plausible fixes against symptoms nobody had locally observed. It also pre-authorised the two sandbox tricks that made reproduction possible at all (DNS blackholing for #28, seeding Overseerr's post-wizard state for #29).

2. **`/plan` first — research before any change.** The session opened in plan mode, which is read-only by construction: issues #28/#29, the full PR #30 comment thread (including the reporter's latest logs and compose file), `configure.sh`, the compose files, and the nginx confs were all read before a single edit was possible. Hypotheses formed during this phase were written down as *candidates to discriminate by experiment*, not conclusions — the plan itself said "confirmed-plausible causes to discriminate by repro". The approved plan was staged with an explicit gate: **Stage A** build the reproduction sandbox → **Stage B** root-cause confirmation matrix → **Stage C** remediation of confirmed causes only → **Stage D** verification, with "no fixes until Stage B is complete" written into it. Only after plan approval did execution start.

3. **Reproduction → identification → resolution was run as a loop, not a pipeline.** The direction was that the three phases repeat until closure, with closure defined by evidence — the reproduction harness green in the reporter's exact topology, an idempotent re-run, and the test suite passing — not by "the fix has been applied". The loop ran three times in practice:
   - **Pass 1:** both reported failures reproduced byte-for-byte, root-caused, fixed, re-verified in the same harness.
   - **Pass 2:** Stage D verification *itself* surfaced three previously unknown defects (7–9 above: the missing `activeProfileName`, the nested-quality-id mis-parse, the never-functional watchlist sync) — because fixing the crash meant the happy path executed against real services for the first time. Rather than shipping, the session dropped back to identification: each new failure was diagnosed with a live experiment (manual `curl` against the failing endpoint to capture the real error body) before its fix.
   - **Pass 3:** full-suite run, with every failing test diffed against a clean HEAD worktree to separate genuine regressions (one — a hardcoded count, fixed) from pre-existing aspirational-red tests (left alone, documented).

   Without the loop discipline, pass 1 would have looked like success and shipped three latent bugs.

### The loop in detail

#### 1. Reproduce exactly what the reporter sees, sandboxed

Two isolated environments were built (throwaway compose projects, nothing touching the repo state):

- **Repro A (#28):** the reporter's exact VPN-mode topology — gluetun uncommented with the alias block, VPN qBittorrent override, nginx on 8282/8443 — with every heavy or manual component replaced by a stub that only preserves what nginx needs at parse time (its DNS name). Crucially, nginx's external DNS was **blackholed** (`dns: 127.0.0.1`; container names still resolve via Docker's embedded DNS) to recreate native-Linux conditions, because the dev machine's DNS chain resolves `host.docker.internal` and masks the bug. Result: the reporter's error, byte-for-byte, at the same line number — plus a contrast run (same conf, normal DNS) proving why local validation had always passed.
- **Repro B (#29):** real pinned containers for Radarr, Sonarr, Prowlarr, qBittorrent and Overseerr. The only truly manual step — Overseerr's Plex OAuth wizard — was simulated faithfully without OAuth: boot Overseerr once, flip `"initialized": true` in its `settings.json`, and insert the owner row (id 1) into its SQLite `user` table so API-key auth carries admin permissions. The script was then run in the three states the reporter described (bare invocation per the readme, `DOCKER_CONFIG` set, wizard not completed), capturing exit codes and API state before/after.

#### 2. Confirm root cause before touching code

Every hypothesis was either confirmed or discarded by a live experiment — including negative results that shaped the fix: `forceSave=true` does **not** bypass Prowlarr's indexer validation; replacement indexers (1337x, EZTV) fail from blocked networks too, so "pick better sites" is not a fix and honest reporting is.

#### 3. Fix minimally, then verify in the same harness

Each fix was re-verified in the environment that reproduced the failure: nginx zero restarts / zero emerg under blackholed DNS in the VPN topology; `configure.sh` exit 0 in all three scenarios with Radarr/Sonarr actually present in Overseerr's settings and a second run fully idempotent. Verification is what surfaced defects 7–9 — they were invisible until the happy path was executed against real services for the first time.

#### 4. Regression-proof the findings

`dev-testing/test_issue_28_29_regressions.sh` now guards all of it: static checks for the `extra_hosts` mapping, redirect target, and every `set -e` guard; unit tests for the key extraction against pretty and compact fixtures; and a live two-sided nginx check (config parse must *fail* without the host mapping under blackholed DNS, and *pass* with it). Existing suites were updated for the four-indexer list, with every failure diffed against a HEAD-baseline worktree to separate real regressions from pre-existing aspirational-red tests.

### Why three review rounds missed all of this

1. **Environment masking:** WSL2 resolves `host.docker.internal` via the Windows DNS chain even on native docker-ce — "works on my machine" was literally true and unrepresentative.
2. **The test harness dodged the failing paths by design:** `test_configure_idempotent.sh` points `OVERSEERR_URL` at Radarr so the initialized-Overseerr branch never executes, and excludes qBittorrent — the exact code paths the reporter exercised were the ones no test ran.
3. **Review without execution:** defects 7–9 (wrong API fields, nested-JSON mis-parsing) are invisible to code review; they only appear when the calls hit real services.

### Lessons for future simplarr development

- Reproduce a user-reported failure in their environment shape **before** proposing a fix; a fix that hasn't reproduced the failure is a guess.
- Test DNS-dependent behaviour with the name *absent*, not just present — Docker Desktop and native Linux differ.
- Any parser of service API responses must handle pretty-printed JSON and nested keys; the *arr APIs pretty-print by default.
- Under `set -e`, every top-level integration call needs an explicit failure path — one flaky step must not silently cancel the rest of the run.
- When a "graceful skip" is added to a test harness, record what it skips; those skips mark exactly where field bugs will live.
