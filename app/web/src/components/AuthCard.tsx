import type { ReactNode } from 'react'

export function AuthCard({ title, children }: { title: string; children: ReactNode }) {
  return (
    <main className="auth-card">
      <h1>{title}</h1>
      {children}
    </main>
  )
}
