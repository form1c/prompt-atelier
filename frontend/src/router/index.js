import { createRouter, createWebHistory } from 'vue-router'
import { session, isSignedIn, loadSession } from '@/state/session'
import LibraryView from '@/views/LibraryView.vue'
import PromptView from '@/views/PromptView.vue'
import PromptEditorView from '@/views/PromptEditorView.vue'
import PromptTransferView from '@/views/PromptTransferView.vue'
import KeywordsView from '@/views/KeywordsView.vue'
import WorkspaceView from '@/views/WorkspaceView.vue'
import TrashView from '@/views/TrashView.vue'
import TransferView from '@/views/TransferView.vue'
import AdminAccountsView from '@/views/admin/AccountsView.vue'
import AdminWorkspacesView from '@/views/admin/WorkspacesView.vue'
import AdminAuditView from '@/views/admin/AuditView.vue'
import AdminSettingsView from '@/views/admin/SettingsView.vue'
import ProfileView from '@/views/ProfileView.vue'
import LoginView from '@/views/LoginView.vue'
import RegisterView from '@/views/RegisterView.vue'
import SetupView from '@/views/SetupView.vue'

// Paths and query parameter names are English, like every other identifier in
// this code base. They used to be German on the argument that the address bar
// is on display — but an address is not a caption: it gets typed, pasted into
// tickets and matched by scripts, and a German path beside an English route
// name meant every navigation was written twice in two languages.
//
// What stays German are **domain values**: `status=active`, `visibility=private`,
// `sort=changed`. Those are data, they are stored that way (14.1) and the API
// speaks them; translating them would be a schema migration, not a rename.
//
// The screens are imported outright rather than loaded per route. The usual
// argument for splitting is the size of the first download, and at this scale
// it does not apply: the whole application is well inside NFA-06, so the
// split would buy nothing and cost a round trip on the way to every screen —
// against NFA-03, which counts the time until the library is on display.
// Worth revisiting when a screen brings a heavy dependency of its own; a
// per-route split is a one-line change when it does.

const routes = [
  { path: '/', name: 'library', component: LibraryView },
  // Before '/prompt/:id', or "new" would be read as an identifier and the
  // editor for a new prompt would be a request for the prompt named "new".
  { path: '/prompt/new', name: 'prompt-new', component: PromptEditorView },
  { path: '/prompt/:id', name: 'prompt', component: PromptView },
  { path: '/prompt/:id/edit', name: 'prompt-edit', component: PromptEditorView },
  { path: '/prompt/:id/duplicate', name: 'prompt-duplicate', component: PromptTransferView },
  { path: '/prompt/:id/move', name: 'prompt-move', component: PromptTransferView },
  { path: '/keywords', name: 'keywords', component: KeywordsView },
  { path: '/workspace', name: 'workspace', component: WorkspaceView },
  { path: '/trash', name: 'trash', component: TrashView },
  { path: '/transfer', name: 'transfer', component: TransferView },
  // Four screens behind one entry in the sidebar (S6). One page that loaded
  // accounts, workspaces and the log on every visit was fine while an
  // instance was small; each section now fetches its own data and carries its
  // own filters in the address, so a view of the log can be handed on as a
  // link.
  { path: '/administration', redirect: { name: 'admin-accounts' } },
  { path: '/administration/accounts', name: 'admin-accounts', component: AdminAccountsView },
  { path: '/administration/workspaces', name: 'admin-workspaces', component: AdminWorkspacesView },
  { path: '/administration/audit', name: 'admin-audit', component: AdminAuditView },
  { path: '/administration/settings', name: 'admin-settings', component: AdminSettingsView },
  { path: '/profile', name: 'profile', component: ProfileView },
  { path: '/login', name: 'login', component: LoginView, meta: { public: true } },
  // Public whether or not the setting is on: a bookmark outlives a change of
  // configuration, and the screen itself says so rather than the router
  // pretending the address never existed (FA-107).
  { path: '/register', name: 'register', component: RegisterView, meta: { public: true } },
  { path: '/setup', name: 'setup', component: SetupView, meta: { public: true } },
  // An unknown address is not an error worth a screen of its own in an
  // application this size — it leads to the library, which is where someone
  // who mistyped wanted to go.
  { path: '/:rest(.*)*', redirect: { name: 'library' } }
]

export function createAppRouter (history = createWebHistory()) {
  const router = createRouter({ history, routes })
  router.beforeEach(guard)
  return router
}

// The only place that decides whether a screen may be shown. Note what it is
// not: protection. The server refuses every unauthorised call regardless
// (SEC-06) — this guard exists so the user sees the sign-in screen instead of
// an empty library that fills with 401s.
export async function guard (to) {
  if (session.status === 'unknown') await loadSession()

  // FA-909: an instance without a single account can do exactly one thing.
  if (session.status === 'setup') {
    return to.name === 'setup' ? true : { name: 'setup' }
  }
  if (to.name === 'setup') {
    return { name: isSignedIn() ? 'library' : 'login' }
  }

  if (to.meta?.public) {
    return isSignedIn() ? { name: 'library' } : true
  }

  // FA-903: after an administrator reset the application is closed until a
  // password of one's own is set. The profile is the one screen that opens —
  // it is where the change is made, and it says why nothing else does.
  //
  // A guard and not a screen decision: any other place would leave one route
  // somebody could still walk through, and "kann die Anwendung erst danach
  // benutzen" is a statement about all of them.
  if (isSignedIn()) {
    return session.user?.must_change_password && to.name !== 'profile'
      ? { name: 'profile' }
      : true
  }

  // Where the user wanted to go, so the sign-in can carry on to it. Only
  // in-application paths: a full URL here would turn the sign-in screen into
  // a redirector to any site that asks.
  return { name: 'login', query: continuation(to.fullPath) }
}

export function continuation (fullPath) {
  const internal = typeof fullPath === 'string' &&
    fullPath.startsWith('/') && !fullPath.startsWith('//')

  return internal && fullPath !== '/' ? { next: fullPath } : {}
}

// NT-2 asks what the back button does after signing out. Within the
// application it is a normal navigation and the guard above answers it. What
// the guard never sees is a page the browser restored from its cache — the
// user left the application, came back, and the browser puts the old screen
// on display without running a single line of ours.
//
// So the session is asked again on exactly that event. Without it the last
// screen before signing out would still be readable, and only the first click
// would reveal that nothing works any more.
export function revalidateOnRestore (router, target = globalThis.window) {
  if (!target?.addEventListener) return

  target.addEventListener('pageshow', async (event) => {
    if (!event.persisted) return

    await loadSession()
    if (!isSignedIn()) await router.replace({ name: 'login' })
  })
}
