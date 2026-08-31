<script setup>
import { onMounted, ref } from 'vue'
import { t } from '@/i18n'
import { workspaceName } from '@/util/workspace'
import { get, ApiError } from '@/api/client'
import AppShell from '@/components/AppShell.vue'
import AdminTabs from '@/components/AdminTabs.vue'
import LoadingState from '@/components/LoadingState.vue'
import ErrorState from '@/components/ErrorState.vue'

// S6, workspaces (FA-907).
//
// Counts and an owner, and no way from here into anybody's content. Chapter
// 6.2 is a promise the shape of this list keeps: an instance administrator
// manages accounts and workspaces and reads no foreign prompts. He can obtain
// access by making himself a member — and that leaves a trace (SEC-09).

const workspaces = ref([])
const loading = ref(true)
const failure = ref(null)

onMounted(load)

async function load () {
  loading.value = true
  failure.value = null

  try {
    workspaces.value = (await get('/admin/workspaces')).workspaces ?? []
  } catch (problem) {
    if (!(problem instanceof ApiError)) throw problem

    failure.value = problem
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <AppShell>
    <h1>{{ t('admin.title') }}</h1>
    <AdminTabs />

    <ErrorState v-if="failure" :error="failure" :on-retry="load" />
    <LoadingState v-else-if="loading" :rows="4" />

    <section v-else class="panel" aria-labelledby="workspaces-heading">
      <h2 id="workspaces-heading">{{ t('admin.workspaces_heading', { count: workspaces.length }) }}</h2>

      <ul class="entries">
        <li v-for="workspace in workspaces" :key="workspace.id" class="entry">
          <span class="entry__name">{{ workspaceName(workspace) }}</span>
          <span class="entry__detail">
            <template v-if="workspace.is_personal">{{ t('admin.personal_marker') }} · </template>
            {{ t('admin.workspace_owner', { name: workspace.owner ?? '—' }) }}
            · {{ t('admin.workspace_counts', {
              members: workspace.member_count, prompts: workspace.prompt_count
            }) }}
          </span>
        </li>
      </ul>
    </section>
  </AppShell>
</template>
