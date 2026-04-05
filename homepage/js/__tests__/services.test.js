/**
 * Unit-style static analysis tests for js/services.js
 *
 * services.js is the single source of truth for the service catalogue.
 * These tests verify its shape and contract before any runtime behaviour.
 * Runtime behaviour (health polling, DOM updates) is tested through status.js integration.
 */
'use strict';

// services.js does not exist yet — require() will throw until implementation lands.
// That is intentional: these tests define the contract, not the implementation.
let services;
try {
  services = require('../services');
} catch (_) {
  services = undefined;
}

// ---------------------------------------------------------------------------
// Constants shared across test suites
// ---------------------------------------------------------------------------

const EXPECTED_SERVICE_IDS = [
  'plex',
  'overseerr',
  'radarr',
  'sonarr',
  'prowlarr',
  'qbittorrent',
  'tautulli'
];

// healthPaths are derived from the URL path segments in status.js buildServices().
// services.js must encode these same paths so status.js can import them
// instead of duplicating them inline.
const EXPECTED_HEALTH_PATHS = {
  plex:         '/identity',
  radarr:       '/ping',
  sonarr:       '/ping',
  prowlarr:     '/ping',
  overseerr:    '/api/v1/status',
  qbittorrent:  '/',
  tautulli:     '/status'
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function findService(id) {
  return Array.isArray(services) ? services.find(s => s.id === id) : undefined;
}

// ---------------------------------------------------------------------------
// Suite: module contract
// ---------------------------------------------------------------------------

describe('services.js — module contract', () => {
  test('module can be required without throwing', () => {
    expect(services).toBeDefined();
  });

  test('exports an array (not an object, function, or primitive)', () => {
    expect(Array.isArray(services)).toBe(true);
  });

  test('exports exactly 7 service entries — one per service in config.json.template', () => {
    expect(services).toHaveLength(7);
  });
});

// ---------------------------------------------------------------------------
// Suite: service IDs
// ---------------------------------------------------------------------------

describe('services.js — service IDs', () => {
  test('contains all 7 IDs listed in config.json.template', () => {
    const ids = Array.isArray(services) ? services.map(s => s.id) : [];
    for (const expectedId of EXPECTED_SERVICE_IDS) {
      expect(ids).toContain(expectedId);
    }
  });

  test('has no duplicate IDs', () => {
    const ids = Array.isArray(services) ? services.map(s => s.id) : [];
    const uniqueIds = new Set(ids);
    expect(uniqueIds.size).toBe(ids.length);
  });

  test.each(EXPECTED_SERVICE_IDS)('service "%s" is present', (id) => {
    const service = findService(id);
    expect(service).toBeDefined();
  });
});

// ---------------------------------------------------------------------------
// Suite: required fields on every entry
// ---------------------------------------------------------------------------

describe('services.js — required fields on every entry', () => {
  test.each(EXPECTED_SERVICE_IDS)('service "%s" has all four required fields', (id) => {
    const service = findService(id);
    expect(service).toBeDefined();
    expect(service).toHaveProperty('id');
    expect(service).toHaveProperty('name');
    expect(service).toHaveProperty('healthPath');
    expect(service).toHaveProperty('healthSchema');
  });

  test('every entry has a non-empty string id', () => {
    if (!Array.isArray(services)) return;
    for (const service of services) {
      expect(typeof service.id).toBe('string');
      expect(service.id.trim().length).toBeGreaterThan(0);
    }
  });

  test('every entry has a non-empty string name', () => {
    if (!Array.isArray(services)) return;
    for (const service of services) {
      expect(typeof service.name).toBe('string');
      expect(service.name.trim().length).toBeGreaterThan(0);
    }
  });

  test('every entry has a healthPath string that starts with "/"', () => {
    if (!Array.isArray(services)) return;
    for (const service of services) {
      expect(typeof service.healthPath).toBe('string');
      expect(service.healthPath).toMatch(/^\//);
    }
  });

  test('every entry has a non-null healthSchema object', () => {
    if (!Array.isArray(services)) return;
    for (const service of services) {
      expect(service.healthSchema).not.toBeNull();
      expect(service.healthSchema).not.toBeUndefined();
      expect(typeof service.healthSchema).toBe('object');
    }
  });
});

// ---------------------------------------------------------------------------
// Suite: healthPath values match status.js URL path segments
// ---------------------------------------------------------------------------

describe('services.js — healthPaths match status.js URL patterns', () => {
  test.each(Object.entries(EXPECTED_HEALTH_PATHS))(
    'service "%s" has healthPath "%s"',
    (id, expectedPath) => {
      const service = findService(id);
      expect(service).toBeDefined();
      expect(service.healthPath).toBe(expectedPath);
    }
  );
});

// ---------------------------------------------------------------------------
// Suite: healthSchema structure for JSON-responding services
//
// The work item specifies:
//   - Radarr   /ping         → { status: 'OK' }
//   - Sonarr   /ping         → { status: 'OK' }   (same endpoint pattern as Radarr)
//   - Prowlarr /ping         → { status: 'OK' }   (same endpoint pattern)
//   - Overseerr /api/v1/status → { version, status }
// ---------------------------------------------------------------------------

describe('services.js — healthSchema structure', () => {
  test('radarr healthSchema declares a "status" key', () => {
    const service = findService('radarr');
    expect(service).toBeDefined();
    expect(service.healthSchema).toHaveProperty('status');
  });

  test('sonarr healthSchema declares a "status" key', () => {
    const service = findService('sonarr');
    expect(service).toBeDefined();
    expect(service.healthSchema).toHaveProperty('status');
  });

  test('prowlarr healthSchema declares a "status" key', () => {
    const service = findService('prowlarr');
    expect(service).toBeDefined();
    expect(service.healthSchema).toHaveProperty('status');
  });

  test('overseerr healthSchema declares both "version" and "status" keys', () => {
    const service = findService('overseerr');
    expect(service).toBeDefined();
    expect(service.healthSchema).toHaveProperty('version');
    expect(service.healthSchema).toHaveProperty('status');
  });
});

// ---------------------------------------------------------------------------
// Suite: names match the human-readable labels shown in index.html
// ---------------------------------------------------------------------------

describe('services.js — human-readable names', () => {
  const EXPECTED_NAMES = {
    plex:        'Plex',
    overseerr:   'Overseerr',
    radarr:      'Radarr',
    sonarr:      'Sonarr',
    prowlarr:    'Prowlarr',
    qbittorrent: 'qBittorrent',
    tautulli:    'Tautulli'
  };

  test.each(Object.entries(EXPECTED_NAMES))(
    'service "%s" has name "%s"',
    (id, expectedName) => {
      const service = findService(id);
      expect(service).toBeDefined();
      expect(service.name).toBe(expectedName);
    }
  );
});
