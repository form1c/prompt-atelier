# frozen_string_literal: true

require_relative '../../test_helper'
require 'check_environment'

# TF-601b and TF-601c — the version boundaries from Requirements 18.3.
#
# The decision logic is tested directly rather than by installing five Ruby
# and Node versions. That is the honest split: whether the *rule* is right can
# be settled here; whether it *fires* on a real machine is TF-601b/TF-601c in
# section 10, run by hand on U-LIN-ZUALT before acceptance.
class CheckEnvironmentTest < PromptAtelier::TestCase
  Checker = PromptAtelier::CheckEnvironment

  # --- TF-601b: Ruby lower bound ------------------------------------------

  def test_tf601b_ruby_31_and_32_are_below_the_minimum
    refute Checker.at_least?(Checker.version_of('3.1.7'), Checker::RUBY_MINIMUM),
           'Ruby 3.1 must be rejected: sqlite3 >= 2.9 requires Ruby >= 3.2'
    refute Checker.at_least?(Checker.version_of('3.2.9'), Checker::RUBY_MINIMUM),
           'Ruby 3.2 must be rejected: out of maintenance since March 2026'
  end

  def test_tf601b_ruby_33_and_newer_are_accepted
    %w[3.3.0 3.3.8 3.4.1 4.0.0].each do |version|
      assert Checker.at_least?(Checker.version_of(version), Checker::RUBY_MINIMUM),
             "Ruby #{version} must be accepted"
    end
  end

  # The machine this suite runs on has to satisfy its own rule — otherwise the
  # gems could not have been installed in the first place.
  def test_tf601b_the_running_interpreter_satisfies_the_minimum
    assert Checker.at_least?(Checker.version_of(RUBY_VERSION), Checker::RUBY_MINIMUM)
  end

  # --- TF-601c: Node range ------------------------------------------------

  # These three all satisfy the old, too loose wording "Node >= 20" and would
  # have passed. They break the Vite build.
  def test_tf601c_versions_that_satisfy_node_20_but_break_vite_are_rejected
    ['v20.0.0', 'v20.18.3', 'v21.7.3', 'v22.5.1', 'v22.11.0'].each do |version|
      refute Checker.node_suitable?(Checker.version_of(version)),
             "Node #{version} must be rejected — Vite requires #{Checker::NODE_DESCRIPTION}"
    end
  end

  def test_tf601c_the_two_accepted_ranges
    ['v20.19.0', 'v20.19.2', 'v20.99.0', 'v22.12.0', 'v23.1.0', 'v24.0.0'].each do |version|
      assert Checker.node_suitable?(Checker.version_of(version)),
             "Node #{version} must be accepted"
    end
  end

  # The boundary itself, spelled out: one patch level below 20.19.0 fails,
  # 20.19.0 passes. This is where an off-by-one would hide.
  def test_tf601c_the_lower_boundary_is_exact
    refute Checker.node_suitable?([20, 18, 999])
    assert Checker.node_suitable?([20, 19, 0])
    refute Checker.node_suitable?([22, 11, 999])
    assert Checker.node_suitable?([22, 12, 0])
  end

  def test_tf601c_an_unreadable_version_is_not_silently_accepted
    refute Checker.node_suitable?(nil)
    assert_nil Checker.version_of(nil)
    assert_nil Checker.version_of('irgendwas ohne Zahlen')
  end

  # --- Notes versus errors ------------------------------------------------

  # TF-611 depends on this: an old system sqlite3 must not abort the
  # installation, because the application does not use it at all.
  def test_old_system_sqlite_is_a_note_not_an_error
    notes = []
    Checker.check_sqlite(notes)

    # Either the version is fine (no note) or it produced a note — but in no
    # case may this check contribute to the error list.
    assert notes.all? { |n| n.is_a?(String) }
  end

  def test_install_commands_are_offered_for_every_known_platform
    %i[ruby node].each do |what|
      refute_nil Checker.install_command(what)
      refute_empty Checker.install_command(what).to_s
    end
  end

  # --- TF-601d: the gems themselves ---------------------------------------
  #
  # The check that was missing. Ruby, Bundler and Node being present says
  # nothing about whether the dependencies are installed — and "not installed
  # yet" is the normal state right after unpacking, "the lockfile changed" the
  # normal state right after an update. Without it the first symptom is a
  # stack trace from `bundle exec` at some later moment, which is exactly what
  # BT-02 exists to replace.

  # The lockfile is checked apart from the libraries, and that split matters:
  # a missing lockfile is a property of the **package** and stays fatal even
  # when `install` skips the library check, because installing them is what its
  # second step does. Without a lockfile nothing would be binding and NFA-20
  # would be gone.
  def test_tf601d_a_missing_lockfile_is_an_error_that_names_the_way_out
    errors = []
    Checker.stub(:lockfile, '/gibt/es/nicht/Gemfile.lock') do
      Checker.check_lockfile(errors)
    end

    assert_equal 1, errors.size
    assert_includes errors.first, 'Gemfile.lock'
    assert_match(/install/, errors.first, 'BT-02: the concrete next step, not only the diagnosis')
  end

  def test_tf601d_incomplete_gems_are_an_error_that_names_what_is_missing
    errors = []
    Checker.stub(:capture, [false, "Could not find sequel-5.106.0 in locally installed gems\nRun `bundle install`"]) do
      Checker.check_gems(errors)
    end

    assert_equal 1, errors.size
    assert_includes errors.first, 'sequel-5.106.0'
    # A changed Ruby is the other way into this state, and it is the one
    # nobody expects: gems with native extensions are built per version.
    assert_includes errors.first, 'Ruby version'
  end

  def test_tf601d_complete_gems_produce_no_error
    errors = []
    Checker.stub(:capture, [true, '']) do
      capture_io { Checker.check_gems(errors) }
    end

    assert_empty errors
  end

  # The repair differs between a delivered installation and the development
  # tree. Naming the wrong one sends somebody down a path that does not exist
  # for them.
  def test_tf601d_the_named_repair_matches_the_kind_of_installation
    Checker.stub(:app_dir, '/irgendwo/app') do
      assert_includes Checker.install_hint, 'install'
    end
    Checker.stub(:app_dir, '/irgendwo/backend') do
      assert_equal 'bundle install', Checker.install_hint
    end
  end

  # --- Exit code ----------------------------------------------------------

  def test_run_returns_zero_on_this_machine
    out, = capture_io do
      assert_equal 0, Checker.run([])
    end
    assert_includes out, 'Ruby'
  end
  # TF-696 — the Bundler hint names the version the lockfile asks for.
  #
  # Measured in a Debian machine: `ruby-full` brings no Bundler at all, and the
  # installation stops in its first step. A bare `gem install bundler` works,
  # but Bundler then upgrades itself on every single installation. The message
  # may as well name the version that will be needed anyway.
  def test_tf696_the_bundler_hint_names_the_version_of_the_lockfile
    wanted = File.readlines(File.join(CODE_ROOT, 'backend', 'Gemfile.lock'))
                 .last(2).map(&:strip).find { |l| l.match?(/\A\d+\.\d+/) }

    refute_nil wanted, 'the lockfile names no version, so this proves nothing'
    assert_equal " -v #{wanted}", Checker.send(:bundler_version_switch)
  end

  # And it stays silent rather than guessing when there is no lockfile to read.
  def test_tf696_without_a_lockfile_the_hint_names_no_version
    Checker.stub(:lockfile, '/nonexistent/Gemfile.lock') do
      assert_equal '', Checker.send(:bundler_version_switch)
    end
  end
  # TF-698 — the detail of the gem message ends cleanly or is empty.
  #
  # Measured in a Debian machine: `bundle check` says nothing at all when
  # Bundler itself is missing, and the sentence then read "for this machine:
  # <two spaces> Run scripts/install.sh".
  def test_tf698_an_empty_detail_leaves_no_stray_space
    assert_equal '', Checker.send(:first_meaningful_line, '')
    assert_equal '', Checker.send(:first_meaningful_line, "\n \n")
  end

  def test_tf698_a_detail_carries_its_own_separator
    assert_equal 'two gems missing ', Checker.send(:first_meaningful_line, 'two gems missing')
  end

  # And the version is looked for after the marker, not at the end of the file,
  # so trailing blank lines cannot move it out of view.
  def test_tf698_the_version_is_found_after_the_marker
    file = File.join(install_dir('lockfile_probe'), 'Gemfile.lock')
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, "GEM\n  remote: x\n\nBUNDLED WITH\n   4.0.11\n\n\n")

    Checker.stub(:lockfile, file) do
      assert_equal ' -v 4.0.11', Checker.send(:bundler_version_switch)
    end
  end
end
