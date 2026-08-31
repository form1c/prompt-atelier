# frozen_string_literal: true

require_relative '../../test_helper'
require 'app'

# TF-623 / TF-430 and TF-624 / TF-431 — the start lock from Requirements 18.9.
#
# Both directions matter, and the second is the one that is easy to leave out:
# a database *newer* than the code means someone rolled the application back.
# The old code does not know the newer columns, writes rows without them, and
# nothing errors out. The loss would only show up much later, in data.
class SchemaGuardTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  def app
    PromptAtelier::App
  end

  def teardown
    PromptAtelier::App.reset!
    super
  end

  # --- TF-623 / TF-430: database older than the code -----------------------

  def test_tf623_an_unmigrated_database_refuses_to_start
    dir = install_dir('too_old')
    write_config(dir, valid_config)

    error = assert_raises(PromptAtelier::SchemaGuard::Mismatch) do
      PromptAtelier::App.boot!(root: dir)
    end

    assert_equal :too_old, error.kind
    assert_match(/migrate/i, error.message, 'the message must say what to do')
  end

  def test_tf623_a_database_missing_a_later_step_refuses_to_start
    dir = migrated_dir('missing_step')
    with_db(dir) { |db| db[:schema_migrations].delete }

    error = assert_raises(PromptAtelier::SchemaGuard::Mismatch) do
      PromptAtelier::App.boot!(root: dir)
    end

    assert_equal :too_old, error.kind
  end

  # --- TF-624 / TF-431: database newer than the code -----------------------

  def test_tf624_a_database_with_unknown_steps_refuses_to_start
    dir = migrated_dir('too_new')
    with_db(dir) do |db|
      db[:schema_migrations].insert(version: '999_from_the_future', applied_at: Time.now)
    end

    error = assert_raises(PromptAtelier::SchemaGuard::Mismatch) do
      PromptAtelier::App.boot!(root: dir)
    end

    assert_equal :too_new, error.kind
    assert_match(/999_from_the_future/, error.message, 'the message must name the unknown step')
    refute_match(/migrate/i, error.message,
                 'running migrate would not help here and must not be suggested')
  end

  # --- the good case -------------------------------------------------------

  def test_a_migrated_database_starts_and_reports_its_schema_state
    dir = migrated_dir('good')

    PromptAtelier::App.boot!(root: dir)

    # The newest shipped step, read from the directory. Written out here it
    # would have to be edited with every migration — and be edited without
    # being read.
    assert_equal PromptAtelier::Migration.all(migrations_dir).last.version,
                 PromptAtelier::App.schema_version
  end

  # --- /health now covers the database (15.3) ------------------------------

  def test_health_is_ok_on_a_migrated_database
    dir = migrated_dir('health_ok')
    PromptAtelier::App.boot!(root: dir)

    get '/health'

    assert_equal 200, last_response.status
    assert_equal({ 'status' => 'ok' }, JSON.parse(last_response.body))
  end

  # The database can disappear while the application runs — a wrong path in a
  # changed configuration, a mount that went away. /health has to notice, and
  # it has to answer rather than crash.
  def test_health_reports_503_when_the_database_is_gone
    dir = migrated_dir('health_gone')
    PromptAtelier::App.boot!(root: dir)
    FileUtils.rm_rf(File.join(dir, 'data'))

    get '/health'

    assert_equal 503, last_response.status
    assert_equal({ 'status' => 'error' }, JSON.parse(last_response.body))
  end

  # A migration applied while the application runs must be visible. A health
  # check that reports the state from boot time reports history.
  def test_health_reports_503_when_the_schema_state_changes_underneath
    dir = migrated_dir('health_drift')
    PromptAtelier::App.boot!(root: dir)
    assert_equal 200, get('/health').status

    with_db(dir) do |db|
      db[:schema_migrations].insert(version: '999_from_the_future', applied_at: Time.now)
    end

    get '/health'
    assert_equal 503, last_response.status
  end

  # Still no internals, even in the failing case (SEC-13).
  def test_the_503_reveals_nothing_about_the_cause
    dir = migrated_dir('health_quiet')
    PromptAtelier::App.boot!(root: dir)
    FileUtils.rm_rf(File.join(dir, 'data'))

    get '/health'

    assert_equal %w[status], JSON.parse(last_response.body).keys
    refute_includes last_response.body, dir
  end
end
