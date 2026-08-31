# frozen_string_literal: true

# scripts/lib/measure.rb — the numbers of chapter 12, measured instead of
# claimed (Testkonzept section 11, TF-701 to TF-707)
#
# **Why this script is delivered.** The acceptance rule in Testkonzept 14 says
# sections 10 and 11 are to be carried out on real systems and with a real
# stock — expressly not in the development environment. A measuring tool that
# only exists in the source tree makes that rule unfulfillable: the numbers
# would always be the numbers of the developing machine, and the one question
# an operator has ("does my server carry my 20.000 prompts?") could never be
# answered on the machine it is about. It needs no Node and no test suite, only
# Ruby, so there is nothing standing in the way of delivering it.
#
# **It never touches the operating instance.** Own directory, own database, own
# port, own accounts — the same rule the test suites follow. The bench sits
# beside the installation, not inside `data/`, it says where it is before it
# writes anything, and it is removed again unless `--keep` says otherwise.
#
# What is measured here is the **server side**: the time between a request
# arriving over a real socket and its answer being complete. That is the part
# NFA-02 and NFA-05 are about. The browser adds its own share — rendering, the
# debounce of FA-303 — and that share is measured where it happens, in the
# browser measurements of section 11. Neither number is the other, and adding
# them up is the only honest way to read chapter 12.
#
#   measure                    5.000 prompts, 20 runs per case (NFA-02, NFA-05)
#   measure --prompts=20000    the stock of NFA-08 (TF-707)
#   measure --runs=50          more runs, tighter percentile
#   measure --keep             leave the bench in place for the next run
#   measure --serve            keep it **running** afterwards and say where

require 'etc'
require 'fileutils'
require 'json'
require 'net/http'
require 'securerandom'
require 'socket'
require 'uri'
require 'yaml'
require_relative 'common'
require_relative 'bench'
# For BenchServer::TIMINGS_PATH — the path the bench server hands its own
# timings out on. Requiring rather than restating it keeps one spelling.
require_relative 'bench_server'

