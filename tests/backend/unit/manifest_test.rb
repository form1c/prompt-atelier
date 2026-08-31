# frozen_string_literal: true

require_relative '../../test_helper'
require 'service_unit'
require 'manifest'

# What a delivery package consists of (18.2, 18.8).
#
# The contents are a value, so they can be checked here — in milliseconds, on
# any machine, without Node and without a build. That matters because the way
# this goes wrong is by **omission**: a file that was forgotten leaves no trace
# in a build log. It turns into a broken installation at somebody else's desk,
# and the reason is a line that was never written.
class ManifestTest < PromptAtelier::TestCase
  M = PromptAtelier::Manifest
  SCRIPTS = File.join(CODE_ROOT, 'scripts')

  # --- every script is accounted for ----------------------------------------

  # The case that keeps the two lists honest as the project grows. A fourteenth
  # script belongs in one of them, and until somebody decides which, this fails
  # and names it — rather than the script quietly not being delivered.
  def test_every_script_in_the_tree_is_either_delivered_or_deliberately_not
    present = Dir.glob(File.join(SCRIPTS, '*.sh')).map { |path| File.basename(path, '.sh') }.sort
    classified = (M::OPERATING_SCRIPTS + M::DEVELOPMENT_SCRIPTS).sort

    refute_empty present, 'the search found no scripts at all, so it proves nothing'
    assert_equal present, classified
    assert_empty(M::OPERATING_SCRIPTS & M::DEVELOPMENT_SCRIPTS,
                 'a script cannot be both')
  end

  # 18.1: one pair per task, the same name on both systems. A delivery that
  # carried only the `.sh` would work on Linux and be silently incomplete on
  # Windows — the platform where nobody would think to look for a missing file.
  def test_every_delivered_script_travels_as_a_pair_with_its_ruby
    missing = M.script_files.reject { |name| File.file?(File.join(SCRIPTS, name)) }

    assert_empty missing, 'named in the manifest but not in the tree'
  end

  # The three that stay behind, and the reason each of them would be worse than
  # useless in an installation.
  def test_the_development_scripts_stay_behind
    %w[build run_tests start_development].each do |name|
      refute_includes M::OPERATING_SCRIPTS, name
      refute_includes M.script_files, "#{name}.sh"
    end
  end

  # `run_tests` is the one that would not merely fail but **lie**: `tests/` is
  # not part of a delivery, so it would find no test files, skip every suite
  # and end with "All tests that ran have passed."
  def test_a_delivered_run_tests_would_report_success_over_nothing
    source = File.read(File.join(SCRIPTS, 'lib', 'run_tests.rb'))

    assert_includes source, 'tests_skipped',
                    'the skip path is what would make a delivered run_tests report success'
    refute_includes M.script_files, File.join('lib', 'run_tests.rb')
  end

  # --- the libraries behind them --------------------------------------------

  # An entry point that no delivered script requires, because the service
  # manager starts it directly. It would otherwise look like a library nobody
  # reaches, and be dropped from the package the next time somebody tidied.
  STARTED_FROM_OUTSIDE = %w[service_run].freeze

  # Computed here, listed there. A helper that a script starts requiring is
  # otherwise missing from the package, and the first symptom is
  # "cannot load such file" on a machine that is not this one.
  def test_the_delivered_libraries_are_exactly_what_the_delivered_scripts_reach
    reached = (closure(M::OPERATING_SCRIPTS) + STARTED_FROM_OUTSIDE).uniq

    assert_equal M::OPERATING_LIBS.sort, reached.sort
  end

  # The exception above is narrow, so it has to be earned: the file has to be
  # the one the service registration actually names.
  def test_what_is_started_from_outside_is_what_the_service_plan_names
    named = PromptAtelier::ServiceUnit.service_command.last

    assert_equal 'service_run.rb', File.basename(named)
    assert File.file?(named)
  end

  # And nothing they reach leads back out into the development-only files.
  def test_no_delivered_library_requires_one_that_stays_behind
    M::OPERATING_LIBS.each do |name|
      requires(name).each do |target|
        refute_includes M::DEVELOPMENT_SCRIPTS, target,
                        "#{name}.rb requires #{target}.rb, which is not delivered"
      end
    end
  end

  # --- the plan --------------------------------------------------------------

  def test_the_package_carries_the_application_the_scripts_and_the_template
    targets = plan.map { |item| item[:to] }

    assert_includes targets, 'app'
    assert_includes targets, 'scripts'
    assert_includes targets, 'config/config.example.yml'
    assert_includes targets, 'examples'

    # What a downloaded archive needs in order to be usable without a
    # repository. Before these entries it held no explanatory document at all
    # apart from the proxy templates.
    assert_includes targets, 'README.md'
    assert_includes targets, 'LICENSE.md'
    assert_includes targets, 'CHANGELOG.md'
    assert_includes targets, 'CONTRIBUTING.md'
    assert_includes targets, 'SECURITY.md'
    assert_includes targets, 'doc'
  end

  # 18.2: the structure is complete from the moment of unpacking, not after the
  # first run. Otherwise `install` would be creating directories that its own
  # documentation says are already there.
  def test_the_empty_directories_are_part_of_the_package
    empty = plan.select { |item| item[:kind] == :empty }.map { |item| item[:to] }

    assert_equal ['data', 'data/backups', 'data/logs'], empty
  end

  # The two optional entries, and both are optional for a stated reason.
  # NSSM is a third-party program that cannot be fetched from the build
  # machine, and a missing `tools/` must not stop a release — but it costs
  # something, and `build` says what. `img/` holds the screenshots the README
  # refers to, and a release must not fail over a picture.
  #
  # Everything else is required. A package missing its application, its
  # scripts, its configuration template or its manuals is not a package.
  def test_only_the_named_entries_are_optional
    optional = plan.reject { |item| item[:required] }.map { |item| item[:to] }

    assert_equal %w[tools img], optional
  end

  # The vendored gems live in `app/vendor/bundle`, and Bundler finds them there
  # only because deployment mode points it at `vendor/bundle` beside the
  # Gemfile. Without this file the package would carry 29 MB of gems that are
  # never used, and every installation would fetch them again — offline
  # installation, the whole reason for carrying them, would be gone (18.3).
  def test_the_delivered_bundler_configuration_points_at_the_vendored_gems
    written = plan.find { |item| item[:to] == 'app/.bundle/config' }

    refute_nil written
    assert_includes written[:contents], 'BUNDLE_DEPLOYMENT: "true"'
    assert_includes written[:contents], 'BUNDLE_WITHOUT: "development:test"'
  end

  # The development tree's own `.bundle` and its `vendor` are handled
  # separately — copied along, they would put the developing machine's Bundler
  # settings and a symbolic link into the package.
  def test_the_application_directory_leaves_the_development_bundle_behind
    app = plan.find { |item| item[:to] == 'app' }

    assert_equal %w[vendor .bundle], app[:except]
    assert_equal 'backend', File.basename(app[:from]), 'backend/ becomes app/ (18.2)'
  end

  private

  def plan = M.plan(code: CODE_ROOT, project: File.expand_path('..', CODE_ROOT))

  # The transitive hull over `require_relative`, read from the files rather
  # than from a list — that is what makes it a second opinion.
  def closure(names)
    seen = []
    queue = names.dup

    until queue.empty?
      name = queue.shift
      next if seen.include?(name)

      seen << name
      queue.concat(requires(name))
    end
    seen
  end

  # Scanned over the whole file, not only its head: `install.rb` requires
  # `check_environment`, `migrate` and `service_install` from inside methods,
  # and a scanner that stopped at the first non-require line would miss all
  # three.
  def requires(name)
    path = File.join(SCRIPTS, 'lib', "#{name}.rb")
    return [] unless File.file?(path)

    source = File.read(path)
    (source.scan(/require_relative\s+['"]([\w.\/]+)['"]/).flatten +
     started_by_path(source)).map { |target| File.basename(target, '.rb') }
  end

  # A file that is **started** rather than required.
  #
  # `measure` runs its bench instance as a process of its own — two processes,
  # so that the server and the stopwatch do not share one interpreter lock —
  # and reaches the file by path, not by `require_relative`. The closure was
  # blind to that: `bench_server.rb` was missing from the package while every
  # test stayed green, and the first symptom would have been a measurement
  # that died at "No such file" on somebody else's machine.
  #
  # Matched on the exact idiom `File.join(__dir__, 'x.rb')` rather than on
  # anything ending in `.rb`: file names appear in comments all over these
  # scripts, and a rule that read those would start demanding the delivery of
  # `run_tests`.
  def started_by_path(source)
    source.scan(/File\.join\(__dir__,\s*['"]([\w.]+\.rb)['"]\)/).flatten
  end
end
