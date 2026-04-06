# Test Parity Coverage Map: test.ps1 ↔ test.sh

This document maps every phase of `dev-testing/test.ps1` to its equivalent in
`dev-testing/test.sh`, records line ranges for navigation, notes intentional
gaps, and traces acceptance criteria to specific assertions.

**Last updated:** 2026-04-06
**Scope:** `dev-testing/test.ps1` (all phases) and `dev-testing/test.sh` (Phases 1–9)

---

## Phase Mapping Table

| test.ps1 Phase | Lines (test.ps1) | test.sh Phase | Lines (test.sh) | Coverage |
|---|---|---|---|---|
| Pre-flight Checks | lines 172–205 | Phase 1: Preflight | lines 151–188 | Full parity |
| File Existence Tests | lines 206–236 | Phase 2: File Existence | lines 191–218 | Full parity |
| Syntax Validation Tests | lines 237–292 | Phase 3: Syntax Validation | lines 224–338 | Partial — PSParser N/A (see Gaps) |
| Nginx Configuration Tests | lines 293–344 | Phase 4: Nginx Config Content | lines 345–461 | Full parity |
| Template Configuration Tests | lines 345–386 | Phase 5: qBittorrent Template | lines 468–533 | Full parity |
| Setup Script Validation Tests | lines 387–436 | Phase 6: Setup Script Validation | lines 540–607 | Full parity |
| Configure Script Validation Tests | lines 437–491 | Phase 7: Configure Script Validation | lines 614–687 | Full parity |
| Homepage Tests | lines 492–531 | N/A — no Bash equivalent | — | Homepage gap (see Gaps) |
| Container Startup Tests | lines 547–720 | Phase 8: Container Startup | lines 694–909 | Full parity |
| Service Connectivity Tests | lines 721–770 | Phase 9: Connectivity | lines 916–998 | Full parity |
| API Integration Tests | lines 771–852 | N/A | — | Gap — live API calls not replicated (see Gaps) |
| Configuration File Validation Tests | lines 853–977 | N/A | — | Gap — deep XML/JSON inspection not in test.sh |
| Configure Script Functionality Tests | lines 978–1350 | N/A | — | Gap — Configure Script Functionality partial: static function-presence checks only in Phase 7 |
| Verification Tests | lines 1351–1447 | N/A | — | Gap — wiring confirmation requires live containers |

---

## test.sh Phase Summary

All 9 test.sh phases are documented in this map:

| Phase | Description | Lines (test.sh) |
|---|---|---|
| Phase 1 — Preflight | Docker and docker compose availability | lines 151–188 |
| Phase 2 — File Existence | Required project files exist | lines 191–218 |
| Phase 3 — Syntax Validation | bash -n, docker compose config, nginx -t | lines 224–338 |
| Phase 4 — Nginx Config | Upstream proxy_pass targets, location routes | lines 345–461 |
| Phase 5 — qBittorrent Template | Template/config static analysis | lines 468–533 |
| Phase 6 — Setup Script | setup.sh env vars, modes, qBittorrent deploy | lines 540–607 |
| Phase 7 — Configure Script | configure.sh/configure.ps1 function presence | lines 614–687 |
| Phase 8 — Container Startup | Isolated stack; all health checks pass | lines 694–909 |
| Phase 9 — Connectivity | Health endpoints, config.xml, get_arr_api_key | lines 916–998 |

---

## -Quick Flag Correspondence

`test.ps1 -Quick` skips container startup and all downstream phases, running
only the static/syntax checks. The equivalent scope in `test.sh` is **phases
1–7** (Preflight through Configure Script Validation). Phases 8–9 in test.sh
are automatically skipped when Docker is unavailable, mirroring the `-Quick`
flag behaviour.

```
test.ps1 -Quick  ≡  test.sh phases 1-7 (no Docker required)
test.ps1 (full)  ≡  test.sh phases 1-9
```

---

## Gaps and Intentional Omissions

This section documents every test.ps1 phase that has no full Bash equivalent
and explains why. Each entry includes a justification so the omission is
traceable rather than accidental.

### PSParser / PSScriptAnalyzer Syntax Check (N/A in test.sh)

`test.ps1` Syntax Validation Tests (lines 242–250) use
`[System.Management.Automation.PSParser]::Tokenize()` — a PowerShell-only
AST parser with no Bash equivalent. There is no portable shell tool that
parses PowerShell syntax. The PSParser / PSScriptAnalyzer check is therefore
N/A for test.sh.

**Mitigation:** `test.sh` Phase 3 runs `bash -n` on all `.sh` scripts, which
covers the analogous shell-syntax verification.

### Homepage Tests (Gap — not in test.sh)

`test.ps1` Homepage Tests (lines 492–531) validate the static HTML/JS
dashboard by spinning up a container with Nginx and fetching the rendered
page. There is no corresponding phase in test.sh; the homepage tests were
omitted because:

1. The homepage is a static-file build with no runtime server-side logic.
2. Browser rendering cannot be automated in a headless shell script without
   Playwright/Puppeteer.
3. The Homepage gap is tracked for a future E2E test phase.

**Status:** Homepage gap — intentional omission.

### API Integration Tests (Gap — N/A in test.sh)

