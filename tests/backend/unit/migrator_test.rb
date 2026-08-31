# frozen_string_literal: true

require_relative '../../test_helper'

# TF-620 to TF-622 — the migration sequence from Requirements 18.9.
#
# The point of these tests is not that migrations work when everything goes
# right. It is that a failed migration leaves the data exactly as it was, and
# that the backup taken beforehand is still there afterwards.
class MigratorTest < PromptAtelier::TestCase
  def setup
    super
    @extra_dirs = []
  end

  def teardown
    @extra_dirs.each { |dir| FileUtils.rm_rf(dir) }
    super
  end

  # --- TF-620: the backup comes first -------------------------------------

  def test_tf620_a_pending_step_produces_a_backup_before_the_change
    dir = migrated_dir('tf620')                    # 001 applied, database has data
    with_db(dir) { |db| seed_owner(db) }

    migrations = extra_migration_dir('002_add_note', <<~SQL)
      ALTER TABLE prompts ADD COLUMN note TEXT;
    SQL

    result = migrator_for(dir, migrations: migrations).run

    refute_nil result.backup_path, 'a backup must be created'
    assert File.exist?(result.backup_path)
    # The label is English like every other file name. `scripts/lib/backup.rb`
    # still recognises the former German one when it rotates, so a safety net
    # taken before the rename does not become a file that rotation deletes.
    assert_match(/before-migration-\d{8}-\d{6}\.db\z/, result.backup_path)
    assert PromptAtelier::Backup.usable?(result.backup_path),
           'a backup that cannot be opened is not a backup'
  end

  # The backup has to reflect the state *before* the step, otherwise it is
  # worthless for going back.
  def test_tf620_the_backup_holds_the_state_before_the_change
    dir = migrated_dir('tf620b')
    with_db(dir) { |db| seed_owner(db) }

    migrations = extra_migration_dir('002_add_note', 'ALTER TABLE prompts ADD COLUMN note TEXT;')
    result = migrator_for(dir, migrations: migrations).run

    PromptAtelier::Database.open(result.backup_path, wal: false) do |db|
      refute_includes db[:prompts].columns, :note,
                      'the backup must not already contain the new column'
    end
    with_db(dir) do |db|
      assert_includes db[:prompts].columns, :note
    end
  end

  # --- TF-621: a failing migration changes nothing -------------------------

  def test_tf621_a_failing_migration_leaves_the_data_untouched
    dir = migrated_dir('tf621')
    workspace_id = nil
    with_db(dir) do |db|
      workspace_id, owner = seed_owner(db)
      insert_prompt(db, workspace_id, owner, title: 'Bestand', body: 'Text')
    end

    # First statement succeeds, second one is nonsense — this is what makes it
    # a rollback test rather than a syntax test.
    migrations = extra_migration_dir('002_broken', <<~SQL)
      ALTER TABLE prompts ADD COLUMN note TEXT;
      INSERT INTO gibt_es_nicht (spalte) VALUES (1);
    SQL

    error = assert_raises(PromptAtelier::Migrator::Error) do
      migrator_for(dir, migrations: migrations).run
    end

    assert_match(/002_broken/, error.message, 'the message must name the failing step')
    assert_equal '002_broken', error.version

    with_db(dir) do |db|
      refute_includes db[:prompts].columns, :note,
                      'the first statement must have been rolled back too'
      assert_equal 1, db[:prompts].count, 'existing rows must survive'
      assert_equal 'Bestand', db[:prompts].first[:title]
      assert_equal shipped_versions, db[:schema_migrations].select_map(:version),
                   'the failed step must not be recorded'
    end
    refute_nil workspace_id
  end

  def test_tf621_the_backup_stays_behind_after_a_failure
    dir = migrated_dir('tf621b')
    with_db(dir) { |db| seed_owner(db) }

    migrations = extra_migration_dir('002_broken', 'INSERT INTO gibt_es_nicht (a) VALUES (1);')

    error = assert_raises(PromptAtelier::Migrator::Error) do
      migrator_for(dir, migrations: migrations).run
    end

    refute_nil error.backup_path, 'the error must say where the backup is'
    assert File.exist?(error.backup_path), 'the backup must not be cleaned up on failure'
    assert PromptAtelier::Backup.usable?(error.backup_path)
  end

  # --- TF-622: nothing to do -----------------------------------------------

  def test_tf622_a_run_without_pending_steps_creates_no_backup
    dir = migrated_dir('tf622')
    backups = File.join(dir, 'data', 'backups')
    before  = Dir.exist?(backups) ? Dir.children(backups) : []

    result = migrator_for(dir).run

    assert result.nothing_to_do?
    assert result.already_current
    assert_nil result.backup_path
    after = Dir.exist?(backups) ? Dir.children(backups) : []
    assert_equal before, after, 'an idle run must not fill the backup directory'
  end

  # --- 002: timestamps in UTC (TF-427) -------------------------------------

  # Rows written before this step hold local time without an offset. The step
  # converts them, and it has to use the offset that was in force **on that
  # date** — one hour in January, two in July, in this time zone. A single
  # offset for all rows would be wrong for exactly the dates that make the
  # step necessary.
  def test_002_converts_existing_local_timestamps_to_utc
    dir = install_dir('utc')
    write_config(dir, valid_config)
    run_only_first_migration(dir)

    winter = '2026-01-15 10:30:00.000'
    summer = '2026-07-15 10:30:00.000'
    with_db(dir) do |db|
      db[:users].insert(email: 'a@test', name: 'A', password_hash: 'x',
                        created_at: winter, updated_at: winter, last_login_at: summer)
    end

    migrator_for(dir).run

    with_db(dir) do |db|
      row = db[:users].first
      # Read back as a plain string, because that is what the file holds.
      assert_equal '2026-01-15 09:30:00.000', raw(db, :users, :created_at)
      assert_equal '2026-07-15 08:30:00.000', raw(db, :users, :last_login_at)
      refute_nil row[:created_at]
    end
  end

  # The counter-check: a step that shifted everything by the same amount would
  # pass a test that only looked at one season. The two rows above differ by
  # an hour in the shift for that reason, and this states it outright.
  def test_002_uses_the_offset_that_applied_at_the_time_of_the_row
    dir = install_dir('utc-dst')
    write_config(dir, valid_config)
    run_only_first_migration(dir)

    with_db(dir) do |db|
      db[:users].insert(email: 'a@test', name: 'A', password_hash: 'x',
                        created_at: '2026-01-15 10:30:00.000',
                        updated_at: '2026-07-15 10:30:00.000')
    end

    migrator_for(dir).run

    with_db(dir) do |db|
      winter = Time.parse("#{raw(db, :users, :created_at)} UTC")
      summer = Time.parse("#{raw(db, :users, :updated_at)} UTC")

      assert_equal 1, (Time.parse('2026-01-15 10:30:00 UTC') - winter) / 3600
      assert_equal 2, (Time.parse('2026-07-15 10:30:00 UTC') - summer) / 3600
    end
  end

  # And a time written after the step comes back as the same instant. Without
  # this the conversion above could be correct while the application went on
  # writing local time into a column everyone now reads as UTC.
  def test_002_new_rows_are_written_and_read_as_the_same_instant
    dir = migrated_dir('utc-new')
    written = Time.now

    with_db(dir) do |db|
      db[:users].insert(email: 'b@test', name: 'B', password_hash: 'x',
                        created_at: written, updated_at: written)
      assert_in_delta written, db[:users].first[:created_at], 1
      assert_equal written.utc.strftime('%Y-%m-%d %H:%M'),
                   raw(db, :users, :created_at)[0, 16],
                   'the file holds UTC, not the local reading of it'
    end
  end

  # The case the tests above stepped over: on a fresh database both steps run
  # in one transaction. 001 records itself, and by then Sequel is already
  # writing UTC — so a conversion of that row would put it an offset into the
  # past. Seen in a database that had really been migrated, not in a test.
  def test_002_does_not_convert_what_the_same_run_has_just_written
    dir = migrated_dir('utc-fresh')

    with_db(dir) do |db|
      recorded = db[:schema_migrations].order(:version).map { |row| row[:applied_at] }

      # Read from the directory, not written out: the point of the case is
      # that **every** shipped step runs in the one transaction, and a fixed
      # number would turn each new migration into a failure here.
      assert_equal shipped_versions.size, recorded.size,
                   'every shipped step runs here, which is the point'
      recorded.each do |moment|
        assert_in_delta Time.now, moment, 120,
                        'a second conversion would move this an offset into the past'
      end
    end
  end

  # --- 003: the upgrade path on a database that is already in use ----------

  # Every case above runs the shipped steps on an **empty** database. That is
  # the installation case, not the update case — and the update case is the
  # one that happens at somebody else's site with their data in it (18.9).
  #
  # 003 adds a column to a populated `users` table. What has to hold: the rows
  # survive, the new column is empty for all of them (nobody was waiting
  # before the feature existed), and the application still works over the
  # result.
  def test_003_adds_the_column_to_a_database_that_already_holds_accounts
    dir = install_dir('upgrade-003')
    write_config(dir, valid_config)
    run_migrations_up_to(dir, '002_utc_timestamps')

    with_db(dir) do |db|
      # German on purpose. This database is migrated to 002 only, so the
      # `CHECK` on `users.status` is still the one from 001 and knows nothing
      # of `locked` — migration 005 has not run here and must not, because
      # what is under test is 003 meeting rows that already exist.
      db[:users].insert(email: 'alt@test', name: 'Alt', password_hash: 'x',
                        status: 'gesperrt', created_at: Time.now, updated_at: Time.now)
      refute db.schema(:users).map(&:first).include?(:pending_since),
             'the premise: the column does not exist yet'
    end

    result = migrator_for(dir).run

    assert_includes result.applied, '003_registration'
    with_db(dir) do |db|
      row = db[:users].first(email: 'alt@test')
      refute_nil row, 'the account survives the step'
      assert_equal 'locked', row[:status]
      assert_nil row[:pending_since],
                 'nobody was waiting before the feature existed'
    end
  end

  # The two indexes of FA-908 are part of the same step. Without them the
  # filter is a table scan over up to two hundred thousand rows.
  def test_003_creates_the_indexes_the_audit_filter_needs
    dir = migrated_dir('upgrade-003-index')

    with_db(dir) do |db|
      names = db.indexes(:audit_logs).keys.map(&:to_s)
      assert_includes names, 'idx_audit_actor'
      assert_includes names, 'idx_audit_action'
    end
  end

  # --- state ---------------------------------------------------------------

  def test_a_fresh_database_reports_everything_as_pending
    dir = install_dir('fresh')
    write_config(dir, valid_config)

    migrator = migrator_for(dir)
    assert_empty migrator.applied_versions
    # Every shipped step, not a list written out here: a test that has to be
    # edited for each new migration invites editing it without looking.
    assert_equal shipped_versions, migrator.pending.map(&:version)
    assert_includes migrator.pending.map(&:version), '001_initial'
  end

  def test_applied_versions_are_recorded_with_a_timestamp
    dir = migrated_dir('recorded')

    with_db(dir) do |db|
      row = db[:schema_migrations].order(:version).first
      assert_equal '001_initial', row[:version]
      refute_nil row[:applied_at]
    end
  end

  # A version the code does not know means the database is newer — a rollback
  # of the application. Detected here, refused at startup (TF-624).
  def test_unknown_applied_versions_are_reported
    dir = migrated_dir('newer')
    with_db(dir) do |db|
      db[:schema_migrations].insert(version: '999_from_the_future', applied_at: Time.now)
    end

    assert_equal ['999_from_the_future'], migrator_for(dir).unknown_applied
  end

  def test_migration_versions_must_follow_the_naming_rule
    refute PromptAtelier::Migration.valid_version?('1_initial'),   'prefix must be three digits'
    refute PromptAtelier::Migration.valid_version?('001-initial'), 'separator is an underscore'
    refute PromptAtelier::Migration.valid_version?('001_Initial'), 'lower case only'
    assert PromptAtelier::Migration.valid_version?('002_valid_name')
  end

  # The file name is the version. A mismatch would mean the sort order and the
  # recorded version disagree — the kind of thing that only shows up when a
  # third migration arrives.
  def test_a_file_that_registers_a_different_version_is_rejected
    dir = File.join(PromptAtelier::TestSupport.scratch_dir, "mismatch-#{rand(100_000)}")
    FileUtils.mkdir_p(dir)
    @extra_dirs << dir
    File.write(File.join(dir, '002_expected.rb'),
               "PromptAtelier::Migration.register('002_something_else') { '' }")

    assert_raises(PromptAtelier::Migration::LoadError) do
      PromptAtelier::Migration.all(dir)
    end
  end

  private

  # Builds a directory holding a symlink to the real 001 plus one extra step,
  # so the migrator sees a genuine sequence rather than a single file.
  #
  # A symlink rather than a copy: 001_initial.rb resolves its own requires
  # relative to its location, and a copy in a scratch directory would look for
  # services/ next to itself and not find it.
  def extra_migration_dir(version, sql)
    dir = File.join(PromptAtelier::TestSupport.scratch_dir, "migr-#{version}-#{rand(100_000)}")
    FileUtils.mkdir_p(dir)
    @extra_dirs << dir

    FileUtils.ln_s(File.join(migrations_dir, '001_initial.rb'), File.join(dir, '001_initial.rb'))
    File.write(File.join(dir, "#{version}.rb"), <<~RUBY)
      PromptAtelier::Migration.register('#{version}') { #{sql.strip.inspect} }
    RUBY

    dir
  end


  # Applies 001 only, so a test can create rows in the old format and then let
  # 002 loose on them.
  # Applies the shipped steps up to and including +version+, so a later step
  # can be exercised against a database that is already in use.
  def run_migrations_up_to(dir, version)
    FileUtils.mkdir_p(File.join(dir, 'data'))
    steps = PromptAtelier::Migration.all(migrations_dir)
    wanted = steps.take_while { |step| step.version <= version }
    refute_empty wanted, "no shipped migration up to #{version}"

    PromptAtelier::Database.open(File.join(dir, 'data', 'promptatelier.db')) do |db|
      wanted.each do |step|
        db.synchronize { |conn| conn.execute_batch(step.sql) }
        db[:schema_migrations].insert(version: step.version, applied_at: Time.now)
      end
    end
  end

  def run_only_first_migration(dir)
    first = PromptAtelier::Migration.all(migrations_dir).first
    FileUtils.mkdir_p(File.join(dir, 'data'))
    PromptAtelier::Database.open(File.join(dir, 'data', 'promptatelier.db')) do |db|
      db.synchronize { |conn| conn.execute_batch(first.sql) }
      db[:schema_migrations].insert(version: first.version, applied_at: Time.now)
    end
  end

  # The value as it stands in the file. Sequel typecasts a DATETIME column
  # into a Time on the way out, which is exactly what these tests must not
  # look at — the question is what the file holds, so the driver is asked
  # directly.
  def raw(db, table, column)
    db.synchronize { |conn| conn.execute("SELECT #{column} FROM #{table} LIMIT 1").first.first }
  end

  # The migrations the application ships with, in order — read from the
  # directory rather than repeated here.
  def shipped_versions
    PromptAtelier::Migration.all(migrations_dir).map(&:version)
  end

end
