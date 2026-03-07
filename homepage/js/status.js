// Get current hostname for building URLs
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

function buildServices(ports) {
  return [
    { id: 'plex', url: `${protocol}//${host}:${ports.plex}/identity`, timeout: 5000 },
    { id: 'radarr', url: `${protocol}//${host}:${ports.radarr}/ping`, timeout: 3000 },
    { id: 'sonarr', url: `${protocol}//${host}:${ports.sonarr}/ping`, timeout: 3000 },
    { id: 'prowlarr', url: `${protocol}//${host}:${ports.prowlarr}/ping`, timeout: 3000 },
    { id: 'overseerr', url: `${protocol}//${host}:${ports.overseerr}/api/v1/status`, timeout: 3000 },
    { id: 'qbittorrent', url: `${protocol}//${host}:${ports.qbittorrent}/`, timeout: 3000 },
    { id: 'tautulli', url: `${protocol}//${host}:${ports.tautulli}/status`, timeout: 3000 }
  ];
}

let services = buildServices(defaultPorts);

async function checkService(service) {
  const el = document.getElementById(`status-${service.id}`);
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), service.timeout);

    await fetch(service.url, {
      method: 'HEAD',
      signal: controller.signal,
      mode: 'no-cors'
    });
    clearTimeout(timeoutId);

    // no-cors means we can't read status, but if we get here without error, service responded
    el.textContent = 'Online';
    el.className = 'status up';
  } catch (err) {
    el.textContent = 'Offline';
    el.className = 'status down';
  }
}

async function checkAll() {
  document.getElementById('last-check').textContent = new Date().toLocaleTimeString();
  for (const service of services) {
    checkService(service);
  }
}

fetch('/config.json')
  .then(function (r) { return r.json(); })
  .then(function (config) {
    services = buildServices({
      plex: config.plex || defaultPorts.plex,
      overseerr: config.overseerr || defaultPorts.overseerr,
      radarr: config.radarr || defaultPorts.radarr,
      sonarr: config.sonarr || defaultPorts.sonarr,
      prowlarr: config.prowlarr || defaultPorts.prowlarr,
      qbittorrent: config.qbittorrent || defaultPorts.qbittorrent,
      tautulli: config.tautulli || defaultPorts.tautulli
    });
    checkAll();
  })
  .catch(function () {
    checkAll();
  });
