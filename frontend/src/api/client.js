import { t, currentLanguage, setLanguage } from '@/i18n'

// The single way the interface talks to the server (Requirements 15.1).
//
// Everything that is true for every call lives here and nowhere else: the
// base path, the CSRF header, the shape of an error, and what happens when a
// session has expired. A component that builds its own fetch would sooner or
// later forget one of them, and the one it forgets would be the CSRF header —
// visible only as a 403 in a situation nobody tests by hand.

export const API_PREFIX = '/api/v1'

// Set by the server (SEC-05). Readable by script on purpose: the value is not
// a secret, the protection is that a foreign origin can neither read the
// cookie nor set the header.
export const CSRF_COOKIE = 'promptatelier_csrf'

const WRITING_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE'])

// One error type for every failure, so a caller never has to tell a rejected
// promise from a returned error object.
//
//   status   HTTP status, 0 when the request never reached the server
//   code     the machine-readable code from 15.2, e.g. 'validation_failed'
//   params   what the sentence needs filling in with, e.g. { count: 3 }
//   message  **the sentence, written here** (AP-19). The server sends a code,
//            not a sentence: it would otherwise have to know the reader's
//            language, and the same situation would be written down twice —
//            once in its own locale files and once here for the cases the
//            browser decides alone. Two wordings for one situation drift
//            apart with nothing to notice.
//   fields   per-field **codes** from 15.2, for marking form fields
//   details  the rest of the answer beside `error`
//
// `details` exists for the refusals that carry a payload of their own. FA-404
// is the first: deleting a keyword answers 409 and names the prompts it is
// on, because "3 Prompts betroffen" is a number and their titles are an
// answer. Without this the browser would see the sentence and throw the list
// away — and a component wanting it would have to build its own fetch, which
// is the thing this file exists to prevent.
export class ApiError extends Error {
  constructor ({ status = 0, code = 'unexpected', params = {}, message, fields = {}, details = {} } = {}) {
    super(message ?? sentenceFor(code, params))
    this.name = 'ApiError'
    this.status = status
    this.code = code
    this.params = params
    this.fields = fields
    this.details = details
  }

  // The sentence for one field, by its code. Returns undefined when the field
  // is not among them, so a form can ask about every field it draws.
  fieldMessage (name) {
    const problem = this.fields?.[name]
    if (problem === undefined || problem === null) return undefined

    return typeof problem === 'string'
      ? sentenceFor(problem, {}, 'field')
      : sentenceFor(problem.code, problem.params ?? {}, 'field')
  }

  get unauthorized () {
    return this.status === 401
  }
}

// How to obtain a fresh session when one has expired. Installed by the
// session layer rather than imported from it, because the client must not
// depend on the interface that uses it — otherwise a test of the client would
// pull in the router, the state and half the components.
let reauthenticate = null

export function onSessionExpired (handler) {
  reauthenticate = handler
}

export function readCookie (name, jar = globalThis.document?.cookie ?? '') {
  for (const part of jar.split(';')) {
    const index = part.indexOf('=')
    if (index < 0) continue
    if (decodeURIComponent(part.slice(0, index).trim()) !== name) continue

    return decodeURIComponent(part.slice(index + 1).trim())
  }
  return null
}

// +options+
//   body            object, sent as JSON
//   params          object, appended as query string; null and undefined omitted
//   allowExpiry     false for calls that must not open the sign-in overlay:
//                   the sign-in call itself, and the check that asks whether
//                   there is a session at all. Without this the first load of
//                   a signed-out browser would greet the user with "your
//                   session has expired".
export async function request (method, path, options = {}) {
  const { body, params, allowExpiry = true } = options
  const verb = method.toUpperCase()

  let response
  try {
    response = await fetch(url(path, params), {
      method: verb,
      // The session cookie is the authentication (SEC-03). Same-origin is
      // enough because the interface is served by the same server, and it
      // keeps the cookie out of any future cross-origin call.
      credentials: 'same-origin',
      headers: headersFor(verb, body),
      body: body === undefined ? undefined : JSON.stringify(body)
    })
  } catch {
    // fetch rejects only when the request never completed — server down,
    // connection lost, request aborted. Everything else is a status code.
    throw new ApiError({ status: 0, code: 'network' })
  }

  await followServerLanguage(response)

  if (response.status === 401 && allowExpiry && reauthenticate) {
    return await retryAfterSignIn(method, path, options)
  }

  const payload = await parse(response)

  if (!response.ok) throw errorFrom(response, payload)

  return payload
}

