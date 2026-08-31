# frozen_string_literal: true

require_relative '../../test_helper'
require 'install'
# `install` requires this itself in step 5, before it asks anything. Loaded
# here because the cases below call into the asking directly.
require 'services/password'
require 'open3'

# What step 5 of `install` does with an answer it cannot use (BT-03, BT-15).
#
# **From a Windows installation:** four unfamiliar questions in a row, one of
# them answered with Enter, and the run ended — after the configuration had
# been written, the schema applied and several minutes spent compiling
# libraries. `ask_port` two steps earlier already loops; this step simply did
# not follow the pattern standing in the same file.
#
# Tested at the decision, not through a terminal: what is under test is whether
# it asks again, and a real terminal cannot be typed into from here.
class InstallAnswersTest < PromptAtelier::TestCase
  Install = PromptAtelier::Install

  # `common.rb` sets this when a script loads, so a real run is English from
  # its first line. The shared test helper puts every suite back to German
  # afterwards — right for the suites about the browser, wrong here. Restored,
  # and the **effect** on a real process is checked in `wrong_package_test`,
  # where nothing resets anything.
  def setup
    super
    PromptAtelier::I18n.default_language = PromptAtelier::I18n::BASE_LANGUAGE
  end

  # --- typed answers ---------------------------------------------------------

  def test_an_empty_answer_is_asked_again_and_the_second_one_counts
    answers = ['', '  ', 'Anna Beispiel']
    value = nil

    out, = capture_io do
      Install.stub(:ask, ->(_question) { answers.shift }) do
        value = Install.ask_until(nil, 'Name?') { |entry| !entry.empty? }
      end
    end

    assert_equal 'Anna Beispiel', value
    assert_includes out, 'try again'
  end

  # An address without an @ cannot sign in afterwards, so it is refused here
  # rather than accepted and discovered at the first attempt to use it.
  def test_an_address_that_could_never_sign_in_is_asked_again
    answers = ['formic', 'formic@localhost', 'formic@example.com']
    value = nil

    capture_io do
      Install.stub(:ask, ->(_question) { answers.shift }) do
        value = Install.ask_until(nil, 'E-Mail?') { |entry| Install.valid_email?(entry) }
      end
    end

    assert_equal 'formic@example.com', value
  end

  # It gives up eventually. A loop that never ends would spin for ever against
  # a terminal that keeps returning nothing at the end of its input — the
  # question would scroll past for ever and nobody could stop it.
  def test_it_gives_up_after_a_few_attempts_and_says_nothing_is_lost
    out, = capture_io do
      Install.stub(:ask, ->(_question) { '' }) do
        assert_nil Install.ask_until(nil, 'Name?') { |entry| !entry.empty? }
      end
    end

    assert_includes out, 'run install again'
  end

  # A short password is a slip like any other, and the run has four steps of
  # work behind it by then.
  def test_a_password_that_the_policy_refuses_is_asked_again
    attempts = ['kurz', 'ein-langes-testpasswort']
    value = nil

    out, = capture_io do
      Install.stub(:ask_password, -> { attempts.shift }) do
        value = Install.ask_password_until(nil)
      end
    end

    assert_equal 'ein-langes-testpasswort', value
    assert_includes out, 'at least', 'and the reason is said in English (E-12, BT-16)'
  end

  # --- the console speaks English (E-12, BT-16) ----------------------------

  # The **mechanism**, observed in a process of its own: loading a script sets
  # the language to the base table. Most console namespaces exist only there
  # and are English by themselves; `password.*` is not, because the browser
  # shows those sentences too — and a German line appeared in the middle of an
  # English installation on a Windows machine.
  #
  # In a process, because the shared test helper puts every suite back to
  # German and would answer this question with its own setting.
  def test_loading_a_script_puts_the_console_into_the_base_language
    output, = Open3.capture2e(
      script_env,
      RbConfig.ruby, '-e',
      "$LOAD_PATH.unshift('#{File.join(CODE_ROOT, 'scripts', 'lib')}'); require 'common'; " \
      "puts PromptAtelier::I18n.language; puts PromptAtelier::I18n.t('password.too_short', minimum: 12)"
    )

    assert_includes output, 'en'
    assert_includes output, 'at least', 'and the base table has to answer the key at all'
    refute_includes output, 'Das Passwort'
  end

  # --- switches --------------------------------------------------------------

  # A switch comes from a script. Nobody is there to correct it, and asking a
  # terminal that does not exist would hang — so an unusable one still ends the
  # run.
  def test_an_unusable_switch_is_not_asked_about_but_refused
    out, = capture_io do
      assert_nil Install.ask_until('', 'Name?') { |entry| !entry.empty? }
      assert_nil Install.ask_password_until('kurz')
    end

    assert_includes out, 'switch'
  end

  def test_a_usable_switch_is_taken_as_it_stands
    assert_equal 'Anna', Install.ask_until('  Anna  ', 'Name?') { |entry| !entry.empty? }
    assert_equal 'ein-langes-testpasswort', Install.ask_password_until('ein-langes-testpasswort')
  end
  # TF-690 — the start check has to start something it can also stop.
  #
  # **Measured in a Windows virtual machine.** It spawned `bundle`, which is
  # `bundle.bat` there, so a `cmd.exe` started Puma as a child of its own. The
  # kill afterwards ended the wrapper and left Puma holding the port, and the
  # leftover process had to be ended by hand. Going through the same entry
  # point the service uses gives one process that **is** Puma.
  def test_the_start_check_launches_the_entry_point_of_the_service
    source = File.read(File.join(CODE_ROOT, 'scripts', 'lib', 'install.rb'))
    spawn_body = source[/def spawn_application.*?\n    end/m]

    refute_nil spawn_body
    assert_includes spawn_body, 'service_run.rb'
    refute_includes spawn_body, "'bundle'",
                    'a wrapper process is not the process that holds the port'
  end
end
