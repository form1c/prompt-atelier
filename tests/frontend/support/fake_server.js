import { vi } from 'vitest'

// A stand-in for the backend, for the suites that test what the interface
// does with an answer rather than what the server puts in it.
//
// Deliberately not a mock of the client: the client is the thing under test
// in half of these suites, and a test that replaces it would prove that the
// components call a function, not that a request carries the CSRF header.
// So the seam is fetch — the same one the browser has.

export function installFakeServer (handlers = [], { headers = {} } = {}) {
  const calls = []
  const routes = [...handlers]

  const fetchStub = vi.fn(async (url, options = {}) => {
    const method = (options.method ?? 'GET').toUpperCase()
    const path = String(url)
    const call = { method, path, options, headers: options.headers ?? {} }
    calls.push(call)

    const index = routes.findIndex((route) => matches(route, method, path))
    if (index < 0) {
      throw new Error(`No fake route for ${method} ${path}`)
    }

    const route = routes[index]
    // A route with `once` is consumed, so a test can let the same call answer
    // 401 first and 200 afterwards — which is the whole point of TF-415.
    if (route.once) routes.splice(index, 1)

    if (route.fail) throw new TypeError('Failed to fetch')

    return respond(route, headers)
  })

  globalThis.fetch = fetchStub

  return {
    calls,
    fetchStub,
    add (route) { routes.push(route) },
    callsTo (method, fragment) {
      return calls.filter((call) => call.method === method.toUpperCase() && call.path.includes(fragment))
    }
  }
}

function matches (route, method, path) {
  const sameMethod = (route.method ?? 'GET').toUpperCase() === method
  if (!sameMethod || !path.split('?')[0].endsWith(route.path)) return false

  // A route may additionally require something in the query string, so a
  // test can answer the filtered call differently from the unfiltered one.
  // Order decides: the more specific route belongs first.
  return route.query === undefined || path.includes(route.query)
}

function respond (route, defaults = {}) {
  const status = route.status ?? 200
  const text = route.text !== undefined ? route.text : JSON.stringify(route.body ?? {})

  // **The real server sends `Content-Language` on every answer** (11.7), and a
  // stand-in that leaves it out would let the interface sit in whatever
  // language it started in — green over a fiction. `en` is what an instance
  // that chose nothing answers, which is also what these suites assert.
  const sent = new Map(Object.entries({
    'Content-Language': 'en', ...defaults, ...(route.headers ?? {})
  }))

  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: (name) => sent.get(name) ?? null },
    text: async () => text
  }
}

// The signed-in answers every suite needs: who am I, and which workspaces.
export const SIGNED_IN_USER = {
  id: 1,
  email: 'martin@example.test',
  name: 'Martin',
  is_instance_admin: false,
  must_change_password: false,
  locale: ''
}

// The remembered workspace is deliberately *not* the first in the list. With
// the two the same, an interface that simply took the first entry would be
// indistinguishable from one that honours what the server remembers (FA-605),
// and a mutation probe showed exactly that: replacing the one with the other
// left every assertion green.
// `permissions` comes from the server's own matrix (SEC-06). The third entry
// is the case TF-308 is about: a workspace the user may read and may not write
// to. Without one, a target list that offered everything would look correct.
//
// The three sets below are what `workspace_permissions` really answers for an
// owner of a personal workspace, an editor and a viewer — copied from the
// matrix, not invented. What keeps the copy honest is permissions_test.rb,
// which reads the same values off the running server; if the two ever part,
// that suite is where it shows, not here.
//
// The personal workspace is the interesting one: its owner may do everything
// except touch its membership or delete it (FA-606, TF-425).
export const WORKSPACES = {
  workspaces: [
    {
      id: 7,
      name: 'Persönlich-Martin',
      slug: 'persoenlich-martin',
      is_personal: true,
      role: 'owner',
      permissions: {
        create: true, keywords: true, trash: true, purge: true,
        members: false, grant_owner: false, rename: true, delete: false,
        export: true, import: true
      }
    },
    {
      id: 9,
      name: 'Marketing',
      slug: 'marketing',
      is_personal: false,
      role: 'editor',
      permissions: {
        create: true, keywords: true, trash: true, purge: false,
        members: false, grant_owner: false, rename: false, delete: false,
        export: true, import: false
      }
    },
    {
      id: 11,
      name: 'Nur-Lesen',
      slug: 'nur-lesen',
      is_personal: false,
      role: 'viewer',
      permissions: {
        create: false, keywords: false, trash: false, purge: false,
        members: false, grant_owner: false, rename: false, delete: false,
        export: false, import: false
      }
    }
  ],
  selected_workspace_id: 9
}

// The same list seen by somebody who administers the team workspace. Some
// screens exist to be operated, and an editor may not operate them — a suite
// that only ever signs in as one would leave every button untested.
export function ownerWorkspaces () {
  const workspaces = WORKSPACES.workspaces.map((workspace) => (
    workspace.id === 9
      ? {
          ...workspace,
          role: 'owner',
          permissions: {
            create: true, keywords: true, trash: true, purge: true,
            members: true, grant_owner: true, rename: true, delete: true,
            export: true, import: true
          }
        }
      : workspace
  ))

  return { ...WORKSPACES, workspaces }
}

// What a signed-in screen asks for before it can show anything: who am I,
// which workspaces, and — since AP-10 — the library behind it. The last two
// are here rather than in the library's own suite because every signed-in
// screen loads them, and a suite that leaves them out would be testing an
// interface that reports "server not reachable" the whole time.
export function signedInRoutes (prompts = [], tags = []) {
  return [
    { method: 'GET', path: '/auth/me', body: { user: SIGNED_IN_USER } },
    { method: 'GET', path: '/workspaces', body: WORKSPACES },
    { method: 'GET', path: '/prompts', body: { prompts, meta: { total: prompts.length, page: 1, per_page: 50 } } },
    { method: 'GET', path: '/tags', body: { tags } }
  ]
}

// A line of the library, with the fields 11.3 puts on it.
export function promptRow (overrides = {}) {
  return {
    id: 1,
    workspace_id: 9,
    owner_id: 1,
    title: 'Blogartikel-Generator',
    description: 'Erstellt SEO-Artikel zu beliebigem Thema',
    visibility: 'workspace',
    status: 'active',
    favorite: false,
    tags: ['seo', 'content'],
    variable_count: 2,
    owner_name: 'Sabine',
    workspace_name: 'Marketing',
    // Sent on every row since the server started answering it: the browser
    // shows a translated label for a personal workspace and the stored name
    // for every other, and it cannot tell them apart without this.
    workspace_is_personal: false,
    updated_at: new Date().toISOString(),
    ...overrides
  }
}

// A refusal the way the server really sends one since AP-19: a **code** and
// its parameters, never a sentence. The third argument used to be the message;
// it is the parameters now, and a stand-in that still sent a sentence would let
// the interface show something the server can no longer produce — green over a
// fiction.
export function apiError (status, code, params = undefined, fields = undefined) {
  return {
    status,
    body: {
      error: {
        code,
        ...(params ? { params } : {}),
        ...(fields ? { fields } : {})
      }
    }
  }
}
