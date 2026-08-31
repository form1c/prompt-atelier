// Cutting a text into marked and unmarked pieces (FA-501).
//
// The server sends positions, not marked-up text — pairs of start and length
// in the original. This turns them into a list of pieces the template renders
// one by one.
//
// It has to be pieces rather than a string with tags in it. Prompt content is
// never HTML (SEC-10), and `v-html` on it would be the one place where that
// stops being true: a title containing `<script>` would go from being text to
// being a script, on the very screen everybody looks at first.

export function segments (text, ranges = []) {
  const source = text ?? ''
  if (source === '' || ranges.length === 0) return [{ text: source, marked: false }]

  const pieces = []
  let position = 0

  // Sorted and merged, because two terms can find overlapping words and a
  // range that starts before the previous one ended would produce a piece of
  // negative length — which renders as nothing at all, silently losing text.
  for (const [start, length] of tidy(ranges, source.length)) {
    if (start > position) pieces.push({ text: source.slice(position, start), marked: false })
    pieces.push({ text: source.slice(start, start + length), marked: true })
    position = start + length
  }

  if (position < source.length) pieces.push({ text: source.slice(position), marked: false })

  return pieces
}

function tidy (ranges, limit) {
  const sane = ranges
    .filter(([start, length]) => Number.isInteger(start) && Number.isInteger(length) &&
                                 start >= 0 && length > 0 && start < limit)
    .map(([start, length]) => [start, Math.min(length, limit - start)])
    .sort((one, other) => one[0] - other[0])

  return sane.reduce((merged, [start, length]) => {
    const previous = merged[merged.length - 1]
    if (previous && start <= previous[0] + previous[1]) {
      previous[1] = Math.max(previous[1], start + length - previous[0])
      return merged
    }
    merged.push([start, length])
    return merged
  }, [])
}
