import { describe, it, expect } from 'vitest'
import { jsonDocument, download } from '../../frontend/src/util/download.js'

// What handing a file over looks like on this side. The **name** is not here:
// it follows the slug rule of 14.2 and is decided by the server, because that
// rule is the normalisation of FA-501 and a second implementation would be a
// second place for it to be wrong. The first draft of this file had one, and
// it turned "Größe" into "gro-e".

describe('The content of a JSON export', () => {
  // Indented, because the file may well be opened in an editor or put under
  // version control — and a diff of two single-line files says nothing.
  it('is indented and ends with a line break', () => {
    const document = jsonDocument({ format: 'promptatelier-export', prompts: [] })

    expect(document).toContain('\n  "format"')
    expect(document.endsWith('\n')).toBe(true)
    expect(JSON.parse(document).format).toBe('promptatelier-export')
  })
})

describe('Handing it to the browser', () => {
  // An environment without object URLs must not turn a missing convenience
  // into an exception halfway through an export.
  it('reports when the browser has nothing to offer instead of failing', () => {
    expect(download('x.json', '{}', undefined)).toBe(false)
    expect(download('x.json', '{}', {})).toBe(false)
  })
})
