/**
 * Tests for status.js — same-origin JSON health fetch migration
 *
 * Two test groups:
 *  1. Static analysis  — source text must not contain no-cors / HEAD and must
 *                        import from services.js using response.ok.
 *  2. Behavioral       — checkService() must produce the correct DOM state for
 *                        200 OK, 500 error, network timeout, and Plex (non-JSON).
 *
 * These tests are written BEFORE implementation (TDD red phase).
 * Static-analysis assertions fail immediately.
 * Behavioral assertions fail because checkService is not yet exported.
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const STATUS_JS_PATH = join(__dirname, '..', 'status.js');

// ---------------------------------------------------------------------------
// Mock services.js so importing status.js doesn't blow up when the real file
// doesn't exist yet.  vi.mock is hoisted above all imports by Vitest.
// ---------------------------------------------------------------------------
vi.mock('../services.js', () => ({
  services: [
    { id: 'plex', url: '/health/plex', timeout: 5000 },
    { id: 'radarr', url: '/health/radarr', timeout: 3000 },
    { id: 'sonarr', url: '/health/sonarr', timeout: 3000 },
    { id: 'prowlarr', url: '/health/prowlarr', timeout: 3000 },
    { id: 'overseerr', url: '/health/overseerr', timeout: 3000 },
    { id: 'qbittorrent', url: '/health/qbittorrent', timeout: 3000 },
    { id: 'tautulli', url: '/health/tautulli', timeout: 3000 },
  ],
}));

// ---------------------------------------------------------------------------
// Static analysis
// ---------------------------------------------------------------------------
describe('status.js static analysis', () => {
  const source = readFileSync(STATUS_JS_PATH, 'utf8');

  it('should not contain the string "no-cors"', () => {
    expect(source).not.toContain('no-cors');
  });

  it('should not use method: "HEAD" in fetch options', () => {
    // Matches 'HEAD', "HEAD", and template-literal HEAD with surrounding quotes
    expect(source).not.toMatch(/method\s*:\s*['"`]HEAD['"`]/);
  });

  it('should import services from services.js', () => {
    // Accepts any of: import { services } from './services.js'
    //                 import * as … from './services.js'
    //                 import services from './services.js'
    expect(source).toMatch(/import\s+.+from\s+['"`]\.\/services\.js['"`]/);
  });

  it('should use response.ok to gate the Online state', () => {
    expect(source).toContain('response.ok');
  });

  it('should have an "Unhealthy" label (500 must not map to Online)', () => {
    expect(source).toContain('Unhealthy');
  });

  it('should not rebuild the service list inline (no buildServices or defaultPorts)', () => {
    expect(source).not.toContain('defaultPorts');
    expect(source).not.toContain('buildServices');
  });
});

// ---------------------------------------------------------------------------
// Behavioral tests
// ---------------------------------------------------------------------------
describe('checkService', () => {
  beforeEach(() => {
    // Provide the DOM skeleton that status.js manipulates.
    document.body.innerHTML = `
      <span id="status-plex"></span>
      <span id="status-radarr"></span>
      <span id="status-sonarr"></span>
      <span id="status-prowlarr"></span>
      <span id="status-overseerr"></span>
      <span id="status-qbittorrent"></span>
      <span id="status-tautulli"></span>
      <span id="last-check"></span>
    `;
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.useRealTimers();
    vi.resetModules();
  });

  // ── Happy path ─────────────────────────────────────────────────────────────

  it('should set textContent to "Online" and class to include "up" for HTTP 200', async () => {
    global.fetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: vi.fn().mockResolvedValue({ status: 'ok' }),
    });

    const { checkService } = await import('../status.js');
    await checkService({ id: 'radarr', url: '/health/radarr', timeout: 3000 });

    const el = document.getElementById('status-radarr');
    expect(el.textContent).toBe('Online');
    expect(el.className).toContain('up');
  });

  // ── 500 must become Unhealthy, not Online ──────────────────────────────────

  it('should set textContent to "Unhealthy" when the server returns 500', async () => {
    global.fetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 500,
    });

    const { checkService } = await import('../status.js');
    await checkService({ id: 'radarr', url: '/health/radarr', timeout: 3000 });

    const el = document.getElementById('status-radarr');
    expect(el.textContent).toBe('Unhealthy');
    expect(el.className).toContain('down');
  });

  it('should set textContent to "Unhealthy" for any non-2xx HTTP response (404)', async () => {
    global.fetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 404,
    });

    const { checkService } = await import('../status.js');
    await checkService({ id: 'sonarr', url: '/health/sonarr', timeout: 3000 });

    expect(document.getElementById('status-sonarr').textContent).toBe('Unhealthy');
  });

  // ── Network / timeout → Offline ───────────────────────────────────────────

  it('should set textContent to "Offline" when fetch is aborted (timeout)', async () => {
    global.fetch = vi.fn().mockRejectedValue(
      new DOMException('The operation was aborted.', 'AbortError'),
    );

    const { checkService } = await import('../status.js');
    await checkService({ id: 'radarr', url: '/health/radarr', timeout: 3000 });

    const el = document.getElementById('status-radarr');
    expect(el.textContent).toBe('Offline');
    expect(el.className).toContain('down');
  });

  it('should set textContent to "Offline" on a network failure (TypeError)', async () => {
    global.fetch = vi.fn().mockRejectedValue(
      new TypeError('Failed to fetch'),
    );

    const { checkService } = await import('../status.js');
    await checkService({ id: 'sonarr', url: '/health/sonarr', timeout: 3000 });

    expect(document.getElementById('status-sonarr').textContent).toBe('Offline');
  });

  // ── Plex (non-JSON response) ───────────────────────────────────────────────

  it('should mark Plex Online when HTTP 200 even if the body is not JSON', async () => {
    global.fetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      // Plex /identity returns XML, not JSON — json() would throw
      json: vi.fn().mockRejectedValue(new SyntaxError('Unexpected token < in JSON')),
    });

    const { checkService } = await import('../status.js');
    await checkService({ id: 'plex', url: '/health/plex', timeout: 5000 });

    // Success must be gated by response.ok, not by JSON parsing succeeding
    expect(document.getElementById('status-plex').textContent).toBe('Online');
  });

  it('should mark Plex Unhealthy when the Nginx proxy returns 500 for Plex', async () => {
    global.fetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 500,
    });

    const { checkService } = await import('../status.js');
    await checkService({ id: 'plex', url: '/health/plex', timeout: 5000 });

    expect(document.getElementById('status-plex').textContent).toBe('Unhealthy');
  });

  // ── Request shape (no HEAD, no no-cors) ────────────────────────────────────

  it('should not pass method: HEAD to fetch', async () => {
    global.fetch = vi.fn().mockResolvedValue({ ok: true, status: 200 });

    const { checkService } = await import('../status.js');
    await checkService({ id: 'radarr', url: '/health/radarr', timeout: 3000 });

    const [, options = {}] = global.fetch.mock.calls[0];
    expect(options.method).not.toBe('HEAD');
  });

  it('should not pass mode: no-cors to fetch', async () => {
    global.fetch = vi.fn().mockResolvedValue({ ok: true, status: 200 });

    const { checkService } = await import('../status.js');
    await checkService({ id: 'radarr', url: '/health/radarr', timeout: 3000 });

    const [, options = {}] = global.fetch.mock.calls[0];
    expect(options.mode).not.toBe('no-cors');
  });

  it('should fetch exactly the URL provided in the service config (same-origin relative)', async () => {
    global.fetch = vi.fn().mockResolvedValue({ ok: true, status: 200 });

    const { checkService } = await import('../status.js');
    await checkService({ id: 'radarr', url: '/health/radarr', timeout: 3000 });

    const [fetchedUrl] = global.fetch.mock.calls[0];
    expect(fetchedUrl).toBe('/health/radarr');
  });

  // ── Each service gets its own element updated ──────────────────────────────

  it('should update the DOM element for the specific service id only', async () => {
    global.fetch = vi.fn().mockResolvedValue({ ok: true, status: 200 });

    const { checkService } = await import('../status.js');
    await checkService({ id: 'sonarr', url: '/health/sonarr', timeout: 3000 });

    // sonarr updated
    expect(document.getElementById('status-sonarr').textContent).toBe('Online');
    // radarr untouched
    expect(document.getElementById('status-radarr').textContent).toBe('');
  });
});
