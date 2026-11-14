import { useState, type SyntheticEvent } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuthState, useLogin } from '../api/auth'
import { AuthCard } from '../components/AuthCard'
import { AuthStateError } from '../components/AuthStateError'
import { ErrorMessage } from '../components/ErrorMessage'

export function LoginPage() {
  const state = useAuthState()
  const login = useLogin()
  const [password, setPassword] = useState('')

  if (state.isPending) {
    return (
      <AuthCard title="Sign in">
        <p role="status">Loading…</p>
      </AuthCard>
    )
  }
  if (!state.data) {
    return (
      <AuthStateError
        title="Sign in"
        error={state.error}
        onRetry={() => {
          void state.refetch()
        }}
      />
    )
  }
  if (state.data.setupRequired) return <Navigate to="/setup" replace />
  if (state.data.authenticated) return <Navigate to="/" replace />

  function onSubmit(event: SyntheticEvent<HTMLFormElement>) {
    event.preventDefault()
    login.mutate({ password })
  }

  return (
    <AuthCard title="Sign in">
      <form onSubmit={onSubmit}>
        <label>
          Admin password
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="current-password"
            required
          />
        </label>
        {login.error ? <ErrorMessage error={login.error} /> : null}
        <button type="submit" disabled={login.isPending}>
          {login.isPending ? 'Signing in…' : 'Sign in'}
        </button>
      </form>
    </AuthCard>
  )
}
