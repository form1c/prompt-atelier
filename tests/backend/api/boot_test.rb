# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'app'

# TF-660 — booting twice in one process (AP-21).
#
# **The defect this was written for.** `App.database` is memoised, and a second
# `boot!` used to keep the first connection. The configuration then named one
# installation while every read and write went to another, and nothing said so:
# `configuration.database_path` answered correctly, `database.opts[:database]`
# answered the old file, and the two were never compared.
#
# In a running instance this could not bite — `boot!` happens once. In a test
# process it turns a whole suite into an assertion about nothing, and it does
# it **silently**: the shipped fixture writes the same ids into every
# installation, so a sign-in succeeds against the wrong database, a deletion
# answers 200, and the row the test then looks at is untouched because it was
# never the row the application had.
#
# That is the shape of the sporadic failure AP-21 was opened for
# (`AccountsTest#test_tf409_deleting_with_the_prompts`: a 200 over a row that
# was still there). Whether it was the cause of every occurrence is not settled
# — but it is a way for exactly that to happen, and it is closed.
class BootTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  def app = PromptAtelier::App

  def teardown
    PromptAtelier::App.reset!
    super
  end

  def test_a_second_boot_uses_the_database_of_the_new_installation
    first = migrated_dir('boot-first')
    PromptAtelier::App.boot!(root: first)
    assert_equal database_path(first), PromptAtelier::App.database.opts[:database]

    # Deliberately without `reset!` in between — that is the whole point.
    second = migrated_dir('boot-second')
    PromptAtelier::App.boot!(root: second)

    assert_equal database_path(second), PromptAtelier::App.database.opts[:database],
                 'the application must write where its configuration points'
  end

  # And what the configuration says has to be the same thing. Two sources for
  # one fact is how they came apart in the first place.
  def test_the_configuration_and_the_connection_name_the_same_file
    dir = migrated_dir('boot-agree')
    PromptAtelier::App.boot!(root: dir)

    assert_equal PromptAtelier::App.configuration.database_path,
                 PromptAtelier::App.database.opts[:database]
  end

  # The counter-direction: booting again on the **same** installation must not
  # throw a healthy pool away. `boot!` is also how a configuration is reloaded.
  def test_booting_again_on_the_same_installation_keeps_the_connection
    dir = migrated_dir('boot-same')
    PromptAtelier::App.boot!(root: dir)
    before = PromptAtelier::App.database

    PromptAtelier::App.boot!(root: dir)

    assert_same before, PromptAtelier::App.database,
                'a connection to the same file is not stale and is not thrown away'
  end

  # The invariant the API suites rest on, said once here rather than hoped for
  # in each of them: what a test writes through `Database.open` and what the
  # application writes through its own pool land in one file.
  def test_a_direct_connection_sees_what_the_application_wrote
    dir = migrated_dir('boot-visible')
    PromptAtelier::App.boot!(root: dir)

    now = Time.now
    id = PromptAtelier::App.database[:workspaces].insert(
      name: 'Durchstich', slug: 'durchstich', created_at: now, updated_at: now
    )

    with_db(dir) do |db|
      refute_nil db[:workspaces][id: id],
                 'what the application wrote has to be there for a second connection'
    end
  end

  # --- the failure this package was opened for, built on purpose ------------

  # The four cases above pin the mechanism. This one pins the **symptom**, and
  # it is the difference between "a defect that could produce that" and "the
  # defect that produced it".
  #
  # Repeated runs could never settle it: the failure came three times in one
  # afternoon and then a dozen times not at all, so a green loop only fails to
  # refute. So the ordering a full run stumbles into by accident is built here
  # deliberately — and measured both ways. Without `drop_stale_connection` it
  # answers **200 over a row that is still there**, which is the recorded
  # failure word for word; with it, the row is gone.
  #
  # Three ingredients, and leaving any one out makes the symptom vanish:
  #
  #   1. an earlier installation that was **used**, not merely booted —
  #      `App.database` is memoised lazily, so a boot alone leaves no pool
  #      behind for the next one to keep
  #   2. a second `boot!` without `reset!`
  #   3. the shipped fixture, which writes the **same ids** into every
  #      installation, so the sign-in succeeds and the deletion finds its row
  #      — in the wrong database
  def test_a_deletion_lands_in_the_database_the_configuration_names
    first = migrated_dir('boot-symptom-first')
    PromptAtelier::App.boot!(root: first)
    with_db(first) { |db| PromptAtelier::Fixture.build(db) }
    get '/api/v1/health'
    refute_nil PromptAtelier::App.database, 'ingredient 1: the first instance has a pool'

    second = migrated_dir('boot-symptom-second')
    PromptAtelier::App.boot!(root: second)
    ids = with_db(second) { |db| PromptAtelier::Fixture.build(db) }
    PromptAtelier::RateLimit.reset!

    sign_in_as(:thomas)
    csrf_delete("/api/v1/admin/users/#{ids[:users][:martin]}", prompts_action: 'delete')

    assert_equal 200, last_response.status, last_response.body
    with_db(second) do |db|
      assert_nil db[:users][id: ids[:users][:martin]],
                 'a 200 about a deletion, and the row still there, is the failure of AP-21'
    end
  end

  private

  def sign_in_as(person)
    clear_cookies
    post '/api/v1/auth/login',
         JSON.generate(email: PromptAtelier::Fixture::PEOPLE[person][:email],
                       password: PromptAtelier::Fixture::PASSWORD),
         'CONTENT_TYPE' => 'application/json'
    assert_equal 200, last_response.status, "could not sign in as #{person}"
  end

  def csrf_delete(path, payload)
    token = rack_mock_session.cookie_jar[PromptAtelier::Sessions::CSRF_COOKIE_NAME]
    delete path, JSON.generate(payload),
           'CONTENT_TYPE' => 'application/json', 'HTTP_X_CSRF_TOKEN' => token.to_s
  end
end
