// The rendering pipeline — Requirements chapter 8, normative.
//
// The second of two implementations. The first is
// backend/services/rendering.rb, and both must produce **character-identical**
// output (NFA-14, R-01): the preview here shows what a later model call
// receives from there, and a difference between them would be invisible until
// somebody compared the two by hand.
//
// The 34 vectors in tests/vectors/rendering.json are read by the Minitest
// suite and by the Vitest suite from the same file. A divergence therefore
// shows up in a test run rather than at the user.
//
// This file is a deliberate line-by-line port. Where the two languages differ
// the comment says so — those are the places a divergence would come from:
//
//   * Ruby's `$` matches the end of a *line*, JavaScript's only the end of
//     the string unless the m flag is given (step 4, second rule)
//   * `\A` and `\z` are `^` and `$` without that flag
//   * `gsub` with a string argument replaces literally, without a pattern
//
// Free of any dependency on Vue or the API, as its Ruby counterpart is free
// of Sinatra and the database (NFA-14).
//
// Besides the text, the pipeline reports **where** it put things: `renderMarked`
// returns one mark per substituted variable, in positions of the *finished*
// text. Requirements 8.3 asks for the spot of a missing mandatory value to be
// marked in the preview, and only a position in the finished text says where
// that spot is — the position from step 2 would be wrong, because steps 2b to
// 4 go on moving everything around.
//
// The marks ride **along** the single pipeline instead of being worked out by
// a second one. `render` is `renderMarked` with the marks dropped, so the text
// cannot depend on whether anybody asked for them. A second implementation of
// the pipeline, however careful, would be a third place for R-01 to happen.

// What may stand between the braces, per 8.2: a letter followed by up to 39
// letters, digits or underscores.
//
// **The `u` flag is load-bearing, and its absence would not be an error.**
// `\p{L}` without it is not a Unicode property at all — it is the literal
// letters `p`, `{`, `L`, `}` — so the pattern would go on matching something,
// just not this. That is the whole reason the case comparing this side with
// the server exists (TF-541): the two are one rule written twice, and a
// difference between them is silent by nature.
//
// Letters and not ASCII letters since AP-23: the prompt text is the user's
// content, and `{{año}}` used to be no variable and no error either.
//
// The length bound is part of the pattern, not a check afterwards: a key of 41
// characters is not a variable at all (14.3). With `u` the count is in code
// points, which is what the server counts too.
const KEY = String.raw`[\p{L}][\p{L}\p{N}_]{0,39}`

const REFERENCE = new RegExp(String.raw`(\\)?\{\{[ \t]*(${KEY})[ \t]*\}\}`, 'gu')

// Something that was meant to be a reference and is not one — see the Ruby
// side for why this exists: the failure it catches is silent.
const CANDIDATE = new RegExp(String.raw`(\\)?\{\{([^{}\n]{0,80})\}\}`, 'gu')

const EXACT_KEY = new RegExp(String.raw`^${KEY}$`, 'u')
const ESCAPED_OPENING = '\\{{'
const BLOCK_SEPARATOR = '\n\n'

// +body+       the prompt text
// +variables+  metadata and bindings: key, value, default_value, required
// +keywords+   active keywords: name, text, position, sort_order
export function render (input) {
  const { marks, ...result } = renderMarked(input)
  return result
}

// The same, plus the marks. Each one is `{ key, start, end, filled }` with
// `start`/`end` as offsets into the finished text.
//
// `showPlaceholders` is what the preview asks for: a variable with no value
// puts its own `{{key}}` in as the value, so the surrounding text is laid out
// around **something**. The difference matters more than it looks. With
//
//     Deute diesen Protokollauszug:
//
//     {{auszug}}
//
//     Was ist passiert?
//
// an unfilled `auszug` contributes nothing, the four line breaks collapse to
// two (step 4), and a placeholder drawn into *that* text afterwards ends up
// glued to the following sentence. Laying out around the placeholder gives
// the shape the prompt will have once it is filled in — which is what the
// preview is for.
//
// The finished text keeps its own answer: `render` never asks for this, so
// what gets copied and counted is unaffected (8.3.1).
export function renderMarked ({ body, variables = [], keywords = [], showPlaceholders = false } = {}) {
  const table = variableTable(variables)

  const { unknown, ...substituted } = substitute(String(body ?? ''), table, showPlaceholders) // step 2
  const unescaped = resolveEscapes(substituted) // step 2b
  const withKeywords = applyKeywords(unescaped, keywords) // step 3
  const normalized = normalize(withKeywords) // step 4

  const missing = missingRequired(table)

  return {
    text: normalized.text,
    marks: normalized.marks,
    unknownKeys: unknown,
    rejectedKeys: rejectedKeys(String(body ?? '')),
    missingRequired: missing,
    complete: missing.length === 0
  }
}

