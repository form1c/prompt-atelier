# frozen_string_literal: true

require_relative '../../test_helper'
require 'net/http'
require 'open3'

$LOAD_PATH.unshift(File.join(CODE_ROOT, 'scripts', 'lib'))
require 'start_portable'
require 'service_unit'

# `start_portable` — the operating mode that touches nothing (18.5, 18.6,
# 18.10, BT-05, E-14, TF-645).
#
# **It was missing while `install` already pointed at it.** The closing line of
# a finished installation names `scripts/start_portable.sh`; the file did not
# exist. Nothing failed while the earlier packages were built, because nothing
# calls the last line of another script — which is exactly the kind of gap a
# test suite has to close instead of a reader.
#
# The case in the middle starts a real instance in a throwaway installation of
# its own — own directory, own port, own database. Never against the
# installation being developed against.
class StartPortableTest < PromptAtelier::TestCase
  Portable = PromptAtelier::StartPortable
  Unit     = PromptAtelier::ServiceUnit

  # --- one start command, in two places (TF-645) ----------------------------

  # The service and the portable start have to run the **same** thing.
  # Two commands that drift apart mean an instance behaves differently
  # depending on how it was started, and the difference shows up as a bug
  # nobody can reproduce.
  # TF-691. **They are no longer merely alike, they are the same list.** Both start the
  # one entry point, so there is nothing left that could drift.
  def test_tf645_the_portable_start_and_the_service_run_the_same_command
    exec_line = Unit.systemd_unit(scope: :user)
                    .lines.find { |line| line.start_with?('ExecStart=') }.strip

    assert_includes exec_line, 'service_run.rb'
    assert_equal Unit.service_command, Portable.command
    # The one permitted difference, and it is the finding from section 2:
    # systemd splits `ExecStart` on spaces, so a path like
    # `/opt/prompt atelier/` has to be quoted there. Nowhere else — and not
    # here, where the argument is handed over as one word anyway.
    assert exec_line.end_with?(Unit.quoted(Portable.command.last)),
           'both have to point at the same puma configuration'
  end

  # **Ruby is invoked on Bundler's own script, not on the name `bundle`.**
  #
  # On Windows `bundle` is a batch wrapper: starting it starts `cmd.exe`, which
  # starts Ruby, which loads Puma — and the process this script can see and
  # stop is the wrapper. Killing it left Puma running and the port bound, so
  # the next start ended in `Errno::EADDRINUSE` with thirty lines of stack
  # trace. Reported from a Windows installation after stopping and starting
  # again.
  #
  # There is no Windows machine here, so what is checked is the decision that
  # makes the difference: no wrapper is put in between.
  def test_the_start_puts_no_wrapper_between_itself_and_the_process_it_must_stop
    first = Portable.command.first

    assert_equal RbConfig.ruby, first,
                 'the running interpreter, so what is started is what can be stopped'
    assert Portable.command[1].end_with?('service_run.rb'),
           'and the entry point as a script it can load'
    assert_equal 2, Portable.command.size, 'nothing between the two'
  end

  # Host and port come from config.yml and have exactly one source (BT-19). A
  # port on the command line would win over the file, and changing the file
  # would then do nothing — with no hint as to why.
  def test_bt19_neither_start_command_names_a_host_or_a_port
    both = [Unit.systemd_unit(scope: :user, bundle: '/usr/bin/bundle'),
            Portable.command.join(' ')].join("\n")

    refute_match(/--port|--bind|-p\s+\d/, both)
    refute_match(/0\.0\.0\.0|:9292/, both)
  end

  # BUNDLE_GEMFILE is not decoration: the Gemfile lives in `app/`, the start
  # runs one level above it, and without the assignment bundler stops with
  # "Could not locate Gemfile" (TF-645b).
  def test_the_start_carries_the_gemfile_and_the_production_mode
    environment = Portable.environment.first

    assert environment['BUNDLE_GEMFILE'].end_with?(File.join('Gemfile'))
    assert_equal 'production', environment['RACK_ENV'],
                 'without it Sinatra serves stack traces to the browser (SEC-13)'
  end

  # --- a real start and a real Ctrl+C ---------------------------------------

  # The whole way through: it comes up, it answers, Ctrl+C stops it, and a
  # backup is on disk afterwards (18.10 — in portable operation the schedule is
  # "on the way out", because nobody sets a timer for a program they start by
  # hand).
  #
  # The signal goes to the **process group**, which is what a terminal does.
  # Puma runs in a group of its own, so it hears exactly one termination — the
  # one this script sends. Without that separation it would receive the
  # interrupt directly *and* the following TERM, shut down twice at once and
  # end in `No live threads left. Deadlock? (fatal)`. That sentence is asserted
  # against below, because it is what the bug looked like.
  def test_it_starts_answers_stops_on_ctrl_c_and_leaves_a_backup_behind
    dir = portable_installation
    pid = start(dir)

    assert answers?(dir), 'the instance did not come up'

    Process.kill('INT', -pid)
    output = finish(pid)

    assert_includes output, 'Stopping'
    refute_includes output, 'Deadlock'
    refute_includes output, 'start_portable.rb:', 'a stack trace is not a shutdown'
    refute_empty Dir.glob(File.join(dir, 'data', 'backups', 'promptatelier-*.db')),
                 'the state at shutdown is what somebody who pulls the stick out keeps'
  end

  # **The case a mutation probe asked for.** With the process group taken away
  # the run above stayed green: Puma survives receiving the interrupt directly
  # *and* the following TERM well enough that nothing shows on the outside of
  # this installation. The shape of the failure — a second shutdown from inside
  # a signal handler — depends on timing and on the Puma version, so the
  # console output is not the place to observe it.
  #
  # So it is observed one level down, where it is a fact rather than a symptom:
  # the child sits in a process group of its own. Read from the process table
  # rather than from the source, which keeps this a check on what happens
  # instead of on what was written (test concept 3.4).
  def test_puma_runs_in_a_process_group_of_its_own
    skip 'the process table is read from /proc here' unless File.directory?('/proc')

    dir = portable_installation
    pid = start(dir)

    assert answers?(dir)
    child = children_of(pid).first
    refute_nil child, 'no application process was found below the starter'
    refute_equal Process.getpgid(pid), child[:group],
                 'in one group Ctrl+C reaches Puma directly as well, and it shuts down twice'
  ensure
    Process.kill('INT', -pid) if pid
    finish(pid) if pid
  end

  # The same run without the backup. Somebody who stops and starts an instance
  # ten times an afternoon should be able to say so.
  def test_no_backup_is_taken_when_it_is_declined
    dir = portable_installation
    pid = start(dir, '--no-backup')

    assert answers?(dir)
    Process.kill('INT', -pid)
    finish(pid)

    assert_empty Dir.glob(File.join(dir, 'data', 'backups', '*.db'))
  end

  # --- refusals -------------------------------------------------------------

  # Checked **before** anything starts. Otherwise Puma dies a second later and
  # the real reason is buried under its output — the finding from NT-0, in the
  # one script where it would be met most often.
  # A port somebody else holds is one sentence, not thirty lines of stack
  # trace. The most likely holder is the instance the person thought they had
  # stopped, so that is what the message says first.
  def test_a_port_that_is_taken_is_one_sentence_and_nothing_is_started
    dir = portable_installation
    holder = TCPServer.new('127.0.0.1', configured_port(dir))

    output, status = Open3.capture2e(
      { 'BUNDLE_GEMFILE' => File.join(dir, 'app', 'Gemfile') },
      RbConfig.ruby, File.join(dir, 'scripts', 'lib', 'start_portable.rb'),
      chdir: dir
    )

    refute_predicate status, :success?
    assert_includes output, 'already in use'
    assert_includes output, 'still running', 'and it names the likely reason'
    refute_includes output, 'EADDRINUSE', 'the errno is not an explanation'
    refute_match(/^\s+from .*\.rb:\d+/, output, 'and a stack trace is not one either')
  ensure
    holder&.close
  end

  def test_a_bad_configuration_is_refused_before_puma_is_started
    dir = portable_installation
    write_config(dir, valid_config.merge('server' => { 'host' => '127.0.0.1', 'port' => 70_000 }))

    output, status = Open3.capture2e(
      { 'BUNDLE_GEMFILE' => File.join(dir, 'app', 'Gemfile') },
      RbConfig.ruby, File.join(dir, 'scripts', 'lib', 'start_portable.rb'),
      chdir: dir
    )

    refute_predicate status, :success?
    assert_includes output, '65535'
    refute_includes output, 'Address:', 'nothing may be announced that was never started'
  end

  private

  # --- driving the script ----------------------------------------------------

  def start(dir, *switches)
    reader, writer = IO.pipe
    @output = reader
    # A group of its own, so the interrupt can be sent to the group the way a
    # terminal sends it — and so it never reaches the process running this
    # suite.
    pid = spawn({ 'BUNDLE_GEMFILE' => File.join(dir, 'app', 'Gemfile') },
                RbConfig.ruby, File.join(dir, 'scripts', 'lib', 'start_portable.rb'), *switches,
                chdir: dir, out: writer, err: writer, pgroup: true)
    writer.close
    pid
  end

  def finish(pid, timeout: 30)
    deadline = Time.now + timeout
    while Time.now < deadline
      done, = Process.waitpid2(pid, Process::WNOHANG)
      break if done

      sleep 0.1
    end
    text = @output.read
    @output.close
    text
  ensure
    kill_leftover(pid)
  end

  def kill_leftover(pid)
    Process.kill('KILL', -pid)
    Process.waitpid(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # Parent and group of every process, taken from /proc. Split at the last
  # `") "` on purpose: the second field is the program name in parentheses and
  # may itself contain spaces, so a plain split on whitespace shifts every
  # field after it.
  def children_of(pid)
    Dir.glob('/proc/[0-9]*/stat').filter_map do |path|
      fields = File.read(path).split(') ').last.to_s.split
      { pid: File.basename(File.dirname(path)).to_i,
        parent: fields[1].to_i, group: fields[2].to_i }
    rescue Errno::ENOENT, Errno::ESRCH, Errno::EACCES
      nil
    end.select { |process| process[:parent] == pid }
  end

  def answers?(dir, timeout: 30)
    port = configured_port(dir)
    deadline = Time.now + timeout

    while Time.now < deadline
      begin
        return true if Net::HTTP.start('127.0.0.1', port, open_timeout: 1, read_timeout: 2) { |http|
          http.get('/health').code
        } == '200'
      rescue StandardError
        nil
      end
      sleep 0.2
    end
    false
  end

  # --- a throwaway installation in delivered shape --------------------------

  # `app/` beside `config/`, `scripts/` and `data/` (18.2). Built as a delivery
  # rather than as a development tree, for the reason `install_test` records:
  # the development tree is the one layout in which a delivery bug is
  # invisible.
  def portable_installation
    dir = install_dir('portable')
    app = File.join(dir, 'app')
    FileUtils.mkdir_p(app)

    source = File.join(CODE_ROOT, 'backend')
    %w[app.rb config.ru version.rb Gemfile Gemfile.lock].each do |name|
      FileUtils.cp(File.join(source, name), File.join(app, name))
    end
    %w[services locales config migrations models routes wordlists public].each do |name|
      FileUtils.cp_r(File.join(source, name), app) if File.exist?(File.join(source, name))
    end
    FileUtils.cp_r(File.join(source, '.bundle'), app)
    FileUtils.ln_s(File.join(source, 'vendor'), File.join(app, 'vendor'))

    FileUtils.cp_r(File.join(CODE_ROOT, 'scripts'), dir)
    port = free_port
    write_config(dir, valid_config.merge(
                        'server' => { 'host' => '127.0.0.1', 'port' => port,
                                      'base_url' => "http://localhost:#{port}" }
                      ))
    migrate_installation(dir)
    dir
  end
end
