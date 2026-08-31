<script setup>
import { computed, ref, watch } from 'vue'
import { t, availableLanguages, languageName, setLanguage } from '@/i18n'
import { get, put, post, ApiError } from '@/api/client'
import { session, loadSession } from '@/state/session'
import { notify } from '@/state/notices'
import { jsonDocument, download } from '@/util/download'
import AppShell from '@/components/AppShell.vue'
import Icon from '@/components/Icon.vue'

// S7 — one's own account (FA-105, FA-106, SEC-18).
//
// Three things, and the third is the one that is easy to leave out: the
// self-disclosure. SEC-18 puts it **here**, in the user's own profile, and
// deliberately not with the administrator — chapter 6.2 promises that an
// instance administrator sees no foreign content, and a disclosure endpoint
// for other people would undo that promise in one line.
//
// The screen also carries the forced password change of FA-903. After a
// reset the router lets nothing else through, so this is the one screen a
// person in that state can reach — and it says why.

const account = ref({ name: '', email: '' })
const passwords = ref({ current: '', replacement: '', repeat: '' })
const accountError = ref(null)
const passwordError = ref(null)
const busy = ref(false)

const forced = computed(() => session.user?.must_change_password === true)

// The refusal as the person can act on it: a field message when the server
// named a field, the general sentence otherwise. Without this the screen shows
// "the entry is incomplete" and leaves them hunting for which one — the server
// answers `validation_failed` with a field, never a sentence about the field.
const accountProblem = computed(() => {
  const problem = accountError.value
  if (!problem) return ''

  const field = Object.keys(problem.fields ?? {})[0]
  return (field && problem.fieldMessage(field)) || problem.message
})

// Filled from the session rather than fetched: it is already there, and a
// second request would only be a chance for the two to disagree.
watch(() => session.user, (user) => {
  if (user) account.value = { name: user.name ?? '', email: user.email ?? '' }
}, { immediate: true })

// The languages on offer are the files that exist (11.7). A fixed list here
// would mean adding a language in two places, and the second one would be
// forgotten — "a new language is one file" has to be true of this select too.
//
// The empty option is what `users.locale` holds until somebody chooses:
// follow the instance, and the browser behind it. It is offered as a choice
// of its own because "no choice" is a state a person may want to go back to.
//
// Sorted by the name on display, not by the code behind it. The two happen to
// agree for `de` and `en`, which is exactly why sorting by code would look
// right until the third language arrived and landed in the wrong place.
const languages = availableLanguages()
  .map((code) => ({ code, name: languageName(code) }))
  .sort((one, other) => one.name.localeCompare(other.name))

async function saveLanguage (code) {
  if (busy.value) return

  busy.value = true
  try {
    // The **saved** name and address, not what stands in the form: changing
    // the language must not save a half-typed name along with it.
    await put('/auth/me', {
      body: { name: session.user.name, email: session.user.email, locale: code }
    })
    await loadSession()
    // Applied here as well as on the server: the next answer carries the new
    // `Content-Language`, but the screen the person is looking at right now
    // should not wait for a request that may not come.
    await setLanguage(code === '' ? undefined : code)
    notify(t('profile.language_saved'))
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    accountError.value = problem
  } finally {
    busy.value = false
  }
}

async function saveAccount () {
  if (busy.value) return

  busy.value = true
  accountError.value = null

  try {
    await put('/auth/me', { body: { name: account.value.name, email: account.value.email } })
    await loadSession()
    notify(t('profile.saved'))
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    accountError.value = problem
  } finally {
    busy.value = false
  }
}

async function changePassword () {
  if (busy.value) return

  // Checked here because the server never sees the repetition — it is a guard
  // against a typo, not a rule about passwords, and the rules themselves stay
  // where they belong (SEC-01, checked on the server).
  if (passwords.value.replacement !== passwords.value.repeat) {
    passwordError.value = { message: t('profile.password_mismatch') }
    return
  }

  busy.value = true
  passwordError.value = null

  try {
    await post('/auth/password', {
      body: { current_password: passwords.value.current, new_password: passwords.value.replacement }
    })
    passwords.value = { current: '', replacement: '', repeat: '' }
    // The session carries `must_change_password`; without reloading it the
    // router would keep the person on this screen after they had done exactly
    // what it asked for.
    await loadSession()
    notify(t('profile.password_changed'))
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    passwordError.value = problem
  } finally {
    busy.value = false
  }
}