// The placeholders somebody wrote that 8.2 does not accept — read from the
// **original** text, before anything was substituted, because that is where
// they still stand exactly as they were typed. An escaped one is a deliberate
// literal and not a mistake.
export function rejectedKeys (body) {
  const found = []

  for (const [, escaped, inner] of body.matchAll(freshly(CANDIDATE))) {
    if (escaped) continue

    const candidate = inner.trim()
    if (!EXACT_KEY.test(candidate) && !found.includes(candidate)) found.push(candidate)
  }

  return found
}

// --- step 2: variables ------------------------------------------------------

// One pass, no recursion. A value that itself contains {{...}} stays as it is
// — otherwise a variable value could smuggle in foreign variables or cause an
// endless loop (8.2).
//
// Escaped references are stepped over here and only lose their backslash in
// step 2b. Doing both at once would make the order of the two rules
// unobservable, and this side could get it wrong unnoticed.
//
// Written out as a scan rather than as `replace` with a function, because the
// mark needs the offset in the text **being built** — which a replace callback
// is never told. The replacements themselves are the same ones in the same
// order, so the text is unchanged.
function substitute (body, table, showPlaceholders = false) {
  const unknown = []
  const marks = []
  let text = ''
  let read = 0

  for (const match of body.matchAll(freshly(REFERENCE))) {
    const [whole, escaped, name] = match
    text += body.slice(read, match.index)
    read = match.index + whole.length

    if (escaped) {
      text += whole
      continue
    }

    const key = name.toLowerCase()
    const entry = table.get(key)
    if (entry === undefined) {
      if (!unknown.includes(key)) unknown.push(key)
      text += whole
      continue
    }

    const value = valueFor(entry)
    // `filled` follows the real value, never the stand-in. Everything that
    // decides something — the missing mandatory values, the copy — reads the
    // value; only the drawing reads the stand-in.
    const shown = value === '' && showPlaceholders ? `{{${key}}}` : value

    marks.push({ key, start: text.length, end: text.length + shown.length, filled: value !== '' })
    text += shown
  }

  text += body.slice(read)

  return { text, marks, unknown }
}

// User input, or the default when the input is empty, or empty text when
// there is no default either (8.1 step 2). An empty input and no input at all
// behave the same — the requirement says "falls Eingabe leer".
function valueFor (entry) {
  const value = entry.value
  if (value !== null && value !== undefined && String(value) !== '') return String(value)

  return entry.default_value === null || entry.default_value === undefined
    ? ''
    : String(entry.default_value)
}

// --- step 2b: escapes -------------------------------------------------------

// Applies to the **whole** result of step 2, including substituted values
// (8.2). A position-dependent rule would be nearly impossible to implement
// identically in two languages, and it is harmless here because no further
// substitution follows.
//
// A literal left-to-right scan rather than a regular expression: the Ruby side
// passes a string to gsub, which replaces literally. A pattern would have to
// escape the backslash and the braces, and getting that wrong is a silent
// difference. `split(needle).join(…)` scans the same way and was what stood
// here before the marks needed the positions of the cuts.
function resolveEscapes (state) {
  return applyEdits(state, literalEdits(state.text, ESCAPED_OPENING, '{{'))
}

function literalEdits (text, needle, replacement) {
  const edits = []
  let at = text.indexOf(needle)

  while (at !== -1) {
    edits.push([at, needle.length, replacement])
    at = text.indexOf(needle, at + needle.length)
  }

  return edits
}

