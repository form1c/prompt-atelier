import { describe, it, expect, afterEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { createMemoryHistory } from 'vue-router'
import { settle } from './support/flush.js'
import {
  installFakeServer, signedInRoutes, apiError, WORKSPACES, ownerWorkspaces
} from './support/fake_server.js'

// S10 — import and export (FA-801 to FA-804, W-8, TF-357).
//
// The rules are the server's and are checked there. What is checked here is
// the one sentence of W-8 that is a statement about the **screen**: "Kein
// Import ohne vorherige Vorschau." So the question this suite keeps asking is
// not whether the import works, but whether there is any way to reach it
// without the preview.

const realFetch = globalThis.fetch

const previewBody = (overrides = {}) => ({
  preview: {
    prompts: [{ index: 0, title: 'Ganz neu', state: 'new', decisions: [], candidates: [] }],
    new_count: 1,
    collision_count: 0,
    keywords: { to_create: [], missing: [], conflicts: [] },
    unknown_fields: [],
    ...overrides
  }
})

// A keyword whose name is already taken in the target. It used to appear in
// neither keyword line of the preview, and the definition in the file was
// dropped without a word.
const keywordConflictPreview = previewBody({
  keywords: {
    to_create: [],
    missing: [],
    conflicts: [{
      index: 0,
      name: 'formal',
      decisions: ['skip', 'overwrite'],
      identical: false,
      existing: { name: 'formal', text: 'Schreibe sachlich.', position: 'append', sort_order: 10 },
      incoming: { name: 'formal', text: 'Sei knapp.', position: 'append', sort_order: 10 }
    }]
  }
})

const identicalKeywordPreview = previewBody({
  keywords: {
    to_create: [],
    missing: [],
    conflicts: [{
      index: 0,
      name: 'formal',
      decisions: ['skip', 'overwrite'],
      identical: true,
      existing: { name: 'formal', text: 'Schreibe sachlich.', position: 'append', sort_order: 10 },
      incoming: { name: 'formal', text: 'Schreibe sachlich.', position: 'append', sort_order: 10 }
    }]
  }
})

const collidingPreview = previewBody({
  prompts: [
    { index: 0, title: 'Ganz neu', state: 'new', decisions: [], candidates: [] },
    {
      index: 1,
      title: 'Blogartikel-Generator',
      state: 'collision',
      decisions: ['skip', 'copy', 'overwrite'],
      candidates: [{ id: 5, title: 'Blogartikel-Generator', updated_at: '2026-07-01T10:00:00+02:00' }]
    }
  ],
  new_count: 1,
  collision_count: 1
})

const mounted = []

async function screen ({ routes = [], workspaces = WORKSPACES } = {}) {
  const server = installFakeServer([
    ...routes,
    { method: 'GET', path: '/workspaces', body: workspaces },
    ...signedInRoutes()
  ])
  vi.resetModules()
  const { default: App } = await import('../../frontend/src/App.vue')
  const { createAppRouter } = await import('../../frontend/src/router/index.js')

  const router = createAppRouter(createMemoryHistory())
  const wrapper = mount(App, { global: { plugins: [router] }, attachTo: document.body })
  mounted.push(wrapper)
  await router.push('/transfer')
  await settle()

  return { wrapper, router, server }
}

// Picking a file, without a browser. `File.text()` is what the screen calls;
// jsdom has the constructor but the suite would still need a real file, so the
// event carries a stand-in with exactly the two members the screen uses.
async function pick (wrapper, content, name = 'export.json') {
  const input = wrapper.find('[data-test="file"]')
  Object.defineProperty(input.element, 'files', {
    configurable: true,
    value: [{ name, text: async () => content }]
  })
  await input.trigger('change')
  await settle()
}

const sent = (server, fragment) => JSON.parse(server.callsTo('POST', fragment).at(-1).options.body)

// `callsTo` matches by substring, and "/import" is a substring of
// "/import/preview" — so counting calls to the writing endpoint that way
// counts the preview as well and can never fail. The path has to end there.
const writingCalls = (server) => server.calls.filter(
  (call) => call.method === 'POST' && call.path.endsWith('/import')
)

// jsdom has no object URLs. Stubbed rather than avoided, so the handing-over
// is really walked through and the file name can be asserted — the name is a
// rule of its own (util/download.js), not a detail.
function catchDownloads () {
  const handed = []
  URL.createObjectURL = (blob) => {
    handed.push(blob)
    return 'blob:test'
  }
  URL.revokeObjectURL = () => {}
  const clicks = []
  const original = document.createElement.bind(document)
  vi.spyOn(document, 'createElement').mockImplementation((tag) => {
    const element = original(tag)
    if (tag === 'a') {
      element.click = () => clicks.push(element.download)
    }
    return element
  })

  return clicks
}

afterEach(() => {
  while (mounted.length) mounted.pop().unmount()
  globalThis.fetch = realFetch
  vi.restoreAllMocks()
})

describe('Export (FA-801, FA-803)', () => {
  it('fetches the export in the chosen format and hands it on as a file', async () => {
    const clicks = catchDownloads()
    const { wrapper, server } = await screen({
      routes: [{
        method: 'POST',
        path: '/export',
        body: { format: 'json', filename: 'marketing-2026-08-02.json', package: { prompts: [] } }
      }]
    })

    await wrapper.find('[data-test="export"]').trigger('click')
    await settle()

    expect(sent(server, '/export')).toEqual({ workspace_id: 9, format: 'json' })
    // The name comes from the server, which owns the slug rule (14.2). The
    // screen must use it rather than build one of its own.
    expect(clicks).toEqual(['marketing-2026-08-02.json'])
  })

  // 17.2: one file per prompt, so one download per prompt — not everything
  // stuffed into a single file that no importer would read back.
  it('hands on one file per prompt for Markdown', async () => {
    const clicks = catchDownloads()
    const { wrapper } = await screen({
      routes: [{
        method: 'POST',
        path: '/export',
        body: {
          format: 'markdown',
          files: [{ name: 'erster.md', content: '---\ntitle: Erster\n---\n\nText.' },
                  { name: 'zweiter.md', content: '---\ntitle: Zweiter\n---\n\nText.' }]
        }
      }]
    })

    await wrapper.findAll('input[type="radio"]')[1].setValue(true)
    await wrapper.find('[data-test="export"]').trigger('click')
    await settle()

    expect(clicks).toEqual(['erster.md', 'zweiter.md'])
  })

  it('sends the Markdown format when it is chosen', async () => {
    const { wrapper, server } = await screen({
      routes: [{ method: 'POST', path: '/export', body: { format: 'markdown', files: [] } }]
    })

    await wrapper.findAll('input[type="radio"]')[1].setValue(true)
    await wrapper.find('[data-test="export"]').trigger('click')
    await settle()

    expect(sent(server, '/export').format).toBe('markdown')
  })

  // FA-803 and 17.2: Markdown is not a removal van. The limitation belongs
  // where the choice is made — learning it later, when the timestamps are
  // gone, is too late.
  it('names the limitation of Markdown at the choice', async () => {
    const { wrapper } = await screen()

    expect(wrapper.text()).toContain('Without timestamps')
    expect(wrapper.text()).toContain('not for moving')
  })
})

describe('No import without a preview (W-8, TF-357)', () => {
  // The heart of the workflow. Before a file has been read there is nothing
  // to press — not a disabled button, none at all.
  it('offers nothing to import before a file is chosen', async () => {
    const { wrapper } = await screen({ workspaces: ownerWorkspaces() })

    expect(wrapper.find('[data-test="import"]').exists()).toBe(false)
  })

  it('fetches the preview as soon as a file is chosen, and writes nothing doing it', async () => {
    const { wrapper, server } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [{ method: 'POST', path: '/import/preview', body: previewBody() }]
    })

    await pick(wrapper, '{"format":"promptatelier-export"}')

    expect(server.callsTo('POST', '/import/preview')).toHaveLength(1)
    expect(writingCalls(server)).toHaveLength(0)
    expect(wrapper.text()).toContain('1 new')
    expect(wrapper.find('[data-test="import"]').exists()).toBe(true)
  })

  it('sends the very file the preview saw when importing', async () => {
    const { wrapper, server } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [
        { method: 'POST', path: '/import/preview', body: previewBody() },
        { method: 'POST', path: '/import', body: { report: report() } }
      ]
    })

    await pick(wrapper, '{"format":"promptatelier-export"}')
    await wrapper.find('[data-test="import"]').trigger('click')
    await settle()

    expect(JSON.parse(writingCalls(server).at(-1).options.body).content).toBe('{"format":"promptatelier-export"}')
  })

  // Abandoning takes the preview with it, so the next file starts from
  // nothing. Otherwise a second, smaller file would inherit the decisions of
  // the first.
  it('forgets the preview on cancelling', async () => {
    const { wrapper } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [{ method: 'POST', path: '/import/preview', body: collidingPreview }]
    })

    await pick(wrapper, '{}')
    await wrapper.findAll('button').find((entry) => entry.text().includes('Cancel')).trigger('click')
    await settle()

    expect(wrapper.find('[data-test="import"]').exists()).toBe(false)
  })
})

