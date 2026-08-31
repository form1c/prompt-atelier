// Handing a file to the browser (W-8).
//
// No server round trip and no temporary file: the content is already in
// memory, so it becomes a Blob and an anchor click. The alternative — a
// download URL on the server — would mean a second endpoint that answers
// without the CSRF header and hands out content to whoever holds the link.
//
// Separated from the screen so the assembling can be tested without a
// browser, which is the half that has rules: the file name, and what the
// JSON is formatted like.

// Indented, because a file somebody may open in an editor is worth two
// kilobytes of whitespace. It is also what makes a diff of two exports
// readable, which is the point of keeping prompts in version control at all.
export const jsonDocument = (payload) => `${JSON.stringify(payload, null, 2)}\n`

// The file name comes from the **server** (`Transfer.filename_for`), not from
// here. It has to follow the slug rule of 14.2, and that rule is the
// normalisation of FA-501 — the one that turns ß into ss and ä into a. A
// second implementation in the browser would be a second place for it to be
// wrong, and the first draft of this file proved the point: it stripped
// combining marks, which handles ä and leaves ß as a hyphen. Same class of
// mistake as R-01, one layer up.

export function download (name, content, target = globalThis.document) {
  if (!target?.createElement || typeof URL?.createObjectURL !== 'function') return false

  const url = URL.createObjectURL(new Blob([content], { type: 'application/octet-stream' }))
  const anchor = target.createElement('a')
  anchor.href = url
  anchor.download = name
  target.body.appendChild(anchor)
  anchor.click()
  anchor.remove()
  // Released on the next turn rather than straight away: revoking while the
  // click is still being processed cancels the download in some browsers.
  setTimeout(() => URL.revokeObjectURL(url), 0)

  return true
}