// --- step 3: keywords -------------------------------------------------------

// Keyword texts are added here and never pass through steps 2 or 2b. A
// {{placeholder}} inside a keyword stays untouched, and so does a backslash
// before it — keywords are plain text blocks (E-05).
function applyKeywords (state, keywords) {
  const sorted = sortKeywords(keywords)
  const prepend = blockFor(sorted, 'prepend')
  const append = blockFor(sorted, 'append')

  const text = [prepend, state.text, append].filter((part) => part !== null && part !== '')
    .join(BLOCK_SEPARATOR)

  // Everything the body contributed moves right by the prepended block. The
  // offset is worked out even when the body itself was dropped for being
  // empty: the position where it would have started is still where its
  // variables belong, and that is the one thing left to show for a prompt
  // whose whole text is a single placeholder.
  const offset = prepend === '' ? 0 : prepend.length + BLOCK_SEPARATOR.length

  return { text, marks: state.marks.map((mark) => shift(mark, offset)) }
}

function shift (mark, offset) {
  return { ...mark, start: mark.start + offset, end: mark.end + offset }
}

// By sort_order, then by name. The second key is what makes the result
// deterministic when two keywords share an order (TF-120); without it the
// output would depend on the order they happen to arrive in.
//
// The name comparison is by code unit, which matches Ruby's byte order for
// the ASCII names the catalogue allows. Two keywords of the same order whose
// names differ only beyond ASCII would be the one case where the two sides
// could disagree — noted here rather than guarded against, because the
// catalogue does not produce them.
function sortKeywords (keywords) {
  return [...keywords].sort((one, other) => {
    const order = wholeNumber(one.sort_order) - wholeNumber(other.sort_order)
    if (order !== 0) return order

    return compare(String(one.name ?? ''), String(other.name ?? ''))
  })
}

function blockFor (sorted, position) {
  return sorted
    .filter((keyword) => String(keyword.position ?? '') === position)
    .map((keyword) => String(keyword.text ?? ''))
    .filter((text) => text !== '')
    .join(BLOCK_SEPARATOR)
}

// --- step 4: normalisation --------------------------------------------------

// The order of these five is load-bearing, and TF-134 is the vector that
// proves it: with "A\n\n   \n\nB" — a line of nothing but spaces between two
// blank ones — stripping first yields "A\n\nB", collapsing first yields
// "A\n\n\n\nB".
const LINE_ENDINGS = /\r\n?/g
// The m flag is the whole difference to the Ruby line: there `$` means the
// end of a line already, here it would mean the end of the text and only the
// very last line would be stripped.
const TRAILING_SPACES = /[ \t]+$/gm
const REPEATED_BREAKS = /\n{3,}/g
const LEADING_BREAKS = /^\n+/ // \A in Ruby — no m flag, so the text, not a line
const TRAILING_BREAKS = /\n+$/ // \z in Ruby

// Step 4 alone, on plain text. Exported because the preview's promise is
// stated in terms of it: take what is on the screen, drop the drawn
// placeholders, normalise — and the finished text has to come back. Without
// that, "the display is the copy plus placeholders and nothing else" would be
// a claim nobody checks.
export function normalizeText (text) {
  return normalize({ text: String(text ?? ''), marks: [] }).text
}

function normalize (state) {
  let result = replaceTracked(state, LINE_ENDINGS, '\n')
  result = replaceTracked(result, TRAILING_SPACES, '')
  result = replaceTracked(result, REPEATED_BREAKS, '\n\n')
  result = replaceTracked(result, LEADING_BREAKS, '')
  result = replaceTracked(result, TRAILING_BREAKS, '')

  return result
}

// --- carrying the marks -----------------------------------------------------

// Every step above is a set of replacements at known places. Rather than
// letting each one work out for itself where the marks end up, they all hand
// the replacements here and the bookkeeping happens once.
//
// The edits must be ordered and must not overlap, which is what both sources
// produce: `matchAll` and a left-to-right `indexOf` scan.
function replaceTracked (state, pattern, replacement) {
  const edits = []

  if (pattern.global) {
    for (const match of state.text.matchAll(freshly(pattern))) {
      edits.push([match.index, match[0].length, replacement])
    }
  } else {
    const match = pattern.exec(state.text)
    if (match) edits.push([match.index, match[0].length, replacement])
  }

  return applyEdits(state, edits)
}

