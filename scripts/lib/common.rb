# frozen_string_literal: true

# scripts/lib/common.rb — shared basis for every script listed in 18.5.
#
# The .sh and .bat files contain no logic (18.1). Anything beyond a single
# call lives here or in the matching lib/<name>.rb, so that each rule exists
# exactly once instead of twice in two languages that drift apart.

require 'rbconfig'
require 'open3'

# The application directory is `backend/` while developing and `app/` in a
# delivered installation (18.2). Located rather than assumed, and located
# **here** rather than only in Script.app_dir below: this line runs before the
# module exists, and with a fixed `backend` every script would fail in every
# delivered installation with "cannot load such file -- services/i18n".
#
# Found by running install against a built layout instead of reading it — the
# same lesson as the start-up check before AP-01.
$LOAD_PATH.unshift(
  %w[backend app]
    .map { |name| File.expand_path("../../#{name}", __dir__) }
    .find { |dir| File.file?(File.join(dir, 'config.ru')) } ||
  File.expand_path('../../backend', __dir__)
)
require 'services/i18n'

# **A script speaks English, whatever language the application speaks** (E-12,
# BT-16). Set here, once, before any script prints a line.
#
# Most console namespaces exist only in the base table, so they came out
# English by themselves — but not all of them. `Password.policy_violations`
# builds its sentences from `password.*`, and that namespace **is** carried by
# the language file, because the browser shows those very sentences too. The
# result was a German line in the middle of an English installation:
#
#     Error Das Passwort muss mindestens 12 Zeichen lang sein.
#
# Reported from a Windows installation. Anything a script prints is console,
# and the console is English.
PromptAtelier::I18n.default_language = PromptAtelier::I18n::BASE_LANGUAGE

# **Unbuffered, and that matters most where nobody is watching.** Written to a
# terminal Ruby flushes line by line; written to a pipe or a file it collects
# several kilobytes first. Every one of these scripts starts child processes —
# npm, bundle, puma, the test suites — whose output is not buffered by us at
# all. Redirected into a log file, the child's lines therefore appear in the
# middle of a step that had not started yet, and reading the log afterwards
# means reconstructing an order that the file no longer holds. `build.log`
# already showed it. One line, and every script's log reads in the order things
# happened.
$stdout.sync = true

