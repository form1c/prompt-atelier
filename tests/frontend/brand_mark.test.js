import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import BrandMark from '../../frontend/src/components/BrandMark.vue'

// FA-911 — the exchangeable mark above the three screens somebody sees before
// signing in.
//
// It is loaded from a file in `public/`, which lands verbatim in `app/public/`
// of the delivery: an operator swaps that one file and reloads. A bundled
// asset would carry a checksum in its name and could not be replaced without a
// build tool — on a server without Node, that means never.
//
// Which file it is, is **not** asserted here. The name was pinned to
// `/logo.svg` once and the case then failed the day somebody put their own
// `logo.jpg` in place — a red test over a change that was exactly what FA-911
// invites. What has to hold is the property: an absolute path out of
// `public/`, not a bundled asset.

describe('The brand mark (FA-911)', () => {
  it('shows the file as long as it can be loaded', () => {
    const wrapper = mount(BrandMark)

    const logo = wrapper.find('img')
    expect(logo.exists()).toBe(true)
    // Out of public/, and not inlined: Vite turns a static `src` on a file
    // this small into a base64 data URI, and the exchangeable mark would be
    // baked into the JavaScript.
    expect(logo.attributes('src')).toMatch(/^\/[\w.-]+\.(svg|png|jpe?g|webp)$/)
    expect(logo.attributes('src')).not.toMatch(/^data:/)
    // Not decoration: whoever cannot see the image has to learn where they are.
    expect(logo.attributes('alt')).toBe('Prompt Atelier')
  })

  // The delivered placeholder is meant to be deleted, so this is the normal
  // state of a fresh instance and not an exotic one. A broken-image icon
  // above the sign-in form would be the first thing it showed of itself.
  it('falls back to the wordmark when the file is missing', async () => {
    const wrapper = mount(BrandMark)

    await wrapper.find('img').trigger('error')

    expect(wrapper.find('img').exists()).toBe(false)
    expect(wrapper.text()).toContain('Prompt Atelier')
  })

  // While the image is there the name is still announced — but once, not
  // twice: the alt text carries it, so a second visible copy would be read out
  // after it.
  it('names the name exactly once', () => {
    const wrapper = mount(BrandMark)

    expect(wrapper.find('.brand__word').exists()).toBe(false)
    expect(wrapper.find('.visually-hidden').exists()).toBe(true)
  })
})
