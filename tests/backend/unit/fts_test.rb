# frozen_string_literal: true

require_relative '../../test_helper'

# The mirror columns, the triggers that keep them, and the FTS index that
# reads them (Requirements 14.1, FA-501, R-06).
#
# This is the part of the schema where a mistake stays invisible: nothing
# errors out when the index and the content table drift apart, the search just
# stops finding things.
class FtsTest < PromptAtelier::TestCase
  def setup
    super
    @dir = migrated_dir('fts')
  end

  # --- mirror columns -----------------------------------------------------

  def test_inserting_a_prompt_fills_the_mirror_columns
    with_db(@dir) do |db|
      ws, owner = seed_owner(db)
      id = insert_prompt(db, ws, owner,
                         title: 'Größe der Übung',
                         description: 'Für Straßen',
                         body: 'Ein Text über WEISSE Flächen')

      row = db[:prompts].where(id: id).first
      assert_equal 'grosse der ubung',           row[:title_norm]
      assert_equal 'fur strassen',               row[:description_norm]
      assert_equal 'ein text uber weisse flachen', row[:body_norm]
    end
  end

  # The original columns are never touched. Whatever the search needs lives
  # beside them, and the application always reads title/description/body for
  # display. There is no way back from the normalised form and none is needed.
  def test_the_original_text_is_never_modified
    with_db(@dir) do |db|
      ws, owner = seed_owner(db)
      title = 'Die Straße hat eine Größe von 30 Fuß'
      body  = 'Grüße aus Weißenburg — ÄÖÜ bleiben ÄÖÜ'
      id = insert_prompt(db, ws, owner, title: title, body: body)

      row = db[:prompts].where(id: id).first
      assert_equal title, row[:title], 'the original title must survive verbatim'
      assert_equal body,  row[:body],  'the original body must survive verbatim'
      assert_equal 'die strasse hat eine grosse von 30 fuss', row[:title_norm]

      # And an update does not creep in either.
      db[:prompts].where(id: id).update(title: title)
      assert_equal title, db[:prompts].where(id: id).get(:title)
    end
  end

  # description is nullable; the mirror column is NOT NULL. Without the
  # coalesce in the trigger this insert would fail with a constraint error.
  def test_a_prompt_without_description_is_accepted
    with_db(@dir) do |db|
      ws, owner = seed_owner(db)
      id = insert_prompt(db, ws, owner, title: 'Ohne', body: 'Text')

      assert_equal '', db[:prompts].where(id: id).get(:description_norm)
    end
  end

  def test_updating_a_prompt_updates_the_mirror_columns_and_the_index
    with_db(@dir) do |db|
      ws, owner = seed_owner(db)
      id = insert_prompt(db, ws, owner, title: 'Blogartikel', body: 'Text')
      assert_equal [id], search(db, 'blog')

      db[:prompts].where(id: id).update(title: 'Größenrechner')

      assert_equal 'grossenrechner', db[:prompts].where(id: id).get(:title_norm)
      assert_equal [id], search(db, 'grossen')
      assert_empty search(db, 'blogartikel'), 'the old title must be gone from the index'
    end
  end

  def test_deleting_a_prompt_removes_it_from_the_index
    with_db(@dir) do |db|
      ws, owner = seed_owner(db)
      id = insert_prompt(db, ws, owner, title: 'Blogartikel', body: 'Text')

      db[:prompts].where(id: id).delete

      assert_empty search(db, 'blog')
      assert_equal 0, db.fetch('SELECT count(*) AS c FROM prompts_fts').first[:c]
    end
  end

  # --- search semantics (FA-501) ------------------------------------------

  def test_prefix_search_matches_word_beginnings
    with_db(@dir) do |db|
      ws, owner = seed_owner(db)
      id = insert_prompt(db, ws, owner, title: 'Blogartikel-Generator', body: 'Text')

      assert_equal [id], search(db, 'blog')
      assert_equal [id], search(db, 'Blogartikel')
      # Documented limitation: prefix search only matches at word starts.
      assert_empty search(db, 'artikel')
    end
  end

  def test_umlaut_spellings_all_find_the_same_prompt
    with_db(@dir) do |db|
      ws, owner = seed_owner(db)
      id = insert_prompt(db, ws, owner, title: 'Größe und Übung', body: 'für alle')

      %w[Grosse Groesse Größe Ubung Uebung Übung fur fuer für].each do |term|
        assert_equal [id], search(db, term), "#{term.inspect} must find the prompt"
      end
    end
  end

  def test_all_four_fields_are_searchable
    with_db(@dir) do |db|
      ws, owner = seed_owner(db)
      id = insert_prompt(db, ws, owner,
                         title: 'Titelwort', description: 'Beschreibungswort',
                         body: 'Textwort')
      tag = db[:tags].insert(workspace_id: ws, name: 'Schlagwort', created_at: Time.now)
      db[:prompt_tags].insert(prompt_id: id, tag_id: tag)

      %w[Titelwort Beschreibungswort Textwort Schlagwort].each do |term|
        assert_equal [id], search(db, term), "#{term} must be searchable"
      end
    end
  end

  # --- tags_text ----------------------------------------------------------

  def test_attaching_a_tag_updates_tags_text
    with_db(@dir) do |db|
      ws, owner = seed_owner(db)
      id  = insert_prompt(db, ws, owner, title: 'Eins', body: 'Text')
      tag = db[:tags].insert(workspace_id: ws, name: 'Blogartikel', created_at: Time.now)
      db[:prompt_tags].insert(prompt_id: id, tag_id: tag)

      assert_equal 'blogartikel', db[:prompts].where(id: id).get(:tags_text)
      assert_equal [id], search(db, 'blog')
    end
  end

  def test_renaming_a_tag_updates_every_affected_prompt
    with_db(@dir) do |db|
      ws, owner = seed_owner(db)
      first  = insert_prompt(db, ws, owner, title: 'Eins', body: 'Text')
      second = insert_prompt(db, ws, owner, title: 'Zwei', body: 'Text')
      tag    = db[:tags].insert(workspace_id: ws, name: 'Entwurf', created_at: Time.now)
      db[:prompt_tags].insert(prompt_id: first,  tag_id: tag)
      db[:prompt_tags].insert(prompt_id: second, tag_id: tag)

      db[:tags].where(id: tag).update(name: 'Veröffentlicht')

      assert_equal 'veroffentlicht', db[:prompts].where(id: first).get(:tags_text)
      assert_equal 'veroffentlicht', db[:prompts].where(id: second).get(:tags_text)
      assert_equal [first, second].sort, search(db, 'veroeffentlicht').sort
      assert_empty search(db, 'draft')
    end
  end

  # --- the counter-check for PRAGMA foreign_keys (Definition of Done) ------

  # Deleting a tag has to cascade into prompt_tags, which fires the trigger
  # that rewrites tags_text. Without PRAGMA foreign_keys = ON nothing
  # cascades, the trigger never runs, and tags_text keeps a tag that no longer
  # exists — findable by a search for something that is gone (R-06).
  def test_deleting_a_tag_cascades_and_updates_tags_text
    with_db(@dir) do |db|
      ws, owner = seed_owner(db)
      id  = insert_prompt(db, ws, owner, title: 'Eins', body: 'Text')
      tag = db[:tags].insert(workspace_id: ws, name: 'Blogartikel', created_at: Time.now)
      db[:prompt_tags].insert(prompt_id: id, tag_id: tag)
      assert_equal [id], search(db, 'blog')

      db[:tags].where(id: tag).delete

      assert_equal 0,  db[:prompt_tags].count,                       'assignment must be gone'
      assert_equal '', db[:prompts].where(id: id).get(:tags_text),   'tags_text must follow'
      assert_empty search(db, 'blog'),                               'index must follow'
    end
  end

  # The same case with the pragma switched off, to show it is the pragma doing
  # the work and not something else. If this ever starts passing with
  # foreign_keys OFF, the test above has stopped proving anything.
  def test_without_the_pragma_the_cascade_does_not_happen
    with_db(@dir) do |db|
      ws, owner = seed_owner(db)
      id  = insert_prompt(db, ws, owner, title: 'Eins', body: 'Text')
      tag = db[:tags].insert(workspace_id: ws, name: 'Blogartikel', created_at: Time.now)
      db[:prompt_tags].insert(prompt_id: id, tag_id: tag)

      db.run('PRAGMA foreign_keys = OFF')
      db[:tags].where(id: tag).delete

      assert_equal 1, db[:prompt_tags].count,
                   'without the pragma the assignment survives its tag — this is R-06'
      assert_equal 'blogartikel', db[:prompts].where(id: id).get(:tags_text),
                   'and tags_text keeps a tag that no longer exists'
    end
  end

  # --- maintenance commands (14.1, R-06) ----------------------------------

  # The trap that made the mirror columns necessary: rebuild reads straight
  # from the content table. Had the normalisation lived only in the index, it
  # would be silently gone after this — "Grosse" would stop finding "Größe"
  # with nothing else having changed.
  def test_rebuild_preserves_the_normalisation
    with_db(@dir) do |db|
      ws, owner = seed_owner(db)
      id = insert_prompt(db, ws, owner, title: 'Größe', body: 'Text')

      db.run("INSERT INTO prompts_fts(prompts_fts) VALUES('rebuild')")

      assert_equal [id], search(db, 'Grosse'), 'search must still match after a rebuild'
      assert_equal [id], search(db, 'Größe')
    end
  end

  def test_both_integrity_check_variants_pass
    with_db(@dir) do |db|
      ws, owner = seed_owner(db)
      id = insert_prompt(db, ws, owner, title: 'Größe', body: 'Text')
      tag = db[:tags].insert(workspace_id: ws, name: 'Blog', created_at: Time.now)
      db[:prompt_tags].insert(prompt_id: id, tag_id: tag)
      db[:prompts].where(id: id).update(title: 'Andere Größe')

      db.run("INSERT INTO prompts_fts(prompts_fts) VALUES('integrity-check')")
      # The variant with the argument compares index and content table. It is
      # the one that would fail if the normalisation lived only in the index.
      db.run("INSERT INTO prompts_fts(prompts_fts, rank) VALUES('integrity-check', 1)")
    end
  end
end
