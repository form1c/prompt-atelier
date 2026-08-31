import { reactive, readonly } from 'vue'
import { get, post, put, onSessionExpired, ApiError } from '@/api/client'

// Who is signed in, and the two questions that depend on it: may this screen
// be shown, and which workspace is it about.
//
// Deliberately a plain reactive module rather than a store library. It holds
// four values and three actions; a dependency for that would be more code to
// keep in step than the thing it replaces.

// unknown    not asked yet — the state at the first paint
// signed-in  a session exists
// signed-out no session; the sign-in screen belongs on the display
// setup      the instance has no account at all (FA-909)
const state = reactive({
  status: 'unknown',
  user: null,
  workspaces: [],
  selectedWorkspaceId: null
})

export const session = readonly(state)

export function isSignedIn () {
  return state.status === 'signed-in'
}

// Asks the server who we are. Called once before the first navigation, and
// again whenever the browser may have restored a page from its cache.
//
// allowExpiry is off: a 401 here is the normal answer for a browser that is
// simply not signed in, not an expired session, and it must not open the
// overlay that asks a signed-out user to sign in again.
export async function loadSession () {
  try {
    const payload = await get('/auth/me', { allowExpiry: false })
    state.user = payload.user
    state.status = 'signed-in'
    await loadWorkspaces()
  } catch (error) {
    if (!(error instanceof ApiError) || !error.unauthorized) throw error

    state.user = null
    state.status = (await setupRequired()) ? 'setup' : 'signed-out'
  }
  return state.status
}

export async function signIn (email, password) {
  const payload = await post('/auth/login', {
    body: { email, password },
    allowExpiry: false
  })
  state.user = payload.user
  state.status = 'signed-in'
  await loadWorkspaces()
  return state.user
}

// FA-107. Two outcomes, and they are not the same event: with `open` the
// answer carries a session and the person is in, with `approval` it carries
// nothing but the news that they are waiting. Returning the flag rather than
// deciding here keeps the screen in charge of what it says.
export async function registerAccount ({ name, email, password }) {
  const payload = await post('/auth/register', {
    body: { name, email, password },
    allowExpiry: false
  })

  if (payload.pending) return { pending: true, code: payload.code }

  state.user = payload.user
  state.status = 'signed-in'
  await loadWorkspaces()
  return { pending: false, user: state.user }
}

// Whether the login screen offers a way in at all. Asked of the server and
// never guessed: it is a setting of the instance (18.4), and a browser that
// decided for itself would offer a button that answers 403.
export async function registrationState () {
  try {
    return (await get('/auth/registration', { allowExpiry: false })).registration ?? { enabled: false }
  } catch {
    // The same reasoning as for the setup question: if it cannot be answered,
    // the closed door is the safe answer.
    return { enabled: false }
  }
}

export async function completeSetup ({ name, email, password }) {
  const payload = await post('/setup', {
    body: { name, email, password },
    allowExpiry: false
  })
  state.user = payload.user
  state.status = 'signed-in'
  await loadWorkspaces()
  return state.user
}

// FA-102. The local state is cleared even when the call fails: a server that
// cannot be reached must not leave a screen behind that looks signed in. The
// cookie is the authority, and it is gone either way once the browser is
// closed — but until then, showing someone else's name would be worse than a
// sign-out that the server did not hear about.
export async function signOut () {
  try {
    await post('/auth/logout', { allowExpiry: false })
  } finally {
    forgetSession()
  }
}

export function forgetSession () {
  state.user = null
  state.workspaces = []
  state.selectedWorkspaceId = null
  state.status = 'signed-out'
}

// FA-605. Which workspace someone last worked in is kept on the server, so a
// second device lands in the same place (TF-308f).
export async function selectWorkspace (workspaceId) {
  const payload = await put('/workspaces/selection', { body: { workspace_id: workspaceId } })
  state.selectedWorkspaceId = payload.selected_workspace_id
  return state.selectedWorkspaceId
}

export function selectedWorkspace () {
  return state.workspaces.find((workspace) => workspace.id === state.selectedWorkspaceId) ?? null
}

// The list again, after the workspace screen changed it. A rename has to
// reach the header, and a deletion has to take the entry out of the switcher
// — both are on display in a component that knows nothing about that screen.
//
// The selected workspace comes back from the server too, deliberately: after
// deleting the one that was chosen, the server names the fallback (FA-605),
// and picking one here would be the browser deciding something it has no
// business deciding.
export async function refreshWorkspaces () {
  await loadWorkspaces()
}

async function loadWorkspaces () {
  const payload = await get('/workspaces')
  state.workspaces = payload.workspaces ?? []
  state.selectedWorkspaceId = payload.selected_workspace_id ?? null
}

async function setupRequired () {
  try {
    return (await get('/setup/status', { allowExpiry: false })).setup_required === true
  } catch {
    // Whether the instance needs setting up is a nicety; if the question
    // cannot be answered, the sign-in screen is the safe answer.
    return false
  }
}

// --- expiry (FA-103, TF-415) ----------------------------------------------

// Installed once at startup. The overlay component takes over from here: it
// puts itself on the screen, and resolves the promise when the user has
// signed in again — at which point the client repeats the request that ran
// into the expired session.
export function installExpiryHandler (openOverlay) {
  onSessionExpired(async () => {
    state.status = 'expired'
    await openOverlay()
    state.status = 'signed-in'
  })
}
