<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { t } from '@/i18n'
import { workspaceName } from '@/util/workspace'
import { session, signOut, selectWorkspace, selectedWorkspace } from '@/state/session'
import { get } from '@/api/client'
import { notify } from '@/state/notices'
import Icon from '@/components/Icon.vue'

// The frame every signed-in screen sits in (Requirements 11.2): header with
// the workspace switcher, sidebar with the sections.
//
// The entries are data, and an entry only appears once its route exists. That
// is why the sidebar is short at this stage and grows by itself as the later
// packages register their screens — the alternative, listing everything now
// and greying out what is missing, produces a menu full of dead ends and a
// second list to keep in step.

// The running version, shown at the foot of the account menu.
//
// **Why it is on the screen at all.** The endpoint has existed since AP-01 and
// nothing displayed it, so the only way to learn which version an instance ran
// was the command line — on a machine the person reporting a fault usually
// cannot reach. A bug report without a version costs a round trip every time.
//
// **Shown in two places, on purpose.** At the foot of the sidebar it is
// visible without a click, which is where it reads best. That place is not
// reliable on its own: the library fills the same sidebar with the tag list of
// the workspace, and with enough tags the version leaves the screen. The
// account menu is therefore the second place, two clicks from anywhere and
// independent of how long the sidebar happens to be.
//
// Failure is deliberately silent: an instance that answers everything else but
// not this one should still be usable, and a red box over a version number
// would be worse than no version number.
const version = ref(null)

onMounted(async () => {
  try {
    const payload = await get('/version')
    version.value = payload?.app ?? null
  } catch {
    version.value = null
  }
})

const MAIN = [
  { route: 'library', label: 'shell.nav.library' },
  { route: 'favorites', label: 'shell.nav.favorites' },
  { route: 'recent', label: 'shell.nav.recent' }
]

const MANAGEMENT = [
  { route: 'keywords', label: 'shell.nav.keywords' },
  { route: 'workspace', label: 'shell.nav.workspace' },
  { route: 'transfer', label: 'shell.nav.transfer' },
  { route: 'trash', label: 'shell.nav.trash' }
]

const INSTANCE = [
  { route: 'admin-accounts', label: 'shell.nav.administration' }
]

// FA-509: "Alle Workspaces" is not a workspace but a view across everything
// the user may read. Offered only where it means something — the library
// passes it in, the other screens do not.
const ACROSS_ALL = 'all'

const props = defineProps({
  // Which entry the switcher shows as chosen. A plain value rather than the
  // session's own, because the library keeps it in the address (FA-506) and
  // "all" exists only there.
  workspaceValue: { type: String, default: '' },
  allWorkspaces: { type: Boolean, default: false }
})

const emit = defineEmits(['choose-workspace'])

const router = useRouter()
const workspaceMenu = ref(false)
const accountMenu = ref(false)

const existing = (entries) => entries.filter((entry) => router.hasRoute(entry.route))

const canCreate = computed(() => router.hasRoute('prompt-new'))

// 11.6: `n` opens a new prompt, and single-key shortcuts only work outside an
// input field — inside one they would type their letter. It lives in the frame
// rather than on a screen because it works on all of them.
function onShortcut (event) {
  const inField = ['INPUT', 'TEXTAREA', 'SELECT'].includes(event.target?.tagName)
  if (event.key !== 'n' || inField || event.ctrlKey || event.metaKey || event.altKey) return
  if (!canCreate.value) return

  event.preventDefault()
  router.push({ name: 'prompt-new' })
}

onMounted(() => window.addEventListener('keydown', onShortcut))
onUnmounted(() => window.removeEventListener('keydown', onShortcut))

const across = computed(() => props.workspaceValue === ACROSS_ALL)

const main = computed(() => existing(MAIN))

// 11.2: in the view across all workspaces the management entries disappear.
// They need one unambiguous workspace — keywords, members, the trash all
// belong to exactly one — and an entry that would have to ask "which one?"
// after being clicked is a question the menu should not be asking.
const management = computed(() => (across.value ? [] : existing(MANAGEMENT)))
const instance = computed(() => (
  session.user?.is_instance_admin ? existing(INSTANCE) : []
))

const chosenValue = computed(() => (
  props.workspaceValue || String(session.selectedWorkspaceId ?? '')
))

