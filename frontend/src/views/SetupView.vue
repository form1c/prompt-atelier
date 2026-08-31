<script setup>
import { ref, onMounted, useTemplateRef } from 'vue'
import { useRouter } from 'vue-router'
import { t } from '@/i18n'
import { completeSetup } from '@/state/session'
import { ApiError } from '@/api/client'
import BrandMark from '@/components/BrandMark.vue'

// FA-909 — the first account, created in the browser.
//
// W-6 describes two ways to the first administrator: `install` offers it, and
// whoever skips it there gets this screen. Without it a fresh instance would
// show a sign-in screen that nobody on earth can pass — which is why this
// belongs with the sign-in screen and not with the rest of the
// administration.

// SEC-02. The server is the authority and rejects a shorter password with its
// own message; this number only tells the user before they type. A test keeps
// it equal to Password::MINIMUM_LENGTH in the backend, so the two cannot
// drift apart unnoticed.
const PASSWORD_MINIMUM = 12

const router = useRouter()

const name = ref('')
const email = ref('')
const password = ref('')
const repetition = ref('')
const problems = ref({})
const failure = ref(null)
const busy = ref(false)

const nameField = useTemplateRef('nameField')

onMounted(() => nameField.value?.focus())

async function submit () {
  problems.value = {}
  failure.value = null

  if (name.value.trim() === '') problems.value.name = t('setup.name_required')
  if (email.value.trim() === '') problems.value.email = t('setup.email_required')
  if (password.value === '') problems.value.password = t('setup.password_required')
  else if (password.value !== repetition.value) problems.value.repetition = t('setup.password_mismatch')
  if (Object.keys(problems.value).length > 0) return

  busy.value = true
  try {
    await completeSetup({ name: name.value.trim(), email: email.value.trim(), password: password.value })
    await router.replace({ name: 'library' })
  } catch (error) {
    if (!(error instanceof ApiError)) throw error

    failure.value = error.message
    problems.value = Object.fromEntries(
      Object.keys(error.fields ?? {}).map((field) => [field, error.fieldMessage(field)])
    )
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <main class="setup">
    <div class="setup__card">
      <BrandMark />
      <h1>{{ t('setup.title') }}</h1>
      <p class="setup__intro">{{ t('setup.intro') }}</p>

      <form novalidate @submit.prevent="submit">
        <p v-if="failure" class="alert" role="alert">{{ failure }}</p>

        <label class="field">
          <span>{{ t('setup.name') }}</span>
          <input
            ref="nameField"
            v-model="name"
            type="text"
            name="name"
            autocomplete="name"
            :aria-invalid="Boolean(problems.name)"
            :disabled="busy"
          >
          <span v-if="problems.name" class="field-error">{{ problems.name }}</span>
        </label>

        <label class="field">
          <span>{{ t('setup.email') }}</span>
          <input
            v-model="email"
            type="email"
            name="email"
            autocomplete="username"
            :aria-invalid="Boolean(problems.email)"
            :disabled="busy"
          >
          <span v-if="problems.email" class="field-error">{{ problems.email }}</span>
        </label>

        <!-- The hint sits **outside** the label, and that is the whole point:
             everything inside a label becomes part of the field's *name*. With
             the hint in there a screen reader announced "Passwort Mindestens 12
             Zeichen. Länge zählt mehr als Sonderzeichen." as the name of the
             field and offered no description at all. A hint is a description
             (`aria-describedby`), not a name (NFA-11). -->
        <div class="field">
          <label>
            <span>{{ t('setup.password') }}</span>
            <input
              v-model="password"
              type="password"
              name="password"
              autocomplete="new-password"
              :aria-invalid="Boolean(problems.password)"
              aria-describedby="setup-password-hint"
              :disabled="busy"
            >
          </label>
          <span id="setup-password-hint" class="hint">
            {{ t('setup.password_hint', { minimum: PASSWORD_MINIMUM }) }}
          </span>
          <span v-if="problems.password" class="field-error">{{ problems.password }}</span>
        </div>

        <label class="field">
          <span>{{ t('setup.password_repeat') }}</span>
          <input
            v-model="repetition"
            type="password"
            name="password_repeat"
            autocomplete="new-password"
            :aria-invalid="Boolean(problems.repetition)"
            :disabled="busy"
          >
          <span v-if="problems.repetition" class="field-error">{{ problems.repetition }}</span>
        </label>

        <button type="submit" class="button setup__submit" :disabled="busy">
          {{ busy ? t('setup.submitting') : t('setup.submit') }}
        </button>
      </form>
    </div>
  </main>
</template>

<style scoped>
.setup {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100%;
  padding: 1.5rem;
}

.setup__card {
  width: 100%;
  max-width: 28rem;
  padding: 1.75rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface);
  box-shadow: var(--shadow);
}


.setup__intro {
  margin-bottom: 1.25rem;
  color: var(--muted);
}

.setup__submit { width: 100%; }
</style>
