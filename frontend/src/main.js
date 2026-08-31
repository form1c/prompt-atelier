import { createApp } from 'vue'
import App from '@/App.vue'
import { createAppRouter, revalidateOnRestore } from '@/router'
import { installExpiryHandler } from '@/state/session'
import { requestSignIn } from '@/state/reauthentication'
import '@/styles/base.css'

// Application entry point.
//
// The order matters in one place: the expiry handler is installed before the
// router is created. The router's first guard already talks to the server,
// and a 401 arriving before the handler exists would end up as an error
// instead of as the overlay.

installExpiryHandler(requestSignIn)

const router = createAppRouter()
revalidateOnRestore(router)

createApp(App).use(router).mount('#app')
