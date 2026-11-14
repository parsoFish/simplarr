import { AuthCard } from './AuthCard'
import { ErrorMessage } from './ErrorMessage'

// Shown only when the auth state has never loaded. Once a state is cached, a
// failed background refetch keeps the page and this card is not used.
export function AuthStateError({ title, error, onRetry }: { title: string; error: unknown; onRetry: () => void }) {
  return (
    <AuthCard title={title}>
      <ErrorMessage error={error} />
      <button type="button" onClick={onRetry}>
        Try again
      </button>
    </AuthCard>
  )
}
