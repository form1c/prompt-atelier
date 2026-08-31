import { t } from '@/i18n'

// Times on the screen (TF-427, Requirements 11.6).
//
// The rule has three parts, and each of them exists for a reason:
//
//   * The server stores and sends UTC (migration 002). The browser turns that
//     into the reader's own time zone — someone in Vienna and someone in
//     London see the same instant, each in their own clock.
//   * Up to a week, a relative statement: "vor 2 Tagen" says more at a glance
//     than a date does. It is how people talk about recent things.
//   * From a week on, the date. "vor 43 Tagen" is a number nobody converts
//     into anything useful, and a date is what someone would look for.
//
// The wording comes from the browser rather than from de.json — Intl knows
// German plurals, and a table of them here would be a second, worse copy. The
// language tag is in the text table, so it travels with the translation.

const WEEK_IN_MILLISECONDS = 7 * 24 * 60 * 60 * 1000

// Seconds are deliberately absent: "vor 30 Sekunden" is a precision nobody
// asked for on a list of prompts, and it changes while it is being read.
// Anything under a minute is "gerade eben".
const UNITS = [
  { unit: 'minute', milliseconds: 60 * 1000 },
  { unit: 'hour', milliseconds: 60 * 60 * 1000 },
  { unit: 'day', milliseconds: 24 * 60 * 60 * 1000 }
]

export function parseTime (value) {
  if (value === null || value === undefined) return null

  const parsed = new Date(value)
  return Number.isNaN(parsed.getTime()) ? null : parsed
}

export function formatTime (value, now = new Date()) {
  const parsed = parseTime(value)
  if (parsed === null) return ''

  const distance = now.getTime() - parsed.getTime()

  return distance >= WEEK_IN_MILLISECONDS || distance < 0
    ? absolute(parsed)
    : relative(distance)
}

// The full timestamp, for the `title` of an element whose text is relative.
// Somebody who wants to know the exact moment should not have to open the
// prompt to find it.
export function exactTime (value) {
  const parsed = parseTime(value)
  if (parsed === null) return ''

  return new Intl.DateTimeFormat(t('time.locale_tag'), {
    dateStyle: 'long', timeStyle: 'short'
  }).format(parsed)
}

function absolute (date) {
  return new Intl.DateTimeFormat(t('time.locale_tag'), { dateStyle: 'long' }).format(date)
}

function relative (distance) {
  // The largest unit that has reached one, so "vor 90 Minuten" comes out as
  // "vor 1 Stunde". Anything under a minute is not worth a number.
  const chosen = UNITS.filter(({ milliseconds }) => distance >= milliseconds).pop()
  if (!chosen) return t('time.just_now')

  const amount = Math.floor(distance / chosen.milliseconds)
  return new Intl.RelativeTimeFormat(t('time.locale_tag'), { numeric: 'auto' })
    .format(-amount, chosen.unit)
}
