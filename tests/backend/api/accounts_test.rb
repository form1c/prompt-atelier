# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'app'

# Account administration over HTTP (FA-901 to FA-906, SEC-15, SEC-17, SEC-18).
#
# ⚠ Several cases here destroy what others need — TF-409 deletes an account,
# TF-651 another. The fixture is rebuilt before every test (test concept 4), so
# the order of execution decides nothing.
class AccountsTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  def app = PromptAtelier::App

  def setup
    super
    @dir = migrated_dir('accounts')
    PromptAtelier::App.boot!(root: @dir)
    PromptAtelier::RateLimit.reset!
    @ids = with_app_db { |db| PromptAtelier::Fixture.build(db) }
  end

  def teardown
    PromptAtelier::App.reset!
    PromptAtelier::RateLimit.reset!
    super
  end

  # --- FA-906: the list -----------------------------------------------------

  def test_fa906_the_list_carries_what_the_overview_shows
    sign_in(:thomas)
    get "#{prefix}/admin/users"

    martin = accounts.find { |entry| entry['name'] == 'Martin' }
    assert_equal 'editor@test', martin['email']
    assert_equal 'active', martin['status']
    # The two counts are what the deletion dialogue of FA-904 asks about a
    # moment later — answered in advance.
    assert_operator martin['prompt_count'], :>, 0
    assert_operator martin['workspace_count'], :>, 0
    refute martin.key?('password_hash'), 'never, on any path'
  end

  def test_fa906_the_list_is_searchable_by_name_and_address
    sign_in(:thomas)

    get "#{prefix}/admin/users?q=martin"
    assert_equal %w[Martin], accounts.map { |entry| entry['name'] }

    get "#{prefix}/admin/users?q=WSADMIN@"
    assert_equal %w[Anna], accounts.map { |entry| entry['name'] }, 'and without regard to case'
  end

  def test_the_list_belongs_to_the_instance_administrator
    sign_in(:sabine)
    get "#{prefix}/admin/users"

    assert_equal 403, last_response.status
  end

  # --- FA-902 and TF-410: locking ------------------------------------------

  # The two halves of the requirement, and the second is the one that is easy
  # to forget: the person is locked out, the work stays where it is.
  def test_tf410_locking_discards_the_sessions_and_leaves_the_prompts_alone
    martins_session = sign_in(:martin)
    prompts_before = with_app_db { |db| db[:prompts].where(owner_id: @ids[:users][:martin]).count }

    sign_in(:thomas)
    csrf(:post, "#{prefix}/admin/users/#{@ids[:users][:martin]}/lock")
    assert_equal 200, last_response.status

    with_app_db do |db|
      assert_equal 'locked', db[:users][id: @ids[:users][:martin]][:status]
      assert_equal 0, db[:sessions].where(user_id: @ids[:users][:martin]).count, 'SEC-15'
      assert_equal prompts_before, db[:prompts].where(owner_id: @ids[:users][:martin]).count
    end
    refute_nil martins_session, 'he had one, which is what made the check above worth making'

    # And a locked account cannot sign in again (FA-902).
    clear_cookies
    post "#{prefix}/auth/login",
         JSON.generate(email: 'editor@test', password: PromptAtelier::Fixture::PASSWORD),
         'CONTENT_TYPE' => 'application/json'
    assert_equal 401, last_response.status
  end

  def test_a_locked_account_can_be_unlocked_again
    sign_in(:thomas)
    csrf(:post, "#{prefix}/admin/users/#{@ids[:users][:martin]}/lock")
    csrf(:post, "#{prefix}/admin/users/#{@ids[:users][:martin]}/unlock")

    assert_equal 200, last_response.status
    with_app_db { |db| assert_equal 'active', db[:users][id: @ids[:users][:martin]][:status] }
  end

  # FA-905 by a side door: locking the last instance administrator would leave
  # nobody who can administer the instance, and it would do it without ever
  # touching the flag.
  def test_the_last_instance_administrator_cannot_be_locked_out
    sign_in(:thomas)
    csrf(:post, "#{prefix}/admin/users/#{@ids[:users][:thomas]}/lock")

    assert_equal 403, last_response.status
    with_app_db { |db| assert_equal 'active', db[:users][id: @ids[:users][:thomas]][:status] }
  end

  # --- FA-903: resetting a password ----------------------------------------

  def test_fa903_a_reset_yields_a_one_time_password_and_forces_a_change
    sign_in(:martin)
    sign_in(:thomas)
    csrf(:post, "#{prefix}/admin/users/#{@ids[:users][:martin]}/reset-password")

    assert_equal 200, last_response.status
    initial = JSON.parse(last_response.body)['initial_password']
    refute_nil initial
    assert_operator initial.length, :>=, 16

    with_app_db do |db|
      assert db[:users][id: @ids[:users][:martin]][:must_change_pw]
      assert_equal 0, db[:sessions].where(user_id: @ids[:users][:martin]).count, 'SEC-15'
    end

    # The new password works, and the old one does not.
    clear_cookies
    post "#{prefix}/auth/login", JSON.generate(email: 'editor@test', password: initial),
         'CONTENT_TYPE' => 'application/json'
    assert_equal 200, last_response.status

    clear_cookies
    post "#{prefix}/auth/login",
         JSON.generate(email: 'editor@test', password: PromptAtelier::Fixture::PASSWORD),
         'CONTENT_TYPE' => 'application/json'
    assert_equal 401, last_response.status
  end

  # --- FA-904 and TF-409: deleting -----------------------------------------

  def test_tf409_deleting_with_the_prompts
    sign_in(:thomas)
    csrf_delete("#{prefix}/admin/users/#{@ids[:users][:martin]}", { prompts_action: 'delete' })

    assert_equal 200, last_response.status, last_response.body

    # **Is the application even writing where this test is reading?**
    #
    # AP-21: this case failed now and then with a 200 over a row that was still
    # there — a successful answer about a deletion that had not happened. One
    # explanation covers every observation: `App.database` is memoised and
    # `boot!` does not replace it, so an instance booted earlier keeps its old
    # file. The fixture has the same ids in every database, so the sign-in
    # works, the deletion happens — somewhere else — and the answer is 200.
    #
    # Checked here rather than reasoned about, because the two databases are
    # indistinguishable by their content.
    assert_equal database_path(@dir), PromptAtelier::App.database.opts[:database],
                 'the application is writing to a different database than this test reads'

    with_app_db do |db|
      assert_nil db[:users][id: @ids[:users][:martin]]
      assert_equal 0, db[:prompts].where(owner_id: @ids[:users][:martin]).count
    end
  end

  # The other branch of the same requirement. What makes it more than a change
  # of owner: the successor has to end up able to **see** what he inherited.
  #
  # The successor is **Jörg**, who is not a member of *Marketing*. With Anna,
  # who is one already, the membership check passes whether or not anything
  # adds it — a mutation probe walked straight through the first version of
  # this test.
  def test_tf409_deleting_and_transferring_the_prompts
    sign_in(:thomas)
    with_app_db do |db|
      assert_nil PromptAtelier::Workspaces.membership(db, marketing, @ids[:users][:joerg]),
                 'the premise: he is a stranger to that workspace'
    end

    csrf_delete("#{prefix}/admin/users/#{@ids[:users][:martin]}",
                { prompts_action: 'transfer', successor_id: @ids[:users][:joerg] })

    assert_equal 200, last_response.status, last_response.body
    with_app_db do |db|
      assert_nil db[:users][id: @ids[:users][:martin]]
      inherited = db[:prompts].where(owner_id: @ids[:users][:joerg], title: 'P-EDIT').first
      refute_nil inherited
      refute_nil PromptAtelier::Workspaces.membership(db, inherited[:workspace_id], @ids[:users][:joerg]),
                 'an inherited prompt he cannot see is inherited in name only'
    end
  end

  # A prompt in the deleted account's personal workspace has nowhere to stay —
  # that workspace goes with the account (FA-606). It moves into the
  # successor's own, which is the one place he is certain to be able to write.
  def test_a_prompt_from_the_personal_workspace_moves_to_the_successors_own
    personal = @ids[:workspaces][:personal_martin]
    id = with_app_db do |db|
      PromptAtelier::Prompts.create(db, workspace_id: personal, owner_id: @ids[:users][:martin],
                                        attributes: { 'title' => 'Ganz privat', 'body' => 'Text.' })
    end

    sign_in(:thomas)
    csrf_delete("#{prefix}/admin/users/#{@ids[:users][:martin]}",
                { prompts_action: 'transfer', successor_id: @ids[:users][:anna] })
    assert_equal 200, last_response.status, last_response.body

    with_app_db do |db|
      assert_equal @ids[:workspaces][:personal_anna], db[:prompts][id: id][:workspace_id]
      assert_nil db[:workspaces][id: personal], 'the personal workspace goes with the account (FA-606)'
    end
  end

  def test_deleting_without_saying_what_happens_to_the_prompts_is_refused
    sign_in(:thomas)
    csrf_delete("#{prefix}/admin/users/#{@ids[:users][:martin]}")

    assert_equal 422, last_response.status
    with_app_db { |db| refute_nil db[:users][id: @ids[:users][:martin]] }
  end

  def test_transferring_to_nobody_is_refused
    sign_in(:thomas)
    csrf_delete("#{prefix}/admin/users/#{@ids[:users][:martin]}", { prompts_action: 'transfer' })

    assert_equal 422, last_response.status
    with_app_db { |db| refute_nil db[:users][id: @ids[:users][:martin]] }
  end

  # --- SEC-17, TF-520 and TF-651: what a deletion leaves behind ------------

  # The audit trail survives the person. Administrative acts have to stay
  # readable, and a name is what makes them so — but the link to the account
  # is gone.
  def test_tf520_and_tf651_the_audit_trail_keeps_the_name_and_loses_the_link
    sign_in(:martin)
    with_app_db do |db|
      db[:favorites].insert(user_id: @ids[:users][:martin], prompt_id: @ids[:prompts]['P-WS'],
                            created_at: Time.now)
    end

    sign_in(:thomas)
    csrf(:post, "#{prefix}/admin/users/#{@ids[:users][:martin]}/lock")
    csrf_delete("#{prefix}/admin/users/#{@ids[:users][:martin]}", { prompts_action: 'delete' })

    with_app_db do |db|
      entries = db[:audit_logs].where(actor_name: 'Martin').all
      refute_empty entries, 'he did things, and they stay on record'
      assert(entries.all? { |entry| entry[:actor_id].nil? }, 'the link to the account is gone')

      assert_equal 0, db[:sessions].where(user_id: @ids[:users][:martin]).count
      assert_equal 0, db[:favorites].where(user_id: @ids[:users][:martin]).count
      assert_equal 0, db[:memberships].where(user_id: @ids[:users][:martin]).count
    end
  end

  # --- SEC-18 and TF-650: the self-disclosure ------------------------------

  def test_tf650_the_disclosure_carries_what_sec18_lists
    sign_in(:martin)
    get "#{prefix}/auth/me/data-export"

    assert_equal 200, last_response.status
    disclosure = JSON.parse(last_response.body)['disclosure']

    assert_equal 'editor@test', disclosure.dig('account', 'email')
    refute disclosure['account'].key?('password_hash')
    assert(disclosure['memberships'].any? { |entry| entry['role'] == 'editor' })
    assert(disclosure['prompts'].any? { |entry| entry['title'] == 'P-EDIT' })
    assert(disclosure['prompts'].all? { |entry| entry.key?('body') }, 'with the content, not just titles')
    assert_kind_of Array, disclosure['favorites']
    assert(disclosure['audit_entries'].any? { |entry| entry['action'] == PromptAtelier::Audit::LOGIN_SUCCEEDED })
  end

  def test_tf650_the_disclosure_is_itself_recorded
    sign_in(:martin)
    with_app_db { |db| db[:audit_logs].delete }
    get "#{prefix}/auth/me/data-export"

    with_app_db do |db|
      refute_nil db[:audit_logs].first(action: 'self_disclosure.requested')
    end
  end

  # TF-650b, the counter-check: there is no administrative way to somebody
  # else's data. Chapter 6.2 promises it, and an endpoint for it would undo
  # the promise in one line.
  def test_tf650b_there_is_no_disclosure_endpoint_for_a_foreign_account
    sign_in(:thomas)

    ["#{prefix}/admin/users/#{@ids[:users][:martin]}/data-export",
     "#{prefix}/auth/me/data-export?user_id=#{@ids[:users][:martin]}"].each do |path|
      get path
      next assert_equal 404, last_response.status if path.include?('admin')

      # The second is not a 404 — it is the administrator's **own** data. The
      # parameter is ignored, which is the point.
      assert_equal 'admin@test', JSON.parse(last_response.body).dig('disclosure', 'account', 'email')
    end
  end

  # --- FA-106: the profile --------------------------------------------------

  def test_fa106_name_and_address_can_be_changed_and_the_session_survives
    sign_in(:martin)
    csrf(:put, "#{prefix}/auth/me", { name: 'Martin M.', email: 'martin.neu@example.test' })

    assert_equal 200, last_response.status
    # A changed address hands access to nobody, so the sessions stay (15.3).
    get "#{prefix}/auth/me"
    assert_equal 200, last_response.status
    assert_equal 'Martin M.', JSON.parse(last_response.body).dig('user', 'name')
  end

  def test_fa106_an_address_somebody_else_already_holds_is_refused
    sign_in(:martin)
    csrf(:put, "#{prefix}/auth/me", { name: 'Martin', email: 'owner@test' })

    assert_equal 422, last_response.status
    with_app_db { |db| assert_equal 'editor@test', db[:users][id: @ids[:users][:martin]][:email] }
  end

  # Two counter-checks in one, and both are about saving a form unchanged.
  #
  # Keeping one's own address must not collide with oneself — and it must not
  # fall over the format check either: `editor@test` has no dot in the domain
  # and `valid_email?` refuses it. Somebody carrying such an address could
  # otherwise never change so much as their name. Found while writing this
  # test; the format is now checked on a **changed** address only.
  def test_fa106_keeping_ones_own_address_is_not_a_collision
    sign_in(:martin)
    csrf(:put, "#{prefix}/auth/me", { name: 'Martin M.', email: 'editor@test' })

    assert_equal 200, last_response.status, last_response.body
    with_app_db { |db| assert_equal 'Martin M.', db[:users][id: @ids[:users][:martin]][:name] }
  end

  # And the check still bites where it is meant to: a new address that is not
  # one.
  def test_fa106_a_new_address_still_has_to_look_like_one
    sign_in(:martin)
    csrf(:put, "#{prefix}/auth/me", { name: 'Martin', email: 'kein-at-zeichen' })

    assert_equal 422, last_response.status
  end

  private

  def prefix = PromptAtelier::App::API_PREFIX
  def marketing = @ids[:workspaces][:marketing]
  def with_app_db(&block) = PromptAtelier::Database.open(database_path(@dir), &block)
  def accounts = JSON.parse(last_response.body)['users']

  def sign_in(person)
    clear_cookies
    post "#{prefix}/auth/login",
         JSON.generate(email: PromptAtelier::Fixture::PEOPLE[person][:email],
                       password: PromptAtelier::Fixture::PASSWORD),
         'CONTENT_TYPE' => 'application/json'
    assert_equal 200, last_response.status, "could not sign in as #{person}"
    rack_mock_session.cookie_jar[PromptAtelier::Sessions::COOKIE_NAME]
  end

  def csrf_token = rack_mock_session.cookie_jar[PromptAtelier::Sessions::CSRF_COOKIE_NAME]

  def csrf(method, path, payload = nil)
    send(method, path, payload.nil? ? '' : JSON.generate(payload),
         'CONTENT_TYPE' => 'application/json', 'HTTP_X_CSRF_TOKEN' => csrf_token.to_s)
  end

  def csrf_delete(path, payload = nil) = csrf(:delete, path, payload)
end
