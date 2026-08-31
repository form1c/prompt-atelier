# frozen_string_literal: true

require_relative '../../test_helper'
require 'open3'
require 'json'
require 'fileutils'

# TF-550 — `export_all` and `import_all`, the two scripts that move a whole
# instance to another one (18.5).
#
# **Neither had a case that ran it.** `export_all` appeared once, in the list
# of scripts driven through the "the gems are unusable" failure in
# `wrong_package_test`; `import_all` appeared in a comment and nowhere else.
# A coverage measurement of the whole suite loaded neither file. So the pair
# that carries somebody's entire instance from one machine to the next was
# delivered on the strength of having been read.
#
# **The scripts run from inside the throwaway installation, and that is not a
# detail.** `Script.root` is `File.expand_path('../..', __dir__)` — the
# script's own location. Running the copy in the source tree operates on the
# **developer's own installation** whatever `chdir` says, which is exactly what
# a first attempt at this did. `vendor` is linked rather than copied for the
# same reason the other script suites link it: 30 MB per case is not a test.
class TransferScriptsTest < PromptAtelier::TestCase
  def setup
    super
    @source = delivered_installation('transfer-source')
    @target = delivered_installation('transfer-target')
    with_db(@source) { |db| seed(db) }
  end

  # The round trip, and the only assertion that matters: what went in comes out
  # on the other side. Checked in the target's database rather than in the
  # script's own summary — a script that counts what it *meant* to write is not
  # a witness to what it wrote.
  def test_tf550_a_whole_instance_travels_from_one_installation_to_the_other
    file = File.join(@source, 'instance.json')

    status, output = run_script(@source, 'export_all', file)

    assert_equal 0, status, output
    assert_path_exists file
    assert_includes output, '1 accounts'

    status, output = run_script(@target, 'import_all', file, '--yes')

    assert_equal 0, status, output

    with_db(@target) do |db|
      assert_equal 1, db[:users].count
      assert_equal 'a@example.test', db[:users].first[:email]
      assert_equal 1, db[:prompts].count
      assert_equal 'Sichtbarer Prompt', db[:prompts].first[:title]
      assert_includes db[:workspaces].select_map(:name), 'Marketing'
    end
  end

  # SEC: the file is carried between machines by hand, so it must not be a
  # password file. The export says so in its own output; this is the check that
  # the sentence is true.
  def test_tf550_the_exported_file_carries_no_password_hashes
    file = File.join(@source, 'instance.json')
    run_script(@source, 'export_all', file)

    content = File.read(file)
    hash = with_db(@source) { |db| db[:users].first[:password_hash] }

    refute_includes content, hash, 'the hash of an account must not travel'
    refute_includes content, 'password_hash'
  end

  # Every account arrives without a usable password, so the script hands out
  # one-time ones. They are shown once and stored nowhere — which means the run
  # that prints them is the only chance anybody has, and a silent import would
  # lock every account out of the new instance.
  def test_tf550_every_imported_account_gets_a_one_time_password_that_is_shown
    file = File.join(@source, 'instance.json')
    run_script(@source, 'export_all', file)

    _, output = run_script(@target, 'import_all', file, '--yes')

    assert_includes output, 'a@example.test'
    assert_match(/[A-Za-z0-9]{16,}/, output, 'a password has to be readable in the output')
    assert with_db(@target) { |db| db[:users].first[:must_change_pw] == true },
           'and it has to be temporary'
  end

  # The refusal that gives the pair its shape (AP-15b): filling an instance
  # that already has accounts would mean merging, and merging asks who is who —
  # a question for the per-workspace import, where a person stands next to it.
  def test_tf550_an_instance_that_already_has_accounts_is_not_filled
    file = File.join(@source, 'instance.json')
    run_script(@source, 'export_all', file)
    with_db(@target) { |db| seed(db) }

    status, output = run_script(@target, 'import_all', file, '--yes')

    refute_equal 0, status
    assert_includes output, 'only fills an empty one'
    with_db(@target) { |db| assert_equal 1, db[:users].count, 'nothing may have been added' }
  end

  private

  def seed(db)
    now = Time.now
    workspace = db[:workspaces].insert(name: 'Marketing', slug: 'marketing',
                                       created_at: now, updated_at: now)
    user = db[:users].insert(email: 'a@example.test', name: 'A', password_hash: 'argon2-stellvertreter',
                             status: 'active', is_instance_admin: true, locale: 'en',
                             created_at: now, updated_at: now)
    db[:memberships].insert(user_id: user, workspace_id: workspace, role: 'owner', created_at: now)
    db[:prompts].insert(workspace_id: workspace, owner_id: user,
                        title: 'Sichtbarer Prompt', title_sort: 'sichtbarer prompt',
                        body: 'Ein Text.', visibility: 'workspace', status: 'draft',
                        created_at: now, updated_at: now)
  end

  def delivered_installation(name)
    dir = install_dir(name)
    app = File.join(dir, 'app')
    FileUtils.mkdir_p(app)

    source = File.join(CODE_ROOT, 'backend')
    %w[app.rb config.ru version.rb Gemfile Gemfile.lock].each do |file|
      FileUtils.cp(File.join(source, file), File.join(app, file))
    end
    %w[services locales config migrations].each do |folder|
      FileUtils.cp_r(File.join(source, folder), app)
    end
    %w[wordlists].each do |folder|
      FileUtils.cp_r(File.join(source, folder), app) if Dir.exist?(File.join(source, folder))
    end
    FileUtils.cp_r(File.join(source, '.bundle'), app) if Dir.exist?(File.join(source, '.bundle'))
    FileUtils.ln_s(File.join(source, 'vendor'), File.join(app, 'vendor'))

    FileUtils.cp_r(File.join(CODE_ROOT, 'scripts'), dir)
    write_config(dir, valid_config)
    migrator_for(dir).run
    dir
  end

  def with_db(dir, &block) = PromptAtelier::Database.open(database_path(dir), &block)

  def run_script(dir, name, *args)
    output, status = Open3.capture2e(
      script_env,
      RbConfig.ruby, File.join(dir, 'scripts', 'lib', "#{name}.rb"), *args,
      chdir: dir
    )
    [status.exitstatus, output]
  end
end
