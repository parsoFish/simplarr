'use strict';

/**
 * Single source of truth for the service catalogue.
 *
 * Each entry declares:
 *   id          — stable key used by status.js and future modules
 *   name        — human-readable label shown in index.html
 *   url         — relative path through Nginx proxy (same-origin, no host/port)
 *   timeout     — health check timeout in milliseconds
 *   healthPath  — URL path appended to the service base URL for health checks
 *   healthSchema — shape of a healthy JSON response (keys that must be present)
 *
 * status.js imports this array instead of duplicating service definitions inline.
 * All URLs are relative paths that route through the Nginx proxy, so the same
 * list works for both unified and split topologies without hardcoding any
 * host names or ports.
 */

const services = [
  {
    id: 'plex',
    name: 'Plex',
    url: '/health/plex',
    timeout: 5000,
    healthPath: '/identity',
    healthSchema: {}
  },
  {
    id: 'overseerr',
    name: 'Overseerr',
    url: '/health/overseerr',
    timeout: 3000,
    healthPath: '/api/v1/status',
    healthSchema: { version: null, status: null }
  },
  {
    id: 'radarr',
    name: 'Radarr',
    url: '/health/radarr',
    timeout: 3000,
    healthPath: '/ping',
    healthSchema: { status: 'OK' }
  },
  {
    id: 'sonarr',
    name: 'Sonarr',
    url: '/health/sonarr',
    timeout: 3000,
    healthPath: '/ping',
    healthSchema: { status: 'OK' }
  },
  {
    id: 'prowlarr',
    name: 'Prowlarr',
    url: '/health/prowlarr',
    timeout: 3000,
    healthPath: '/ping',
    healthSchema: { status: 'OK' }
  },
  {
    id: 'qbittorrent',
    name: 'qBittorrent',
    url: '/health/qbittorrent',
    timeout: 3000,
    healthPath: '/',
    healthSchema: {}
  },
  {
    id: 'tautulli',
    name: 'Tautulli',
    url: '/health/tautulli',
    timeout: 3000,
    healthPath: '/status',
    healthSchema: {}
  }
];

module.exports = services;
