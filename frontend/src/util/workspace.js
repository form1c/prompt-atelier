import { t } from '@/i18n'

// The name a workspace is shown under (11.7, AP-19).
//
// **The personal workspace has its name in the database.** `Workspaces.create`
// writes `Persönlich-<Name>` into the row at the moment an account is created,
// and no language switch reaches a stored row — it would still read German in
// an English interface, and translating the row later would rename something
// somebody may have renamed themselves.
//
// So the flag decides the label and the row keeps the name. `is_personal` is
// the truth about what the workspace *is*; the stored name stays as the
// fallback for rows that predate the flag and as the basis of the slug.
export function workspaceName (workspace) {
  if (!workspace) return ''

  return workspace.is_personal ? t('shell.personal_workspace') : (workspace.name ?? '')
}

// The same name, for a row that only *mentions* a workspace instead of being
// one: a hit in the library, a prompt in the trash. Those carry the workspace
// flattened into two fields, and both of them are needed — the name alone
// showed "Persönlich-Martin" three lines under a switcher reading "Persönlicher
// Workspace", which is one workspace wearing two names with nothing to say
// they are the same.
export function originName (row) {
  if (!row) return ''

  return workspaceName({ name: row.workspace_name, is_personal: row.workspace_is_personal })
}
