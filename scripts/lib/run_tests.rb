# frozen_string_literal: true

# scripts/lib/run_tests.rb — backend and frontend tests (18.5, BT-01)
#
# Order per test concept 3.3:
#
#   1. Minitest    tests/backend/
#   2. Vitest      tests/frontend/
#   3. Playwright  tests/e2e/     only with --e2e or during the build
#
# Non-zero exit code on any failure. `build` evaluates it and aborts (BT-08).
#
# Every test run writes its traces to test-results/ outside project/. That is not a
# matter of tidiness: a test running against project/data/ would overwrite the
# development database.

require 'fileutils'
require_relative 'common'

module PromptAtelier
  module RunTests
    extend Script

    module_function

    # The four suites `--only=` can name. Written out so that a value which is
    # not one of them can be refused — see `run`.
    SUITES = %w[backend frontend e2e measure].freeze

    # The switches this script knows. Anything else is refused, for the same
    # reason an unknown value of `--only=` is: a switch that is silently
    # dropped looks like it worked. `--e2ee` runs backend and frontend only,
    # reports "All tests that ran have passed" and exits 0 — and whoever typed
    # it believes the browser cases ran. Found by typing `--help`, which ran
    # the entire suite instead of printing anything.
    SWITCHES = ['--e2e', '--measure'].freeze

    def run(argv = [])
      e2e     = argv.include?('--e2e')
      measure = argv.include?('--measure')
      only = argv.find { |a| a.start_with?('--only=') }&.split('=', 2)&.last

      return 1 unless accepted?(argv)
      return 1 unless known?(only)

      target = test_results_dir
      FileUtils.mkdir_p(File.join(target, 'tmp'))
      FileUtils.mkdir_p(File.join(target, 'reports'))

      outcomes = []
      outcomes << backend_tests(target)  if only.nil? || only == 'backend'
      outcomes << frontend_tests(target) if only.nil? || only == 'frontend'
      outcomes << e2e_tests(target)      if e2e && (only.nil? || only == 'e2e')
      outcomes << measurements(target)   if measure && (only.nil? || only == 'measure')

      puts
      # **An empty list is not a pass.** `[].all?` is true, so a selection that
      # matched no suite used to end with "All tests that ran have passed" and
      # exit code 0 — the exact sentence this file's own manifest entry warns
      # about, in the tool that certifies everything else. Found by typing
      # `--only=minitest`, which is not a suite name: nothing ran, and the run
      # reported success. `--only=e2e` without `--e2e` reaches the same state
      # by an honest route, and it is refused too, because a run that was asked
      # for the browser tests and silently did nothing is worse than one that
      # says it was asked for two contradictory things.
      if outcomes.empty?
        bad(t('script.tests_none_ran', selection: only || (measure ? 'measure' : 'e2e')))
        return 1
      end

      return 1 unless outcomes.all?

      ok(t('script.tests_passed'))
      0
    end

    def accepted?(argv)
      unknown = argv.reject { |a| SWITCHES.include?(a) || a.start_with?('--only=') }
      return true if unknown.empty?

      puts
      bad(t('script.tests_unknown_switch',
             name: unknown.first,
             known: (SWITCHES + ['--only=<suite>']).join(', ')))
      false
    end

    def known?(only)
      return true if only.nil? || SUITES.include?(only)

      puts
      bad(t('script.tests_unknown_suite', name: only, known: SUITES.join(', ')))
      false
    end

    # --- Minitest ---------------------------------------------------------

    def backend_tests(target)
      heading(t('script.tests_backend'))

      files = Dir.glob(File.join(tests_dir, 'backend', '**', '*_test.rb')).sort
      if files.empty?
        note(t('script.tests_skipped', name: 'Minitest', reason: 'no test files'))
        return true
      end

      env = bundle_env(
        'PROMPTATELIER_TEST_RESULTS' => target,
        'RACK_ENV'                    => 'test'
      )
      loader = files.map { |f| "require '#{File.expand_path(f)}'" }.join('; ')

      success = system(env, 'bundle', 'exec', 'ruby', '-e', loader, chdir: root)
      bad(t('script.tests_failed', name: 'Minitest')) unless success
      success
    end

    # The browser measurements (TF-702, TF-703), AP-17.
    #
    # Their own configuration, because they need an instance holding 5.000
    # prompts and building one costs about a minute. They belong to a release,
    # not to a commit — which is why `--measure` has to be asked for, exactly
    # as `--e2e` does.
    def measurements(target)
      heading(t('script.tests_measure'))

      success = system({ 'PROMPTATELIER_TEST_RESULTS' => target },
                       npx, 'playwright', 'test', '--config', 'playwright.measure.config.js',
                       chdir: root)
      bad(t('script.tests_failed', name: 'Playwright (measurements)')) unless success
      success
    end

    # --- Vitest -----------------------------------------------------------

    # Runs from the npm workspace root (project/), not from frontend/: node_modules
    # is hoisted there so that the suites in tests/frontend/ can resolve their
    # imports at all. See the developer handbook, "npm workspace".
    def frontend_tests(target)
      heading(t('script.tests_frontend'))

      unless File.file?(File.join(root, 'package.json'))
        note(t('script.tests_skipped', name: 'Vitest', reason: 'no package.json'))
        return true
      end

      unless Dir.exist?(File.join(root, 'node_modules'))
        say(t('script.dependencies_missing'))
        return false unless npm_install
      end

      success = system({ 'PROMPTATELIER_TEST_RESULTS' => target },
                       npm, 'run', '--silent', 'test', chdir: root)
      bad(t('script.tests_failed', name: 'Vitest')) unless success
      success
    end

    # --- Playwright -------------------------------------------------------

    # Runs from the npm workspace root (project/) like Vitest, and for the same
    # reason: that is where node_modules and playwright.config.js are. The
    # configuration starts an instance of its own — own port, own directory,
    # own database — so a run never reaches the installation being developed
    # against.
    # The browser projects, **one invocation each** (TF-712, TF-709).
    #
    # Not one run over four projects, and the difference is a whole class of
    # false failures. The browser tests share a single instance on purpose
    # (test concept 3.2): each case sets up what it needs and takes nothing
    # away, which holds as long as each case runs **once**. Four projects in
    # one invocation run them four times over one database, and the second
    # engine then finds the first one's prompts: `strict mode violation:
    # getByRole(…) resolved to 2 elements`. Firefox and WebKit looked broken
    # and were not — run against an instance of their own, both pass every
    # case.
    #
    # Listed here and checked against playwright.config.js by a test, rather
    # than read out of it: a list that is duplicated and compared stays honest,
    # and parsing a JavaScript configuration from Ruby would be the more
    # fragile half of the two.
    E2E_PROJECTS = %w[chromium firefox webkit 360px].freeze

    def e2e_tests(target)
      specs = Dir.glob(File.join(tests_dir, 'e2e', '*.spec.js'))
      if specs.empty?
        heading(t('script.tests_e2e'))
        note(t('script.tests_skipped', name: 'Playwright', reason: 'no test files'))
        return true
      end

      # `all?` would stop at the first failing engine, and the report would say
      # nothing about the other two. All of them run, then the verdict.
      E2E_PROJECTS.map { |project| e2e_project(target, project) }.all?
    end

    def e2e_project(target, project)
      heading(t('script.tests_e2e_project', project: project))

      success = system({ 'PROMPTATELIER_TEST_RESULTS' => File.join(target, project) },
                       npx, 'playwright', 'test', "--project=#{project}", chdir: root)
      bad(t('script.tests_failed', name: "Playwright (#{project})")) unless success
      success
    end

    # --- helpers ----------------------------------------------------------

    def npm = windows? ? 'npm.cmd' : 'npm'
    def npx = windows? ? 'npx.cmd' : 'npx'

    def npm_install
      say(t('script.installing_dependencies'))
      # `ci` keeps the lockfile authoritative (NFA-20); `install` only for the
      # very first run, when no lockfile exists yet.
      subcommand = File.exist?(File.join(root, 'package-lock.json')) ? 'ci' : 'install'
      system(npm, subcommand, chdir: root)
    end
  end
end

exit PromptAtelier::RunTests.run(ARGV) if $PROGRAM_NAME == __FILE__
