# frozen_string_literal: true

require_relative '../services/migration'

# Timestamps in UTC (Testkonzept TF-427, Requirements 15.1).
#
# Until now every timestamp was written in the local time of the server, with
# no offset beside it: `2026-08-02 10:52:30.309505`. Reading it back on the
# same machine at the same time of year gives the right instant, which is why
# nothing was ever visibly wrong. What that form cannot express:
#
#   * The hour of the autumn clock change happens twice. A row written at
#     02:30 is ambiguous, and there is nothing in the value to resolve it.
#   * A server that moves, or an operator who fixes the machine's time zone,
#     silently reinterprets every row that was written before.
#   * `Time.iso8601` in an answer would carry the offset of the *reading*
#     moment, not of the writing one — so a summer entry read in winter would
#     be an hour off in the browser.
#
# From here on Sequel writes and reads UTC (`Sequel.default_timezone`), and
# the answers carry `+00:00`. The browser turns that back into local time,
# which is what TF-427 asks for.
#
# **The existing rows are converted here.** `datetime(…, 'utc')` treats the
# value as local time and applies the offset that was in force *on that date*
# — SQLite consults the system time zone rules, so a row from January is
# shifted by one hour and a row from July by two, in this time zone. A single
# offset for all rows would have been wrong for exactly the dates that make
# this migration necessary.
#
# `strftime('%Y-%m-%d %H:%M:%f', …)` rather than plain `datetime(…)`: the
# latter truncates to whole seconds, and the sub-second part is what keeps
# rows written in the same second in order.
PromptAtelier::Migration.register('002_utc_timestamps') do
  columns = {
    'users'             => %w[last_login_at created_at updated_at],
    'workspaces'        => %w[created_at updated_at],
    'memberships'       => %w[created_at],
    'prompts'           => %w[created_at updated_at deleted_at],
    'tags'              => %w[created_at],
    'keywords'          => %w[created_at updated_at],
    'favorites'         => %w[created_at],
    'prompt_revisions'  => %w[created_at],
    'sessions'          => %w[last_seen_at expires_at created_at],
    'audit_logs'        => %w[created_at],
    'login_attempts'    => %w[attempted_at]
  }

  # `schema_migrations.applied_at` is deliberately **not** in that list.
  #
  # On a fresh installation both steps run in one transaction: 001 records
  # itself — and by then Sequel is already writing UTC — and 002 would then
  # convert that value a second time, putting it an offset into the past. The
  # two cases cannot be told apart from the data: a row from an older
  # installation is local time, a row from this very run is not.
  #
  # Leaving the column alone is the honest way out. Nothing reads it: the
  # migrator looks at `version`, never at the time. It is a note in a logbook,
  # and a note that is an hour out is better than a value that was corrected
  # into being wrong.
  #
  # Found by looking at a database that had actually been migrated — the test
  # applied 001 by hand and never saw the two steps meet.

  # The FTS triggers listen on title, description and body only, so touching
  # the time columns of `prompts` leaves the search index alone. Verified
  # against the trigger definitions in 001; a trigger on the whole row would
  # have meant rebuilding the index here.
  statements = columns.map do |table, names|
    assignments = names.map do |name|
      "#{name} = strftime('%Y-%m-%d %H:%M:%f', #{name}, 'utc')"
    end.join(",\n        ")

    <<~SQL
      UPDATE #{table} SET
        #{assignments}
      WHERE #{names.map { |name| "#{name} IS NOT NULL" }.join(' OR ')};
    SQL
  end

  statements.join("\n")
end