function applyEdits (state, edits) {
  if (edits.length === 0) return state

  let text = ''
  let read = 0
  const jumps = []

  for (const [start, length, replacement] of edits) {
    text += state.text.slice(read, start)
    const from = text.length
    text += replacement
    jumps.push({ start, end: start + length, from, to: text.length })
    read = start + length
  }
  text += state.text.slice(read)

  const marks = state.marks.map((mark) => {
    const start = moved(jumps, mark.start, 'start')
    const end = moved(jumps, mark.end, 'end')
    // A mark can never turn itself inside out: both ends may be pulled to the
    // same place, but the end never lands before the start.
    return { ...mark, start, end: Math.max(start, end) }
  })

  return { text, marks }
}

// Where a position of the old text ends up in the new one.
//
// A position **inside** an edited stretch has no exact counterpart, so the
// mark gives that stretch up: a start moves to the far end of the replacement,
// an end to its near one. The mark shrinks rather than grows.
//
// That only matters where a replacement is not empty, because a deletion
// leaves both edges in the same place. The case is a value that ends — or
// begins — with a line break which then collapses together with the body's:
// growing would tint the collapsed blank line as if it came from the value,
// and a coloured empty line is a thing nobody can read a meaning into.
//
// Where a mark surrounds an edit completely, neither branch applies and the
// mark keeps it; where it lies entirely inside one, both ends land in the same
// place and the caller's clamp turns it into an empty mark — the value has
// been used up, and nothing of it is left to point at.
function moved (jumps, position, side) {
  let delta = 0

  for (const jump of jumps) {
    if (jump.end <= position) {
      delta += (jump.to - jump.from) - (jump.end - jump.start)
      continue
    }
    if (jump.start <= position) return side === 'end' ? jump.from : jump.to

    break
  }

  return position + delta
}

// A copy, because `matchAll` reads `lastIndex` from the pattern it is given
// and the patterns here are module-level constants. Nothing in this file
// leaves one advanced today; a `test` or `exec` added later in the wrong place
// would silently skip the first matches, and this is a cheaper guard than the
// test that would have to notice it.
function freshly (pattern) {
  return new RegExp(pattern.source, pattern.flags)
}

// --- helpers ----------------------------------------------------------------

function variableTable (variables) {
  const table = new Map()

  for (const variable of variables) {
    const key = String(variable.key ?? '').toLowerCase()
    if (key === '') continue

    table.set(key, variable)
  }
  return table
}

// Required, and neither bound nor given a default (8.3). The preview is still
// produced; the caller disables copying.
function missingRequired (table) {
  return [...table.entries()]
    .filter(([, entry]) => Boolean(entry.required) && valueFor(entry) === '')
    .map(([key]) => key)
}

// Ruby's to_i on a string, on nil and on a number, in the cases that occur
// here: "10" and 10 give 10, everything else 0.
function wholeNumber (value) {
  const parsed = Number.parseInt(value, 10)
  return Number.isNaN(parsed) ? 0 : parsed
}

function compare (one, other) {
  if (one === other) return 0
  return one < other ? -1 : 1
}

// The keys a text actually references, lower-cased and in order of first
// occurrence (FA-301). Same pattern as the renderer uses — two separate
// notions of "what is a variable" would let a prompt carry metadata for
// something that never renders.
export function variableKeys (body) {
  const keys = []

  String(body ?? '').replace(REFERENCE, (whole, escaped, name) => {
    if (escaped) return whole

    const key = name.toLowerCase()
    if (!keys.includes(key)) keys.push(key)
    return whole
  })

  return keys
}

// Characters and words of the finished prompt (11.4). Words are runs of
// non-whitespace: the figure is there to judge the length for a model with a
// limit, not to be a linguistic statement.
export function measure (text) {
  const source = String(text ?? '')
  const words = source.split(/\s+/).filter((word) => word !== '')

  return { characters: [...source].length, words: words.length }
}
