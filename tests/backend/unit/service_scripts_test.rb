# frozen_string_literal: true

require_relative '../../test_helper'

$LOAD_PATH.unshift(File.join(CODE_ROOT, 'scripts', 'lib'))
require 'service_install'
require 'service_uninstall'

# The decisions of `service_install` and `service_uninstall` (BT-04, BT-07,
# BT-15).
#
# What actually registers a service needs systemd or Windows; what can be
# checked here is every branch that decides **whether** to, and what it says
# when it will not. Those are the branches a person meets when something is
# wrong, which is when the wording matters most.
class ServiceScriptsTest < PromptAtelier::TestCase
  Install = PromptAtelier::ServiceInstall
  Uninstall = PromptAtelier::ServiceUninstall

  # --- a machine without systemd -------------------------------------------

  # Not an error in the application, a fact about the machine. So it says what
  # to use instead rather than only what is missing (BT-15).
  def test_without_systemd_it_names_the_portable_mode_instead
    status = nil
    out, = capture_io do
      Install.stub(:available?, false) { status = Install.run([]) }
    end

    assert_equal 1, status
    assert_includes out, 'systemctl'
    assert_includes out, 'start_portable'
  end

  # --- Windows without the wrapper -----------------------------------------

  # Ruby scripts cannot be a Windows service on their own, so a wrapper is
  # needed at all (18.6). Missing it, the script offers the scheduled task —
  # and says in the same breath that it is **not** the same thing.
  def test_on_windows_without_the_wrapper_the_fallback_is_offered_and_qualified
    status = nil
    out, = capture_io do
      Install.stub(:windows?, true) do
        PromptAtelier::ServiceUnit.stub(:nssm_available?, false) { status = Install.run([]) }
      end
    end

    assert_equal 1, status
    assert_includes out, 'schtasks'
    assert_includes out, 'NOT restarted after a crash',
                    'offering a weaker thing without saying so would leave BT-06 unmet in silence'
  end

  # --- removing twice (BT-07) ----------------------------------------------

  def test_removing_a_service_that_is_not_there_is_the_desired_state_not_an_error
    status = nil
    out, = capture_io do
      Uninstall.stub(:available?, true) do
        PromptAtelier::ServiceUnit.stub(:unit_path, '/does/not/exist.service') do
          status = Uninstall.run([])
        end
      end
    end

    assert_equal 0, status, 'a second run must not fail'
    assert_includes out, 'no service to remove'
  end

  # The promise of this script: config/ and data/ are not part of a service.
  def test_removing_says_that_the_data_stayed
    unit = File.join(install_dir('service'), 'promptatelier.service')
    File.write(unit, 'placeholder')
    status = nil

    out, = capture_io do
      Uninstall.stub(:available?, true) do
        Uninstall.stub(:capture, [true, '']) do
          PromptAtelier::ServiceUnit.stub(:unit_path, unit) { status = Uninstall.run([]) }
        end
      end
    end

    assert_equal 0, status
    refute File.exist?(unit), 'the unit file has to be gone'
    assert_includes out, 'config/ and data/ were left untouched'
  end

  # --- a name that is already taken (TF-685) --------------------------------

  # A Windows service outlives the directory it was installed from, so a failed
  # attempt leaves one behind and the next `nssm install` refuses. The refusal
  # arrives in the language of the machine, so the question is asked before
  # installing rather than read out of the answer.
  def test_an_existing_service_is_named_before_anything_is_attempted
    out, = capture_io do
      PromptAtelier::ServiceUnit.stub(:nssm_available?, true) do
        Install.stub(:capture, [true, '']) do
          assert_equal 1, Install.send(:windows_service, [])
        end
      end
    end

    assert_includes out, 'already registered'
    assert_includes out, 'service_uninstall'
  end

  def test_a_free_name_lets_the_installation_proceed
    answers = [[false, ''], [false, 'boom']]
    out, = capture_io do
      PromptAtelier::ServiceUnit.stub(:nssm_available?, true) do
        Install.stub(:capture, ->(*) { answers.shift || [false, ''] }) do
          Install.send(:windows_service, [])
        end
      end
    end

    refute_includes out, 'already registered', 'a free name must not look taken'
  end

  # --- what the service itself said (TF-686) --------------------------------

  # Four device tests ended with "send me the log file". The script can read it.
  def test_a_failed_registration_reads_out_the_service_log
    log = File.join(PromptAtelier::ServiceUnit.send(:root), 'data', 'logs', 'service.log')
    FileUtils.mkdir_p(File.dirname(log))
    File.write(log, "bundler: command not found: puma\n")

    out, = capture_io do
      PromptAtelier::ServiceUnit.stub(:nssm_available?, true) do
        Install.stub(:service_exists?, false) do
          Install.stub(:carry_out, false) { Install.send(:windows_service, []) }
        end
      end
    end

    assert_includes out, 'command not found: puma'
  ensure
    FileUtils.rm_f(log)
  end

  # --- what the removal leaves behind (TF-695) -------------------------------

  # Measured in a Debian machine: after `service_uninstall` the unit files are
  # gone and `Linger=yes` remains. The setting is machine-wide and may have been
  # set by something else, so it is named rather than undone.
  def test_the_removal_says_that_lingering_stays_on
    assert_includes removal_output(lingering: true), 'Lingering stays switched on'
    assert_includes removal_output(lingering: true), 'disable-linger'
  end

  def test_it_says_nothing_when_lingering_was_never_set
    refute_includes removal_output(lingering: false), 'Lingering stays switched on'
  end

  # A unit file has to exist, otherwise the removal answers "there is no service
  # to remove" and never reaches the line under test. Written into a throwaway
  # directory and deleted by the plan itself.
  def removal_output(lingering:)
    unit = File.join(install_dir('linger_probe'), 'promptatelier.service')
    FileUtils.mkdir_p(File.dirname(unit))
    File.write(unit, "[Unit]\n")

    out, = capture_io do
      PromptAtelier::ServiceUnit.stub(:unit_path, unit) do
        PromptAtelier::ServiceUnit.stub(:linger_still_set?, lingering) do
          Uninstall.stub(:available?, true) do
            Uninstall.stub(:capture, [true, '']) { Uninstall.send(:linux_service, :user) }
          end
        end
      end
    end
    out
  end

  # --- carrying out a plan (TF-683) ----------------------------------------

  # The step that exists because an exit code lied. `carry_out` has to treat a
  # failed `:verify` like a failed `:run`: report it and stop, rather than
  # carrying on to configure a service that is not there.
  def test_a_failed_check_stops_the_plan_and_says_what_it_means
    out, = capture_io do
      Install.stub(:capture, [false, '']) do
        assert_equal false, Install.send(:carry_out, [[:verify, [['nssm', 'status', 'x']]]])
      end
    end

    assert_includes out, 'The service was not created'
    assert_includes out, 'administrator', 'the likely reason belongs in the message'
  end

  # The evidence that used to be thrown away. `nssm install` answered 0 and
  # printed something while doing nothing, and `carry_out` dropped that text
  # because the command had "succeeded". It is the only thing that says why.
  def test_a_failed_check_repeats_what_the_successful_step_had_said
    answers = [[true, 'Access is denied.'], [false, '']]
    out, = capture_io do
      Install.stub(:capture, ->(*) { answers.shift }) do
        Install.send(:carry_out, [[:run, [['nssm', 'install', 'x']]],
                                  [:verify, [['nssm', 'status', 'x']]]])
      end
    end

    assert_includes out, 'Access is denied.'
  end

  def test_a_passing_check_lets_the_plan_continue
    reached = false
    Install.stub(:capture, [true, '']) do
      plan = [[:verify, [['nssm', 'status', 'x']]], [:delete, '/nonexistent/marker']]
      reached = Install.send(:carry_out, plan)
    end

    assert reached, 'a check that passes must not stop anything'
  end

  # The counter-case to the message above: it is said **before** the attempt,
  # so somebody without rights learns it while it can still be acted on.
  def test_windows_names_the_rights_it_needs_before_it_tries
    out, = capture_io do
      PromptAtelier::ServiceUnit.stub(:nssm_available?, false) do
        Install.send(:windows_service, [])
      end
    end

    assert_includes out, 'needs an administrator'
  end

  # --- the scope is chosen by switch ---------------------------------------

  # The user service is the default because it needs no administrator (18.6).
  def test_the_user_service_is_the_default_and_the_system_service_is_asked_for
    user_out, = capture_io do
      Install.stub(:available?, true) do
        Install.stub(:carry_out, false) { Install.run([]) }
      end
    end
    system_out, = capture_io do
      Install.stub(:available?, true) do
        Install.stub(:carry_out, false) { Install.run(['--system']) }
      end
    end

    assert_includes user_out, 'no administrator rights needed'
    assert_includes system_out, 'administrator rights'
  end

  # --- lingering ------------------------------------------------------------

  # It may fail, and then the service is still set up: one that runs after the
  # next login is worth more than none. What must not happen is that the
  # failure goes unmentioned — somebody would reboot and find nothing running.
  def test_a_failed_linger_is_reported_with_the_command_to_catch_up
    out, = capture_io do
      Install.stub(:capture, [false, 'not permitted']) { Install.linger(:user) }
    end

    assert_includes out, 'only start after somebody logs in'
    assert_includes out, 'loginctl enable-linger'
  end

  def test_a_system_service_is_not_asked_about_lingering
    out, = capture_io { Install.linger(:system) }

    assert_empty out.strip
  end
end
