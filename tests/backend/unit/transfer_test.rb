# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'services/transfer'
require 'services/catalog'
require 'services/search'

# TF-340 to TF-346 at the level where the rules live — the endpoints repeat
# them over HTTP in transfer_api_test.rb.
#
# The promise under all of it is FA-804: a JSON export read back into an empty
# instance yields the same content. Everything else in this file exists because
# that promise has edges — a Markdown file that deliberately loses things, a
# title that already exists in the target, a file that turns out to be unusable
# halfway through.
class TransferTest < PromptAtelier::TestCase
  T = PromptAtelier::Transfer
  P = PromptAtelier::Prompts
  C = PromptAtelier::Catalog

  def setup
    super
    @dir = migrated_dir('transfer')
  end

  def with_instance
    with_db(@dir) do |db|
      ids = PromptAtelier::Fixture.build(db)
      yield db, ids
    end
  end

  # A workspace with something worth exporting: two variables, one of them a
  # selection with options, tags, and a default keyword. An export of a bare
  # prompt would pass any round-trip test and prove nothing.
  def furnish(db, ids)
    marketing = ids[:workspaces][:marketing]
    keyword = C.create_keyword(db, marketing, {
      'name' => 'formal', 'description' => 'Sachlicher Ton',
      'text' => 'Schreibe sachlich.', 'position' => 'append', 'sort_order' => 10
    })

    id = P.create(db, workspace_id: marketing, owner_id: ids[:users][:sabine], attributes: {
      'title' => 'Reisebericht', 'description' => 'Fasst eine Reise zusammen',
      'body' => "Schreibe über {{ziel}} für {{gruppe}}.",
      'visibility' => 'workspace', 'status' => 'active', 'model_hint' => 'Claude Opus',
      'tags' => %w[reise text],
      'variables' => [
        { 'key' => 'ziel', 'label' => 'Reiseziel', 'type' => 'text', 'required' => true, 'position' => 0 },
        { 'key' => 'gruppe', 'label' => 'Gruppe', 'type' => 'select',
          'default_value' => 'Familien', 'options' => %w[Familien Paare Alleinreisende],
          'required' => false, 'position' => 1 }
      ],
      'keyword_ids' => [keyword]
    })

    [marketing, id]
  end

  # The prompt of TF-545, in the workspace the export reads from.
  def create_accented(db, ids, workspace)
    id = P.create(db, workspace_id: workspace, owner_id: ids[:users][:sabine], attributes: {
                    'title' => ACCENTED['title'], 'description' => ACCENTED['description'],
                    'body' => ACCENTED['body'],
                    'visibility' => 'workspace', 'status' => 'active',
                    'tags' => %w[français italiano],
                    'variables' => [
                      { 'key' => 'prénom', 'label' => 'Prénom', 'type' => 'text',
                        'required' => true, 'position' => 0 },
                      { 'key' => 'città', 'label' => 'Città', 'type' => 'text',
                        'required' => false, 'position' => 1 }
                    ]
                  })

    db[:prompts][id: id]
  end

  # --- TF-340 and FA-804: the round trip ------------------------------------

  # The core promise, and it is checked field by field rather than by comparing
  # two exports: two exports of the same bug are equal, and that is exactly the
  # comparison that would not notice.
  def test_tf340_a_json_export_read_into_an_empty_workspace_returns_the_same_content
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      package = T.export(db, workspace_id: marketing)

      target = PromptAtelier::Workspaces.create(db, name: 'Ziel', owner_id: ids[:users][:sabine])
      T.import(db, workspace_id: target, owner_id: ids[:users][:sabine],
                   package: T.parse(JSON.generate(package)))

      copy = db[:prompts].first(workspace_id: target, title: 'Reisebericht')
      original = db[:prompts].first(workspace_id: marketing, title: 'Reisebericht')

      %i[title description body visibility status model_hint].each do |field|
        assert_equal original[field], copy[field], field.to_s
      end
      assert_equal P.tag_names(db, original[:id]), P.tag_names(db, copy[:id])
      assert_equal %w[formal], P.default_keywords(db, copy[:id]).map { |entry| entry[:name] }

      # The timestamps too — that is what separates FA-804 from "close enough".
      assert_equal original[:created_at].to_i, copy[:created_at].to_i
      assert_equal original[:updated_at].to_i, copy[:updated_at].to_i
    end
  end

  def test_tf340_the_variables_survive_with_their_metadata
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      package = T.export(db, workspace_id: marketing)
      target = PromptAtelier::Workspaces.create(db, name: 'Ziel', owner_id: ids[:users][:sabine])

      T.import(db, workspace_id: target, owner_id: ids[:users][:sabine],
                   package: T.parse(JSON.generate(package)))

      copy = db[:prompts].first(workspace_id: target, title: 'Reisebericht')
      variables = db[:prompt_variables].where(prompt_id: copy[:id]).order(:position).all

      assert_equal %w[ziel gruppe], variables.map { |entry| entry[:key] }
      assert_equal 'select', variables.last[:type]
      assert_equal 'Familien', variables.last[:default_value]
      # The file carries options as a list, the column as one per line. The
      # conversion happens in exactly one place, and this is the check that it
      # happens in both directions.
      assert_equal %w[Familien Paare Alleinreisende], variables.last[:options].split("\n")
      assert variables.first[:required]
    end
  end

  # 17.1 says `options` is a **list**. The round trip alone cannot see this:
  # the importer takes `Array(entry['options'])`, and for a single string that
  # yields a one-element list which is stored back as the same text — the trip
  # is invariant while the file is wrong. Found by a mutation probe; the file
  # itself has to be looked at.
  def test_tf340_the_file_carries_options_as_a_list_not_as_the_stored_text
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      package = T.export(db, workspace_id: marketing)

      entry = package['prompts'].find { |prompt| prompt['title'] == 'Reisebericht' }
      assert_kind_of Array, entry['variables'].last['options']
      assert_equal %w[Familien Paare Alleinreisende], entry['variables'].last['options']
      # And a variable without options carries null, not an empty string —
      # anything else would make a text field look like an empty selection.
      assert_nil entry['variables'].first['options']
    end
  end

  # The keyword definitions travel, not just their names — otherwise a target
  # instance would have a prompt pointing at a keyword nobody can see (FA-804).
  def test_tf340_the_keyword_definitions_travel_with_the_file
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      target = PromptAtelier::Workspaces.create(db, name: 'Ziel', owner_id: ids[:users][:sabine])

      T.import(db, workspace_id: target, owner_id: ids[:users][:sabine],
                   package: T.parse(JSON.generate(T.export(db, workspace_id: marketing))))

      keyword = db[:keywords].first(workspace_id: target, name: 'formal')
      refute_nil keyword
      assert_equal 'Schreibe sachlich.', keyword[:text]
      assert_equal 'append', keyword[:position]
      assert_equal 10, keyword[:sort_order]
    end
  end

  # --- TF-346: the scope follows ownership ----------------------------------

  # An editor may read more than belongs to him. If the export covered
  # everything readable, the ◐ of the permission matrix would mean nothing
  # (FA-801).
  def test_tf346_an_export_of_ones_own_holds_only_ones_own_and_the_keywords_they_use
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      C.create_keyword(db, marketing, { 'name' => 'unbenutzt', 'text' => 'Steht nur herum.',
                                        'position' => 'prepend', 'sort_order' => 1 })
      mine = P.create(db, workspace_id: marketing, owner_id: ids[:users][:martin],
                          attributes: { 'title' => 'Martins Eigener', 'body' => 'Text.' })

      package = T.export(db, workspace_id: marketing, owner_id: ids[:users][:martin])

      titles = package['prompts'].map { |entry| entry['title'] }
      assert_includes titles, 'Martins Eigener'
      refute_includes titles, 'Reisebericht', 'a foreign prompt is readable, not exportable'
      assert_empty package['keywords'], 'his prompt uses none, so none travel'

      # The counter-check: as soon as one of his prompts uses a keyword, it is
      # in the file — the file has to stand on its own (FA-801).
      keyword = db[:keywords].first(workspace_id: marketing, name: 'formal')
      P.assign_keywords(db, mine, marketing, [keyword[:id]])
      again = T.export(db, workspace_id: marketing, owner_id: ids[:users][:martin])
      assert_equal %w[formal], again['keywords'].map { |entry| entry['name'] }
    end
  end

  def test_a_full_export_carries_the_whole_catalogue_even_the_unused
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      C.create_keyword(db, marketing, { 'name' => 'unbenutzt', 'text' => 'Steht nur herum.',
                                        'position' => 'prepend', 'sort_order' => 1 })

      names = T.export(db, workspace_id: marketing)['keywords'].map { |entry| entry['name'] }
      # Ordered as the catalogue orders them (position, then sort_order, then
      # name), so a file reads the way the screen does.
      assert_equal %w[formal unbenutzt], names, 'a workspace export rebuilds the workspace'
    end
  end

  def test_a_deleted_prompt_is_not_exported
    with_instance do |db, ids|
      marketing, id = furnish(db, ids)
      P.move_to_trash(db, db[:prompts][id: id], actor_id: ids[:users][:sabine])

      titles = T.export(db, workspace_id: marketing)['prompts'].map { |entry| entry['title'] }
      refute_includes titles, 'Reisebericht'
    end
  end
  # --- TF-341 and FA-802: collisions ----------------------------------------

  # The comparison key is the title inside the target workspace. What makes it
  # a rule rather than an equality check is what it ignores: case and
  # surrounding spaces (TF-341c).
  def test_tf341c_a_title_collides_regardless_of_case_and_padding
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      package = T.parse(JSON.generate(one_prompt('  REISEBERICHT ')))

      entry = T.preview(db, workspace_id: marketing, package: package)['prompts'].first
      assert_equal 'collision', entry['state']
      assert_equal 'Reisebericht', entry['candidates'].first['title']
    end
  end

  def test_tf341_a_single_collision_offers_all_three_choices
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      plan = T.preview(db, workspace_id: marketing, package: T.parse(JSON.generate(one_prompt('Reisebericht'))))

      assert_equal 1, plan['collision_count']
      assert_equal 0, plan['new_count']
      assert_equal %w[skip copy overwrite], plan['prompts'].first['decisions']
    end
  end

  # TF-341b. The lage arises by itself, because FA-204 makes titles like
  # "… (Kopie)" — and with two candidates there is no way to say which one
  # "overwrite" means. The preview names them with their change dates so the
  # decision can be made by hand.
  def test_tf341b_several_candidates_take_overwrite_off_the_table
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      P.create(db, workspace_id: marketing, owner_id: ids[:users][:sabine],
                   attributes: { 'title' => 'reisebericht', 'body' => 'Zweiter mit gleichem Titel.' })

      entry = T.preview(db, workspace_id: marketing,
                            package: T.parse(JSON.generate(one_prompt('Reisebericht'))))['prompts'].first

      assert_equal 'ambiguous', entry['state']
      assert_equal %w[skip copy], entry['decisions']
      assert_equal 2, entry['candidates'].size
      assert(entry['candidates'].all? { |candidate| candidate['updated_at'] })
    end
  end

  def test_a_collision_without_a_decision_is_skipped
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      before = db[:prompts].where(workspace_id: marketing).count

      report = T.import(db, workspace_id: marketing, owner_id: ids[:users][:sabine],
                            package: T.parse(JSON.generate(one_prompt('Reisebericht'))))

      assert_equal ['Reisebericht'], report['skipped']
      assert_equal before, db[:prompts].where(workspace_id: marketing).count
      assert_equal 'Schreibe über {{ziel}} für {{gruppe}}.',
                   db[:prompts].first(workspace_id: marketing, title: 'Reisebericht')[:body]
    end
  end

  def test_the_choice_copy_leaves_the_original_alone
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      T.import(db, workspace_id: marketing, owner_id: ids[:users][:sabine],
                   package: T.parse(JSON.generate(one_prompt('Reisebericht'))),
                   decisions: { '0' => 'copy' })

      assert_equal 'Schreibe über {{ziel}} für {{gruppe}}.',
                   db[:prompts].first(workspace_id: marketing, title: 'Reisebericht')[:body]
      assert_equal 'Ein ganz anderer Text.',
                   db[:prompts].first(workspace_id: marketing, title: 'Reisebericht (Kopie)')[:body]
    end
  end

  # TF-341d. Leitprinzip 2: an import must never replace something beyond
  # recall. The revision is written by Prompts.update, which is why overwriting
  # goes through it rather than around it.
  def test_tf341d_overwriting_writes_a_revision_and_undo_restores_the_state_before_the_import
    with_instance do |db, ids|
      marketing, id = furnish(db, ids)

      T.import(db, workspace_id: marketing, owner_id: ids[:users][:sabine],
                   package: T.parse(JSON.generate(one_prompt('Reisebericht'))),
                   decisions: { '0' => 'overwrite' })

      assert_equal 'Ein ganz anderer Text.', db[:prompts][id: id][:body]
      assert_equal 1, db[:prompt_revisions].where(prompt_id: id).count

      P.undo(db, db[:prompts][id: id], actor_id: ids[:users][:sabine])
      assert_equal 'Schreibe über {{ziel}} für {{gruppe}}.', db[:prompts][id: id][:body]
    end
  end

  # A decision the preview did not offer is refused, not quietly reinterpreted.
  # Silently turning it into "skip" would answer a question nobody asked; doing
  # it anyway would pick a victim at random.
  def test_an_overwrite_that_was_never_offered_is_refused
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      P.create(db, workspace_id: marketing, owner_id: ids[:users][:sabine],
                   attributes: { 'title' => 'reisebericht', 'body' => 'Zweiter mit gleichem Titel.' })

      refused = assert_raises(T::Refused) do
        T.import(db, workspace_id: marketing, owner_id: ids[:users][:sabine],
                     package: T.parse(JSON.generate(one_prompt('Reisebericht'))),
                     decisions: { '0' => 'overwrite' })
      end
      assert_equal :decision_not_available, refused.code
    end
  end

  # --- TF-342, TF-343: what a file may be wrong about -----------------------

  def test_tf342_a_damaged_file_is_refused_with_a_reason_and_writes_nothing
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      before = db[:prompts].where(workspace_id: marketing).count

      refused = assert_raises(T::Refused) { T.parse('{ "format": "promptatelier-export", ') }
      assert_equal :malformed_json, refused.code
      refute_empty refused.detail[:reason].to_s, 'the reason names what is wrong with the file'

      assert_equal before, db[:prompts].where(workspace_id: marketing).count
    end
  end

  # `do ... end` would bind to `assert_equal` instead of `assert_raises`, and
  # the failure reads "assert_raises requires a block" rather than anything
  # about the code under test. Named locals instead.
  def test_a_file_that_is_not_an_export_is_told_apart_from_a_damaged_one
    foreign = assert_raises(T::Refused) { T.parse('{"hello": "world"}') }
    empty = assert_raises(T::Refused) do
      T.parse(JSON.generate({ 'format' => T::FORMAT, 'version' => 1, 'prompts' => [] }))
    end
    newer = assert_raises(T::Refused) do
      T.parse(JSON.generate({ 'format' => T::FORMAT, 'version' => 99, 'prompts' => [{}] }))
    end

    assert_equal :not_an_export, foreign.code
    assert_equal :no_content, empty.code
    assert_equal :unsupported_version, newer.code
  end

  # The counter-case to the one above, and the reason the refusal was narrowed:
  # a workspace holding keywords and no prompts exports to a file with an empty
  # `prompts` list, and refusing that meant refusing a file this application
  # had written itself.
  def test_a_file_with_keywords_and_no_prompts_is_read
    package = T.parse(JSON.generate({
      'format' => T::FORMAT, 'version' => 2, 'prompts' => [],
      'keywords' => [{ 'name' => 'formal', 'text' => 'Bleiben Sie sachlich.',
                       'position' => 'prepend', 'sort_order' => 10 }]
    }))

    assert_empty package['prompts']
    assert_equal ['formal'], package['keywords'].map { |entry| entry['name'] }
  end

  # An export is somebody's backup. The product was renamed to Prompt Atelier
  # after files had already been written under the old marker, and a rename
  # must not make yesterday's file unreadable.
  #
  # The counter-check matters as much as the case: **written** is only the
  # current marker, or the old name would live on in every new file.
  def test_a_file_written_under_the_former_name_is_still_read
    package = T.parse(JSON.generate({
      'format' => 'promptstorage-export', 'version' => 1,
      'prompts' => [{ 'title' => 'Alt', 'body' => 'Text' }]
    }))

    assert_equal 1, package['prompts'].size
  end

  def test_a_new_file_carries_the_current_name_only
    with_instance do |db, ids|
      package = T.export(db, workspace_id: ids[:workspaces][:marketing])

      assert_equal 'promptatelier-export', package['format']
      refute_includes T::FORMER_FORMATS, package['format']
    end
  end

  def test_an_entry_without_a_title_or_body_names_its_position_in_the_file
    refused = assert_raises(T::Refused) do
      T.parse(JSON.generate({ 'format' => T::FORMAT, 'version' => 1,
                              'prompts' => [{ 'title' => 'Gut', 'body' => 'Text.' }, { 'body' => 'Ohne Titel.' }] }))
    end
    assert_equal :prompt_without_title, refused.code
    assert_equal 1, refused.detail[:index], 'a file with 51 entries needs to say which one'
  end

  # TF-343: a file from a newer version stays usable. What was not understood
  # is **named** — dropping it in silence would let somebody believe the import
  # was complete.
  def test_tf343_unknown_fields_are_reported_rather_than_dropped_in_silence
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      source = one_prompt('Ganz neu')
      source['prompts'][0]['zukunftsfeld'] = 'unbekannt'
      source['prompts'][0]['variables'] = [{ 'key' => 'ziel', 'label' => 'Ziel', 'noch_eins' => true }]
      source['prompts'][0]['body'] = 'Text mit {{ziel}}.'

      report = T.import(db, workspace_id: marketing, owner_id: ids[:users][:sabine],
                            package: T.parse(JSON.generate(source)))

      assert_equal %w[noch_eins zukunftsfeld], report['unknown_fields']
      assert_equal ['Ganz neu'], report['created'], 'and the import still happens'
    end
  end

  # SEC-12 and TF-412: a file that fails partway leaves nothing behind. The
  # second entry has 51 variables, which is refused after the row already
  # exists — exactly the shape that left half a prompt behind before AP-08a.
  def test_tf412_a_file_that_fails_halfway_leaves_nothing_behind
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      before = db[:prompts].where(workspace_id: marketing).count

      broken = one_prompt('Erster Neuer')
      broken['prompts'] << { 'title' => 'Zweiter Neuer',
                             'body' => (1..51).map { |n| "{{v#{n}}}" }.join(' ') }

      assert_raises(P::Refused) do
        T.import(db, workspace_id: marketing, owner_id: ids[:users][:sabine],
                     package: T.parse(JSON.generate(broken)))
      end

      assert_equal before, db[:prompts].where(workspace_id: marketing).count
      assert_nil db[:prompts].first(workspace_id: marketing, title: 'Erster Neuer'),
                 'the entry that had already gone in must be gone again'
    end
  end

  # The file name follows the slug rule of 14.2, which is the normalisation of
  # FA-501 — the one that turns ß into ss. Decided here and not in the browser:
  # a second implementation of that rule is a second place for it to be wrong,
  # and the first draft in JavaScript turned "Größe" into "gro-e".
  def test_the_export_file_is_named_after_the_workspace_and_the_day
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      db[:workspaces].where(id: marketing).update(name: 'Größe & Maß')
      package = T.export(db, workspace_id: marketing, now: Time.new(2026, 8, 2, 10, 15, 0))

      assert_equal 'grosse-mass-2026-08-02.json', T.export_filename(package)
    end
  end

  def test_a_workspace_name_that_slugs_to_nothing_still_yields_a_name
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      db[:workspaces].where(id: marketing).update(name: '///')
      package = T.export(db, workspace_id: marketing, now: Time.new(2026, 8, 2, 10, 15, 0))

      assert_equal 'promptatelier-2026-08-02.json', T.export_filename(package)
    end
  end

  # --- TF-345 and TF-345b: Markdown, and what it loses on purpose -----------

  # FA-803 names nine things that survive. Checked one by one, because the
  # value of this format is exactly that list — and the value of the next test
  # is exactly what is missing from it.
  def test_tf345_a_markdown_round_trip_keeps_what_fa803_promises
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      file = T.export_markdown(db, workspace_id: marketing).find { |entry| entry['name'] == 'reisebericht.md' }
      refute_nil file, 'the file is named after the title, by the slug rule of 14.2'

      target = PromptAtelier::Workspaces.create(db, name: 'Ziel', owner_id: ids[:users][:sabine])
      C.create_keyword(db, target, { 'name' => 'formal', 'text' => 'Anders formuliert.',
                                     'position' => 'prepend', 'sort_order' => 5 })
      T.import(db, workspace_id: target, owner_id: ids[:users][:sabine],
                   package: T.parse(file['content']))

      copy = db[:prompts].first(workspace_id: target, title: 'Reisebericht')
      original = db[:prompts].first(workspace_id: marketing, title: 'Reisebericht')

      %i[title description body visibility status model_hint].each do |field|
        assert_equal original[field], copy[field], field.to_s
      end
      assert_equal P.tag_names(db, original[:id]), P.tag_names(db, copy[:id])
      assert_equal %w[formal], P.default_keywords(db, copy[:id]).map { |entry| entry[:name] }

      variables = db[:prompt_variables].where(prompt_id: copy[:id]).order(:position).all
      assert_equal %w[ziel gruppe], variables.map { |entry| entry[:key] }
      assert_equal %w[Familien Paare Alleinreisende], variables.last[:options].split("\n")
    end
  end

  # --- TF-545: the characters, through both formats (AP-23) -----------------

  # A prompt written the way somebody in Paris, Rome or Madrid writes one, out
  # and back in again — through JSON **and** through Markdown.
  #
  # Every one of these characters is here because something in this
  # application used to treat it wrongly: the ligature the index could not
  # find, the accents an identifier turned into hyphens, the inverted question
  # mark, and a variable name that was no variable at all and said nothing
  # about it. What this case adds to those is the plainest question of the
  # lot: does the text come back **byte for byte**.
  #
  # The file name is checked with it. It is derived from the title by the slug
  # rule (14.2), and that rule is the one AP-23 split in two — an export whose
  # files were called `citt-e-pasi.md` would be found by nobody.
  ACCENTED = {
    'title' => 'Cœur de métier — Año & Città',
    'description' => '¿Qué tal? Grüße aus Kopenhagen: rød grød med fløde.',
    'body' => "Bonjour {{prénom}}, ¡bienvenido!\n\n" \
              "Au cœur de l'œuvre : « la sœur ainée ». Prezzo in €, città: {{città}}.\n" \
              'Straße, Größe, Łódź, ÄÖÜ, ĉ ĝ ħ.'
  }.freeze

  def test_tf545_a_json_round_trip_keeps_every_character
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      original = create_accented(db, ids, marketing)

      target = PromptAtelier::Workspaces.create(db, name: 'Ziel', owner_id: ids[:users][:sabine])
      T.import(db, workspace_id: target, owner_id: ids[:users][:sabine],
                   package: T.parse(JSON.generate(T.export(db, workspace_id: marketing))))

      copy = db[:prompts].first(workspace_id: target, title: ACCENTED['title'])
      refute_nil copy, 'the accented title has to arrive as the title'

      ACCENTED.each { |field, value| assert_equal value, copy[field.to_sym], field }
      assert_equal %w[prénom città],
                   db[:prompt_variables].where(prompt_id: copy[:id]).order(:position).select_map(:key),
                   'and the variable names are content, not identifiers of ours'

      assert_equal original[:body], copy[:body], 'byte for byte'
    end
  end

  def test_tf545_a_markdown_round_trip_keeps_every_character_and_names_the_file_readably
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      create_accented(db, ids, marketing)

      files = T.export_markdown(db, workspace_id: marketing)
      file = files.find { |entry| entry['content'].include?('Cœur de métier') }
      refute_nil file

      assert_equal 'coeur-de-metier-ano-citta.md', file['name'],
                   'the ligature is spelled out and the accents come off — no hyphen soup'

      target = PromptAtelier::Workspaces.create(db, name: 'Ziel', owner_id: ids[:users][:sabine])
      T.import(db, workspace_id: target, owner_id: ids[:users][:sabine],
                   package: T.parse(file['content']))

      copy = db[:prompts].first(workspace_id: target, title: ACCENTED['title'])
      refute_nil copy, 'the head of the Markdown file has to survive its own quoting'
      ACCENTED.each { |field, value| assert_equal value, copy[field.to_sym], field }
    end
  end

  # And the search finds it afterwards — the round trip is only half the
  # promise if the copy cannot be found again.
  def test_tf545_the_imported_copy_is_findable_by_either_spelling
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      create_accented(db, ids, marketing)

      %w[coeur cœur soeur metier].each do |term|
        found = PromptAtelier::Search.find(db, term: term, workspace_ids: [marketing],
                                               visible_for: ids[:users][:sabine])
        assert_includes found.map { |row| row[:title] }, ACCENTED['title'], term
      end
    end
  end

  # TF-345b, the counter-check to the one above. Markdown is a filing format,
  # not a removal van (17.2) — and a test that only showed what survives would
  # let somebody use it for a migration and lose the rest.
  def test_tf345b_markdown_gives_new_timestamps_and_does_not_create_keywords
    with_instance do |db, ids|
      marketing, id = furnish(db, ids)
      # Dated back on purpose. Exporting and importing within the same second
      # makes "the timestamp is new" indistinguishable from "the timestamp
      # travelled" — the first draft asserted exactly that and compared a
      # number with itself.
      long_ago = Time.now - (400 * 24 * 60 * 60)
      db[:prompts].where(id: id).update(created_at: long_ago, updated_at: long_ago)

      file = T.export_markdown(db, workspace_id: marketing).find { |entry| entry['name'] == 'reisebericht.md' }
      refute_match(/created_at/, file['content'], 'the file does not even carry the field')
      target = PromptAtelier::Workspaces.create(db, name: 'Ziel', owner_id: ids[:users][:sabine])

      report = T.import(db, workspace_id: target, owner_id: ids[:users][:sabine],
                            package: T.parse(file['content']))

      copy = db[:prompts].first(workspace_id: target, title: 'Reisebericht')
      refute_equal long_ago.to_i, copy[:created_at].to_i, 'no timestamps travel in Markdown (17.2)'

      # And the counter-check that this is a property of Markdown and not of
      # the importer: the same prompt through JSON keeps its date.
      through_json = PromptAtelier::Workspaces.create(db, name: 'Ziel-JSON', owner_id: ids[:users][:sabine])
      T.import(db, workspace_id: through_json, owner_id: ids[:users][:sabine],
                   package: T.parse(JSON.generate(T.export(db, workspace_id: marketing))))
      assert_equal long_ago.to_i,
                   db[:prompts].first(workspace_id: through_json, title: 'Reisebericht')[:created_at].to_i

      # The keyword is named in the frontmatter and defined nowhere, so it is
      # reported and **not** invented — the same rule as duplicating into a
      # workspace that does not have it (FA-204).
      assert_equal %w[formal], report['keywords_missing']
      assert_nil db[:keywords].first(workspace_id: target, name: 'formal')
      assert_empty P.default_keywords(db, copy[:id])
    end
  end

  def test_two_prompts_whose_titles_slug_alike_get_separate_files
    with_instance do |db, ids|
      marketing, = furnish(db, ids)
      P.create(db, workspace_id: marketing, owner_id: ids[:users][:sabine],
                   attributes: { 'title' => 'Reise-Bericht!', 'body' => 'Anderer Text.' })

      names = T.export_markdown(db, workspace_id: marketing).map { |entry| entry['name'] }
      assert_equal names.uniq.size, names.size, 'or one file would overwrite the other on disk'
    end
  end

  def test_a_markdown_file_without_a_head_is_refused_by_name
    assert_equal :no_frontmatter, assert_raises(T::Refused) { T.parse("Nur Text, kein Kopf.\n") }.code
  end

  # --- TF-347 to TF-347f: keyword collisions on import (FA-802, FA-804) ---
  #
  # The case that used to vanish. A keyword whose name is already taken here
  # was in neither list of the preview and in neither list of the report, and
  # the definition the file carried was dropped without a word. Every test
  # below exists because that silence was indistinguishable from success.

  # A file made of keywords alone, read back into an empty workspace. This is
  # FA-804 for a workspace that holds no prompts, and it could not be met at
  # all while a promptless file was refused.
  # TF-347
  def test_a_keyword_only_export_survives_the_round_trip
    with_instance do |db, ids|
      # Two workspaces of this test's own, so the fixture's stock cannot make
      # the file non-empty behind its back.
      source = empty_workspace(db, 'Nur Keywords')
      target = empty_workspace(db, 'Ziel')
      C.create_keyword(db, source, { 'name' => 'formal', 'description' => 'Sachlicher Ton',
                                     'text' => 'Schreibe sachlich.', 'position' => 'append',
                                     'sort_order' => 10 })
      file = T.export(db, workspace_id: source)

      assert_empty file['prompts'], 'the workspace has no prompts, so the file has none'
      assert_equal 1, file['keywords'].size, 'a full export carries every keyword of the workspace'

      report = T.import(db, workspace_id: target, owner_id: ids[:users][:sabine],
                            package: T.parse(JSON.generate(file)))

      assert_equal ['formal'], report['keywords_created']
      written = db[:keywords][workspace_id: target, name: 'formal']
      assert_equal 'Schreibe sachlich.', written[:text]
      assert_equal 'append', written[:position]
      assert_equal 10, written[:sort_order]
    end
  end

  # TF-347b
  def test_a_name_already_taken_here_is_named_in_the_preview
    with_instance do |db, ids|
      workspace = ids[:workspaces][:marketing]
      C.create_keyword(db, workspace, { 'name' => 'formal', 'description' => 'Sachlicher Ton',
                                        'text' => 'Schreibe sachlich.', 'position' => 'append',
                                        'sort_order' => 10 })
      plan = T.preview(db, workspace_id: workspace, package: incoming_formal('Sei knapp.'))

      assert_empty plan['keywords']['to_create'], 'it exists here, so nothing is created'
      assert_empty plan['keywords']['missing'], 'the file provides it, so nothing is missing'

      conflict = plan['keywords']['conflicts'].fetch(0)
      assert_equal 'formal', conflict['name']
      assert_equal 0, conflict['index']
      assert_equal %w[skip overwrite], conflict['decisions'],
                   'a copy would carry a name no imported prompt refers to'
      # Both texts, because there are no revisions to fall back on.
      assert_equal 'Schreibe sachlich.', conflict['existing']['text']
      assert_equal 'Sei knapp.', conflict['incoming']['text']
      refute conflict['identical']
    end
  end

  # TF-347b
  def test_an_unchanged_keyword_is_marked_as_such
    with_instance do |db, ids|
      workspace = ids[:workspaces][:marketing]
      C.create_keyword(db, workspace, { 'name' => 'formal', 'description' => 'Sachlicher Ton',
                                        'text' => 'Schreibe sachlich.', 'position' => 'append',
                                        'sort_order' => 10 })
      plan = T.preview(db, workspace_id: workspace,
                           package: incoming_formal('Schreibe sachlich.'))

      assert plan['keywords']['conflicts'].fetch(0)['identical'],
             'forty unchanged keywords must not read as forty decisions'
    end
  end

  # TF-347c
  def test_without_a_decision_the_existing_keyword_stands_and_is_reported
    with_instance do |db, ids|
      workspace = ids[:workspaces][:marketing]
      C.create_keyword(db, workspace, { 'name' => 'formal', 'description' => 'Sachlicher Ton',
                                        'text' => 'Schreibe sachlich.', 'position' => 'append',
                                        'sort_order' => 10 })
      report = T.import(db, workspace_id: workspace, owner_id: ids[:users][:sabine],
                            package: incoming_formal('Sei knapp.'))

      assert_equal ['formal'], report['keywords_skipped'], 'skipping is only safe if it is said'
      assert_empty report['keywords_created']
      assert_equal 'Schreibe sachlich.', db[:keywords][workspace_id: workspace, name: 'formal'][:text]
    end
  end

  # TF-347d
  def test_overwrite_replaces_the_definition_and_keeps_the_row
    with_instance do |db, ids|
      workspace = ids[:workspaces][:marketing]
      before = C.create_keyword(db, workspace, { 'name' => 'formal', 'description' => 'Sachlicher Ton',
                                                 'text' => 'Schreibe sachlich.', 'position' => 'append',
                                                 'sort_order' => 10 })
      report = T.import(db, workspace_id: workspace, owner_id: ids[:users][:sabine],
                            package: incoming_formal('Sei knapp.'),
                            keyword_decisions: { '0' => 'overwrite' })

      assert_equal ['formal'], report['keywords_overwritten']
      row = db[:keywords][workspace_id: workspace, name: 'formal']
      assert_equal 'Sei knapp.', row[:text]
      # The same row, so every prompt already pointing at it now renders the
      # new definition without anything having to be relinked.
      assert_equal before, row[:id]
      assert_equal 1, db[:keywords].where(workspace_id: workspace, name: 'formal').count
    end
  end

  # An overwritten keyword is reached through `prompt_keywords`, so the prompts
  # that used it have to render the new text. Checking the column alone would
  # pass over a relinking that silently went wrong.
  # TF-347d
  def test_a_prompt_already_using_the_keyword_gets_the_new_definition
    with_instance do |db, ids|
      workspace = ids[:workspaces][:marketing]
      keyword = C.create_keyword(db, workspace, { 'name' => 'formal', 'description' => 'Sachlicher Ton',
                                                  'text' => 'Schreibe sachlich.', 'position' => 'append',
                                                  'sort_order' => 10 })
      prompt = P.create(db, workspace_id: workspace, owner_id: ids[:users][:sabine], attributes: {
                          'title' => 'Bericht', 'body' => 'Fasse zusammen.',
                          'keyword_ids' => [keyword]
                        })

      T.import(db, workspace_id: workspace, owner_id: ids[:users][:sabine],
                   package: incoming_formal('Sei knapp.'),
                   keyword_decisions: { '0' => 'overwrite' })

      assert_equal [keyword], db[:prompt_keywords].where(prompt_id: prompt).select_map(:keyword_id)
      assert_equal 'Sei knapp.', db[:keywords][id: keyword][:text]
    end
  end

  # The same rule the prompts follow: a decision the preview did not offer is
  # refused, not reinterpreted. "copy" is the one that is never offered.
  # TF-347e
  def test_a_decision_the_preview_does_not_offer_is_refused
    with_instance do |db, ids|
      workspace = ids[:workspaces][:marketing]
      C.create_keyword(db, workspace, { 'name' => 'formal', 'description' => 'Sachlicher Ton',
                                        'text' => 'Schreibe sachlich.', 'position' => 'append',
                                        'sort_order' => 10 })
      refused = assert_raises(T::Refused) do
        T.import(db, workspace_id: workspace, owner_id: ids[:users][:sabine],
                     package: incoming_formal('Sei knapp.'),
                     keyword_decisions: { '0' => 'copy' })
      end

      assert_equal :decision_not_available, refused.code
      assert_equal 'Schreibe sachlich.', db[:keywords][workspace_id: workspace, name: 'formal'][:text],
                   'the refusal happens inside the transaction, so nothing is left behind'
    end
  end

  # A file that carries neither is still refused, because there is nothing to
  # preview and nothing to write.
  # TF-347f
  def test_a_file_with_neither_prompts_nor_keywords_is_refused
    refused = assert_raises(T::Refused) do
      T.parse(JSON.generate({ 'format' => T::FORMAT, 'version' => 2,
                              'prompts' => [], 'keywords' => [] }))
    end

    assert_equal :no_content, refused.code
  end

  def empty_workspace(db, name)
    now = Time.now
    db[:workspaces].insert(name: name, slug: T.slug_for(name), created_at: now, updated_at: now)
  end

  def incoming_formal(text)
    T.parse(JSON.generate({
      'format' => T::FORMAT, 'version' => 2, 'prompts' => [],
      'keywords' => [{ 'name' => 'formal', 'description' => 'Sachlicher Ton',
                       'text' => text, 'position' => 'append', 'sort_order' => 10 }]
    }))
  end
  private

  # A minimal file carrying one prompt under the given title. Deliberately a
  # different body from the fixture, so an overwrite is visible.
  def one_prompt(title)
    {
      'format' => T::FORMAT, 'version' => 1,
      'prompts' => [{ 'title' => title, 'body' => 'Ein ganz anderer Text.' }]
    }
  end
end
