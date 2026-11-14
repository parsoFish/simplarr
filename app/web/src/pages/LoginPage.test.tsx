import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import { ADMIN_PASSWORD, createGate, installBackend } from '../test/backend'
import { dispatchSubmit, failAuthStateRefresh, renderApp } from '../test/render'
import { server } from '../test/server'

describe('LoginPage', () => {
  it('signs in with the admin password and lands on the home page', async () => {
    const user = userEvent.setup()
    const backend = installBackend({ setupRequired: false, authenticated: false })

    renderApp('/login')
    await user.type(await screen.findByLabelText('Admin password'), ADMIN_PASSWORD)
    await user.click(screen.getByRole('button', { name: 'Sign in' }))

    expect(await screen.findByText(/you are signed in/i)).toBeInTheDocument()
    expect(backend.requests).toEqual([
      { method: 'POST', path: '/api/v1/auth/login', body: { password: ADMIN_PASSWORD }, csrfHeader: null },
    ])
  })

  it('shows the server message for a wrong password and stays on the page', async () => {
    const user = userEvent.setup()
    installBackend({ setupRequired: false, authenticated: false })

    const { queryClient } = renderApp('/login')
    await user.type(await screen.findByLabelText('Admin password'), 'not the password')
    await user.click(screen.getByRole('button', { name: 'Sign in' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Incorrect password.')
    expect(screen.getByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
    // A failed call re-validates the auth state; let that request finish.
    await waitFor(() => expect(queryClient.isFetching()).toBe(0))
  })

  it('redirects to setup when no admin exists yet', async () => {
    installBackend({ setupRequired: true, authenticated: false })
    renderApp('/login')
    expect(await screen.findByRole('heading', { name: 'Set up Simplarr' })).toBeInTheDocument()
  })

  it('does not submit the form natively', async () => {
    installBackend({ setupRequired: false, authenticated: false })

    const { queryClient } = renderApp('/login')
    const submit = dispatchSubmit(await screen.findByRole('button', { name: 'Sign in' }))

    expect(submit.defaultPrevented).toBe(true)
    // The empty submit reaches the fake backend, which answers 401.
    expect(await screen.findByRole('alert')).toHaveTextContent('Incorrect password.')
    await waitFor(() => expect(queryClient.isFetching()).toBe(0))
  })

  it('disables the button and shows progress while signing in', async () => {
    const user = userEvent.setup()
    const backend = installBackend({ setupRequired: false, authenticated: false })
    const gate = createGate()
    server.use(
      http.post('/api/v1/auth/login', async () => {
        await gate.opened
        backend.state = { setupRequired: false, authenticated: true }
        return HttpResponse.json(backend.state)
      }),
    )

    renderApp('/login')
    await user.type(await screen.findByLabelText('Admin password'), ADMIN_PASSWORD)
    await user.click(screen.getByRole('button', { name: 'Sign in' }))

    expect(await screen.findByRole('button', { name: 'Signing in…' })).toBeDisabled()

    gate.open()
    expect(await screen.findByText(/you are signed in/i)).toBeInTheDocument()
  })

  it('keeps the form and what was typed when a background refresh of the auth state fails', async () => {
    const user = userEvent.setup()
    installBackend({ setupRequired: false, authenticated: false })

    const { queryClient } = renderApp('/login')
    await user.type(await screen.findByLabelText('Admin password'), 'half typed')
    await failAuthStateRefresh(queryClient)

    expect(screen.getByLabelText('Admin password')).toHaveValue('half typed')
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('does not keep the password in the mutation cache', async () => {
    const user = userEvent.setup()
    installBackend({ setupRequired: false, authenticated: false })

    const { queryClient } = renderApp('/login')
    await user.type(await screen.findByLabelText('Admin password'), ADMIN_PASSWORD)
    await user.click(screen.getByRole('button', { name: 'Sign in' }))
    expect(await screen.findByText(/you are signed in/i)).toBeInTheDocument()

    await waitFor(() => expect(queryClient.getMutationCache().getAll()).toHaveLength(0))
  })
})