module PromptAtelier
  module Measure
    extend Script

    DEFAULT_PROMPTS = 5_000
    DEFAULT_RUNS    = 20

    # Runs that are thrown away before the stopwatch counts. The first call
    # into a fresh process pays for page cache, prepared statements and the
    # first fill of SQLite's own cache — costs that occur once in the life of
    # an instance and would otherwise be charged to every measurement.
    WARMUP = 5

    # The percentile of Testkonzept section 11. Not the average: an average
    # hides the slow tail, and the slow tail is what people notice.
    PERCENTILE = 95

    # How long the bench server is given to come up before the run is
    # abandoned. Generous, because a 20.000-prompt database opens a little
    # slower than an empty one.
    STARTUP_SECONDS = 60

    # Raised when a case cannot be measured at all — the answer failed, or it
    # found less than the case is named after. Its own class so that `run` can
    # end with **one sentence** instead of a stack trace through four of our
    # own files: the reader has to see which query was too thin, not which line
    # of Ruby noticed.
    class Unusable < StandardError; end

    module_function

    def run(argv = [])
      activate_gems!
      options = parse(argv)
      return 1 if options.nil?

      require File.join(app_dir, 'services', 'configuration')
      require File.join(app_dir, 'services', 'database')
      require File.join(app_dir, 'services', 'migrator')
      require File.join(app_dir, 'services', 'password')
      require File.join(app_dir, 'services', 'accounts')
      require File.join(app_dir, 'services', 'workspaces')
      require File.join(app_dir, 'services', 'prompts')
      # For SEC-19's write limit, which paces the writing clients of the load
      # measurement. Read from the service so a changed limit changes the
      # measurement with it.
      require File.join(app_dir, 'services', 'rate_limit')

      heading(t('measure.title'))
      say(t('measure.bench', path: options[:dir]))
      say(t('measure.machine', description: machine))

      facts = prepare(options)
      # The report is written **inside** the block, and that is the only reason
      # the block has a body at all: with `--serve` the instance stays up when
      # the block returns, and a report printed after that would appear once
      # somebody had already stopped using it.
      status = 1
      with_server(options) do |client|
        results = measure_all(client, facts, options) +
                  (options[:load] ? load_measurement(facts, options) : [])
        status = report(results, options, facts)
      end
      status
    rescue Unusable => e
      puts
      bad(e.message)
      1
    ensure
      FileUtils.rm_rf(options[:dir]) if options && !options[:keep] && options[:dir]
    end

    # --- arguments ------------------------------------------------------------

    def parse(argv)
      options = { prompts: DEFAULT_PROMPTS, runs: DEFAULT_RUNS, keep: false,
                  reseed: false, load: true, serve: false, dir: default_dir }

      argv.each do |argument|
        case argument
        when /\A--prompts=(\d+)\z/ then options[:prompts] = Integer(Regexp.last_match(1))
        when /\A--runs=(\d+)\z/    then options[:runs]    = Integer(Regexp.last_match(1))
        when /\A--dir=(.+)\z/      then options[:dir]     = File.expand_path(Regexp.last_match(1))
        when '--keep'              then options[:keep]    = true
        when '--reseed'            then options[:reseed]  = true
        # The load measurement takes 20 seconds and writes to the stock. Both
        # are reasons somebody repeating a search timing wants it out of the
        # way — never a reason for it to be missing from a release measurement,
        # which is why it is on by default.
        when '--no-load'           then options[:load]    = false
        # A-02 asks a person to walk W-1 at 5.000 prompts, and nothing else
        # hands them a library that size to walk. Implies --keep: an instance
        # that is deleted the moment somebody starts using it is no use.
        when '--serve'             then options[:serve] = options[:keep] = true
        else
          heading(t('measure.title'))
          bad(t('measure.unknown_option', option: argument))
          return nil
        end
      end

      return options if options[:runs].positive? && options[:prompts].positive?

      bad(t('measure.needs_positive'))
      nil
    end

    # Beside the installation, never inside `data/`. Two reasons: a bench
    # database under `data/` would be picked up by `backup` and would travel
    # into every archive from then on, and `package` refuses outright when it
    # finds a stray database there — which is right, and would turn a
    # forgotten measurement into a refused delivery.
    def default_dir = File.join(test_results_dir, 'measure')

    # --- the bench ------------------------------------------------------------

    # Builds the stock, or keeps the one that is already there. Seeding 20.000
    # prompts takes minutes; repeating it for every run of a measurement series
    # would make the tool too slow to be used, which is how measuring stops
    # happening.
    def prepare(options)
      existing = reusable_stock(options)
      if existing
        heading(t('measure.step_stock_kept', count: options[:prompts]))
        return existing
      end

      heading(t('measure.step_stock', count: options[:prompts]))
      FileUtils.rm_rf(options[:dir])
      FileUtils.mkdir_p(File.join(options[:dir], 'config'))
      FileUtils.mkdir_p(File.join(options[:dir], 'data'))
      write_configuration(options)

      Migrator.new(database_path: database_of(options),
                   migrations_dir: File.join(app_dir, 'migrations'),
                   backup_dir: File.join(options[:dir], 'data', 'backups')).run

      facts = seed(options)
      File.write(facts_path(options), JSON.pretty_generate(facts))
      ok(t('measure.stock_written', count: options[:prompts]))
      facts
    end

    def seed(options)
      last = 0
      facts = Database.open(database_of(options)) do |db|
        Bench.build(db, prompts: options[:prompts], progress: lambda { |written|
          next unless written - last >= 1_000 || written == options[:prompts]

          last = written
          say(t('measure.stock_progress', written: written, total: options[:prompts]))
        })
      end
      # Symbol keys survive the round trip through JSON as strings, so the
      # facts are normalised **here** rather than at every reader.
      JSON.parse(JSON.generate(facts))
    end

    # A stock is reusable when it was built for the same number of prompts and
    # nobody asked for a fresh one. The count is read from the facts file
    # rather than counted in the database: a half-written bench from an
    # interrupted run has rows but no facts file, and reusing it would measure
    # a library nobody can describe.
    def reusable_stock(options)
      return nil if options[:reseed]
      return nil unless File.file?(facts_path(options)) && File.file?(database_of(options))

      facts = JSON.parse(File.read(facts_path(options)))
      return nil unless facts['prompts'] == options[:prompts]

      facts
    rescue JSON::ParserError
      nil
    end

    def facts_path(options)  = File.join(options[:dir], 'bench.json')
    def database_of(options) = File.join(options[:dir], 'data', 'promptatelier.db')

    # The bench configuration. A port of its own, picked free at build time and
    # written down, so that a kept bench keeps answering at the same address
    # between runs. Argon2 stays at the delivered cost: the accounts are
    # created the way any account is, and the sign-in is not part of any
    # measurement.
    def write_configuration(options)
      port = free_port
      settings = {
        'server' => { 'host' => '127.0.0.1', 'port' => port,
                      'base_url' => "http://127.0.0.1:#{port}" },
        'security' => { 'registration' => 'off' }
      }

      path = File.join(options[:dir], 'config', 'config.yml')
      File.write(File.join(options[:dir], 'config', 'config.example.yml'),
                 File.read(config_template))
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(YAML.dump(settings))
      end
    end

    def free_port
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      server.close
      port
    end

    def bench_port(options)
      YAML.safe_load(File.read(File.join(options[:dir], 'config', 'config.yml')),
                     permitted_classes: [], aliases: false).dig('server', 'port')
    end

    # --- the server -----------------------------------------------------------

    # Starts the bench instance, hands a signed-in client to the block and
    # stops the server afterwards **whatever happened in between**. A measuring
    # run that dies halfway and leaves a Puma holding a port is the fault that
    # makes the next run fail for a reason that has nothing to do with it —
    # the same finding as the EADDRINUSE report from Windows.
    def with_server(options)
      heading(t('measure.step_server'))
      port = bench_port(options)
      pid = spawn(*server_command(options), chdir: root, **own_group)

      unless awaited(port, pid)
        stop(pid)
        raise Unusable, t('measure.server_silent', seconds: STARTUP_SECONDS)
      end

      ok(t('measure.server_up', port: port))
      yield Client.new(port)
      stay(options, port, pid) if options[:serve]
    ensure
      stop(pid) if pid
    end

    # Hands the bench over to a person and waits.
    #
    # **A-02 cannot be met without this.** It asks somebody familiar with the
    # application to walk W-1 at 5.000 prompts — and until now nothing produced
    # a library that size that anybody could click on. `seed_demo` writes ten to
    # fifteen prompts, and the measuring instance was torn down the moment the
    # numbers were taken.
    def stay(options, port, pid)
      facts = JSON.parse(File.read(facts_path(options)))
      puts
      heading(t('measure.serving'))
      say(t('measure.serving_address', url: "http://127.0.0.1:#{port}"))
      say(t('measure.serving_account', email: facts['email'], password: facts['password']))
      say(t('measure.serving_stock', count: facts['prompts']))
      say(t('measure.serving_stop'))

      %w[INT TERM].each { |name| Signal.trap(name) { throw :done } }
      catch(:done) { Process.waitpid(pid) }
    rescue Errno::ECHILD, Interrupt
      nil
    end

    def server_command(options)
      [bundle_env('RACK_ENV' => 'production'),
       RbConfig.ruby, File.join(__dir__, 'bench_server.rb'), options[:dir]]
    end

    def own_group = windows? ? { new_pgroup: true } : { pgroup: true }

    # Waits for the health endpoint — and watches the child at the same time.
    # Waiting only for the port would turn a server that aborted at once into a
    # full minute of silence followed by a timeout, which reads like a slow
    # machine rather than like the refusal it is.
    def awaited(port, pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STARTUP_SECONDS

      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        return false if Process.waitpid(pid, Process::WNOHANG)
        return true if healthy?(port)

        sleep 0.2
      end
      false
    rescue Errno::ECHILD
      false
    end

    def healthy?(port)
      Net::HTTP.start('127.0.0.1', port, open_timeout: 1, read_timeout: 2) do |http|
        http.get('/health').code == '200'
      end
    rescue StandardError
      false
    end

    def stop(pid)
      Process.kill(windows? ? 'KILL' : 'TERM', windows? ? pid : -pid)
      50.times do
        return if Process.waitpid(pid, Process::WNOHANG)

        sleep 0.1
      end
      Process.kill('KILL', windows? ? pid : -pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    # --- the measurements -----------------------------------------------------

    # What is asked, what it may cost — and **how much it has to find**.
    #
    # The two limits are the two requirements: a search is allowed 200 ms
    # (NFA-02), every other reading call 150 ms (NFA-05). Deliberately more
    # than one case per limit: a search for a word that occurs once and one for
    # a word that occurs in every eighth prompt exercise opposite halves of the
    # index, and a single comfortable query would let the tool report a number
    # that says nothing.
    #
    # `expect` is the lesson of the first run. Every case was green, and one of
    # them was searching for a term the measuring account was not allowed to
    # see: 200 OK, zero results, 1.4 ms — the best number in the table, over
    # nothing at all. A measurement that does not say what it found cannot be
    # told apart from a measurement of an empty answer, so each case now states
    # its floor and the run stops when the answer falls below it.
    def measurement_cases(client, facts)
      workspace = facts['workspace_id']
      prompt_id = first_prompt_id(client, workspace)
      stock = facts['prompts']

      [
        { id: 'TF-701', key: 'search_rare', limit: 200, requirement: 'NFA-02', expect: 1..1,
          path: library_path(workspace, q: facts['rare_terms'].first) },
        { id: 'TF-701', key: 'search_common', limit: 200, requirement: 'NFA-02', expect: share(stock, 30),
          path: library_path(workspace, q: facts['common_term']) },
        { id: 'TF-701', key: 'search_prefix', limit: 200, requirement: 'NFA-02', expect: share(stock, 60),
          path: library_path(workspace, q: 'Fassaden') },
        { id: 'TF-701', key: 'search_umlaut', limit: 200, requirement: 'NFA-02', expect: share(stock, 60),
          path: library_path(workspace, q: facts['umlaut_term']) },
        { id: 'TF-704', key: 'library_page', limit: 150, requirement: 'NFA-05', expect: share(stock, 4),
          path: library_path(workspace) },
        { id: 'TF-704', key: 'library_sorted', limit: 150, requirement: 'NFA-05', expect: share(stock, 4),
          path: library_path(workspace, sort: 'title') },
        { id: 'TF-704', key: 'prompt_detail', limit: 150, requirement: 'NFA-05', expect: 1..1,
          path: "#{API}/prompts/#{prompt_id}" },
        { id: 'TF-704', key: 'workspaces', limit: 150, requirement: 'NFA-05', expect: 3..,
          path: "#{API}/workspaces" },
        { id: 'TF-704', key: 'tags', limit: 150, requirement: 'NFA-05', expect: 5..,
          path: "#{API}/tags?workspace_id=#{workspace}" }
      ]
    end

    # The floor a case has to clear, as a fraction of the stock rather than as
    # a number. The frequencies in `bench` are proportional by construction, so
    # a fixed floor would be a statement about 5.000 prompts that quietly
    # became wrong for every other size — and the first small run would look
    # like a defect in the corpus instead of a floor that never fitted.
    # Never zero: a case that is allowed to find nothing is the case this
    # whole mechanism exists to prevent.
    #
    # `Range.new(x, nil)` rather than `x..`: a trailing `..` at the end of a
    # line goes on reading the next one, and the endless range then began at
    # something else entirely. It failed with `bad value for range`, which
    # names neither the line nor the reason.
    def share(stock, divisor) = Range.new([stock / divisor, 1].max, nil)

    # How much an answer found. `meta.total` for anything that pages, otherwise
    # the number of entries in the one list the answer carries — a single
    # prompt counts as one. Read from the answer rather than from the database,
    # so what is counted is what the caller actually received.
    def found_in(body)
      parsed = JSON.parse(body)
      return parsed.dig('meta', 'total') if parsed.dig('meta', 'total')
      return 1 if parsed.key?('prompt')

      list = parsed.values.find { |value| value.is_a?(Array) }
      list ? list.length : 0
    end

    API = '/api/v1'

    def library_path(workspace, q: nil, sort: nil)
      query = { 'workspace_id' => workspace }
      query['q'] = q if q
      query['sort'] = sort if sort
      "#{API}/prompts?#{URI.encode_www_form(query)}"
    end

    # An identifier from the stock rather than a guessed one. Prompt 1 belongs
    # to whoever the seeding created first, and `visibility: private` means the
    # measuring account may not be allowed to read it — the case would then
    # measure the speed of a 403.
    def first_prompt_id(client, workspace)
      body = JSON.parse(client.get(library_path(workspace)).body)
      body.fetch('prompts').first.fetch('id')
    end

    def measure_all(client, facts, options)
      client.login(facts['email'], facts['password'])
      heading(t('measure.step_measurements', runs: options[:runs]))

      measurement_cases(client, facts).map do |measurement|
        found = verify(client, measurement)
        samples = collect(client, measurement[:path], options[:runs])
        measurement.merge(statistics(samples)).merge(found: found)
                   .tap { |result| announce(result) }
      end
    end

    # Once per case, before the stopwatch starts: does this query find what the
    # case is named after? See `measurement_cases` for why this exists.
    def verify(client, measurement)
      response = client.get(measurement[:path])
      expect_ok(response, measurement[:path])
      found = found_in(response.body)
      return found if measurement[:expect].cover?(found)

      raise Unusable, t('measure.too_few', case: measurement[:path], found: found,
                                           expected: describe(measurement[:expect]))
    end

    # `5..` has no last element and asking for one raises, so the open end is
    # read from `end` being nil rather than from comparing the two.
    def describe(expected)
      expected.end.nil? || expected.end > expected.begin ? "at least #{expected.begin}" : expected.begin.to_s
    end

    # One case. The warm-up runs are thrown away, and every answer is checked:
    # a 500 answered in 3 ms would otherwise be the fastest result in the
    # table.
    def collect(client, path, runs)
      WARMUP.times { expect_ok(client.get(path), path) }

      Array.new(runs) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = client.get(path)
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
        expect_ok(response, path)
        elapsed
      end
    end

    def expect_ok(response, path)
      return if response.code == '200'

      raise Unusable, t('measure.not_answered', path: path, code: response.code)
    end

    def statistics(samples)
      { min: samples.min, median: percentile(samples, 50),
        p95: percentile(samples, PERCENTILE), max: samples.max }
    end

    # Nearest rank, the definition Testkonzept section 11 uses: the smallest
    # value that at least 95 % of the samples are less than or equal to. No
    # interpolation between neighbours — with 20 samples that would invent a
    # measurement nobody took.
    def percentile(samples, wanted)
      sorted = samples.sort
      rank = (wanted / 100.0 * sorted.length).ceil
      sorted[[rank - 1, 0].max]
    end

    def announce(result)
      line = t('measure.result', case: t("measure.case_#{result[:key]}"),
                                 p95: format('%.1f', result[:p95]),
                                 limit: result[:limit], found: result[:found])
      result[:p95] <= result[:limit] ? ok(line) : bad(line)
    end

    # --- the load measurement (TF-706, NFA-07) --------------------------------
    #
    # **The outstanding proof for the assumption in 18.3.1.** `threads 1, 8` was
    # chosen with a stated reason and never measured; NFA-07 asks for 30
    # concurrent users. Everything below is about making that number mean
    # something — and the first attempt made it mean the wrong thing.
    #
    # **Thirty users are not thirty requests in flight.** The first version ran
    # thirty clients with no pause at all, on the argument that the harsher
    # reading is the safer one. At 5.000 prompts it produced 98 requests a
    # second and a read p95 of 306 ms against a limit of 200. That looks like a
    # failed requirement and is not one. Little's law on the same two numbers:
    # 98 × 0.306 ≈ 30 — every one of the thirty clients was **queueing**, all of
    # the time. The mean service time was 10 ms, the same as the sequential
    # measurement; nothing had got slower. The server was simply saturated, and
    # under saturation the latency says how many clients there are, not how
    # fast the software is. Add a thirty-first and it rises again.
    #
    # So the step measures **two different things**, and keeps them apart:
    #
    #   * **NFA-07 (gated).** Thirty clients that behave like people: after each
    #     answer they pause. That is the requirement as written, and it is the
    #     number that decides.
    #   * **The ceiling (reported, not gated).** The same thirty clients flat
    #     out. It answers "how much does this machine have in reserve", which is
    #     what an operator actually wants to know, and it is a throughput figure
    #     — the latency beside it is a property of the client count.
    #
    # **Six of the thirty write.** SQLite allows one writer at a time (R-03),
    # so the risk NFA-07 really carries is on the writing side, and a load
    # measurement made of reads alone would miss it completely. The writers
    # save an existing prompt, which is the commonest write there is and the
    # expensive one: a revision is kept (FA-701) and the full text index is
    # rebuilt for that row.
    #
    # They change the **description** of prompts at the end of the stock, never
    # a title and never one of the needles. The corpus keeps its size and every
    # searched term keeps its frequency, so a bench left in place with `--keep`
    # still measures the same library afterwards.

    LOAD_USERS   = 30
    LOAD_WRITERS = 6

    # The pause between one answer and the next request, drawn from an
    # exponential distribution with this mean. Exponential rather than fixed
    # because thirty people in lockstep are not thirty people — the bunching is
    # half of what a load measurement is for.
    #
    # Three seconds is **fast**. Someone reading a prompt, filling two fields
    # and deciding takes longer; this is the pace of somebody who knows exactly
    # what they are looking for and does nothing else. Stated here rather than
    # buried, because it is the one number in this file that a reader is
    # entitled to disagree with.
    THINK_SECONDS = 3.0

    # The gated window and the ceiling window. The first is longer because
    # thinking clients send fewer requests, and a percentile over sixty samples
    # is a percentile over almost nothing.
    NFA_SECONDS     = 30
    CEILING_SECONDS = 20

    # **The writers keep to the speed limit even at full tilt** — the finding of
    # the first ceiling run.
    #
    # SEC-19 allows 120 writing calls per minute and session. Six writers with
    # no pause between saves reached about 500 a minute each, and 274 of 994
    # saves came back `429 rate_limited`. Nothing was broken: the limiter did
    # exactly what it is for. But the measurement had become a measurement **of
    # the limiter**, over durations that mostly belonged to refusals — and
    # refusals are fast, so the table looked excellent.
    LOAD_WRITE_HEADROOM = 0.75

    # No requirement states a limit for saving, so this one is **chosen**, and
    # saying so is part of the measurement. A second is the point at which an
    # action stops feeling like a direct consequence of the click; TF-706 asks
    # for "no noticeable delay", and this is that sentence turned into a number.
    LOAD_WRITE_LIMIT = 1_000

    def load_measurement(facts, options)
      heading(t('measure.step_load', users: LOAD_USERS, writers: LOAD_WRITERS,
                                     think: THINK_SECONDS, seconds: NFA_SECONDS))
      port = bench_port(options)

      readers = sign_in_many(port, facts['email'], facts['password'], LOAD_USERS - LOAD_WRITERS)
      writers = sign_in_many(port, facts['author_email'], facts['password'], LOAD_WRITERS)
      say(t('measure.load_signed_in', count: readers.length + writers.length))

      targets = write_targets(writers.first, facts)
      paths = read_paths(readers.first, facts)

      timings = Client.new(port)
      gated = run_load(readers, writers, paths, targets, 'nfa', timings,
                       seconds: NFA_SECONDS, think: THINK_SECONDS)
      say(t('measure.load_ceiling', seconds: CEILING_SECONDS))
      ceiling = run_load(readers, writers, paths, targets, 'ceiling', timings,
                         seconds: CEILING_SECONDS, think: nil)

      (gated + ceiling).each { |result| announce_load(result) }
    end

    # The bench server's own view, emptied and read back around each run. See
    # `BenchServer::Timings` for why the client's stopwatch cannot be the one
    # that decides.
    def server_timings(client)
      JSON.parse(client.get(BenchServer::TIMINGS_PATH).body).fetch('samples')
    end

    # Signed in one after another, before the stopwatch starts. Argon2 is
    # serialised behind a mutex (18.3), so thirty sign-ins at once would queue
    # anyway — and they would be queueing inside the measurement instead of
    # before it.
    def sign_in_many(port, email, password, count)
      Array.new(count) do
        Client.new(port).tap { |client| client.login(email, password) }
      end
    end

    # The prompts the writers save, taken from the **end** of the library by
    # title. The needles sit at the start of the stock, and a writer that
    # happened to rewrite one of them would change what the search cases find.
    def write_targets(client, facts)
      path = library_path(facts['workspace_id'], sort: 'title')
      body = JSON.parse(client.get("#{path}&per_page=#{LOAD_WRITERS}&page=2").body)
      rows = body.fetch('prompts')
      raise Unusable, t('measure.load_no_targets') if rows.length < LOAD_WRITERS

      rows.map { |row| row.fetch('id') }
    end

    # What the readers ask for: a search, a library page and a single prompt,
    # in turn. The same three shapes the sequential cases measure, so the two
    # tables can be held against each other.
    def read_paths(client, facts)
      workspace = facts['workspace_id']
      [library_path(workspace, q: facts['common_term']),
       library_path(workspace),
       "#{API}/prompts/#{first_prompt_id(client, workspace)}",
       library_path(workspace, q: facts['umlaut_term'])]
    end

    # +think+ is the mean pause between requests, or nil for the ceiling run.
    # The two runs differ in nothing else, which is what makes their numbers
    # comparable — and the comparison is the interesting part: the same clients,
    # the same queries, once behaving like people and once not.
    def run_load(readers, writers, paths, targets, kind, timings, seconds:, think:)
      server_timings(timings) # emptied, so what follows belongs to this run only
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      reading = readers.each_with_index.map do |client, i|
        reader_thread(client, paths, i, deadline, think)
      end
      writing = writers.each_with_index.map do |client, i|
        writer_thread(client, targets[i], deadline, think)
      end

      outcomes = { read: reading.map(&:value), write: writing.map(&:value) }
      server = server_timings(timings).group_by { |method, _, _| method == 'PUT' ? :write : :read }

      limits = limits_for(kind)

      %i[read write].map do |side|
        summarise("#{kind}_#{side}", outcomes[side], server.fetch(side, []), limits[side], seconds)
      end
    end

    # The ceiling run carries **no latency limit**, and that is the whole point
    # of separating the two runs: under saturation every client is queueing, so
    # a percentile measures how many clients the tool happened to start. It is
    # still gated on errors — saturation is no excuse for a failed request.
    #
    # A method of its own so the decision can be asked about. Inline it was a
    # ternary inside a method that starts thirty threads, and no test could
    # reach it without a load run.
    def limits_for(kind)
      return { read: 200, write: LOAD_WRITE_LIMIT } if kind == 'nfa'

      { read: nil, write: nil }
    end

    def reader_thread(client, paths, offset, deadline, think)
      Thread.new do
        samples = []
        errors = []
        round = offset
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          timed(samples, errors) { client.get(paths[round % paths.length]) }
          round += 1
          pause(think)
        end
        [samples, errors]
      end
    end

    # Exponentially distributed around +mean+, by inverse transform. Nil means
    # the ceiling run, which does not pause at all.
    def pause(mean)
      return if mean.nil?

      sleep(-Math.log(1.0 - rand) * mean)
    end

    # Each writer saves its own prompt, so the six of them are contending for
    # the one write lock SQLite allows — which is the point. The value changes
    # every round, because `Prompts.update` deliberately writes nothing when
    # nothing changed (FA-701): saving the same text back would have measured
    # a no-op thirty times a second.
    # A writer never goes faster than SEC-19 allows, whether it is thinking or
    # not — see LOAD_WRITE_HEADROOM. With a think time it is slower still, and
    # that is right: nobody saves twice a second.
    def writer_thread(client, prompt_id, deadline, think)
      floor = write_interval
      Thread.new do
        samples = []
        errors = []
        round = 0
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          round += 1
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          timed(samples, errors) do
            client.put("#{API}/prompts/#{prompt_id}",
                       'description' => "Unter Last gespeichert, Durchgang #{round}.")
          end
          pause(think)
          rest = floor - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
          sleep(rest) if rest.positive?
        end
        [samples, errors]
      end
    end

    # Taken from SEC-19 itself rather than written down here, so that a changed
    # limit changes the measurement with it. See LOAD_WRITE_HEADROOM.
    def write_interval
      60.0 / (RateLimit::WRITES_PER_MINUTE * LOAD_WRITE_HEADROOM)
    end

    def timed(samples, errors)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = yield
      samples << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000)
      errors << response.code unless response.code == '200'
    rescue StandardError => e
      errors << e.class.name
    end

    # Two views of the same run, and only one of them decides.
    #
    # `p95` is the **server's** own timing — the number the limit is held
    # against. `client_p95` is what the measuring process saw; it is reported
    # beside it because the gap between the two is worth seeing, and because
    # somebody comparing this table with the sequential one needs to know that
    # the sequential figures are client-side and uncontended.
    def summarise(key, outcomes, server, limit, seconds)
      samples = outcomes.flat_map(&:first)
      errors  = outcomes.flat_map(&:last)
      raise Unusable, t('measure.load_silent', case: key) if samples.empty?

      server_samples = server.map(&:last)
      # **No falling back to the client's numbers.** The first version did, and
      # a bench whose timing middleware had stopped working would have gone on
      # reporting — quietly labelling client figures as the server's, which is
      # the very confusion this whole arrangement exists to end.
      raise Unusable, t('measure.no_server_timings', case: key) if server_samples.empty?

      { id: 'TF-706', key: key, limit: limit, requirement: 'NFA-07',
        found: samples.length, errors: errors.length, error_kinds: errors.tally,
        rate: (samples.length / seconds.to_f).round(1),
        client_p95: percentile(samples, PERCENTILE) }
        .merge(statistics(server_samples))
    end

    # A failed request is not a slow request, and the two must not be summed
    # into one verdict. The line therefore says both, and the gate below reads
    # both.
    def announce_load(result)
      line = t("measure.load_result#{result[:limit] ? '' : '_ceiling'}",
               case: t("measure.case_#{result[:key]}"),
               p95: format('%.1f', result[:p95]), limit: result[:limit],
               client: format('%.1f', result[:client_p95]),
               requests: result[:found], rate: result[:rate], errors: result[:errors])
      passed?(result) ? ok(line) : bad(line)
    end

    # No limit means the ceiling run: it can only fail on errors. See run_load.
    def passed?(result)
      return false if result[:errors].to_i.positive?

      result[:limit].nil? || result[:p95] <= result[:limit]
    end

    # --- the report -----------------------------------------------------------

    # Written down, always, including when the run failed its targets. A
    # measurement that only leaves a number on a console is one nobody can
    # compare with next month's.
    def report(results, options, facts)
      heading(t('measure.step_report'))
      path = report_path(options)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, report_text(results, options, facts))
      ok(t('measure.report_written', path: path))

      missed = results.reject { |result| result[:limit].nil? || result[:p95] <= result[:limit] }
      # A failed request is its own verdict. Thirty threads that all get a 500
      # get it quickly, so a table read on times alone would call that a
      # success — and TF-706 asks for "no write errors" as a separate clause
      # precisely because it cannot be inferred from a duration.
      failed = results.select { |result| result[:errors].to_i.positive? }
      return 0 if missed.empty? && failed.empty?

      puts
      missed.each { |result| bad(t('measure.missed', requirement: result[:requirement],
                                                     case: t("measure.case_#{result[:key]}"))) }
      failed.each { |result| bad(t('measure.errors', case: t("measure.case_#{result[:key]}"),
                                                     count: result[:errors],
                                                     kinds: result[:error_kinds].to_a.map { |kind, n|
                                                       "#{kind}×#{n}"
                                                     }.join(', '))) }
      1
    end

    # Beside the bench, not beside this script. The bench is removed at the end
    # of a run and the report has to outlive it, so it goes one level up —
    # which with the default `--dir` is the same `reports/` directory
    # `run_tests` writes into, and with `--dir=` follows wherever the operator
    # put the bench. Deriving it from the bench keeps the two together: a
    # report in a directory the run never mentioned is one nobody finds again.
    def report_path(options)
      File.join(File.dirname(options[:dir]), 'reports', "measurement-#{options[:prompts]}.md")
    end

    def report_text(results, options, facts)
      sequential, load = results.partition { |result| result[:id] != 'TF-706' }

      sequential_report(sequential, options, facts) + load_report(load)
    end

    # The load table stands apart from the sequential one, and not for layout.
    # The two answer different questions — "how fast is one call" and "what
    # happens when thirty people are here at once" — and a reader who took a
    # p95 out of a merged table would have no way of knowing which of the two
    # they were quoting.
    def load_report(load)
      return '' if load.empty?

      <<~REPORT

        ## Under load (TF-706, NFA-07)

        #{LOAD_USERS} clients, #{LOAD_WRITERS} of them saving. Measured twice, because
        the two runs answer two different questions.

        **The requirement (#{NFA_SECONDS} s).** The clients behave like people: after each
        answer they pause, for a time drawn from an exponential distribution
        with a mean of #{THINK_SECONDS} s. Three seconds is fast — somebody who knows
        exactly what they want and does nothing else. This is the run that
        decides.

        **The ceiling (#{CEILING_SECONDS} s).** The same clients with no pause at all. Read as a
        **throughput** figure: how much this machine has in reserve. The latency
        beside it is **not** a verdict — under saturation every client is
        queueing, so the percentile measures how many clients there are. It is
        gated on errors only.

        The writers never exceed **#{(RateLimit::WRITES_PER_MINUTE * LOAD_WRITE_HEADROOM).round} saves per minute each**, a quarter below the
        limit SEC-19 sets. Driven past it they measure the rate limiter instead
        of the database: refusals are fast, and a table of fast refusals looks
        like a good result.

        The limit for saving is **chosen, not quoted**: no requirement states one.
        #{LOAD_WRITE_LIMIT} ms is where an action stops feeling like a consequence of the click.

        | Case | Requests | per second | Errors | p#{PERCENTILE} | Limit | min | median | max | client p#{PERCENTILE} | |
        |---|---|---|---|---|---|---|---|---|---|---|
        #{load.map { |result| load_row(result) }.join("\n")}

        Every figure but the last is the **server's own** measurement, taken inside
        the bench instance. The last column is what the measuring process saw.
        The gap between them is the measuring process itself: thirty Ruby threads
        share one interpreter lock, which is handed on in slices of up to 100 ms,
        so a thread whose answer arrived long ago may not get to stop its own
        stopwatch. That is why the limit is held against the server's number.
        Against the client's, this table would say more about the machine running
        `measure` than about the one answering.
      REPORT
    end

    def load_row(result)
      cells = [t("measure.case_#{result[:key]}"), result[:found], result[:rate],
               result[:errors].zero? ? 'none' : result[:error_kinds].to_a.join(' '),
               format('%.1f', result[:p95]), result[:limit] || 'not gated',
               format('%.1f', result[:min]), format('%.1f', result[:median]),
               format('%.1f', result[:max]), format('%.1f', result[:client_p95]),
               passed?(result) ? 'ok' : 'MISSED']
      "| #{cells.join(' | ')} |"
    end

    def sequential_report(results, options, facts)
      <<~REPORT
        # Measurement report — Prompt Atelier #{version}

        | | |
        |---|---|
        | Taken | #{Time.now.strftime('%Y-%m-%d %H:%M:%S %z')} |
        | Machine | #{machine} |
        | Stock | #{facts['prompts']} prompts, #{facts['workspace_ids'].length} workspaces |
        | Runs per case | #{options[:runs]} (after #{WARMUP} discarded warm-up runs) |
        | Thread pool | #{thread_pool_note} |

        Server-side times in milliseconds: from the request arriving over a real
        socket to the answer being complete. The browser adds its own share; it is
        measured separately (TF-702, TF-703).

        | Case | Test | Requirement | Found | p#{PERCENTILE} | Limit | min | median | max | |
        |---|---|---|---|---|---|---|---|---|---|
        #{results.map { |result| report_row(result) }.join("\n")}

        "Found" is the number of prompts the query answered with. It is in the
        table because a fast answer over an empty result is the one failure a
        table of times cannot show by itself.
      REPORT
    end

    def report_row(result)
      cells = [t("measure.case_#{result[:key]}"), result[:id], result[:requirement],
               result[:found], format('%.1f', result[:p95]), result[:limit],
               format('%.1f', result[:min]), format('%.1f', result[:median]),
               format('%.1f', result[:max]),
               result[:p95] <= result[:limit] ? 'ok' : 'MISSED']
      "| #{cells.join(' | ')} |"
    end

    def version
      require File.join(app_dir, 'version')
      PromptAtelier::VERSION
    rescue StandardError, LoadError
      package_info['version'].to_s
    end

    def thread_pool_note
      match = File.read(puma_config).match(/^threads\s+(\d+)\s*,\s*(\d+)\s*$/)
      match ? "#{match[1]}, #{match[2]} (config/puma.rb)" : 'unknown'
    rescue StandardError
      'unknown'
    end

    # Which machine the numbers belong to. Without it a report is a table of
    # figures about nothing — 180 ms on a laptop and 180 ms on a virtual server
    # with one core are entirely different findings.
    def machine
      cores = begin
        Etc.nprocessors
      rescue StandardError
        '?'
      end
      "#{RUBY_DESCRIPTION.split(' (').first}, #{Gem::Platform.local}, #{cores} cores"
    end

    # --- the client -----------------------------------------------------------

    # One connection for the whole run. A browser keeps its connection open,
    # and opening a fresh TCP connection per request would put the handshake
    # into every measurement — a cost that occurs once in reality and would be
    # charged nine times here.
    class Client
      CSRF_COOKIE = 'promptatelier_csrf'

      def initialize(port)
        @http = Net::HTTP.new('127.0.0.1', port)
        @http.keep_alive_timeout = 60
        @http.start
        @cookies = {}
      end

      def login(email, password)
        request = Net::HTTP::Post.new("#{API}/auth/login", 'Content-Type' => 'application/json')
        request.body = JSON.generate(email: email, password: password)
        response = perform(request)
        return if response.code == '200'

        raise "Signing in as #{email} failed with #{response.code}: #{response.body}"
      end

      def get(path) = perform(Net::HTTP::Get.new(path))

      # SEC-05 is double submit: the header has to repeat what the cookie says.
      # A load run without it would be measuring the speed of `403 csrf_failed`
      # — thirty threads answered in two milliseconds each, and a report full of
      # excellent numbers about a write that never happened.
      def put(path, payload)
        request = Net::HTTP::Put.new(path, 'Content-Type' => 'application/json',
                                           'X-CSRF-Token' => @cookies.fetch(CSRF_COOKIE, ''))
        request.body = JSON.generate(payload)
        perform(request)
      end

      private

      def perform(request)
        request['Cookie'] = @cookies.map { |name, value| "#{name}=#{value}" }.join('; ') if @cookies.any?
        response = @http.request(request)
        remember(response)
        response
      end

      def remember(response)
        Array(response.get_fields('Set-Cookie')).each do |header|
          name, value = header.split(';').first.split('=', 2)
          @cookies[name] = value
        end
      end
    end
  end
end

exit PromptAtelier::Measure.run(ARGV) if $PROGRAM_NAME == __FILE__
