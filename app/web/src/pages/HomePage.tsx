import { useLogout } from '../api/auth'
import { ErrorMessage } from '../components/ErrorMessage'

// Placeholder: the overview, deployment and configuration pages arrive in the
// web UI plan. For now the shell proves the sign-in round trip.
export function HomePage() {
  const logout = useLogout()
  return (
    <main className="page">
      <h1>Simplarr</h1>
      <p>You are signed in. The control plane pages arrive in a later release.</p>
      {logout.error ? <ErrorMessage error={logout.error} /> : null}
      <button type="button" onClick={() => logout.mutate(undefined)} disabled={logout.isPending}>
        Sign out
      </button>
    </main>
  )
}
