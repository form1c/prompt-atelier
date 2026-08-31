// Putting the finished prompt into the clipboard (FA-305, TF-416).
//
// The modern way is `navigator.clipboard.writeText`. It is refused more often
// than one would think: over plain http on anything but localhost it does not
// exist at all, in a background tab it rejects, and some settings switch it
// off entirely. TF-416 asks what happens then — and the answer must not be
// "nothing happened".
//
// So the caller gets a plain yes or no, and on a no the screen shows the text
// in a marked, selectable field. That is the fallback the requirement names:
// it always works, because selecting and copying is something the browser
// cannot refuse.

export async function copyText (text, target = globalThis.navigator) {
  if (!target?.clipboard?.writeText) return false

  try {
    await target.clipboard.writeText(text)
    return true
  } catch {
    // A rejection here is the normal case in a browser that does not want to,
    // not an exception worth reporting as an error.
    return false
  }
}
