# frozen_string_literal: true

require_relative '../services/migration'
require_relative '../services/normalization'

# Initial schema — Requirements 14.1.
#
# The table definitions follow that chapter literally, so the document and the
# database can be compared line by line. Only the triggers are generated,
# because they embed the normalisation rule from FA-501 and that rule must
# exist exactly once (see services/normalization.rb).
PromptAtelier::Migration.register('001_initial') do
  n = PromptAtelier::Normalization.method(:sql_expression)

  # tags_text for one prompt: the normalised names of its tags, space
  # separated. Order is not defined and does not need to be — the FTS
  # tokenizer splits on whitespace anyway.
  tags_text = lambda do |prompt_id|
    <<~SQL.strip
      (SELECT coalesce(group_concat(#{n.call('t.name')}, ' '), '')
         FROM prompt_tags pt JOIN tags t ON t.id = pt.tag_id
        WHERE pt.prompt_id = #{prompt_id})
    SQL
  end

  # Removes a prompt's row from the FTS index. External content tables need
  # the *previously indexed* values here, not the new ones — otherwise the
  # index keeps orphaned terms and integrity-check reports corruption.
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

  <<~SQL
    -- ---------------------------------------------------------------- users
    CREATE TABLE users (
      id                INTEGER PRIMARY KEY,
      email             TEXT    NOT NULL UNIQUE COLLATE NOCASE,
      name              TEXT    NOT NULL,
      password_hash     TEXT    NOT NULL,
      must_change_pw    BOOLEAN NOT NULL DEFAULT 0,
      status            TEXT    NOT NULL DEFAULT 'aktiv'
                                CHECK (status IN ('aktiv','gesperrt')),
      is_instance_admin BOOLEAN NOT NULL DEFAULT 0,
      locale            TEXT    NOT NULL DEFAULT 'de',
      last_workspace_id INTEGER REFERENCES workspaces(id) ON DELETE SET NULL,
      last_login_at     DATETIME,
      created_at        DATETIME NOT NULL,
      updated_at        DATETIME NOT NULL
    );

    -- ----------------------------------------------------------- workspaces
    CREATE TABLE workspaces (
      id          INTEGER PRIMARY KEY,
      name        TEXT    NOT NULL,
      slug        TEXT    NOT NULL UNIQUE,
      is_personal BOOLEAN NOT NULL DEFAULT 0,
      created_at  DATETIME NOT NULL,
      updated_at  DATETIME NOT NULL
    );

    -- ---------------------------------------------------------- memberships
    CREATE TABLE memberships (
      id           INTEGER PRIMARY KEY,
      user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      role         TEXT    NOT NULL,
      created_at   DATETIME NOT NULL,
      UNIQUE (user_id, workspace_id),
      CHECK (role IN ('owner','admin','editor','viewer'))
    );
    CREATE INDEX idx_memberships_ws ON memberships (workspace_id);

    -- -------------------------------------------------------------- prompts
    CREATE TABLE prompts (
      id           INTEGER PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      owner_id     INTEGER NOT NULL REFERENCES users(id),
      title        TEXT    NOT NULL,
      description  TEXT,
      body         TEXT    NOT NULL,
      visibility   TEXT    NOT NULL DEFAULT 'privat',
      status       TEXT    NOT NULL DEFAULT 'entwurf',
      model_hint   TEXT,
      -- Normalised mirror columns, used by the search only (FA-501).
      -- Maintained by trigger. The FTS index reads THESE columns, not the
      -- originals — see the note in Requirements 14.1 on rebuild.
      title_norm       TEXT NOT NULL DEFAULT '',
      description_norm TEXT NOT NULL DEFAULT '',
      body_norm        TEXT NOT NULL DEFAULT '',
      tags_text        TEXT NOT NULL DEFAULT '',
      created_at   DATETIME NOT NULL,
      updated_at   DATETIME NOT NULL,
      deleted_at   DATETIME,
      deleted_by   INTEGER REFERENCES users(id) ON DELETE SET NULL,
      CHECK (visibility IN ('privat','workspace','instanz')),
      CHECK (status     IN ('entwurf','aktiv','archiviert'))
    );
    CREATE INDEX idx_prompts_ws      ON prompts (workspace_id, deleted_at);
    CREATE INDEX idx_prompts_updated ON prompts (updated_at DESC);
    CREATE INDEX idx_prompts_owner   ON prompts (owner_id);
    CREATE INDEX idx_prompts_deleted ON prompts (deleted_by) WHERE deleted_by IS NOT NULL;

    -- ----------------------------------------------------- prompt_variables
    CREATE TABLE prompt_variables (
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
      CHECK (type IN ('text','mehrzeilig','auswahl','zahl'))
    );

    -- ----------------------------------------------------------------- tags
    CREATE TABLE tags (
      id           INTEGER PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      name         TEXT    NOT NULL,
      created_at   DATETIME NOT NULL,
      UNIQUE (workspace_id, name)
    );

    CREATE TABLE prompt_tags (
      prompt_id INTEGER NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
      tag_id    INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
      PRIMARY KEY (prompt_id, tag_id)
    );
    CREATE INDEX idx_prompt_tags_tag ON prompt_tags (tag_id);

    -- ------------------------------------------------------------- keywords
    CREATE TABLE keywords (
      id           INTEGER PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      name         TEXT    NOT NULL,
      description  TEXT,
      text         TEXT    NOT NULL,
      position     TEXT    NOT NULL DEFAULT 'append',
      sort_order   INTEGER NOT NULL DEFAULT 100,
      created_at   DATETIME NOT NULL,
      updated_at   DATETIME NOT NULL,
      UNIQUE (workspace_id, name),
      CHECK (position IN ('prepend','append'))
    );

    CREATE TABLE prompt_keywords (
      prompt_id  INTEGER NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
      keyword_id INTEGER NOT NULL REFERENCES keywords(id) ON DELETE CASCADE,
      PRIMARY KEY (prompt_id, keyword_id)
    );
    CREATE INDEX idx_prompt_keywords_kw ON prompt_keywords (keyword_id);

    -- ------------------------------------------------------------ favorites
    CREATE TABLE favorites (
      user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      prompt_id  INTEGER NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
      created_at DATETIME NOT NULL,
      PRIMARY KEY (user_id, prompt_id)
    );

    -- ---------------------------------------------------- prompt_revisions
    CREATE TABLE prompt_revisions (
      id            INTEGER PRIMARY KEY,
      prompt_id     INTEGER NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
      snapshot_json TEXT    NOT NULL,
      comment       TEXT,
      changed_by    INTEGER REFERENCES users(id),
      created_at    DATETIME NOT NULL
    );
    CREATE INDEX idx_revisions_prompt ON prompt_revisions (prompt_id, created_at DESC);

    -- ------------------------------------------------------------- sessions
    CREATE TABLE sessions (
      id             INTEGER PRIMARY KEY,
      user_id        INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      token_hash     TEXT    NOT NULL UNIQUE,
      ip             TEXT,
      user_agent     TEXT,
      last_seen_at   DATETIME NOT NULL,
      expires_at     DATETIME NOT NULL,
      created_at     DATETIME NOT NULL
    );
    CREATE INDEX idx_sessions_user ON sessions (user_id);

    -- ----------------------------------------------------------- audit_logs
    CREATE TABLE audit_logs (
      id          INTEGER PRIMARY KEY,
      actor_id    INTEGER REFERENCES users(id) ON DELETE SET NULL,
      actor_name  TEXT,
      action      TEXT    NOT NULL,
      target_type TEXT,
      target_id   INTEGER,
      meta_json   TEXT,
      ip          TEXT,
      created_at  DATETIME NOT NULL
    );
    CREATE INDEX idx_audit_created ON audit_logs (created_at DESC);

    -- ------------------------------------------------------- login_attempts
    CREATE TABLE login_attempts (
      id           INTEGER PRIMARY KEY,
      email        TEXT,
      ip           TEXT,
      attempted_at DATETIME NOT NULL
    );
    CREATE INDEX idx_attempts_email ON login_attempts (email, attempted_at DESC);
    CREATE INDEX idx_attempts_ip    ON login_attempts (ip, attempted_at DESC);

    -- ---------------------------------------------------- schema_migrations
    CREATE TABLE schema_migrations (
      version    TEXT PRIMARY KEY,
      applied_at DATETIME NOT NULL
    );

    -- ----------------------------------------------------------- prompts_fts
    CREATE VIRTUAL TABLE prompts_fts USING fts5 (
      title_norm, description_norm, body_norm, tags_text,
      content='prompts', content_rowid='id',
      tokenize='unicode61 remove_diacritics 2',
      prefix='2 3 4'
    );

    -- --------------------------------------------------------------- triggers
    --
    -- Each trigger that changes a mirror column writes it back with a plain
    -- UPDATE. That UPDATE cannot re-enter the trigger below it, because the
    -- UPDATE trigger is declared "OF title, description, body" and the write
    -- touches only the *_norm columns. The design therefore does not depend on
    -- PRAGMA recursive_triggers in either direction.

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

    -- Also fires when a tag is deleted, because ON DELETE CASCADE removes the
    -- rows here. That is exactly why PRAGMA foreign_keys = ON is mandatory:
    -- without it nothing cascades, this trigger never runs, and tags_text
    -- keeps a tag that no longer exists.
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
  SQL
end
