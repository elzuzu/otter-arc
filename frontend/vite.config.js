import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { defineConfig } from 'vite'

// The app is served from https://elzuzu.github.io/otter-arc/, so assets must be requested from
// that sub-path rather than the domain root. Override with BASE_PATH=/ for a root-hosted deploy.
const base = process.env.BASE_PATH ?? '/otter-arc/'

// https://vite.dev/config/
export default defineConfig({
  base,
  plugins: [react(), tailwindcss()],
})
