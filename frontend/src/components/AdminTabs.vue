<script setup>
import { t } from '@/i18n'

// The four sections of the administration (S6).
//
// One entry in the sidebar, four screens behind it. Until AP-15b they were
// one page that loaded accounts, workspaces and the log on every visit — even
// when somebody only wanted to reset a password. Split, each screen fetches
// its own data and carries its own filters in the address, so a view of the
// log can be handed to somebody else as a link.
//
// The price is one click more on a small instance. That is what it costs to
// stay usable on a large one.

const SECTIONS = [
  { route: 'admin-accounts', label: 'admin.tab_accounts' },
  { route: 'admin-workspaces', label: 'admin.tab_workspaces' },
  { route: 'admin-audit', label: 'admin.tab_audit' },
  { route: 'admin-settings', label: 'admin.tab_settings' }
]
</script>

<template>
  <nav class="tabs" :aria-label="t('admin.sections')">
    <RouterLink
      v-for="section in SECTIONS"
      :key="section.route"
      class="tabs__link"
      :to="{ name: section.route }"
    >
      {{ t(section.label) }}
    </RouterLink>
  </nav>
</template>

<style scoped>
.tabs {
  display: flex;
  flex-wrap: wrap;
  gap: 0.25rem;
  margin-bottom: 1.25rem;
  border-bottom: 1px solid var(--border);
}

.tabs__link {
  padding: 0.5rem 0.875rem;
  border-bottom: 2px solid transparent;
  color: var(--muted);
  text-decoration: none;
}

.tabs__link:hover {
  color: var(--text);
}

/* The active section is marked by more than colour — a border below it, so it
   is distinguishable without colour vision (NFA-11). */
.tabs__link.router-link-active {
  border-bottom-color: var(--accent);
  color: var(--text);
  font-weight: 600;
}
</style>
