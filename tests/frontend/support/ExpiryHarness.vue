<script setup>
import { ref } from 'vue'
import { post } from '@/api/client'
import SessionExpiredDialog from '@/components/SessionExpiredDialog.vue'

// A stand-in for any screen with unsaved input, for TF-415.
//
// It has to be a screen the test can inspect: one field that holds what the
// user typed, one action that writes, and the overlay above both. Using a
// real screen instead would tie the test to whichever one happens to have a
// form this week.

const draft = ref('')
const saved = ref(null)
const failure = ref(null)

async function save () {
  failure.value = null
  try {
    saved.value = await post('/prompts', { body: { title: draft.value } })
  } catch (error) {
    failure.value = error
  }
}

defineExpose({ draft, saved, failure })
</script>

<template>
  <div>
    <input data-test="draft" v-model="draft">
    <button data-test="save" type="button" @click="save">save</button>
    <SessionExpiredDialog />
  </div>
</template>
