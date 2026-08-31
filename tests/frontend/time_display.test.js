import { describe, it, expect } from 'vitest'
import { formatTime, exactTime, parseTime } from '../../frontend/src/util/time.js'

// TF-427 — times on the screen.
//
// Three rules, and each of them can be got wrong on its own: the reader's own
// time zone, a relative statement while it is recent, a date once it is not.

const NOW = new Date('2026-08-02T12:00:00Z')
const ago = (milliseconds) => new Date(NOW.getTime() - milliseconds).toISOString()

const MINUTE = 60 * 1000
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR

describe('Time displays', () => {
  it('says how long ago it was for fresh entries', () => {
    expect(formatTime(ago(30 * 1000), NOW)).toBe('just now')
    expect(formatTime(ago(5 * MINUTE), NOW)).toBe('5 minutes ago')
    expect(formatTime(ago(2 * HOUR), NOW)).toBe('2 hours ago')
    expect(formatTime(ago(2 * DAY), NOW)).toBe('2 days ago')
  })

  // The largest unit that has been reached: 90 minutes is an hour ago, not
  // ninety minutes ago. Nobody counts in ninetieths.
  it('picks the largest unit that has been reached', () => {
    expect(formatTime(ago(90 * MINUTE), NOW)).toBe('1 hour ago')
    expect(formatTime(ago(36 * HOUR), NOW)).toBe('yesterday')
  })

  // The switch, from both sides. "43 days ago" is a number nobody converts
  // into anything; a date is what someone would look for.
  it('switches to the date from a week on', () => {
    expect(formatTime(ago(6 * DAY), NOW)).toMatch(/6 days ago/)
    expect(formatTime(ago(7 * DAY), NOW)).toBe('26 July 2026')
    expect(formatTime(ago(400 * DAY), NOW)).toBe('28 June 2025')
  })

  // The server sends UTC (migration 002) and the browser turns it into the
  // reader's own clock. Without the conversion, everyone east of Greenwich
  // would see their own entries dated an hour early.
  it('converts to the time zone of the browser', () => {
    const stamp = '2026-08-02T22:30:00Z'
    const local = new Date(stamp)

    expect(exactTime(stamp)).toContain(String(local.getDate()))
    expect(exactTime(stamp)).toContain(
      String(local.getHours()).padStart(2, '0')
    )
  })

  it('stays silent rather than wrong on an unusable entry', () => {
    expect(parseTime(null)).toBeNull()
    expect(parseTime('kein Datum')).toBeNull()
    expect(formatTime(undefined, NOW)).toBe('')
    expect(exactTime('kein Datum')).toBe('')
  })

  // The counter-check to the format the server sends: Ruby's default
  // rendering of a Time — a space instead of the T — is what Safari refuses
  // to parse. If it ever comes back, this is where it shows.
  it('reads the shape the server sends, not the one before it', () => {
    expect(parseTime('2026-08-02T10:52:30+02:00')).not.toBeNull()
    expect(parseTime('2026-08-02T08:52:30Z')).not.toBeNull()
    expect(formatTime('2026-08-02T11:00:00Z', NOW)).toBe('1 hour ago')
  })
})
