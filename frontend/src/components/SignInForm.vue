<script setup>
import { ref, onMounted, useTemplateRef } from 'vue'
import { t } from '@/i18n'
import { signIn } from '@/state/session'
import { ApiError } from '@/api/client'

// The credentials form. Used twice: on the sign-in screen S8 and inside the
// overlay that appears when a session expires (TF-415). One component for
// both, because the rules are the same in both places — and because a second
// copy would be the one that keeps the button enabled during the request.
//
// While the request runs the fields are read-only rather than disabled. The
// disabled button is what prevents a second submission; disabling the fields
// as well takes them out of the page for the browser's password manager,
// which is looking at exactly them at exactly that moment.

const props = defineProps({
  submitLabel: { type: String, required: true },
  busyLabel: { type: String, required: true },
  initialEmail: { type: String, default: '' }
})

const emit = defineEmits(['signed-in'])

const email = ref(props.initialEmail)
const password = ref('')
const problems = ref({})
const failure = ref(null)
const busy = ref(false)

const emailField = useTemplateRef('emailField')
const passwordField = useTemplateRef('passwordField')

onMounted(() => {
  // Where the work starts. With a known address that is the password field —
  // the case after an expired session, where retyping the address would be
  // pure friction.
  const field = props.initialEmail ? passwordField.value : emailField.value
  field?.focus()
})

async function submit () {
  problems.value = {}
  failure.value = null

  // Checked here so an empty field is answered without a round trip. The
  // server checks again regardless (SEC-08); this is convenience, not
  // validation.
  if (email.value.trim() === '') problems.value.email = t('login.email_required')
  if (password.value === '') problems.value.password = t('login.password_required')
  if (Object.keys(problems.value).length > 0) return

  busy.value = true
  try {
    await signIn(email.value.trim(), password.value)
    // The field is deliberately not cleared here. The form is removed from
    // the page a moment later — on the sign-in screen by the route change, in
    // the overlay by its own `v-if` — so there is nothing to clear that does
    // not disappear anyway. A password manager, on the other hand, reads the
    // fields while it decides whether it has just seen a successful sign-in,
    // and an emptied field at that moment looks like a cancelled one.
    emit('signed-in')
  } catch (error) {
    if (!(error instanceof ApiError)) throw error

    // One message for every rejected sign-in. Which of the two was wrong is
    // something the server refuses to say (SEC-07), and picking the message
    // apart here would give that answer away after all.
    failure.value = error.message
    problems.value = Object.fromEntries(
      Object.keys(error.fields ?? {}).map((field) => [field, error.fieldMessage(field)])
    )
    passwordField.value?.focus()
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <form novalidate @submit.prevent="submit">
    <p v-if="failure" class="alert" role="alert">{{ failure }}</p>

    <label class="field">
      <span>{{ t('login.email') }}</span>
      <input
        ref="emailField"
        v-model="email"
        type="email"
        name="email"
        autocomplete="username"
        :aria-invalid="Boolean(problems.email)"
        :readonly="busy"
      >
      <span v-if="problems.email" class="field-error">{{ problems.email }}</span>
    </label>

    <label class="field">
      <span>{{ t('login.password') }}</span>
      <input
        ref="passwordField"
        v-model="password"
        type="password"
        name="password"
        autocomplete="current-password"
        :aria-invalid="Boolean(problems.password)"
        :readonly="busy"
      >
      <span v-if="problems.password" class="field-error">{{ problems.password }}</span>
    </label>

    <button type="submit" class="button button--wide" :disabled="busy">
      {{ busy ? busyLabel : submitLabel }}
    </button>
  </form>
</template>

<style scoped>
.button--wide { width: 100%; }
</style>
