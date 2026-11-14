import react from '@vitejs/plugin-react'
import { defineConfig } from 'vitest/config'

// In development the SPA runs on Vite's server and talks to a locally running
// `simplarr serve` on :8080. In production the Go binary serves the built files.
const backend = 'http://127.0.0.1:8080'

export default defineConfig({
  plugins: [react()],
  server: { proxy: { '/api': backend, '/healthz': backend } },
  // The Go binary embeds this directory (internal/webui, build tag webdist).
  // It sits outside the Vite root, so emptyOutDir must be explicit.
  build: { outDir: '../internal/webui/dist', emptyOutDir: true },
  test: {
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    restoreMocks: true,
  },
})
