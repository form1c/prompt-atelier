# frozen_string_literal: true

require_relative '../../test_helper'
require 'open3'
require 'yaml'

# What a delivered installation does when it does **not** fit the machine
# (18.3, BT-02, BT-15).
#
# **Every case here comes from one report.** The plattform-bound Linux archive
# was unpacked on a Windows machine, and each of the four things that happened
# was wrong in its own way:
#
#   1. `check_environment` demanded Node and npm — with the sentence "It is
#      needed only to build the frontend, not to run it" printed next to it,
#      and an exit code of 1. A message that says something is not a problem,
#      over an exit code that says it is.
#   2. The message about the real cause was cut off mid-list, and the part that
#      named it ("but your local platform is x64-mingw-ucrt") was in the piece
#      that got cut.
#   3. `install` aborted in step 1 over exactly the thing its step 2 exists to
#      repair. The documented visible fallback to `bundle install` was never
#      reached.
#   4. `start_portable` ended in `NameError: uninitialized constant
#      …::Configuration` — the rescue clause of a script referring to a file
#      that had not been loaded, hiding the actual error behind a second one.
#
# Reproduced here by building a throwaway installation whose `VERSION` claims a
# platform this machine does not have. The real Windows case is NT-5; what can
# be settled without a Windows machine is every decision above.
class WrongPackageTest < PromptAtelier::TestCase
  ELSEWHERE = { 'platform' => 'x64-mingw-ucrt', 'ruby' => '9.9.9' }.freeze

  def setup
    super
    @dir = delivered_installation
  end

  # --- what it says (BT-02, BT-15) -----------------------------------------

  # The first sentence names the cause. Everything below it would fail as a
  # consequence, and three consequences are harder to read than one cause.
  def test_the_mismatch_is_named_with_both_sides
    write_version(ELSEWHERE)

    status, output = run_script('check_environment')

    refute_equal 0, status
    assert_includes output, 'x64-mingw-ucrt', 'what the package was built for'
    assert_includes output, Gem::Platform.local.to_s, 'and what this machine is'
    assert_includes output, 'universal', 'and the way out'
  end

  # A package that fits says nothing about platforms at all. Without this the
  # case above would also pass over a script that complains on every machine.
  def test_a_package_that_fits_says_nothing_about_platforms
    write_version('platform' => Gem::Platform.local.to_s, 'ruby' => RbConfig::CONFIG['ruby_version'])

    status, output = run_script('check_environment')

    assert_equal 0, status, output
    refute_includes output, 'universal'
  end

  # The universal shape carries no gems and therefore fits every machine. It
  # must not be accused of belonging to another one.
  def test_the_universal_shape_is_never_a_mismatch
    write_version('shape' => 'universal', 'platform' => 'any', 'ruby' => '>= 3.3.0')

    status, output = run_script('check_environment')

    assert_equal 0, status, output
  end

  # --- Node is not a prerequisite for running (18.3) -----------------------

  # The finding in its purest form: in a delivered installation the build tools
  # are not asked for at all. `--all` asks anyway, which is the counter-check —
  # without it this case would also pass over a script that never looks.
  def test_a_delivered_installation_does_not_demand_node
    write_version('platform' => Gem::Platform.local.to_s, 'ruby' => RbConfig::CONFIG['ruby_version'])

    _, plain = run_script('check_environment')
    _, everything = run_script('check_environment', '--all')

    refute_includes plain, 'Node.js'
    assert_includes everything, 'Node.js'
  end

  # --- install must reach its own second step ------------------------------

  # The gems are step 2's business, so step 1 must not end the run over them.
  # Made to fail the way a wrong package does: the vendored tree is taken away,
  # which is what `bundle check` sees on a machine the package is not for.
  def test_install_gets_past_the_gems_to_the_step_that_installs_them
    # A stand-in `bundle` that reports the libraries as missing and then
    # installs nothing. The real one would reach for the network and take
    # minutes; what is under test is which **step** deals with the answer.
    stub_bundle(check: false)

    _, output = run_script('install', "--port=#{free_port}", '--mode=portable',
                           '--admin-name=A', '--admin-email=a@example.test',
                           '--admin-password=ein-langes-testpasswort',
                           path: File.join(@dir, 'stubs'))

    assert_includes output, 'Step 2 of 7',
                     'step 1 must not end the run over something step 2 repairs'
    assert_includes output, 'Installing the Ruby libraries',
                     'and step 2 has to actually try'
    # The step says what it is doing **before** it starts, because on Windows
    # it compiles from source and then stands still for minutes.
    assert_includes output, 'takes a few minutes',
                     'and it has to say so before the silence, not after'
  end

  # The counter-check. With the libraries in order nothing is installed, and
  # without this case the one above would also pass over an `install` that
  # reached for the network on every run.
  def test_install_installs_nothing_when_the_libraries_are_in_order
    stub_bundle(check: true)

    _, output = run_script('install', "--port=#{free_port}", '--mode=portable',
                           '--admin-name=A', '--admin-email=a@example.test',
                           '--admin-password=ein-langes-testpasswort',
                           path: File.join(@dir, 'stubs'))

    assert_includes output, 'already installed'
    refute_includes output, 'Installing the Ruby libraries'
  end

  # --- no stack trace, ever (BT-15) ----------------------------------------

  # The fourth part of the report. Bundler prints its paragraph and calls
  # `exit`; the script's `rescue Configuration::Error` then raised a NameError,
  # because that constant comes from a file which is required **after** the
  # gems are activated. Two errors, neither of them the cause.
  #
  # Every script that needs the gems in its own process is driven here, because
  # the broken clause was in eight of them and a case for one would have proven
  # nothing about the other seven.
  %w[start_portable backup migrate seed_demo export_all].each do |script|
    define_method("test_#{script}_ends_with_a_sentence_when_the_gems_are_unusable") do
      break_the_bundle

      status, output = run_script(script)

      refute_equal 0, status
      assert_includes output, 'cannot be used on this machine'
      refute_includes output, 'NameError', 'the rescue clause must not raise on its own'
      refute_match(/^\s+from .*\.rb:\d+/, output, 'a stack trace is not a message')
    end
  end

  private

  # The state a wrong package leaves a machine in: the libraries are named in
  # the lockfile and **not present where the package says they are**. Bundler
  # then refuses, which is what the Windows report showed.
  #
  # Produced by pointing Bundler at an empty directory, and that detail is the
  # whole difficulty of this file. Three more obvious triggers were tried and
  # every one of them proved nothing:
  #
  #   * rewriting the `Gemfile` — whether Bundler refuses depends on how it
  #     finds its own configuration;
  #   * deleting the vendored tree — the scripts **succeeded**, because this
  #     machine has the same gems installed elsewhere and Bundler took them;
  #   * naming a foreign platform in the lockfile — likewise not refused here.
  #
  # An empty gem path cannot be satisfied from anywhere, on any machine. What
  # is under test is not how Bundler fails but what the script makes of it.
  def break_the_bundle
    empty = File.join(@dir, 'no-gems-here')
    FileUtils.mkdir_p(empty)
    File.write(File.join(@dir, 'app', '.bundle', 'config'),
               "---\nBUNDLE_DEPLOYMENT: \"true\"\nBUNDLE_PATH: \"#{empty}\"\n")
  end

  def write_version(values)
    lines = { 'product' => 'Prompt Atelier', 'version' => '1.0.0', 'shape' => 'vendored' }.merge(values)
    File.write(File.join(@dir, 'VERSION'), lines.map { |k, v| format("%-9s %s\n", "#{k}:", v) }.join)
  end

  # `RUBYOPT` is cleared, and without that this whole file would prove nothing.
  #
  # The suite itself runs under `bundle exec`, which sets `RUBYOPT=-rbundler/
  # setup`. A child process then loads Bundler **before its own first line** —
  # so with a broken bundle the script died in `gem_prelude`, never reached
  # `activate_gems!`, and the stack trace under test was Bundler's own rather
  # than the one the report described. The launchers from 18.5 call plain
  # `ruby` and set nothing; this reproduces that.
  #
  # The same class of mistake as the `Process.spawn` one from AP-01: the child
  # inherits the environment, and a counter-check that ignores it proves
  # nothing.
  def stub_bundle(check:)
    stubs = File.join(@dir, 'stubs')
    FileUtils.mkdir_p(stubs)
    path = File.join(stubs, 'bundle')
    File.write(path, <<~SHELL)
      #!/bin/sh
      case "$1" in
        --version) echo "Bundler version 4.0.11" ;;
        check)     exit #{check ? 0 : 1} ;;
        install)   echo "nothing to do" ;;
      esac
      exit 0
    SHELL
    File.chmod(0o755, path)
  end

  def run_script(name, *arguments, path: nil)
    # `GEM_HOME`/`GEM_PATH` matter as much as `RUBYOPT`: `bundle exec` sets
    # them to the developer's own gems, and a child that inherits them finds
    # everything no matter what the package says. Every case here was green
    # over scripts quietly using gems from somewhere else entirely. A plain
    # shell, which is where the launchers of 18.5 run, has none of the four.
    environment = script_env
    environment['PATH'] = "#{path}:#{ENV.fetch('PATH', '')}" if path

    output, status = Open3.capture2e(
      environment,
      RbConfig.ruby, File.join(@dir, 'scripts', 'lib', "#{name}.rb"), *arguments,
      chdir: @dir
    )
    [status.exitstatus, output]
  end

  # The delivered shape (18.2), with a configuration and a database, so the
  # scripts get as far as the thing under test.
  def delivered_installation
    # Assigned here rather than by the caller: `write_version` below already
    # needs it, and `@dir` would still be nil at that point.
    dir = @dir = install_dir('wrong-package')
    app = File.join(dir, 'app')
    FileUtils.mkdir_p(app)

    source = File.join(CODE_ROOT, 'backend')
    %w[app.rb config.ru version.rb Gemfile Gemfile.lock].each do |name|
      FileUtils.cp(File.join(source, name), File.join(app, name))
    end
    %w[services locales config migrations models routes wordlists].each do |name|
      FileUtils.cp_r(File.join(source, name), app)
    end
    FileUtils.cp_r(File.join(source, '.bundle'), app)
    FileUtils.ln_s(File.join(source, 'vendor'), File.join(app, 'vendor'))
    FileUtils.cp_r(File.join(CODE_ROOT, 'scripts'), dir)

    write_config(dir, valid_config.merge('server' => { 'host' => '127.0.0.1', 'port' => free_port }))
    migrate_installation(dir)
    write_version('platform' => Gem::Platform.local.to_s, 'ruby' => RbConfig::CONFIG['ruby_version'])
    dir
  end
end
