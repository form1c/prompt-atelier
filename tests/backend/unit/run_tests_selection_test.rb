# frozen_string_literal: true

require_relative '../../test_helper'
require 'run_tests'

# `run_tests --only=` — the selection, and what happens when it matches nothing
# (BT-01).
#
# **The finding this file exists for.** `--only=minitest` is not a suite name;
# the suites are called backend, frontend and e2e. The selection therefore
# matched nothing, no suite ran, and the run ended with
#
#     OK    All tests that ran have passed.
#
# and exit code 0 — because `[].all?` is true. It is the exact failure the
# manifest warns about for a delivered `run_tests` ("a script that announces
# success having checked nothing"), and it was sitting in the tool that
# certifies every other one. `build` reads this exit code (BT-08), so a typo in
# a build script would have produced a release-grade package over a run that
# checked nothing at all.
#
# Nothing is started here: the cases are about the decision, and a case that
# had to run a suite in order to find out that no suite ran would take minutes.
class RunTestsSelectionTest < PromptAtelier::TestCase
  R = PromptAtelier::RunTests

  def test_a_selection_that_names_no_suite_is_refused_before_anything_starts
    status, output = capture_run('--only=minitest')

    assert_equal 1, status
    assert_includes output, 'Unknown suite: minitest'
    assert_includes output, 'backend, frontend, e2e', 'and it says what would have worked'
    refute_includes output, 'passed'
  end

  # The honest route to the same state: e2e is a real suite name, but the
  # browser tests only run when `--e2e` is given as well. Asked for one and
  # given neither, the run must say so rather than end green.
  def test_asking_for_the_browser_tests_without_e2e_is_refused
    status, output = capture_run('--only=e2e')

    assert_equal 1, status
    assert_includes output, 'nothing was checked'
    assert_includes output, '--e2e'
    refute_includes output, 'passed'
  end

  # TF-551 — a switch the script does not know stops the run.
  #
  # **Found by typing `--help`**, which ran the entire suite instead of saying
  # anything: an unknown switch was simply dropped. The dangerous version of
  # the same slip is `--e2ee` — backend and frontend run, the browser cases do
  # not, and the last line reads "All tests that ran have passed." True, and
  # useless to whoever asked for the browser tests.
  #
  # It is the rule that already guards `--only=`, one level up: a selection
  # that quietly becomes a different selection is worse than a refusal.
  def test_tf551_an_unknown_switch_is_refused_before_anything_starts
    status, output = capture_run('--e2ee')

    assert_equal 1, status
    assert_includes output, 'Unknown switch: --e2ee'
    assert_includes output, '--e2e', 'and it says what would have worked'
    refute_includes output, 'passed'
  end

  def test_tf551_a_typo_next_to_a_good_switch_is_caught_too
    status, output = capture_run('--e2e', '--measrue')

    assert_equal 1, status
    assert_includes output, '--measrue'
  end

  # The counter-check, and it is the one that matters: the switches that do
  # exist still get through, in combination and next to a selection. A check
  # that refuses everything would satisfy both cases above.
  def test_tf551_the_real_switches_are_still_accepted
    assert R.accepted?(['--e2e']), '--e2e is a switch'
    assert R.accepted?(['--measure']), '--measure is a switch'
    assert R.accepted?(['--e2e', '--measure', '--only=e2e']), 'and they combine'
    assert R.accepted?([]), 'no switch at all is the normal case'
  end

  def test_the_three_real_suite_names_are_accepted
    %w[backend frontend e2e].each do |name|
      assert R.known?(name), "#{name} is a suite and has to be selectable"
    end
    assert R.known?(nil), 'no selection at all means all of them'
  end

  private

  # Only the selection is exercised, so the run is stopped at the first thing
  # it would do after deciding. Anything else would start Minitest inside
  # Minitest.
  def capture_run(*argv)
    status = nil
    output, = capture_io do
      status = R.run(argv)
    end
    [status, output]
  end
end