module PromptAtelier
  module Script
    # `extend self` rather than `module_function`: the latter turns every
    # method into a *private* instance method, so a module doing
    # `extend Script` would receive them as private singleton methods and
    # could not be exercised from a test.
    extend self

    # Installation directory: two levels above this file
    # (scripts/lib/common.rb -> scripts -> root).
    def root
      @root ||= File.expand_path('../..', __dir__)
    end

    # backend/ during development, app/ after building. Located rather than
    # guessed so the same scripts run in both layouts (18.2).
    def app_dir
      @app_dir ||= %w[backend app].map { |name| File.join(root, name) }
                                  .find { |dir| File.file?(File.join(dir, 'config.ru')) } ||
                   File.join(root, 'backend')
    end

    def gemfile         = File.join(app_dir, 'Gemfile')
    def lockfile        = File.join(app_dir, 'Gemfile.lock')
    def puma_config     = File.join(app_dir, 'config', 'puma.rb')
    def frontend_dir    = File.join(root, 'frontend')
    def tests_dir       = File.join(root, 'tests')
    def config_file     = File.join(root, 'config', 'config.yml')
    def config_template = File.join(root, 'config', 'config.example.yml')

    # Where test runs leave their traces: throwaway installations under tmp/
    # and reports under reports/. Deliberately outside project/ so that a test run
    # can never touch the development database in project/data/.
    def test_results_dir
      @test_results_dir ||= ENV.fetch('PROMPTATELIER_TEST_RESULTS',
                                      File.expand_path('../test-results', root))
    end

    def windows? = Gem.win_platform?

    # --- Output ----------------------------------------------------------
    #
    # Colours only when writing to a terminal. In a log file or in captured
    # test output the escape sequences would just be noise.

    def color? = $stdout.tty? && !windows?

    def colorize(text, code) = color? ? "\e[#{code}m#{text}\e[0m" : text

    def heading(text)
      puts
      puts colorize("== #{text}", '1')
    end

    # The three prefixes every script line carries. English like the messages
    # themselves, and written out here rather than looked up: they are the one
    # piece of console output that must still be readable when the locale
    # files cannot be loaded at all.
    #
    # Padded to the same width so the messages line up under one another —
    # a wall of text is harder to scan than a column.
    def say(text)  = puts("   #{text}")
    def ok(text)   = puts("   #{colorize('OK', '32')}    #{text}")
    def note(text) = puts("   #{colorize('Note', '33')}  #{text}")
    def bad(text)  = puts("   #{colorize('Error', '31')} #{text}")

    def t(key, **replacements) = I18n.t(key, **replacements)

    # --- Processes -------------------------------------------------------

    # Runs a command and returns [success, output]. A missing program is a
    # result, not a crash: these scripts are supposed to name missing
    # prerequisites, not fail on them.
    def capture(*command, env: {})
      output, status = Open3.capture2e(env, *command)
      [status.success?, output.strip]
    rescue Errno::ENOENT, Errno::EACCES
      [false, nil]
    end

    def available?(program)
      success, = capture(program, '--version')
      success
    end

    # Environment for every bundle/puma call. BUNDLE_GEMFILE is required: the
    # Gemfile lives in backend/ resp. app/, while the scripts work from the
    # installation directory. Without it bundle aborts with
    # "Could not locate Gemfile" (finding P-1, TF-645b).
    def bundle_env(extra = {})
      { 'BUNDLE_GEMFILE' => gemfile }.merge(extra)
    end

    # Makes the bundled gems available *inside this process*.
    #
    # The launchers from 18.5 call plain `ruby`, not `bundle exec` — they are
    # meant to stay free of logic. Scripts that only spawn other processes
    # (check_environment, run_tests) never notice. A script that needs Sequel
    # itself, such as migrate, would fail with "cannot load such file --
    # sequel". Activating Bundler here keeps the launcher thin and the rule
    # in one place (18.1).
    # A failure here **ends the script with a sentence**, not with a stack
    # trace. Two reasons, and the second was found the hard way:
    #
    #   1. Bundler prints its own paragraph and then calls `exit`. Left alone,
    #      the caller sees "Your bundle only supports platforms […]" followed
    #      by twenty lines of Ruby internals, and has to work out which of them
    #      is the message.
    #   2. Every caller wraps its body in `rescue Configuration::Error`, and
    #      that constant comes from a file which is required **after** this
    #      call. When Bundler failed, the rescue clause itself raised
    #      `NameError: uninitialized constant …::Configuration` and buried the
    #      real cause under a second, unrelated error. Reported from a Windows
    #      machine, where the mismatch below is the normal way to meet it.
    def activate_gems!
      return if @gems_activated

      ENV['BUNDLE_GEMFILE'] ||= gemfile
      begin
        require 'bundler/setup'
        # **And one real gem on top of it.** `bundler/setup` only arranges the
        # load path; with libraries that are named but not present it can
        # succeed and leave the failure to the first `require` in some service
        # file further down — where it arrives as `cannot load such file --
        # sequel` plus a stack trace through three of our own files, and the
        # message about the actual cause never gets printed at all. Found by
        # running the scripts against an installation whose libraries were out
        # of reach; the Windows report is the same situation.
        require 'sequel'
      rescue SystemExit, StandardError, LoadError
        report_missing_gems
        # `exit!`, not `exit`, and that is the whole fix for the second half of
        # the report. `exit` raises `SystemExit`, which travels out through the
        # caller's `rescue Configuration::Error` clause — and **evaluating that
        # clause** raises `NameError: uninitialized constant …::Configuration`,
        # because the file defining it is required a line later and never was.
        # The person then reads two errors, neither of them the cause.
        #
        # `exit!` ends the process without unwinding, so no rescue clause of
        # any of the eight scripts is evaluated. One line, and it holds for all
        # of them. Same tool and same reason as in `config.ru` since NT-0.
        exit!(1)
      end
      @gems_activated = true
    end

    def report_missing_gems
      puts
      bad(t('script.gems_unusable'))
      mismatch = platform_mismatch
      say(mismatch) if mismatch
      say(t('script.gems_unusable_next', command: windows? ? 'scripts\\install.bat' : 'scripts/install.sh'))
      # Flushed by hand, because the caller ends the process with `exit!` and
      # that skips the flush an ordinary exit performs. Without this the whole
      # message is written into a buffer and then thrown away — the run ends
      # with a non-zero code and **not one line** of explanation, which is
      # worse than the stack trace it replaced.
      $stdout.flush
      $stderr.flush
    end

    # --- what this package is, and what this machine is --------------------

    # The `VERSION` file of a delivered package, as key/value pairs. Empty in
    # the development tree, where there is none — everything below then simply
    # says nothing rather than guessing.
    def package_info
      @package_info ||= begin
        path = File.join(root, 'VERSION')
        File.file?(path) ? File.read(path).scan(/^(\w+):\s*(.+)$/).to_h : {}
      end
    end

    # The one sentence somebody needs when they unpacked the wrong archive.
    #
    # The name of the file says it (`…-x86_64-linux-gnu-ruby3.3.0`), but nobody
    # compares a file name with `Gem::Platform.local` in their head. Nil when
    # the package fits, when it carries no gems at all, or when there is no
    # package — saying nothing is right in all three cases.
    def platform_mismatch
      return nil unless package_info['shape'] == 'vendored'

      built = package_info['platform'].to_s
      series = package_info['ruby'].to_s
      return nil if built == Gem::Platform.local.to_s && series == RbConfig::CONFIG['ruby_version']

      t('script.package_mismatch', built: built, series: series,
                                   platform: Gem::Platform.local.to_s,
                                   running: RbConfig::CONFIG['ruby_version'])
    end

    # The command that starts the application, as a real list of arguments.
    #
    # **Ruby is invoked directly on Bundler's own script — not `bundle`.** On
    # Windows `bundle` is a batch wrapper: `spawn('bundle', …)` starts
    # `cmd.exe`, which starts Ruby, which loads Puma. The process this script
    # can see and stop is then the **wrapper**, and killing it leaves Puma
    # running and the port bound. The next start ended in
    #
    #     bind(2) for "127.0.0.1" port 9292 (Errno::EADDRINUSE)
    #
    # with thirty lines of stack trace. Reported from a Windows installation
    # after stopping and starting again. Ruby on the exe path is one process,
    # and Bundler loads Puma inside it (`kernel_load`), so what is started is
    # what can be stopped.
    #
    # Falls back to the plain name where Bundler cannot be located that way —
    # on Unix there is no wrapper in between and it makes no difference.
    # **And the executable comes from the bundle, not from the PATH.**
    #
    # `bundle exec puma` looks the command up on the PATH after putting the
    # bundle's own bin directory in front of it. Measured in a Windows virtual
    # machine: that directory did not exist. The Ruby there is a user-scoped
    # RubyInstaller whose built-in defaults carry
    # `--bindir C:/Users/<name>/AppData/Local/Microsoft/WindowsApps`, so every
    # gem executable of the installation landed in one person's profile.
    #
    # It went unnoticed for a long time because a system-wide Ruby does give
    # the bundle a bin directory, and then the lookup succeeds. Both kinds of
    # installation occur at users, so neither may be relied on.
    #
    # `Gem.bin_path` asks the activated specification and answers with the file
    # inside the bundle. `-rbundler/setup` gives the child the load path that
    # goes with it.
    # One file, started the same way by the portable mode and by both kinds of
    # service. It sets its own environment and resolves Puma from the bundle,
    # so nothing here depends on a PATH.
    def entry_point = File.join(root, 'scripts', 'lib', 'service_run.rb')

    def application_command
      [RbConfig.ruby, entry_point]
    end

    def bundler_exe
      path = Gem.bin_path('bundler', 'bundle')
      [RbConfig.ruby, path]
    rescue StandardError
      ['bundle']
    end

    # --- Version comparison ----------------------------------------------

    def version_of(text)
      return nil if text.nil?

      match = text.match(/(\d+)\.(\d+)(?:\.(\d+))?/)
      return nil unless match

      [match[1].to_i, match[2].to_i, match[3].to_i]
    end

    def at_least?(actual, minimum)
      return false if actual.nil?

      (actual <=> minimum) >= 0
    end
  end
end
