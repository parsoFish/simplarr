import { http, HttpResponse } from 'msw'
import { server } from './server'

export interface BackendState {
  setupRequired: boolean
  authenticated: boolean
}

export interface RecordedRequest {
  method: string
  path: string
  body: unknown
  csrfHeader: string | null
}

export interface FakeBackend {
  state: BackendState
  requests: RecordedRequest[]
}

export const SETUP_TOKEN = '0123456789abcdef0123456789abcdef'
export const ADMIN_PASSWORD = 'a perfectly good password'
export const CSRF_VALUE = 'csrf-token-from-server'

// createGate lets a test hold a handler's response until it calls open(), so
// the in-flight state of a page can be asserted.
export function createGate() {
  let open!: () => void
  const opened = new Promise<void>((resolve) => {
    open = resolve
  })
  return { opened, open }
}

function apiError(status: number, code: string, message: string, fix?: string) {
  return HttpResponse.json({ error: { code, message, fix } }, { status })
}

// installBackend registers MSW handlers that behave like the real auth API and
// records every request, so tests can assert on what the SPA sent.
export function installBackend(initial: BackendState): FakeBackend {
  const backend: FakeBackend = { state: { ...initial }, requests: [] }

  async function record(request: Request, path: string): Promise<unknown> {
    const text = await request.text()
    const body: unknown = text ? JSON.parse(text) : undefined
    backend.requests.push({
      method: request.method,
      path,
      body,
      csrfHeader: request.headers.get('x-csrf-token'),
    })
    return body
  }

  server.use(
    http.get('/api/v1/auth/state', () => HttpResponse.json(backend.state)),

    http.post('/api/v1/auth/setup', async ({ request }) => {
      const body = (await record(request, '/api/v1/auth/setup')) as { token: string; password: string }
      if (body.token !== SETUP_TOKEN) {
        return apiError(403, 'invalid_setup_token', 'The setup token is wrong.', 'Copy it from the container logs.')
      }
      backend.state = { setupRequired: false, authenticated: false }
      return HttpResponse.json(backend.state)
    }),

    http.post('/api/v1/auth/login', async ({ request }) => {
      const body = (await record(request, '/api/v1/auth/login')) as { password: string }
      if (body.password !== ADMIN_PASSWORD) {
        return apiError(401, 'invalid_credentials', 'Incorrect password.')
      }
      backend.state = { setupRequired: false, authenticated: true }
      document.cookie = `simplarr_csrf=${CSRF_VALUE}; path=/`
      return HttpResponse.json(backend.state)
    }),

    http.post('/api/v1/auth/logout', async ({ request }) => {
      await record(request, '/api/v1/auth/logout')
      if (request.headers.get('x-csrf-token') !== CSRF_VALUE) {
        return apiError(403, 'csrf_failed', 'The request was missing a valid CSRF token.', 'Reload the page and try again.')
      }
      backend.state = { setupRequired: false, authenticated: false }
      return HttpResponse.json(backend.state)
    }),
  )
  return backend
}
