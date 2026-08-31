import { describe, it, expect, afterEach, vi } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { settle } from './support/flush.js'
import { apiError } from './support/fake_server.js'
import { texts } from '../../frontend/src/i18n/index.js'
import { adminScreen, unmountAll, SETTINGS } from './support/admin.js'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const SETTINGS_SOURCE = path.resolve(HERE, '..', '..', 'backend', 'services', 'settings.rb')

// The editable keys, read from the server's own source rather than repeated
// here. One list: a setting added there without a text here fails this suite
// instead of appearing on the screen as a missing-text error at run time.
function editableKeys () {
  const source = readFileSync(SETTINGS_SOURCE, 'utf8')
  const block = source.match(/EDITABLE = %w\[([^\]]+)\]/)

  return block[1].trim().split(/\s+/)
}

// S6, settings (FA-910).
//
// Only product values are here. Operating values — address, port, paths, the
// trusted proxies — stay in config.yml, and not out of
// tidiness: a wrong one takes the instance off the network, and the screen on
// which the mistake was made is then unreachable. With the port that is
// literally so.

const realFetch = globalThis.fetch

const screen = (options = {}) => adminScreen('/administration/settings', options)

afterEach(() => {
  unmountAll()
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

// The labels are looked up by a key that is only known at run time, so the
// scan in interface_texts.test.js cannot see them. This is what covers them
// instead — and it covers more, because it starts from the server's list
// rather than from what happens to be in the text table.
describe('The label of every setting', () => {
  it('has a label and an explanation for every adjustable value', () => {
    const missing = []

    for (const key of editableKeys()) {
      const base = `setting_${key.replace('.', '_')}`
      if (!texts.admin?.[base]) missing.push(`admin.${base}`)
      if (!texts.admin?.[`${base}_hint`]) missing.push(`admin.${base}_hint`)
    }

    expect(missing).toEqual([])
  })

  it('spots a missing label', () => {
    // The counter-check: without it the case above would also pass over an
    // empty list of keys.
    expect(editableKeys().length).toBeGreaterThan(5)
    expect(texts.admin?.setting_gibt_es_nicht).toBeUndefined()
  })

  // The kinds are the other family the text scan cannot see. Read from the
  // server's own rule table, so a new kind on an editable key fails here
  // instead of reaching a form as an unreadable key.
  it('has a German explanation for every kind of value', () => {
    const source = readFileSync(SETTINGS_SOURCE, 'utf8')
    const rules = readFileSync(
      path.resolve(HERE, '..', '..', 'backend', 'services', 'configuration.rb'), 'utf8')

    const kinds = new Set()
    for (const key of editableKeys()) {
      const rule = rules.match(new RegExp(`'${key.replace('.', '\\.')}'\\s*=>\\s*:(\\w+)`))
      if (rule) kinds.add(rule[1])
    }

    expect(kinds.size).toBeGreaterThan(1)
    expect(source).toContain('EDITABLE')
    for (const kind of kinds) {
      expect(texts.admin?.[`kind_${kind}`], `admin.kind_${kind} fehlt`).toBeTruthy()
    }
  })

  it('has a label for every choice on self-registration', () => {
    for (const choice of ['off', 'approval', 'open']) {
      expect(texts.admin?.[`choice_${choice}`]).toBeTruthy()
    }
  })
})

describe('The settings screen (FA-910)', () => {
  // A control per setting, chosen by the kind the server names — a list for a
  // choice, a number field for a limit. Typing free text into a configuration
  // is what this screen exists to replace.
  it('draws the control of its kind for every setting', async () => {
    const { wrapper } = await screen()

    const mode = wrapper.find('[data-test="security.registration"]')
    expect(mode.element.tagName).toBe('SELECT')
    expect(mode.findAll('option').map((entry) => entry.element.value))
      .toEqual(['off', 'approval', 'open'])

    expect(wrapper.find('[data-test="retention.trash_days"]').element.type).toBe('number')
  })

  it('shows the values in force', async () => {
    const { wrapper } = await screen()

    expect(wrapper.find('[data-test="security.registration"]').element.value).toBe('off')
    expect(wrapper.find('[data-test="retention.trash_days"]').element.value).toBe('30')
  })

  // Somebody who has never touched a setting should be able to tell the
  // shipped default from a decision somebody made.
  it('tells defaults from the file apart from decisions that were made', async () => {
    const { wrapper } = await screen()
    const text = wrapper.find('[aria-labelledby="settings-heading"]').text()

    expect(text).toContain('Default from the configuration file')
    // `retention.audit_months` carries from_file: false in the stand-in, so
    // the note must not appear for every entry.
    const notes = wrapper.findAll('.hint').filter((entry) =>
      entry.text().includes('Default from the configuration file'))
    expect(notes.length).toBe(SETTINGS.filter((entry) => entry.from_file).length)
  })

  it('sends the changed values to the server', async () => {
    const { wrapper, server } = await screen({
      routes: [{ method: 'PUT', path: '/admin/settings', body: { settings: SETTINGS } }]
    })

    await wrapper.find('[data-test="security.registration"]').setValue('approval')
    await wrapper.find('[data-test="save-settings"]').trigger('click')
    await settle()

    const sent = JSON.parse(server.callsTo('PUT', '/admin/settings')[0].options.body)
    expect(sent.settings['security.registration']).toBe('approval')
  })

  // The server answers with the **kind** of value it expected, not with a
  // sentence: its own descriptions are the console English of the scripts
  // (I18n::BASE_LANGUAGE), and this form is German. The screen writes the
  // sentence itself — it knows the kind anyway, it draws the control from it.
  it('writes the refusal of the server in the language of the screen', async () => {
    const { wrapper } = await screen({
      routes: [{
        method: 'PUT',
        path: '/admin/settings',
        ...apiError(422, 'validation_failed', undefined,
                    { 'retention.trash_days': { kind: 'positive_integer', detail: 'eine ganze Zahl größer als 0' } })
      }]
    })

    await wrapper.find('[data-test="retention.trash_days"]').setValue('0')
    await wrapper.find('[data-test="save-settings"]').trigger('click')
    await settle()

    expect(wrapper.text()).toContain('whole number greater than 0')
    expect(wrapper.text()).not.toContain('eine ganze Zahl')
    expect(wrapper.find('[data-test="retention.trash_days"]').attributes('aria-invalid')).toBe('true')
  })

  // A kind the screen has no sentence for is possible — a new rule on the
  // server, an older interface. "Not permitted" is still true, and better
  // than printing a key nobody can read.
  it('stays understandable for a kind it does not know yet', async () => {
    const { wrapper } = await screen({
      routes: [{
        method: 'PUT',
        path: '/admin/settings',
        ...apiError(422, 'validation_failed', undefined,
                    { 'retention.trash_days': { kind: 'gibt_es_noch_nicht' } })
      }]
    })

    await wrapper.find('[data-test="retention.trash_days"]').setValue('0')
    await wrapper.find('[data-test="save-settings"]').trigger('click')
    await settle()

    expect(wrapper.text()).toContain('not allowed')
    expect(wrapper.text()).not.toContain('gibt_es_noch_nicht')
  })

  // No restart button, and none is needed: the application reads its
  // configuration on every request. A button would be worse than useless — in
  // three of the four operating modes of E-14 nothing would start the
  // application again, and nobody would be signed in to notice.
  it('offers no restart', async () => {
    const { wrapper } = await screen()

    const labels = wrapper.findAll('button').map((entry) => entry.text())
    expect(labels.some((label) => /neu\s*start/i.test(label))).toBe(false)
    expect(wrapper.text()).toContain('no restart is needed')
  })

  // The screen must not offer what the server refuses — an operating value
  // here would be a control that always answers 422.
  it('shows no operating values', async () => {
    const { wrapper } = await screen()
    const text = wrapper.find('[aria-labelledby="settings-heading"]').text()

    expect(text).not.toContain('server.port')
    expect(text).not.toContain('trusted_proxies')
    expect(wrapper.find('[data-test="server.port"]').exists()).toBe(false)
  })
})
