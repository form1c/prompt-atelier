<script setup>
import NoticeHost from '@/components/NoticeHost.vue'
import SessionExpiredDialog from '@/components/SessionExpiredDialog.vue'

// The root. Three things live above every screen: the screen itself, the
// short confirmations from 11.6, and the overlay for an expired session.
//
// The overlay sits here on purpose. Mounted inside a screen it would be
// unmounted the moment the guard sent that screen away — which is exactly the
// situation it exists for (TF-415).
</script>

<template>
  <RouterView />
  <NoticeHost />
  <SessionExpiredDialog />
</template>
