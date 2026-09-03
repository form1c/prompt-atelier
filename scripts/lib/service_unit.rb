# frozen_string_literal: true

# scripts/lib/service_unit.rb — what a service is made of, without doing it
# (18.6, BT-04, BT-06)
#
# Separated from `service_install` on purpose. Registering a service needs
# systemd, an administrator, a Windows machine — none of which a test has.
# What can be checked everywhere is the **plan**: which file gets written,
# with what in it, and which commands run in which order. That is also where
# every one of the five decisions of 18.6 lives, and each of them is a line
# somebody could "simplify" into a service that does not start.

require 'rbconfig'
require_relative 'common'
require 'etc'

module PromptAtelier
  module ServiceUnit
    extend Script

    NAME = 'promptatelier'

    module_function

    # The systemd unit, built for **this** machine rather than shipped as a
    # template. Every substitution below is one of the five decisions from
    # 18.6, and the comments say what breaks without them.
    def systemd_unit(scope:, ruby: nil, bundle: nil)
      # **`Environment=` has to be quoted, `WorkingDirectory=` must not be.**
      #
      # systemd splits `Environment=` on whitespace and reads each piece as one
      # assignment. An installation under `/mnt/Eigene Projekte/…` therefore
      # arrived as `BUNDLE_GEMFILE=/mnt/Eigene` plus a second piece that systemd
      # discarded with "Invalid environment assignment". `WorkingDirectory=`
      # takes the rest of the line and needs no quotes.
      #
      # Found with `systemd-analyze verify` on the generated file. Every test in
      # this suite reads the text of the unit, and none of them had ever handed
      # it to systemd, so the unit had been wrong for as long as an installation
      # path contained a space.
      <<~UNIT
        [Unit]
        Description=Prompt Atelier
        After=network.target

        [Service]
        Type=simple
        #{scope == :system ? "User=#{owner}\nGroup=#{owner_group}\n" : ''}WorkingDirectory=#{root}
        Environment="RACK_ENV=production"
        Environment="BUNDLE_GEMFILE=#{gemfile}"
        ExecStart=#{quoted(RbConfig.ruby)} #{quoted(entry_point)}
        Restart=on-failure
        RestartSec=5

        [Install]
        WantedBy=#{scope == :system ? 'multi-user.target' : 'default.target'}
      UNIT
    end

    # `ExecStart` is split on spaces, unlike every other line of a unit.
    #
    # An installation under `/opt/prompt atelier/` or `C:\\Program Files\\…`
    # would otherwise produce a command line whose first token is `/opt/prompt`
    # — and systemd would report 203/EXEC for a file that is plainly there.
    # `WorkingDirectory` and `Environment` take the rest of the line as it
    # stands and are left alone; quoting them would make the quotes part of
    # the value.
    def quoted(path)
      path.to_s.include?(' ') ? "\"#{path}\"" : path.to_s
    end

    # **The system service runs as the account that owns the installation.**
    #
    # Without `User=` a system service runs as root, and Puma then writes
    # `data/promptatelier.pid` as root into a directory belonging to somebody
    # else. Puma does not remove that file when it is killed, and the owner of
    # the installation cannot overwrite a root-owned file. The next start, by
    # the user service or the portable mode, binds the port, then dies in
    # `write_pid` with `Errno::EACCES` and goes into a restart loop. The cause
    # sits two lines below a line that reads like a successful start.
    #
    # Measured in a Debian machine, each link of that chain separately.
    #
    # The owner of the installation directory is the right account by
    # construction: it is the one that has to be able to write `config/` and
    # `data/`. Where root owns the installation, `User=root` is what the unit
    # had all along and the problem does not arise.
    def owner
      Etc.getpwuid(File.stat(root).uid).name
    rescue StandardError
      Etc.getlogin || 'root'
    end

    def owner_group
      Etc.getgrgid(File.stat(root).gid).name
    rescue StandardError
      owner
    end

    def unit_path(scope:, home: Dir.home)
      return File.join('/etc/systemd/system', "#{NAME}.service") if scope == :system

      File.join(home, '.config', 'systemd', 'user', "#{NAME}.service")
    end

    # `systemctl` with or without `--user`, in one place: every caller below
    # would otherwise repeat the branch, and one of them would forget it.
    def systemctl(scope, *arguments)
      scope == :system ? ['systemctl', *arguments] : ['systemctl', '--user', *arguments]
    end

    # What installing consists of, in order. Returned rather than executed so
    # that a test can read it on a machine that has no systemd.
    def install_plan(scope:, home: Dir.home)
      [
        [:write, unit_path(scope: scope, home: home), systemd_unit(scope: scope)],
        [:run, systemctl(scope, 'daemon-reload')],
        [:run, systemctl(scope, 'enable', NAME)],
        [:run, systemctl(scope, 'restart', NAME)]
      ]
    end

    # Removing is the reverse, and it stops at the unit file. `config/` and
    # `data/` are not part of a service — somebody who removes the service
    # wants it off the system, not their prompts gone (BT-04, TF-612).
    def uninstall_plan(scope:, home: Dir.home)
      [
        [:run, systemctl(scope, 'stop', NAME)],
        [:run, systemctl(scope, 'disable', NAME)],
        [:delete, unit_path(scope: scope, home: home)],
        [:run, systemctl(scope, 'daemon-reload')]
      ]
    end

    # A user service starts with the **user session**, not with the machine.
    # After a reboot nothing would run until somebody logs in, and the promise
    # of an automatic start would be unmet.
    #
    # Whether this needs elevated rights depends on the machine. Measured on
    # Debian 13: the call succeeded as the ordinary user, because polkit grants
    # `set-self-linger` to an active local session without asking. Elsewhere it
    # may not, so the call is allowed to fail: the service is set up either way
    # and the command to catch up is named.
    def linger_command(user: Etc.getlogin || ENV.fetch('USER', nil))
      ['loginctl', 'enable-linger', user.to_s]
    end

    def linger_needed?(scope) = scope == :user

    # **Not undone when the service is removed, and said rather than done.**
    # `enable-linger` is a machine-wide setting that outlives the service, and
    # it may have been set by something else entirely. Switching it off could
    # therefore take away what somebody else relies on. Measured in a Debian
    # machine: after `service_uninstall` the unit files are gone and
    # `Linger=yes` remains.
    def linger_still_set?(user: Etc.getlogin || ENV.fetch('USER', nil))
      success, output = capture('loginctl', 'show-user', user.to_s, '-p', 'Linger')
      success && output.to_s.strip == 'Linger=yes'
    end

    def disable_linger_command(user: Etc.getlogin || ENV.fetch('USER', nil))
      ['loginctl', 'disable-linger', user.to_s]
    end

    # --- Windows -----------------------------------------------------------

    def nssm_path = File.join(root, 'tools', windows? ? 'nssm.exe' : 'nssm')

    def nssm_available? = File.file?(nssm_path)

    # NSSM wraps the process as a service. Ruby scripts cannot be one directly,
    # which is why a wrapper is needed at all (18.6).
    # **What NSSM starts has to be a real executable.** NSSM launches the
    # application with CreateProcess, and CreateProcess cannot run a batch
    # file: it needs an `.exe`. RubyInstaller puts three files next to each
    # other, `bundle`, `bundle.bat` and `bundle.cmd`, and none of them is one.
    #
    # Both earlier attempts got this wrong in a different way. The first
    # registered the extensionless `bundle`, the second `bundle.bat`. The
    # second was accepted by `nssm install`, because the file exists, and the
    # service then never started: NSSM retried, hit its own throttle and
    # reported SERVICE_PAUSED.
    #
    # `ruby.exe` is an executable, and the extensionless `bundle` is the Ruby
    # script it is meant to run. That pair needs no shell in between.
    # **One executable, one argument.** Measured on a Windows machine: of the
    # parameters this plan sets, `AppStdout` and `AppStderr` take effect, while
    # `AppDirectory` and `AppEnvironmentExtra` reported success and did not.
    # Read back afterwards, the first still held the directory of ruby.exe and
    # the second was empty, so the service ran in the wrong place with none of
    # its settings.
    #
    # Why those two do not hold was not established, so the plan no longer
    # depends on them. `service_run.rb` sets its own environment and changes
    # into its own directory, and what is left for the service manager is the
    # part that works.
    def service_command
      [RbConfig.ruby, entry_point]
    end

    # **Both service kinds start the same file.** systemd used to be given
    # `bundle exec puma`, which looks the command up on the PATH. That is the
    # same weakness the Windows service had, and it stayed invisible here only
    # because a system-wide Ruby gives the bundle a bin directory. A user-scoped
    # one does not, and both occur at users.
    #
    # The entry point sets its own environment, so the `Environment=` lines of
    # the unit below are a second belt rather than the thing it hangs on.


    def service_log = File.join(root, 'data', 'logs', 'service.log')

    def nssm_plan
      [
        [:run, [nssm_path, 'install', NAME, *service_command]],

        # **The exit code of `install` is not evidence that the service exists.**
        # Reported from a Windows machine: `install` returned 0, and the next
        # step then failed with "OpenService(): the specified service is not an
        # installed service". Creating a service needs an administrator, and
        # without one this is how it looks from here. So the service is asked
        # for directly, and the answer to that is the evidence.
        [:verify, [nssm_path, 'status', NAME]],

        # Kept although it was measured to have no effect on the machine this
        # was reported from. It costs nothing, it is the correct value, and
        # nothing depends on it any more.
        [:run, [nssm_path, 'set', NAME, 'AppDirectory', root]],
        [:run, [nssm_path, 'set', NAME, 'Start', 'SERVICE_AUTO_START']],

        # Where the application writes when it runs as a service. Without this
        # a service that will not start says only that it will not start, and
        # the reason is in a console nobody sees. It cost two device tests to
        # learn that, so it is set here rather than left to be discovered.
        [:run, [nssm_path, 'set', NAME, 'AppStdout', service_log]],
        [:run, [nssm_path, 'set', NAME, 'AppStderr', service_log]],

        [:run, [nssm_path, 'start', NAME]]
      ]
    end

    # The fallback when NSSM is not there. Not run automatically: a scheduled
    # task is a different thing from a service. It starts at boot but is not
    # restarted after a crash, and swapping one for the other behind somebody's
    # back would leave them believing they had a service.
    #
    # **The task starts the launcher, not `bundle` directly.** Two reasons, and
    # the first version got both wrong:
    #
    #   1. A task starts in `C:\Windows\System32` with a bare environment.
    #      `bundle exec puma` there stops with "Could not locate Gemfile",
    #      because `BUNDLE_GEMFILE` is not set and the working directory is not
    #      the installation. The launcher sets both, and it resolves its own
    #      location, so it does not care where it was started from.
    #   2. `/TR` takes **one** argument. A command with its own quoted parts
    #      has to arrive as a single quoted string, and the inner quotes have
    #      to survive the shell. Written out below rather than assembled from
    #      the pieces, because the pieces are what made it fall apart.
    def scheduled_task_command
      [
        'schtasks', '/Create', '/TN', 'PromptAtelier', '/SC', 'ONSTART', '/RL', 'HIGHEST',
        '/TR', "\"\\\"#{windows_path(launcher_path)}\\\"\""
      ]
    end

    def launcher_path = File.join(root, 'scripts', 'start_portable.bat')

    # cmd resolves forward slashes in most places but not all of them, and a
    # path shown to somebody who has to type it should look like the paths on
    # their machine.
    def windows_path(path) = path.tr('/', '\\')
  end
end
