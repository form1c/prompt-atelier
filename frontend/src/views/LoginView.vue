<script setup>
import { onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { t } from '@/i18n'
import { registrationState } from '@/state/session'
import SignInForm from '@/components/SignInForm.vue'
import BrandMark from '@/components/BrandMark.vue'

// S8 — the sign-in screen (FA-101, FA-107).

const route = useRoute()
const router = useRouter()

// Asked of the server rather than assumed. The way in is a setting of the
// instance (18.4), delivered switched off, and a screen that offered the
// button regardless would send people to a form that answers 403.
const registration = ref({ enabled: false })

onMounted(async () => { registration.value = await registrationState() })

async function proceed () {
  // Back to wherever the guard interrupted, otherwise the library. `replace`
  // rather than `push`: the sign-in screen has no business in the history a
  // back button walks through.
  const target = route.query.next
  await router.replace(typeof target === 'string' && target.startsWith('/') ? target : { name: 'library' })
}
</script>

<template>
  <main class="signin">
    <div class="signin__card">
      <BrandMark />
      <h1>{{ t('login.title') }}</h1>

      <SignInForm
        :submit-label="t('login.submit')"
        :busy-label="t('login.submitting')"
        @signed-in="proceed"
      />

      <p v-if="registration.enabled" class="signin__register">
        <RouterLink :to="{ name: 'register' }" data-test="to-register">
          {{ t('login.register') }}
        </RouterLink>
      </p>

      <!-- E-13, TF-421: this is deliberately a paragraph and not a link.
           There is no self-service reset in v1, and an inviting "Passwort
           vergessen?" that leads nowhere is worse than the plain sentence
           about who can help. -->
      <section class="signin__hint" aria-labelledby="forgotten">
        <h2 id="forgotten">{{ t('login.forgotten_title') }}</h2>
        <p>{{ t('login.forgotten_hint') }}</p>
      </section>
    </div>
  </main>
</template>

<style scoped>
.signin {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100%;
  padding: 1.5rem;
}

.signin__card {
  width: 100%;
  max-width: 26rem;
  padding: 1.75rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface);
  box-shadow: var(--shadow);
}


.signin__register {
  margin-top: 1rem;
  margin-bottom: 0;
  text-align: center;
  font-size: 0.9375rem;
}

.signin__hint {
  margin-top: 1.5rem;
  padding-top: 1rem;
  border-top: 1px solid var(--border);
}

.signin__hint h2 {
  font-size: 0.9375rem;
}

.signin__hint p {
  margin: 0;
  color: var(--muted);
  font-size: 0.9375rem;
}
</style>
