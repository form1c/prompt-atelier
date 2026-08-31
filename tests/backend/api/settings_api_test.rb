# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'app'

# Product settings over HTTP (FA-910).
#
# The one property everything else rests on is the last case here: a changed
# setting is in force on the **next request**. If it were not, this feature
# would need a restart button — and a restart button is exactly what an
# application must not have (see migrations/004_settings.rb).
class SettingsApiTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  def app = PromptAtelier::App

  def setup
    super
    @dir = migrated_dir('settings-api')
    PromptAtelier::App.boot!(root: @dir)
    PromptAtelier::RateLimit.reset!
    @ids = with_app_db { |db| PromptAtelier::Fixture.build(db) }
  end

  def teardown
    PromptAtelier::App.reset!
    PromptAtelier::RateLimit.reset!
    super
  end

  def test_the_settings_belong_to_the_instance_administrator
    sign_in(:sabine)
    get "#{prefix}/admin/settings"
    assert_equal 403, last_response.status

    csrf(:put, "#{prefix}/admin/settings", { settings: { 'retention.trash_days' => 45 } })
    assert_equal 403, last_response.status
    assert_equal 0, with_app_db { |db| db[:settings].count }
  end

  def test_the_list_carries_the_current_value_and_where_it_comes_from
    sign_in(:thomas)
    get "#{prefix}/admin/settings"

    trash = setting('retention.trash_days')
    assert_equal 30, trash['value'], 'the shipped default'
    assert trash['from_file']
    assert_equal 'positive_integer', trash['kind'], 'so the screen knows what control to draw'

    mode = setting('security.registration')
    assert_equal %w[off approval open], mode['choices'],
                 'a choice with three values, not two switches'
  end

  # Not one operating value is offered. Whoever could widen `trusted_proxies`
  # from here would disable the login limit and could write any address into
  # the very log this screen shows.
  def test_no_operating_value_is_offered
    sign_in(:thomas)
    get "#{prefix}/admin/settings"

    keys = json['settings'].map { |entry| entry['key'] }
    refute_includes keys, 'server.trusted_proxies'
    refute_includes keys, 'server.port'
    refute_includes keys, 'database.path'
  end

  def test_a_change_is_recorded_with_its_values
    sign_in(:thomas)
    csrf(:put, "#{prefix}/admin/settings", { settings: { 'retention.trash_days' => 45 } })

    assert_equal 200, last_response.status
    entry = with_app_db do |db|
      db[:audit_logs].where(action: PromptAtelier::Audit::SETTINGS_CHANGED).first
    end
    refute_nil entry, 'who may register and how long things are kept is worth looking up later'
    assert_equal 45, JSON.parse(entry[:meta_json])['retention.trash_days']
  end

  def test_a_refused_value_is_answered_per_field_and_writes_nothing
    sign_in(:thomas)
    csrf(:put, "#{prefix}/admin/settings", { settings: { 'retention.trash_days' => 0 } })

    assert_equal 422, last_response.status
    refute_nil json['error']['fields']['retention.trash_days']
    assert_equal 0, with_app_db { |db| db[:settings].count }
  end

  # The property the whole design rests on. `security.registration` is `off`
  # in the delivered configuration; after the change the very next request has
  # to behave differently — without anything being restarted.
  def test_a_changed_setting_is_in_force_on_the_next_request
    post_json "#{prefix}/auth/register", name: 'Nina', email: 'nina@example.test',
                                         password: PromptAtelier::Fixture::PASSWORD
    assert_equal 403, last_response.status, 'the premise: registration is off'

    sign_in(:thomas)
    csrf(:put, "#{prefix}/admin/settings", { settings: { 'security.registration' => 'open' } })
    assert_equal 200, last_response.status
    clear_cookies

    post_json "#{prefix}/auth/register", name: 'Nina', email: 'nina@example.test',
                                         password: PromptAtelier::Fixture::PASSWORD

    assert_equal 201, last_response.status,
                 'no restart — the configuration is read on every request'
  end

  # The same for a limit, so the case above is not the only path through the
  # layer: the login limit comes from the same lookup.
  def test_a_changed_limit_takes_effect_without_a_restart
    sign_in(:thomas)
    csrf(:put, "#{prefix}/admin/settings", { settings: { 'security.login_attempts_per_account' => 1 } })
    clear_cookies

    2.times do
      post_json "#{prefix}/auth/login", email: 'editor@test', password: 'ganz-sicher-falsch'
    end

    assert_equal 'too_many_attempts', json['error']['code'],
                 'the second attempt already hits the new limit'
    assert_equal 15, json['error']['params']['minutes'], 'and the sentence gets the new number'
  end

  private

  def prefix = PromptAtelier::App::API_PREFIX
  def json = JSON.parse(last_response.body)
  def setting(key) = json['settings'].find { |entry| entry['key'] == key }
  def with_app_db(&block) = PromptAtelier::Database.open(database_path(@dir), &block)

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