// SEC-18. Handed over as a file rather than shown on the screen: it is
// somebody's whole record, and a page of JSON is not something one reads —
// it is something one keeps.
async function requestDisclosure () {
  if (busy.value) return

  busy.value = true

  try {
    const payload = await get('/auth/me/data-export')
    download('selbstauskunft.json', jsonDocument(payload.disclosure))
    notify(t('profile.disclosure_done'))
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    accountError.value = problem
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <AppShell>
    <h1>{{ t('profile.title') }}</h1>

    <!-- FA-903: after a reset this screen is the only one that opens, and
         saying so is part of it — a person who cannot get anywhere and is not
         told why will try the address bar. -->
    <div v-if="forced" class="alert" role="alert">
      <p><strong>{{ t('profile.forced_title') }}</strong></p>
      <p>{{ t('profile.forced_hint') }}</p>
    </div>

    <section class="panel" aria-labelledby="password-heading">
      <h2 id="password-heading">{{ t('profile.password_heading') }}</h2>

      <p v-if="passwordError" class="alert" role="alert">{{ passwordError.message }}</p>

      <form @submit.prevent="changePassword">
        <label class="field">
          <span>{{ t('profile.field_current') }}</span>
          <input v-model="passwords.current" type="password" autocomplete="current-password">
        </label>

        <div class="field">
          <label>
            <span>{{ t('profile.field_new') }}</span>
            <input v-model="passwords.replacement" type="password"
                   autocomplete="new-password" aria-describedby="password-rule">
          </label>
          <span id="password-rule" class="hint">{{ t('profile.password_hint') }}</span>
        </div>

        <label class="field">
          <span>{{ t('profile.field_repeat') }}</span>
          <input v-model="passwords.repeat" type="password" autocomplete="new-password">
        </label>

        <button type="submit" class="button" :disabled="busy" data-test="change-password">
          {{ t('profile.change_password') }}
        </button>
      </form>
    </section>

    <section class="panel" aria-labelledby="account-heading">
      <h2 id="account-heading">{{ t('profile.account_heading') }}</h2>

      <p v-if="accountError" class="alert" role="alert">{{ accountProblem }}</p>

      <form @submit.prevent="saveAccount">
        <label class="field">
          <span>{{ t('profile.field_name') }}</span>
          <input v-model="account.name" type="text">
        </label>

        <label class="field">
          <span>{{ t('profile.field_email') }}</span>
          <input v-model="account.email" type="email">
        </label>

        <button type="submit" class="button" :disabled="busy" data-test="save-account">
          {{ t('profile.save') }}
        </button>
      </form>
    </section>

    <section class="panel" aria-labelledby="language-heading">
      <h2 id="language-heading">{{ t('profile.language_heading') }}</h2>

      <label class="field">
        <span>{{ t('profile.field_language') }}</span>
        <select :value="session.user?.locale ?? ''" :disabled="busy"
                data-test="language" @change="saveLanguage($event.target.value)">
          <option value="">{{ t('profile.language_automatic') }}</option>
          <option v-for="language in languages" :key="language.code" :value="language.code">
            {{ language.name }}
          </option>
        </select>
      </label>

      <p class="hint">{{ t('profile.language_hint') }}</p>
    </section>

    <section class="panel" aria-labelledby="disclosure-heading">
      <h2 id="disclosure-heading">{{ t('profile.disclosure_heading') }}</h2>
      <p class="hint">{{ t('profile.disclosure_hint') }}</p>

      <button type="button" class="button button--quiet" :disabled="busy"
              data-test="disclosure" @click="requestDisclosure">
        <Icon name="download" /> {{ t('profile.disclosure') }}
      </button>
    </section>
  </AppShell>
</template>

<style scoped>
.panel .hint {
  display: block;
  margin-bottom: 0.75rem;
  color: var(--muted);
  font-size: 0.875rem;
}

.panel form {
  max-width: 26rem;
}

.alert p:last-child {
  margin-bottom: 0;
}
</style>
