# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'services/relocation'

# Moving a whole instance (FA-804a).
#
# Three rules shape the format, and each is a refusal to promise what a script
# cannot keep. Every one of them has a case here, and each case has the
# counter-check that would fail if the rule were quietly dropped.
class RelocationTest < PromptAtelier::TestCase
  R = PromptAtelier::Relocation

  def setup
    super
    @dir = migrated_dir('relocation')
  end

  def with_full_instance
    with_db(@dir) do |db|
      ids = PromptAtelier::Fixture.build(db)
      yield db, ids
    end
  end

  def with_empty_instance(&block)
    with_db(migrated_dir('relocation-empty'), &block)
  end

  # A package from an instance of its own. Needed wherever a case also wants
  # to look at a **populated** target: building the fixture twice into the
  # same database fails on the unique address, and the failure would look
  # like the import rather than like the preparation.
  def package_from_another_instance
    with_db(migrated_dir('relocation-source')) do |db|
      PromptAtelier::Fixture.build(db)
      R.export(db)
    end
  end

  # --- what goes into the file ---------------------------------------------

  def test_it_carries_the_accounts_and_the_team_workspaces
    with_full_instance do |db, _ids|
      package = R.export(db)

      assert_equal 6, package['users'].size
      assert_includes package['users'].map { |user| user['email'] }, 'admin@test'
      assert_equal ['Marketing'], package['workspaces'].map { |workspace| workspace['name'] }
    end
  end

  # **No password hashes.** A file that carries credentials gets copied around
  # and stays on three laptops. Checked on the serialised text, not on the
  # structure: a hash nested somewhere it was not looked for would pass a
  # check on the keys.
  def test_no_credential_ever_reaches_the_file
    with_full_instance do |db, _ids|
      text = JSON.generate(R.export(db))

      refute_includes text, 'password_hash'
      refute_match(/\$argon2/, text)
    end
  end

  # The audit log stays behind. Another instance's entries in your log would
  # be a fiction — the import writes one entry about itself instead.
  def test_the_audit_log_does_not_travel
    with_full_instance do |db, _ids|
      db[:audit_logs].insert(action: 'login.succeeded', actor_name: 'Thomas', created_at: Time.now)

      refute_includes JSON.generate(R.export(db)), 'login.succeeded'
    end
  end

  # A personal workspace belongs to an account and is created with it
  # (FA-602). Carrying it over would give everybody a second one.
  def test_personal_workspaces_stay_behind
    with_full_instance do |db, _ids|
      names = R.export(db)['workspaces'].map { |workspace| workspace['name'] }

      refute(names.any? { |name| name.start_with?('Persönlich') })
    end
  end

  def test_the_members_travel_with_their_roles
    with_full_instance do |db, _ids|
      members = R.export(db)['workspaces'].first['members']

      assert_equal 'owner', members.find { |m| m['email'] == 'owner@test' }['role']
      assert_equal 'viewer', members.find { |m| m['email'] == 'viewer@test' }['role']
    end
  end

  # --- what happens on the other side --------------------------------------

  def test_an_empty_instance_ends_up_with_the_same_people_and_workspaces
    package = with_full_instance { |db, _| R.export(db) }

    with_empty_instance do |db|
      created = R.import(db, package)

      assert_equal 6, created.size
      assert_equal 6, db[:users].count
      assert_equal 1, db[:workspaces].exclude(is_personal: true).count
      assert_operator db[:prompts].count, :>, 0, 'the prompts travel too'
    end
  end

  # FA-602 on this path as well: every account brings its own place to write.
  def test_every_imported_account_has_a_personal_workspace
    package = with_full_instance { |db, _| R.export(db) }

    with_empty_instance do |db|
      R.import(db, package)

      assert_equal db[:users].count, db[:workspaces].where(is_personal: true).count
    end
  end

  # Nobody arrives with a usable password: each gets a one-time one and has to
  # choose their own. The file could not have carried a password anyway — the
  # case above proves it holds none.
  def test_everybody_arrives_with_a_one_time_password_and_has_to_change_it
    package = with_full_instance { |db, _| R.export(db) }

    with_empty_instance do |db|
      created = R.import(db, package)

      assert(created.all? { |entry| entry['password'].to_s.length >= 16 })
      assert_equal db[:users].count, db[:users].where(must_change_pw: true).count
    end
  end

  # Whoever was shut out on the old instance must not walk in through the move.
  def test_a_locked_account_stays_locked
    package = with_full_instance do |db, ids|
      db[:users].where(id: ids[:users][:lisa]).update(status: 'locked')
      R.export(db)
    end

    with_empty_instance do |db|
      R.import(db, package)

      assert_equal 'locked', db[:users].where(email: 'viewer@test').get(:status)
      assert_equal 'active', db[:users].where(email: 'admin@test').get(:status)
    end
  end

  def test_the_import_writes_one_entry_about_itself
    package = with_full_instance { |db, _| R.export(db) }

    with_empty_instance do |db|
      R.import(db, package)
      entry = db[:audit_logs].where(action: 'import.completed').first

      refute_nil entry, 'a move that leaves no trace is indistinguishable from an intrusion'
      assert_equal 6, JSON.parse(entry[:meta_json])['users']
    end
  end

  # --- the refusals ---------------------------------------------------------

  # The one precondition. Merging asks who is who, and that is a question for
  # the per-workspace import inside the application, where somebody can
  # answer it (FA-802).
  def test_it_refuses_an_instance_that_is_already_in_use
    package = package_from_another_instance

    with_full_instance do |db, _ids|
      error = assert_raises(R::Refused) { R.import(db, package) }

      assert_equal 'instance_not_empty', error.message
      assert_equal 6, db[:users].count, 'and nothing was added'
    end
  end

  # A workspace export and an instance export are different files. Reading one
  # as the other would create workspaces named after nothing.
  def test_it_refuses_a_file_that_is_a_workspace_export
    workspace_file = with_full_instance do |db, ids|
      PromptAtelier::Transfer.export(db, workspace_id: ids[:workspaces][:marketing])
    end

    with_empty_instance do |db|
      error = assert_raises(R::Refused) { R.import(db, workspace_file) }

      assert_equal 'not_an_instance_export', error.message
    end
  end

  def test_it_refuses_a_newer_version_and_a_file_without_accounts
    with_empty_instance do |db|
      newer = assert_raises(R::Refused) do
        R.import(db, { 'format' => R::FORMAT, 'version' => 99, 'users' => [{}] })
      end
      empty = assert_raises(R::Refused) do
        R.import(db, { 'format' => R::FORMAT, 'version' => 1, 'users' => [] })
      end

      assert_equal 'unsupported_version', newer.message
      assert_equal 'no_users', empty.message
    end
  end

  # A refused import must leave nothing behind. Everything happens in one
  # transaction, and this is the case that proves it rather than assuming it.
  def test_a_failure_half_way_leaves_no_accounts_behind
    package = with_full_instance { |db, _| R.export(db) }
    package['workspaces'].first['prompts'] = 'not a list'

    with_empty_instance do |db|
      assert_raises(StandardError) { R.import(db, package) }

      assert_equal 0, db[:users].count, 'a half-moved instance is worse than none'
    end
  end
end
