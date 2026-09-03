# frozen_string_literal: true

require_relative '../../test_helper'
require 'etc'

$LOAD_PATH.unshift(File.join(CODE_ROOT, 'scripts', 'lib'))
require 'service_unit'

# What a service is made of (18.6, BT-04, BT-06).
#
# Registering one needs systemd, an administrator or a Windows machine — none
# of which a test has, and none of which the interesting part needs. The
# interesting part is the **plan**: which file, with what in it, and which
# commands in which order.
#
# Every case below is one of the five decisions of 18.6, and each of them is a
# line somebody could tidy away into a service that does not start. The reason
# is in the case, not only in the source.
class ServiceUnitTest < PromptAtelier::TestCase
  Subject = PromptAtelier::ServiceUnit

  def unit(scope: :user, **rest) = Subject.systemd_unit(scope: scope, **rest)

  # --- the five decisions ---------------------------------------------------

  # systemd starts services **without a login shell** and with a minimal PATH.
  # The shims of rbenv, rvm and asdf are not on it, so `/usr/bin/env bundle`
  # would find nothing and the service would die with 203/EXEC — on exactly
  # the systems a version manager was installed for.
  def test_exec_start_names_everything_by_its_absolute_path
    line = exec_start(unit)

    refute_includes line, '/usr/bin/env'
    assert_match %r{ExecStart="?/}, line, 'an absolute path, not a bare name'
    assert_includes line, 'service_run.rb'
  end

  # Sinatra ships no server (18.3.1). `ruby config.ru` aborts with
  # NoMethodError, because config.ru is a Rack configuration file and not a
  # script. The entry point loads Puma, and there is a case of its own for
  # that in this file.
  def test_it_starts_the_entry_point_and_not_the_rack_file
    assert_includes unit, 'service_run.rb'
    refute_includes unit, 'config.ru'
  end

  # The Gemfile lives in app/, the service works in the installation
  # directory. Without this the start aborts with "Could not locate Gemfile" —
  # and it is an **absolute** path, because nothing in a unit may depend on
  # how a working directory is resolved.
  def test_the_gemfile_is_named_absolutely
    line = unit.lines.grep(/BUNDLE_GEMFILE/).first

    assert_match %r{Environment="BUNDLE_GEMFILE=/}, line
    assert_includes line, 'Gemfile'
  end

  # Without it Sinatra runs in development mode and answers errors with paths
  # and stack traces — a breach of SEC-13 on a machine nobody is watching.
  def test_it_runs_in_production
    assert_includes unit, 'Environment="RACK_ENV=production"'
  end

  def test_the_working_directory_is_the_installation_directory
    assert_includes unit, "WorkingDirectory=#{Subject.root}"
  end

  # BT-06: after a crash, back within five seconds.
  def test_it_restarts_itself
    assert_includes unit, 'Restart=on-failure'
    assert_includes unit, 'RestartSec=5'
  end

  # Host and port come from config.yml and from nowhere else (18.4). In the
  # unit they would be a second source, and whoever changed the configuration
  # would keep landing on the old port.
  def test_neither_host_nor_port_appear_in_the_unit
    refute_match(/9292|127\.0\.0\.1|--port|--bind/, unit)
  end

  # --- a path with a space --------------------------------------------------

  # `ExecStart` is split on spaces, unlike every other line of a unit. An
  # installation under `/opt/prompt atelier/` would otherwise produce a
  # command line whose first token is `/opt/prompt`, and systemd would report
  # 203/EXEC for a file that is plainly there.
  # An installation under a path with a space is the normal case on Windows and
  # occurs on Linux too. The entry point is named there, so it is the one that
  # has to survive.
  def test_a_path_with_a_space_is_quoted_in_exec_start
    line = exec_start(unit)

    assert_match(/ExecStart=\S+ "?\S/, line)
    Subject.stub(:root, '/opt/prompt atelier') do
      assert_includes exec_start(Subject.systemd_unit(scope: :user)),
                      '"/opt/prompt atelier/scripts/lib/service_run.rb"'
    end
  end

  # TF-692 — **this case used to enshrine the defect.** It asserted that
  # `Environment=` is *not* quoted. systemd splits that setting on whitespace
  # and reads each piece as one assignment, so an installation under
  # `/mnt/Eigene Projekte/…` arrived as `BUNDLE_GEMFILE=/mnt/Eigene` plus a
  # second piece that systemd discarded with "Invalid environment assignment".
  #
  # Found with `systemd-analyze verify` on the generated file. Every case here
  # reads the text of the unit, and none had ever handed it to systemd.
  def test_the_environment_is_quoted_and_the_working_directory_is_not
    # Takes the rest of the line, so quotes would become part of the value.
    refute_match(/WorkingDirectory="/, unit)

    assert_match(/Environment="RACK_ENV=production"/, unit)
    assert_match(/Environment="BUNDLE_GEMFILE=[^"]+"/, unit)
  end

  # The counter-check, and the one that would have caught it: a path with a
  # space has to survive as one assignment.
  # `app_dir` is memoised, so the Gemfile is stubbed alongside the root rather
  # than derived from it.
  def test_a_space_in_the_path_does_not_split_the_environment
    Subject.stub(:root, '/opt/prompt atelier') do
      Subject.stub(:gemfile, '/opt/prompt atelier/app/Gemfile') do
        unit = Subject.systemd_unit(scope: :user)
        line = unit.lines.find { |l| l.start_with?('Environment="BUNDLE_GEMFILE') }.strip

        assert_equal 'Environment="BUNDLE_GEMFILE=/opt/prompt atelier/app/Gemfile"', line
        assert_includes unit, 'WorkingDirectory=/opt/prompt atelier',
                        'and this one stays unquoted, it takes the rest of the line'
      end
    end
  end

  def test_a_path_without_a_space_stays_unquoted
    Subject.stub(:root, '/opt/promptatelier') do
      line = exec_start(Subject.systemd_unit(scope: :user))

      assert_includes line, '/opt/promptatelier/scripts/lib/service_run.rb'
      refute_includes line, '"/opt/promptatelier'
    end
  end

  # TF-694 — the system service does not run as root.
  #
  # **Measured in a Debian machine, link by link.** Without `User=` a system
  # service runs as root, and Puma writes `data/promptatelier.pid` as root into
  # a directory belonging to somebody else. Puma does not remove that file when
  # it is killed. The owner of the installation then cannot overwrite it, so the
  # next start binds the port, dies in `write_pid` with `Errno::EACCES` and goes
  # into a restart loop. Whoever tries the system service and then pulls the
  # plug can afterwards start neither the user service nor the portable mode.
  def test_the_system_service_runs_as_the_owner_of_the_installation
    unit = Subject.systemd_unit(scope: :system)
    expected = Etc.getpwuid(File.stat(Subject.send(:root)).uid).name

    assert_includes unit, "User=#{expected}"
    assert_includes unit, 'Group='
  end

  # A user service already runs as that user. Naming it again would be a second
  # place to keep right.
  def test_a_user_service_names_no_account
    refute_includes Subject.systemd_unit(scope: :user), 'User='
  end

  # --- user and system service ---------------------------------------------

  def test_the_two_scopes_differ_in_target_and_in_path
    assert_includes unit(scope: :user), 'WantedBy=default.target'
    assert_includes unit(scope: :system), 'WantedBy=multi-user.target'

    assert_includes Subject.unit_path(scope: :user, home: '/home/x'), '/home/x/.config/systemd/user'
    assert_equal '/etc/systemd/system/promptatelier.service', Subject.unit_path(scope: :system)
  end

  def test_a_user_service_is_addressed_with_user_and_a_system_service_without
    assert_includes Subject.systemctl(:user, 'restart', 'x'), '--user'
    refute_includes Subject.systemctl(:system, 'restart', 'x'), '--user'
  end

  # A user service starts with the **user session**, not with the machine.
  # After a reboot nothing would run until somebody logs in, and BT-06 would
  # be unmet — so lingering is asked for at a user service and only there.
  def test_lingering_is_needed_for_a_user_service_only
    assert Subject.linger_needed?(:user)
    refute Subject.linger_needed?(:system)
    assert_includes Subject.linger_command(user: 'anna'), 'enable-linger'
    assert_includes Subject.linger_command(user: 'anna'), 'anna'
  end

  # --- the plans ------------------------------------------------------------

  def test_installing_writes_the_unit_before_it_reloads_and_enables
    kinds = Subject.install_plan(scope: :user, home: '/home/x').map(&:first)

    assert_equal %i[write run run run], kinds, 'the file has to exist before daemon-reload'
    commands = Subject.install_plan(scope: :user, home: '/home/x')
                      .select { |kind,| kind == :run }.map { |_, command| command.last }
    assert_equal %w[daemon-reload promptatelier promptatelier], commands
  end

  # BT-04 and TF-612: removing the service takes the unit away and nothing
  # else. Somebody who removes a service wants it off the machine, not their
  # prompts gone.
  def test_removing_touches_the_unit_and_nothing_of_config_or_data
    plan = Subject.uninstall_plan(scope: :user, home: '/home/x')
    deleted = plan.select { |kind,| kind == :delete }.map { |_, path| path }

    assert_equal [Subject.unit_path(scope: :user, home: '/home/x')], deleted
    refute(plan.flatten.compact.any? { |part| part.to_s.include?('/data') })
    refute(plan.flatten.compact.any? { |part| part.to_s.match?(%r{/config(/|$)}) })
  end

  # --- Windows --------------------------------------------------------------

  def test_the_windows_plan_asks_for_an_automatic_start
    plan = Subject.nssm_plan.map { |_, command| command.join(' ') }

    assert(plan.any? { |line| line.include?('SERVICE_AUTO_START') }, 'it has to start at boot')
    assert(plan.any? { |line| line.include?('AppDirectory') },
           'still set, although it was measured not to take hold, because it costs nothing')
  end

  # The environment moved into the entry point, so that is where it has to be.
  def test_the_entry_point_sets_the_environment_the_plan_no_longer_does
    source = File.read(File.join(CODE_ROOT, 'scripts', 'lib', 'service_run.rb'))

    %w[RACK_ENV BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_APP_CONFIG].each do |name|
      assert_includes source, "ENV['#{name}']", "#{name} is set nowhere now"
    end
  end

  # TF-683 — **the exit code of `install` was taken as evidence and was not.**
  # Reported from a Windows machine: the wrapper answered 0, the service did
  # not exist, and the next step failed with "OpenService(): the specified
  # service is not an installed service". The plan now asks for the service
  # instead of believing the answer.
  def test_the_plan_checks_that_the_service_exists_before_configuring_it
    kinds = Subject.nssm_plan.map(&:first)

    assert_equal :verify, kinds[1],
                 'the check belongs directly after installing, before anything is set'
    assert_equal :run, kinds.first
  end

  def test_the_check_asks_the_wrapper_for_the_service_by_name
    _, command = Subject.nssm_plan[1]

    assert_includes command, 'status'
    assert_includes command, Subject::NAME
  end

  # TF-684 — what NSSM is told to start.
  #
  # **Two attempts got this wrong in two different ways**, and the second was
  # my own correction of the first. NSSM launches the application with
  # CreateProcess, which needs a real executable. The extensionless `bundle` is
  # a Ruby script, `bundle.bat` is a batch file, and CreateProcess runs
  # neither. The second was worse than the first, because `nssm install`
  # accepted it: the service was created and then never started, and NSSM
  # answered SERVICE_PAUSED after hitting its own throttle.
  def test_the_service_starts_a_real_executable
    program = Subject.send(:service_command).first

    refute program.end_with?('.bat'), 'CreateProcess cannot run a batch file'
    refute program.end_with?('.cmd'), 'CreateProcess cannot run a batch file'
    assert_equal RbConfig.ruby, program, 'the interpreter is the executable, bundle is its argument'
  end

  # TF-684 — what NSSM is told to start.
  #
  # **Three attempts got this wrong, and two of them were mine.** NSSM starts
  # the application with CreateProcess, which needs a real executable: the
  # extensionless `bundle` is a Ruby script and `bundle.bat` is a batch file,
  # and neither qualifies. What settled it was reading the registration back
  # from a Windows machine.
  def test_the_service_starts_a_real_executable
    program = Subject.service_command.first

    refute program.end_with?('.bat'), 'CreateProcess cannot run a batch file'
    refute program.end_with?('.cmd'), 'CreateProcess cannot run a batch file'
    assert_equal RbConfig.ruby, program
  end

  # TF-688 — the registration asks for as little as possible.
  #
  # Read back from the registered service: `AppStdout` and `AppStderr` had
  # taken effect, `AppDirectory` still held the directory of ruby.exe and
  # `AppEnvironmentExtra` was empty, although both `set` calls had reported
  # success. The service therefore ran in the wrong directory with none of its
  # settings. Rather than guess at why, the plan stopped depending on them.
  def test_the_service_is_started_with_one_executable_and_one_argument
    command = Subject.service_command

    assert_equal 2, command.size,
                 'everything else is the entry point\'s own business'
    assert command.last.end_with?(File.join('scripts', 'lib', 'service_run.rb'))
  end

  def test_the_entry_point_it_names_exists
    assert File.file?(Subject.service_command.last), 'a service cannot start a file that is not there'
  end

  # The counter-check on the other half: nothing in the plan may reintroduce a
  # dependency on the parameter that was measured not to hold.
  def test_the_plan_does_not_rely_on_the_environment_parameter
    plan = Subject.nssm_plan.map { |_, command| command.join(' ') }

    refute(plan.any? { |line| line.include?('AppEnvironmentExtra') },
           'it reported success and did nothing, so nothing may depend on it')
  end

  # TF-689 — the executable is taken from the bundle, never from the PATH.
  #
  # **Measured in a Windows virtual machine.** `bundle exec` looks the command
  # up on the PATH after putting the bundle's own bin directory in front. That
  # directory did not exist: the Ruby there is a user-scoped RubyInstaller
  # whose built-in defaults carry
  # `--bindir C:/Users/<name>/AppData/Local/Microsoft/WindowsApps`, so every
  # gem executable of the installation landed in one person's profile. The
  # service account does not have it on its PATH.
  #
  # Adding that directory to the PATH would fix one account on one machine and
  # would make a portable installation depend on somebody's profile.
  def test_the_entry_point_resolves_puma_from_the_bundle
    source = File.read(File.join(CODE_ROOT, 'scripts', 'lib', 'service_run.rb'))

    assert_includes source, "Gem.bin_path('puma', 'puma')",
                    'the specification answers with the file inside the bundle'
    refute_includes source, "'exec', 'puma'",
                    'bundle exec goes through the PATH, which is what failed'
  end

  # Where a service that will not start says why. Two device tests were needed
  # to find out that it said nothing, because nothing collected its output.
  def test_the_plan_gives_the_service_somewhere_to_write
    plan = Subject.nssm_plan.map { |_, command| command.join(' ') }

    assert(plan.any? { |line| line.include?('AppStdout') }, 'the reason has to land somewhere')
    assert(plan.any? { |line| line.include?('AppStderr') })
  end

  # The start comes last. Setting anything after it would configure a service
  # that is already running with the previous settings.
  def test_the_service_is_started_only_once_everything_is_set
    plan = Subject.nssm_plan.map { |_, command| command.join(' ') }

    assert_includes plan.last, 'start'
  end

  # The fallback is offered, never run. A scheduled task starts at boot and is
  # **not** restarted after a crash — swapping one for the other behind
  # somebody's back would leave them believing they had BT-06.
  def test_the_scheduled_task_is_a_command_to_show_not_a_plan_to_run
    command = Subject.scheduled_task_command

    assert_includes command, 'ONSTART'
    assert_kind_of Array, command
    refute_respond_to Subject, :run_scheduled_task
  end

  # TF-681 — **The command used to be unusable, and the case above did not notice.** It
  # asked only whether `ONSTART` was in there. What the operator got was
  #
  #   /TR "<bundle>" exec puma -C "<config>"
  #
  # where `/TR` takes one argument: the shell consumed the quotes, schtasks saw
  # `exec`, `puma` and `-C` as options of its own and refused. Reported from a
  # Windows machine, not found here.
  def test_the_task_hands_over_exactly_one_argument_to_tr
    command = Subject.scheduled_task_command
    after = command[command.index('/TR') + 1..]

    assert_equal 1, after.size, '/TR takes one argument, and everything after it is that argument'
  end

  # The second half of the same defect. `bundle exec puma` from a scheduled
  # task starts in the system directory without BUNDLE_GEMFILE and stops with
  # "Could not locate Gemfile". The launcher sets both and resolves its own
  # location.
  def test_the_task_starts_the_launcher_and_not_bundle_directly
    argument = Subject.scheduled_task_command.last

    assert_includes argument, 'start_portable.bat'
    refute_includes argument, 'exec puma',
                    'calling bundle directly leaves the environment unset'
  end

  # A path with a space is the normal case on Windows, where the installation
  # tends to sit under a user profile.
  def test_the_path_inside_the_argument_stays_quoted
    argument = Subject.scheduled_task_command.last

    assert argument.start_with?('"\\"'), 'the inner quote has to survive the shell'
    assert argument.end_with?('\\""')
  end

  def test_the_path_is_written_the_way_windows_writes_paths
    argument = Subject.scheduled_task_command.last

    refute_includes argument, '/', 'a path shown to somebody who types it uses backslashes'
  end

  private

  def exec_start(text) = text.lines.grep(/ExecStart/).first.to_s.strip

end