export const get = (path, options) => request('GET', path, options)
export const post = (path, options) => request('POST', path, options)
export const put = (path, options) => request('PUT', path, options)
export const del = (path, options) => request('DELETE', path, options)

// --- the parts ------------------------------------------------------------

// `/health` and `/version` sit **beside** the API, not inside it — the server
// lists them that way too, because an operator has to be able to ask both
// without knowing which API generation an instance speaks. Without this line
// they would be prefixed into `/api/v1/version`, which is not a route.
const OPERATIONAL = ['/health', '/version']

function url (path, params) {
  const absolute = path.startsWith('/api/') || OPERATIONAL.includes(path)
  const base = absolute ? path : `${API_PREFIX}${path}`
  const query = new URLSearchParams()

  for (const [key, value] of Object.entries(params ?? {})) {
    if (value === null || value === undefined) continue
    if (Array.isArray(value)) {
      value.forEach((entry) => query.append(`${key}[]`, entry))
    } else {
      query.append(key, value)
    }
  }

  const suffix = query.toString()
  return suffix ? `${base}?${suffix}` : base
}

function headersFor (verb, body) {
  const headers = { Accept: 'application/json' }

  if (body !== undefined) headers['Content-Type'] = 'application/json'

  // SEC-05, double submit: repeat what the cookie says. Only on the methods
  // that change something — a GET carrying the header would suggest the check
  // applies there too, and hide the day it stops being sent.
  if (WRITING_METHODS.has(verb)) {
    const token = readCookie(CSRF_COOKIE)
    if (token) headers['X-CSRF-Token'] = token
  }

  return headers
}

async function parse (response) {
  if (response.status === 204) return {}

  const text = await response.text()
  if (text === '') return {}

  try {
    return JSON.parse(text)
  } catch {
    // A body that is not JSON means something in front of the application
    // answered — a proxy, an error page. Reporting it as "unreadable" is more
    // honest than reporting whatever status it carried.
    return { error: { code: 'unreadable' } }
  }
}

// The language the server negotiated, taken from `Content-Language` (11.7).
//
// The browser does not decide this for itself on purpose: it cannot see
// config.yml, so an instance the operator set to `de` would answer in German
// inside an English interface, and nothing would report the disagreement.
// Reading it off the answer keeps one truth and costs a header.
//
// Applied on every answer, including a 401 — the sign-in screen is exactly the
// moment when there is no profile to ask and the header is all there is.
async function followServerLanguage (response) {
  const spoken = response.headers?.get?.('Content-Language')
  if (spoken && spoken !== currentLanguage()) await setLanguage(spoken)
}

function errorFrom (response, payload) {
  const { error = {}, ...details } = payload ?? {}
  return new ApiError({
    status: response.status,
    code: error.code ?? 'unexpected',
    params: error.params ?? {},
    fields: error.fields ?? {},
    details
  })
}

// A code turned into a sentence. An unknown code is not an exception: the
// server may be newer than the interface, and "something went wrong" beats a
// blank page. The generic sentence carries the code so that whoever is asked
// about it has something to quote.
function sentenceFor (code, params = {}, namespace = 'server') {
  // `server.` first, then `error.` — the codes the **browser** raises for
  // itself (network, unreadable) live there, and looking only in `server.`
  // turned every lost connection into "an unexpected error occurred", which
  // is exactly the sentence that tells nobody anything.
  for (const key of [`${namespace}.${code}`, `error.${code}`]) {
    try {
      return t(key, params)
    } catch { /* try the next place */ }
  }
  return t('error.unexpected')
}

// FA-103, TF-415: a session can expire in the middle of a piece of work. The
// call is not lost and the screen is not thrown away — the overlay asks for
// the password, and afterwards exactly the request that failed is sent again.
// The user's inputs stay in the form because the view is never unmounted.
//
// The retry disables the mechanism for its own attempt: were the second call
// to answer 401 as well, an enabled handler would open the overlay again, and
// again, without ever telling the user that something else is wrong.
async function retryAfterSignIn (method, path, options) {
  await reauthenticate()
  return await request(method, path, { ...options, allowExpiry: false })
}
