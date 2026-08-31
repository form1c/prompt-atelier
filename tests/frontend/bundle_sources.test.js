// @vitest-environment node
//
// The only suite that does not run in jsdom. It builds the application with
// the real toolchain, and esbuild refuses to start inside jsdom: its typed
// arrays come from a different realm, so a check esbuild makes on its own
// output fails. Nothing here needs a DOM anyway — the subject is a directory
// of files.

import { describe, it, expect } from 'vitest'
import { build } from 'vite'
import { gzipSync } from 'node:zlib'
import { existsSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// TF-714, NFA-13, SEC-11 — no external sources in the delivered interface.
//
// This is the half of TF-714 that can be automated: the built bundle is
// searched for addresses pointing anywhere but at this installation. The
// other half — recording the traffic of a running instance — stays with the
// user test in AP-17, because only a real browser shows what is actually
// fetched.
//
// The check is deliberately made on the *build*, not on the sources. A CDN
// address rarely gets typed into a component; it arrives with a dependency,
// and a dependency only shows up in the output. It is also the counter-check
// to SEC-11 the test concept asks for: a policy without external sources is
// no use if the bundle contains some, because then the page stays half empty
// instead of being protected.

const HERE = path.dirname(fileURLToPath(import.meta.url))
const CODE_ROOT = path.resolve(HERE, '..', '..')
const FRONTEND = path.join(CODE_ROOT, 'frontend')

// Traces go outside project/, like every other test run: project/data/ holds the
// database being developed against, and project/backend/public/ is where a real
// build lands. Neither may be touched by a test.
const RESULTS = process.env.PROMPTATELIER_TEST_RESULTS ??
  path.resolve(CODE_ROOT, '..', 'test-results')
const OUT = path.join(RESULTS, 'tmp', 'bundle-scan')

// Addresses in a position that loads something: the module loader, a
// request, a source attribute, a stylesheet reference. Protocol-relative
// ("//host/x") counts — it names a foreign host just as surely.
//
// Not every address in the bundle is one of these, and that distinction is
// the point. Vue and vue-router carry documentation links inside their
// warning messages; those are text on a console, not a download. A search for
// any address at all reports thirteen of them and would have to be answered
// with a growing list of exceptions — which is how a check quietly stops
// checking. What NFA-13 forbids is fetching from a foreign host, so that is
// what is looked for. The policy from SEC-11 blocks the rest at runtime, and
// the traffic recording in AP-17 has the final word.
const LOADING = new RegExp(
  '(?:\\bimport\\s*\\(|\\bfetch\\s*\\(|\\bimportScripts\\s*\\(|' +
  '\\bnew\\s+(?:Worker|SharedWorker|EventSource|WebSocket)\\s*\\(|' +
  '\\.(?:src|href)\\s*=\\s*|\\burl\\(|@import\\s+)' +
  '\\s*["\'`]?((?:https?:)?//[^"\'`)\\s]+)',
  'g'
)

// Namespaces rather than downloads: an XML namespace identifier is never
// fetched, it only names a dialect. Local addresses are the development
// server itself.
const HARMLESS = /^(?:https?:)?\/\/(localhost|127\.0\.0\.1|www\.w3\.org)([:/]|$)/

function filesUnder (directory, collected = []) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name)
    if (entry.isDirectory()) filesUnder(full, collected)
    else collected.push(full)
  }
  return collected
}

function externalAddresses (text) {
  return [...text.matchAll(LOADING)]
    .map(([, address]) => address)
    .filter((address) => !HARMLESS.test(address))
}

describe('The built bundle', () => {
  it('contains no external sources', async () => {
    rmSync(OUT, { recursive: true, force: true })

    await build({
      configFile: path.join(FRONTEND, 'vite.config.js'),
      root: FRONTEND,
      logLevel: 'silent',
      build: { outDir: OUT, emptyOutDir: true }
    })

    const offenders = []
    const files = filesUnder(OUT)

    for (const file of files) {
      for (const address of externalAddresses(readFileSync(file, 'utf8'))) {
        offenders.push(`${path.relative(OUT, file)}: ${address}`)
      }
    }

    expect(files.length).toBeGreaterThan(1)
    expect(offenders).toEqual([])
  }, 120_000)

  // TF-705, NFA-06. Measured here rather than in AP-17 because the build
  // already stands: a limit that is only checked at the end is a limit that
  // gets exceeded in the middle, and the package that exceeds it is then hard
  // to find. Compressed, because that is what crosses the wire.
  it('stays under the size limit for the JavaScript', () => {
    const scripts = filesUnder(OUT).filter((file) => file.endsWith('.js'))
    const compressed = scripts.reduce(
      (total, file) => total + gzipSync(readFileSync(file)).length, 0
    )

    expect(scripts.length).toBeGreaterThan(0)
    expect(compressed).toBeLessThan(300 * 1024)
  })

  // An icon is the one file a browser fetches without anybody writing the
  // request, and the one whose absence nothing reports: a missing favicon
  // costs a 404 in a log nobody reads and a blank square in the tab. So the
  // declaration and the delivery are compared here rather than believed —
  // a `rel="icon"` pointing at a file that was never shipped looks exactly
  // like no icon at all.
  it('ships every icon the page declares', () => {
    const page = readFileSync(path.join(OUT, 'index.html'), 'utf8')
    const icons = [...page.matchAll(/<link\b[^>]*\brel="icon"[^>]*>/g)]
      .map(([tag]) => tag.match(/\bhref="([^"]+)"/)?.[1])

    expect(icons.length).toBeGreaterThan(0)
    for (const icon of icons) {
      expect(icon).toBeDefined()
      // Without a content hash on purpose (see index.html): the delivery is
      // meant to be exchangeable by swapping the file, and a hashed name
      // would mean a rebuild for a new logo.
      expect(existsSync(path.join(OUT, icon.replace(/^\//, '')))).toBe(true)
    }
  })

  it('loads its own script and its own styling without a foreign machine', () => {
    const page = readFileSync(path.join(OUT, 'index.html'), 'utf8')
    const references = [...page.matchAll(/(?:src|href)="([^"]+)"/g)].map(([, value]) => value)

    expect(references.length).toBeGreaterThan(0)
    for (const reference of references) {
      // Root-relative. A protocol-relative address would resolve to a foreign
      // host, and a fully qualified one names it outright.
      expect(reference.startsWith('/')).toBe(true)
      expect(reference.startsWith('//')).toBe(false)
    }
  })

  // The counter-check: the search has to be able to find something. Without
  // it a regular expression that matched nothing would report a clean bundle
  // for one full of CDN addresses. The last two lines are the other half —
  // what it must *not* report, or the check would drown in exceptions.
  it('spots a source loaded afterwards and skips an address merely mentioned', () => {
    expect(externalAddresses('import("https://cdn.example.test/vue.js")'))
      .toEqual(['https://cdn.example.test/vue.js'])
    expect(externalAddresses('@font-face { src: url(https://fonts.example.test/x.woff2) }'))
      .toEqual(['https://fonts.example.test/x.woff2'])
    expect(externalAddresses('element.src = "//cdn.example.test/a.js"'))
      .toEqual(['//cdn.example.test/a.js'])

    expect(externalAddresses('console.warn("Siehe https://router.vuejs.org/guide")')).toEqual([])
    expect(externalAddresses('fetch("http://127.0.0.1:9292/api/v1/auth/me")')).toEqual([])
  })
})
