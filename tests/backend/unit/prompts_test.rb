# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'services/prompts'

# TF-301 to TF-309b, TF-330 to TF-337 and the edge cases TF-402, TF-403,
# TF-414, TF-428 — at the level where the rules live. The endpoints repeat
# them over HTTP in prompt_api_test.rb.
class PromptsTest < PromptAtelier::TestCase
  P = PromptAtelier::Prompts

  def setup
    super
    @dir = migrated_dir('prompts')
  end

  def with_instance
    with_db(@dir) do |db|
      ids = PromptAtelier::Fixture.build(db)
      yield db, ids
    end
  end

  def create(db, ids, body:, **rest)
    attributes = { 'title' => 'Titel', 'body' => body }.merge(rest.transform_keys(&:to_s))
    P.create(db, workspace_id: ids[:workspaces][:marketing],
                 owner_id: ids[:users][:sabine], attributes: attributes)
  end

  def variables(db, id)
    db[:prompt_variables].where(prompt_id: id).order(:position).all
  end

  # --- TF-301 to TF-303: variables follow the text --------------------------

  def test_tf301_a_variable_in_the_text_becomes_a_metadata_record
    with_instance do |db, ids|
      id = create(db, ids, body: 'Schreibe über {{thema}}.')

      entry = variables(db, id).first
      assert_equal 'thema', entry[:key]
      assert_equal 'text', entry[:type]
      refute entry[:required]
    end
  end

  def test_tf302_removing_a_variable_from_the_text_removes_its_record
    with_instance do |db, ids|
      id = create(db, ids, body: 'Über {{thema}} für {{alt}}.',
                           variables: [{ 'key' => 'thema', 'label' => 'Das Thema', 'required' => true },
                                       { 'key' => 'alt', 'label' => 'Alt' }])
      prompt = db[:prompts][id: id]

      P.update(db, prompt, attributes: { 'body' => 'Über {{thema}}.',
                                         'variables' => [{ 'key' => 'thema', 'label' => 'Das Thema', 'required' => true }] },
                           actor_id: ids[:users][:sabine])

      remaining = variables(db, id)
      assert_equal %w[thema], remaining.map { |row| row[:key] }
      assert_equal 'Das Thema', remaining.first[:label], 'the settings of the survivors stay'
      assert remaining.first[:required]
    end
  end

  def test_tf303_a_choice_variable_keeps_exactly_its_options
    with_instance do |db, ids|
      id = create(db, ids, body: 'Für {{zielgruppe}}.',
                           variables: [{ 'key' => 'zielgruppe', 'type' => 'select',
                                         'options' => %w[Einsteiger Fortgeschrittene Profis],
                                         'default_value' => 'Einsteiger' }])

      entry = variables(db, id).first
      assert_equal 'select', entry[:type]
      assert_equal %w[Einsteiger Fortgeschrittene Profis], entry[:options].split("\n")
      assert_equal 'Einsteiger', entry[:default_value]
    end
  end

  def test_tf304_a_prompt_without_variables_has_none_recorded
    with_instance do |db, ids|
      id = create(db, ids, body: 'Ein Text ganz ohne Platzhalter.')

      assert_empty variables(db, id)
    end
  end

  # FA-301: an escaped reference is literal text, not a variable.
  def test_an_escaped_reference_does_not_become_a_variable
    with_instance do |db, ids|
      id = create(db, ids, body: 'Literal: \\{{keinevariable}} und echt: {{thema}}.')

      assert_equal %w[thema], variables(db, id).map { |row| row[:key] }
    end
  end

  # --- TF-402, TF-403: the text decides, not the client ---------------------

  def test_tf402_a_variable_without_metadata_is_created_with_defaults
    with_instance do |db, ids|
      id = create(db, ids, body: 'Über {{neu}}.', variables: [])

      entry = variables(db, id).first
      assert_equal 'neu', entry[:key]
      assert_equal 'text', entry[:type]
    end
  end

  def test_tf403_metadata_without_an_occurrence_is_discarded
    with_instance do |db, ids|
      id = create(db, ids, body: 'Ganz ohne Platzhalter.',
                           variables: [{ 'key' => 'geist', 'label' => 'Gespenst' }])

      assert_empty variables(db, id), 'a record the client sent but the text does not use'
    end
  end

  # --- TF-452, FA-302: the order of the fields belongs to the author --------
  #
  # Found when AP-12 began. FA-302 lists the order among the editable things,
  # and the position that arrived with the metadata was thrown away — every
  # variable took the place its occurrence in the text gave it. Nothing said
  # so, because the screen that edits metadata did not exist yet. The same
  # shape as the missing marking in 8.3: a requirement whose only user was a
  # screen still to be written.

  def test_a_position_from_the_metadata_decides_the_order
    with_instance do |db, ids|
      id = create(db, ids, body: '{{eins}} {{zwei}} {{drei}}', variables: [
                    { 'key' => 'eins', 'position' => 2 },
                    { 'key' => 'zwei', 'position' => 0 },
                    { 'key' => 'drei', 'position' => 1 }
                  ])

      assert_equal %w[zwei drei eins], variables(db, id).map { |row| row[:key] }
    end
  end

  # And the counter-check: with no entry the order of the text stands.
  def test_without_a_position_the_text_decides
    with_instance do |db, ids|
      id = create(db, ids, body: '{{eins}} {{zwei}} {{drei}}', variables: [])

      assert_equal %w[eins zwei drei], variables(db, id).map { |row| row[:key] }
    end
  end

  # Three keys, not two: with two, "reversed" is the same as "sorted", and a
  # mutation that simply turns the order around would come through.
  def test_a_variable_typed_in_later_falls_in_where_the_text_puts_it
    with_instance do |db, ids|
      id = create(db, ids, body: '{{eins}} {{zwei}} {{neu}}', variables: [
                    { 'key' => 'eins', 'position' => 1 },
                    { 'key' => 'zwei', 'position' => 0 }
                  ])

      # `neu` stands third in the text and brings no entry with it — it lands
      # where the text has it, behind the two that were named.
      assert_equal %w[zwei eins neu], variables(db, id).map { |row| row[:key] }
    end
  end

  # Whatever arrives: what is stored is a gapless run from 0. Otherwise the
  # sorting would decide on display over values nobody assigned — and a second
  # save would shift the order again.
  def test_the_stored_positions_are_gapless_from_zero
    with_instance do |db, ids|
      id = create(db, ids, body: '{{a}} {{b}} {{c}}', variables: [
                    { 'key' => 'a', 'position' => 90 },
                    { 'key' => 'b', 'position' => 5 },
                    { 'key' => 'c', 'position' => 40 }
                  ])

      assert_equal [0, 1, 2], variables(db, id).map { |row| row[:position] }
      assert_equal %w[b c a], variables(db, id).map { |row| row[:key] }
    end
  end

  # Variables all claiming the same place: the text decides.
  #
  # **What this case achieves and what it does not.** Ruby guarantees no
  # stability for `sort` and `sort_by` — this Ruby preserves the input order on
  # equal keys anyway, checked for every count possible here. A mutation probe
  # that removes the second sort key therefore comes through, and no result
  # could tell the two versions apart.
  #
  # The second key stays all the same: it turns an accident of the
  # implementation into a promise. This case holds that promise fast, so that a
  # Ruby version or another implementation that really does reorder is caught
  # here rather than at the user. Twelve variables, not two: with two elements
  # even an unstable sort practically never swaps.
  def test_variables_claiming_one_place_are_decided_by_the_text
    with_instance do |db, ids|
      keys = (1..12).map { |n| "v#{n}" }
      id = create(db, ids, body: keys.map { |key| "{{#{key}}}" }.join(' '),
                           variables: keys.map { |key| { 'key' => key, 'position' => 0 } })

      assert_equal keys, variables(db, id).map { |row| row[:key] }
    end
  end

  # --- TF-305 to TF-305c, TF-428: the limits of chapter 14.3 ----------------

  def test_tf305_more_than_fifty_variables_are_refused
    with_instance do |db, ids|
      body = (1..51).map { |n| "{{v#{n}}}" }.join(' ')

      error = assert_raises(P::Refused) { create(db, ids, body: body) }
      assert_equal :too_many_variables, error.code
      assert_equal 50, error.fields[:limit]
      assert_equal 51, error.fields[:actual]
    end
  end

  def test_exactly_fifty_variables_are_still_accepted
    with_instance do |db, ids|
      id = create(db, ids, body: (1..50).map { |n| "{{v#{n}}}" }.join(' '))

      assert_equal 50, variables(db, id).size
    end
  end

  # TF-549 — the two rows of the 14.3 table that had no case of their own.
  #
  # Measured, not suspected: deleting `if wanted.size > MAX_TAGS` left the
  # whole suite green. The limits work — a probe refused every one of them —
  # but nothing was watching them, and a limit nobody watches is a limit that
  # survives until the first refactoring.
  def test_tf549_more_than_twenty_tags_are_refused
    with_instance do |db, ids|
      error = assert_raises(P::Refused) do
        create(db, ids, body: 'x', tags: (1..21).map { |n| "schlagwort#{n}" })
      end

      assert_equal :too_many_tags, error.code
      assert_equal 20, error.fields[:limit]
      assert_equal 21, error.fields[:actual]
    end
  end

  def test_tf549_exactly_twenty_tags_are_still_accepted
    with_instance do |db, ids|
      id = create(db, ids, body: 'x', tags: (1..20).map { |n| "schlagwort#{n}" })

      assert_equal 20, db[:prompt_tags].where(prompt_id: id).count, 'the limit is 20, not 19'
    end
  end

  def test_tf549_more_than_a_hundred_options_on_one_variable_are_refused
    with_instance do |db, ids|
      error = assert_raises(P::Refused) do
        create(db, ids, body: '{{v}}',
                        variables: [{ 'key' => 'v', 'kind' => 'select',
                                      'options' => (1..101).map(&:to_s) }])
      end

      assert_equal :too_many_options, error.code
      assert_equal 100, error.fields[:limit]
    end
  end

  def test_tf549_exactly_a_hundred_options_are_still_accepted
    with_instance do |db, ids|
      id = create(db, ids, body: '{{v}}',
                           variables: [{ 'key' => 'v', 'kind' => 'select',
                                         'options' => (1..100).map(&:to_s) }])

      refute_nil id, 'the limit is 100, not 99'
    end
  end

  # TF-428: the message names the limit and the actual value. "Too long" on
  # its own leaves the user counting characters by hand.
  def test_tf428_an_exceeded_field_limit_names_the_limit_and_the_actual_value
    with_instance do |db, ids|
      error = assert_raises(P::Refused) { create(db, ids, body: 'x', title: 'T' * 201) }

      assert_equal :validation_failed, error.code
      assert_equal({ limit: 200, minimum: 1, actual: 201 }, error.fields[:title])
    end
  end

  def test_every_offending_field_is_reported_at_once
    with_instance do |db, ids|
      error = assert_raises(P::Refused) do
        create(db, ids, body: '', title: 'T' * 201, description: 'd' * 1001, model_hint: 'm' * 201)
      end

      assert_equal %i[title description body model_hint].sort, error.fields.keys.sort
    end
  end

  def test_unknown_visibility_or_status_is_refused
    with_instance do |db, ids|
      error = assert_raises(P::Refused) { create(db, ids, body: 'x', visibility: 'oeffentlich') }

      assert_includes error.fields[:visibility][:allowed], 'workspace'
    end
  end

  def test_tf305b_more_than_twenty_keywords_in_one_render_are_refused
    with_instance do |db, ids|
      id = create(db, ids, body: 'Text.')
      keywords = Array.new(21) { |n| { name: "k#{n}", text: 'x', position: 'append', sort_order: n } }

      error = assert_raises(P::Refused) do
        P.render(db, db[:prompts][id: id], values: {}, keywords: keywords)
      end
      assert_equal :too_many_keywords, error.code
      assert_equal 20, error.fields[:limit]
    end
  end

  def test_tf305c_a_rendered_result_beyond_two_hundred_thousand_characters_is_refused
    with_instance do |db, ids|
      id = create(db, ids, body: 'A' * 100_000)
      keywords = Array.new(20) { |n| { name: "k#{n}", text: 'B' * 5_000, position: 'append', sort_order: n } }

      error = assert_raises(P::Refused) do
        P.render(db, db[:prompts][id: id], values: {}, keywords: keywords)
      end
      assert_equal :rendered_too_long, error.code
      assert_operator error.fields[:actual], :>, 200_000
    end
  end

  # --- TF-331 to TF-334: revisions and undo ---------------------------------

  def test_tf331_a_save_without_a_change_creates_no_revision
    with_instance do |db, ids|
      id = create(db, ids, body: 'Unverändert.')
      prompt = db[:prompts][id: id]

      changed = P.update(db, prompt, attributes: { 'title' => 'Titel', 'body' => 'Unverändert.' },
                                     actor_id: ids[:users][:sabine])

      refute changed
      assert_equal 0, db[:prompt_revisions].where(prompt_id: id).count
    end
  end

  def test_tf332_a_real_change_creates_exactly_one_revision_with_the_previous_state
    with_instance do |db, ids|
      id = create(db, ids, body: 'Erster Stand.', description: 'Beschreibung')
      P.update(db, db[:prompts][id: id], attributes: { 'body' => 'Zweiter Stand.' },
                                         actor_id: ids[:users][:sabine])

      revisions = db[:prompt_revisions].where(prompt_id: id).all
      assert_equal 1, revisions.size

      snapshot = JSON.parse(revisions.first[:snapshot_json])
      assert_equal 'Erster Stand.', snapshot['body']
      assert_equal 'Beschreibung', snapshot['description'], 'the whole previous state, not only the changed field'
      assert_equal ids[:users][:sabine], revisions.first[:changed_by]
    end
  end

  def test_a_changed_variable_alone_already_counts_as_a_change
    with_instance do |db, ids|
      id = create(db, ids, body: 'Über {{thema}}.')

      changed = P.update(db, db[:prompts][id: id],
                         attributes: { 'variables' => [{ 'key' => 'thema', 'required' => true }] },
                         actor_id: ids[:users][:sabine])

      assert changed, 'the prompt columns are untouched but the variable is not'
      assert_equal 1, db[:prompt_revisions].where(prompt_id: id).count
    end
  end

  def test_tf333_undo_restores_the_previous_state
    with_instance do |db, ids|
      id = create(db, ids, body: 'Erster Stand.')
      P.update(db, db[:prompts][id: id], attributes: { 'body' => 'Zweiter Stand.' },
                                         actor_id: ids[:users][:sabine])

      P.undo(db, db[:prompts][id: id], actor_id: ids[:users][:sabine])

      assert_equal 'Erster Stand.', db[:prompts][id: id][:body]
    end
  end

  # TF-334: undoing is itself undoable. Without keeping the overwritten state
  # a mistaken undo would be a one-way door.
  def test_tf334_undo_twice_returns_to_the_state_before_the_first_undo
    with_instance do |db, ids|
      id = create(db, ids, body: 'Erster Stand.')
      P.update(db, db[:prompts][id: id], attributes: { 'body' => 'Zweiter Stand.' },
                                         actor_id: ids[:users][:sabine])

      P.undo(db, db[:prompts][id: id], actor_id: ids[:users][:sabine])
      assert_equal 'Erster Stand.', db[:prompts][id: id][:body]

      P.undo(db, db[:prompts][id: id], actor_id: ids[:users][:sabine])
      assert_equal 'Zweiter Stand.', db[:prompts][id: id][:body]
    end
  end

  def test_undo_without_a_revision_is_refused
    with_instance do |db, ids|
      id = create(db, ids, body: 'Nur ein Stand.')

      assert_equal :no_revision,
                   assert_raises(P::Refused) { P.undo(db, db[:prompts][id: id], actor_id: ids[:users][:sabine]) }.code
    end
  end

  def test_undo_also_restores_the_variables_and_tags_of_that_state
    with_instance do |db, ids|
      id = create(db, ids, body: 'Über {{alt}}.', tags: %w[seo])
      P.update(db, db[:prompts][id: id], attributes: { 'body' => 'Über {{neu}}.', 'tags' => %w[content] },
                                         actor_id: ids[:users][:sabine])

      P.undo(db, db[:prompts][id: id], actor_id: ids[:users][:sabine])

      assert_equal %w[alt], variables(db, id).map { |row| row[:key] }
      assert_equal %w[seo], P.tag_names(db, id)
    end
  end

  # TF-414: two people saving the same prompt. The later state wins, and the
  # overwritten one is reachable through undo — which is exactly what the
  # revision is for.
  def test_tf414_the_later_save_wins_and_the_earlier_stays_reachable
    with_instance do |db, ids|
      id = create(db, ids, body: 'Gemeinsamer Stand.')
      prompt = db[:prompts][id: id]

      P.update(db, prompt, attributes: { 'body' => 'Martins Fassung.' }, actor_id: ids[:users][:martin])
      P.update(db, db[:prompts][id: id], attributes: { 'body' => 'Annas Fassung.' }, actor_id: ids[:users][:anna])

      assert_equal 'Annas Fassung.', db[:prompts][id: id][:body]

      P.undo(db, db[:prompts][id: id], actor_id: ids[:users][:anna])
      assert_equal 'Martins Fassung.', db[:prompts][id: id][:body]
    end
  end

  # --- TF-335 to TF-337: the trash ------------------------------------------

  def test_tf335_an_editor_sees_only_what_they_deleted_or_own
    with_instance do |db, ids|
      marketing = ids[:workspaces][:marketing]
      own     = create(db, ids, body: 'Von Martin.')
      db[:prompts].where(id: own).update(owner_id: ids[:users][:martin])
      foreign = create(db, ids, body: 'Von Sabine.')

      P.move_to_trash(db, db[:prompts][id: own], actor_id: ids[:users][:martin])
      P.move_to_trash(db, db[:prompts][id: foreign], actor_id: ids[:users][:sabine])

      visible = P.trash_for(db, marketing, ids[:users][:martin], 'editor').map { |row| row[:id] }
      assert_includes visible, own
      refute_includes visible, foreign
    end
  end

  def test_tf336_an_administrator_sees_the_whole_trash_of_the_workspace
    with_instance do |db, ids|
      marketing = ids[:workspaces][:marketing]
      first  = create(db, ids, body: 'Eins.')
      second = create(db, ids, body: 'Zwei.')
      P.move_to_trash(db, db[:prompts][id: first], actor_id: ids[:users][:martin])
      P.move_to_trash(db, db[:prompts][id: second], actor_id: ids[:users][:sabine])

      visible = P.trash_for(db, marketing, ids[:users][:anna], 'admin').map { |row| row[:id] }
      assert_includes visible, first
      assert_includes visible, second
    end
  end

  # The half that is easy to forget: an admin deletes a foreign prompt, and its
  # owner has to find it again even though they did not delete it.
  def test_an_editor_finds_their_own_prompt_that_someone_else_deleted
    with_instance do |db, ids|
      id = create(db, ids, body: 'Martins Prompt.')
      db[:prompts].where(id: id).update(owner_id: ids[:users][:martin])
      P.move_to_trash(db, db[:prompts][id: id], actor_id: ids[:users][:anna])

      visible = P.trash_for(db, ids[:workspaces][:marketing], ids[:users][:martin], 'editor').map { |row| row[:id] }
      assert_includes visible, id
    end
  end

  def test_tf337_restoring_brings_back_visibility_and_status_unchanged
    with_instance do |db, ids|
      id = create(db, ids, body: 'Text.', visibility: 'workspace', status: 'archived')
      P.move_to_trash(db, db[:prompts][id: id], actor_id: ids[:users][:sabine])

      P.restore(db, db[:prompts][id: id])

      restored = db[:prompts][id: id]
      assert_nil restored[:deleted_at]
      assert_nil restored[:deleted_by]
      assert_equal 'workspace', restored[:visibility]
      assert_equal 'archived', restored[:status]
    end
  end

  def test_purging_removes_the_prompt_and_its_revisions
    with_instance do |db, ids|
      id = create(db, ids, body: 'Erster Stand.')
      P.update(db, db[:prompts][id: id], attributes: { 'body' => 'Zweiter.' }, actor_id: ids[:users][:sabine])
      P.move_to_trash(db, db[:prompts][id: id], actor_id: ids[:users][:sabine])

      P.purge(db, db[:prompts][id: id])

      assert_equal 0, db[:prompts].where(id: id).count
      assert_equal 0, db[:prompt_revisions].where(prompt_id: id).count
    end
  end

  # --- TF-306: duplicating across a workspace boundary ----------------------

  def test_tf306_a_copy_into_a_foreign_workspace_resolves_tags_and_reports_keywords
    with_instance do |db, ids|
      marketing = ids[:workspaces][:marketing]
      target    = ids[:workspaces][:personal_joerg]

      source_id = create(db, ids, body: 'Über {{thema}} für {{zielgruppe}}.',
                                  tags: %w[seo content blog], visibility: 'instance')
      formal = db[:keywords].insert(workspace_id: marketing, name: 'formal', text: 'Förmlich.',
                                    position: 'append', sort_order: 10,
                                    created_at: Time.now, updated_at: Time.now)
      db[:prompt_keywords].insert(prompt_id: source_id, keyword_id: formal)

      copy_id, dropped = P.duplicate(db, db[:prompts][id: source_id],
                                     target_workspace_id: target, actor_id: ids[:users][:joerg])

      copy = db[:prompts][id: copy_id]
      assert_equal 'Titel (Kopie)', copy[:title]
      assert_equal 'private', copy[:visibility]
      assert_equal 'draft', copy[:status]
      assert_equal ids[:users][:joerg], copy[:owner_id]
      assert_equal target, copy[:workspace_id]

      assert_equal %w[thema zielgruppe], variables(db, copy_id).map { |row| row[:key] }
      assert_equal %w[blog content seo], P.tag_names(db, copy_id), 'missing tags are created in the target'
      assert_equal 3, db[:tags].where(workspace_id: target).count

      assert_empty P.keyword_names(db, copy_id), 'formal does not exist there'
      assert_equal %w[formal], dropped, 'and it is named rather than silently dropped'
    end
  end

  def test_a_copy_carries_no_revisions_and_no_favourites
    with_instance do |db, ids|
      source_id = create(db, ids, body: 'Erster Stand.')
      P.update(db, db[:prompts][id: source_id], attributes: { 'body' => 'Zweiter.' }, actor_id: ids[:users][:sabine])
      db[:favorites].insert(user_id: ids[:users][:sabine], prompt_id: source_id, created_at: Time.now)

      copy_id, = P.duplicate(db, db[:prompts][id: source_id],
                             target_workspace_id: ids[:workspaces][:personal_sabine],
                             actor_id: ids[:users][:sabine])

      assert_equal 0, db[:prompt_revisions].where(prompt_id: copy_id).count
      assert_equal 0, db[:favorites].where(prompt_id: copy_id).count
    end
  end

  # --- TF-307, TF-423: moving -----------------------------------------------

  def test_tf307_moving_resets_a_workspace_visibility_to_private
    with_instance do |db, ids|
      id = create(db, ids, body: 'Über {{thema}}.', visibility: 'workspace')
      db[:prompts].where(id: id).update(owner_id: ids[:users][:martin])
      db[:favorites].insert(user_id: ids[:users][:martin], prompt_id: id, created_at: Time.now)
      P.update(db, db[:prompts][id: id], attributes: { 'body' => 'Über {{thema}} neu.' },
                                         actor_id: ids[:users][:martin])

      result = P.move(db, db[:prompts][id: id], target_workspace_id: ids[:workspaces][:personal_martin])

      assert_equal ids[:workspaces][:personal_martin], result[:prompt][:workspace_id]
      assert_equal 'private', result[:prompt][:visibility]
      assert result[:visibility_reset], 'the user has to be told'
      assert_equal ids[:users][:martin], result[:prompt][:owner_id], 'owner unchanged'
      assert_equal 1, db[:prompt_revisions].where(prompt_id: id).count, 'revisions unchanged'
      assert_equal 1, db[:favorites].where(prompt_id: id).count, 'favourites unchanged'
      assert_equal %w[thema], variables(db, id).map { |row| row[:key] }
    end
  end

  def test_moving_leaves_nothing_behind_in_the_source_workspace
    with_instance do |db, ids|
      id = create(db, ids, body: 'Text.', visibility: 'workspace')

      P.move(db, db[:prompts][id: id], target_workspace_id: ids[:workspaces][:personal_sabine])

      assert_equal 0, db[:prompts].where(workspace_id: ids[:workspaces][:marketing], id: id).count
    end
  end

  # An instance-wide prompt is already readable by everyone, so moving it
  # widens nothing and the visibility stays as the owner set it.
  def test_moving_an_instance_wide_prompt_leaves_its_visibility_alone
    with_instance do |db, ids|
      id = create(db, ids, body: 'Text.', visibility: 'instance')

      result = P.move(db, db[:prompts][id: id], target_workspace_id: ids[:workspaces][:personal_sabine])

      assert_equal 'instance', result[:prompt][:visibility]
      refute result[:visibility_reset]
    end
  end

  def test_tf424_moving_resolves_tags_and_reports_lost_keywords
    with_instance do |db, ids|
      marketing = ids[:workspaces][:marketing]
      id = create(db, ids, body: 'Text.', tags: %w[seo], visibility: 'workspace')
      formal = db[:keywords].insert(workspace_id: marketing, name: 'formal', text: 'x',
                                    position: 'append', sort_order: 10,
                                    created_at: Time.now, updated_at: Time.now)
      db[:prompt_keywords].insert(prompt_id: id, keyword_id: formal)

      result = P.move(db, db[:prompts][id: id], target_workspace_id: ids[:workspaces][:personal_sabine])

      assert_equal %w[seo], P.tag_names(db, id), 'the tag is created in the target'
      assert_equal ids[:workspaces][:personal_sabine],
                   db[:tags].first(name: 'seo', workspace_id: ids[:workspaces][:personal_sabine])[:workspace_id]
      assert_equal %w[formal], result[:dropped_keywords]
      assert_empty P.keyword_names(db, id)
    end
  end

  # --- permitted keywords when rendering (FA-604) ---------------------------

  def test_a_keyword_attached_to_the_prompt_is_allowed_without_membership
    with_instance do |db, ids|
      marketing = ids[:workspaces][:marketing]
      id = create(db, ids, body: 'Text.', visibility: 'instance')
      formal = db[:keywords].insert(workspace_id: marketing, name: 'formal', text: 'x',
                                    position: 'append', sort_order: 10,
                                    created_at: Time.now, updated_at: Time.now)
      db[:prompt_keywords].insert(prompt_id: id, keyword_id: formal)

      allowed = P.permitted_keywords(db, db[:prompts][id: id], [formal], [])
      assert_equal [formal], allowed.map { |row| row[:id] }
    end
  end

  # Otherwise this endpoint would hand out a foreign workspace's keywords one
  # id at a time, which is the very thing FA-604 rules out.
  def test_a_foreign_keyword_that_is_not_attached_is_refused
    with_instance do |db, ids|
      marketing = ids[:workspaces][:marketing]
      id = create(db, ids, body: 'Text.', visibility: 'instance')
      loose = db[:keywords].insert(workspace_id: marketing, name: 'kurz', text: 'x',
                                   position: 'append', sort_order: 20,
                                   created_at: Time.now, updated_at: Time.now)

      assert_equal :foreign_keyword,
                   assert_raises(P::Refused) { P.permitted_keywords(db, db[:prompts][id: id], [loose], []) }.code
    end
  end

  def test_an_unknown_keyword_id_is_refused
    with_instance do |db, ids|
      id = create(db, ids, body: 'Text.')

      assert_equal :unknown_keyword,
                   assert_raises(P::Refused) { P.permitted_keywords(db, db[:prompts][id: id], [999_999], []) }.code
    end
  end
end
