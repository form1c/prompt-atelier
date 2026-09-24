<script setup>
import { useTemplateRef } from 'vue'
import { t } from '@/i18n'

// TF-416: the browser refused the clipboard. The text is put where it can be
// selected, which is something no setting can take away.
//
// One component for every screen that copies, so the way out looks and works
// the same wherever the clipboard says no. The caller passes the hint, because
// only the caller knows what the text is: a finished prompt, the text of a
// keyword.

defineProps({
  text: { type: String, required: true },
  hint: { type: String, required: true }
})

const field = useTemplateRef('field')

// Called by the screen after every refusal, not only the first one: a second
// click on the same button leaves the text unchanged, and the selection must
// still come back.
function select () {
  field.value?.select()
}

defineExpose({ select })
</script>

<template>
  <div class="manual-copy">
    <h3>{{ t('prompt.copy_manual_title') }}</h3>
    <p>{{ hint }}</p>
    <textarea ref="field" readonly rows="6" :value="text" />
  </div>
</template>

<style scoped>
.manual-copy {
  margin-top: 1rem;
  padding: 0.75rem;
  border: 1px solid var(--danger);
  border-radius: var(--radius);
  background: var(--danger-surface);
}

.manual-copy h3 { font-size: 1rem; }

.manual-copy textarea {
  width: 100%;
  padding: 0.5rem;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  font: inherit;
}
</style>
