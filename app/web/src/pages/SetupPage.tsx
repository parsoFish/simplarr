import { useState, type SyntheticEvent } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuthState, useSetup } from '../api/auth'
import { AuthCard } from '../components/AuthCard'
import { AuthStateError } from '../components/AuthStateError'
import { ErrorMessage } from '../components/ErrorMessage'

// Mirrors the server policy (spec §8.2); the server is still the authority.
export const MIN_PASSWORD_LENGTH = 12

export function SetupPage() {
  const state = useAuthState()
  const setup = useSetup()
  const [token, setToken] = useState('')
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [localError, setLocalError] = useState<string | null>(null)

  if (state.isPending) {
    return (
      <AuthCard title="Set up Simplarr">
        <p role="status">Loading…</p>
      </AuthCard>
    )
  }
  if (!state.data) {
    return (
      <AuthStateError
        title="Set up Simplarr"
        error={state.error}
        onRetry={() => {
          void state.refetch()
        }}
      />
    )
  }
  if (!state.data.setupRequired) {
    return <Navigate to={state.data.authenticated ? '/' : '/login'} replace />
  }

  function onSubmit(event: SyntheticEvent<HTMLFormElement>) {
    event.preventDefault()
    if ([...password].length < MIN_PASSWORD_LENGTH) {
      setLocalError(`Use at least ${MIN_PASSWORD_LENGTH} characters.`)
      return
    }
    if (password !== confirm) {
      setLocalError('The two passwords do not match.')
      return
    }
    setLocalError(null)
    setup.mutate({ token: token.trim(), password })
  }

  const error = localError ? new Error(localError) : setup.error

  return (
    <AuthCard title="Set up Simplarr">
      <p>
        Choose the admin password. The one-time setup token is in the container log:{' '}
        <code>docker logs simplarr</code>
      </p>
      <form onSubmit={onSubmit}>
        <label>
          Setup token
          <input
            type="text"
            value={token}
            onChange={(e) => setToken(e.target.value)}
            autoComplete="off"
            spellCheck={false}
            required
          />
        </label>
        <label>
          Admin password
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="new-password"
            required
          />
        </label>
        <label>
          Repeat password
          <input
            type="password"
            value={confirm}
            onChange={(e) => setConfirm(e.target.value)}
            autoComplete="new-password"
            required
          />
        </label>
        {error ? <ErrorMessage error={error} /> : null}
        <button type="submit" disabled={setup.isPending}>
          {setup.isPending ? 'Saving…' : 'Set password'}
        </button>
      </form>
    </AuthCard>
  )
}
