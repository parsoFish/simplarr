import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import { ADMIN_PASSWORD, SETUP_TOKEN, createGate, installBackend } from '../test/backend'
import { dispatchSubmit, failAuthStateRefresh, renderApp } from '../test/render'
import { server } from '../test/server'

type User = ReturnType<typeof userEvent.setup>

async function fillForm(user: User, token: string, password: string, confirm: string) {
  await user.type(await screen.findByLabelText('Setup token'), token)
  await user.type(screen.getByLabelText('Admin password'), password)
  await user.type(screen.getByLabelText('Repeat password'), confirm)
  await user.click(screen.getByRole('button', { name: 'Set password' }))
}

// Replaces both password fields and submits again, for tests that try several
// passwords on one rendered form.
async function retypePasswords(user: User, password: string) {
  for (const label of ['Admin password', 'Repeat password']) {
    const field = screen.getByLabelText(label)
    await user.clear(field)
    await user.type(field, password)
  }
  await user.click(screen.getByRole('button', { name: 'Set password' }))
}

describe('SetupPage', () => {
  it('sets the password and moves on to the login page', async () => {
    const user = userEvent.setup()
    const backend = installBackend({ setupRequired: true, authenticated: false })

    renderApp('/setup')
    await fillForm(user, `  ${SETUP_TOKEN}  `, ADMIN_PASSWORD, ADMIN_PASSWORD)

    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
    expect(backend.requests).toEqual([
      {
        method: 'POST',
        path: '/api/v1/auth/setup',
        body: { token: SETUP_TOKEN, password: ADMIN_PASSWORD },
        csrfHeader: null,
      },
    ])
  })

  it('rejects a short password without calling the server', async () => {
    const user = userEvent.setup()
    const backend = installBackend({ setupRequired: true, authenticated: false })

    renderApp('/setup')
    await fillForm(user, SETUP_TOKEN, 'too short', 'too short')

    expect(await screen.findByRole('alert')).toHaveTextContent('Use at least 12 characters.')
    expect(backend.requests).toEqual([])
  })

  it('rejects mismatched passwords without calling the server', async () => {
    const user = userEvent.setup()
    const backend = installBackend({ setupRequired: true, authenticated: false })

    renderApp('/setup')
    await fillForm(user, SETUP_TOKEN, ADMIN_PASSWORD, `${ADMIN_PASSWORD}!`)

    expect(await screen.findByRole('alert')).toHaveTextContent('do not match')
    expect(backend.requests).toEqual([])
  })

  it('shows the server message and fix for a wrong token', async () => {
    const user = userEvent.setup()
    installBackend({ setupRequired: true, authenticated: false })

    const { queryClient } = renderApp('/setup')
    await fillForm(user, 'wrong-token', ADMIN_PASSWORD, ADMIN_PASSWORD)

    const alert = await screen.findByRole('alert')
    expect(alert).toHaveTextContent('The setup token is wrong.')
    expect(alert).toHaveTextContent('Copy it from the container logs.')
    expect(screen.getByRole('heading', { name: 'Set up Simplarr' })).toBeInTheDocument()
    // A failed call re-validates the auth state; let that request finish.
    await waitFor(() => expect(queryClient.isFetching()).toBe(0))
  })

  it('redirects to the login page once setup is complete', async () => {
    installBackend({ setupRequired: false, authenticated: false })
    renderApp('/setup')
    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
  })

  it('redirects an already signed-in admin to the home page', async () => {
    installBackend({ setupRequired: false, authenticated: true })
    renderApp('/setup')
    expect(await screen.findByText(/you are signed in/i)).toBeInTheDocument()
  })

  it('rejects an 11-character password and accepts a 12-character one', async () => {
    const user = userEvent.setup()
    const backend = installBackend({ setupRequired: true, authenticated: false })

    renderApp('/setup')
    await fillForm(user, SETUP_TOKEN, 'elevenchars', 'elevenchars')
    expect(await screen.findByRole('alert')).toHaveTextContent('Use at least 12 characters.')
    expect(backend.requests).toEqual([])

    await retypePasswords(user, 'twelve chars')
    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
    expect(backend.requests).toEqual([
      {
        method: 'POST',
        path: '/api/v1/auth/setup',
        body: { token: SETUP_TOKEN, password: 'twelve chars' },
        csrfHeader: null,
      },
    ])
  })

  it('counts characters, not UTF-16 units', async () => {
    const user = userEvent.setup()
    const backend = installBackend({ setupRequired: true, authenticated: false })

    renderApp('/setup')
    await fillForm(user, SETUP_TOKEN, '🙂'.repeat(11), '🙂'.repeat(11))
    expect(await screen.findByRole('alert')).toHaveTextContent('Use at least 12 characters.')
    expect(backend.requests).toEqual([])

    await retypePasswords(user, '🙂'.repeat(12))
    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
    expect(backend.requests).toHaveLength(1)
    expect(backend.requests[0]?.body).toEqual({ token: SETUP_TOKEN, password: '🙂'.repeat(12) })
  })

  it('keeps the form and what was typed when a background refresh of the auth state fails', async () => {
    const user = userEvent.setup()
    installBackend({ setupRequired: true, authenticated: false })

    const { queryClient } = renderApp('/setup')
    await user.type(await screen.findByLabelText('Setup token'), 'half typed')
    await failAuthStateRefresh(queryClient)

    expect(screen.getByLabelText('Setup token')).toHaveValue('half typed')
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('does not submit the form natively', async () => {
    installBackend({ setupRequired: true, authenticated: false })

    renderApp('/setup')
    const submit = dispatchSubmit(await screen.findByRole('button', { name: 'Set password' }))

    expect(submit.defaultPrevented).toBe(true)
  })

  it('disables the button and shows progress while saving', async () => {
    const user = userEvent.setup()
    const backend = installBackend({ setupRequired: true, authenticated: false })
    const gate = createGate()
    server.use(
      http.post('/api/v1/auth/setup', async () => {
        await gate.opened
        backend.state = { setupRequired: false, authenticated: false }
        return HttpResponse.json(backend.state)
      }),
    )

    renderApp('/setup')
    await fillForm(user, SETUP_TOKEN, ADMIN_PASSWORD, ADMIN_PASSWORD)

    expect(await screen.findByRole('button', { name: 'Saving…' })).toBeDisabled()

    gate.open()
    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument()
  })
})