const current = computed(() => {
  if (across.value) return { name: t('shell.all_workspaces') }
  if (props.workspaceValue) {
    const chosen = session.workspaces.find((entry) => String(entry.id) === props.workspaceValue)
    if (chosen) return chosen
  }
  return selectedWorkspace()
})

// A screen that passes a value in decides itself what a change means — the
// library writes it into the address. Without one, the switcher keeps the
// server-side choice up to date on its own (FA-605).
async function choose (value) {
  workspaceMenu.value = false
  if (value === props.workspaceValue) return

  if (props.workspaceValue !== '' || props.allWorkspaces) {
    emit('choose-workspace', value)
    return
  }

  await selectWorkspace(Number(value))
}

async function leave () {
  accountMenu.value = false
  await signOut()
  notify(t('session.signed_out'))
  // FA-102 and NT-2: `replace`, so the screen that was on display before
  // signing out is not one step back in the history.
  await router.replace({ name: 'login' })
}
</script>

<template>
  <div class="shell">
    <header class="shell__header">
      <p class="shell__brand">{{ t('app.name') }}</p>

      <div class="menu">
        <button
          type="button"
          class="button button--quiet"
          :aria-expanded="workspaceMenu"
          @click="workspaceMenu = !workspaceMenu"
        >
          <span class="visually-hidden">{{ t('shell.workspace_label') }}</span>
          {{ current ? workspaceName(current) : "—" }}
          <Icon name="chevron-down" class="menu__caret" />
        </button>

        <ul v-if="workspaceMenu" class="menu__list">
          <li v-for="workspace in session.workspaces" :key="workspace.id">
            <button
              type="button"
              class="menu__item"
              :aria-current="String(workspace.id) === chosenValue"
              @click="choose(String(workspace.id))"
            >
              {{ workspaceName(workspace) }}
              <span v-if="workspace.is_personal" class="menu__note">
                {{ t('shell.personal_marker') }}
              </span>
            </button>
          </li>

          <!-- Set apart at the end on purpose (11.2): this is not a workspace
               but a view over everything the user may read. -->
          <li v-if="allWorkspaces" class="menu__divider">
            <button
              type="button"
              class="menu__item"
              :aria-current="across"
              @click="choose('all')"
            >
              {{ t('shell.all_workspaces') }}
            </button>
          </li>
        </ul>
      </div>

      <!-- The search field belongs to the screen, not to the frame: only the
           library knows what searching means there (11.2, 11.3). -->
      <div class="shell__search">
        <slot name="search" />
      </div>

      <!-- 11.2: making something new is reachable from every screen, not only
           from an empty library. Absent until its screen exists, like every
           other entry here. -->
      <RouterLink v-if="canCreate" class="button shell__new" :to="{ name: 'prompt-new' }">
        <Icon name="plus-lg" /> <span class="shell__new-label">{{ t('shell.new_prompt') }}</span>
      </RouterLink>

      <!-- The same look as the workspace switcher next to it. It used to be
           `button--plain` — no border, no background — and read as a label
           that happened to carry a name, not as something to press. Two menu
           buttons side by side that look different is a difference the eye
           has to explain away. -->
      <div class="menu menu--end">
        <button
          type="button"
          class="button button--quiet"
          :aria-expanded="accountMenu"
          @click="accountMenu = !accountMenu"
        >
          <Icon name="person-circle" />
          <span class="visually-hidden">{{ t('shell.account_label') }}</span>
          {{ session.user?.name }}
          <Icon name="chevron-down" class="menu__caret" />
        </button>

        <ul v-if="accountMenu" class="menu__list menu__list--end">
          <li v-if="router.hasRoute('profile')">
            <RouterLink class="menu__item" :to="{ name: 'profile' }" @click="accountMenu = false">
              <Icon name="person-circle" /> {{ t('shell.profile') }}
            </RouterLink>
          </li>
          <li>
            <button type="button" class="menu__item" @click="leave">
              <Icon name="box-arrow-right" /> {{ t('shell.sign_out') }}
            </button>
          </li>
          <!-- A statement, not an action, so neither a button nor anything
               focusable. The keyboard order of the menu stays what it was,
               two entries, both of which do something. -->
          <li v-if="version" class="menu__note">{{ t('shell.version', { version }) }}</li>
        </ul>
      </div>
    </header>

    <div class="shell__body">
      <nav class="shell__sidebar">
        <ul class="nav">
          <li v-for="entry in main" :key="entry.route">
            <RouterLink :to="{ name: entry.route }">{{ t(entry.label) }}</RouterLink>
          </li>
        </ul>

        <slot name="sidebar" />

        <template v-if="management.length">
          <h2 class="nav__heading">{{ t('shell.sections.management') }}</h2>
          <ul class="nav">
            <li v-for="entry in management" :key="entry.route">
              <RouterLink :to="{ name: entry.route }">{{ t(entry.label) }}</RouterLink>
            </li>
          </ul>
        </template>

        <template v-if="instance.length">
          <h2 class="nav__heading">{{ t('shell.sections.instance') }}</h2>
          <ul class="nav">
            <li v-for="entry in instance" :key="entry.route">
              <RouterLink :to="{ name: entry.route }">{{ t(entry.label) }}</RouterLink>
            </li>
          </ul>
        </template>
        <p v-if="version" class="shell__version">{{ t('shell.version', { version }) }}</p>
      </nav>

      <main class="shell__main">
        <slot />
      </main>
    </div>
  </div>