`test.ps1` API Integration Tests (lines 771–852) exercise live Arr API
endpoints (Radarr, Sonarr, Prowlarr, Overseerr) after container startup,
validating that API keys are accepted and services respond to authenticated
requests. The API Integration gap exists because:

- `test.sh` Phase 9 performs only basic HTTP connectivity checks
  (HTTP 200/302/401 from health endpoints) and does not issue authenticated
  API calls.
- Implementing full API Integration parity would require `jq` and complex
  orchestration that was deemed out of scope for the initial Bash port.

**Status:** API Integration tests are a gap between test.ps1 and test.sh.
Tracked for a future Bash API integration phase.

### Configuration File Validation Tests (Gap — N/A in test.sh)

`test.ps1` Configuration File Validation Tests (lines 853–977) inspect
generated XML, INI, and JSON config files in depth (Radarr/Sonarr/Prowlarr
`config.xml`, qBittorrent `qBittorrent.conf`, Overseerr `settings.json`,
Tautulli config). There is no equivalent in `test.sh` beyond the existence
check for `config.xml` in Phase 9 (lines 963–977 of test.sh). Deep
Configuration File Validation is a gap.

### Configure Script Functionality Tests (Gap — partial coverage in test.sh)

`test.ps1` Configure Script Functionality Tests (lines 978–1350) invoke live
API calls to wire services together (root folders, download clients, indexers,
Prowlarr sync). `test.sh` Phase 7 (lines 614–687) provides only partial
coverage: it verifies that every required function is *defined* in
`configure.sh` and `configure.ps1`, but does not execute them against live
containers. Configure Script Functionality is therefore a partial gap.

### Verification Tests (Gap — N/A in test.sh)

`test.ps1` Verification Tests (lines 1351–1447) confirm that wiring
completed successfully by re-querying each service's API and checking that
Prowlarr indexers propagated to Radarr/Sonarr. There is no Bash equivalent;
this phase depends on the preceding Configure Script Functionality phase which
is itself a gap.

---

## Acceptance Criteria Traceability

The work item `wi-simplarr-023` specifies the following acceptance criteria.
Each criterion is traceable to a specific assertion in `test_parity_doc.sh`:

| Acceptance Criterion | Verified by |
|---|---|
| Document exists and is non-empty | `test_parity_doc.sh` Section 1 — smoke test (file existence + byte count) |
| Every test.ps1 phase has a corresponding entry or explicit N/A | `test_parity_doc.sh` Section 3 — 14 PS1 phase pattern checks |
| PSParser syntax check is noted as having no Bash equivalent | `test_parity_doc.sh` Section 5a — PSParser/PSScriptAnalyzer N/A assertion |
| Homepage Tests phase is noted as having no Bash equivalent | `test_parity_doc.sh` Section 5b — Homepage gap assertion |
| All 9 test.sh phases appear in the document | `test_parity_doc.sh` Section 4 — Phase 1–9 pattern checks |
| Document contains a phase mapping table | `test_parity_doc.sh` Section 2 — table header + pipe-row checks |
| Each N/A entry includes a justification | `test_parity_doc.sh` Sections 5a, 5b, 6 — justification-string checks |
| All milestone acceptance criteria are traceable to specific assertions | This table |

---

## Cross-Reference: Source Navigation

Use the line ranges below to navigate directly to each phase:

| Script | Phase | Start | End |
|---|---|---|---|
| `dev-testing/test.ps1` | Pre-flight Checks | L172 | L205 |
| `dev-testing/test.ps1` | File Existence Tests | L206 | L236 |
| `dev-testing/test.ps1` | Syntax Validation Tests | L237 | L292 |
| `dev-testing/test.ps1` | Nginx Configuration Tests | L293 | L344 |
| `dev-testing/test.ps1` | Template Configuration Tests | L345 | L386 |
| `dev-testing/test.ps1` | Setup Script Validation Tests | L387 | L436 |
| `dev-testing/test.ps1` | Configure Script Validation Tests | L437 | L491 |
| `dev-testing/test.ps1` | Homepage Tests | L492 | L531 |
| `dev-testing/test.ps1` | Container Startup Tests | L547 | L720 |
| `dev-testing/test.ps1` | Service Connectivity Tests | L721 | L770 |
| `dev-testing/test.ps1` | API Integration Tests | L771 | L852 |
| `dev-testing/test.ps1` | Configuration File Validation Tests | L853 | L977 |
| `dev-testing/test.ps1` | Configure Script Functionality Tests | L978 | L1350 |
| `dev-testing/test.ps1` | Verification Tests | L1351 | L1447 |
| `dev-testing/test.sh` | Phase 1 — Preflight | L151 | L188 |
| `dev-testing/test.sh` | Phase 2 — File Existence | L191 | L218 |
| `dev-testing/test.sh` | Phase 3 — Syntax Validation | L224 | L338 |
| `dev-testing/test.sh` | Phase 4 — Nginx Config | L345 | L461 |
| `dev-testing/test.sh` | Phase 5 — qBittorrent Template | L468 | L533 |
| `dev-testing/test.sh` | Phase 6 — Setup Script | L540 | L607 |
| `dev-testing/test.sh` | Phase 7 — Configure Script | L614 | L687 |
| `dev-testing/test.sh` | Phase 8 — Container Startup | L694 | L909 |
| `dev-testing/test.sh` | Phase 9 — Connectivity | L916 | L998 |
