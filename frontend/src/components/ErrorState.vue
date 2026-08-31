<script setup>
import { computed } from 'vue'
import { t } from '@/i18n'

// Requirements 11.6: say what to do, not what the system could not do. The
// sentence itself comes from the server, which answers in the user's language
// already (15.2) — repeating it here would give one situation two wordings
// that drift apart.
//
// The technical detail stays available but folded away. SEC-13 keeps paths,
// queries and stack traces out of the answer, so what is left is the code and
// the status: enough to name the case in a report, not enough to be a leak.

const props = defineProps({
  error: { type: Object, required: true },
  onRetry: { type: Function, default: null }
})

const message = computed(() => props.error?.message || t('error.unexpected'))
const detail = computed(() => {
  const parts = [props.error?.code, props.error?.status].filter(
    (part) => part !== undefined && part !== null && part !== 0
  )
  return parts.join(' · ')
})
</script>

<template>
  <div class="alert" role="alert">
    <p>{{ message }}</p>

    <p v-if="onRetry" class="error__actions">
      <button type="button" class="button button--quiet" @click="onRetry">
        {{ t('state.retry') }}
      </button>
    </p>

    <details v-if="detail">
      <summary>{{ t('state.show_details') }}</summary>
      <code>{{ detail }}</code>
    </details>
  </div>
</template>

<style scoped>
.alert p:last-child { margin-bottom: 0; }

.error__actions { margin-top: 0.5rem; }

details {
  margin-top: 0.5rem;
  font-size: 0.875rem;
}

summary { cursor: pointer; }
</style>
