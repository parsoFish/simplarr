import { setupServer } from 'msw/node'

// One MSW server for the whole test run. Tests add handlers with server.use.
// A request without a handler is recorded here, and the afterEach hook in
// setup.ts fails the test: a rejected fetch alone is not enough, because the
// code under test (apiFetch, TanStack Query) turns it into an ordinary error.
export const server = setupServer()

const unhandled: string[] = []

server.events.on('request:unhandled', ({ request }) => {
  unhandled.push(`${request.method} ${request.url}`)
})

export function assertNoUnhandledRequests(): void {
  const missed = unhandled.splice(0)
  if (missed.length > 0) {
    throw new Error(`Requests without an MSW handler: ${missed.join(', ')}`)
  }
}
