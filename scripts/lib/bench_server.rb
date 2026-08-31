# frozen_string_literal: true

# scripts/lib/bench_server.rb — the instance the measurements run against
#
# Started by `measure` as a **process of its own**, and that is the whole
# reason this file exists. A server booted inside the measuring process would
# share one global interpreter lock with the client asking the questions: every
# millisecond the server spent answering would be a millisecond the stopwatch
# could not run, and the load measurement of TF-706 would be measuring the
# measurement. Two processes, as in operation.
#
# It cannot be `puma -C app/config/puma.rb`, the way `start_portable` starts
# the application: that file derives the installation directory from **its own
# location** and would therefore read the operating configuration and bind the
# operating port. The bench has a directory, a database and a port of its own,
# and must not be able to reach the instance somebody is actually using.
#
# What it must not do either is invent its own settings. The thread pool is the
# subject of TF-706 — the assumption from 18.3.1 that `threads 1, 8` carries 30
# concurrent users is exactly what is being tested — so measuring a different
# pool than the delivered one would prove nothing about the delivery. The pair
# is therefore **read out of config/puma.rb**, and if it cannot be found there
# this file refuses to start rather than fall back on a number of its own. A
# bench that quietly measured 1,8 while the delivery had moved to 2,16 would
# report a result about software that no longer exists.

require 'json'
require_relative 'common'

module PromptAtelier
  module BenchServer
    extend Script

    # The line in config/puma.rb that decides how many requests are answered at
    # once. Anchored to the start of a line so a mention in a comment cannot
    # answer for it.
    THREAD_LINE = /^threads\s+(\d+)\s*,\s*(\d+)\s*$/

    # Raised when the delivered pool cannot be read. A class rather than an
    # immediate `exit!`, so that a test can ask what happens without the test
    # run being the thing that ends.
    class NoPool < StandardError; end

    # Where the bench hands out its own timings. Named here because `measure`
    # asks for this path too, and a second spelling in another file is a
    # spelling that drifts. Underscored on both sides so it cannot collide with
    # an address the application will ever want.
    TIMINGS_PATH = '/__bench__/timings'

    # How long the **server** took, measured in the server.
    #
    # **The finding this exists for.** The load measurement first timed its
    # requests in the measuring process: thirty Ruby threads with a stopwatch
    # each. At eight requests a second — eight per cent of what this machine
    # answers — it reported a 95th percentile of 163 ms. Measured against
    # client count instead of guessed at, the shape was unmistakable:
    #
    #     1 client    median 14.3 ms    p95  28.2 ms
    #     4 clients   median 12.4 ms    p95  47.3 ms
    #    12 clients   median 12.8 ms    p95 106.0 ms
    #    24 clients   median 12.9 ms    p95 208.6 ms
    #
    # The median — what the server does — never moved. The tail grew in
    # proportion to the number of **client** threads. Ruby hands the global
    # interpreter lock over in slices of up to 100 ms, so a thread whose answer
    # has arrived may wait that long before it can stop its own stopwatch. The
    # measurement was measuring the measuring tool.
    #
    # So the server times itself. This middleware sits above the application,
    # sees every request, and hands the samples out on a path of its own. That
    # path exists **only here**, never in the delivered application — a test
    # holds it to that.
    class Timings
      def initialize(app)
        @app = app
        @samples = []
        @lock = Mutex.new
      end

      def call(env)
        return dump if env['PATH_INFO'] == TIMINGS_PATH

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        status, headers, body = @app.call(env)
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
        @lock.synchronize { @samples << [env['REQUEST_METHOD'], status, elapsed] }
        [status, headers, body]
      end

      # Handing the samples out **empties** them, so a caller can bracket a run
      # with two calls and get exactly that run. Without it the second load run
      # would carry the first one's tail and nobody could see which.
      def dump
        taken = @lock.synchronize { @samples.tap { @samples = [] } }
        payload = JSON.generate(samples: taken)
        [200, { 'content-type' => 'application/json' }, [payload]]
      end
    end

    module_function

    def run(argv = [])
      directory = argv[0]
      abort_with('bench_server needs the bench directory as its first argument') if directory.nil?

      activate_gems!
      require 'puma'
      require 'puma/configuration'
      require 'puma/launcher'
      require 'app'

      App.boot!(root: directory, interface_root: interface_root)
      serve(directory)
      0
    rescue NoPool => e
      abort_with(e.message)
    end

    # The built interface, when there is one. In a delivered installation it is
    # always there; in the development tree it may be absent or stale, and the
    # server-side measurements do not need it. `measure` builds it when the
    # browser measurements ask for it.
    def interface_root
      path = File.join(app_dir, 'public')
      File.directory?(path) ? path : nil
    end

    def serve(directory)
      config = Configuration.load(root: directory)
      minimum, maximum = thread_pool

      timed = Timings.new(App)

      configuration = Puma::Configuration.new do |puma|
        puma.bind "tcp://#{config['server.host']}:#{config['server.port']}"
        puma.app timed
        puma.environment 'production'
        puma.threads minimum, maximum
      end

      Puma::Launcher.new(configuration, events: Puma::Events.new).run
    end

    # The delivered pool, taken from the delivered file. See the file header
    # for why this is not a constant here.
    def thread_pool
      match = File.read(puma_config).match(THREAD_LINE)
      if match.nil?
        raise NoPool, "No `threads <min>, <max>` line in #{puma_config}. " \
                      'The bench refuses to measure a pool the delivery does not have.'
      end

      [Integer(match[1]), Integer(match[2])]
    end

    def abort_with(message)
      warn "PromptAtelier bench: #{message}"
      $stderr.flush
      exit!(1)
    end
  end
end

exit PromptAtelier::BenchServer.run(ARGV) if $PROGRAM_NAME == __FILE__
