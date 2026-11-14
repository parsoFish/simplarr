import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { act, render } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { MemoryRouter } from 'react-router-dom'
import { authStateKey } from '../api/auth'
import { App } from '../App'
import { server } from './server'

// Renders the whole app at a route with a fresh query cache, and returns the
// cache's client so tests can inspect or refetch it.
export function renderApp(route: string) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return {
    ...render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={[route]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>,
    ),
    queryClient,
  }
}

// Makes the auth state endpoint fail and refetches it, as a window-focus
// refetch would after a container restart. TanStack Query tells its observers
// on a timer, so this waits for that and the re-render before it returns:
// without the wait, an assertion that the page survived passes vacuously.
export async function failAuthStateRefresh(queryClient: QueryClient): Promise<void> {
  server.use(http.get('/api/v1/auth/state', () => new HttpResponse('Bad Gateway', { status: 502 })))
  await act(async () => {
    await queryClient.refetchQueries({ queryKey: authStateKey })
    await new Promise((resolve) => setTimeout(resolve, 0))
  })
  if (queryClient.getQueryState(authStateKey)?.status !== 'error') {
    throw new Error('the refetch of the auth state was expected to fail')
  }
}

// Dispatches a bare submit event on the form that holds the given element, the
// way the browser does for a native submit, and returns the event so a test can
// check that the page called preventDefault (otherwise the browser navigates).
export function dispatchSubmit(inside: HTMLElement): Event {
  const form = inside.closest('form')
  if (!form) throw new Error('the element is not inside a form')
  const event = new Event('submit', { bubbles: true, cancelable: true })
  act(() => {
    form.dispatchEvent(event)
  })
  return event
}
