// Thin fetch wrapper for the simplarr API. Every non-GET request echoes the
// CSRF cookie in the X-CSRF-Token header (double-submit, spec §8.2), and every
// failure becomes an ApiError that carries the server's code, message and fix.

const CSRF_COOKIE = 'simplarr_csrf'
const CSRF_HEADER = 'X-CSRF-Token'

export class ApiError extends Error {
  readonly status: number
  readonly code: string
  readonly fix: string | undefined

  constructor(status: number, code: string, message: string, fix?: string) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.code = code
    this.fix = fix
  }
}

export function readCookie(name: string, cookies: string = document.cookie): string | undefined {
  for (const part of cookies.split(';')) {
    const [key, ...rest] = part.trim().split('=')
    if (key === name) {
      const raw = rest.join('=')
      try {
        return decodeURIComponent(raw)
      } catch {
        return raw // not percent-encoded; use the value as sent
      }
    }
  }
  return undefined
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function toApiError(status: number, data: unknown): ApiError {
  if (isRecord(data) && isRecord(data.error)) {
    const { code, message, fix } = data.error
    if (typeof code === 'string' && typeof message === 'string') {
      return new ApiError(status, code, message, typeof fix === 'string' ? fix : undefined)
    }
  }
  return new ApiError(status, `http_${status}`, `The server answered ${status}.`)
}

interface RequestOptions {
  method?: string
  body?: unknown
}

export async function apiFetch<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const method = (options.method ?? 'GET').toUpperCase()
  const headers: Record<string, string> = { Accept: 'application/json' }
  if (options.body !== undefined) headers['Content-Type'] = 'application/json'
  if (method !== 'GET' && method !== 'HEAD') {
    const csrf = readCookie(CSRF_COOKIE)
    if (csrf) headers[CSRF_HEADER] = csrf
  }

  let response: Response
  try {
    response = await fetch(path, {
      method,
      headers,
      credentials: 'same-origin',
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    })
  } catch {
    throw new ApiError(0, 'network_error', 'Cannot reach the Simplarr server.', 'Check that the simplarr container is running.')
  }

  const text = await response.text()
  let data: unknown
  if (text) {
    try {
      data = JSON.parse(text)
    } catch {
      data = undefined
    }
  }
  if (!response.ok) throw toApiError(response.status, data)
  if (data === undefined) {
    throw new ApiError(response.status, 'invalid_response', 'The server sent a response that is not JSON.')
  }
  return data as T
}
