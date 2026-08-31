import { shallowRef } from 'vue'
import base from '@/locales/en.json'

// User-facing texts of the interface (NFA-15, E-12, 11.7).
//
// The counterpart to backend/services/i18n.rb and deliberately built the same
// way: a dotted lookup path, placeholders in curly braces, no library. Two
// implementations of a lookup table are cheaper than one shared dependency
// that has to work in Ruby and in the browser.
//
// **English is the base table and is always in the bundle.** Every other
// language is laid over it at runtime, so a translation that does not carry a
// key is answered from the base rather than leaving a hole. A statically
// imported language would mean one language per build, which is the thing this
// package exists to end.
//
// **The language is not decided here.** The server negotiates it — profile,
// then config.yml, then Accept-Language — and says so in `Content-Language` on
// every answer. Deciding it a second time in the browser would be a second
// truth: an operator who wrote `locale: de` into config.yml would get a German
// API inside an English interface, and nothing would report the disagreement.
//
// The one difference to the backend is what happens on a missing key. The
// backend raises, because a broken message there ends up in a log. Here it
// would end up in a render function, and an exception during render leaves the
// user with a blank page — a worse outcome than an untranslated word. So it
// raises everywhere except in the production build, where an incomplete
// translation is the normal case and the base table answers instead.

export const BASE_LANGUAGE = 'en'

// Every file in locales/ is a language, and the list of languages is the list
// of files — that is what makes "a new language is one file" true rather than
// a promise. Loaded lazily, so a language nobody selects costs nothing.
const loaders = import.meta.glob('../locales/*.json')

const codeOf = (path) => path.slice(path.lastIndexOf('/') + 1, -'.json'.length)

// `shallowRef` and not a plain variable: `t` is called during render, so
// reading `.value` here is what makes a component re-render when the language
// changes. Without it the switch would take effect on the next navigation and
// look like a bug that comes and goes.
const table = shallowRef(base)
const active = shallowRef(BASE_LANGUAGE)

let failOnMissing = !import.meta.env.PROD

// For tests: switch the behaviour deliberately instead of guessing at the
// build mode. Returns the previous value so a test can restore it.
export function failOnMissingTexts (value) {
  const previous = failOnMissing
  failOnMissing = value
  return previous
}

export function availableLanguages () {
  return Object.keys(loaders).map(codeOf).sort()
}

// What a language is called, in that language. `de` reads "Deutsch", not
// "German" — somebody who cannot read the interface they are looking at has to
// be able to find their own language in the list, and that is the whole job of
// this chooser.
//
// Asked of the browser rather than kept in a table here. A table would be a
// second place to edit whenever a language file is added, and "a new language
// is one file" is the promise this module makes; the second place is the one
// that gets forgotten. Unknown or malformed codes fall back to the code
// itself, which is still an answer a person can act on.
export function languageName (code) {
  try {
    const name = new Intl.DisplayNames([code], { type: 'language' }).of(code)
    return name ? capitalised(name, code) : code
  } catch {
    return code
  }
}

// The romance languages write their own name in lower case — `español`,
// `français`, `italiano` — while German and English capitalise. A list mixing
// the two reads like three entries somebody forgot to finish, so the first
// letter is raised. That is what a language chooser does; it is a list of
// names, not a sentence.
//
// `toLocaleUpperCase` with the language's own code, not the plain one: in
// Turkish the capital of `i` is `İ`, and the rule that is right for the list
// has to be right for every entry in it.
function capitalised (name, code) {
  return name.charAt(0).toLocaleUpperCase(code) + name.slice(1)
}

export function currentLanguage () {
  return active.value
}

// Which of the files on hand answers for a code, in three steps: the code
// itself, its primary subtag, the base.
//
// The middle step is the one that earns its place. The server relays the most
// specific tag the request asked for — a browser sending `fr-FR` gets
// `Content-Language: fr-FR` — and it is right not to trim it, because it
// cannot know whether this bundle carries `fr` or `fr-FR`. **This** side knows.
// Without the step, a French browser landed on English while `fr.json` sat in
// the bundle unused.
function resolve (code) {
  const have = availableLanguages()
  const wanted = String(code ?? '')

  if (have.includes(wanted)) return wanted

  const primary = wanted.split('-')[0]
  return have.includes(primary) ? primary : BASE_LANGUAGE
}

// Applies a language. Unknown codes fall back to the base rather than raising:
// a language file can be removed while somebody has it in their profile, and
// that person has to keep working (11.7).
export async function setLanguage (code) {
  const wanted = resolve(code)

  if (wanted !== BASE_LANGUAGE) {
    const module = await loaders[`../locales/${wanted}.json`]()
    table.value = deepMerge(base, module.default ?? module)
  } else {
    table.value = base
  }

  active.value = wanted
  // The page has to say which language it is in. `lang` is what a screen
  // reader picks its voice from and what the browser hyphenates by — leaving
  // it at whatever index.html was built with means a German interface read
  // aloud in an English voice, and nothing on the screen shows it.
  if (typeof document !== 'undefined') document.documentElement.lang = wanted
  return wanted
}

export function t (key, replacements = {}) {
  const value = lookup(table.value, key)
  if (typeof value === 'string') return interpolate(value, replacements)

  // The language file may carry the key as something that is not a sentence —
  // an object where the base has a string, say, which deep merging lets
  // through. The base is asked before anything is given up.
  const fallback = lookup(base, key)
  if (typeof fallback === 'string') return interpolate(fallback, replacements)

  if (failOnMissing) throw new Error(`Unknown text key: ${key}`)
  return String(key)
}

function lookup (source, key) {
  return String(key).split('.').reduce(
    (node, part) => (node && typeof node === 'object' ? node[part] : undefined),
    source
  )
}

// Merged **deeply**, so a translation may override a single entry of a
// namespace without repeating the whole namespace. Replacing per namespace
// would let one translated sentence take the other sixty of its namespace
// with it — and those sixty would then be missing, not English.
//
// Exported for the test that proves exactly that. It cannot be shown through
// the delivered files, because `de.json` is complete and a complete
// translation hides the difference between merging and replacing — which is
// precisely why the mistake would survive to the first incomplete language.
export function deepMerge (lower, upper) {
  const result = { ...lower }

  for (const [key, value] of Object.entries(upper)) {
    const existing = result[key]
    result[key] = isPlainObject(existing) && isPlainObject(value)
      ? deepMerge(existing, value)
      : value
  }

  return result
}

const isPlainObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value)

function interpolate (template, replacements) {
  return template.replace(/\{(\w+)\}/g, (whole, name) => (
    Object.hasOwn(replacements, name) ? String(replacements[name]) : whole
  ))
}

// The raw tables, for the test that checks every key used in the code exists
// and that no language carries a key the base does not have.
export { base as texts, base }
