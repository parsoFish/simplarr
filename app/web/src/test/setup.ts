import '@testing-library/jest-dom/vitest'
import { cleanup } from '@testing-library/react'
import { afterAll, afterEach, beforeAll } from 'vitest'
import { assertNoUnhandledRequests, server } from './server'

beforeAll(() => server.listen({ onUnhandledFrame: 'error' }))

afterEach(() => {
  cleanup()
  server.resetHandlers()
  document.cookie = 'simplarr_csrf=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/'
  assertNoUnhandledRequests()
})

afterAll(() => server.close())
