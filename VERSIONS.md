# Simplarr — Pinned Docker Image Versions

All Docker images in this project are pinned to specific stable release tags.
This document records the pinned version, release date, and upstream changelog URL for each service.

> **Last updated:** 2026-03-05

---

## Pinned Images

| Service | Image | Tag | Release Date | Upstream Changelog |
|---------|-------|-----|-------------|-------------------|
| Plex Media Server | `linuxserver/plex` | `1.43.0.10492-121068a07-ls295` | 2026-03-02 | [GitHub Releases](https://github.com/linuxserver/docker-plex/releases) / [Plex Release Notes](https://www.plex.tv/media-server-downloads/plex-media-server/release-notes/) |
| Radarr | `linuxserver/radarr` | `6.0.4.10291-ls294` | 2026-03-01 | [GitHub Releases](https://github.com/linuxserver/docker-radarr/releases) / [Radarr Releases](https://github.com/Radarr/Radarr/releases) |
| Sonarr | `linuxserver/sonarr` | `4.0.16.2944-ls303` | 2026-02-14 | [GitHub Releases](https://github.com/linuxserver/docker-sonarr/releases) / [Sonarr Releases](https://github.com/Sonarr/Sonarr/releases) |
| Prowlarr | `linuxserver/prowlarr` | `2.3.0.5236-ls138` | 2026-03-04 | [GitHub Releases](https://github.com/linuxserver/docker-prowlarr/releases) / [Prowlarr Releases](https://github.com/Prowlarr/Prowlarr/releases) |
| qBittorrent | `linuxserver/qbittorrent` | `5.1.4-r2-ls443` | 2026-03-01 | [GitHub Releases](https://github.com/linuxserver/docker-qbittorrent/releases) / [qBittorrent News](https://www.qbittorrent.org/news.php) |
| Tautulli | `linuxserver/tautulli` | `v2.16.1-ls217` | 2026-02-16 | [GitHub Releases](https://github.com/linuxserver/docker-tautulli/releases) / [Tautulli Releases](https://github.com/Tautulli/Tautulli/releases) |
| Overseerr | `sctx/overseerr` | `1.35.0` | 2026-02-15 | [GitHub Releases](https://github.com/sct/overseerr/releases) |
| Nginx (reverse proxy) | `nginx` | `1.28.2-alpine3.23` | 2026-02-08 | [Docker Hub Tags](https://hub.docker.com/_/nginx/tags) / [nginx CHANGES-1.28](https://nginx.org/en/CHANGES-1.28) |
| Gluetun VPN (optional) | `qmcgaw/gluetun` | `v3.41.1` | 2026-02-11 | [GitHub Releases](https://github.com/qdm12/gluetun/releases) |

> **Note on nginx versions:** nginx uses a stable/mainline dual-branch model. Even minor versions
> (1.28.x) are stable; odd minor versions (1.29.x) are mainline. Use the stable branch for production.

---

## Checking for Newer Stable Releases

To check for newer stable releases and update image tags:

### linuxserver/* images (plex, radarr, sonarr, prowlarr, qbittorrent, tautulli)

Visit the GitHub Releases page for each image (linked above). Pick the most recent tag that does **not**
include `nightly-`, `develop-`, or `rc` in the tag name — those are pre-release builds.

Tag format: `{upstream_version}-ls{build_number}` (e.g. `6.0.4.10291-ls294`)

```bash
# Check the latest stable tag via Docker Hub API (example for radarr):
curl -s "https://hub.docker.com/v2/repositories/linuxserver/radarr/tags/?page_size=10" \
  | python3 -c "import sys,json; [print(t['name']) for t in json.load(sys.stdin)['results'] if 'develop' not in t['name'] and 'nightly' not in t['name']]"
```

### sctx/overseerr

Check [https://github.com/sct/overseerr/releases](https://github.com/sct/overseerr/releases) for the
latest stable release. The Docker Hub tag omits the `v` prefix — use `1.35.0` not `v1.35.0`.

### nginx (official)

Check [https://hub.docker.com/_/nginx/tags](https://hub.docker.com/_/nginx/tags) and filter for
`1.28.*-alpine*` tags (stable branch). Prefer the fully-pinned variant (e.g. `1.28.2-alpine3.23`)
over the floating `1.28-alpine` shorthand.

### qmcgaw/gluetun

Check [https://github.com/qdm12/gluetun/releases](https://github.com/qdm12/gluetun/releases) for
the latest release. Tags follow `vX.Y.Z` format.

---

## Updating Image Versions

When you find a newer stable release for any service:

1. Update the tag in the relevant compose file(s):
   - `docker-compose-unified.yml` — all services (single-host deployment)
   - `docker-compose-nas.yml` — plex, qbittorrent (NAS host in split deployment)
   - `docker-compose-pi.yml` — radarr, sonarr, prowlarr, tautulli, nginx, overseerr (Pi/server host)

2. Update `homepage/Dockerfile` when updating the nginx image tag.

3. Update this file (`VERSIONS.md`) with the new tag, release date, and any notes.

4. Run the test suite to confirm the new tags are valid:
   ```powershell
   Invoke-Pester ./dev-testing/Test-PinnedImages.Tests.ps1 -Output Detailed
   ```

5. Commit with: `chore: update image versions — <service> to <new-tag>`
