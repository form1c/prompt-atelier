<script setup>
import { t } from '@/i18n'

// The fill-in form (FA-303): one field per variable, by type, prefilled with
// the default, in the order the prompt gives them.
//
// The order is `position`, not the order of appearance in the text. They are
// usually the same, but the editor can change it — someone who writes a
// prompt knows better than the parser which question comes first.

const props = defineProps({
  variables: { type: Array, required: true },
  values: { type: Object, required: true },
  missing: { type: Array, default: () => [] }
})

const emit = defineEmits(['update'])

const sorted = () => [...props.variables].sort((one, other) => (one.position ?? 0) - (other.position ?? 0))

// The label the author gave, or the key. A key is a poor label, but it is
// better than an empty one — and it says exactly what the text refers to.
const labelFor = (variable) => variable.label || variable.key

const isMissing = (variable) => props.missing.includes(String(variable.key).toLowerCase())

// Options of a selection variable (FA-302). Stored as one text, one option
// per line, because that is what the editor is going to write into.
function optionsOf (variable) {
  return String(variable.options ?? '')
    .split('\n')
    .map((option) => option.trim())
    .filter((option) => option !== '')
}

function change (variable, event) {
  emit('update', variable.key, event.target.value)
}
</script>

<template>
  <div class="fill">
    <p v-if="variables.length === 0" class="fill__none">{{ t('prompt.no_variables') }}</p>

    <label v-for="variable in sorted()" :key="variable.key" class="field">
      <span>
        {{ labelFor(variable) }}<abbr
          v-if="variable.required"
          class="fill__required"
          :title="t('prompt.required_marker')"
        >*</abbr>
      </span>

      <textarea
        v-if="variable.type === 'multiline'"
        :value="values[variable.key] ?? ''"
        :aria-invalid="isMissing(variable)"
        rows="4"
        @input="change(variable, $event)"
      />

      <select
        v-else-if="variable.type === 'select'"
        :value="values[variable.key] ?? ''"
        :aria-invalid="isMissing(variable)"
        @change="change(variable, $event)"
      >
        <!-- An empty entry, unless the variable is required: without it a
             selection could never be undone, and the first option would be
             an answer nobody gave. -->
        <option v-if="!variable.required" value="" />
        <option v-for="option in optionsOf(variable)" :key="option" :value="option">
          {{ option }}
        </option>
      </select>

      <input
        v-else
        :type="variable.type === 'number' ? 'number' : 'text'"
        :value="values[variable.key] ?? ''"
        :aria-invalid="isMissing(variable)"
        @input="change(variable, $event)"
      >

      <span v-if="isMissing(variable)" class="field-error">{{ t('prompt.required_missing') }}</span>
    </label>
  </div>
</template>

<style scoped>
.fill__none {
  color: var(--muted);
}

.fill__required {
  margin-left: 0.125rem;
  color: var(--danger);
  text-decoration: none;
  cursor: help;
}

textarea,
select {
  width: 100%;
  padding: 0.5rem 0.625rem;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  background: var(--surface);
  font: inherit;
}

textarea {
  resize: vertical;
}

[aria-invalid="true"] {
  border-color: var(--danger);
}
</style>
