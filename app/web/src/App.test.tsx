import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import { authStateKey } from './api/auth'
import { ADMIN_PASSWORD, CSRF_VALUE, createGate, installBackend } from './test/backend'
import { failAuthStateRefresh, renderApp } from './test/render'
import { server } from './test/server'

describe('route guards', () => {
  it('sends an unauthenticated visitor from / to the login page', async () => {
    installBackend({ setupRequired: false, authenticated: false })
    renderApp('/')
    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
  })

  it('sends everyone to setup on first run', async () => {
    installBackend({ setupRequired: true, authenticated: false })
    renderApp('/')
    expect(await screen.findByRole('heading', { name: 'Set up Simplarr' })).toBeInTheDocument()
  })

  it('shows the home page to a signed-in admin', async () => {
    installBackend({ setupRequired: false, authenticated: true })
    renderApp('/')
    expect(await screen.findByText(/you are signed in/i)).toBeInTheDocument()
  })

  it('keeps a signed-in admin away from the login and setup pages', async () => {
    installBackend({ setupRequired: false, authenticated: true })
    renderApp('/login')
    expect(await screen.findByText(/you are signed in/i)).toBeInTheDocument()
  })

  it('shows a not-found page for unknown routes', async () => {
    installBackend({ setupRequired: false, authenticated: true })
    renderApp('/no/such/page')
    expect(await screen.findByRole('heading', { name: 'Page not found' })).toBeInTheDocument()
  })
})

describe('sign out', () => {
  it('posts the CSRF token from the cookie and returns to the login page', async () => {
    const user = userEvent.setup()
    const backend = installBackend({ setupRequired: false, authenticated: false })

    renderApp('/login')
    await user.type(await screen.findByLabelText('Admin password'), ADMIN_PASSWORD)
    await user.click(screen.getByRole('button', { name: 'Sign in' }))
    await user.click(await screen.findByRole('button', { name: 'Sign out' }))

    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
    const logout = backend.requests.find((r) => r.path === '/api/v1/auth/logout')
    expect(logout?.csrfHeader).toBe(CSRF_VALUE)
  })

  it('disables Sign out while the request is in flight', async () => {
    const user = userEvent.setup()
    const backend = installBackend({ setupRequired: false, authenticated: true })
    const gate = createGate()
    server.use(
      http.post('/api/v1/auth/logout', async () => {
        await gate.opened
        backend.state = { setupRequired: false, authenticated: false }
        return HttpResponse.json(backend.state)
      }),
    )

    const { queryClient } = renderApp('/')
    await user.click(await screen.findByRole('button', { name: 'Sign out' }))

    await waitFor(() => expect(screen.getByRole('button', { name: 'Sign out' })).toBeDisabled())

    gate.open()
    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
    await waitFor(() => expect(queryClient.isFetching()).toBe(0))
  })

  it('shows the error from a failed sign-out and stays signed in', async () => {
    const user = userEvent.setup()
    installBackend({ setupRequired: false, authenticated: true })
    server.use(
      http.post('/api/v1/auth/logout', () =>
        HttpResponse.json(
          { error: { code: 'csrf_failed', message: 'The request was missing a valid CSRF token.', fix: 'Reload the page and try again.' } },
          { status: 403 },
        ),
      ),
    )

    const { queryClient } = renderApp('/')
    await user.click(await screen.findByRole('button', { name: 'Sign out' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('The request was missing a valid CSRF token.')
    expect(screen.getByText(/you are signed in/i)).toBeInTheDocument()
    // A failed call re-validates the auth state; let that request finish.
    await waitFor(() => expect(queryClient.isFetching()).toBe(0))
  })

  it('re-checks the auth state when sign-out fails and lands on the login page if the session has expired', async () => {
    const user = userEvent.setup()
    const backend = installBackend({ setupRequired: false, authenticated: true })
    server.use(
      http.post('/api/v1/auth/logout', () =>
        HttpResponse.json({ error: { code: 'unauthenticated', message: 'Your session has expired.' } }, { status: 401 }),
      ),
    )

    renderApp('/')
    const signOut = await screen.findByRole('button', { name: 'Sign out' })
    backend.state = { setupRequired: false, authenticated: false }
    await user.click(signOut)

    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
  })
})

describe('auth state loading', () => {
  it('keeps the signed-in page when a background refresh of the auth state fails', async () => {
    installBackend({ setupRequired: false, authenticated: true })
    const { queryClient } = renderApp('/')
    expect(await screen.findByText(/you are signed in/i)).toBeInTheDocument()

    await failAuthStateRefresh(queryClient)

    expect(queryClient.getQueryData(authStateKey)).toEqual({ setupRequired: false, authenticated: true })
    expect(screen.getByText(/you are signed in/i)).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('offers a retry when the auth state cannot be loaded at all', async () => {
    const user = userEvent.setup()
    // A flag rather than a call counter: a stray request from an earlier test's
    // unmounted tree must not be the one that takes the failure.
    let healthy = false
    server.use(
      http.get('/api/v1/auth/state', () =>
        healthy
          ? HttpResponse.json({ setupRequired: false, authenticated: true })
          : new HttpResponse('Bad Gateway', { status: 502 }),
      ),
    )

    renderApp('/')
    expect(await screen.findByRole('alert')).toBeInTheDocument()
    const retry = screen.getByRole('button', { name: 'Try again' })
    healthy = true
    await user.click(retry)

    expect(await screen.findByText(/you are signed in/i)).toBeInTheDocument()
  })
})
