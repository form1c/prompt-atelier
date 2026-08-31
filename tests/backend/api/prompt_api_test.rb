# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'app'

# The prompt endpoints over HTTP, and with them the twelve rows of TF-201 that
# AP-06 could only decide against the table because their endpoints did not
# exist yet. This is the repetition the plan foresees.
#
# TF-202 is completed here too: the parts about prompts were stated at the
# access layer in AP-06 and are now made over the wire, which is what test
# concept 6.1 asks for.
class PromptApiTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  def app = PromptAtelier::App

  def setup
    super
    @dir = migrated_dir('prompt-api')
    PromptAtelier::App.boot!(root: @dir)
    PromptAtelier::RateLimit.reset!
    @ids = with_app_db { |db| PromptAtelier::Fixture.build(db) }
  end

  def teardown
    PromptAtelier::App.reset!
    PromptAtelier::RateLimit.reset!
    super
  end

  # --- TF-201: the prompt rows over the wire --------------------------------

  # The reference object is P-WS in Marketing, exactly as test concept 6.2
  # fixes it. Thomas gets 404 throughout: he is not a member, so the prompt
  # does not exist for him.
  def test_tf201_reading_a_prompt_follows_the_matrix
    check(:get, ->(id) { "#{prefix}/prompts/#{id}" }, 'P-WS',
          { lisa: 200, martin: 200, anna: 200, sabine: 200, thomas: 404 })
  end

  def test_tf201_rendering_follows_the_matrix
    check(:post, ->(id) { "#{prefix}/prompts/#{id}/render" }, 'P-WS',
          { lisa: 200, martin: 200, anna: 200, sabine: 200, thomas: 404 }, payload: { values: {} })
  end

  def test_tf201_marking_a_favourite_follows_the_matrix
    check(:post, ->(id) { "#{prefix}/prompts/#{id}/favorite" }, 'P-WS',
          { lisa: 200, martin: 200, anna: 200, sabine: 200, thomas: 404 })
  end

  # Creating carries the workspace in the body, so Thomas gets 404 here too —
  # a 403 would tell him Marketing exists (footnote 3 of test concept 6.2).
  def test_tf201_creating_a_prompt_follows_the_matrix
    { lisa: 403, martin: 201, anna: 201, sabine: 201, thomas: 404 }.each do |person, expected|
      sign_in(person)
      csrf(:post, "#{prefix}/prompts",
           { workspace_id: marketing, title: 'Neu', body: 'Text.' })

      assert_equal expected, last_response.status, "#{person} creating"
    end
  end

  # The row that makes ◐ visible: an editor may edit their own and not a
  # foreign one, an admin may edit both.
  def test_tf201_editing_a_foreign_prompt_follows_the_matrix
    check(:put, ->(id) { "#{prefix}/prompts/#{id}" }, 'P-WS',
          { lisa: 403, martin: 403, anna: 200, sabine: 200, thomas: 404 },
          payload: { title: 'Geändert' })
  end

  def test_tf201_an_editor_may_edit_their_own_prompt
    sign_in(:martin)
    csrf(:put, "#{prefix}/prompts/#{prompt('P-EDIT')}", { title: 'Martins neue Fassung' })

    assert_equal 200, last_response.status
  end

  def test_tf201_deleting_a_foreign_prompt_follows_the_matrix
    check(:delete, ->(id) { "#{prefix}/prompts/#{id}" }, 'P-WS',
          { lisa: 403, martin: 403, anna: 200, sabine: 200, thomas: 404 })
  end

  def test_tf201_moving_follows_the_matrix
    check(:post, ->(id) { "#{prefix}/prompts/#{id}/move" }, 'P-WS',
          { lisa: 403, martin: 403, anna: 200, sabine: 200, thomas: 404 },
          payload_for: ->(person) { { workspace_id: personal_of(person) } })
  end

  def test_tf201_purging_from_the_trash_follows_the_matrix
    check(:delete, ->(id) { "#{prefix}/trash/#{id}" }, 'P-DEL',
          { lisa: 404, martin: 403, anna: 200, sabine: 200, thomas: 404 })
  end

  # --- TF-202: the stranger, over the wire ----------------------------------

  # TF-417 and TF-418 are the same statements among the edge cases: an
  # instance-wide prompt is readable but not editable, and an invisible one
  # answers 404 rather than 403.
  def test_tf202_and_tf417_and_tf418_a_stranger_meets_the_documented_answers
    sign_in(:joerg)

    get "#{prefix}/prompts/#{prompt('P-WS')}"
    assert_equal 404, last_response.status

    get "#{prefix}/prompts/#{prompt('P-PRIV-S')}"
    assert_equal 404, last_response.status

    get "#{prefix}/prompts/#{prompt('P-INST')}"
    assert_equal 200, last_response.status, 'instance-wide is readable'

    csrf(:put, "#{prefix}/prompts/#{prompt('P-INST')}", { title: 'Meins' })
    assert_equal 403, last_response.status, 'readable but not editable'

    csrf(:delete, "#{prefix}/prompts/#{prompt('P-INST')}")
    assert_equal 403, last_response.status

    csrf(:post, "#{prefix}/prompts/#{prompt('P-INST')}/move", { workspace_id: personal_of(:joerg) })
    assert_equal 403, last_response.status
  end

  def test_tf202_a_stranger_may_copy_an_instance_wide_prompt_into_their_own
    sign_in(:joerg)
    csrf(:post, "#{prefix}/prompts/#{prompt('P-INST')}/duplicate",
         { workspace_id: personal_of(:joerg) })

    assert_equal 201, last_response.status
    copy = JSON.parse(last_response.body)['prompt']
    assert_equal personal_of(:joerg), copy['workspace_id']
    assert_equal 'private', copy['visibility']
  end

  def test_tf202_listing_a_foreign_workspace_answers_404
    sign_in(:joerg)

    get "#{prefix}/prompts?workspace_id=#{marketing}"
    assert_equal 404, last_response.status, 'a 403 would disclose that the workspace exists'

    get "#{prefix}/trash?workspace_id=#{marketing}"
    assert_equal 404, last_response.status
  end

  # A keyword of a foreign workspace that does not hang on the prompt must not
  # be usable through the render endpoint — otherwise the foreign keyword
  # collection could be read out one id at a time (FA-604).
  def test_tf202_a_foreign_keyword_cannot_be_switched_on_from_outside
    loose = with_app_db do |db|
      db[:keywords].insert(workspace_id: marketing, name: 'kurz', text: 'Kurz.',
                           position: 'append', sort_order: 20,
                           created_at: Time.now, updated_at: Time.now)
    end

    sign_in(:joerg)
    csrf(:post, "#{prefix}/prompts/#{prompt('P-INST')}/render", { values: {}, keyword_ids: [loose] })

    assert_equal 403, last_response.status
  end

  def test_tf202_a_keyword_hanging_on_the_prompt_is_allowed_without_membership
    attached = with_app_db do |db|
      id = db[:keywords].insert(workspace_id: marketing, name: 'formal', text: 'Förmlich.',
                                position: 'append', sort_order: 10,
                                created_at: Time.now, updated_at: Time.now)
      db[:prompt_keywords].insert(prompt_id: prompt('P-INST'), keyword_id: id)
      id
    end

    sign_in(:joerg)
    csrf(:post, "#{prefix}/prompts/#{prompt('P-INST')}/render", { values: {}, keyword_ids: [attached] })

    assert_equal 200, last_response.status
    assert_includes JSON.parse(last_response.body)['text'], 'Förmlich.'
  end

  # --- the list (FA-205, TF-309b) -------------------------------------------

  def test_tf309b_archived_prompts_stay_out_of_the_list_until_asked_for
    sign_in(:sabine)

    get "#{prefix}/prompts?workspace_id=#{marketing}"
    ids = JSON.parse(last_response.body)['prompts'].map { |p| p['id'] }
    refute_includes ids, prompt('P-ARCH')
    assert_includes ids, prompt('P-WS')

    get "#{prefix}/prompts?workspace_id=#{marketing}&status=archived"
    assert_equal [prompt('P-ARCH')], JSON.parse(last_response.body)['prompts'].map { |p| p['id'] }
  end

  def test_the_list_never_contains_a_deleted_prompt
    sign_in(:sabine)
    get "#{prefix}/prompts?workspace_id=#{marketing}"

    refute_includes JSON.parse(last_response.body)['prompts'].map { |p| p['id'] }, prompt('P-DEL')
  end

  def test_the_list_hides_a_foreign_private_prompt
    sign_in(:anna)
    get "#{prefix}/prompts?workspace_id=#{marketing}"

    refute_includes JSON.parse(last_response.body)['prompts'].map { |p| p['id'] }, prompt('P-PRIV-S')
  end

  # 15.1: the parameter is mandatory. Choosing a default would silently pick a
  # scope for the caller.
  def test_a_list_call_without_a_workspace_is_refused
    sign_in(:sabine)
    get "#{prefix}/prompts"

    assert_equal 422, last_response.status
  end

  # --- TF-330: favourites belong to the person ------------------------------

  def test_tf330_a_favourite_of_one_member_does_not_appear_for_another
    sign_in(:martin)
    csrf(:post, "#{prefix}/prompts/#{prompt('P-WS')}/favorite")
    assert_equal 200, last_response.status

    get "#{prefix}/prompts/#{prompt('P-WS')}"
    assert JSON.parse(last_response.body)['prompt']['favorite']

    sign_in(:sabine)
    get "#{prefix}/prompts/#{prompt('P-WS')}"
    refute JSON.parse(last_response.body)['prompt']['favorite'], 'Sabine must not inherit it'
  end

  # --- TF-306 over the wire -------------------------------------------------

  def test_tf306_a_copy_reports_the_keyword_it_could_not_carry_over
    with_app_db do |db|
      formal = db[:keywords].insert(workspace_id: marketing, name: 'formal', text: 'Förmlich.',
                                    position: 'append', sort_order: 10,
                                    created_at: Time.now, updated_at: Time.now)
      db[:prompt_keywords].insert(prompt_id: prompt('P-INST'), keyword_id: formal)
      PromptAtelier::Prompts.assign_tags(db, prompt('P-INST'), marketing, %w[seo content blog])
    end

    sign_in(:joerg)
    csrf(:post, "#{prefix}/prompts/#{prompt('P-INST')}/duplicate", { workspace_id: personal_of(:joerg) })

    body = JSON.parse(last_response.body)
    assert_equal %w[formal], body['dropped_keywords']
    assert_equal %w[blog content seo], body['prompt']['tags']
    assert_empty body['prompt']['keywords']
  end

  # TF-204 over the wire. The access layer decides this in permissions_test.rb;
  # here it is proven that the endpoint actually asks. A mutation probe showed
  # the target check could be removed without any test noticing.
  def test_tf204_a_copy_into_a_workspace_without_create_rights_is_refused
    sign_in(:lisa)

    csrf(:post, "#{prefix}/prompts/#{prompt('P-WS')}/duplicate", { workspace_id: marketing })
    assert_equal 403, last_response.status, 'a viewer may read but not put a copy back'

    csrf(:post, "#{prefix}/prompts/#{prompt('P-WS')}/duplicate", { workspace_id: personal_of(:martin) })
    assert_equal 403, last_response.status, 'and not into somebody else’s workspace either'

    csrf(:post, "#{prefix}/prompts/#{prompt('P-WS')}/duplicate", { workspace_id: 999_999 })
    assert_equal 403, last_response.status, 'an absent target must look the same'

    csrf(:post, "#{prefix}/prompts/#{prompt('P-WS')}/duplicate", { workspace_id: personal_of(:lisa) })
    assert_equal 201, last_response.status, 'her own workspace is allowed'
  end

  # TF-308, server side. The dialog of "duplicate" and "move" has to offer
  # only workspaces the caller may write to — a target that can only end in
  # the 403 above is not a choice, it is a trap.
  #
  # The answer comes from the server rather than from the role in the browser.
  # A rule restated on the far side is a second place for it to be wrong, and
  # the second place is the one nobody tests (SEC-06). Lisa is the case that
  # tells the two apart: viewer in Marketing, owner of her own workspace.
  def test_tf308_the_workspace_list_says_where_a_prompt_may_be_created
    sign_in(:lisa)
    get "#{prefix}/workspaces"

    permitted = JSON.parse(last_response.body)['workspaces'].to_h do |workspace|
      [workspace['id'], workspace.dig('permissions', 'create')]
    end

    assert_equal false, permitted[marketing], 'a viewer may read there and create nothing'
    assert_equal true, permitted[personal_of(:lisa)], 'her own workspace is hers to fill'
  end

  # The counter-check on the same list: whoever may write there sees it that
  # way too. Without it the case above would hold even if the entry always read
  # `false`.
  def test_the_same_list_says_yes_where_the_role_allows_it
    sign_in(:martin)
    get "#{prefix}/workspaces"

    marketing_entry = JSON.parse(last_response.body)['workspaces'].find { |w| w['name'] == 'Marketing' }

    assert_equal 'editor', marketing_entry['role']
    assert_equal true, marketing_entry.dig('permissions', 'create')
  end

  # --- TF-307 and TF-422 over the wire --------------------------------------

  def test_tf307_moving_reports_the_visibility_reset
    sign_in(:martin)
    csrf(:post, "#{prefix}/prompts/#{prompt('P-EDIT')}/move", { workspace_id: personal_of(:martin) })

    body = JSON.parse(last_response.body)
    assert_equal 'private', body['prompt']['visibility']
    assert body['visibility_reset'], 'the user is told, rather than finding out later'
  end

  # TF-422: a target the caller may not write to is refused — and refused the
  # same way whether it is foreign, forbidden or absent.
  def test_tf422_moving_into_a_workspace_without_create_rights_is_refused
    sign_in(:martin)
    csrf(:post, "#{prefix}/prompts/#{prompt('P-EDIT')}/move", { workspace_id: personal_of(:lisa) })
    assert_equal 403, last_response.status

    csrf(:post, "#{prefix}/prompts/#{prompt('P-EDIT')}/move", { workspace_id: 999_999 })
    assert_equal 403, last_response.status, 'an absent target must look the same'
  end

  # --- trash over the wire (TF-335 to TF-337) -------------------------------

  # A second deleted prompt is needed, belonging to somebody else. With only
  # P-DEL in the trash the editor's narrower view is indistinguishable from
  # the administrator's — a mutation probe showed the test passing while the
  # role was ignored entirely.
  def test_tf335_and_tf336_the_trash_shows_what_the_role_allows
    foreign = with_app_db do |db|
      id = db[:prompts].insert(workspace_id: marketing, owner_id: @ids[:users][:sabine],
                               title: 'Sabines geloeschter', body: 'Text.',
                               visibility: 'workspace', status: 'active',
                               deleted_at: Time.now, deleted_by: @ids[:users][:sabine],
                               created_at: Time.now, updated_at: Time.now)
      id
    end

    sign_in(:martin)
    get "#{prefix}/trash?workspace_id=#{marketing}"
    martins = JSON.parse(last_response.body)['prompts'].map { |p| p['id'] }
    assert_includes martins, prompt('P-DEL'), 'P-DEL belongs to Martin'
    refute_includes martins, foreign, 'an editor does not see a foreign deletion'

    sign_in(:lisa)
    get "#{prefix}/trash?workspace_id=#{marketing}"
    assert_equal 403, last_response.status, 'a viewer has no trash at all'

    sign_in(:anna)
    get "#{prefix}/trash?workspace_id=#{marketing}"
    annas = JSON.parse(last_response.body)['prompts'].map { |p| p['id'] }
    assert_includes annas, prompt('P-DEL')
    assert_includes annas, foreign, 'an administrator sees the whole workspace'
  end

  # FA-703 names three things a line in the trash carries: the time of
  # deletion, the deleting **user** and the workspace it came from. Two of
  # them were in the payload as identifiers, which answers the question in a
  # form nobody can read — "gelöscht von 4" is not the deleting user.
  def test_tf335_the_trash_names_the_deleting_user_and_the_origin
    sign_in(:anna)
    get "#{prefix}/trash?workspace_id=#{marketing}"

    entry = JSON.parse(last_response.body)['prompts'].find { |row| row['id'] == prompt('P-DEL') }

    refute_nil entry['deleted_at'], 'the time of deletion'
    assert_equal 'Martin', entry['deleted_by_name'], 'the deleting user, by name'
    assert_equal 'Marketing', entry['workspace_name'], 'where it came from'
  end

  # FA-704: purging is admin and owner only, and restoring is not. The screen
  # decides which buttons to draw from these, so they have to come apart on
  # the same row — a single answer for the whole list would be wrong for half
  # of it.
  def test_the_trash_says_per_row_what_may_be_done_with_it
    foreign = with_app_db do |db|
      db[:prompts].insert(workspace_id: marketing, owner_id: @ids[:users][:sabine],
                          title: 'Sabines geloeschter', body: 'Text.',
                          visibility: 'workspace', status: 'active',
                          deleted_at: Time.now, deleted_by: @ids[:users][:anna],
                          created_at: Time.now, updated_at: Time.now)
    end

    sign_in(:martin)
    get "#{prefix}/trash?workspace_id=#{marketing}"
    rows = JSON.parse(last_response.body)['prompts'].to_h { |row| [row['id'], row['permissions']] }

    assert rows.dig(prompt('P-DEL'), 'restore'), 'his own prompt comes back'
    refute rows.dig(prompt('P-DEL'), 'purge'), 'but an editor never purges'
    # Anna deleted this one and Sabine owns it, so Martin sees it in neither
    # half of the editor's view — the counter-check that the row filter and
    # the permissions agree.
    refute_includes rows.keys, foreign

    sign_in(:anna)
    get "#{prefix}/trash?workspace_id=#{marketing}"
    annas = JSON.parse(last_response.body)['prompts'].to_h { |row| [row['id'], row['permissions']] }

    assert annas.dig(foreign, 'purge'), 'an administrator may purge'
    assert annas.dig(prompt('P-DEL'), 'restore')
  end

  def test_tf337_restoring_returns_the_prompt_to_the_library
    sign_in(:anna)
    csrf(:post, "#{prefix}/trash/#{prompt('P-DEL')}/restore")
    assert_equal 200, last_response.status

    get "#{prefix}/prompts?workspace_id=#{marketing}"
    assert_includes JSON.parse(last_response.body)['prompts'].map { |p| p['id'] }, prompt('P-DEL')
  end

  # A prompt in the trash is gone from the ordinary path — the trash has its
  # own endpoints and its own permissions.
  def test_a_deleted_prompt_is_not_reachable_through_the_normal_path
    sign_in(:sabine)
    get "#{prefix}/prompts/#{prompt('P-DEL')}"

    assert_equal 404, last_response.status
  end

  def test_a_live_prompt_is_not_reachable_through_the_trash_path
    sign_in(:sabine)
    csrf(:post, "#{prefix}/trash/#{prompt('P-WS')}/restore")

    assert_equal 404, last_response.status
  end

  # --- undo over the wire (TF-333) ------------------------------------------

  def test_tf333_undo_restores_the_previous_state
    sign_in(:sabine)
    csrf(:put, "#{prefix}/prompts/#{prompt('P-WS')}", { body: 'Ein ganz neuer Text.' })
    assert_equal 200, last_response.status

    csrf(:post, "#{prefix}/prompts/#{prompt('P-WS')}/undo")
    assert_equal 200, last_response.status
    refute_equal 'Ein ganz neuer Text.', JSON.parse(last_response.body)['prompt']['body']
  end

  def test_undo_without_a_previous_state_is_refused
    sign_in(:sabine)
    csrf(:post, "#{prefix}/prompts/#{prompt('P-WS')}/undo")

    assert_equal 422, last_response.status
  end

  # --- TF-428 over the wire -------------------------------------------------

  def test_tf428_an_exceeded_limit_is_reported_with_limit_and_actual_value
    sign_in(:sabine)
    csrf(:post, "#{prefix}/prompts", { workspace_id: marketing, title: 'T' * 201, body: 'x' })

    assert_equal 422, last_response.status
    fields = JSON.parse(last_response.body).dig('error', 'fields')
    assert_equal 200, fields.dig('title', 'limit')
    assert_equal 201, fields.dig('title', 'actual')
  end

  # --- what the screen may offer (11.4) -------------------------------------

  # The detail answer says what this person may do, so the menu can leave out
  # what is not allowed instead of offering it and being refused. Computed
  # from the same matrix the endpoints use — a second copy in the browser
  # would be a second place for the rules to be wrong.
  def test_the_detail_says_what_the_reader_may_do
    sign_in(:martin)

    mine = detail(prompt('P-EDIT'))['permissions']
    assert_equal({ 'update' => true, 'delete' => true, 'duplicate' => true,
                   'move' => true, 'visibility' => true }, mine)
  end

  # The counter-check, and the case 11.4 names: on a foreign prompt from the
  # view across all workspaces only duplicating is left.
  def test_a_foreign_prompt_offers_only_what_a_stranger_may_do
    sign_in(:joerg)

    foreign = detail(prompt('P-INST'))['permissions']

    assert_equal false, foreign['update']
    assert_equal false, foreign['delete']
    assert_equal false, foreign['move']
    assert_equal false, foreign['visibility']
    assert_equal true,  foreign['duplicate'], 'FA-604: duplicating stays open'
  end

  # A viewer sees the prompt and may do nothing to it — the row of the matrix
  # that is easiest to get wrong in an interface, because the screen looks the
  # same as an editor's.
  def test_a_viewer_is_offered_nothing_but_duplicating
    sign_in(:lisa)

    permissions = detail(prompt('P-WS'))['permissions']

    assert_equal [true], permissions.select { |_action, allowed| allowed }.values
    assert permissions['duplicate']
  end

  # The default keywords in full. The preview renders in the browser (NFA-14),
  # so it needs text, position and order — with only the names it would leave
  # out what the server puts in, and the two renderings would differ on the
  # screen that exists to show them agreeing.
  def test_the_detail_carries_the_default_keywords_with_everything_rendering_needs
    sign_in(:sabine)
    keyword_id = with_app_db do |db|
      id = db[:keywords].insert(workspace_id: marketing, name: 'rolle', text: 'Du bist Fachautor.',
                                position: 'prepend', sort_order: 10,
                                created_at: Time.now, updated_at: Time.now)
      db[:prompt_keywords].insert(prompt_id: prompt('P-WS'), keyword_id: id)
      id
    end

    keywords = detail(prompt('P-WS'))['keywords']

    assert_equal 1, keywords.size
    assert_equal({ 'id' => keyword_id, 'name' => 'rolle', 'text' => 'Du bist Fachautor.',
                   'position' => 'prepend', 'sort_order' => 10 }, keywords.first)
  end

  # And they come along even when their workspace is closed to the reader
  # (TF-426). The render endpoint applies these very keywords for this very
  # reader, so withholding the text here would only make the local preview
  # wrong.
  def test_a_stranger_gets_the_attached_keywords_of_an_instance_wide_prompt
    with_app_db do |db|
      id = db[:keywords].insert(workspace_id: marketing, name: 'formal', text: 'Förmlich.',
                                position: 'append', sort_order: 10,
                                created_at: Time.now, updated_at: Time.now)
      db[:prompt_keywords].insert(prompt_id: prompt('P-INST'), keyword_id: id)
    end
    sign_in(:joerg)

    keywords = detail(prompt('P-INST'))['keywords']

    assert_equal ['formal'], keywords.map { |keyword| keyword['name'] }
    assert_equal 'Förmlich.', keywords.first['text']
  end

  private

  def detail(id)
    get "#{prefix}/prompts/#{id}"
    assert_equal 200, last_response.status, last_response.body[0, 200]
    JSON.parse(last_response.body)['prompt']
  end

  def prefix = PromptAtelier::App::API_PREFIX
  def marketing = @ids[:workspaces][:marketing]
  def prompt(label) = @ids[:prompts][label]
  def personal_of(person) = @ids[:workspaces][:"personal_#{person}"]
  def with_app_db(&block) = PromptAtelier::Database.open(database_path(@dir), &block)

  # Runs one row of the matrix: the same call as each person in turn, with the
  # fixture rebuilt in between when the call changed something.
  def check(method, path, label, expectations, payload: nil, payload_for: nil)
    expectations.each do |person, expected|
      rebuild
      sign_in(person)
      body = payload_for ? payload_for.call(person) : payload

      if method == :get
        get path.call(prompt(label))
      else
        csrf(method, path.call(prompt(label)), body)
      end

      assert_equal expected, last_response.status,
                   "#{person}: #{method.upcase} #{path.call(prompt(label))} — #{last_response.body[0, 120]}"
    end
  end

  # Several rows are destructive (delete, move, purge). Rebuilding between
  # people keeps each one measuring the permission rather than the leftovers
  # of the person before (test concept 4).
  def rebuild
    PromptAtelier::App.reset!
    @dir = migrated_dir("prompt-api-#{SecureRandom.hex(4)}")
    PromptAtelier::App.boot!(root: @dir)
    @ids = with_app_db { |db| PromptAtelier::Fixture.build(db) }
  end

  def sign_in(person)
    clear_cookies
    post "#{prefix}/auth/login",
         JSON.generate(email: PromptAtelier::Fixture::PEOPLE[person][:email],
                       password: PromptAtelier::Fixture::PASSWORD),
         'CONTENT_TYPE' => 'application/json'
    assert_equal 200, last_response.status, "could not sign in as #{person}: #{last_response.body}"
  end

  def csrf_token = rack_mock_session.cookie_jar[PromptAtelier::Sessions::CSRF_COOKIE_NAME]

  def csrf(method, path, payload = nil)
    send(method, path, payload.nil? ? '' : JSON.generate(payload),
         'CONTENT_TYPE' => 'application/json', 'HTTP_X_CSRF_TOKEN' => csrf_token.to_s)
  end
end