describe('Collisions (FA-802)', () => {
  it('shows the choices of the server for each collision', async () => {
    const { wrapper } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [{ method: 'POST', path: '/import/preview', body: collidingPreview }]
    })

    await pick(wrapper, '{}')

    const row = wrapper.findAll('.entry').find((entry) => entry.text().includes('Blogartikel'))
    const options = row.findAll('option').map((option) => option.element.value)
    expect(options).toEqual(['skip', 'copy', 'overwrite'])
  })

  // TF-341b: with more than one candidate the server does not offer
  // "overwrite", and the screen offers exactly what the server offered — a
  // list assembled here would be a second copy of the rule.
  it('offers nothing the server did not offer', async () => {
    const ambiguous = previewBody({
      prompts: [{
        index: 0, title: 'Blogartikel-Generator', state: 'ambiguous',
        decisions: ['skip', 'copy'],
        candidates: [
          { id: 5, title: 'Blogartikel-Generator', updated_at: '2026-07-01T10:00:00+02:00' },
          { id: 6, title: 'blogartikel-generator', updated_at: '2026-07-02T10:00:00+02:00' }
        ]
      }],
      new_count: 0,
      collision_count: 1
    })
    const { wrapper } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [{ method: 'POST', path: '/import/preview', body: ambiguous }]
    })

    await pick(wrapper, '{}')

    const options = wrapper.findAll('option').map((option) => option.element.value)
    expect(options).not.toContain('overwrite')
    expect(wrapper.text()).toContain('2 times')
  })

  // The safe answer is the default. Somebody clicking through without reading
  // must not be able to overwrite anything.
  it('stands on skip until somebody chooses otherwise', async () => {
    const { wrapper, server } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [
        { method: 'POST', path: '/import/preview', body: collidingPreview },
        { method: 'POST', path: '/import', body: { report: report() } }
      ]
    })

    await pick(wrapper, '{}')
    await wrapper.find('[data-test="import"]').trigger('click')
    await settle()

    expect(JSON.parse(writingCalls(server).at(-1).options.body).decisions).toEqual({ 1: 'skip' })
  })

  it('sends the decision that was made', async () => {
    const { wrapper, server } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [
        { method: 'POST', path: '/import/preview', body: collidingPreview },
        { method: 'POST', path: '/import', body: { report: report() } }
      ]
    })

    await pick(wrapper, '{}')
    await wrapper.find('.entry select').setValue('overwrite')
    await wrapper.find('[data-test="import"]').trigger('click')
    await settle()

    expect(JSON.parse(writingCalls(server).at(-1).options.body).decisions).toEqual({ 1: 'overwrite' })
  })
})

