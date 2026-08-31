import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// Where the browser tests find their instance.
//
// The port is fixed and is not the one the development installation uses
// (9292 by default, 18.4). A test run must never end up talking to the
// installation being developed against — that one holds real work.

export const PORT = Number(process.env.PROMPTATELIER_E2E_PORT ?? 9393)
export const BASE_URL = `http://127.0.0.1:${PORT}`

const HERE = path.dirname(fileURLToPath(import.meta.url))
const CODE_ROOT = path.resolve(HERE, '..', '..')

export const RESULTS = process.env.PROMPTATELIER_TEST_RESULTS ??
  path.resolve(CODE_ROOT, '..', 'test-results')

// The credentials are not repeated here. The server writes them out after it
// has seeded the accounts, so there is one source: the fixture from test
// concept 4.1. A copy in JavaScript would be a second one, and the day the
// fixture changes its password the browser tests would fail with "wrong
// password" — which is exactly what they are supposed to be able to report
// as a genuine result.
export function account () {
  return JSON.parse(readFileSync(path.join(RESULTS, 'e2e', 'account.json'), 'utf8'))
}

// The instance administrator. Written by the same file and for the same
// reason: one source, so a changed fixture shows up as a changed file rather
// than as a puzzling sign-in failure.
export function adminAccount () {
  return account().admin
}

// The measurement stock and the account that reads it — present only when the
// server was started with PROMPTATELIER_E2E_PROMPTS. Written by the same file,
// out of scripts/lib/bench.rb, so the browser measurements and the server-side
// ones are looking at one library rather than at two that sound alike.
export function bench () {
  return JSON.parse(readFileSync(path.join(RESULTS, 'e2e', 'bench.json'), 'utf8'))
}