</template>

<style scoped>
.shell {
  display: flex;
  flex-direction: column;
  min-height: 100%;
}

.shell__header {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.5rem 1rem;
  border-bottom: 1px solid var(--border);
  background: var(--surface);
}

.shell__brand {
  margin: 0;
  font-weight: 700;
}

.menu {
  position: relative;
}

.menu--end {
  margin-left: 0.5rem;
}

.shell__search {
  flex: 1;
  max-width: 32rem;
  margin-left: auto;
}

.shell__new {
  text-decoration: none;
}

/* Below the two-column threshold the label goes and the plus stays: the
   button keeps its meaning, the header keeps its room (11.6). */
@media (max-width: 599px) {
  .shell__new-label { display: none; }
}

.menu__divider {
  margin-top: 0.25rem;
  padding-top: 0.25rem;
  border-top: 1px solid var(--border);
}

.menu__list {
  position: absolute;
  z-index: 10;
  min-width: 12rem;
  margin: 0.25rem 0 0;
  padding: 0.25rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface);
  box-shadow: var(--shadow);
  list-style: none;
}

.menu__list--end {
  right: 0;
}

.menu__item {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  width: 100%;
  padding: 0.375rem 0.5rem;
  border: 0;
  border-radius: var(--radius);
  background: none;
  text-align: left;
  cursor: pointer;
}

.menu__item:hover { background: var(--surface-sunken); }
.menu__item[aria-current="true"] { font-weight: 600; }

.menu__note {
  margin-left: auto;
  color: var(--muted);
  font-size: 0.8125rem;
}

/* Small and set back: it says the button opens something, it is not part of
   what the button is called. */
.menu__caret {
  margin-left: 0.125rem;
  font-size: 0.75em;
  opacity: 0.7;
}

.shell__body {
  display: flex;
  flex: 1;
  align-items: stretch;
}

.shell__sidebar {
  flex: 0 0 14rem;
  padding: 1rem;
  border-right: 1px solid var(--border);
  background: var(--surface);
}

.nav {
  margin: 0 0 1rem;
  padding: 0;
  list-style: none;
}

.nav a {
  display: block;
  padding: 0.375rem 0.5rem;
  border-radius: var(--radius);
  color: var(--text);
  text-decoration: none;
}

.nav a:hover { background: var(--surface-sunken); }

.nav a.router-link-active {
  background: var(--surface-sunken);
  font-weight: 600;
}

.nav__heading {
  margin: 0 0 0.375rem;
  color: var(--muted);
  font-size: 0.75rem;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.menu__note {
  padding: 0.5rem 0.75rem 0.375rem;
  border-top: 1px solid var(--border);
  color: var(--muted);
  font-size: 0.75rem;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

.shell__version {
  margin: 1.5rem 0 0;
  color: var(--muted);
  font-size: 0.75rem;
  font-variant-numeric: tabular-nums;
}

.shell__main {
  flex: 1;
  padding: 1.5rem;
}

/* Requirements 11.6: usable from 360 px. Below the two-column threshold the
   sidebar moves above the content instead of squeezing it. */
@media (max-width: 899px) {
  .shell__body { flex-direction: column; }

  .shell__sidebar {
    flex: 0 0 auto;
    border-right: 0;
    border-bottom: 1px solid var(--border);
  }
}
</style>
