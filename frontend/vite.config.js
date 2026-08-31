import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// Vite configuration (Requirements 18.7, 18.8).
//
// Two decisions are load-bearing:
//
//   1. The dev server proxies /api, /health and /version to the backend, so
//      the browser only ever sees a single origin. Without that the session
//      cookie rules from SEC-03 would behave differently in development than
//      in production — the class of bug that only shows up after deployment.
//   2. The production build writes into backend/public/, which is where the
//      backend serves static files from. `build` (18.8) picks it up from
//      there; nothing is copied twice.
//
// The backend port is read from config/config.yml so that host and port keep
// exactly one source of truth (BT-19).

import { readFileSync, existsSync } from 'node:fs'

const here = fileURLToPath(new URL('.', import.meta.url))
const installRoot = fileURLToPath(new URL('..', import.meta.url))

function backendPort () {
  for (const name of ['config.yml', 'config.example.yml']) {
    const path = `${installRoot}config/${name}`
    if (!existsSync(path)) continue
    // Deliberately a small regex instead of a YAML dependency: the dev server
    // needs exactly one number, and an extra package for that would be noise.
    const match = readFileSync(path, 'utf8').match(/^\s{2}port:\s*(\d+)/m)
    if (match) return Number(match[1])
  }
  return 9292
}

const target = `http://127.0.0.1:${backendPort()}`

export default defineConfig({
  root: here,
  plugins: [vue()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url))
    }
  },
  server: {
    // Bind IPv4 explicitly. Vite's default binds only to ::1, so the server
    // answers on http://localhost:5173 but not on http://127.0.0.1:5173 —
    // confusing, and inconsistent with the backend, which binds 127.0.0.1.
    host: '127.0.0.1',

    // Fixed port, and fail rather than silently move to 5174: start_development
    // opens this address in the browser, so it must be predictable.
    port: 5173,
    strictPort: true,

    // The test suites live in code/tests/frontend/ (test concept 3.2), i.e.
    // outside this root. Without an explicit allowance Vite refuses to serve
    // them and reports them as missing.
    fs: { allow: [installRoot] },
    proxy: {
      '/api': { target, changeOrigin: false },
      '/health': { target, changeOrigin: false },
      '/version': { target, changeOrigin: false }
    }
  },
  build: {
    outDir: fileURLToPath(new URL('../backend/public', import.meta.url)),
    emptyOutDir: true
  },
  test: {
    environment: 'jsdom',
    include: ['../tests/frontend/**/*.test.js'],
    root: here
  }
})