describe('The report', () => {
  it('names the skipped prompts, not merely their number', async () => {
    const { wrapper } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [
        { method: 'POST', path: '/import/preview', body: collidingPreview },
        {
          method: 'POST',
          path: '/import',
          body: { report: report({ created: ['Ganz neu'], skipped: ['Blogartikel-Generator'] }) }
        }
      ]
    })

    await pick(wrapper, '{}')
    await wrapper.find('[data-test="import"]').trigger('click')
    await settle()

    expect(wrapper.text()).toContain('1 created')
    expect(wrapper.text()).toContain('Blogartikel-Generator')
  })

  it('reports missing keywords instead of keeping quiet about them', async () => {
    const { wrapper } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [
        { method: 'POST', path: '/import/preview', body: previewBody() },
        { method: 'POST', path: '/import', body: { report: report({ keywords_missing: ['formal'] }) } }
      ]
    })

    await pick(wrapper, '{}')
    await wrapper.find('[data-test="import"]').trigger('click')
    await settle()

    expect(wrapper.text()).toContain('These keywords are missing here')
    expect(wrapper.text()).toContain('formal')
  })

  // A second, broken file after a good one must not leave the first one's
  // preview standing — otherwise the button would still be there and send the
  // content of a file the server never saw.
  it('leaves no stale preview standing after a refused file', async () => {
    const { wrapper } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [
        { method: 'POST', path: '/import/preview', body: previewBody(), once: true },
        { method: 'POST', path: '/import/preview', ...apiError(422, 'malformed_json') }
      ]
    })

    await pick(wrapper, '{"format":"promptatelier-export"}')
    expect(wrapper.find('[data-test="import"]').exists()).toBe(true)

    await pick(wrapper, 'kaputt', 'kaputt.json')
    expect(wrapper.find('[data-test="import"]').exists()).toBe(false)
    expect(wrapper.find('.alert').text()).toContain('not valid JSON')
  })

  it('names a refused file with the reason from the server', async () => {
    const { wrapper } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [{
        method: 'POST',
        path: '/import/preview',
        ...apiError(422, 'malformed_json')
      }]
    })

    await pick(wrapper, 'kaputt')

    expect(wrapper.find('.alert').text()).toContain('not valid JSON')
    expect(wrapper.find('[data-test="import"]').exists()).toBe(false)
  })
})

