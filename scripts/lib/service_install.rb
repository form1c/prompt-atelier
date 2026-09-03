# frozen_string_literal: true

# scripts/lib/service_install.rb — register the application as a service
# (18.5, 18.6, BT-04, BT-06, BT-07, BT-15)
#
# Four operating modes come out of two decisions: Linux or Windows, and — on
# Linux — user service or system service. The user service is the default,
# because it needs no administrator; the system service is there for machines
# where nobody logs in.
#
# What the script does **not** do is decide for anybody. Where a step needs
# elevated rights, or where a wrapper is missing, it says so and names the
# command rather than quietly doing something else that looks similar. A
# scheduled task instead of a service would be exactly that: it starts at boot
# and is not restarted after a crash, so somebody would believe they had BT-06
# when they do not.

require 'etc'
require 'fileutils'
require_relative 'common'
require_relative 'service_unit'

module PromptAtelier
  module ServiceInstall
    extend Script

    module_function

    def run(argv = [])
      heading(t('service.install_title'))

      return windows_service(argv) if windows?

      scope = argv.include?('--system') ? :system : :user
      linux_service(scope)
    end

    # --- Linux ---------------------------------------------------------------

    def linux_service(scope)
      unless available?('systemctl')
        bad(t('service.no_systemd'))
        return 1
      end

      say(t("service.scope_#{scope}"))
      return 1 unless carry_out(ServiceUnit.install_plan(scope: scope))

      ok(t('service.installed', path: ServiceUnit.unit_path(scope: scope)))
      linger(scope)
      say(t('service.status_hint', command: ServiceUnit.systemctl(scope, 'status', ServiceUnit::NAME).join(' ')))
      0
    end

    # The one step of a user service that **may** need elevated rights (18.1).
    # Measured on Debian 13: the call succeeded as the ordinary user, because
    # polkit grants `org.freedesktop.login1.set-self-linger` to an active local
    # session without asking. Saying it always needs elevation would send
    # somebody looking for a rights problem they do not have.
    # fail — and then the service is still set up, because a service that runs
    # after the next login is worth more than none at all. What must not happen
    # is that the failure goes unmentioned: somebody would reboot the machine
    # and find nothing running, with no idea which of the steps was the reason.
    def linger(scope)
      return unless ServiceUnit.linger_needed?(scope)

      command = ServiceUnit.linger_command
      success, = capture(*command)

      if success
        ok(t('service.linger_done'))
      else
        note(t('service.linger_failed', command: command.join(' ')))
      end
    end

    # --- Windows -------------------------------------------------------------

    def windows_service(_argv)
      # Said before anything is attempted, not afterwards. Creating a Windows
      # service needs an administrator, and the Linux path has named its
      # equivalent since the beginning.
      say(t('service.windows_needs_admin'))

      unless ServiceUnit.nssm_available?
        bad(t('service.no_nssm', path: ServiceUnit.nssm_path))
        say(t('service.nssm_fallback'))
        say("   #{ServiceUnit.scheduled_task_command.join(' ')}")
        return 1
      end

      # **Asked before installing, not read out of the failure afterwards.**
      # `nssm install` refuses when the name is taken, and it says so in the
      # language of the machine it runs on. Matching that text would be a check
      # that works in German and not in Polish. The question itself does not
      # depend on a language.
      if service_exists?
        bad(t('service.already_there', name: ServiceUnit::NAME))
        return 1
      end

      unless carry_out(ServiceUnit.nssm_plan)
        show_service_log
        return 1
      end

      ok(t('service.installed_windows'))
      0
    end

    # The service writes there, so when it will not stay up the reason is in
    # that file and not on this screen. Reading it out here saves the round trip
    # of asking somebody to go and look, which is a round trip this took four
    # times.
    def show_service_log
      path = ServiceUnit.service_log
      return unless File.file?(path)

      lines = File.readlines(path).last(5).map(&:strip).reject(&:empty?).uniq
      return if lines.empty?

      say(t('service.log_says', path: path))
      lines.each { |line| say("   #{line}") }
    end

    def service_exists? = capture(ServiceUnit.nssm_path, 'status', ServiceUnit::NAME).first

    # --- carrying out a plan -------------------------------------------------

    # One place that turns a plan into actions, so the plan itself stays a
    # value a test can read on a machine with no systemd at all.
    #
    # A `run` step that fails stops everything: half a service is worse than
    # none, because it looks installed.
    def carry_out(plan)
      # What the last command said while reporting success. Normally of no
      # interest and therefore not printed. It becomes the only evidence there
      # is the moment a check finds that the command did not do what its exit
      # code claimed, and it used to be thrown away at exactly that point.
      last_output = nil

      plan.each do |kind, *arguments|
        case kind
        when :write  then write_unit(*arguments)
        when :delete then FileUtils.rm_f(arguments.first)
        when :run
          command = arguments.first
          success, output = capture(*command)
          if success
            last_output = output
            next
          end

          bad(t('service.command_failed', command: command.join(' ')))
          say(output.to_s.lines.last(3).join.strip) unless output.to_s.strip.empty?
          return false
        when :verify
          # A step that asks whether the previous one did what it said. It
          # exists because one of them said yes and had not.
          next if capture(*arguments.first).first

          bad(t('service.not_created'))
          say(t('service.last_said', output: last_output.to_s.lines.last(3).join.strip)) \
            unless last_output.to_s.strip.empty?
          return false
        end
      end
      true
    end

    def write_unit(path, contents)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end
  end
end

exit PromptAtelier::ServiceInstall.run(ARGV) if $PROGRAM_NAME == __FILE__
