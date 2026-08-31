# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'app'

# Self-registration and approval over HTTP (FA-107, FA-101, FA-906).
class RegistrationApiTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  def app = PromptAtelier::App

  def setup
    super
    @dir = migrated_dir('registration-api')
    boot(mode: 'off')
    @ids = with_app_db { |db| PromptAtelier::Fixture.build(db) }
  end

  def teardown
    PromptAtelier::App.reset!
    PromptAtelier::RateLimit.reset!
    super
  end

  # --- what the login screen asks -------------------------------------------

  def test_the_login_screen_is_told_whether_there_is_a_way_in
    get "#{prefix}/auth/registration"
    assert_equal 200, last_response.status
    refute registration['enabled'], 'delivered switched off'

    boot(mode: 'approval')
    get "#{prefix}/auth/registration"
    assert registration['enabled']
    assert registration['approval_required']

    boot(mode: 'open')
    get "#{prefix}/auth/registration"
    assert registration['enabled']
    refute registration['approval_required']
  end

  # --- switched off ---------------------------------------------------------

  # The screen offers no button, so this is a caller who went round it.
  def test_switched_off_the_endpoint_refuses_and_creates_nothing
    before = with_app_db { |db| db[:users].count }

    post_json "#{prefix}/auth/register", name: 'Neu', email: 'neu@example.test',
                                         password: PromptAtelier::Fixture::PASSWORD

    assert_equal 403, last_response.status
    assert_equal before, with_app_db { |db| db[:users].count }
  end

  # --- with approval (the recommended setting) ------------------------------

  def test_with_approval_the_account_waits_and_is_not_signed_in
    boot(mode: 'approval')

    post_json "#{prefix}/auth/register", name: 'Nina', email: 'nina@example.test',
                                         password: PromptAtelier::Fixture::PASSWORD

    assert_equal 201, last_response.status
    assert json['pending'], 'FA-107'
    refute json.key?('user'), 'no account details before the door is opened'

    # Not signed in: handing out a session that every following call refuses
    # would be worse than none at all.
    get "#{prefix}/auth/me"
    assert_equal 401, last_response.status
  end

  # The mistake this guards against: reusing "locked" for "waiting". Somebody
  # who registered a minute ago and reads that their account has been locked
  # looks for a fault of their own where there is none.
  def test_someone_waiting_is_told_they_are_waiting_and_not_that_they_are_locked
    boot(mode: 'approval')
    register('nina@example.test')

    post_json "#{prefix}/auth/login", email: 'nina@example.test',
                                      password: PromptAtelier::Fixture::PASSWORD

    assert_equal 401, last_response.status
    # The two must not be confused, and since AP-19 that is a question about
    # **codes**: the server sends no sentences at all, and the one this case
    # used to compare against came from a server-side table that has since
    # been removed for having no readers (AP-22).
    assert_equal 'account_pending', json['error']['code']
    refute_equal 'account_locked', json['error']['code']
  end

  def test_a_locked_account_still_reads_as_locked
    sign_in(:thomas)
    csrf(:post, "#{prefix}/admin/users/#{@ids[:users][:martin]}/lock")
    clear_cookies

    post_json "#{prefix}/auth/login", email: 'editor@test',
                                      password: PromptAtelier::Fixture::PASSWORD

    assert_equal 'account_locked', json['error']['code']
  end

  # --- the administrator's side (FA-906, FA-107) ----------------------------

  def test_whoever_waits_is_listed_first_and_marked_as_waiting
    boot(mode: 'approval')
    register('nina@example.test')

    sign_in(:thomas)
    get "#{prefix}/admin/users"

    # Sorted to the top, because without e-mail (E-13) nothing else tells the
    # administrator that somebody is waiting. "Nina" sorts between Martin and
    # Sabine by name, so the position proves the rule rather than the alphabet.
    assert_equal 'Nina', accounts.first['name']
    refute_nil accounts.first['pending_since']
    assert_nil accounts.find { |entry| entry['name'] == 'Martin' }['pending_since']
  end

  def test_approving_lets_the_person_in_and_is_recorded_under_its_own_name
    boot(mode: 'approval')
    register('nina@example.test')
    nina = with_app_db { |db| db[:users].where(email: 'nina@example.test').first }

    sign_in(:thomas)
    csrf(:post, "#{prefix}/admin/users/#{nina[:id]}/approve")
    assert_equal 200, last_response.status

    with_app_db do |db|
      row = db[:users][id: nina[:id]]
      assert_equal 'active', row[:status]
      assert_nil row[:pending_since], 'no longer waiting for anything'
      assert_equal 1, db[:audit_logs].where(action: PromptAtelier::Audit::USER_APPROVED).count
      assert_equal 0, db[:audit_logs].where(action: PromptAtelier::Audit::USER_UNLOCKED).count,
                   'admitting somebody is not the same act as lifting a lock'
    end

    clear_cookies
    post_json "#{prefix}/auth/login", email: 'nina@example.test',
                                      password: PromptAtelier::Fixture::PASSWORD
    assert_equal 200, last_response.status
  end

  # Two administrative acts, two buttons, two entries in the log. The row
  # change is the same, which is exactly why one endpoint for both would have
  # recorded the wrong reason.
  def test_unlocking_refuses_an_account_that_was_never_locked_by_anybody
    boot(mode: 'approval')
    register('nina@example.test')
    nina = with_app_db { |db| db[:users].where(email: 'nina@example.test').first }

    sign_in(:thomas)
    csrf(:post, "#{prefix}/admin/users/#{nina[:id]}/unlock")

    assert_equal 422, last_response.status
    assert_equal 'locked', with_app_db { |db| db[:users][id: nina[:id]][:status] }
  end

  def test_approving_refuses_an_account_that_is_not_waiting
    sign_in(:thomas)
    csrf(:post, "#{prefix}/admin/users/#{@ids[:users][:martin]}/approve")

    assert_equal 422, last_response.status
    assert_equal 'not_pending', json['error']['code']
  end

  def test_approving_belongs_to_the_instance_administrator
    boot(mode: 'approval')
    register('nina@example.test')
    nina = with_app_db { |db| db[:users].where(email: 'nina@example.test').first }

    sign_in(:sabine)
    csrf(:post, "#{prefix}/admin/users/#{nina[:id]}/approve")

    assert_equal 403, last_response.status
    assert_equal 'locked', with_app_db { |db| db[:users][id: nina[:id]][:status] }
  end

  # --- open registration ----------------------------------------------------

  def test_with_open_registration_the_newcomer_is_signed_in_at_once
    boot(mode: 'open')

    post_json "#{prefix}/auth/register", name: 'Otto', email: 'otto@example.test',
                                         password: PromptAtelier::Fixture::PASSWORD

    assert_equal 201, last_response.status
    refute json['pending']
    assert_equal 'Otto', json['user']['name']

    get "#{prefix}/auth/me"
    assert_equal 200, last_response.status, 'the session came with the answer'
  end

  # --- what the form refuses ------------------------------------------------

  # Answered honestly, which does tell a stranger that an address exists. The
  # alternative — "we have sent you an e-mail" — is a sentence this
  # application cannot make true (E-13), and it would leave an honest person
  # with a form that appears to work and never does. What limits the
  # enumeration instead is the hourly cap.
  #
  # Asked in the other case, too: the fixture addresses carry no dot in their
  # domain, so `valid_email?` refuses them before the question is even reached.
  def test_an_address_already_in_use_is_named_as_such
    boot(mode: 'open')
    register('zwilling@example.test')

    post_json "#{prefix}/auth/register", name: 'Zwilling', email: 'ZWILLING@Example.test',
                                         password: PromptAtelier::Fixture::PASSWORD

    assert_equal 422, last_response.status
    assert_equal 'email_taken', json['error']['fields']['email'],
                 'and without regard to case — the column is COLLATE NOCASE'
  end

  def test_the_password_rules_hold_here_too
    boot(mode: 'open')

    post_json "#{prefix}/auth/register", name: 'Kurz', email: 'kurz@example.test',
                                         password: 'kurz'

    assert_equal 422, last_response.status
    refute_nil json['error']['fields']['password']
    assert_equal 0, with_app_db { |db| db[:users].where(email: 'kurz@example.test').count }
  end

  def test_a_registration_that_fails_costs_nothing_from_the_hourly_budget
    boot(mode: 'open', per_hour: 2)

    3.times { post_json "#{prefix}/auth/register", name: 'X', email: 'x', password: 'kurz' }
    post_json "#{prefix}/auth/register", name: 'Gut', email: 'gut@example.test',
                                         password: PromptAtelier::Fixture::PASSWORD

    assert_equal 201, last_response.status,
                 'the meter counts accounts created, not forms filled in badly'
  end

  def test_too_many_accounts_from_one_address_are_refused_with_429
    boot(mode: 'open', per_hour: 1)
    register('erste@example.test')

    post_json "#{prefix}/auth/register", name: 'Zweite', email: 'zweite@example.test',
                                         password: PromptAtelier::Fixture::PASSWORD

    assert_equal 429, last_response.status
    assert_equal 0, with_app_db { |db| db[:users].where(email: 'zweite@example.test').count }
  end

  private

  def prefix = PromptAtelier::App::API_PREFIX
  def json = JSON.parse(last_response.body)
  def registration = json['registration']
  def accounts = json['users']
  def with_app_db(&block) = PromptAtelier::Database.open(database_path(@dir), &block)

  # Rewrites the configuration and starts the application over it. The two
  # settings are read at request time from the booted configuration, so a
  # test that wants a different mode has to go through here.
  def boot(mode:, per_hour: 20)
    PromptAtelier::App.reset!
    write_config(@dir, valid_config.merge(
                         'security' => { 'registration' => mode,
                                         'registrations_per_hour' => per_hour }
                       ))
    PromptAtelier::App.boot!(root: @dir)
    PromptAtelier::RateLimit.reset!
  end

  def register(email)
    post_json "#{prefix}/auth/register", name: email.split('@').first.capitalize,
                                         email: email, password: PromptAtelier::Fixture::PASSWORD
    assert_equal 201, last_response.status, "could not register #{email}"
    clear_cookies
  end

  def post_json(path, **payload)
    post path, JSON.generate(payload), 'CONTENT_TYPE' => 'application/json'
  end

  def sign_in(person)
    clear_cookies
    post_json "#{prefix}/auth/login", email: PromptAtelier::Fixture::PEOPLE[person][:email],
                                      password: PromptAtelier::Fixture::PASSWORD
    assert_equal 200, last_response.status, "could not sign in as #{person}"
  end

  def csrf_token = rack_mock_session.cookie_jar[PromptAtelier::Sessions::CSRF_COOKIE_NAME]

  def csrf(method, path, payload = nil)
    send(method, path, payload.nil? ? '' : JSON.generate(payload),
         'CONTENT_TYPE' => 'application/json', 'HTTP_X_CSRF_TOKEN' => csrf_token.to_s)
  end
end
