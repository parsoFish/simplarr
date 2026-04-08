'use strict';

/**
 * Single source of truth for the service catalogue.
 *
 * Each entry declares:
 *   id          — stable key used by status.js and future modules
 *   name        — human-readable label shown in index.html
 *   healthPath  — URL path appended to the service base URL for health checks
 *   healthSchema — shape of a healthy JSON response (keys that must be present)
 *
 * status.js imports this array instead of duplicating service definitions inline.
 * Future features (queue data, disk usage) will extend these entries.
 */

const services = [
  {
    id: 'plex',
    name: 'Plex',
    healthPath: '/identity',
    healthSchema: {}
  },
  {
    id: 'overseerr',
    name: 'Overseerr',
    healthPath: '/api/v1/status',
    healthSchema: { version: null, status: null }
  },
  {
    id: 'radarr',
    name: 'Radarr',
    healthPath: '/ping',
    healthSchema: { status: 'OK' }
  },
  {
    id: 'sonarr',
    name: 'Sonarr',
    healthPath: '/ping',
    healthSchema: { status: 'OK' }
  },
  {
    id: 'prowlarr',
    name: 'Prowlarr',
    healthPath: '/ping',
    healthSchema: { status: 'OK' }
  },
  {
    id: 'qbittorrent',
    name: 'qBittorrent',
    healthPath: '/',
    healthSchema: {}
  },
  {
    id: 'tautulli',
    name: 'Tautulli',
    healthPath: '/status',
    healthSchema: {}
  }
];

module.exports = services;
