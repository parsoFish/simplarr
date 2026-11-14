import { ApiError } from '../api/client'

// Shows an error with the server's "fix" line when there is one.
export function ErrorMessage({ error }: { error: unknown }) {
  const message = error instanceof Error ? error.message : 'Something went wrong.'
  const fix = error instanceof ApiError ? error.fix : undefined
  return (
    <div role="alert" className="error">
      <p>{message}</p>
      {fix ? <p className="fix">{fix}</p> : null}
    </div>
  )
}
