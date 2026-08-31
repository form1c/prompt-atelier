<script setup>
import { ref } from 'vue'
import { t } from '@/i18n'

// The mark above the three cards that are shown to somebody who is not signed
// in yet — sign-in, registration, first setup.
//
// **The image is optional and is replaced without rebuilding.** It is loaded
// from `/logo.svg`, which comes out of `public/` and therefore lands verbatim
// in `app/public/` of the delivery (18.8). An operator swaps that one file and
// reloads the page; nothing is compiled, no build tool is needed on the server.
//
// If the file is missing or unreadable the wordmark takes its place. That is
// not a nicety: the delivered placeholder is meant to be deleted, and a broken
// image icon above the sign-in form would be the first thing a new instance
// showed of itself.

const failed = ref(false)

// Bound rather than written as a literal `src="/logo.svg"`, and that is the
// whole point of the requirement. Vite treats a static `src` in a template as
// an asset reference: it would inline a file this small into the bundle as a
// base64 data URI, and the exchangeable logo would be baked into the
// JavaScript. A bound expression is left alone, so the browser fetches
// `/logo.svg` from `app/public/` — where an operator can replace it.
const LOGO = '/logo.jpg'
</script>

<template>
  <p class="brand">
    <img
      v-if="!failed"
      class="brand__logo"
      :src="LOGO"
      :alt="t('app.name')"
      @error="failed = true"
    >
    <span :class="failed ? 'brand__word' : 'visually-hidden'">{{ t('app.name') }}</span>
  </p>
</template>

<style scoped>
.brand {
  margin-bottom: 1rem;
  text-align: center;
}

/* A height rather than a width: a wordmark and a square badge should occupy
   the same line, whatever their proportions. */
.brand__logo {
  max-width: 100%;
  /*max-height: 4rem;*/
  border-radius: 10px;
}

.brand__word {
  display: block;
  color: var(--muted);
  font-size: 0.875rem;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}
</style>
