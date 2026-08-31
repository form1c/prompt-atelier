<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import { t } from '@/i18n'

// Requirements 11.6: a skeleton rather than a spinner, and only once the wait
// is long enough to notice. Below that threshold a placeholder does not
// reassure anyone — it flickers, and the flicker is what people report.

const DELAY_MILLISECONDS = 300

const props = defineProps({
  rows: { type: Number, default: 3 },
  delay: { type: Number, default: DELAY_MILLISECONDS }
})

const visible = ref(false)
let timer = null

onMounted(() => {
  timer = setTimeout(() => { visible.value = true }, props.delay)
})

onUnmounted(() => clearTimeout(timer))
</script>

<template>
  <!-- aria-busy rather than a text: a screen reader announces the region as
       busy, and nothing is read out twice when the content arrives. -->
  <div v-if="visible" class="loading" role="status" aria-busy="true">
    <span class="visually-hidden">{{ t('state.loading') }}</span>
    <div v-for="row in rows" :key="row" class="loading__row" />
  </div>
</template>

<style scoped>
.loading__row {
  height: 1rem;
  margin-bottom: 0.75rem;
  border-radius: var(--radius);
  background: linear-gradient(90deg, #e7e9ed 0%, #f2f3f5 50%, #e7e9ed 100%);
  background-size: 200% 100%;
  animation: shimmer 1.4s ease-in-out infinite;
}

.loading__row:nth-child(3) { width: 70%; }
.loading__row:nth-child(4) { width: 85%; }

@keyframes shimmer {
  from { background-position: 200% 0; }
  to { background-position: -200% 0; }
}

/* Someone who has asked their system for less motion gets a plain block. */
@media (prefers-reduced-motion: reduce) {
  .loading__row { animation: none; }
}
</style>
