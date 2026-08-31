# frozen_string_literal: true

require_relative '../../test_helper'
require 'open3'
require 'yaml'

# `install` in a throwaway installation that has the **delivered** shape
# (BT-03, BT-05, BT-07, BT-15, NFA-19).
#
# Built as `app/` rather than `backend/`, and that is not decoration: the very
# first run of this suite found that `scripts/lib/common.rb` put a fixed
# `backend` on the load path, so **no script would have run in a delivered
# installation at all** — every one of them would have stopped at "cannot load
# such file -- services/i18n". Reading the code would not have shown it; the
# development tree is the one layout where the bug is invisible.
#
# Everything is driven through the switches. `install` asks when it has a
# terminal and takes switches when it does not, and a test has none — which
# also makes the last case here possible: without either, it must say what is
# missing rather than block for ever.
class InstallTest < PromptAtelier::TestCase
  ADMIN = { name: 'Admin', email: 'admin@example.test',
            password: 'ein-langes-testpasswort' }.freeze

  def setup
    super
    @dir = delivered_installation
  end

  # --- the whole way through (BT-03) ---------------------------------------

  def test_bt03_it_leads_from_the_unpacked_archive_to_a_running_instance
    status, output = install(port: free_port)

    assert_equal 0, status, output
    assert_includes output, 'Installation complete'

    # The four things that have to exist afterwards, each named separately so
    # a failure says which one is missing.
    assert File.file?(config_path), 'the configuration was not created'
    assert File.file?(database_path), 'the database was not created'
    assert_equal 1, administrators, 'nobody could sign in'
    assert_includes output, 'The application answered on',
                     'the run must not end without the instance having answered once'
  end

  # BT-03 again, from the other side: no file was edited by hand, and none had
  # to be. The switches are the unattended equivalent of the questions.
  def test_bt03_it_asks_for_nothing_that_cannot_be_supplied
    status, = install(port: free_port)

    assert_equal 0, status
    settings = YAML.safe_load(File.read(config_path), permitted_classes: [], aliases: false)
    assert_equal ADMIN[:email], first_administrator_email
    refute_nil settings.dig('server', 'port')
  end

  # --- a second run (BT-07) -------------------------------------------------

  # The step where idempotency actually matters. Whoever runs `install` a
  # second time — usually after an update — has a configuration they edited:
  # the port, the proxies they trust, the language of the instance. None of it
  # may be thrown away by a script that was asked to update. Compared byte for
  # byte, not key by key: a comparison that lists the keys it cares about is
  # blind to the one nobody thought of.
  def test_bt07_a_second_run_keeps_the_configuration_as_it_was
    install(port: free_port)
    before = File.read(config_path)

    status, output = install

    assert_equal 0, status, output
    assert_equal before, File.read(config_path), 'not one line may be rewritten'
    assert_includes output, 'kept as it is'
  end

  def test_bt07_a_second_run_creates_no_second_administrator
    install(port: free_port)
    status, output = install

    assert_equal 0, status
    assert_equal 1, administrators
    assert_includes output, 'An instance administrator already exists.'
  end

  def test_bt07_a_second_run_applies_no_schema_step_and_takes_no_backup
    install(port: free_port)
    backups_before = Dir.glob(File.join(@dir, 'data', 'backups', '*')).size

    _, output = install

    assert_includes output, 'Nothing to do'
    assert_equal backups_before, Dir.glob(File.join(@dir, 'data', 'backups', '*')).size,
                 'a run with nothing to do must not fill the disk with backups'
  end

  # --- where things end up (NFA-19, BT-05) ---------------------------------

  def test_nfa19_everything_written_stays_inside_the_installation
    install(port: free_port)

    assert File.file?(File.join(@dir, 'data', 'promptatelier.db'))
    assert_equal File.expand_path(@dir),
                 File.expand_path(File.join(File.dirname(database_path), '..')),
                 'the database must not land beside the installation directory'
  end

  # SEC-20. Checked on the file rather than on the code: a `chmod` after the
  # write would leave it readable in between, and only the result tells the
  # two apart.
  #
  # What is worth closing off is named in the assertion below: `trusted_proxies`
  # is a way to lift the sign-in limit of SEC-07 and to write any address into
  # the audit log, so it may not be readable — let alone writable — by other
  # accounts on the machine.
  def test_sec20_the_configuration_is_readable_by_nobody_else
    skip 'no POSIX permissions' if Gem.win_platform?

    install(port: free_port)

    assert_equal '600', format('%o', File.stat(config_path).mode & 0o777)
    settings = YAML.safe_load(File.read(config_path), permitted_classes: [], aliases: false)
    refute_nil settings.dig('server', 'trusted_proxies'), 'and it really is that file'
  end

  # --- refusals that have to be readable (BT-15) ---------------------------

  # A port somebody else holds is the most likely reason a first installation
  # fails, and the message has to name the port rather than the errno.
  def test_bt15_a_port_that_is_taken_is_refused_by_name
    holder = TCPServer.new('127.0.0.1', 0)
    taken = holder.addr[1]

    status, output = install(port: taken)

    assert_equal 1, status
    assert_includes output, taken.to_s
    refute File.file?(config_path), 'nothing may be written when the port cannot be had'
  ensure
    holder&.close
  end

  def test_bt15_an_impossible_port_is_refused_before_anything_is_done
    status, output = install(port: 70_000)

    assert_equal 1, status
    assert_includes output, '1 to 65535'
    refute File.file?(config_path)
  end

  def test_bt15_an_unknown_operating_mode_is_refused_and_names_the_choices
    status, output = install(port: free_port, mode: 'irgendwie')

    assert_equal 1, status
    assert_includes output, 'portable, service'
  end

  # Without a terminal there is nobody to answer. Blocking on a question
  # nobody can see is worse than failing, so it fails — and says which switch
  # would have supplied the answer.
  def test_bt15_without_a_terminal_and_without_a_switch_it_says_so_instead_of_waiting
    status, output = run_install(['--port=' + free_port.to_s, '--mode=portable'])

    assert_equal 1, status
    assert_includes output, '--switch=value'
    assert_equal 0, administrators
  end

  # --- a failing prerequisite has to stop the run --------------------------
  #
  # Also asked for by a mutation probe: with step 1 forced to succeed the
  # suite stayed green, and `install` would have walked past a machine that
  # cannot run the application at all — reporting the real trouble five steps
  # later, in a message about something else.
  #
  # A missing lockfile is the realistic shape of this: an archive whose gems
  # were never installed.
  def test_a_failing_prerequisite_stops_the_run_before_anything_is_written
    FileUtils.rm_f(File.join(@dir, 'app', 'Gemfile.lock'))

    status, output = install(port: free_port)

    assert_equal 1, status
    assert_includes output, 'Gemfile.lock'
    refute File.file?(config_path), 'nothing may be written past a failed prerequisite'
    refute File.file?(database_path)
  end

  # --- the start check has to be able to fail (BT-15) ----------------------
  #
  # The case a mutation probe asked for: with `reachable?` forced to true the
  # whole suite stayed green, and `install` would have reported success on an
  # instance that never starts — which is the one thing step 7 exists to
  # prevent.
  #
  # Made to fail through the Puma configuration: steps 1 to 6 do not touch it,
  # so everything before behaves exactly as in a good run and only the start
  # can go wrong.
  def test_bt15_an_instance_that_does_not_start_is_reported_as_a_failure
    FileUtils.rm_f(File.join(@dir, 'app', 'config', 'puma.rb'))

    status, output = install(port: free_port)

    assert_equal 1, status
    assert_includes output, 'did not answer'
    assert_includes output, 'start_portable', 'the message has to name the next step'
  end

  # And what came before is left standing. A failed start check is a report,
  # not a rollback — undoing five good steps because the sixth failed would
  # throw away the administrator account somebody just typed in.
  def test_a_failed_start_check_leaves_the_work_of_the_earlier_steps_alone
    FileUtils.rm_f(File.join(@dir, 'app', 'config', 'puma.rb'))
    install(port: free_port)

    assert File.file?(config_path)
    assert_equal 1, administrators
  end

  # A password the policy refuses must not produce an account (SEC-02).
  def test_a_weak_password_creates_no_account
    status, output = install(port: free_port, password: 'kurz')

    assert_equal 1, status
    assert_equal 0, administrators
    refute_empty output
  end

  # --- the service mode (BT-04) --------------------------------------------

  # `install` calls `service_install` for the service mode (18.6). A service
  # that cannot be registered must **not** fail the installation: everything
  # that matters is in place by then, the portable start works, and undoing
  # six good steps because a machine has no systemd would be the wrong answer
  # to "this machine has no systemd".
  #
  # Made to fail with a stand-in `systemctl` on the PATH that refuses. Running
  # the real one is out of the question — a test must never register a service
  # on the machine it runs on.
  def test_bt04_a_service_that_cannot_be_registered_does_not_fail_the_installation
    stubs = File.join(@dir, 'stubs')
    FileUtils.mkdir_p(stubs)
    File.write(File.join(stubs, 'systemctl'), "#!/bin/sh\nexit 1\n")
    File.chmod(0o755, File.join(stubs, 'systemctl'))

    status, output = install(port: free_port, mode: 'service',
                             path: "#{stubs}:#{ENV.fetch('PATH', '')}")

    assert_equal 0, status, output
    assert_includes output, 'Installation complete'
    assert_includes output, 'start_portable', 'it has to say how to run the instance meanwhile'
    assert_equal 1, administrators, 'the work of the earlier steps stands'
  end

  private

  def config_path   = File.join(@dir, 'config', 'config.yml')
  def database_path = File.join(@dir, 'data', 'promptatelier.db')

  def install(port: nil, mode: 'portable', password: ADMIN[:password], path: nil)
    switches = ["--mode=#{mode}", "--admin-name=#{ADMIN[:name]}",
                "--admin-email=#{ADMIN[:email]}", "--admin-password=#{password}"]
    switches << "--port=#{port}" if port

    run_install(switches, path: path)
  end

  def run_install(switches, path: nil)
    environment = { 'BUNDLE_GEMFILE' => File.join(@dir, 'app', 'Gemfile') }
    environment['PATH'] = path if path

    output, status = Open3.capture2e(
      environment,
      RbConfig.ruby, File.join(@dir, 'scripts', 'lib', 'install.rb'), *switches,
      chdir: @dir
    )
    [status.exitstatus, output]
  end

  def administrators
    return 0 unless File.file?(database_path)

    PromptAtelier::Database.open(database_path) do |db|
      db[:users].where(is_instance_admin: true).count
    end
  end

  def first_administrator_email
    PromptAtelier::Database.open(database_path) do |db|
      db[:users].where(is_instance_admin: true).get(:email)
    end
  end

  # The delivered shape: `app/` beside `config/`, `scripts/` and `data/`
  # (18.2). The gems are linked rather than installed — what is under test is
  # the installation, not `bundle install`.
  def delivered_installation
    dir = install_dir('install')
    app = File.join(dir, 'app')
    FileUtils.mkdir_p(app)

    source = File.join(CODE_ROOT, 'backend')
    %w[app.rb config.ru version.rb Gemfile Gemfile.lock].each do |name|
      FileUtils.cp(File.join(source, name), File.join(app, name))
    end
    %w[services locales config migrations wordlists].each do |name|
      FileUtils.cp_r(File.join(source, name), app)
    end
    FileUtils.cp_r(File.join(source, '.bundle'), app) if Dir.exist?(File.join(source, '.bundle'))
    FileUtils.ln_s(File.join(source, 'vendor'), File.join(app, 'vendor'))

    FileUtils.cp_r(File.join(CODE_ROOT, 'scripts'), dir)
    FileUtils.mkdir_p(File.join(dir, 'config'))
    FileUtils.cp(File.join(CODE_ROOT, 'config', 'config.example.yml'),
                 File.join(dir, 'config', 'config.example.yml'))
    dir
  end
end
