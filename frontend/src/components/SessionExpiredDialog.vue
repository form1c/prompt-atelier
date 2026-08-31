<script setup>
import { useRouter } from 'vue-router'
import { t } from '@/i18n'
import { session, signOut } from '@/state/session'
import { reauthentication, completeSignIn, abandonSignIn } from '@/state/reauthentication'
import { notify } from '@/state/notices'
import SignInForm from '@/components/SignInForm.vue'

// TF-415 — the session expires while someone is working.
//
// The screen behind stays exactly as it is. That is the whole point: a
// redirect to the sign-in page would throw away a half-filled form, and the
// user would have to reconstruct from memory what they had typed. The overlay
// asks for the password, the client repeats the request that ran into the
// expiry, and the work carries on where it stopped.

const router = useRouter()

async function leave () {
  abandonSignIn()
  await signOut()
  notify(t('session.signed_out'))
  await router.replace({ name: 'login' })
}
</script>

<template>
  <!-- No Escape binding, unlike the dialogues in 11.6. Both ways out of this
       one have consequences — carry on, or sign out — and a key pressed in
       passing should not pick either. -->
  <div v-if="reauthentication.open" class="overlay">
    <div
      class="overlay__dialog"
      role="dialog"
      aria-modal="true"
      aria-labelledby="session-expired-title"
    >
      <h1 id="session-expired-title">{{ t('session.expired_title') }}</h1>
      <p>{{ t('session.expired_hint') }}</p>

      <SignInForm
        :submit-label="t('session.resume')"
        :busy-label="t('login.submitting')"
        :initial-email="session.user?.email ?? ''"
        @signed-in="completeSignIn"
      />

      <button type="button" class="button button--plain overlay__leave" @click="leave">
        {{ t('session.abandon') }}
      </button>
    </div>
  </div>
</template>

<style scoped>
.overlay {
  position: fixed;
  inset: 0;
  z-index: 30;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 1.5rem;
  background: rgb(31 35 40 / 55%);
}

.overlay__dialog {
  width: 100%;
  max-width: 24rem;
  padding: 1.5rem;
  border-radius: var(--radius);
  background: var(--surface);
  box-shadow: var(--shadow);
}

.overlay__dialog h1 { font-size: 1.25rem; }

.overlay__dialog > p {
  color: var(--muted);
  font-size: 0.9375rem;
}

.overlay__leave {
  width: 100%;
  margin-top: 0.5rem;
}
</style>
