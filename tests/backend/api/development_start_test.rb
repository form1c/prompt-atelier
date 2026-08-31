# frozen_string_literal: true

require_relative '../../test_helper'
require 'net/http'
require 'socket'

# Starting and stopping the development environment (Requirements 18.7, BT-02).
#
# The reason this suite exists is a report from use: Ctrl+C ended with
#
#   No live threads left. Deadlock? (fatal)
#
# and a stack trace out of Puma. The cause was not in Puma. Ctrl+C goes to the
# whole foreground process group, so the backend received the interrupt
# directly *and* the TERM this script sends a moment later — a second shutdown
# on top of one already running inside a signal handler.
#
# Like startup_test.rb, this really starts the processes. A test that imitated
# the start could not have this defect: it lives entirely in how the operating
# system delivers a signal.
class DevelopmentStartTest < PromptAtelier::TestCase
  BOOT_TIMEOUT = 30 # seconds
  STOP_TIMEOUT = 15 # seconds

  def setup
    super
    skip 'process groups are a POSIX notion' if Gem.win_platform?
  end

  # The heart of it: the backend must sit in a group of its own, so the only
  # signal it hears is the one the script sends deliberately.
  def test_the_backend_runs_in_its_own_process_group
    with_development_environment do |dir, script_pid|
      backend = backend_pid(dir)

      refute_equal Process.getpgid(script_pid), Process.getpgid(backend),
                   'sharing the group means Ctrl+C reaches the backend twice'
      assert_equal backend, Process.getpgid(backend),
                   'the child leads its own group, so the group can be signalled as a whole'
    end
  end

  def test_ctrl_c_stops_everything_without_a_stack_trace
    output = nil
    port = nil

    with_development_environment do |dir, script_pid, log|
      port = configured_port(dir)
      # Exactly what a terminal does: the signal goes to the group, not to one
      # process.
      Process.kill('INT', -Process.getpgid(script_pid))
      output = wait_for_exit(script_pid, log)
    end

    refute_match(/Deadlock/, output, 'the shutdown must not end in a fatal error')
    refute_match(/puma\.rb:\d+:in/, output, 'nor in a stack trace out of the server')
    assert_match(/Stopping/, output, 'the script says what it is doing')
    refute port_open?(port), 'the port must be free again afterwards'
  end

  # The counter-check to both: the environment has to have been genuinely up,
  # or a shutdown without a stack trace would prove nothing.
  def test_the_backend_answers_before_it_is_stopped
    with_development_environment do |dir, _pid|
      response = Net::HTTP.get_response(URI("http://127.0.0.1:#{configured_port(dir)}/health"))

      assert_equal '200', response.code
      assert_equal 'ok', JSON.parse(response.body)['status']
    end
  end

  private

  # A throwaway installation with the scripts in it. The script derives the
  # installation directory from its own location, so a copy inside the scratch
  # directory works on that copy — and never on project/data/, where the
  # developer's own database lives.
  def development_installation
    dir = build_installation(app_dir_name: 'backend')
    FileUtils.cp_r(File.join(CODE_ROOT, 'scripts'), dir)
    dir
  end

  def with_development_environment
    dir = development_installation
    log = File.join(dir, 'start.log')

    pid = Process.spawn(
      { 'BUNDLE_GEMFILE' => File.join(dir, 'backend', 'Gemfile') },
      RbConfig.ruby, File.join(dir, 'scripts', 'lib', 'start_development.rb'),
      '--no-frontend', '--no-browser',
      out: log, err: log, pgroup: true
    )

    wait_for_health(dir, pid, log)
    yield dir, pid, log
  ensure
    stop_group(pid)
    FileUtils.rm_rf(dir) if dir
  end

  def wait_for_health(dir, pid, log)
    port = configured_port(dir)
    deadline = Time.now + BOOT_TIMEOUT

    until Time.now > deadline
      return if port_open?(port)
      raise "the script exited early:\n#{File.read(log)}" if Process.waitpid(pid, Process::WNOHANG)

      sleep 0.2
    end
    raise "no answer on port #{port} within #{BOOT_TIMEOUT} s:\n#{File.read(log)}"
  end

  # Puma writes its pid into data/ (18.4), which is how the test finds the
  # process the script started without the script having to report it.
  def backend_pid(dir)
    path = File.join(dir, 'data', 'promptatelier.pid')
    deadline = Time.now + BOOT_TIMEOUT

    sleep 0.1 until File.exist?(path) || Time.now > deadline
    Integer(File.read(path).strip)
  end

  def wait_for_exit(pid, log)
    deadline = Time.now + STOP_TIMEOUT

    until Time.now > deadline
      return File.read(log) if Process.waitpid(pid, Process::WNOHANG)

      sleep 0.2
    end
    raise "the script did not stop within #{STOP_TIMEOUT} s:\n#{File.read(log)}"
  end

  def stop_group(pid)
    return if pid.nil?

    Process.kill('TERM', -Process.getpgid(pid))
    Process.waitpid(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def port_open?(port)
    TCPSocket.new('127.0.0.1', port).close
    true
  rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
    false
  end
end
