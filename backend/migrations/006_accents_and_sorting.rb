# frozen_string_literal: true

require_relative '../services/migration'
require_relative '../services/normalization'

# The ligature the search could not find, and a list that sorted by bytes
# (AP-23).
#
# Two things an instance written in French, Italian or Spanish runs into, both
# measured before this step existed:
#
#   1. `œ` is a **ligature**. Unicode does not decompose it, so the tokenizer
#      cannot take it apart, and `Cœur` was indexed as `cœur` while `coeur`
#      became `cour` — two values that never meet. For French that is not a
#      corner case: *cœur*, *sœur*, *œuvre*, *bœuf*. The rule now spells the
#      ligature out (`œ` -> `oe`), and the digraph group folds it the rest of
#      the way, so both spellings land on `cour`.
#
#   2. The library ordered by `prompts.title`, and SQLite compares **bytes**:
#
#        ["Anfang", "Zebra", "apple", "Ábaco", "Éclair", "Œuvre"]
#
#      Capitals first, then lower case, then everything accented at the end.
#      That is wrong for German too — "Zebra" before "apple" — but with three
#      accent-rich languages it stops looking like a list at all. This step
#      adds `title_sort`, an ASCII fold of the title, and an index on it.
#
# ---------------------------------------------------------------------------
#
# **Why this one does not declare `foreign_keys: :off`, unlike 005.**
#
# 005 had to rebuild tables, because SQLite cannot alter a `CHECK` constraint —
# and `DROP TABLE` with foreign keys on fires `ON DELETE CASCADE` silently.
# Nothing here is rebuilt: a column is added, triggers are replaced, values are
# recomputed. `ALTER TABLE ... ADD COLUMN` touches no row and no constraint, so
# the relaxation that 005 needed would only widen the window for a mistake.
#
# **Why every trigger is dropped and written again.** The normalisation rule is
# compiled into them as nested `replace()` calls; a trigger created in 001 or
# recreated in 005 still carries the old table. There is no ALTER for a trigger
# body, so the five that embed the rule are replaced — and the sixth,
# `prompts_after_delete`, comes with them because it reads the mirror columns
# and belongs to the same set.
#
# **Why `title_sort` is filled by its own expression.** `sql_fold_expression`
# names 161 accented letters one by one, because SQLite cannot decompose. That
# is affordable on a title of a few dozen characters and would not be on a
# prompt body of up to 200,000 — which is exactly why the search table stays
# as it is and lets the tokenizer fold accents on both sides.
PromptAtelier::Migration.register('006_accents_and_sorting') do
  n    = PromptAtelier::Normalization.method(:sql_expression)
  fold = PromptAtelier::Normalization.method(:sql_fold_expression)

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

  <<~SQL
    -- ------------------------------------------------ 1. empty the index
    --
    -- Before the values it mirrors are recomputed. An external content table
    -- keeps what it was given; deleting afterwards would ask it to remove
    -- terms that are no longer in the columns, and the integrity check at the
    -- end would report exactly that.
    INSERT INTO prompts_fts(prompts_fts) VALUES('delete-all');

    -- --------------------------------------------- 2. the sorting column
    ALTER TABLE prompts ADD COLUMN title_sort TEXT NOT NULL DEFAULT '';

    -- ------------------------------------------- 3. the triggers of old
    DROP TRIGGER prompts_after_insert;
    DROP TRIGGER prompts_after_update;
    DROP TRIGGER prompts_after_delete;
    DROP TRIGGER prompt_tags_after_insert;
    DROP TRIGGER prompt_tags_after_delete;
    DROP TRIGGER tags_after_update_name;

    -- ------------------------------------------------ 4. recompute rows
    --
    -- Every prompt, not only the ones with a ligature in them: `title_sort`
    -- is empty on all of them, and telling "already right" from "not touched
    -- yet" would cost more than doing the lot.
    UPDATE prompts SET
      title_norm       = #{n.call('title')},
      description_norm = #{n.call("coalesce(description,'')")},
      body_norm        = #{n.call('body')},
      title_sort       = #{fold.call('title')},
      tags_text        = #{tags_text.call('prompts.id')};

    -- ------------------------------------------------------ 5. the index
    --
    -- With the workspace in front: every listing is scoped to one workspace
    -- (or to the set a person may read), so an index on the sort key alone
    -- would be read for rows that are thrown away again.
    CREATE INDEX index_prompts_workspace_title_sort ON prompts (workspace_id, title_sort);

    -- ------------------------------------------------ 6. the triggers anew
    --
    -- `prompts_after_update` is declared "OF title, description, body" so the
    -- write below cannot re-enter it: it touches only the mirror columns and
    -- `title_sort`. The design does not depend on PRAGMA recursive_triggers
    -- in either direction.
    CREATE TRIGGER prompts_after_insert AFTER INSERT ON prompts BEGIN
      UPDATE prompts SET
        title_norm       = #{n.call('NEW.title')},
        description_norm = #{n.call("coalesce(NEW.description,'')")},
        body_norm        = #{n.call('NEW.body')},
        title_sort       = #{fold.call('NEW.title')}
      WHERE id = NEW.id;
      #{fts_insert_from_prompts.call('id = NEW.id')}
    END;

    CREATE TRIGGER prompts_after_update AFTER UPDATE OF title, description, body ON prompts BEGIN
      #{fts_delete_from_prompts.call('id = OLD.id')}
      UPDATE prompts SET
        title_norm       = #{n.call('NEW.title')},
        description_norm = #{n.call("coalesce(NEW.description,'')")},
        body_norm        = #{n.call('NEW.body')},
        title_sort       = #{fold.call('NEW.title')}
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

    -- ------------------------------------------------- 7. refill the index
    #{fts_insert_from_prompts.call('1 = 1')}

    -- ------------------------------------------------------- 8. the guard
    --
    -- A migration that half worked is worse than one that failed. Two things
    -- would go unnoticed otherwise: a title whose sort key stayed empty, and
    -- a ligature still standing in a mirror column because a trigger was
    -- forgotten. A CHECK on a throwaway table is the only way SQL can refuse
    -- from inside a script.
    CREATE TEMP TABLE migration_006_guard (leftovers INTEGER NOT NULL CHECK (leftovers = 0));
    INSERT INTO migration_006_guard
      SELECT count(*) FROM prompts
       WHERE (title_sort = '' AND #{fold.call('title')} <> '')
          OR title_norm LIKE '%œ%' OR title_norm LIKE '%Œ%'
          OR body_norm  LIKE '%œ%' OR body_norm  LIKE '%Œ%';
    DROP TABLE migration_006_guard;

    -- And the index really matches the content table again. The variant with
    -- the argument is the one that compares the two rather than only checking
    -- the index against itself.
    INSERT INTO prompts_fts(prompts_fts, rank) VALUES('integrity-check', 1);
  SQL
end
