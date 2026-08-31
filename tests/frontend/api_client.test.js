import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import {
  request, get, post, put, del, readCookie, onSessionExpired, ApiError, CSRF_COOKIE
} from '../../frontend/src/api/client.js'
import { installFakeServer, apiError } from './support/fake_server.js'

// The API client (Requirements 15.1, 15.2, SEC-05).
//
// Everything here is a rule that holds for every call in the application. A
// component cannot restate them, so if one of them stops holding it stops
// holding everywhere at once — which is why they are tested here and not
// through a screen.

const realFetch = globalThis.fetch

function setCookie (value) {
  document.cookie = `${CSRF_COOKIE}=${value}; path=/`
}

function clearCookie () {
  document.cookie = `${CSRF_COOKIE}=; path=/; expires=Thu, 01 Jan 1970 00:00:00 GMT`
}

describe('API client', () => {
  beforeEach(() => {
    clearCookie()
    onSessionExpired(null)
  })

  afterEach(() => {
    globalThis.fetch = realFetch
    vi.restoreAllMocks()
  })

  it('puts every call on the base path from 15.1', async () => {
    const server = installFakeServer([{ method: 'GET', path: '/auth/me', body: { user: {} } }])

    await get('/auth/me')

    expect(server.calls[0].path).toBe('/api/v1/auth/me')
  })

  it('appends query parameters, leaves empty ones out and writes lists with brackets', async () => {
    const server = installFakeServer([{ method: 'GET', path: '/prompts', body: {} }])

    await get('/prompts', { params: { workspace_id: 7, q: null, tags: ['seo', 'blog'] } })

    expect(server.calls[0].path).toBe('/api/v1/prompts?workspace_id=7&tags%5B%5D=seo&tags%5B%5D=blog')
  })

  // SEC-05
  it('sends the CSRF header on every changing method', async () => {
    setCookie('token-42')
    const server = installFakeServer([
      { method: 'POST', path: '/prompts', body: {} },
      { method: 'PUT', path: '/prompts/1', body: {} },
      { method: 'DELETE', path: '/prompts/1', body: {} }
    ])

    await post('/prompts', { body: { title: 'x' } })
    await put('/prompts/1', { body: { title: 'y' } })
    await del('/prompts/1')

    for (const call of server.calls) {
      expect(call.headers['X-CSRF-Token']).toBe('token-42')
    }
  })

  // The counter-check to the one above. Without it the assertion would pass
  // just as happily if the header were attached to every request — and the
  // day it stops being sent on writes would look the same as today.
  it('does not send the CSRF header when reading', async () => {
    setCookie('token-42')
    const server = installFakeServer([{ method: 'GET', path: '/prompts', body: {} }])

    await get('/prompts')

    expect(server.calls[0].headers['X-CSRF-Token']).toBeUndefined()
  })

  it('sends no empty CSRF header when there is no cookie', async () => {
    const server = installFakeServer([{ method: 'POST', path: '/prompts', body: {} }])

    await post('/prompts', { body: {} })

    expect(server.calls[0].headers).not.toHaveProperty('X-CSRF-Token')
  })

  it('reads the cookie out of a jar with several entries', () => {
    const jar = `andere=1; ${CSRF_COOKIE}=abc%20def; noch_eine=2`

    expect(readCookie(CSRF_COOKIE, jar)).toBe('abc def')
    expect(readCookie('fehlt', jar)).toBeNull()
  })

  // 15.2
  it('turns the error answer into an ApiError with code, message and fields', async () => {
    installFakeServer([{
      method: 'POST',
      path: '/prompts',
      ...apiError(422, 'validation_failed', undefined, { title: 'title_required' })
    }])

    const error = await post('/prompts', { body: {} }).catch((caught) => caught)

    expect(error).toBeInstanceOf(ApiError)
    expect(error.status).toBe(422)
    expect(error.code).toBe('validation_failed')
    expect(error.message).toBe('The entry is incomplete or wrong.')
    expect(error.fields).toEqual({ title: 'title_required' })
  })

  it('reports an unreachable application as a network error rather than a status code', async () => {
    installFakeServer([{ method: 'GET', path: '/auth/me', fail: true }])

    const error = await get('/auth/me').catch((caught) => caught)

    expect(error.code).toBe('network')
    expect(error.status).toBe(0)
    expect(error.message).toMatch(/cannot be reached/)
  })

  it('reports an answer that is not JSON as unreadable', async () => {
    installFakeServer([{ method: 'GET', path: '/auth/me', status: 502, text: '<html>Bad Gateway</html>' }])

    const error = await get('/auth/me').catch((caught) => caught)

    expect(error.code).toBe('unreadable')
    expect(error.status).toBe(502)
  })

  it('accepts an empty answer with no content', async () => {
    installFakeServer([{ method: 'DELETE', path: '/prompts/1', status: 204, text: '' }])

    await expect(del('/prompts/1')).resolves.toEqual({})
  })

  // FA-103, TF-415
  describe('an expired session', () => {
    it('repeats exactly the call that ran into the expiry', async () => {
      setCookie('token-42')
      const server = installFakeServer([
        { method: 'POST', path: '/prompts', status: 401, once: true, body: { error: { code: 'unauthorized' } } },
        { method: 'POST', path: '/prompts', status: 201, body: { prompt: { id: 5 } } }
      ])

      const signIn = vi.fn(async () => {})
      onSessionExpired(signIn)

      const result = await post('/prompts', { body: { title: 'Entwurf' } })

      expect(signIn).toHaveBeenCalledTimes(1)
      expect(result).toEqual({ prompt: { id: 5 } })

      const attempts = server.callsTo('POST', '/prompts')
      expect(attempts).toHaveLength(2)
      // The repeated call is the same call: same body, same header. A retry
      // that dropped either would look successful here and fail in the browser.
      expect(attempts[1].options.body).toBe(JSON.stringify({ title: 'Entwurf' }))
      expect(attempts[1].headers['X-CSRF-Token']).toBe('token-42')
    })

    it('does not open the sign-in a second time when the repeat is refused too', async () => {
      installFakeServer([
        { method: 'POST', path: '/prompts', status: 401, body: { error: { code: 'unauthorized', message: 'Nicht angemeldet.' } } }
      ])

      const signIn = vi.fn(async () => {})
      onSessionExpired(signIn)

      const error = await post('/prompts', { body: {} }).catch((caught) => caught)

      expect(signIn).toHaveBeenCalledTimes(1)
      expect(error.status).toBe(401)
    })

    it('does not let the sign-in call itself run into the resumption', async () => {
      installFakeServer([
        { method: 'POST', path: '/auth/login', ...apiError(401, 'invalid_credentials') }
      ])

      const signIn = vi.fn(async () => {})
      onSessionExpired(signIn)

      const error = await request('POST', '/auth/login', {
        body: { email: 'a@b.test', password: 'falsch' },
        allowExpiry: false
      }).catch((caught) => caught)

      // Without this exemption a wrong password would open an overlay asking
      // for the password — on top of the screen that just asked for it.
      expect(signIn).not.toHaveBeenCalled()
      expect(error.message).toMatch(/not correct/)
    })
  })
})
