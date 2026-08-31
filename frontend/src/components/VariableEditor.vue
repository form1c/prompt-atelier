<script setup>
import { t } from '@/i18n'
import { VARIABLE_TYPES } from '@/util/draft'
import Icon from '@/components/Icon.vue'

// The metadata of the recognised variables (FA-302).
//
// There is no button to add one and none to remove one, and that is the
// point: the set follows from the text (FA-301). What can be edited is what
// each one *is* — label, type, default, whether it is mandatory, and the
// options of a selection — plus the order they are asked in.

const props = defineProps({
  variables: { type: Array, required: true },
  errors: { type: Object, default: () => ({}) }
})

const emit = defineEmits(['update', 'move'])

// How the key reads in the text. Built here and not in the template: a `{{`
// inside a mustache is read as the start of another one, and the compiler
// stops with "unterminated string constant" — which names the symptom and not
// the cause, and cost a build to work out.
const reference = (key) => `{{${key}}}`

function change (variable, field, event) {
  emit('update', variable.key, { [field]: event.target.value })
}

function toggle (variable, event) {
  emit('update', variable.key, { required: event.target.checked })
}

// Options as one per line, which is how they are written and how the database
// keeps them (14.1). The list form is what travels (17.1); the conversion is
// here, at the one place a person types them.
//
// The text is taken **as typed**, without tidying. Splitting and cleaning up on
// every keystroke made the field unusable: pressing Enter produced "Eins\n",
// the empty last line was dropped as noise, the joined value came straight
// back into the field as "Eins", and the line break was gone before the finger
// left the key. Exactly one option could ever be entered — under a hint that
// says "one option per line".
//
// The lesson is more general than the field: a value that is normalised on
// every keystroke can never be in a state that only makes sense halfway
// through. Tidying happens once, in `payloadOf`, on the way to the server.
function changeOptions (variable, event) {
  emit('update', variable.key, { options: event.target.value.split('\n') })
}

const optionText = (variable) => variable.options.join('\n')
</script>

<template>
  <section class="variables" aria-labelledby="variables-heading">
    <h2 id="variables-heading" class="variables__heading">
      {{ variables.length === 1
        ? t('editor.variables_one')
        : t('editor.variables_many', { count: variables.length }) }}
    </h2>

    <p v-if="variables.length === 0" class="variables__none">{{ t('editor.variables_none') }}</p>

    <ul v-else class="variables__list">
      <li v-for="(variable, index) in variables" :key="variable.key" class="variables__entry">
        <div class="variables__head">
          <code class="variables__key">{{ reference(variable.key) }}</code>

          <div class="variables__order">
            <button
              type="button"
              class="button button--quiet variables__step"
              :disabled="index === 0"
              :aria-label="t('editor.move_up', { key: variable.key })"
              @click="emit('move', variable.key, -1)"
            >
              <Icon name="chevron-down" class="variables__up" />
            </button>
            <button
              type="button"
              class="button button--quiet variables__step"
              :disabled="index === variables.length - 1"
              :aria-label="t('editor.move_down', { key: variable.key })"
              @click="emit('move', variable.key, 1)"
            >
              <Icon name="chevron-down" />
            </button>
          </div>
        </div>

        <div class="variables__fields">
          <label class="field">
            <span>{{ t('editor.variable_label') }}</span>
            <input type="text" :value="variable.label" @input="change(variable, 'label', $event)">
          </label>

          <label class="field">
            <span>{{ t('editor.variable_type') }}</span>
            <select :value="variable.type" @change="change(variable, 'type', $event)">
              <option v-for="entry in VARIABLE_TYPES" :key="entry.value" :value="entry.value">
                {{ t(entry.label) }}
              </option>
            </select>
          </label>

          <label class="field">
            <span>{{ t('editor.variable_default') }}</span>
            <input
              type="text"
              :value="variable.default_value"
              :aria-invalid="Boolean(errors.default_value)"
              @input="change(variable, 'default_value', $event)"
            >
          </label>

          <label class="variables__required">
            <input type="checkbox" :checked="variable.required" @change="toggle(variable, $event)">
            <span>{{ t('editor.variable_required') }}</span>
          </label>
        </div>

        <div v-if="variable.type === 'select'" class="field">
          <label>
            <span>{{ t('editor.variable_options') }}</span>
            <textarea
              rows="3"
              :value="optionText(variable)"
              :aria-describedby="`options-hint-${variable.key}`"
              @input="changeOptions(variable, $event)"
            />
          </label>
          <span :id="`options-hint-${variable.key}`" class="hint">
            {{ t('editor.variable_options_hint') }}
          </span>
        </div>
      </li>
    </ul>
  </section>
</template>

<style scoped>
.variables {
  margin-top: 1.5rem;
}

.variables__heading {
  margin-bottom: 0.5rem;
  color: var(--muted);
  font-size: 0.75rem;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.variables__none {
  color: var(--muted);
  font-size: 0.875rem;
}

.variables__list {
  margin: 0;
  padding: 0;
  list-style: none;
}

.variables__entry {
  margin-bottom: 0.75rem;
  padding: 0.75rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface);
}

.variables__head {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin-bottom: 0.5rem;
}

.variables__key {
  font-weight: 600;
}

.variables__order {
  display: flex;
  gap: 0.25rem;
  margin-left: auto;
}

.variables__step {
  padding: 0.125rem 0.375rem;
}

/* One shape for both directions, turned over for "up". Two nearly identical
   outlines in the registry would be two things to keep in step. */
.variables__up {
  transform: rotate(180deg);
}

.variables__fields {
  display: grid;
  gap: 0 0.75rem;
  grid-template-columns: repeat(auto-fit, minmax(9rem, 1fr));
  align-items: end;
}

.variables__fields .field {
  margin-bottom: 0.5rem;
}

.variables__required {
  display: flex;
  align-items: center;
  gap: 0.375rem;
  margin-bottom: 0.75rem;
  font-size: 0.9375rem;
}

.variables select,
.variables textarea {
  width: 100%;
  padding: 0.375rem 0.5rem;
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  background: var(--surface);
  font: inherit;
}
</style>
