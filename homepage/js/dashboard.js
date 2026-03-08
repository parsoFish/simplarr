// Build URLs using the current hostname
const host = window.location.hostname;
const protocol = window.location.protocol;

const defaultPorts = {
  plex: 32400,
  overseerr: 5055,
  radarr: 7878,
  sonarr: 8989,
  prowlarr: 9696,
  qbittorrent: 8080,
  tautulli: 8181
};

function applyLinks(ports) {
  for (const [id, port] of Object.entries(ports)) {
    const el = document.getElementById(id);
    if (el) {
      // Plex has /web path, others get trailing slash
      const path = id === 'plex' ? '/web' : '/';
      el.href = `${protocol}//${host}:${port}${path}`;
    }
  }
}

fetch('/config.json')
  .then(function (r) { return r.json(); })
  .then(function (config) {
    applyLinks({
      plex: config.plex || defaultPorts.plex,
      overseerr: config.overseerr || defaultPorts.overseerr,
      radarr: config.radarr || defaultPorts.radarr,
      sonarr: config.sonarr || defaultPorts.sonarr,
      prowlarr: config.prowlarr || defaultPorts.prowlarr,
      qbittorrent: config.qbittorrent || defaultPorts.qbittorrent,
      tautulli: config.tautulli || defaultPorts.tautulli
    });
  })
  .catch(function () {
    applyLinks(defaultPorts);
  });
