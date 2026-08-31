// Cutting the finished prompt into the pieces the preview shows (8.3, 11.4).
//
// Requirements 8.3 asks for the spot of a missing mandatory value to be marked
// in the preview. That spot is a *position*, not a stretch of text — a variable
// nobody filled in contributes no characters — so there has to be something to
// point at, and that something is the placeholder `{{key}}` drawn back in.
//
// Two kinds of piece, and the difference matters:
//
//   plain, value      the finished text, cut up. Put end to end they give
//                     back exactly what `render` produced and exactly what
//                     the clipboard receives.
//   empty, missing    **not** in that text. They are drawn where a variable
//                     would have gone, so the reader can see the gap; the
//                     screen says as much, and copying leaves them out.
//
// The separation is the whole point. It would be easy — and wrong — to let the
// placeholder back into the text: an optional variable left empty on purpose
// would then paste `{{aufhaenger}}` into a model prompt. Whoever really wants
// the braces takes the second copy button (FA-305).
//
// Pieces rather than a string with markup in it, for the same reason as in
// highlight.js: prompt content is never HTML (SEC-10), and `v-html` on it is
// the one place where that would stop being true.

export function pieces (text, marks = [], missing = []) {
  const source = String(text ?? '')
  const gaps = missing.map((key) => String(key).toLowerCase())
  const out = []
  let position = 0

  for (const mark of ordered(marks, source.length)) {
    // Clamped to what is left. The pipeline hands over ordered, disjoint
    // marks, but this runs on whatever the screen last stored — and a piece of
    // negative length renders as nothing at all, which would lose text
    // silently instead of loudly.
    const start = Math.max(mark.start, position)
    const end = Math.max(mark.end, start)

    if (start > position) plain(out, source.slice(position, start))

    // An unfilled variable first, because it is unfilled whether or not it
    // covers any characters. With `showPlaceholders` the render has already
    // laid the text out around its `{{key}}` and the mark covers exactly that;
    // without it the mark is empty and the placeholder is drawn in here. Both
    // ways the piece says the same thing, and the text is written out rather
    // than sliced so it cannot depend on which way it was.
    if (!mark.filled) {
      out.push({
        kind: gaps.includes(mark.key) ? 'missing' : 'empty',
        key: mark.key,
        text: `{{${mark.key}}}`
      })
    } else if (end > start) {
      out.push({ kind: 'value', key: mark.key, text: source.slice(start, end) })
    }

    position = end
  }

  if (position < source.length) plain(out, source.slice(position))

  return out
}

// Two stretches of plain text never stay next to each other. A value that
// normalisation used up leaves its two neighbours touching, and one piece of
// text is what that is — the alternative renders the same characters in two
// elements for a reason nobody can see and makes every expected value in the
// tests depend on where the gap used to be.
function plain (out, text) {
  const last = out[out.length - 1]

  if (last?.kind === 'plain') last.text += text
  else out.push({ kind: 'plain', text })
}

// Marks that make no sense are dropped, the rest is put in order.
//
// No clamping of `end` to the length: `slice` limits itself and the loop above
// never walks backwards, so a mark reaching past the end already comes out
// right. A clamp here would be a line no test could ever tell apart from its
// absence, which is a worse thing to leave in the file than nothing at all.
function ordered (marks, limit) {
  return [...marks]
    .filter((mark) => Number.isInteger(mark.start) && Number.isInteger(mark.end) &&
                      mark.start >= 0 && mark.end >= mark.start && mark.start <= limit)
    .sort((one, other) => one.start - other.start)
}
