# frozen_string_literal: true

# scripts/lib/service_uninstall.rb — take the service off the system
# (18.5, BT-04, BT-07, TF-612)
#
# **`config/` and `data/` are not touched, and that is the whole promise of
# this script.** Somebody who removes the service wants it off the machine,
# not their prompts gone. The two live in different directories precisely so
# that this distinction can be kept (18.2).
#
# Runnable twice (BT-07): a service that is already gone is not an error, it
# is the desired state, and the script says so instead of failing.

require 'fileutils'
require_relative 'common'
require_relative 'service_install'
require_relative 'service_unit'

module PromptAtelier
  module ServiceUninstall
    extend Script

    module_function

    def run(argv = [])
      heading(t('service.uninstall_title'))

      return windows_service if windows?

      scope = argv.include?('--system') ? :system : :user
      linux_service(scope)
    end

    def linux_service(scope)
      unless available?('systemctl')
        bad(t('service.no_systemd'))
        return 1
      end

      path = ServiceUnit.unit_path(scope: scope)
      unless File.file?(path)
        ok(t('service.already_gone'))
        return 0
      end

      # `stop` and `disable` on a unit that is already stopped answer with a
      # non-zero status on some versions. Their outcome is not what matters —
      # what matters is that the unit file is gone afterwards, and that is
      # checked below rather than assumed from an exit code.
      ServiceUnit.uninstall_plan(scope: scope).each do |kind, *arguments|
        case kind
        when :run    then capture(*arguments.first)
        when :delete then FileUtils.rm_f(arguments.first)
        end
      end

      if File.file?(path)
        bad(t('service.uninstall_failed', path: path))
        return 1
      end

      ok(t('service.uninstalled'))
      say(t('service.data_kept'))

      # Named rather than undone. `enable-linger` is a machine-wide setting
      # that outlives this service and may have been set for something else, so
      # switching it off here could take away what somebody else relies on.
      if scope == :user && ServiceUnit.linger_still_set?
        say(t('service.linger_kept', command: ServiceUnit.disable_linger_command.join(' ')))
      end

      0
    end

    def windows_service
      unless ServiceUnit.nssm_available?
        bad(t('service.no_nssm', path: ServiceUnit.nssm_path))
        return 1
      end

      capture(ServiceUnit.nssm_path, 'stop', ServiceUnit::NAME)
      success, = capture(ServiceUnit.nssm_path, 'remove', ServiceUnit::NAME, 'confirm')
      unless success
        bad(t('service.uninstall_failed', path: ServiceUnit::NAME))
        return 1
      end

      ok(t('service.uninstalled'))
      say(t('service.data_kept'))
      0
    end
  end
end

exit PromptAtelier::ServiceUninstall.run(ARGV) if $PROGRAM_NAME == __FILE__