describe('Whoever may not', () => {
  // An editor exports his own and imports nothing (matrix). Offering the half
  // he may not use would be a form that can only end in a refusal.
  it('gets only the part they may use', async () => {
    const { wrapper } = await screen()

    expect(wrapper.find('[data-test="export"]').exists()).toBe(true)
    expect(wrapper.find('[data-test="file"]').exists()).toBe(false)
  })

  it('gets a sentence when both are missing', async () => {
    const { wrapper } = await screen({
      workspaces: { ...WORKSPACES, selected_workspace_id: 11 }
    })

    expect(wrapper.find('[data-test="export"]').exists()).toBe(false)
    expect(wrapper.text()).toContain('neither export nor import')
  })
})

// TF-347b to TF-347d on the screen.
describe('A keyword that already exists here', () => {
  // The case that used to vanish. Not in `to_create`, because it exists, and
  // not in `missing`, because the file provides it.
  it('is shown with both texts instead of falling between the two lists', async () => {
    const { wrapper } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [{ method: 'POST', path: '/import/preview', body: keywordConflictPreview }]
    })

    await pick(wrapper, '{}')

    const conflicts = wrapper.find('[data-test="keyword-conflicts"]')
    expect(conflicts.exists()).toBe(true)
    expect(conflicts.text()).toContain('formal')
    // Both, because a keyword has no revisions to fall back on.
    expect(conflicts.text()).toContain('Schreibe sachlich.')
    expect(conflicts.text()).toContain('Sei knapp.')
  })

  it('offers skipping and overwriting, and never a copy', async () => {
    const { wrapper } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [{ method: 'POST', path: '/import/preview', body: keywordConflictPreview }]
    })

    await pick(wrapper, '{}')

    const choices = wrapper.find('[data-test="keyword-conflicts"] select')
      .findAll('option').map((option) => option.element.value)

    // A copy would carry a name no imported prompt refers to.
    expect(choices).toEqual(['skip', 'overwrite'])
  })

  it('starts on skipping and sends that without anything being touched', async () => {
    const { wrapper, server } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [
        { method: 'POST', path: '/import/preview', body: keywordConflictPreview },
        { method: 'POST', path: '/import', body: { report: report() } }
      ]
    })

    await pick(wrapper, '{}')
    expect(wrapper.find('[data-test="keyword-conflicts"] select').element.value).toBe('skip')

    await wrapper.find('[data-test="import"]').trigger('click')
    await settle()

    expect(JSON.parse(writingCalls(server).at(-1).options.body).keyword_decisions)
      .toEqual({ 0: 'skip' })
  })

  it('sends the overwrite once it is chosen', async () => {
    const { wrapper, server } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [
        { method: 'POST', path: '/import/preview', body: keywordConflictPreview },
        { method: 'POST', path: '/import', body: { report: report() } }
      ]
    })

    await pick(wrapper, '{}')
    await wrapper.find('[data-test="keyword-conflicts"] select').setValue('overwrite')
    await wrapper.find('[data-test="import"]').trigger('click')
    await settle()

    expect(JSON.parse(writingCalls(server).at(-1).options.body).keyword_decisions)
      .toEqual({ 0: 'overwrite' })
  })

  // Forty unchanged keywords must not read as forty decisions waiting to be
  // made.
  it('says so when the definition is the same on both sides', async () => {
    const { wrapper } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [{ method: 'POST', path: '/import/preview', body: identicalKeywordPreview }]
    })

    await pick(wrapper, '{}')

    expect(wrapper.find('[data-test="keyword-conflicts"]').text()).toContain('Identical')
  })

  it('names what was overwritten and what was skipped afterwards', async () => {
    const { wrapper } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [
        { method: 'POST', path: '/import/preview', body: keywordConflictPreview },
        {
          method: 'POST',
          path: '/import',
          body: { report: report({ keywords_overwritten: ['formal'], keywords_skipped: ['knapp'] }) }
        }
      ]
    })

    await pick(wrapper, '{}')
    await wrapper.find('[data-test="import"]').trigger('click')
    await settle()

    expect(wrapper.text()).toContain('Keywords overwritten: formal')
    expect(wrapper.text()).toContain('Keywords skipped: knapp')
  })
})

