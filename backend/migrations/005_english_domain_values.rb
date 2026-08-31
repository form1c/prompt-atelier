# frozen_string_literal: true

require_relative '../services/migration'
require_relative '../services/normalization'

# English domain values, and four letters the search could not find (AP-18).
#
# The application stores its domain values in German: a user is `aktiv`, a
# prompt is `entwurf` and `privat`. Nobody sees them — the screen reads what
# `de.json` says — but they sit in `CHECK` constraints, in every query and in
# every test, and they are the last German left in the implementation. This
# step translates them. **No behaviour changes**; the display stays German.
#
#   users.status            aktiv, gesperrt              -> active, locked
#   prompts.visibility      privat, workspace, instanz   -> private, workspace, instance
#   prompts.status          entwurf, aktiv, archiviert   -> draft, active, archived
#   prompt_variables.type   text, mehrzeilig, auswahl,   -> text, multiline, select,
#                           zahl                            number
#
# `memberships.role` and `keywords.position` were English from the start and
# are not touched.
#
# ---------------------------------------------------------------------------
#
# **Why this step declares `foreign_keys: :off`.**
#
# SQLite cannot alter a `CHECK` constraint. The only way is to build the table
# anew, copy, drop the old one and rename — and `DROP TABLE` with foreign keys
# on performs an implicit delete that fires `ON DELETE CASCADE`.
#
# Measured on this schema, both halves separately:
#
#   the `users` half   fails loudly, `FOREIGN KEY constraint failed`, because
#                      `prompts.owner_id` names no delete action
#   the `prompts` half runs **through**, and afterwards `prompt_variables`,
#                      `prompt_revisions`, `prompt_tags` and `favorites` are
#                      all empty. Nothing errors out: a cascade is not a
#                      violation
#
# The second one is why this is not a matter of ordering the statements
# better. Run in the order below the migration stops at `users` and nothing is
# lost — but that is luck, not a safeguard.
#
# Migration 003 ran into this and went around it — that is why `pending_since`
# is a column of its own instead of a third value in `users.status`. Here
# there is no way around it, so the migrator learned to set the pragma
# **before** it opens the transaction, where it is silently ignored, and to
# run `PRAGMA foreign_key_check` before committing. See Migrator#run_steps.
#
# ---------------------------------------------------------------------------
#
# **The four letters** (`ø ł đ æ`) ride along rather than getting a step of
# their own. Extending Normalization::REPLACEMENTS changes `sql_expression`,
# hence the triggers, hence the mirror columns — it is the very same table
# rebuild. Done twice it would be the same risk twice.
#
# Because the rule changes, **every mirror column is recomputed** during the
# copy, and the FTS index is emptied before and refilled afterwards.
#
# Not via the FTS5 `rebuild` command — and the reason is an ordering one, not a
# prohibition. Requirements 14.1 says the opposite of what an earlier draft of
# this comment claimed: since the mirror columns exist, `rebuild` reads the
# same values as normal operation and is safe (`test_rebuild_preserves_the_
# normalisation` in unit/fts_test.rb). What it cannot do is the first half of
# the job: an external content table has to be told the values it was filled
# from in order to give them up, and after the copy those values are gone.
PromptAtelier::Migration.register('005_english_domain_values', foreign_keys: :off) do
  n = PromptAtelier::Normalization.method(:sql_expression)

  # Repeated from 001 rather than shared: a migration has to keep saying what
  # it did on the day it ran. A helper pulled from elsewhere would change
  # under it the next time somebody edits that elsewhere, and this file would
  # then describe a step that never happened.
  tags_text = lambda do |prompt_id|
    <<~SQL.strip
      (SELECT coalesce(group_concat(#{n.call('t.name')}, ' '), '')
         FROM prompt_tags pt JOIN tags t ON t.id = pt.tag_id
        WHERE pt.prompt_id = #{prompt_id})
    SQL
  end

  fts_delete_from_prompts = lambda do |where|
    <<~SQL.strip
      INSERT INTO prompts_fts(prompts_fts, rowid, title_norm, description_norm, body_norm, tags_text)
        SELECT 'delete', id, title_norm, description_norm, body_norm, tags_text
          FROM prompts WHERE #{where};
    SQL
  end

  fts_insert_from_prompts = lambda do |where|
    <<~SQL.strip
      INSERT INTO prompts_fts(rowid, title_norm, description_norm, body_norm, tags_text)
        SELECT id, title_norm, description_norm, body_norm, tags_text
          FROM prompts WHERE #{where};
    SQL
  end

  # A CASE that leaves anything unknown alone. `ELSE column` rather than
  # `ELSE NULL`: a value the mapping does not know would otherwise become NULL
  # against a NOT NULL column, and the migration would fail on the row instead
  # of on the mapping. The new CHECK below is what actually refuses it, and it
  # names the value in the error.
  translate = lambda do |column, mapping|
    whens = mapping.map { |from, to| "WHEN '#{from}' THEN '#{to}'" }.join("\n           ")
    "CASE #{column}\n           #{whens}\n           ELSE #{column} END"
  end

  <<~SQL
    -- ------------------------------------------------- 1. empty the FTS index
    --
    -- Must come first, while `prompts` still holds the values the index was
    -- built from. An external content table is told what to remove, and it
    -- has to be told the old values; afterwards they are gone.
    #{fts_delete_from_prompts.call('1 = 1')}

    -- --------------------------------------------------------- 2. users
    CREATE TABLE users_new (
      id                INTEGER PRIMARY KEY,
      email             TEXT    NOT NULL UNIQUE COLLATE NOCASE,
      name              TEXT    NOT NULL,
      password_hash     TEXT    NOT NULL,
      must_change_pw    BOOLEAN NOT NULL DEFAULT 0,
      status            TEXT    NOT NULL DEFAULT 'active'
                                CHECK (status IN ('active','locked')),
      is_instance_admin BOOLEAN NOT NULL DEFAULT 0,
      locale            TEXT    NOT NULL DEFAULT 'de',
      last_workspace_id INTEGER REFERENCES workspaces(id) ON DELETE SET NULL,
      last_login_at     DATETIME,
      created_at        DATETIME NOT NULL,
      updated_at        DATETIME NOT NULL,
      pending_since     DATETIME
    );

    INSERT INTO users_new
      (id, email, name, password_hash, must_change_pw, status, is_instance_admin,
       locale, last_workspace_id, last_login_at, created_at, updated_at, pending_since)
      SELECT id, email, name, password_hash, must_change_pw,
             #{translate.call('status', 'aktiv' => 'active', 'gesperrt' => 'locked')},
             is_instance_admin, locale, last_workspace_id, last_login_at,
             created_at, updated_at, pending_since
        FROM users;

    DROP TABLE users;
    ALTER TABLE users_new RENAME TO users;

    -- ------------------------------------------- 3. the surviving triggers
    --
    -- Dropped **before** `prompts` goes, not after, and that order is not a
    -- matter of taste. `ALTER TABLE ... RENAME` re-parses every trigger in
    -- the schema; a trigger still naming the table that was just dropped
    -- makes the rename fail with "no such table: main.prompts". These three
    -- hang off `prompt_tags` and `tags`, so they would outlive the drop and
    -- be exactly that kind of leftover.
    --
    -- They have to be replaced in any case: they carry the normalisation rule
    -- inside them and would otherwise keep applying the old one to every tag
    -- renamed after today. All six are recreated together in step 6.
    DROP TRIGGER prompt_tags_after_insert;
    DROP TRIGGER prompt_tags_after_delete;
    DROP TRIGGER tags_after_update_name;

    -- -------------------------------------------------------- 4. prompts
    CREATE TABLE prompts_new (
      id           INTEGER PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      owner_id     INTEGER NOT NULL REFERENCES users(id),
      title        TEXT    NOT NULL,
      description  TEXT,
      body         TEXT    NOT NULL,
      visibility   TEXT    NOT NULL DEFAULT 'private',
      status       TEXT    NOT NULL DEFAULT 'draft',
      model_hint   TEXT,
      title_norm       TEXT NOT NULL DEFAULT '',
      description_norm TEXT NOT NULL DEFAULT '',
      body_norm        TEXT NOT NULL DEFAULT '',
      tags_text        TEXT NOT NULL DEFAULT '',
      created_at   DATETIME NOT NULL,
      updated_at   DATETIME NOT NULL,
      deleted_at   DATETIME,
      deleted_by   INTEGER REFERENCES users(id) ON DELETE SET NULL,
      CHECK (visibility IN ('private','workspace','instance')),
      CHECK (status     IN ('draft','active','archived'))
    );

    -- The mirror columns are recomputed rather than copied: the four new
    -- letters changed the rule, and a copied value would keep the old one for
    -- every row that already exists. Everything else is carried over as it
    -- stands, ids included — the FTS index is keyed by them.
    INSERT INTO prompts_new
      (id, workspace_id, owner_id, title, description, body, visibility, status,
       model_hint, title_norm, description_norm, body_norm, tags_text,
       created_at, updated_at, deleted_at, deleted_by)
      SELECT id, workspace_id, owner_id, title, description, body,
             #{translate.call('visibility', 'privat' => 'private', 'instanz' => 'instance')},
             #{translate.call('status', 'entwurf' => 'draft', 'aktiv' => 'active', 'archiviert' => 'archived')},
             model_hint,
             #{n.call('title')},
             #{n.call("coalesce(description,'')")},
             #{n.call('body')},
             #{tags_text.call('prompts.id')},
             created_at, updated_at, deleted_at, deleted_by
        FROM prompts;

    DROP TABLE prompts;
    ALTER TABLE prompts_new RENAME TO prompts;

    CREATE INDEX idx_prompts_ws      ON prompts (workspace_id, deleted_at);
    CREATE INDEX idx_prompts_updated ON prompts (updated_at DESC);
    CREATE INDEX idx_prompts_owner   ON prompts (owner_id);
    CREATE INDEX idx_prompts_deleted ON prompts (deleted_by) WHERE deleted_by IS NOT NULL;

    -- ----------------------------------------------- 5. prompt_variables
    CREATE TABLE prompt_variables_new (
      id            INTEGER PRIMARY KEY,
      prompt_id     INTEGER NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
      key           TEXT    NOT NULL,
      label         TEXT,
      type          TEXT    NOT NULL DEFAULT 'text',
      default_value TEXT,
      options       TEXT,
      required      BOOLEAN NOT NULL DEFAULT 0,
      position      INTEGER NOT NULL DEFAULT 0,
      UNIQUE (prompt_id, key),
      CHECK (type IN ('text','multiline','select','number'))
    );

    INSERT INTO prompt_variables_new
      (id, prompt_id, key, label, type, default_value, options, required, position)
      SELECT id, prompt_id, key, label,
             #{translate.call('type', 'mehrzeilig' => 'multiline', 'auswahl' => 'select', 'zahl' => 'number')},
             default_value, options, required, position
        FROM prompt_variables;

    DROP TABLE prompt_variables;
    ALTER TABLE prompt_variables_new RENAME TO prompt_variables;

    -- ------------------------------------------------------- 6. triggers
    --
    -- All six, last, once every table stands under its final name. The three
    -- on `prompts` went with the table, the other three were dropped in step
    -- 3. These are the definitions from 001 with the current normalisation
    -- rule; nothing about their logic changes here.
    CREATE TRIGGER prompts_after_insert AFTER INSERT ON prompts BEGIN
      UPDATE prompts SET
        title_norm       = #{n.call('NEW.title')},
        description_norm = #{n.call("coalesce(NEW.description,'')")},
        body_norm        = #{n.call('NEW.body')}
      WHERE id = NEW.id;
      #{fts_insert_from_prompts.call('id = NEW.id')}
    END;

    CREATE TRIGGER prompts_after_update AFTER UPDATE OF title, description, body ON prompts BEGIN
      #{fts_delete_from_prompts.call('id = OLD.id')}
      UPDATE prompts SET
        title_norm       = #{n.call('NEW.title')},
        description_norm = #{n.call("coalesce(NEW.description,'')")},
        body_norm        = #{n.call('NEW.body')}
      WHERE id = NEW.id;
      #{fts_insert_from_prompts.call('id = NEW.id')}
    END;

    CREATE TRIGGER prompts_after_delete AFTER DELETE ON prompts BEGIN
      INSERT INTO prompts_fts(prompts_fts, rowid, title_norm, description_norm, body_norm, tags_text)
        VALUES ('delete', OLD.id, OLD.title_norm, OLD.description_norm, OLD.body_norm, OLD.tags_text);
    END;

    CREATE TRIGGER prompt_tags_after_insert AFTER INSERT ON prompt_tags BEGIN
      #{fts_delete_from_prompts.call('id = NEW.prompt_id')}
      UPDATE prompts SET tags_text = #{tags_text.call('NEW.prompt_id')} WHERE id = NEW.prompt_id;
      #{fts_insert_from_prompts.call('id = NEW.prompt_id')}
    END;

    CREATE TRIGGER prompt_tags_after_delete AFTER DELETE ON prompt_tags BEGIN
      #{fts_delete_from_prompts.call('id = OLD.prompt_id')}
      UPDATE prompts SET tags_text = #{tags_text.call('OLD.prompt_id')} WHERE id = OLD.prompt_id;
      #{fts_insert_from_prompts.call('id = OLD.prompt_id')}
    END;

    CREATE TRIGGER tags_after_update_name AFTER UPDATE OF name ON tags BEGIN
      #{fts_delete_from_prompts.call('id IN (SELECT prompt_id FROM prompt_tags WHERE tag_id = NEW.id)')}
      UPDATE prompts SET tags_text = #{tags_text.call('prompts.id')}
        WHERE id IN (SELECT prompt_id FROM prompt_tags WHERE tag_id = NEW.id);
      #{fts_insert_from_prompts.call('id IN (SELECT prompt_id FROM prompt_tags WHERE tag_id = NEW.id)')}
    END;

    -- -------------------------------------------- 7. revision snapshots
    --
    -- **The trap this step exists for.** A revision keeps the whole prompt as
    -- JSON, old values and all. Translating the columns alone would leave
    -- `"status":"entwurf"` inside every snapshot, and FA-702 ("undo the last
    -- change") writes a snapshot straight back into the column — against a
    -- `CHECK` that no longer allows it. The failure would surface weeks
    -- later, on the first undo of an old prompt, with nothing to connect it
    -- to this migration.
    --
    -- Replaced as text, on the member including its quotes, and that is safe
    -- for a reason worth writing down: inside a JSON string every quote is
    -- escaped, so a prompt whose *body* discusses JSON and literally contains
    -- "status":"entwurf" is stored as \\"status\\":\\"entwurf\\" and cannot
    -- match. Verified with exactly that prompt (TF-460).
    --
    -- json_set would be the tidier tool but re-serialises the whole snapshot
    -- through SQLite, rewriting user content that has no business changing
    -- here. replace() touches the eight byte sequences below and nothing else.
    UPDATE prompt_revisions SET snapshot_json =
      #{[['"visibility":"privat"',  '"visibility":"private"'],
         ['"visibility":"instanz"', '"visibility":"instance"'],
         ['"status":"entwurf"',     '"status":"draft"'],
         ['"status":"aktiv"',       '"status":"active"'],
         ['"status":"archiviert"',  '"status":"archived"'],
         ['"type":"mehrzeilig"',    '"type":"multiline"'],
         ['"type":"auswahl"',       '"type":"select"'],
         ['"type":"zahl"',          '"type":"number"']].reduce('snapshot_json') do |inner, (from, to)|
           "replace(#{inner}, '#{from}', '#{to}')"
         end};

    -- ------------------------------------------------- 8. refill the index
    #{fts_insert_from_prompts.call('1 = 1')}

    -- ----------------------------------------------------- 9. the guard
    --
    -- A migration that half worked is worse than one that failed: the
    -- constraints above catch a forgotten column, but nothing would catch a
    -- forgotten snapshot. This does, and it aborts the whole run — the
    -- CHECK on a throwaway table is the only way SQL can refuse from inside
    -- a script.
    CREATE TEMP TABLE migration_005_guard (leftovers INTEGER NOT NULL CHECK (leftovers = 0));
    INSERT INTO migration_005_guard
      SELECT count(*) FROM prompt_revisions
       WHERE json_extract(snapshot_json, '$.status')     IN ('entwurf','aktiv','archiviert')
          OR json_extract(snapshot_json, '$.visibility') IN ('privat','instanz')
          OR EXISTS (SELECT 1 FROM json_each(prompt_revisions.snapshot_json, '$.variables') v
                      WHERE json_extract(v.value, '$.type') IN ('mehrzeilig','auswahl','zahl'));
    DROP TABLE migration_005_guard;

    -- And the index really matches the content table again. The variant with
    -- the argument is the one that compares the two rather than only checking
    -- the index against itself.
    INSERT INTO prompts_fts(prompts_fts, rank) VALUES('integrity-check', 1);
  SQL
end
