import { render, normalizeText } from '@/util/rendering'

// What a keyword does to a prompt, as something a screen can draw.
//
// W-4 states the rule: "Die Wirkung eines Keywords ist beim Anlegen an einem
// Beispiel sichtbar. Ohne diese Vorschau bleibt prepend/append abstrakt." A
// select box holding two English words is not an explanation, and the person
// choosing between them has no way to find out what they mean except by
// saving and looking.
//
// So the preview shows the example with the keyword in place, cut into the
// two parts it is made of — the keyword's own text, and the prompt's. Which
// one comes first is the whole answer.

export const POSITIONS = [
  { value: 'prepend', label: 'keywords.position_prepend' },
  { value: 'append', label: 'keywords.position_append' }
]

const BLOCK_SEPARATOR = '\n\n'

// The parts, in the order they appear. Each is `{ kind, text }` with `kind`
// either 'keyword' or 'prompt'.
//
// Assembled from the pieces rather than searched for in the finished text.
// Looking for the example inside the output would be a guess that happens to
// work — and the day normalisation changed a character at the seam it would
// quietly show the wrong half.
//
// Each part is normalised on its own, and that is the same result as
// normalising the join (step 4 of chapter 8): the five rules are per line, per
// run of blank lines, or anchored at the ends, and the separator inserted
// between two normalised blocks is exactly the two breaks the collapse rule
// leaves behind. `sameAsPipeline` below is the assertion of it, and the test
// runs it over the awkward inputs — trailing spaces, extra blank lines, a
// keyword text that is nothing but whitespace.
export function effectParts ({ body, keyword }) {
  const own = { kind: 'keyword', text: normalizeText(String(keyword?.text ?? '')) }
  const prompt = { kind: 'prompt', text: normalizeText(String(body ?? '')) }

  const order = String(keyword?.position) === 'append' ? [prompt, own] : [own, prompt]

  // An empty block disappears instead of leaving a gap — which is what the
  // pipeline does with it too (`blockFor` drops empty texts).
  return order.filter((part) => part.text !== '')
}

// The promise the parts make, as a function so a test can hold them to it:
// what is drawn, put back together, is what the pipeline produces for the
// same input. Not used by the screen — a screen that checked its own drawing
// would only be able to report that it disagrees with itself.
export function sameAsPipeline ({ body, keyword }) {
  const drawn = effectParts({ body, keyword }).map((part) => part.text).join(BLOCK_SEPARATOR)

  return drawn === render({ body, variables: [], keywords: [keyword] }).text
}
