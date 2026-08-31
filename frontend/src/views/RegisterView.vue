<script setup>
import { ref, onMounted, useTemplateRef } from 'vue'
import { useRouter } from 'vue-router'
import { t } from '@/i18n'
import { registerAccount, registrationState } from '@/state/session'
import { ApiError } from '@/api/client'
import BrandMark from '@/components/BrandMark.vue'

// S11 — a way in of one's own (FA-107).
//
// Why this exists in a self-hosted product: the application sends no e-mail
// (E-13). Without it the administrator must not only create every account but
// also carry the one-time password to its owner by phone, chat or on a note.
// Here the password is chosen by the only person who should ever know it, and
// nothing has to be handed over at all.
//
// The screen is reachable whether or not the setting is on — a bookmark
// outlives a configuration change. What differs is what it shows: with
// registration switched off it says so plainly instead of offering a form
// whose every submission would answer 403.

const PASSWORD_MINIMUM = 12

const router = useRouter()

const mode = ref(null)
const name = ref('')
const email = ref('')
const password = ref('')
const repetition = ref('')
const problems = ref({})
const failure = ref(null)
const waiting = ref(null)
const busy = ref(false)

const nameField = useTemplateRef('nameField')

onMounted(async () => {
  mode.value = await registrationState()
  nameField.value?.focus()
})

async function submit () {
  problems.value = {}
  failure.value = null

  if (name.value.trim() === '') problems.value.name = t('register.name_required')
  if (email.value.trim() === '') problems.value.email = t('register.email_required')
  if (password.value === '') problems.value.password = t('register.password_required')
  // Checked here because the server never sees the repetition: it guards
  // against a typo, not against a weak password. The rules themselves stay
  // where they belong (SEC-02, checked on the server).
  else if (password.value !== repetition.value) problems.value.repetition = t('register.password_mismatch')
  if (Object.keys(problems.value).length > 0) return

  busy.value = true
  try {
    const outcome = await registerAccount({
      name: name.value.trim(), email: email.value.trim(), password: password.value
    })

    // The server sends a code, not a sentence (AP-19) — including for the
    // outcomes that are not errors.
    if (outcome.pending) waiting.value = t(`server.${outcome.code}`)
    else await router.replace({ name: 'library' })
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
  <main class="register">
    <div class="register__card">
      <BrandMark />
      <h1>{{ t('register.title') }}</h1>

      <!-- Waiting for approval. Deliberately not a notice that fades: it is
           the whole answer to what just happened, and the person has nowhere
           else to go until somebody lets them in. -->
      <template v-if="waiting">
        <p class="alert alert--info" role="status" data-test="pending">{{ waiting }}</p>
        <RouterLink class="button" :to="{ name: 'login' }">{{ t('register.to_login') }}</RouterLink>
      </template>

      <template v-else-if="mode && !mode.enabled">
        <p class="hint" data-test="closed">{{ t('register.closed') }}</p>
        <RouterLink class="button" :to="{ name: 'login' }">{{ t('register.to_login') }}</RouterLink>
      </template>

      <form v-else-if="mode" novalidate @submit.prevent="submit">
        <p v-if="mode.approval_required" class="hint" data-test="approval-notice">
          {{ t('register.approval_notice') }}
        </p>

        <p v-if="failure" class="alert" role="alert">{{ failure }}</p>

        <label class="field">
          <span>{{ t('register.name') }}</span>
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
          <span>{{ t('register.email') }}</span>
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

        <!-- The hint sits outside the label: everything inside one becomes
             part of the field's *name*, and a hint is a description
             (NFA-11). -->
        <div class="field">
          <label>
            <span>{{ t('register.password') }}</span>
            <input
              v-model="password"
              type="password"
              name="password"
              autocomplete="new-password"
              :aria-invalid="Boolean(problems.password)"
              aria-describedby="register-password-hint"
              :disabled="busy"
            >
          </label>
          <span id="register-password-hint" class="hint">
            {{ t('register.password_hint', { minimum: PASSWORD_MINIMUM }) }}
          </span>
          <span v-if="problems.password" class="field-error">{{ problems.password }}</span>
        </div>

        <label class="field">
          <span>{{ t('register.password_repeat') }}</span>
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

        <button type="submit" class="button register__submit" :disabled="busy" data-test="register">
          {{ busy ? t('register.submitting') : t('register.submit') }}
        </button>

        <p class="register__back">
          <RouterLink :to="{ name: 'login' }">{{ t('register.to_login') }}</RouterLink>
        </p>
      </form>
    </div>
  </main>
</template>

<style scoped>
.register {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100%;
  padding: 1.5rem;
}

.register__card {
  width: 100%;
  max-width: 28rem;
  padding: 1.75rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface);
  box-shadow: var(--shadow);
}


.register__submit { width: 100%; }

.register__back {
  margin-top: 1rem;
  margin-bottom: 0;
  text-align: center;
  font-size: 0.9375rem;
}

.hint {
  display: block;
  margin-bottom: 1rem;
  color: var(--muted);
  font-size: 0.9375rem;
}
</style>
