import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { apiFetch } from './client'

export interface AuthState {
  setupRequired: boolean
  authenticated: boolean
}

export const authStateKey = ['auth', 'state'] as const

export function useAuthState() {
  return useQuery({
    queryKey: authStateKey,
    queryFn: () => apiFetch<AuthState>('/api/v1/auth/state'),
  })
}

// Every auth endpoint answers with the new AuthState, so a successful call
// updates the cache directly and the route guards react without a refetch.
function useAuthMutation<Variables>(path: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (variables: Variables) => apiFetch<AuthState>(path, { method: 'POST', body: variables }),
    // The variables hold the plaintext password or setup token; do not keep
    // them in the mutation cache for the default five minutes.
    gcTime: 0,
    onSuccess: (state) => {
      queryClient.setQueryData(authStateKey, state)
    },
    // A failed call (for example sign-out with an expired session) may mean the
    // cached state is stale, so re-validate it.
    onError: () => {
      void queryClient.invalidateQueries({ queryKey: authStateKey })
    },
  })
}

export function useSetup() {
  return useAuthMutation<{ token: string; password: string }>('/api/v1/auth/setup')
}

export function useLogin() {
  return useAuthMutation<{ password: string }>('/api/v1/auth/login')
}

export function useLogout() {
  return useAuthMutation<undefined>('/api/v1/auth/logout')
}
