# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'open3'

$LOAD_PATH.unshift(File.join(CODE_ROOT, 'scripts', 'lib'))
require 'restore'

# `backup` and `restore` (18.10, BT-11, BT-12, NFA-12).
#
# Run as processes against a throwaway installation, because what is being
# checked is what a file on disk looks like afterwards — and `restore` is the
# one script that destroys data on purpose.
class BackupRestoreTest < PromptAtelier::TestCase
  def setup
    super
    @dir = delivered_installation
    seed
  end

  # --- backup (BT-11) -------------------------------------------------------

  # A plain copy of the .db is not a backup: in WAL mode the newest changes
  # live in a side file, and the copy even passes integrity_check — so the
  # loss is discovered on the day it is needed. Checked by reading the backup
  # back and finding the accounts in it.
  def test_bt11_the_backup_is_a_complete_database_and_is_verified
    status, output = run_script('backup')

    assert_equal 0, status, output
    file = backups.first
    refute_nil file, 'no backup was written'

    PromptAtelier::Database.open(file, wal: false) do |db|
      assert_equal 6, db[:users].count, 'the backup has to hold the data, not an empty shell'
    end
    assert_includes output, 'verified'
  end

  def test_bt11_it_runs_while_the_database_is_open
    PromptAtelier::Database.open(database_path) do |db|
      db[:users].count
      status, = run_script('backup')

      assert_equal 0, status, 'a backup that needs the instance stopped is not NFA-12'
    end
  end

  # `backup.keep` from config.yml. The counter-check is the important half:
  # backups taken before a migration are **not** rotated away — the reason to
  # keep one is the schema change, not its age.
  def test_rotation_keeps_the_configured_number_and_spares_the_migration_backups
    write_keep(2)
    FileUtils.mkdir_p(backup_dir)
    File.write(File.join(backup_dir, 'before-migration-20200101-000000.db'), 'x')
    File.write(File.join(backup_dir, 'vor-migration-20200101-000000.db'), 'x')

    3.times { |n| run_script('backup'); sleep 1.1 if n < 2 }

    assert_equal 2, backups.size, 'the newest two of our own'
    assert_equal 2, Dir.glob(File.join(backup_dir, '*migration*')).size,
                 'a safety net from before a schema change is not rotated away — ' \
                 'neither under its current name nor under the former German one'
  end

  # --- restore (BT-12) ------------------------------------------------------

  def test_bt12_it_refuses_without_the_confirmation
    file = make_backup
    change_something

    status, output = run_script('restore', File.basename(file))

    assert_equal 1, status
    assert_includes output, 'No terminal to confirm'
    assert_equal 7, accounts, 'nothing may be overwritten without a confirmation'
  end

  def test_bt12_with_the_confirmation_it_restores_and_keeps_the_replaced_state
    file = make_backup
    change_something

    status, output = run_script('restore', File.basename(file), '--yes')

    assert_equal 0, status, output
    assert_equal 6, accounts, 'the earlier state is back'
    assert_equal 1, Dir.glob(File.join(backup_dir, 'before-restore-*.db')).size,
                 'whoever restores yesterday finds out an hour later that today held something'
  end

  # The one mistake with no way back: a damaged file written over a working
  # database. So the backup is read **before** anything is touched.
  def test_a_damaged_backup_is_refused_and_nothing_is_overwritten
    broken = File.join(backup_dir, 'promptatelier-19990101-000000.db')
    FileUtils.mkdir_p(backup_dir)
    File.write(broken, 'this is not a database')

    status, output = run_script('restore', File.basename(broken), '--yes')

    assert_equal 1, status
    assert_includes output, 'NOT restored'
    assert_equal 6, accounts
  end

  # The WAL and shared-memory files belong to the **old** database. Left
  # behind, SQLite replays them onto the restored one and the result is a
  # mixture of two states.
  #
  # Checked on `replace` directly rather than through the whole script, and a
  # mutation probe is why: the safety copy a few lines earlier opens the
  # database, and SQLite tidies the side files away on a clean close. Through
  # the script the leftover disappears whether or not this line exists — the
  # case looked convincing and could not fail.
  def test_the_side_files_of_the_replaced_database_are_removed
    file = make_backup
    File.write("#{database_path}-wal", 'leftover')
    File.write("#{database_path}-shm", 'leftover')

    config = PromptAtelier::Configuration.load(root: @dir)
    PromptAtelier::Restore.replace(config, file)

    refute File.exist?("#{database_path}-wal"), 'a leftover WAL is replayed onto the restored file'
    refute File.exist?("#{database_path}-shm")
  end

  def test_without_an_argument_it_says_what_there_is_to_restore
    make_backup
    status, output = run_script('restore')

    assert_equal 1, status
    assert_includes output, 'promptatelier-'
    assert_includes output, 'restore.sh'
  end

  def test_an_unknown_file_is_named_rather_than_guessed_at
    status, output = run_script('restore', 'gibt-es-nicht.db', '--yes')

    assert_equal 1, status
    assert_includes output, 'gibt-es-nicht.db'
  end

  private

  def database_path = File.join(@dir, 'data', 'promptatelier.db')
  def backup_dir    = File.join(@dir, 'data', 'backups')
  def backups       = Dir.glob(File.join(backup_dir, 'promptatelier-*.db')).sort.reverse

  def accounts
    PromptAtelier::Database.open(database_path) { |db| db[:users].count }
  end

  def seed
    migrate_installation(@dir)
    PromptAtelier::Database.open(database_path) { |db| PromptAtelier::Fixture.build(db) }
  end

  def change_something
    PromptAtelier::Database.open(database_path) do |db|
      now = Time.now
      db[:users].insert(email: 'spaeter@test', name: 'Spaeter', password_hash: 'x',
                        created_at: now, updated_at: now)
    end
  end

  def make_backup
    run_script('backup')
    backups.first
  end

  def write_keep(count)
    path = File.join(@dir, 'config', 'config.yml')
    settings = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
    settings['backup'] = { 'keep' => count }
    File.write(path, YAML.dump(settings))
  end

  def run_script(name, *arguments)
    output, status = Open3.capture2e(
      { 'BUNDLE_GEMFILE' => File.join(@dir, 'app', 'Gemfile') },
      RbConfig.ruby, File.join(@dir, 'scripts', 'lib', "#{name}.rb"), *arguments,
      chdir: @dir
    )
    [status.exitstatus, output]
  end

  def delivered_installation
    dir = install_dir('backup')
    app = File.join(dir, 'app')
    FileUtils.mkdir_p(app)

    source = File.join(CODE_ROOT, 'backend')
    %w[app.rb config.ru version.rb Gemfile Gemfile.lock].each do |name|
      FileUtils.cp(File.join(source, name), File.join(app, name))
    end
    %w[services locales config migrations wordlists].each { |name| FileUtils.cp_r(File.join(source, name), app) }
    FileUtils.cp_r(File.join(source, '.bundle'), app) if Dir.exist?(File.join(source, '.bundle'))
    FileUtils.ln_s(File.join(source, 'vendor'), File.join(app, 'vendor'))

    FileUtils.cp_r(File.join(CODE_ROOT, 'scripts'), dir)
    write_config(dir, valid_config.merge('server' => { 'port' => free_port }))
    dir
  end
end
