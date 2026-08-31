# frozen_string_literal: true

# scripts/lib/start_development.rb — start the development environment
# (18.5, 18.7)
#
# Starts in parallel:
#   1. the backend with auto reload on the configured port,
#   2. the Vite development server with hot module replacement,
#   3. the default browser at the development address.
#
# On shutdown both processes are stopped together — no orphaned process on the
# port (18.7). Missing dependencies are installed on first run instead of
# aborting with an error message.
#
# The auto reload is deliberately hand-written and pulls in no further gem: a
# directory walk over modification times is enough at this project's scale and
# behaves identically on Windows and Linux.

require 'fileutils'
require 'yaml'
require 'securerandom'
require 'socket'
require_relative 'common'

module PromptAtelier
  module StartDevelopment
    extend Script

    POLL_INTERVAL = 1.0 # seconds

    # Must match server.port / server.host in frontend/vite.config.js, which
    # pins both with strictPort so this address is predictable.
    VITE_HOST = '127.0.0.1'
    VITE_PORT = 5173

    module_function

    def run(argv = [])
      without_frontend = argv.include?('--no-frontend')
      without_browser  = argv.include?('--no-browser') || without_frontend

      children = []

      ensure_configuration
      ensure_dependencies(without_frontend)

      # Validate before starting anything. Without this the backend dies on a
      # bad value while Vite comes up regardless, the browser opens, and the
      # user is left with a page that cannot reach the backend — the clear
      # message buried somewhere above in the Vite output. Found in NT-0.
      config = load_configuration
      return 1 if config.nil?

      trap_shutdown(children)

      heading(t('script.backend_starting', address: config.address))
      children << start_backend

      # Same reasoning: if the backend is not up, saying so beats opening a
      # browser onto a broken page.
      unless backend_reachable?(config, children[0])
        stop_all(children)
        puts
        bad(t('script.backend_failed'))
        return 1
      end

      unless without_frontend
        heading(t('script.frontend_starting'))
        children << start_frontend
      end

      # The browser goes to the *Vite* server, not to the backend. In
      # development backend/public/ is empty — the backend has no interface to
      # show. Vite serves the application and proxies /api, /health and
      # /version through, so the browser sees a single origin and the cookie
      # rules from SEC-03 behave as they will in production (18.7).
      app_address = "http://#{VITE_HOST}:#{VITE_PORT}"
      unless without_browser
        wait_for_frontend
        open_browser(app_address)
      end

      puts
      say(t('script.open_manually', address: app_address)) unless without_frontend
      say(t('script.quit_with_ctrl_c'))

      watch_backend(children)
      0
    ensure
      stop_all(children || [])
    end

    # --- preparation -------------------------------------------------------

    # There is no `install` during development. If config.yml is missing it is
    # created from the template, with mode 0600 — so the development
    # environment does not behave differently from operation (SEC-20).
    def ensure_configuration
      return if File.exist?(config_file)

      say(t('script.config_missing_dev'))
      content = File.read(config_template, encoding: 'UTF-8')

      FileUtils.mkdir_p(File.dirname(config_file))
      write_private(config_file, content)
      ok(t('script.config_created'))
    end

    # The mode is part of the create call, not a chmod afterwards. Writing
    # first and tightening second leaves `trusted_proxies` readable by every
    # account on the machine for as long as the write takes — short, but it is
    # exactly the window SEC-20 exists to close, and closing it costs nothing.
    #
    # On Windows the mode argument is ignored and the file inherits the
    # directory ACL; that is the same behaviour as before and is why SEC-20
    # names an ACL there rather than a mode.
    def write_private(path, content)
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(content)
      end
    end

    def ensure_dependencies(without_frontend)
      unless File.exist?(lockfile)
        say(t('script.lockfile_missing'))
        system(bundle_env, 'bundle', 'lock', chdir: root)
      end

      unless gems_present?
        say(t('script.installing_dependencies'))
        system(bundle_env, 'bundle', 'install', chdir: root)
      end

      return if without_frontend
      return unless File.file?(File.join(root, 'package.json'))
      return if Dir.exist?(File.join(root, 'node_modules'))

      # npm workspace root is project/, not frontend/ — node_modules is hoisted
      # there so the test suites in tests/frontend/ can resolve their imports.
      say(t('script.installing_dependencies'))
      subcommand = File.exist?(File.join(root, 'package-lock.json')) ? 'ci' : 'install'
      system(windows? ? 'npm.cmd' : 'npm', subcommand, chdir: root)
    end

    # Uses the very same validation the application performs at startup, so
    # there is one place where "valid configuration" is defined. Returns nil
    # after printing the problems.
    def load_configuration
      # Absolute path, so `require` works regardless of the layout — the
      # directory is backend/ during development and app/ after building.
      require File.join(app_dir, 'services', 'configuration')
      Configuration.load(root: root)
    rescue Configuration::Error => e
      puts
      e.problems.each { |line| bad(line) }
      puts
      say(I18n.t_safe('config.aborted', 'Start abgebrochen.'))
      nil
    end

    # Waits for the backend to answer, but gives up as soon as the process is
    # gone — otherwise a configuration abort would cost the full timeout before
    # the user learns anything.
    def backend_reachable?(config, pid, timeout: 25)
      host     = config['server.host']
      port     = config['server.port']
      deadline = Time.now + timeout

      while Time.now < deadline
        return false if process_finished?(pid)

        begin
          TCPSocket.new(host, port).close
          return true
        rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, SocketError
          sleep 0.3
        end
      end
      false
    end

    def process_finished?(pid)
      !Process.waitpid(pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      true
    end

    def gems_present?
      _, status = Open3.capture2e(bundle_env, 'bundle', 'check', chdir: root)
      status.success?
    rescue Errno::ENOENT
      false
    end

    # --- processes ---------------------------------------------------------

    def start_backend
      spawn(bundle_env('RACK_ENV' => 'development'),
            'bundle', 'exec', 'puma', '-C', puma_config,
            chdir: root, **own_group)
    end

    def start_frontend
      spawn(windows? ? 'npm.cmd' : 'npm', 'run', 'dev', chdir: root, **own_group)
    end

    # Each child gets a process group of its own — and that is not a detail.
    #
    # Ctrl+C goes to the whole foreground group. Without this, Puma receives it
    # directly *and* gets the TERM this script sends a moment later. It then
    # runs a second shutdown while the first is still in a signal handler, and
    # joins a thread from inside a trap:
    #
    #   No live threads left. Deadlock? (fatal)
    #
    # followed by a stack trace that looks like a broken application. Reported
    # after AP-10. With its own group the child hears exactly one signal — the
    # one this script sends deliberately, which is what "both processes are
    # stopped together" is supposed to mean.
    #
    # It also closes a gap the other way round: `npm run dev` starts Vite as a
    # child of its own. Terminating npm alone left Vite holding port 5173.
    # Signalling the group takes both.
    def own_group
      windows? ? { new_pgroup: true } : { pgroup: true }
    end

    # Opening the browser before Vite is listening shows a connection error and
    # the user has to reload by hand. Waiting a few seconds is cheaper than
    # that. If Vite does not come up, open anyway — the browser error is then
    # the honest signal.
    def wait_for_frontend(timeout: 20)
      deadline = Time.now + timeout
      while Time.now < deadline
        begin
          TCPSocket.new(VITE_HOST, VITE_PORT).close
          return true
        rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
          sleep 0.3
        end
      end
      false
    end

    def open_browser(address)
      command = if windows?
                  ['cmd', '/c', 'start', '', address]
                elsif RbConfig::CONFIG['host_os'] =~ /darwin/
                  ['open', address]
                else
                  ['xdg-open', address]
                end
      spawn(*command, out: File::NULL, err: File::NULL)
    rescue Errno::ENOENT
      note(t('script.browser_failed', address: address))
    end

    # --- auto reload -------------------------------------------------------

    def watch_backend(children)
      state = file_state
      loop do
        sleep POLL_INTERVAL
        current = file_state
        next if current == state

        state = current
        say(t('script.reload_detected'))
        stop(children[0])
        children[0] = start_backend
      end
    rescue Interrupt
      nil
    end

    def file_state
      Dir.glob(File.join(app_dir, '**', '*.rb'))
         .reject { |p| p.include?("#{File::SEPARATOR}vendor#{File::SEPARATOR}") }
         .to_h { |p| [p, File.mtime(p).to_f] }
    end

    # --- shutdown ----------------------------------------------------------

    def trap_shutdown(children)
      %w[INT TERM].each do |signal|
        Signal.trap(signal) do
          puts
          puts "   #{I18n.t('script.stopping')}"
          stop_all(children)
          exit 0
        end
      end
    end

    def stop_all(children)
      children.compact.each { |pid| stop(pid) }
      children.clear
    end

    def stop(pid)
      return if pid.nil?

      signal(windows? ? 'KILL' : 'TERM', pid)
      # Allow a short grace period, then insist.
      20.times do
        return if Process.waitpid(pid, Process::WNOHANG)

        sleep 0.1
      end
      signal('KILL', pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    # The whole group, not just the one process — see own_group. A negative
    # number means the group in Ruby as it does in the shell. Windows has no
    # such notion, so there the process itself is signalled and its children
    # follow when it goes.
    def signal(name, pid)
      Process.kill(name, windows? ? pid : -pid)
    rescue Errno::ESRCH
      Process.kill(name, pid)
    end
  end
end

exit PromptAtelier::StartDevelopment.run(ARGV) if $PROGRAM_NAME == __FILE__
