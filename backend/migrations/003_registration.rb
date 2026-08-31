# frozen_string_literal: true

require_relative '../services/migration'

# Self-registration and a readable audit log (FA-107, FA-908, SEC-07).
#
# **Why `pending_since` and not a third value in `users.status`.**
#
# The obvious shape for "waiting to be approved" is a status of its own beside
# `aktiv` and `gesperrt`. It was the first plan, and it was dropped after
# looking at what the migration would have to do: `status` carries a `CHECK`
# constraint, SQLite cannot alter one, and the table would have to be rebuilt.
# A rebuild means dropping `users` while `memberships`, `prompts`, `favorites`,
# `sessions` and `audit_logs` point at it — and SQLite's own documentation says
# that `DROP TABLE` with foreign keys enabled performs an implicit delete that
# **may fire foreign key actions**. `memberships.user_id` cascades and
# `audit_logs.actor_id` sets null: the rebuild could have emptied every
# membership and anonymised the whole log. `PRAGMA defer_foreign_keys` defers
# the violation *check*, not the *actions*, so it is no way out either, and the
# procedure SQLite recommends needs `PRAGMA foreign_keys = OFF` — which is
# ignored inside a transaction, and migrations run inside one on purpose.
#
# So the state is carried by a column of its own, added the boring way. What
# matters for the login gate is unchanged: a waiting account is `gesperrt` and
# is refused by the same single condition as any other locked one. The column
# decides only what the person is *told* and how the account is *listed* — and
# that is exactly the distinction it exists for. Whoever is waiting must not
# read "your account is locked", and the administrator must be able to tell a
# newcomer from somebody he shut out himself.
#
# The two indexes are for FA-908. The log is filtered by person, by action and
# by period, and `retention.audit_max_entries` allows two hundred thousand
# rows — a filter without an index would be a table scan on every look.
PromptAtelier::Migration.register('003_registration') do
  <<~SQL
    ALTER TABLE users ADD COLUMN pending_since DATETIME;

    CREATE INDEX idx_audit_actor  ON audit_logs (actor_id, created_at DESC);
    CREATE INDEX idx_audit_action ON audit_logs (action, created_at DESC);
  SQL
end
