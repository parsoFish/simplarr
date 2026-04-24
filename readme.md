# 🎬 Simplarr

**A self-hosted media server that just works.** Request a movie or TV show from your Plex watchlist and it automatically downloads and appears in your library — no manual steps required.

Simplarr bundles Plex with the popular *arr suite (Radarr, Sonarr, Prowlarr) and handles all the wiring between them. Run the setup, start the containers, complete two quick wizards, and you're streaming.

> ⚠️ **Early Release Notice:** While comprehensive automated testing has been completed, full end-to-end validation in diverse environments is ongoing. You may encounter issues during setup or operation. Please report any problems via GitHub issues — feedback is actively being collected and addressed to improve the setup experience.

## 🎯 How It Simplifies Setup

Setting up a media server typically involves lots of manual configuration. Simplarr handles the tedious parts for you:

- **Plex watchlist integration** — Add to your Plex watchlist, Overseerr picks it up, and it downloads automatically
- **Pre-wired services** — The configure script connects qBittorrent, Radarr, Sonarr, and Prowlarr so you don't have to
- **Sensible defaults** — qBittorrent comes pre-configured with reasonable limits, public trackers, and proper paths
- **One dashboard** — Access everything from a simple homepage at `http://your-server/` (or your server's IP address)

Once set up, your family and Plex friends just use the Plex app — they don't need to know about the automation behind it.

## 📦 What's Included

| Service | What It Does |
|---------|--------------|
| **Plex** | Streams your media to any device |
| **Radarr** | Finds and downloads movies |
| **Sonarr** | Finds and downloads TV shows |
| **Prowlarr** | Manages torrent indexers for Radarr/Sonarr |
| **qBittorrent** | Downloads torrents |
| **Overseerr** | Lets users request content (syncs with Plex watchlists) |
| **Tautulli** | Shows Plex statistics and history |
| **Nginx** | Provides clean URLs and a unified entry point |
| **Homepage** | Dashboard with links to all services + status page |

## 🔄 How It Works

```
┌─────────────────────────────────────────────────────────────────────┐
│                         YOUR EXPERIENCE                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   1. Add to Plex Watchlist  ──►  2. Automatically Downloads          │
│              │                            │                          │
│              ▼                            ▼                          │
│   ┌─────────────────┐          ┌─────────────────┐                  │
│   │  Plex App       │          │  Appears in     │                  │
│   │  (any device)   │          │  Your Library   │                  │
│   └─────────────────┘          └─────────────────┘                  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘

                    ▼ WHAT HAPPENS BEHIND THE SCENES ▼

┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   Overseerr  │────►│ Radarr/Sonarr│────►│  qBittorrent │
│              │     │              │     │              │
│ Watches your │     │ Searches via │     │  Downloads   │
│ Plex watchlist     │  Prowlarr    │     │  the file    │
└──────────────┘     └──────────────┘     └──────────────┘
       ▲                    │                    │
       │                    ▼                    ▼
       │             ┌──────────────┐     ┌──────────────┐
       │             │   Prowlarr   │     │ Media Library│
       │             │              │     │              │
       └─────────────│  Pre-wired   │     │ /movies /tv  │
      Configured     │  indexers    │     │              │
      automatically  └──────────────┘     └──────────────┘
```

**Automated Wiring:** After you complete the Plex and Overseerr sign-in wizards, the configure script wires everything together — Overseerr monitors your Plex watchlist and sends requests to Radarr/Sonarr.

## 📋 Requirements

- **Docker** and **Docker Compose** installed on your server
- Storage for your media library (local disk, NAS, or mounted drive)
- A free **Plex account** — [sign up at plex.tv](https://plex.tv)

### About Plex Pass

Simplarr works with a free Plex account. **Plex Pass** (paid subscription) adds:
- Hardware transcoding (useful for lower-powered servers)
- Secure remote access to your server from anywhere

If you don't have Plex Pass, remote access isn't available — but that's fine since Simplarr is designed for **LAN use only** anyway. This keeps the setup simple and avoids SSL certificate complexity.

## 🚀 Quick Start

### 1. Clone and enter the repo

```bash
git clone https://github.com/parsoFish/simplarr.git
cd simplarr
```

### 2. Run the setup script

```bash
# Linux/macOS
./setup.sh

# Windows PowerShell
.\setup.ps1
```

The script will ask for your timezone, storage paths, and Plex claim token.

### 3. Start the containers

```bash
docker compose -f docker-compose-unified.yml up -d
```

Wait a few minutes for all services to start. Check status with:
```bash
docker compose -f docker-compose-unified.yml ps
```

### 4. Complete the setup wizards (manual prerequisites)

Only a few quick manual steps remain. Replace `your-server-ip` with your server's IP address (e.g., `192.168.1.100`):

**Plex** (`http://your-server-ip:32400/web`)
1. Sign in with your Plex account
2. Add library → Movies → `/movies`
3. Add library → TV Shows → `/tv`

**Overseerr** (`http://your-server-ip:5055`)
1. **Sign in with Plex** (one-time OAuth authentication - this is required to initialize Overseerr)

> 💡 **Why this step is required first:** Overseerr requires Plex OAuth sign-in before it can be configured via API. Complete this before running the configure script.

### 5. Wire up the services

```bash
# Linux/macOS
./configure.sh

# Windows PowerShell
.\configure.ps1
```

This automatically connects all services together:
- qBittorrent ↔ Radarr/Sonarr ↔ Prowlarr
- **Overseerr ↔ Radarr/Sonarr** (automatic requests)
- **Overseerr Watchlist Sync** (auto-approval enabled)

### 6. Done!

Access your dashboard at `http://your-server-ip/` (replace with your server's IP, e.g., `http://192.168.1.100/`) and start adding content to your Plex watchlist.

## 🏗️ Deployment Options

### Single Machine (Recommended)

All services run on one server. Use `docker-compose-unified.yml`.

### Split Setup (NAS + Separate Server)

If your NAS struggles with the *arr apps, you can run Plex and qBittorrent on the NAS while running the automation services on a Raspberry Pi or separate server. This keeps the NAS focused on storage and transcoding.

| Device | Services | Compose File |
|--------|----------|--------------|
| NAS | Plex, qBittorrent | `docker-compose-nas.yml` |
| Pi/Server | Radarr, Sonarr, Prowlarr, Overseerr, Tautulli, Nginx | `docker-compose-pi.yml` |

**Setup:**
1. Run `./setup.sh` (or `./setup.ps1`) and choose **Split Setup** on each device to generate a local .env with the correct paths.
2. On NAS: `docker compose -f docker-compose-nas.yml up -d`
3. On Pi/Server: Mount NAS storage via NFS, then `docker compose -f docker-compose-pi.yml up -d`
4. On Pi/Server: Run `./configure.sh` (or `./configure.ps1`)

> ✅ **Split setup note:** For the Pi/Server, the configure script should point qBittorrent at the NAS. Set `QBITTORRENT_HOST` to your NAS IP (or hostname) and use `QBITTORRENT_URL` if the WebUI is not on the Pi.

> ⚠️ **Plex cert hostname (`PLEX_DIRECT_HASH`):** In split mode, Tautulli and Overseerr both need to reach Plex over HTTPS, but Plex's certificate is issued for `<dashed-ip>.<hash>.plex.direct` — not for the raw IP. `docker-compose-pi.yml` adds an `extra_hosts` entry so those containers resolve that hostname to the NAS IP. The setup script prompts for the 32-char hex `PLEX_DIRECT_HASH`; find it in your Plex server's `Preferences.xml` as the `CertificateUUID` attribute, or look at Plex **Settings → Network → Custom server access URLs** (the long hex string in the `.plex.direct` hostname). If you skip this, Tautulli's Plex dashboard and Overseerr's library-scan job will fail with TLS validation errors.

### Split Setup From a Primary Machine (No Full Clone on Both Devices)

If you don’t want to keep the full repo on both the NAS and the Pi/Server, you can copy only the required files from a primary machine:

**NAS requires:**
- `docker-compose-nas.yml`
- `.env`
- `setup.sh` or `setup.ps1` (optional, if you want to generate .env locally on NAS)
- `templates/qBittorrent/qBittorrent.conf` (optional, for preconfigured qBittorrent settings)

**Pi/Server requires:**
- `docker-compose-pi.yml`
- `.env`
- `configure.sh` or `configure.ps1`
- `nginx/split.conf`
- `homepage/` (the dashboard container build context)

**Suggested flow:**
1. Clone the repo on your primary machine.
2. Run setup on each device (or generate `.env` on the primary machine and copy it).
3. Copy only the files listed above to each device.
4. Start the NAS services first, then the Pi/Server services.

## 🌐 Accessing Services

Replace `your-server` with either:
- Your server's **IP address** — e.g., `http://192.168.1.100/` (find it with `ifconfig` on Linux/Mac or `ipconfig` on Windows)
- A **friendly hostname** — e.g., `http://simplarr.local/` (requires DNS setup, see below)

### Service URLs

Once running, access services via direct ports or through the homepage:

**Homepage Dashboard:** `http://your-server-ip/`
- Provides a clean dashboard with links to all services
- Status page available at `http://your-server-ip/status`

**Direct Port Access:**

| Service | Port | Example URL |
|---------|------|-------------|
| Plex | 32400 | `http://your-server-ip:32400/web` |
| Radarr | 7878 | `http://your-server-ip:7878/` |
| Sonarr | 8989 | `http://your-server-ip:8989/` |
| Prowlarr | 9696 | `http://your-server-ip:9696/` |
| qBittorrent | 8080 | `http://your-server-ip:8080/` |
| Overseerr | 5055 | `http://your-server-ip:5055/` |
| Tautulli | 8181 | `http://your-server-ip:8181/` |

**Example:** If your server's IP is `192.168.1.100`, the homepage is at `http://192.168.1.100/` and Radarr is at `http://192.168.1.100:7878/`

> **Note:** The homepage JavaScript automatically detects your server hostname and builds the correct URLs for all services.

### Friendly Domain Names (Optional)

Simplarr serves per-service hostnames like `plex.<TLD>`, `radarr.<TLD>`, `overseerr.<TLD>`, etc. The `<TLD>` is whatever you entered for `SUBDOMAIN_TLD` during setup (default: `local`).

Your network needs to resolve those names to the host running simplarr's nginx. Two common options:

**Option A — mDNS / Bonjour (`SUBDOMAIN_TLD=local`, default)**

`.local` is reserved for mDNS. This works automatically on:
- **macOS, iOS** — Bonjour ships with the OS
- **Linux with Avahi** — typically pre-installed on Raspberry Pi OS, Ubuntu desktop, Fedora
- **Windows with Bonjour** (ships with iTunes; otherwise install Bonjour Print Services)

On a pure-mDNS network, all devices will resolve `home.local` / `plex.local` / etc. without any DNS configuration. But be aware:
- **Android** has no built-in mDNS — `.local` names won't resolve on mobile unless you add a DNS entry or use `/etc/hosts`.
- **Windows without Bonjour** won't resolve either.

**Option B — Local DNS (`SUBDOMAIN_TLD=home`, `lan`, etc.)**

If you run Pi-hole, AdGuard Home, dnsmasq, Unbound, or your router provides local DNS:
1. Pick a TLD that won't collide with real internet TLDs (`home`, `lan`, `media`, `box` — all safe; do **not** use `.com`, `.net`, etc.)
2. Re-run `./setup.sh` and enter your chosen TLD at the `SUBDOMAIN_TLD` prompt
3. Add wildcard A-records in your DNS: `*.<TLD>` → your-server-ip
   - **Pi-hole:** Local DNS → CNAME Records → add one per subdomain
   - **AdGuard Home:** Filters → DNS rewrites → `*.home → 192.168.1.100`
   - **dnsmasq:** `address=/<TLD>/your-server-ip` in `/etc/dnsmasq.d/*.conf`

This route works on every device — including Android and Windows without Bonjour — and is the recommended path if you have ≥1 user on those platforms.

> **Why not just use `.local` with local DNS?**
> macOS and iOS hard-code `.local` → mDNS and *never* query regular DNS for it. Adding `.local` entries in dnsmasq fixes Windows/Android/Linux but Apple devices still fail. A custom TLD avoids the whole conflict.

See the [Pi-hole Local DNS guide](https://docs.pi-hole.net/guides/dns/dns-records/) for setup instructions.

## 📡 qBittorrent

qBittorrent is pre-configured with sensible defaults when you run the setup script:

- Download path: `/downloads`
- Auto-add trackers: Enabled (public trackers for better peer discovery)
- Connection limits: 500 global, 100 per torrent
- Seeding: 1:1 ratio or 48 hours

**First login:** Username is `admin`. Find the password in container logs:
```bash
docker logs qbittorrent 2>&1 | grep -i password
```

### Common Customizations

**Lower-powered server (Raspberry Pi, older hardware)?**
- Reduce connection limits: Options → Connection → Max connections global: `100-200`
- Enable "Use alternative web UI": Upload lightweight UI instead of default
- Reduce upload/download slots: Connection → Parallel downloads: `2-4`

**High-speed connection (100+ Mbps)?**
- Increase connection limits: Max connections global: `1000+`
- Increase upload/download slots: Connection → Parallel downloads: `8-16`

**Running private trackers?**
- Disable auto-add trackers to avoid getting banned: Options → BitTorrent → uncheck "Automatically add these trackers"
- Use higher seeding ratio: Advanced → Seeding → set to `2:1` or higher

**Want faster torrents?**
- Enable UPnP/NAT-PMP: Options → Connection → check both boxes (allows external peers to find you)
- Increase BEP3 extension: Options → BitTorrent → check "Enable DHT (for torrent discovery)"

<details>
<summary><b>Advanced: Changing the pre-configured settings</b></summary>

All settings are stored in the qBittorrent config. To reset or manually edit:
1. Stop the container: `docker compose -f docker-compose-unified.yml down qbittorrent`
2. Edit the config: `/path/to/qbittorrent/config/qBittorrent/qBittorrent.conf`
3. Restart: `docker compose -f docker-compose-unified.yml up -d qbittorrent`

Or use the WebUI: Open `http://your-server-ip/torrent`, go to Options, and adjust any setting.
</details>

## 🔐 VPN Support

> ⚠️ **Note:** VPN support is included but currently untested. Use at your own discretion.

If your ISP monitors torrent traffic or you want additional privacy, you can route qBittorrent through a VPN using [Gluetun](https://github.com/qdm12/gluetun-wiki).

**When to use a VPN:**
- You want to maintain privacy from your ISP
- You want additional privacy for your download activity
- You're using public trackers (private trackers often ban VPN IPs)

**Setup:** Uncomment the `gluetun` service in your compose file and add your VPN credentials. See comments in `docker-compose-unified.yml` for details.

Since Simplarr is designed for LAN-only use, the VPN only affects outbound torrent traffic — it doesn't change how you access the services locally.

## 🔒 Security

### LAN-Only Design

Simplarr uses HTTP (not HTTPS) because it's designed for your home network only. This keeps setup simple — no certificates to manage.

**Do not expose these services to the internet.** If someone outside your network could access them:
- Passwords and API keys would be sent unencrypted
- Your viewing/download activity would be visible to network observers
- These services aren't hardened against attacks

### Remote Access

If you need to access your media outside your home:

- **Plex** has secure built-in remote access (requires Plex Pass or free for local playback)
- **For other services**, use a VPN to securely connect to your home network

### Security Checklist

- [ ] Change qBittorrent's default password
- [ ] Don't port-forward these services on your router

## 🐛 Issues and Support

Found a bug or have a suggestion? [Open an issue](https://github.com/parsoFish/simplarr/issues) on GitHub.

Please include:
- What you expected to happen
- What actually happened
- Your OS and Docker version
- Relevant logs (`docker compose logs service-name`)

## 🧪 Development & Testing

**For contributors:** The `dev-testing/` directory contains an automated test suite that validates the entire setup. This is **for development only** and not needed for normal use.

- `test.ps1` (PowerShell) - Comprehensive test suite with ~83 tests

See [dev-testing/README.md](dev-testing/README.md) for details.

## 📝 License

MIT License — use and modify freely for your home setup.

## 🙏 Acknowledgments

Built with:
- [LinuxServer.io](https://linuxserver.io) container images
- [Plex](https://plex.tv), [Radarr](https://radarr.video), [Sonarr](https://sonarr.tv), [Prowlarr](https://prowlarr.com)
- [Overseerr](https://overseerr.dev/), [qBittorrent](https://www.qbittorrent.org/), [Tautulli](https://tautulli.com/)
