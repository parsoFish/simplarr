import { Navigate, Outlet } from 'react-router-dom'
import { useAuthState } from '../api/auth'
import { AuthCard } from './AuthCard'
import { AuthStateError } from './AuthStateError'

// Renders its child routes only for a signed-in admin. Everyone else is sent
// to the setup page (first run) or the login page.
export function RequireAuth() {
  const state = useAuthState()
  if (state.isPending) {
    return (
      <AuthCard title="Simplarr">
        <p role="status">Loading…</p>
      </AuthCard>
    )
  }
  if (!state.data) {
    return (
      <AuthStateError
        title="Simplarr"
        error={state.error}
        onRetry={() => {
          void state.refetch()
        }}
      />
    )
  }
  if (state.data.setupRequired) return <Navigate to="/setup" replace />
  if (!state.data.authenticated) return <Navigate to="/login" replace />
  return <Outlet />
}
