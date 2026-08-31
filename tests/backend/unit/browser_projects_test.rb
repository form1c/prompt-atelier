# frozen_string_literal: true

require_relative '../../test_helper'
require 'run_tests'

# Which browsers the end-to-end tests run in (TF-712, NFA-10) — and at which
# width (TF-709, NFA-09).
#
# The list exists twice: in `playwright.config.js`, which knows how to drive
# each engine, and in `run_tests.rb`, which starts **one invocation per
# project** so that each engine gets an instance of its own. The duplication is
# deliberate — parsing a JavaScript configuration from Ruby would be the more
# fragile half of the two — so it is compared instead of avoided.
#
# **What goes wrong without this file.** A fourth engine added to the
# configuration and forgotten here would simply never run: `run_tests --e2e`
# would report success over three of four, and nothing would say which one was
# missing. NFA-10 names four browsers; a silently skipped engine is exactly the
# way that requirement stops being true.
class BrowserProjectsTest < PromptAtelier::TestCase
  CONFIG = File.read(File.join(CODE_ROOT, 'playwright.config.js'))

  def test_the_runner_starts_every_project_the_configuration_defines
    defined_projects = CONFIG.scan(/name:\s*'([\w-]+)'/).flatten

    refute_empty defined_projects, 'no projects found at all, so this proves nothing'
    assert_equal defined_projects.sort, PromptAtelier::RunTests::E2E_PROJECTS.sort,
                 'a project the runner does not start never runs, and the run still reports success'
  end

  # NFA-10 asks for Firefox, Chrome, Edge and Safari. Edge is represented by
  # Chromium and Safari by WebKit — a substitution the test concept states
  # openly, because neither can be driven on a Linux build machine. What must
  # not happen is that one of the three engines quietly disappears.
  def test_all_three_engines_are_covered
    %w[chromium firefox webkit].each do |engine|
      assert_includes PromptAtelier::RunTests::E2E_PROJECTS, engine,
                      "#{engine} carries part of NFA-10"
    end
  end

  # TF-709: the core workflow at the narrowest supported width. A project whose
  # viewport quietly grew back to the desktop default would still be green —
  # over a screen nobody asked about.
  def test_the_narrow_project_really_is_360_pixels_wide
    assert_includes PromptAtelier::RunTests::E2E_PROJECTS, '360px'
    assert_match(/viewport:\s*\{\s*width:\s*360\b/, CONFIG,
                 'NFA-09 names 360 px, and the project is named after it')
    assert_match(/name:\s*'360px',\s*\n\s*testMatch:\s*'workflow\.spec\.js'/, CONFIG,
                 'W-1 is what TF-709 asks to be walked at that width')
  end

  # The browser measurements take their figures against 5.000 prompts and are
  # started by their own configuration. Left in the regression run they would
  # measure the six-prompt fixture — and pass. A measurement in the wrong suite
  # does not fail; it agrees.
  def test_the_measurements_are_kept_out_of_the_regression_run
    assert_match(/testIgnore:\s*'measurement\.spec\.js'/, CONFIG)
    assert_path_exists File.join(CODE_ROOT, 'playwright.measure.config.js')
  end
end
