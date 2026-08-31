import { describe, it, expect, afterEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { createMemoryHistory } from 'vue-router'
import { readFileSync, readdirSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { settle } from './support/flush.js'
import { installFakeServer, signedInRoutes, SIGNED_IN_USER, WORKSPACES } from './support/fake_server.js'

// TF-530 and TF-531 in the browser — the language of the interface (11.7).
//
// **The browser does not negotiate.** It reads `Content-Language` off the
// answer and follows it. Checking that here rather than the chain itself is
// deliberate: the chain lives on the server, where config.yml can be seen, and
// a second implementation in the browser would be a second truth that nothing
// compares.
//
// English is the base table and is always in the bundle. Every other language
// is laid over it at runtime, so what is checked below is not only "German
// arrives" but the two halves that fail quietly: a key the translation does
// not carry must come from the base, and a language nobody installed must
// leave the interface usable.

const realFetch = globalThis.fetch

afterEach(() => {
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

async function i18n () {
  vi.resetModules()
  return await import('../../frontend/src/i18n/index.js')
}

describe('The language of the interface', () => {
  it('starts in English, which is the table that is always there', async () => {
    const { t, currentLanguage, BASE_LANGUAGE } = await i18n()

    expect(currentLanguage()).toBe(BASE_LANGUAGE)
    expect(t('library.title')).toBe('Library')
  })

  it('lays a language over the base and gives it back again', async () => {
    const { t, setLanguage } = await i18n()

    await setLanguage('de')
    expect(t('library.title')).toBe('Bibliothek')

    await setLanguage('en')
    expect(t('library.title')).toBe('Library')
  })

  // TF-531: the half that fails quietly, and the one the delivered files
  // cannot show. `de.json` is complete, and a complete translation looks the
  // same whether the tables are merged or replaced — so the mistake would
  // survive until the first language that is *not* complete, which is the
  // normal state of every translation ever started.
  it('lets a translation carry one sentence without taking its namespace along', async () => {
    const { deepMerge } = await i18n()

    const base = { library: { title: 'Library', search: 'Search', empty: 'Nothing here' } }
    const partial = { library: { title: 'Bibliothek' } }

    expect(deepMerge(base, partial)).toEqual({
      library: { title: 'Bibliothek', search: 'Search', empty: 'Nothing here' }
    })
  })

  it('answers a key the translation does not carry from the base', async () => {
    const { setLanguage, t } = await i18n()
    await setLanguage('de')

    // Every key of the base has to be answerable in German, whether the German
    // file carries it or not.
    expect(t('library.title')).toBe('Bibliothek')
    expect(() => t('profile.language_automatic')).not.toThrow()
  })

  // The middle step of the resolution. The server relays the tag as asked —
  // `fr-FR` for a French browser — because it cannot know whether this bundle
  // carries `fr` or `fr-FR`. Without this, a French browser saw English while
  // `fr.json` sat unused in the bundle.
  it('answers a regional tag from the language behind it', async () => {
    const { t, setLanguage } = await i18n()

    expect(await setLanguage('fr-FR')).toBe('fr')
    expect(t('library.title')).toBe('Bibliothèque')

    expect(await setLanguage('de-AT')).toBe('de')
    expect(t('library.title')).toBe('Bibliothek')
  })

  // TF-532: a language that is not installed leaves the interface usable and
  // does not raise. Somebody may have a code in their profile from before the
  // file was removed.
  //
  // The example used to be `fr`, which stopped being an example the day AP-22
  // added the file — the case then asserted that French falls back to English,
  // and failed. Any code here is a hostage to the next language, so this one
  // takes the first that is **not** on disk rather than naming one.
  it('falls back to the base for a language nobody installed', async () => {
    const { t, setLanguage, availableLanguages } = await i18n()

    const installed = availableLanguages()
    const absent = ['pt', 'nl', 'pl', 'cs', 'sv'].find((code) => !installed.includes(code))

    expect(absent).toBeDefined()
    expect(await setLanguage(absent)).toBe('en')
    expect(t('library.title')).toBe('Library')
  })

  it('offers exactly the languages that exist as files', async () => {
    const { availableLanguages } = await i18n()

    expect(availableLanguages()).toEqual(['de', 'en', 'es', 'fr', 'it'])
  })

  // Named in the language being named, not in the one currently on display.
  // Somebody who has landed in a language they cannot read has to find their
  // own in the list, and "German" is no help to a person who only reads German.
  // TF-539
  it('names a language in that language', async () => {
    const { languageName } = await i18n()

    expect(languageName('de')).toBe('Deutsch')
    expect(languageName('en')).toBe('English')
    expect(languageName('fr')).toBe('Français')
    expect(languageName('it')).toBe('Italiano')
    expect(languageName('es')).toBe('Español')
  })

  // The romance languages write their own name in lower case. Left as they
  // come, the chooser reads "Deutsch, English, español, français, italiano" —
  // three entries that look unfinished next to two that do not.
  // TF-539
  it('raises the first letter of the names that come in lower case', async () => {
    const { languageName } = await i18n()

    for (const code of ['de', 'en', 'es', 'fr', 'it']) {
      const name = languageName(code)
      expect(name[0]).toBe(name[0].toLocaleUpperCase(code))
    }
  })

  // The fallback matters more than it looks: the names come from the browser,
  // and a code the browser has never heard of must still produce an entry a
  // person can pick. An empty option would be a language that cannot be chosen.
  it('falls back to the code for a language it cannot name', async () => {
    const { languageName } = await i18n()

    expect(languageName('zzz-not-a-language')).toBe('zzz-not-a-language')
  })

  // The page has to declare its own language. A screen reader picks its voice
  // from `lang`, and nothing on the screen shows that it is wrong — a German
  // interface read aloud in an English voice is invisible to everybody who
  // does not need it.
  it('writes the language into the page itself', async () => {
    const { setLanguage } = await i18n()

    await setLanguage('de')
    expect(document.documentElement.lang).toBe('de')

    await setLanguage('en')
    expect(document.documentElement.lang).toBe('en')
  })
})

// TF-536, TF-537, TF-538 — what every language file has to hold true (AP-22).
//
// Read from disk rather than through the module, and deliberately so: the
// lookup answers a missing key from the base table, which is exactly the
// mechanism that makes a gap invisible. A translation with sixty keys missing
// works perfectly and shows English in sixty places, and nothing on the screen
// says which sixty. So the files themselves are compared.
describe('Every language file', () => {
  const HERE = path.dirname(fileURLToPath(import.meta.url))
  const LOCALES = path.resolve(HERE, '..', '..', 'frontend', 'src', 'locales')

  const read = (code) => JSON.parse(readFileSync(path.join(LOCALES, `${code}.json`), 'utf8'))

  const codes = readdirSync(LOCALES)
    .filter((name) => name.endsWith('.json'))
    .map((name) => name.slice(0, -'.json'.length))
    .filter((code) => code !== 'en')

  const flatten = (node, prefix = '') => Object.entries(node).reduce((out, [key, value]) => {
    const at = prefix ? `${prefix}.${key}` : key
    return Object.assign(out, value && typeof value === 'object' ? flatten(value, at) : { [at]: value })
  }, {})

  // `{{example}}` in a hint is the placeholder syntax being shown to the user,
  // not a slot this table fills — it is written out on purpose and translated
  // along with the sentence around it.
  const slots = (text) => [...String(text).matchAll(/(?<!\{)\{(\w+)\}(?!\})/g)].map(([, name]) => name).sort()

  const base = flatten(read('en'))

  it('is more than the base table alone', () => {
    // The counter-check for the three below: with only en.json on disk they
    // would all pass over an empty list and prove nothing at all.
    expect(codes.length).toBeGreaterThan(0)
  })

  // TF-536
  it.each(codes)('%s carries no key the base does not have', (code) => {
    const extra = Object.keys(flatten(read(code))).filter((key) => !(key in base))

    expect(extra).toEqual([])
  })

  // TF-537
  it.each(codes)('%s answers every key of the base', (code) => {
    const missing = Object.keys(base).filter((key) => !(key in flatten(read(code))))

    expect(missing).toEqual([])
  })

  // TF-538. The one a reader cannot catch: a sentence that reads perfectly and
  // has lost its `{count}` shows a number-less sentence, or an untouched
  // `{count}` where the number should be. Both look like a translation nobody
  // finished, and neither raises anything.
  it.each(codes)('%s keeps every placeholder of the base', (code) => {
    const translated = flatten(read(code))
    const drifted = Object.keys(base)
      .filter((key) => slots(base[key]).join() !== slots(translated[key]).join())
      .map((key) => `${key}: ${slots(base[key])} -> ${slots(translated[key])}`)

    expect(drifted).toEqual([])
  })

  // Not a formality: `time.locale_tag` is what dates are formatted with. Left
  // at the base value, a French interface would print English dates and look
  // like a half-applied language.
  // TF-539: the date tag is part of what a language has to bring.
  it.each(codes)('%s names its own tag for dates', (code) => {
    expect(read(code).time.locale_tag).not.toBe(base['time.locale_tag'])
    expect(read(code).time.locale_tag.startsWith(code)).toBe(true)
  })
})

describe('Following the server', () => {
  // The whole point of `Content-Language`: one negotiation, on the side that
  // can see the configuration.
  it('switches when the answer says another language', async () => {
    vi.resetModules()
    const { currentLanguage, t } = await import('../../frontend/src/i18n/index.js')
    const { get } = await import('../../frontend/src/api/client.js')

    installFakeServer([{ method: 'GET', path: '/auth/me', body: { user: SIGNED_IN_USER } }],
      { headers: { 'Content-Language': 'de' } })

    await get('/auth/me')

    expect(currentLanguage()).toBe('de')
    expect(t('library.title')).toBe('Bibliothek')
  })
})

describe('The switch in the profile (TF-530, TF-539)', () => {
  // TF-539
  it('offers every installed language and the choice of following the browser', async () => {
    vi.resetModules()
    const { default: ProfileView } = await import('../../frontend/src/views/ProfileView.vue')
    const { createAppRouter } = await import('../../frontend/src/router/index.js')

    installFakeServer([
      ...signedInRoutes(),
      { method: 'GET', path: '/workspaces', body: WORKSPACES }
    ])

    const router = createAppRouter(createMemoryHistory())
    const wrapper = mount(ProfileView, { global: { plugins: [router] } })
    await settle()

    const options = wrapper.findAll('[data-test="language"] option').map((entry) => entry.attributes('value'))
    expect(options).toEqual(['', 'de', 'en', 'es', 'fr', 'it'])
  })

  // TF-539. What stands in the list, not only what it is worth. The chooser
  // used to show the bare codes — "de", "en" — between two screens' worth of ordinary
  // sentences, which is a control that names its own implementation rather
  // than the choice it offers.
  it('shows the languages by name and not by code', async () => {
    vi.resetModules()
    const { default: ProfileView } = await import('../../frontend/src/views/ProfileView.vue')
    const { createAppRouter } = await import('../../frontend/src/router/index.js')

    installFakeServer([
      ...signedInRoutes(),
      { method: 'GET', path: '/workspaces', body: WORKSPACES }
    ])

    const router = createAppRouter(createMemoryHistory())
    const wrapper = mount(ProfileView, { global: { plugins: [router] } })
    await settle()

    const labels = wrapper.findAll('[data-test="language"] option').map((entry) => entry.text())

    // Sorted by the name on display, not by the code behind it.
    expect(labels).toEqual(['Follow the browser', 'Deutsch', 'English', 'Español', 'Français', 'Italiano'])
  })

  it('sends the chosen language and the saved name, not what stands in the form', async () => {
    vi.resetModules()
    const { default: ProfileView } = await import('../../frontend/src/views/ProfileView.vue')
    const { createAppRouter } = await import('../../frontend/src/router/index.js')

    const server = installFakeServer([
      ...signedInRoutes(),
      { method: 'PUT', path: '/auth/me', body: { user: { ...SIGNED_IN_USER, locale: 'de' } } },
      { method: 'GET', path: '/workspaces', body: WORKSPACES }
    ])

    const router = createAppRouter(createMemoryHistory())
    const wrapper = mount(ProfileView, { global: { plugins: [router] } })
    await settle()

    // A half-typed name in the form must not be saved by changing the language.
    await wrapper.find('input[type="text"]').setValue('Halb getippt')
    await wrapper.find('[data-test="language"]').setValue('de')
    await settle()

    const sent = JSON.parse(server.callsTo('PUT', '/auth/me')[0].options.body)
    expect(sent.locale).toBe('de')
    expect(sent.name).toBe(SIGNED_IN_USER.name)
  })
})

describe('A switch has to be visible', () => {
  // The claim behind `shallowRef` in the i18n module: a component that has
  // already rendered draws itself again when the language changes. Without the
  // reactive read inside `t`, the switch would only take effect on the next
  // navigation — a bug that looks intermittent and is very hard to place.
  it('redraws a component that has already rendered', async () => {
    vi.resetModules()
    const { t, setLanguage } = await import('../../frontend/src/i18n/index.js')

    const wrapper = mount({ setup: () => () => t('library.title') })
    expect(wrapper.text()).toBe('Library')

    await setLanguage('de')
    await settle()

    expect(wrapper.text()).toBe('Bibliothek')
  })
})
