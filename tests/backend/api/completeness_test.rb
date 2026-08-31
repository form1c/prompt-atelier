# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'app'

# The cases the coverage review after AP-08 turned up: five that were testable
# and simply missing, two features of AP-06 that had never been built, and one
# defect the review found in passing.
#
# Also the systematic audit check. SEC-09 lists what has to be recorded and
# calls the list a lower bound. Individual entries were asserted here and
# there; that a documented event is recorded *at all* was not — which is the
# kind of gap that only shows up when someone asks the log a question it
# cannot answer.
class CompletenessTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  def app = PromptAtelier::App

  def setup
    super
    @dir = migrated_dir('completeness')
    PromptAtelier::App.boot!(root: @dir)
    PromptAtelier::RateLimit.reset!
    @ids = with_app_db { |db| PromptAtelier::Fixture.build(db) }
  end

  def teardown
    PromptAtelier::App.reset!
    PromptAtelier::RateLimit.reset!
    super
  end

  # --- a refused write leaves nothing behind --------------------------------

  # Found while reviewing coverage: the prompt row is written before the
  # checks that need its id can run, so a refusal used to leave it there. The
  # caller got 422 and the library gained an entry nobody asked for.
  def test_a_refused_creation_leaves_no_prompt_behind
    before = with_app_db { |db| db[:prompts].count }
    sign_in(:sabine)

    csrf(:post, "#{prefix}/prompts",
         { workspace_id: marketing, title: 'Wird abgelehnt',
           body: (1..51).map { |n| "{{v#{n}}}" }.join(' ') })

    assert_equal 422, last_response.status
    with_app_db do |db|
      assert_equal before, db[:prompts].count, 'the refused prompt must not exist'
      assert_equal 0, db[:prompts].where(title: 'Wird abgelehnt').count
    end
  end

  def test_a_refused_change_leaves_the_prompt_and_its_history_untouched
    sign_in(:sabine)
    id = prompt('P-WS')
    before = with_app_db { |db| [db[:prompts][id: id], db[:prompt_revisions].where(prompt_id: id).count] }

    csrf(:put, "#{prefix}/prompts/#{id}",
         { body: (1..51).map { |n| "{{v#{n}}}" }.join(' ') })

    assert_equal 422, last_response.status
    with_app_db do |db|
      assert_equal before[0], db[:prompts][id: id], 'nothing about the prompt may have moved'
      assert_equal before[1], db[:prompt_revisions].where(prompt_id: id).count,
                   'and no revision may have been written for a change that did not happen'
    end
  end

  # --- TF-510c: injection through the list parameters -----------------------

  # The sort parameter reaches an ORDER BY. It is resolved through an allow
  # list rather than interpolated, so this is safe by construction — and
  # pinned here, because "safe by construction" is a property that a later
  # convenience can remove without anyone noticing.
  def test_tf510c_the_sort_parameter_cannot_carry_sql
    sign_in(:sabine)

    ['p.title; DROP TABLE prompts--', '1) UNION SELECT * FROM users--',
     'title/**/DESC', 'RANDOM()', ''].each do |attempt|
      get "#{prefix}/prompts?workspace_id=#{marketing}&sort=#{CGI.escape(attempt)}"

      assert_equal 200, last_response.status, "sort=#{attempt.inspect}"
    end

    with_app_db do |db|
      assert_equal 6, db[:users].count, 'the users table is untouched'
      refute_equal 0, db[:prompts].count, 'and so are the prompts'
    end
  end

  def test_tf510c_a_tag_name_and_a_prompt_title_are_treated_as_text
    sign_in(:sabine)
    nasty = "'; DROP TABLE prompts;--"

    csrf(:post, "#{prefix}/tags", { workspace_id: marketing, name: nasty })
    assert_equal 201, last_response.status

    csrf(:post, "#{prefix}/prompts", { workspace_id: marketing, title: nasty, body: 'Text.' })
    assert_equal 201, last_response.status

    get "#{prefix}/prompts?workspace_id=#{marketing}&q=#{CGI.escape(nasty)}"
    assert_equal 200, last_response.status

    with_app_db do |db|
      assert_equal 1, db[:tags].where(name: nasty).count, 'stored as the text it is'
      assert_equal 1, db[:prompts].where(title: nasty).count
    end
  end

  # --- TF-309: status transitions -------------------------------------------

  def test_tf309_a_prompt_walks_from_draft_through_active_to_archived
    sign_in(:martin)
    id = prompt('P-DRAFT')

    %w[active archived].each do |status|
      csrf(:put, "#{prefix}/prompts/#{id}", { status: status })

      assert_equal 200, last_response.status
      assert_equal status, JSON.parse(last_response.body)['prompt']['status']
    end
  end

  # --- TF-308b to TF-308e: renaming -----------------------------------------

  def test_tf308b_an_administrator_renames_the_workspace_without_touching_anything_else
    before = with_app_db do |db|
      [db[:memberships].where(workspace_id: marketing).count,
       db[:prompts].where(workspace_id: marketing).count]
    end

    sign_in(:anna)
    csrf(:put, "#{prefix}/workspaces/#{marketing}", { name: 'Marketing und Kommunikation' })

    assert_equal 200, last_response.status
    with_app_db do |db|
      assert_equal 'Marketing und Kommunikation', db[:workspaces][id: marketing][:name]
      assert_equal before, [db[:memberships].where(workspace_id: marketing).count,
                            db[:prompts].where(workspace_id: marketing).count]
    end
  end

  # TF-308c: the instance administrator renames a workspace he is not a member
  # of — and is still refused sight of its contents afterwards. That pairing is
  # the point: administrative reach must not become read access.
  def test_tf308c_the_instance_administrator_renames_without_gaining_sight
    sign_in(:thomas)
    csrf(:put, "#{prefix}/admin/workspaces/#{marketing}", { name: 'Umbenannt von Thomas' })

    assert_equal 200, last_response.status
    with_app_db { |db| assert_equal 'Umbenannt von Thomas', db[:workspaces][id: marketing][:name] }

    get "#{prefix}/prompts?workspace_id=#{marketing}"
    assert_equal 404, last_response.status, 'renaming grants no view of the contents'

    get "#{prefix}/prompts/#{prompt('P-WS')}"
    assert_equal 404, last_response.status
  end

  # TF-308d: the slug stays. Saved links and bookmarks have to survive a
  # rename, so the name is the user's and the slug is the address.
  def test_tf308d_renaming_leaves_the_slug_alone
    before = with_app_db { |db| db[:workspaces][id: marketing][:slug] }

    sign_in(:sabine)
    csrf(:put, "#{prefix}/workspaces/#{marketing}", { name: 'Ganz anders' })

    with_app_db { |db| assert_equal before, db[:workspaces][id: marketing][:slug] }
  end

  def test_tf308e_a_personal_workspace_may_be_renamed_though_not_deleted
    personal = @ids[:workspaces][:personal_martin]
    sign_in(:martin)

    csrf(:put, "#{prefix}/workspaces/#{personal}", { name: 'Meine Sachen' })
    assert_equal 200, last_response.status

    csrf(:delete, "#{prefix}/workspaces/#{personal}")
    assert_equal 403, last_response.status, 'renaming yes, deleting no'
  end

  def test_the_instance_administrator_sees_every_workspace_but_no_contents
    sign_in(:thomas)
    get "#{prefix}/admin/workspaces"

    listed = JSON.parse(last_response.body)['workspaces']
    entry = listed.find { |w| w['id'] == marketing }
    assert_equal 'Sabine', entry['owner']
    assert_equal 4, entry['member_count']
    assert_operator entry['prompt_count'], :>, 0
    refute entry.key?('prompts'), 'counts, never content'
  end

  def test_only_the_instance_administrator_reaches_the_admin_workspace_list
    sign_in(:sabine)
    get "#{prefix}/admin/workspaces"

    assert_equal 403, last_response.status
  end

  # --- TF-308f and TF-308g: the workspace selection -------------------------

  # FA-605: the selection lives on the server. Signing in on another device
  # has to land in the same workspace, which localStorage cannot do.
  def test_tf308f_the_chosen_workspace_survives_a_new_session_elsewhere
    sign_in(:martin)
    csrf(:put, "#{prefix}/workspaces/selection", { workspace_id: marketing })
    assert_equal 200, last_response.status

    sign_in(:martin) # a fresh client, no cookies carried over
    get "#{prefix}/workspaces"

    assert_equal marketing, JSON.parse(last_response.body)['selected_workspace_id']
  end

  # TF-308g: someone can be removed from the workspace still recorded as their
  # last choice. Handing it back would greet them with a 404 on the screen
  # they land on, so the membership is checked rather than assumed.
  def test_tf308g_losing_the_membership_falls_back_to_the_personal_workspace
    sign_in(:martin)
    csrf(:put, "#{prefix}/workspaces/selection", { workspace_id: marketing })

    sign_in(:sabine)
    csrf(:delete, "#{prefix}/workspaces/#{marketing}/members/#{@ids[:users][:martin]}")
    assert_equal 200, last_response.status

    sign_in(:martin)
    get "#{prefix}/workspaces"

    assert_equal @ids[:workspaces][:personal_martin],
                 JSON.parse(last_response.body)['selected_workspace_id'],
                 'no error, just the workspace FA-602 guarantees'
  end

  def test_a_workspace_one_may_not_read_cannot_be_selected
    sign_in(:joerg)
    csrf(:put, "#{prefix}/workspaces/selection", { workspace_id: marketing })

    assert_equal 404, last_response.status
  end

  # --- the halves of the interface-bound cases ------------------------------

  # TF-509 asks that a script tag appears as text and is never executed. The
  # execution half needs a browser and belongs to AP-11. The half that can be
  # settled here is the one a later interface depends on: the API stores and
  # returns the characters unchanged and never claims they are HTML — if the
  # server mangled or re-encoded them, the interface could do everything right
  # and still show something wrong.
  def test_tf509_a_script_tag_is_stored_and_returned_as_the_text_it_is
    payload = '<script>alert(1)</script> & "quotes" <b>bold</b>'
    sign_in(:sabine)

    csrf(:post, "#{prefix}/prompts", { workspace_id: marketing, title: 'XSS', body: payload })
    id = JSON.parse(last_response.body)['prompt']['id']

    get "#{prefix}/prompts/#{id}"
    assert_equal payload, JSON.parse(last_response.body)['prompt']['body'],
                 'unchanged, character for character'
    assert_includes last_response.headers['content-type'], 'application/json',
                    'never announced as HTML'

    csrf(:post, "#{prefix}/prompts/#{id}/render", { values: {} })
    assert_equal payload, JSON.parse(last_response.body)['text']
  end

  # TF-401 asks that an unfilled required variable blocks copying and marks
  # the field. The blocking is the interface's job; the answer it needs is
  # this one. Without `complete: false` and the name of the missing variable
  # the interface could not block anything.
  def test_tf401_the_render_answer_names_what_is_still_missing
    sign_in(:sabine)
    csrf(:post, "#{prefix}/prompts",
         { workspace_id: marketing, title: 'Pflicht', body: 'Über {{thema}} für {{ziel}}.',
           variables: [{ 'key' => 'thema', 'required' => true },
                       { 'key' => 'ziel', 'required' => true }] })
    id = JSON.parse(last_response.body)['prompt']['id']

    csrf(:post, "#{prefix}/prompts/#{id}/render", { values: { 'thema' => 'Bienen' } })

    body = JSON.parse(last_response.body)
    refute body['complete'], 'the interface has to be able to block copying'
    assert_equal ['ziel'], body['missing_required'], 'and to mark the right field'
    assert_includes body['text'], 'Bienen', 'the preview still appears'

    csrf(:post, "#{prefix}/prompts/#{id}/render",
         { values: { 'thema' => 'Bienen', 'ziel' => 'Einsteiger' } })
    assert JSON.parse(last_response.body)['complete']
  end

  # --- SEC-09: the log records what the document says it records ------------

  # The list in SEC-09 is a lower bound, so this test cannot be complete
  # either — but it can be systematic about the events that exist today, and
  # it names the ones that arrive with later packages rather than leaving them
  # unmentioned.
  LOGGED = {
    PromptAtelier::Audit::LOGIN_SUCCEEDED => :sign_in,
    PromptAtelier::Audit::LOGIN_FAILED    => :failed_login,
    PromptAtelier::Audit::LOGOUT          => :logout,
    'user.created'         => :create_account,
    'user.instance_admin_changed' => :grant_flag,
    'workspace.created'    => :create_workspace,
    'workspace.renamed'    => :rename_workspace,
    'workspace.deleted'    => :delete_workspace,
    'membership.added'     => :add_member,
    'membership.role_changed' => :change_role,
    'membership.removed'   => :remove_member,
    'prompt.purged'        => :purge_prompt,
    'import.completed'     => :import_file,
    'user.locked'          => :lock_account,
    'user.unlocked'        => :unlock_account,
    'user.password_reset'  => :reset_password,
    'user.deleted'         => :delete_account,
    'self_disclosure.requested' => :request_disclosure,
    PromptAtelier::Audit::USER_REGISTERED => :register_account,
    PromptAtelier::Audit::USER_APPROVED   => :approve_account,
    PromptAtelier::Audit::PROFILE_CHANGED => :change_own_profile,
    # Both were being recorded all along and neither was in this list — found
    # by the check below, which compares the filter of FA-908 against what the
    # application actually writes.
    PromptAtelier::Audit::PASSWORD_CHANGED => :change_own_password,
    'prompt.exported'      => :export_workspace,
    PromptAtelier::Audit::SETTINGS_CHANGED => :change_a_setting
  }.freeze

  # Events SEC-09 demands whose feature is not built yet. Listed rather than
  # omitted: a forgotten entry and a deliberately deferred one look identical
  # in a coverage count, and only one of them is acceptable.
  # Everything SEC-09 names now exists. The list stays as an empty constant
  # rather than being deleted: the next package that defers an event has a
  # place to put it, and the check below keeps the count honest.
  STILL_TO_COME = [].freeze
  DEFERRED_COUNT = STILL_TO_COME.size

  # The fixture is rebuilt before every trigger. Some of them destroy what the
  # next one needs — deleting the workspace ahead of adding a member — and
  # without the rebuild the test would report a missing log entry where the
  # request had simply been refused with 404 (test concept 4).
  def test_sec09_every_documented_event_that_can_happen_today_is_recorded
    LOGGED.each do |action, trigger|
      rebuild
      with_app_db { |db| db[:audit_logs].delete }
      send(trigger)

      recorded = with_app_db { |db| db[:audit_logs].select_map(:action) }
      assert_includes recorded, action, "#{trigger} must leave #{action} in the log"
    end
  end

  def test_sec09_an_audit_entry_carries_who_what_and_when
    with_app_db { |db| db[:audit_logs].delete }
    create_workspace

    entry = with_app_db { |db| db[:audit_logs].first(action: 'workspace.created') }
    refute_nil entry[:actor_id]
    refute_nil entry[:actor_name], 'the name stays even if the account is deleted later (SEC-17)'
    refute_nil entry[:created_at]
    refute_nil entry[:ip]
  end

  # The counter-check: this test is only worth anything because an event that
  # is *not* recorded makes it fail. Without it a broken Audit.record would
  # pass unnoticed.
  def test_the_log_is_not_simply_full_of_everything
    with_app_db { |db| db[:audit_logs].delete }
    sign_in(:sabine)
    get "#{prefix}/prompts?workspace_id=#{marketing}"

    recorded = with_app_db { |db| db[:audit_logs].select_map(:action) }
    assert_equal [PromptAtelier::Audit::LOGIN_SUCCEEDED], recorded, 'reading is not an audited event'
  end

  def test_the_deferred_events_are_named_rather_than_forgotten
    assert_equal DEFERRED_COUNT, STILL_TO_COME.size,
                 'when a package adds one of these, it moves into LOGGED'
  end

  # --- the filter list of FA-908 against the events that exist --------------
  #
  # Both directions, because both go wrong quietly. An event missing from the
  # list cannot be filtered for at all; a name in the list that nothing ever
  # writes offers a choice that always answers "nothing found", and the reader
  # concludes it never happened.
  def test_the_filter_offers_every_event_the_application_writes
    missing = LOGGED.keys - PromptAtelier::Audit::ACTIONS
    assert_empty missing, 'FA-908 cannot filter for what it does not list'
  end

  def test_the_filter_lists_no_event_that_nothing_writes
    # The two beside the recorded ones: setup happens before there is anybody
    # to look, the console reset happens outside the application (BT-13), and
    # the collapsed entry is written by the flood protection rather than by an
    # action of a user.
    beyond = %w[setup.completed password.reset_by_console] +
             [PromptAtelier::Audit::LOGIN_FAILED_MANY]

    phantoms = PromptAtelier::Audit::ACTIONS - LOGGED.keys - beyond - STILL_TO_COME
    assert_empty phantoms, 'a choice that can never match reads as "it never happened"'
  end

  private

  def prefix = PromptAtelier::App::API_PREFIX
  def marketing = @ids[:workspaces][:marketing]
  def prompt(label) = @ids[:prompts][label]
  def with_app_db(&block) = PromptAtelier::Database.open(database_path(@dir), &block)

  def rebuild
    PromptAtelier::App.reset!
    @dir = migrated_dir("completeness-#{SecureRandom.hex(4)}")
    PromptAtelier::App.boot!(root: @dir)
    PromptAtelier::RateLimit.reset!
    @ids = with_app_db { |db| PromptAtelier::Fixture.build(db) }
  end

  # --- the triggers of the audit table --------------------------------------

  # Without clearing the cookies first this arrives as a login on an existing
  # session, which needs a CSRF token and is refused before the credentials
  # are ever looked at — so nothing would be recorded and the test would
  # report a missing log entry that is not missing.
  def failed_login
    clear_cookies
    post "#{prefix}/auth/login",
         JSON.generate(email: 'owner@test', password: 'ganz-sicher-falsch-aber-lang'),
         'CONTENT_TYPE' => 'application/json'
    assert_equal 401, last_response.status
  end

  def logout
    sign_in(:sabine)
    csrf(:post, "#{prefix}/auth/logout")
  end

  def create_account
    sign_in(:thomas)
    csrf(:post, "#{prefix}/admin/users", { name: 'Neu', email: 'neu@example.test' })
  end

  # Registration is switched off in the delivered configuration (FA-107), so
  # these two go through the service rather than through a boot with a second
  # configuration — the endpoint has its own suite.
  def register_account
    with_app_db do |db|
      PromptAtelier::Registration.register(
        db, name: 'Nina', email: 'nina@example.test',
            password: PromptAtelier::Fixture::PASSWORD, ip: '203.0.113.9',
            config: { 'security.registration' => 'approval' }
      )
    end
  end

  def approve_account
    register_account
    nina = with_app_db { |db| db[:users].where(email: 'nina@example.test').first }
    sign_in(:thomas)
    csrf(:post, "#{prefix}/admin/users/#{nina[:id]}/approve")
  end

  def change_own_profile
    sign_in(:sabine)
    csrf(:put, "#{prefix}/auth/me", { name: 'Sabine Neu', email: 'owner@test' })
  end

  def change_own_password
    sign_in(:sabine)
    csrf(:post, "#{prefix}/auth/password",
         { current_password: PromptAtelier::Fixture::PASSWORD,
           new_password: 'Ein-anderes-Passwort-2026!' })
  end

  def export_workspace
    sign_in(:sabine)
    csrf(:post, "#{prefix}/export", { workspace_id: marketing })
  end

  def change_a_setting
    sign_in(:thomas)
    csrf(:put, "#{prefix}/admin/settings", { settings: { 'retention.trash_days' => 45 } })
  end

  def grant_flag
    sign_in(:thomas)
    csrf(:put, "#{prefix}/admin/users/#{@ids[:users][:sabine]}", { is_instance_admin: true })
  end

  def create_workspace
    sign_in(:sabine)
    csrf(:post, "#{prefix}/workspaces", { name: 'Ein neuer Workspace' })
  end

  def rename_workspace
    sign_in(:sabine)
    csrf(:put, "#{prefix}/workspaces/#{marketing}", { name: 'Anders' })
  end

  def delete_workspace
    sign_in(:sabine)
    csrf(:delete, "#{prefix}/workspaces/#{marketing}")
  end

  def add_member
    sign_in(:sabine)
    csrf(:post, "#{prefix}/workspaces/#{marketing}/members",
         { user_id: @ids[:users][:joerg], role: 'viewer' })
  end

  def change_role
    sign_in(:sabine)
    csrf(:put, "#{prefix}/workspaces/#{marketing}/members/#{@ids[:users][:martin]}", { role: 'admin' })
  end

  def remove_member
    sign_in(:sabine)
    csrf(:delete, "#{prefix}/workspaces/#{marketing}/members/#{@ids[:users][:lisa]}")
  end

  def purge_prompt
    sign_in(:anna)
    csrf(:delete, "#{prefix}/trash/#{prompt('P-DEL')}")
  end

  def lock_account
    sign_in(:thomas)
    csrf(:post, "#{prefix}/admin/users/#{@ids[:users][:martin]}/lock")
  end

  def unlock_account
    sign_in(:thomas)
    csrf(:post, "#{prefix}/admin/users/#{@ids[:users][:martin]}/lock")
    csrf(:post, "#{prefix}/admin/users/#{@ids[:users][:martin]}/unlock")
  end

  def reset_password
    sign_in(:thomas)
    csrf(:post, "#{prefix}/admin/users/#{@ids[:users][:martin]}/reset-password")
  end

  def delete_account
    sign_in(:thomas)
    csrf(:delete, "#{prefix}/admin/users/#{@ids[:users][:martin]}", { prompts_action: 'delete' })
  end

  def request_disclosure
    sign_in(:martin)
    get "#{prefix}/auth/me/data-export"
  end

  def import_file
    sign_in(:sabine)
    csrf(:post, "#{prefix}/import", {
           workspace_id: marketing,
           content: JSON.generate({ 'format' => 'promptatelier-export', 'version' => 1,
                                    'prompts' => [{ 'title' => 'Eingespielt', 'body' => 'Text.' }] })
         })
  end

  def sign_in(person = :sabine)
    clear_cookies
    post "#{prefix}/auth/login",
         JSON.generate(email: PromptAtelier::Fixture::PEOPLE[person][:email],
                       password: PromptAtelier::Fixture::PASSWORD),
         'CONTENT_TYPE' => 'application/json'
    assert_equal 200, last_response.status, "could not sign in as #{person}"
  end

  def csrf_token = rack_mock_session.cookie_jar[PromptAtelier::Sessions::CSRF_COOKIE_NAME]

  def csrf(method, path, payload = nil)
    send(method, path, payload.nil? ? '' : JSON.generate(payload),
         'CONTENT_TYPE' => 'application/json', 'HTTP_X_CSRF_TOKEN' => csrf_token.to_s)
  end
end
