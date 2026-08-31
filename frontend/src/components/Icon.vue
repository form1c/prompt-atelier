<script setup>
import { SHAPES } from '@/components/icons'

// One icon. The shapes and where they come from are in icons.js next door —
// a registry of 15 path definitions in a single-file component would bury the
// three lines that actually draw anything, and a plain module can be read by
// a test without a DOM.

defineProps({
  name: {
    type: String,
    required: true,
    // In development this says which name is wrong, right where it is used.
    // In production Vue drops the check, so the fallback below is what keeps
    // an unknown name from throwing on a screen somebody is looking at.
    validator: (value) => Object.hasOwn(SHAPES, value)
  }
})

const shapeOf = (name) => SHAPES[name] ?? []
</script>

<template>
  <svg class="icon" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true" focusable="false">
    <path v-for="(part, index) in shapeOf(name)" :key="index" :d="part.d" :fill-rule="part.rule" />
  </svg>
</template>

<style scoped>
/* Sized in em, so an icon follows the text it stands next to instead of
   needing a number at every call. The nudge downwards puts its middle on the
   middle of a lower-case letter rather than on the baseline. */
.icon {
  flex: none;
  width: 1em;
  height: 1em;
  vertical-align: -0.125em;
}
</style>
