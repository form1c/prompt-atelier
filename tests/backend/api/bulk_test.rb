# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'app'

# Acting on many prompts at once (TF-359 to TF-366, FA-511, FA-703a).
#
# **Every case here uses a selection in which some entries are permitted and
# some are not**, and that is the point of the file rather than a detail of it.
# A bulk action checked against a wholly permitted selection says nothing about
# the ordinary case: out of fifty prompts a few always fail on chapter 6.2, and
# what the person needs then is not an abort but a list of which ones and why.
#
# The second recurring theme is what a refusal is allowed to say. An id the
# caller may not see is refused **without a title** and with the same reason as
# an id that does not exist. Otherwise a bulk call would be a way of reading
# foreign titles, and the difference between "forbidden" and "gone" would say
# which ids are taken (SEC-06).
class BulkTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  def app = PromptAtelier::App

  def setup
    super
    @dir = migrated_dir('bulk')
    PromptAtelier::App.boot!(root: @dir)
    PromptAtelier::RateLimit.reset!
    @ids = with_app_db { |db| PromptAtelier::Fixture.build(db) }
  end

  def teardown
    PromptAtelier::App.reset!
    PromptAtelier::RateLimit.reset!
    super
  end

  # --- TF-360: moving, with part of the selection refused --------------------

  def test_tf360_a_bulk_move_carries_out_what_is_allowed_and_names_the_rest
    sign_in(:martin)
    mine = prompt_id('P-EDIT')
    foreign = prompt_id('P-PRIV-S')      # Sabine's, private: Martin cannot see it
    others = prompt_id('P-WS')           # Sabine's, visible, but not Martin's to move

    bulk(:post, 'prompts/bulk/move',
         prompt_ids: [mine, others, foreign], workspace_id: personal(:martin))

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)

    assert_equal [mine], body['done'].map { |entry| entry['id'] }
    assert_equal 1, body['counts']['done']
    assert_equal 2, body['counts']['refused']
    assert_equal personal(:martin), with_app_db { |db| db[:prompts][id: mine][:workspace_id] }
  end

  # The refusal carries the title — for the entry the person can see. That is
  # the whole difference between a report and a number: "2 refused" is a
  # figure, two titles are an answer.
  def test_tf360_a_visible_refusal_is_named
    sign_in(:martin)
    others = prompt_id('P-WS')

    bulk(:post, 'prompts/bulk/move',
         prompt_ids: [others], workspace_id: personal(:martin))

    entry = JSON.parse(last_response.body)['refused'].first

    assert_equal 'forbidden', entry['reason']
    assert_equal 'P-WS', entry['title']
  end

  # TF-364. The one the security rule turns on: an id Martin may not see is
  # refused exactly like an id that does not exist — same reason, no title.
  # Without this, a bulk call would answer "does prompt 47 exist?".
  def test_tf364_an_invisible_id_and_an_absent_id_are_indistinguishable
    sign_in(:martin)
    invisible = prompt_id('P-PRIV-S')

    bulk(:post, 'prompts/bulk/move',
         prompt_ids: [invisible, 999_999], workspace_id: personal(:martin))

    entries = JSON.parse(last_response.body)['refused']

    assert_equal %w[not_found not_found], entries.map { |entry| entry['reason'] }
    assert_equal [nil, nil], entries.map { |entry| entry['title'] },
                 'a title here would be the disclosure the uniform answer exists to prevent'
  end

  # TF-360b. FA-207 holds per prompt, and the count is what the interface says
  # once, beforehand.
  def test_tf360b_visibility_falls_back_to_private_and_is_counted
    sign_in(:sabine)
    workspace_visible = prompt_id('P-WS')
    already_private = prompt_id('P-PRIV-S')

    bulk(:post, 'prompts/bulk/move',
         prompt_ids: [workspace_visible, already_private], workspace_id: personal(:sabine))

    assert_equal 1, JSON.parse(last_response.body)['counts']['visibility_reset']
    with_app_db do |db|
      assert_equal 'private', db[:prompts][id: workspace_visible][:visibility]
    end
  end

  # A foreign target is one uniform 403, whatever is wrong with it — the same
  # rule the single move follows (Access.for_target_workspace).
  def test_a_foreign_target_workspace_is_refused_before_anything_moves
    sign_in(:martin)
    mine = prompt_id('P-EDIT')

    bulk(:post, 'prompts/bulk/move', prompt_ids: [mine], workspace_id: personal(:joerg))

    assert_equal 403, last_response.status
    assert_equal @ids[:workspaces][:marketing],
                 with_app_db { |db| db[:prompts][id: mine][:workspace_id] },
                 'nothing may move when the target is refused'
  end

  # --- TF-361: into the trash ------------------------------------------------

  def test_tf361_a_bulk_delete_moves_what_is_allowed_and_records_who_did_it
    sign_in(:martin)
    mine = prompt_id('P-EDIT')
    others = prompt_id('P-WS')

    bulk(:post, 'prompts/bulk/trash', prompt_ids: [mine, others])

    body = JSON.parse(last_response.body)

    assert_equal [mine], body['done'].map { |entry| entry['id'] }
    with_app_db do |db|
      refute_nil db[:prompts][id: mine][:deleted_at]
      assert_equal @ids[:users][:martin], db[:prompts][id: mine][:deleted_by]
      assert_nil db[:prompts][id: others][:deleted_at], 'the refused one stays where it is'
    end
  end

  # --- TF-362: restoring -----------------------------------------------------

  def test_tf362_a_bulk_restore_brings_back_visibility_and_status
    trashed = with_app_db do |db|
      db[:prompts].where(id: prompt_id('P-WS')).update(deleted_at: Time.now,
                                                       deleted_by: @ids[:users][:sabine])
      prompt_id('P-WS')
    end
    sign_in(:sabine)

    bulk(:post, 'trash/bulk/restore', prompt_ids: [trashed, prompt_id('P-DEL')])

    body = JSON.parse(last_response.body)

    assert_equal 2, body['counts']['done'], 'the owner sees the whole trash of the workspace'
    with_app_db do |db|
      assert_nil db[:prompts][id: trashed][:deleted_at]
      assert_equal 'workspace', db[:prompts][id: trashed][:visibility], 'FA-703: metadata returns'
    end
  end

  # An editor sees only what they deleted or own (FA-703), and a bulk restore
  # must not widen that by one entry.
  def test_a_bulk_restore_does_not_reach_past_the_trash_rules
    trashed = with_app_db do |db|
      db[:prompts].where(id: prompt_id('P-PRIV-S')).update(deleted_at: Time.now,
                                                           deleted_by: @ids[:users][:sabine])
      prompt_id('P-PRIV-S')
    end
    sign_in(:martin)

    bulk(:post, 'trash/bulk/restore', prompt_ids: [trashed])

    assert_equal 'not_found', JSON.parse(last_response.body)['refused'].first['reason']
    refute_nil with_app_db { |db| db[:prompts][id: trashed][:deleted_at] }
  end

  # --- TF-363: purging -------------------------------------------------------

  # The only irreversible operation, and the only one that has to leave a trace
  # per prompt: afterwards there is nothing left to look at.
  def test_tf363_a_bulk_purge_writes_one_audit_entry_per_prompt
    sign_in(:sabine)
    doomed = prompt_id('P-DEL')

    bulk(:post, 'trash/bulk/purge', prompt_ids: [doomed])

    with_app_db do |db|
      assert_nil db[:prompts][id: doomed]
      entries = db[:audit_logs].where(action: 'prompt.purged', target_id: doomed).all

      assert_equal 1, entries.length
      assert_equal @ids[:users][:sabine], entries.first[:actor_id]
    end
  end

  # `trash.purge` is denied to an editor even for their own prompt — the matrix
  # says so, and a bulk call is not a way around it.
  def test_an_editor_may_not_purge_even_their_own
    sign_in(:martin)
    own = prompt_id('P-DEL')

    bulk(:post, 'trash/bulk/purge', prompt_ids: [own])

    assert_equal 'forbidden', JSON.parse(last_response.body)['refused'].first['reason']
    refute_nil with_app_db { |db| db[:prompts][id: own] }
  end

  # --- TF-366 and the shape of the request -----------------------------------

  def test_tf366_an_empty_list_is_refused_and_nothing_happens
    sign_in(:martin)

    bulk(:post, 'prompts/bulk/trash', prompt_ids: [])

    assert_equal 422, last_response.status
    assert_equal 'empty', JSON.parse(last_response.body).dig('error', 'fields', 'prompt_ids')
  end

  def test_something_that_is_not_a_list_is_refused
    sign_in(:martin)

    bulk(:post, 'prompts/bulk/trash', prompt_ids: 'alle')

    assert_equal 422, last_response.status
    assert_equal 'not_a_list', JSON.parse(last_response.body).dig('error', 'fields', 'prompt_ids')
  end

  # An unbounded list is an unbounded transaction. The interface only offers
  # "select all results" below this number, so the limit is a promise on both
  # sides rather than a surprise.
  def test_a_list_beyond_the_limit_is_refused
    sign_in(:martin)

    bulk(:post, 'prompts/bulk/trash', prompt_ids: (1..(PromptAtelier::Bulk::MAX_IDS + 1)).to_a)

    assert_equal 422, last_response.status
    assert_equal 'too_many', JSON.parse(last_response.body).dig('error', 'fields', 'prompt_ids')
  end

  def test_a_bulk_call_without_a_session_is_refused
    bulk(:post, 'prompts/bulk/trash', prompt_ids: [prompt_id('P-EDIT')])

    assert_equal 401, last_response.status
  end

  # --- TF-365: one call, not a loop ------------------------------------------

  # SEC-19 allows 120 writing calls per minute and session. This is the
  # counter-check to doing it in the browser: 300 prompts as 300 calls would
  # stop after 120 with the selection half moved and no report saying where.
  def test_tf365_three_hundred_prompts_go_through_in_one_call
    sign_in(:sabine)
    many = with_app_db { |db| Array.new(300) { |n| insert_prompt_for(db, "Massenprompt #{n}") } }

    bulk(:post, 'prompts/bulk/trash', prompt_ids: many)

    assert_equal 200, last_response.status
    assert_equal 300, JSON.parse(last_response.body)['counts']['done']
    with_app_db do |db|
      assert_equal 0, db[:prompts].where(id: many, deleted_at: nil).count
    end
  end

  # And the counter-check to that counter-check: the limit really does bite at
  # 120 single calls, so the case above is measuring something.
  def test_the_same_three_hundred_as_single_calls_would_run_into_the_limit
    sign_in(:sabine)
    prompt = prompt_id('P-PLAIN')

    statuses = (1..125).map do
      csrf(:post, "#{prefix}/prompts/#{prompt}/favorite", {})
      last_response.status
    end

    assert_includes statuses, 429,
                    'without this, TF-365 would be a case about a limit that never applies'
  end

  private

  def prefix = '/api/v1'

  def prompt_id(label) = @ids[:prompts][label]
  def personal(person) = @ids[:workspaces][:"personal_#{person}"]

  def with_app_db(&block) = PromptAtelier::App.database.then(&block)

  def sign_in(person)
    details = PromptAtelier::Fixture::PEOPLE.fetch(person)
    post "#{prefix}/auth/login",
         JSON.generate(email: details[:email], password: PromptAtelier::Fixture::PASSWORD),
         { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 200, last_response.status, "signing in as #{person} failed"
  end

  # Writing calls need the CSRF header (SEC-05); without it every case here
  # would be measuring a 403.
  def bulk(verb, path, payload)
    csrf(verb, "#{prefix}/#{path}", payload)
  end

  def csrf(verb, path, payload)
    token = rack_mock_session.cookie_jar[PromptAtelier::Sessions::CSRF_COOKIE_NAME]
    send(verb, path, JSON.generate(payload),
         { 'CONTENT_TYPE' => 'application/json', 'HTTP_X_CSRF_TOKEN' => token })
  end

  def insert_prompt_for(db, title)
    now = Time.now
    db[:prompts].insert(workspace_id: @ids[:workspaces][:marketing], owner_id: @ids[:users][:sabine],
                        title: title, body: 'Rumpf', visibility: 'workspace', status: 'active',
                        created_at: now, updated_at: now)
  end
end
