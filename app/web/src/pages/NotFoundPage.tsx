import { Link } from 'react-router-dom'
import { AuthCard } from '../components/AuthCard'

export function NotFoundPage() {
  return (
    <AuthCard title="Page not found">
      <p>
        <Link to="/">Back to the start</Link>
      </p>
    </AuthCard>
  )
}
