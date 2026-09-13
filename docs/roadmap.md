# Simplarr roadmap

Written after the 2026-09-12 health audit of the split (NAS + Pi) deployment. Items are ordered by the damage they prevent, not by effort. Each links back to the finding that motivated it.

## 1. Boot resilience (from the NFS-before-Docker incident)

**Finding.** After a power event the Pi's NFS mounts came up 21 s after Docker. Containers bind-mounted the empty local directories under `/mnt/nas/*` and ran that way for ten days while the host mounts looked healthy. Sonarr reported 937 missing episodes and every import failed.

- [ ] `setup.sh` / `setup.ps1` (split mode): write fstab entries with `_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=60` and install a `docker.service.d/10-nfs.conf` drop-in with `After=` + `RequiresMountsFor=` the media mounts. Document the same in `readme.md` § Split Setup.
- [ ] `preflight.sh` / `preflight.ps1`: compare the filesystem device seen inside each container (`docker exec <c> stat -c %d /tv`) with the host mount and fail loudly on mismatch.
- [x] `utility/check_nas_mounts.sh`: container-vs-host device probe, compose v2, correct compose directory (shipped 2026-09-13).
- [ ] Retire the utility script in favour of healarr's `mount_race` check once healarr is installed; keep the script for users without healarr.

## 2. Download hygiene (from the fake-executable torrents)

**Finding.** 19 torrents from The Pirate Bay / 1337x delivered single `.exe`/`.scr` files with realistic sizes and clean release titles. Title and size rules cannot catch them; they sat in `downloads/tv` for months.

- [ ] `configure.sh` / `.ps1`: set qBittorrent `excluded_file_names` to `*.exe;*.scr;*.bat;*.lnk;*.msi;*.zipx` via `app/setPreferences`.
- [ ] `configure.sh` / `.ps1`: enable Sonarr/Radarr "Remove completed" + "Redownload failed", and set qBittorrent ratio/seed-time limits with "remove torrent, keep files" so leftovers are deterministic for cleanup tooling.
- [ ] `templates/`: document a recommended indexer set that excludes public trackers for TV, with a note on why.
- [ ] `readme.md`: explain the category → `/downloads/tv|movies` path convention and why `/downloads` must be one mount on the Pi.

## 3. Healarr integration

- [ ] `nginx/split.conf` + `unified.conf`: `location /healarr/ { proxy_pass http://<healarr-host>:8091/; }` (snippet ships in the healarr repo under `deploy/nginx/`).
- [ ] `homepage/`: status tile reading `/healarr/api/status` (node heartbeats, pending decisions count).
- [ ] `setup.sh`: optional "install healarr" step (download release binary for the host arch, write `config.toml`, install the systemd unit / DSM task script).
- [ ] `readme.md`: prerequisites on Synology — add the agent user to the `docker` group; DSM Task Scheduler boot task.

## 4. Version currency

**Finding.** Every pinned image was 6 months behind (Sonarr 4.0.16 → 4.0.19, Radarr 6.0.4 → 6.3.0, Prowlarr 2.3.0 → 2.5.2, Plex, qBittorrent, Tautulli).

- [x] Bump pins to September 2026 stable tags (this PR).
- [ ] Renovate config for `linuxserver/*`, `sctx/overseerr`, `nginx`, `qmcgaw/gluetun` with a "stable tags only" regex (skip `nightly-`, `develop-`, `rc`).
- [ ] CI job that regenerates the table in `VERSIONS.md` from the compose files so the two never drift.

## 5. Split-setup documentation gaps

- [ ] Plex only answers HTTPS via its `plex.direct` hostname from the LAN; plain HTTP to the IP gets an empty reply. Document the `extra_hosts` trick (already in `docker-compose-pi.yml`) and the health-check URL.
- [ ] qBittorrent WebUI credentials are needed by tooling; the copy Sonarr holds is masked in its API. Document where to keep them (healarr `secrets.toml`, 0600).
- [ ] Synology recycle bin and snapshot replication can pin hundreds of GB of deleted downloads; document checking both when the volume fills.
- [ ] The Pi checkout carried local edits (`extra_hosts`, the mount script) that were never upstreamed. Add a "how to contribute a local fix back" note and a `local-overrides/` convention.

## 6. Later

- [ ] Gluetun VPN path: run the commented-out compose block through `dev-testing/` so it is a tested option, not a suggestion.
- [ ] Bazarr: a config directory exists on the NAS but no service; either add it to the compose files or delete the directory.
- [ ] Overseerr → healarr webhook fast path (import-failed, request-available) instead of polling.
- [ ] Media staleness decisions surfaced on the homepage once healarr exposes them.
