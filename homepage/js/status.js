import { services } from './services.js';

/**
 * Check a single service and update its status DOM element.
 *
 * Uses a same-origin GET request so the HTTP status is readable via response.ok.
 * A 500 sets "Unhealthy", not "Online".
 * Network errors and AbortController timeouts set "Offline".
 */
export async function checkService(service) {
  const el = document.getElementById(`status-${service.id}`);
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), service.timeout);

  try {
    const response = await fetch(service.url, { signal: controller.signal });
    clearTimeout(timeoutId);

    if (response.ok) {
      el.textContent = 'Online';
      el.className = 'status up';
    } else {
      el.textContent = 'Unhealthy';
      el.className = 'status down';
    }
  } catch {
    clearTimeout(timeoutId);
    el.textContent = 'Offline';
    el.className = 'status down';
  }
}

async function checkAll() {
  const lastCheck = document.getElementById('last-check');
  if (lastCheck) {
    lastCheck.textContent = new Date().toLocaleTimeString();
  }
  await Promise.all(services.map(checkService));
}

// DOMContentLoaded fires after deferred modules execute in a real browser but
// has already fired in a jsdom test environment, so this block is a no-op
// during tests and prevents fetch calls from interfering with mock assertions.
document.addEventListener('DOMContentLoaded', () => {
  checkAll();
  setInterval(checkAll, 30000);
});
