# frozen_string_literal: true

# scripts/lib/start_portable.rb — run the application in the foreground
# (18.5, 18.6, 18.10, BT-05, E-14)
#
# The operating mode that touches nothing: no service, no elevated rights, no
# autostart. Meant for trying the application out, for single-user use and for
# running it from a removable drive. Ctrl+C stops it.
#
# **It was missing, and `install` already pointed at it.** The last line of a
# finished installation names `scripts/start_portable.sh` — a file that did not
# exist until now. Nothing failed while building the earlier packages, because
# nothing calls the closing line of another script.
#
# Two decisions are load-bearing:
#
#   * **The child gets a process group of its own.** Ctrl+C goes to the whole
#     foreground group, so Puma would receive it directly *and* the TERM this
#     script sends a moment later. It then shuts down twice at once and ends in
#     `No live threads left. Deadlock? (fatal)` — a stack trace that looks like
#     a broken application. The same lesson as TF-644b in `start_development`.
#   * **The backup is taken after the wait, not inside the signal handler.** A
#     handler that opens a database and writes a file is a handler that can
#     deadlock. It sends the signal and nothing else; the backup happens in the
#     ordinary flow, once the application has really stopped (18.10).

require 'fileutils'
require 'socket'
require_relative 'common'

module PromptAtelier
  module StartPortable
    extend Script

    # How long Puma is given to shut down cleanly before it is insisted upon.
    GRACE_SECONDS = 20

    module_function

    def run(argv = [])
      # **Before the first line is printed**, and that is not a matter of
      # taste. Bundler switches to the version named in the lockfile by
      # **re-executing the whole process** with the same arguments. Everything
      # printed before that point is printed a second time, and the screen
      # showed
      #
      #     == Starting Prompt Atelier
      #
      #     == Starting Prompt Atelier
      #        Address: http://localhost:9292
      #
      # which reads like something went wrong when nothing did. Reported from a
      # Windows installation, where the switch happens because `install` had
      # just fetched a newer Bundler. Every other script already activates
      # first; this one was the exception.
      activate_gems!

      heading(t('portable.title'))

      config = load_configuration
      return 1 if config.nil?

      say(t('portable.address', url: address_of(config)))
      say(t('portable.stop_hint'))

      return 1 unless port_free?(config)

      status = supervise
      return status unless status.zero?

      argv.include?('--no-backup') ? 0 : backup_on_exit(config)
    end

    # The configuration is read **before** anything starts, so that a bad value
    # is a message here rather than a process that dies a second later with its
    # reason buried in Puma's output. The same finding as NT-0.
    def load_configuration
      require File.join(app_dir, 'services', 'configuration')

      Configuration.load(root: root)
    rescue Configuration::Error => e
      puts
      e.problems.each { |line| bad(line) }
      nil
    end

    # --- the process ----------------------------------------------------------

    # Asked before Puma is started, so a port somebody else holds is one
    # sentence instead of thirty lines of stack trace ending in
    # `Errno::EADDRINUSE`. The most likely holder is the instance somebody
    # thought they had stopped, so that is what the message says first.
    def port_free?(config)
      server = TCPServer.new(config['server.host'], config['server.port'])
      server.close
      true
    rescue Errno::EADDRINUSE, Errno::EACCES
      puts
      bad(t('portable.port_taken', port: config['server.port']))
      false
    end

    def supervise
      pid = spawn(*environment, *command, chdir: root, **own_group)
      trap_shutdown(pid)

      _, status = Process.waitpid2(pid)
      puts
      # Puma stopped by signal reports no exit code. That is the normal end of
      # this script, not a failure — treating it as one would make every Ctrl+C
      # look like a crash.
      return 0 if status.exitstatus.nil? || status.exitstatus.zero?

      bad(t('portable.ended_badly', code: status.exitstatus))
      status.exitstatus
    rescue Errno::ECHILD
      0
    end

    # The same command the service unit runs (18.6, TF-645). Host and port are
    # deliberately absent from both: they come from config.yml and must have
    # exactly one source (BT-19). Why Ruby is invoked on Bundler's script
    # rather than on `bundle` is in `common.rb` — on Windows the difference
    # decides whether this script can stop what it started.
    def command
      application_command
    end

    def environment
      [bundle_env('RACK_ENV' => 'production')]
    end

    def own_group
      windows? ? { new_pgroup: true } : { pgroup: true }
    end

    # Only the signal, nothing else — see the file header.
    def trap_shutdown(pid)
      %w[INT TERM].each do |name|
        Signal.trap(name) do
          puts
          puts "   #{I18n.t('portable.stopping')}"
          stop(pid)
        end
      end
    end

    def stop(pid)
      signal(windows? ? 'KILL' : 'TERM', pid)

      (GRACE_SECONDS * 10).times do
        return if Process.waitpid(pid, Process::WNOHANG)

        sleep 0.1
      end
      signal('KILL', pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    # The whole group rather than the one process, see own_group. A negative
    # number means the group, in Ruby as in the shell. Windows has no such
    # notion, so there the process itself is signalled.
    def signal(name, pid)
      Process.kill(name, windows? ? pid : -pid)
    rescue Errno::ESRCH
      Process.kill(name, pid)
    end

    # --- the backup on the way out --------------------------------------------

    # 18.10 puts the schedule for portable operation at shutdown, and that is
    # the only moment this mode has: nobody sets up a timer for a program they
    # start by hand. Whoever pulls the stick out afterwards has the last state
    # in `data/backups/`.
    #
    # A failure is **said out loud** and ends the run non-zero. A backup that
    # quietly did not happen is worse than none at all, because the directory
    # full of older files suggests one was taken.
    def backup_on_exit(config)
      unless File.file?(config.database_path)
        note(t('portable.no_database_yet'))
        return 0
      end

      require_relative 'backup'
      BackupScript.run([]).zero? ? 0 : 1
    end

    def address_of(config)
      config['server.base_url'] || "http://#{config['server.host']}:#{config['server.port']}"
    end
  end
end

exit PromptAtelier::StartPortable.run(ARGV) if $PROGRAM_NAME == __FILE__
