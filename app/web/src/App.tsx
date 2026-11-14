import { Route, Routes } from 'react-router-dom'
import { RequireAuth } from './components/RequireAuth'
import { HomePage } from './pages/HomePage'
import { LoginPage } from './pages/LoginPage'
import { NotFoundPage } from './pages/NotFoundPage'
import { SetupPage } from './pages/SetupPage'

// Client routes must not start with a prefix nginx sends to another service
// (/radarr, /sonarr, /prowlarr, /overseerr, /torrent, /tautulli, /plex,
// /health/): spec §3.3. Later pages live under /services/<name> for that reason.
export function App() {
  return (
    <Routes>
      <Route path="/setup" element={<SetupPage />} />
      <Route path="/login" element={<LoginPage />} />
      <Route element={<RequireAuth />}>
        <Route path="/" element={<HomePage />} />
      </Route>
      <Route path="*" element={<NotFoundPage />} />
    </Routes>
  )
}
