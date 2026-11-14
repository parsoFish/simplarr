import { http, HttpResponse } from 'msw'
import { describe, expect, it, vi } from 'vitest'
import { assertNoUnhandledRequests, server } from '../test/server'
import { ApiError, apiFetch, readCookie } from './client'

describe('readCookie', () => {
  it('finds a cookie among several', () => {
    expect(readCookie('b', 'a=1; b=two; c=3')).toBe('two')
  })
  it('keeps = signs inside the value and decodes it', () => {
    expect(readCookie('t', 't=abc%20def=; x=1')).toBe('abc def=')
  })
  it('returns undefined when absent', () => {
    expect(readCookie('missing', 'a=1')).toBeUndefined()
    expect(readCookie('missing', '')).toBeUndefined()
  })
  it('does not match a cookie whose name merely ends or starts with the wanted name', () => {
    expect(readCookie('simplarr_csrf', 'x_simplarr_csrf=bad; simplarr_csrf_x=bad2; simplarr_csrf=good')).toBe('good')
  })
  it('returns the raw value when the percent-encoding is malformed', () => {
    expect(readCookie('t', 't=%E0%A4%A')).toBe('%E0%A4%A')
  })
})

describe('apiFetch', () => {
  it('sends no CSRF header on GET, even when the cookie exists', async () => {
    document.cookie = 'simplarr_csrf=abc; path=/'
    let seen: string | null = 'unset'
    server.use(
      http.get('/api/v1/thing', ({ request }) => {
        seen = request.headers.get('x-csrf-token')
        return HttpResponse.json({ ok: true })
      }),
    )
    await expect(apiFetch('/api/v1/thing')).resolves.toEqual({ ok: true })
    expect(seen).toBeNull()
  })

  it('echoes the CSRF cookie on POST and sends the body as JSON', async () => {
    document.cookie = 'simplarr_csrf=abc123; path=/'
    let seen: { csrf: string | null; contentType: string | null; body: unknown } | undefined
    server.use(
      http.post('/api/v1/thing', async ({ request }) => {
        seen = {
          csrf: request.headers.get('x-csrf-token'),
          contentType: request.headers.get('content-type'),
          body: await request.json(),
        }
        return HttpResponse.json({ ok: true })
      }),
    )
    await apiFetch('/api/v1/thing', { method: 'POST', body: { a: 1 } })
    expect(seen).toEqual({ csrf: 'abc123', contentType: 'application/json', body: { a: 1 } })
  })

  it('omits the CSRF header when there is no cookie', async () => {
    let seen: string | null = 'unset'
    server.use(
      http.post('/api/v1/thing', ({ request }) => {
        seen = request.headers.get('x-csrf-token')
        return HttpResponse.json({ ok: true })
      }),
    )
    await apiFetch('/api/v1/thing', { method: 'POST' })
    expect(seen).toBeNull()
  })

  it.each(['PUT', 'DELETE', 'PATCH', 'post'])('sends the CSRF header for %s', async (method) => {
    document.cookie = 'simplarr_csrf=tok; path=/'
    let seen: string | null = null
    server.use(
      http.all('/api/v1/thing', ({ request }) => {
        seen = request.headers.get('x-csrf-token')
        return HttpResponse.json({ ok: true })
      }),
    )
    await apiFetch('/api/v1/thing', { method })
    expect(seen).toBe('tok')
  })

  it.each(['GET', 'HEAD', 'get'])('never sends the CSRF header for %s', async (method) => {
    document.cookie = 'simplarr_csrf=tok; path=/'
    let seen: string | null = 'unset'
    server.use(
      http.all('/api/v1/thing', ({ request }) => {
        seen = request.headers.get('x-csrf-token')
        return new HttpResponse(null, { status: 200 })
      }),
    )
    // An empty body is not JSON, so apiFetch rejects; only the captured header matters here.
    await apiFetch('/api/v1/thing', { method }).catch(() => undefined)
    expect(seen).toBeNull()
  })

  it('sends same-origin credentials', async () => {
    server.use(http.get('/api/v1/thing', () => HttpResponse.json({ ok: true })))
    const spy = vi.spyOn(globalThis, 'fetch')
    await apiFetch('/api/v1/thing')
    expect(spy.mock.calls[0]?.[1]).toMatchObject({ credentials: 'same-origin' })
  })

  // Passes only because the afterEach guard in setup.ts fails the test that
  // swallowed the unhandled request. If that guard is removed, this test fails.
  it.fails('afterEach guard fails a test that swallowed an unhandled request', async () => {
    await apiFetch('/api/v1/swallowed').catch(() => undefined)
  })

  it('sends no Content-Type when there is no body', async () => {
    let seen: string | null = 'unset'
    server.use(
      http.post('/api/v1/thing', ({ request }) => {
        seen = request.headers.get('content-type')
        return HttpResponse.json({ ok: true })
      }),
    )
    await apiFetch('/api/v1/thing', { method: 'POST' })
    expect(seen).toBeNull()
  })

  it('records requests without a handler and turns them into a test failure', async () => {
    await apiFetch('/api/v1/no-handler').catch(() => undefined)
    expect(() => assertNoUnhandledRequests()).toThrow('/api/v1/no-handler')
  })

  it('turns the server error envelope into an ApiError', async () => {
    server.use(
      http.get('/api/v1/thing', () =>
        HttpResponse.json(
          { error: { code: 'rate_limited', message: 'Too many failed attempts.', fix: 'Wait 15 minute(s).' } },
          { status: 429 },
        ),
      ),
    )
    const error = await apiFetch('/api/v1/thing').catch((e: unknown) => e)
    expect(error).toBeInstanceOf(ApiError)
    expect(error).toMatchObject({
      status: 429,
      code: 'rate_limited',
      message: 'Too many failed attempts.',
      fix: 'Wait 15 minute(s).',
    })
  })

  it('falls back to a generic ApiError for non-JSON failures', async () => {
    server.use(http.get('/api/v1/thing', () => new HttpResponse('<h1>Bad gateway</h1>', { status: 502 })))
    await expect(apiFetch('/api/v1/thing')).rejects.toMatchObject({ status: 502, code: 'http_502' })
  })

  it('reports a network failure with a fix', async () => {
    server.use(http.get('/api/v1/thing', () => HttpResponse.error()))
    await expect(apiFetch('/api/v1/thing')).rejects.toMatchObject({
      code: 'network_error',
      status: 0,
      fix: 'Check that the simplarr container is running.',
    })
  })

  it('rejects a successful response that is not JSON', async () => {
    server.use(http.get('/api/v1/thing', () => new HttpResponse('plain text', { status: 200 })))
    await expect(apiFetch('/api/v1/thing')).rejects.toMatchObject({ code: 'invalid_response' })
  })
})
