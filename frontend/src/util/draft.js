// What the editor works on, as plain data (S3, Requirements 11.5).
//
// The mechanics of a draft are separated from the screen that shows it for the
// same reason the rendering pipeline is: they are decidable without a browser,
// and the two rules below are the ones worth deciding carefully.
//
//   * The **set** of variables follows from the text and from nothing else
//     (FA-301). Typing `{{thema}}` creates one, deleting the last occurrence
//     removes it. There is no separate step, and the editor offers none.
//   * Their **order** belongs to the author (FA-302). It is not the order of
//     the text: whoever writes a prompt knows better than the parser which
//     question comes first.
//
// Those two pull in opposite directions, and `syncVariables` is where they
// meet.

import { variableKeys } from '@/util/rendering'

// The three vocabularies of a prompt, each value with the key of its label.
//
// Written out as `label: '…'` rather than assembled from the value, because
// that is the shape the coverage check reads (TF-713). A key built at runtime
// is a text the check reports as unused — and one day it would be right.
//
// One list per vocabulary, read by the editor **and** by the reader's screen.
// Two copies would be two places to add a value to, and the second would be
// the one that gets forgotten.
export const VARIABLE_TYPES = [
  { value: 'text', label: 'editor.type_text' },
  { value: 'multiline', label: 'editor.type_multiline' },
  { value: 'select', label: 'editor.type_select' },
  { value: 'number', label: 'editor.type_number' }
]

export const VISIBILITIES = [
  { value: 'private', label: 'prompt.visibility_private' },
  { value: 'workspace', label: 'prompt.visibility_workspace' },
  { value: 'instance', label: 'prompt.visibility_instance' }
]

export const STATUSES = [
  { value: 'draft', label: 'prompt.status_draft' },
  { value: 'active', label: 'prompt.status_active' },
  { value: 'archived', label: 'prompt.status_archived' }
]

const KNOWN_TYPES = VARIABLE_TYPES.map((entry) => entry.value)

export function emptyDraft ({ title = '' } = {}) {
  return {
    title,
    description: '',
    body: '',
    model_hint: '',
    visibility: 'private',
    status: 'draft',
    tags: [],
    variables: []
  }
}

// A prompt as it comes from the server, as something to edit. Absent values
// become empty strings: a form field bound to null renders the word "null".
export function draftFrom (prompt) {
  return {
    title: prompt.title ?? '',
    description: prompt.description ?? '',
    body: prompt.body ?? '',
    model_hint: prompt.model_hint ?? '',
    visibility: prompt.visibility ?? 'private',
    status: prompt.status ?? 'draft',
    tags: [...(prompt.tags ?? [])],
    variables: [...(prompt.variables ?? [])]
      .sort((one, other) => (one.position ?? 0) - (other.position ?? 0))
      .map((variable) => ({
        key: variable.key,
        label: variable.label ?? '',
        type: KNOWN_TYPES.includes(variable.type) ? variable.type : 'text',
        default_value: variable.default_value ?? '',
        options: optionsOf(variable),
        required: variable.required === true
      }))
  }
}

// Options are a list here, as in the exchange format (17.1); the database
// keeps one per line (14.1) and the API answers in that shape.
function optionsOf (variable) {
  if (Array.isArray(variable.options)) return variable.options.filter((option) => option !== '')

  return String(variable.options ?? '').split('\n').map((option) => option.trim())
    .filter((option) => option !== '')
}

// The variable list after the text changed.
//
// Metadata already entered is kept, entries whose occurrence is gone are
// dropped, and a newly typed key appears **where it was typed** — after the
// last known key that precedes it in the text. Appending everything to the end
// would be simpler and wrong: in the ordinary case, where nobody has reordered
// anything, a variable typed into the middle would jump to the bottom.
export function syncVariables (body, existing) {
  const detected = variableKeys(body)
  const known = new Map(existing.map((variable) => [variable.key, variable]))
  const kept = existing.filter((variable) => detected.includes(variable.key))

  let at = 0
  for (const key of detected) {
    const place = kept.findIndex((variable) => variable.key === key)
    if (place >= 0) {
      at = place + 1
      continue
    }

    kept.splice(at, 0, known.get(key) ?? newVariable(key))
    at += 1
  }

  return kept
}

function newVariable (key) {
  return { key, label: '', type: 'text', default_value: '', options: [], required: false }
}

export function moveVariable (variables, key, by) {
  const from = variables.findIndex((variable) => variable.key === key)
  const to = from + by
  if (from < 0 || to < 0 || to >= variables.length) return variables

  const moved = [...variables]
  moved.splice(to, 0, ...moved.splice(from, 1))
  return moved
}

// What goes to the server. `position` is sent explicitly — the service takes
// it as the author's decision and renumbers to 0..n-1 (FA-302). Without it
// every variable would fall back to the order of the text.
export function payloadOf (draft) {
  return {
    title: draft.title.trim(),
    description: draft.description,
    body: draft.body,
    model_hint: draft.model_hint,
    visibility: draft.visibility,
    status: draft.status,
    tags: draft.tags,
    variables: draft.variables.map((variable, position) => ({
      key: variable.key,
      label: variable.label,
      type: variable.type,
      default_value: variable.default_value,
      // Only a selection carries options. Sending them for a text field would
      // store a promise no form ever shows (TF-449 checks the same rule on the
      // example package).
      //
      // Tidied **here** and nowhere earlier: while they are being typed the
      // options may have a trailing empty line and spaces at the ends, because
      // that is what a half-written list looks like. Cleaning up on every
      // keystroke took the line break away as it was typed.
      options: variable.type === 'select' ? tidyOptions(variable.options) : [],
      required: variable.required,
      position
    }))
  }
}

function tidyOptions (options) {
  return options.map((option) => String(option).trim()).filter((option) => option !== '')
}

// Whether anything was touched, for the question asked on the way out (11.5).
// Compared on the payload rather than field by field: the payload is what a
// save would send, so anything it cannot see is by definition not a change.
export function changed (draft, original) {
  return JSON.stringify(payloadOf(draft)) !== JSON.stringify(payloadOf(original))
}

// The variables as the preview needs them: the default value stands in for
// what the reader will type later (11.5).
export function withDefaults (draft) {
  return draft.variables.map((variable) => ({ ...variable, value: variable.default_value }))
}

// Tags are free text and land in a URL and in a filter list. Trimmed,
// de-duplicated, empties dropped — the server would take them, and a tag made
// of one space is a chip nobody can name.
export function addTag (tags, name) {
  const clean = String(name ?? '').trim()
  if (clean === '' || tags.includes(clean)) return tags

  return [...tags, clean]
}
