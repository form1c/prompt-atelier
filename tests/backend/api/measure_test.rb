# frozen_string_literal: true

require_relative '../../test_helper'
require 'open3'
require 'measure'
require 'bench_server'
require 'services/rate_limit'

# `measure` — the numbers of chapter 12, taken instead of claimed (TF-701 to
# TF-707).
#
# Two halves, and the second is the one that was missing on the first run.
#
# The first half is the ordinary one: the script builds a bench of its own,
# starts an instance on it, measures, writes a report and cleans up after
# itself. The second half is about **what a green report is worth**. Every case
# of the first run was green, and one of them was searching for a word the
# measuring account was not allowed to see: 200 OK, nothing found, 1.4 ms — the
# best number in the table, over an empty answer. A measuring tool that cannot
# tell "fast" from "found nothing" reports the emptiness as the achievement.
#
# The cases here are therefore mostly about refusals: too few results, a
# missed limit, an unknown option. The tool has to stop, and it has to say
# which requirement it is stopping over.
class MeasureTest < PromptAtelier::TestCase
  M = PromptAtelier::Measure

  # Small on purpose. What is under test is the tool, not the machine — the
  # real stock is 5.000 and 20.000, and those runs are the operator's, not the
  # test suite's.
  PROMPTS = 60
  RUNS = 3

  def setup
    super
    @results = install_dir('measure-results')
  end

  # --- a run from end to end --------------------------------------------------

  def test_it_measures_and_writes_a_report
    status, output = run_measure

    assert_equal 0, status, output
    assert_includes output, 'Step 5 of 5'
    assert_path_exists report_path
  end

  # The report is the lasting part — the console scrolls away. Everything a
  # reader needs in order to know **what** was measured has to be in the file:
  # which machine, which stock, which thread pool, and how much each query
  # found.
  def test_the_report_says_what_was_measured_and_on_what
    run_measure
    report = File.read(report_path)

    assert_match(/^\| Machine \| .*ruby/, report)
    assert_match(/^\| Stock \| #{PROMPTS} prompts/, report)
    assert_match(/^\| Thread pool \| \d+, \d+ \(config\/puma\.rb\)/, report)
    assert_includes report, 'Found',
                    'without the number found, a fast empty answer reads like a good result'
    assert_includes report, 'TF-701'
    assert_includes report, 'TF-704'
  end

  # 18.3 and the standing rule for every script in this directory: the instance
  # somebody operates is never touched. The bench has a directory, a database
  # and a port of its own — and it is **gone** afterwards, because a forgotten
  # 20.000-prompt database under `data/` would travel into every backup from
  # then on and make `package` refuse outright.
  def test_the_bench_is_removed_again
    run_measure

    refute_path_exists File.join(@results, 'measure'),
                       'the bench outlived the measurement'
  end

  def test_keep_leaves_the_bench_in_place_for_the_next_run
    run_measure('--keep')

    assert_path_exists File.join(@results, 'measure', 'data', 'promptatelier.db')
  end

  # BT-07: every script runs twice without harm. Here the second run is also
  # the one that reuses a kept stock, which is the path an operator takes when
  # measuring a series.
  def test_a_second_run_reuses_the_stock_instead_of_building_it_again
    run_measure('--keep')
    status, output = run_measure('--keep')

    assert_equal 0, status, output
    assert_includes output, 'keeping the stock'
    refute_includes output, 'building a stock'
  end

  # The bench is beside the installation, never inside it. Stated here as well
  # as in the script, because this is the property that keeps a measurement
  # from reaching the developer's own database — and it is one line away from
  # being wrong.
  def test_the_bench_never_lands_inside_the_installation
    default = M.default_dir

    refute default.start_with?(File.join(CODE_ROOT, 'data')),
           'the bench would sit in the directory holding real prompts'
    refute default.start_with?(File.join(CODE_ROOT, 'config'))
  end

  # --- the refusals ------------------------------------------------------------

  # The finding from the first run, as a case. A query that answers 200 with an
  # empty list stops the measurement instead of contributing the fastest number
  # in the table.
  def test_a_query_that_finds_nothing_stops_the_measurement
    error = assert_raises(M::Unusable) do
      M.verify(fake_client('{"prompts":[],"meta":{"total":0}}'),
               { path: '/api/v1/prompts?q=nothing', expect: 1..1 })
    end

    assert_includes error.message, 'found 0 prompts'
    assert_includes error.message, 'is not a result'
  end

  def test_a_query_that_finds_too_few_stops_the_measurement
    assert_raises(M::Unusable) do
      M.verify(fake_client('{"prompts":[1,2],"meta":{"total":2}}'),
               { path: '/api/v1/prompts', expect: 25.. })
    end
  end

  def test_a_query_that_finds_what_the_case_needs_passes
    found = M.verify(fake_client('{"prompts":[1],"meta":{"total":1}}'),
                     { path: '/api/v1/prompts?q=needle', expect: 1..1 })

    assert_equal 1, found
  end

  # A failing request must never become a measurement either. A 500 answered in
  # three milliseconds is the fastest case there is.
  def test_a_failing_request_is_not_a_measurement
    error = assert_raises(M::Unusable) do
      M.verify(fake_client('{"error":{}}', code: '500'), { path: '/api/v1/prompts', expect: 1.. })
    end

    assert_includes error.message, '500'
  end

  # --- the gate ----------------------------------------------------------------

  # A missed target ends the run non-zero and names the requirement. Written
  # against fabricated results rather than by slowing a machine down: the
  # subject is what the tool does with a number over the limit, and that has to
  # be checkable without a slow machine to hand.
  def test_a_missed_limit_ends_the_run_and_names_the_requirement
    status, output = capture_io_of do
      M.report([result(p95: 250.0)], { prompts: PROMPTS, runs: RUNS, dir: File.join(@results, 'measure') }, facts)
    end

    assert_equal 1, status
    assert_includes output, 'NFA-02 missed'
    assert_includes output, 'config/puma.rb',
                    'the plan says the pool is raised before the requirement is changed'
  end

  # And the report is written **anyway**. A run that missed its targets is the
  # one whose numbers somebody will want to compare with next month's.
  def test_the_report_is_written_even_when_the_targets_were_missed
    capture_io_of do
      M.report([result(p95: 250.0)], { prompts: PROMPTS, runs: RUNS, dir: File.join(@results, 'measure') }, facts)
    end

    assert_includes File.read(report_path), 'MISSED'
  end

  def test_a_run_within_its_limits_ends_zero
    status, = capture_io_of do
      M.report([result(p95: 12.0)], { prompts: PROMPTS, runs: RUNS, dir: File.join(@results, 'measure') }, facts)
    end

    assert_equal 0, status
  end

  # --- under load (TF-706, NFA-07) -------------------------------------------------

  # The finding of the first load run, as a case. Six clients saving with no
  # pause reached about 500 writes a minute each; SEC-19 allows 120, so a
  # quarter of the saves came back `429 rate_limited`. Nothing was broken —
  # and the measurement had become a measurement of the limiter, over
  # durations that mostly belonged to refusals. Refusals are fast, so the
  # table looked excellent.
  #
  # The pace is therefore derived from SEC-19 rather than written down, and
  # this case is what keeps the two together.
  def test_the_writing_clients_stay_below_the_limit_sec_19_sets
    permitted = PromptAtelier::RateLimit::WRITES_PER_MINUTE
    actual = 60.0 / M.write_interval

    assert_operator actual, :<, permitted,
                    'the writers would be measuring the rate limiter, not the database'
    assert_operator actual, :>, permitted / 2.0,
                    'and so far below it that the write path is barely exercised'
  end

  # A failed request is not a slow request. Thirty threads all getting a 500
  # get it quickly, so a verdict read off durations alone would call that a
  # success — which is why TF-706 states "no write errors" as a clause of its
  # own.
  def test_failed_requests_end_the_run_even_when_every_time_was_fast
    status, output = capture_io_of do
      M.report([load_result(p95: 8.0, errors: 274)],
               { prompts: PROMPTS, runs: RUNS, dir: File.join(@results, 'measure') }, facts)
    end

    assert_equal 1, status
    assert_includes output, '274 requests did not answer 200'
    assert_includes output, '429', 'and it says which answer came back'
  end

  def test_a_load_run_without_errors_and_within_its_limit_ends_zero
    status, = capture_io_of do
      M.report([load_result(p95: 148.0, errors: 0)],
               { prompts: PROMPTS, runs: RUNS, dir: File.join(@results, 'measure') }, facts)
    end

    assert_equal 0, status
  end

  # The load numbers stand in a table of their own. Merged with the sequential
  # ones, a reader quoting a p95 would have no way of knowing whether it came
  # from one call or from thirty clients at once — two different questions with
  # one column of answers.
  def test_the_load_results_are_reported_apart_from_the_sequential_ones
    capture_io_of do
      M.report([result(p95: 12.0), load_result(p95: 148.0, errors: 0)],
               { prompts: PROMPTS, runs: RUNS, dir: File.join(@results, 'measure') }, facts)
    end
    report = File.read(report_path)

    assert_includes report, '## Under load (TF-706, NFA-07)'
    assert_includes report, 'per second', 'the load table carries the throughput'
    assert_includes report, 'saves per minute each', 'and says why the writers are paced'
    assert_includes report, 'client p95',
                    'both views belong in the table — the gap between them is itself a finding'
    assert_includes report, 'one interpreter lock', 'and the reason it exists'
  end

  # Which run is judged on its times, and which is not. A mutation probe put
  # the limits back on the ceiling run and every case here stayed green — the
  # decision lived inside a method that starts thirty threads, where no test
  # could reach it. It is a method of its own now, and this is the case.
  def test_only_the_run_with_think_time_is_judged_on_its_times
    assert_equal 200, M.limits_for('nfa')[:read]
    assert_equal M::LOAD_WRITE_LIMIT, M.limits_for('nfa')[:write]

    assert_nil M.limits_for('ceiling')[:read],
               'under saturation a percentile measures the number of clients'
    assert_nil M.limits_for('ceiling')[:write]
  end

  # The ceiling run carries no latency limit, and that is a decision, not an
  # omission: with every client queueing, a percentile says how many clients
  # there are. 284 ms at saturation is a throughput figure, not a defect — and
  # gating on it would make the verdict depend on how many clients the tool
  # happens to start.
  def test_the_ceiling_run_is_not_judged_on_its_latency
    status, = capture_io_of do
      M.report([load_result(p95: 284.0, errors: 0, limit: nil, key: 'ceiling_read')],
               { prompts: PROMPTS, runs: RUNS, dir: File.join(@results, 'measure') }, facts)
    end

    assert_equal 0, status
    assert_includes File.read(report_path), 'not gated'
  end

  # Saturation is no excuse for a failed request, though.
  def test_the_ceiling_run_is_still_judged_on_its_errors
    status, = capture_io_of do
      M.report([load_result(p95: 284.0, errors: 3, limit: nil, key: 'ceiling_read')],
               { prompts: PROMPTS, runs: RUNS, dir: File.join(@results, 'measure') }, facts)
    end

    assert_equal 1, status
  end

  # A run that was asked for no load measurement must not grow an empty table
  # for it — an empty section reads like a measurement that found nothing.
  def test_a_run_without_the_load_measurement_has_no_load_table
    capture_io_of do
      M.report([result(p95: 12.0)],
               { prompts: PROMPTS, runs: RUNS, dir: File.join(@results, 'measure') }, facts)
    end

    refute_includes File.read(report_path), 'Under load'
  end

  # The one case that really starts thirty clients. It costs the suite both load
  # windows, which is why every other end-to-end case here passes `--no-load` —
  # but leaving it out entirely would mean the load path was only ever
  # exercised by hand.
  def test_the_load_measurement_really_runs_thirty_clients
    status, output = run_measure(load: true)

    assert_equal 0, status, output
    assert_includes output, 'Step 4 of 5: under load'
    assert_includes output, "#{M::LOAD_USERS} clients signed in"
    assert_includes File.read(report_path), '## Under load'
  end

  def test_no_load_leaves_the_step_out_without_leaving_a_gap_in_the_count
    status, output = run_measure

    assert_equal 0, status, output
    refute_includes output, 'under load'
    assert_includes output, 'Step 5 of 5', 'the report is still the fifth step'
  end

  # A bench whose timing middleware stopped working must stop the run, not fall
  # back on the client's stopwatch. The two numbers differ by a factor of three
  # here, and the fallback would have labelled one as the other — the exact
  # confusion the middleware exists to end.
  def test_a_run_without_server_timings_is_refused_rather_than_reported
    error = assert_raises(M::Unusable) do
      M.summarise('nfa_read', [[[12.0, 13.0], []]], [], 200, 30)
    end

    assert_includes error.message, 'no timings of its own'
    assert_includes error.message, 'not a substitute'
  end

  # The bench server times itself, because the measuring process cannot: thirty
  # Ruby threads with a stopwatch each reported a p95 that grew with the number
  # of threads while the median never moved. That timing lives in a middleware
  # **of the bench**, on a path of its own — and the delivered application must
  # never answer it. A measuring hatch that travelled would hand every visitor
  # a list of what the instance has been doing.
  def test_the_delivered_application_does_not_answer_the_bench_timing_path
    routes = File.read(File.join(CODE_ROOT, 'backend', 'app.rb'))

    refute_includes routes, PromptAtelier::BenchServer::TIMINGS_PATH
    refute_includes routes, '__bench__'
  end

  # --- the bench instance --------------------------------------------------------

  # TF-706 is about the thread pool of 18.3.1, so a bench that ran a different
  # one would answer a question about software nobody ships. The pair is read
  # out of the delivered `config/puma.rb`, and this is the case that keeps the
  # two from drifting: raise the pool there and the bench follows, without
  # anybody remembering that it has to.
  def test_the_bench_runs_the_thread_pool_the_delivery_runs
    delivered = File.read(File.join(CODE_ROOT, 'backend', 'config', 'puma.rb'))
                    .match(/^threads\s+(\d+)\s*,\s*(\d+)\s*$/)

    refute_nil delivered, 'config/puma.rb no longer states a pool, so nothing here means anything'
    assert_equal [Integer(delivered[1]), Integer(delivered[2])],
                 PromptAtelier::BenchServer.thread_pool
  end

  # And when it cannot be read, the bench refuses rather than inventing one. A
  # measurement over a pool that was guessed is worse than no measurement: it
  # carries a number and a false subject.
  def test_a_bench_that_cannot_read_the_pool_refuses_to_start
    without = File.join(install_dir('no-pool'), 'puma.rb')
    File.write(without, "bind 'tcp://127.0.0.1:1234'\n# threads 4, 4 in a comment does not count\n")
    server = PromptAtelier::BenchServer
    server.define_singleton_method(:puma_config) { without }

    assert_raises(server::NoPool) { server.thread_pool }
  ensure
    server.singleton_class.send(:remove_method, :puma_config)
  end

  # --- arguments ----------------------------------------------------------------

  def test_an_unknown_option_is_refused_before_anything_is_built
    status, output = run_measure('--runs=3', '--prompz=5')

    refute_equal 0, status
    assert_includes output, 'Unknown option'
    refute_path_exists File.join(@results, 'measure')
  end

  def test_a_count_of_zero_is_refused
    status, output = run_measure('--prompts=0')

    refute_equal 0, status
    assert_includes output, 'greater than zero'
  end

  private

  def report_path
    File.join(@results, 'reports', "measurement-#{PROMPTS}.md")
  end

  # The script as a process, in the environment a shell would give it (testbed
  # rule 12). This suite is where the four-name version of that rule ran out:
  # under Bundler 4 a `bundle exec` leaves `BUNDLE_LOCKFILE` and
  # `BUNDLER_SETUP` behind as well, and the script then died with
  # `cannot load such file -- sequel` while running perfectly from a shell.
  # `load:` defaults to false because the two load windows together take the
  # better part of a minute and most cases here are about something else
  # entirely. Exactly one case turns it on.
  def run_measure(*extra, load: false)
    arguments = extra.any? { |a| a.start_with?('--prompts') } ? extra : ["--prompts=#{PROMPTS}", *extra]
    arguments << '--no-load' unless load
    output, status = Open3.capture2e(
      script_env('PROMPTATELIER_TEST_RESULTS' => @results),
      RbConfig.ruby, File.join(CODE_ROOT, 'scripts', 'lib', 'measure.rb'),
      "--runs=#{RUNS}", *arguments, chdir: CODE_ROOT
    )
    [status.exitstatus, output]
  end

  def fake_client(body, code: '200')
    answer = Struct.new(:code, :body).new(code, body)
    Object.new.tap { |client| client.define_singleton_method(:get) { |_path| answer } }
  end

  def result(p95:)
    { id: 'TF-701', key: 'search_rare', limit: 200, requirement: 'NFA-02', found: 1,
      min: 1.0, median: 2.0, p95: p95, max: p95 }
  end

  def load_result(p95:, errors:, limit: 1000, key: 'nfa_write')
    { id: 'TF-706', key: key, limit: limit, requirement: 'NFA-07',
      found: 994, rate: 49.7, errors: errors, error_kinds: errors.zero? ? {} : { '429' => errors },
      client_p95: p95 * 3, min: 1.0, median: 2.0, p95: p95, max: p95 }
  end

  def facts
    { 'prompts' => PROMPTS, 'workspace_ids' => [1, 2] }
  end

  # Runs the block with the console captured and returns [return value, output].
  def capture_io_of
    status = nil
    output, = capture_io { status = yield }
    [status, output]
  end
end