// TF-347g. **The message after the import.** It named `created.length` alone, so a file
// of keywords reported "0 Prompts eingespielt" while a keyword had just been
// written, and an import that overwrote five prompts said the same. Nothing
// covered it, which is why it survived.
describe('The message after the import', () => {
  // Read off the screen rather than out of the notices module: `screen()` calls
  // `vi.resetModules()` before importing the app, so a module this file imported
  // at the top would be a different instance from the one the component writes
  // to. The rendered notice is what the user gets anyway.
  const importing = async (reportOverrides) => {
    const { wrapper } = await screen({
      workspaces: ownerWorkspaces(),
      routes: [
        { method: 'POST', path: '/import/preview', body: previewBody() },
        { method: 'POST', path: '/import', body: { report: report(reportOverrides) } }
      ]
    })

    await pick(wrapper, '{}')
    await wrapper.find('[data-test="import"]').trigger('click')
    await settle()

    return wrapper.find('.notices__item').text()
  }

  it('names the keywords when the file carried nothing else', async () => {
    const message = await importing({ created: [], keywords_created: ['formal'] })

    expect(message).toContain('1 keywords imported')
    // The old message said this, while a keyword had just been written.
    expect(message).not.toContain('0 prompts')
  })

  it('names both when the file carried both', async () => {
    const message = await importing({ created: ['Ganz neu'], keywords_created: ['formal'] })

    expect(message).toBe('1 prompts and 1 keywords imported.')
  })

  // The second half of the same mistake: overwriting is writing.
  it('counts an overwritten prompt as imported', async () => {
    const message = await importing({ created: [], overwritten: ['Blogartikel-Generator'] })

    expect(message).toContain('1 prompts imported')
  })

  it('counts an overwritten keyword as imported', async () => {
    const message = await importing({ created: [], keywords_overwritten: ['formal'] })

    expect(message).toContain('1 keywords imported')
  })

  // Reachable whenever every entry collided and every one was skipped. "0
  // eingespielt" would read as a failure rather than as what was asked for.
  it('says so plainly when everything was skipped', async () => {
    const message = await importing({ created: [], skipped: ['Blogartikel-Generator'] })

    expect(message).toBe('Nothing imported. Everything was skipped.')
  })
})

function report (overrides = {}) {
  return {
    created: ['Ganz neu'], overwritten: [], skipped: [],
    keywords_created: [], keywords_overwritten: [], keywords_skipped: [],
    keywords_missing: [], unknown_fields: [],
    ...overrides
  }
}
