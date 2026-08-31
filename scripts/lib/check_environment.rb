# frozen_string_literal: true

# scripts/lib/check_environment.rb — verify prerequisites (18.5, BT-02)
#
# Names each missing prerequisite together with the concrete installation
# command for the detected system, instead of only reporting "prerequisite
# missing" (18.3.1).
#
# Errors and notes are kept strictly apart:
#
#   error  prevents operation or building. Exit code 1.
#   note   concerns convenience, not function. Exit code 0.
#
# The system SQLite version is explicitly only a note: the application does
# not use it, because the sqlite3 gem ships its own library (18.3.1, TF-611).
# Aborting there would be factually wrong.

require_relative 'common'

module PromptAtelier
  module CheckEnvironment
    extend Script

    # Requirements 18.3. Both bounds are evidenced, not estimated:
    #   Ruby 3.3  because sqlite3 >= 2.9 requires Ruby >= 3.2, and 3.1/3.2 are
    #             both out of maintenance.
    #   Node      because Vite 7+ demands exactly this compound range.
    RUBY_MINIMUM     = [3, 3, 0].freeze
    NODE_RANGES      = [
      { major: 20, from: [20, 19, 0] },
      { major: nil, from: [22, 12, 0] }
    ].freeze
    NODE_DESCRIPTION = '^20.19.0 || >=22.12.0'
    SQLITE_COMFORT   = [3, 27, 0].freeze

    module_function

    # **In a delivered installation the build tools are not checked** — Node and
    # npm are expressly not prerequisites for running the application (18.3),
    # the frontend ships as finished files. That was wrong until AP-16a: a
    # delivered `check_environment` reported two errors, each with the sentence
    # "It is needed only to build the frontend, not to run it" written next to
    # it, and exited 1. A message that says something is not a problem, over an
    # exit code that says it is, is worse than either alone. Reported from a
    # Windows machine.
    #
    # +--all+ asks for them anyway, +--operation-only+ suppresses them in the
    # development tree; the default now follows the layout.
    # +--skip-gems+ leaves the gem check out. `install` uses it, because
    # installing the gems is what its **second** step is for — see there.
    # +--no-heading+ leaves the heading out, for a caller that already printed
    # one of its own.
    def run(argv = [])
      build_tools = argv.include?('--all') || !(delivered? || argv.include?('--operation-only'))

      heading(t('environment.title')) unless argv.include?('--no-heading')
      errors = []
      notes  = []

      check_package(errors)
      check_ruby(errors)
      check_bundler(errors)
      # The lockfile is checked even with --skip-gems. A missing one is a
      # property of the **package**, not of the machine: without it nothing
      # would be binding and `bundle install` would resolve afresh, so NFA-20
      # is gone. That is not something install's second step repairs — unlike
      # libraries that are merely not installed here yet.
      check_lockfile(errors)
      check_gems(errors) unless argv.include?('--skip-gems')
      if build_tools
        check_node(errors)
        check_npm(errors)
      end
      check_sqlite(notes)

      puts
      notes.each { |n| note(n) }

      if errors.empty?
        ok(t('environment.all_satisfied'))
        note(t('environment.notes_found', count: notes.size)) unless notes.empty?
        0
      else
        errors.each { |e| bad(e) }
        puts
        bad(t('environment.problems_found', count: errors.size))
        1
      end
    end

    # --- individual checks -----------------------------------------------

    # The first thing to say when somebody unpacked the wrong archive. It comes
    # before Ruby and Bundler on purpose: everything below it will fail as a
    # consequence, and three consequences are harder to read than one cause.
    def check_package(errors)
      mismatch = platform_mismatch
      return if mismatch.nil?

      errors << mismatch
    end

    def check_ruby(errors)
      actual = version_of(RUBY_VERSION)

      if at_least?(actual, RUBY_MINIMUM)
        ok(t('environment.checked', name: 'Ruby', version: RUBY_VERSION))
      else
        errors << t('environment.ruby_too_old',
                    actual: RUBY_VERSION,
                    expected: RUBY_MINIMUM.join('.'),
                    command: install_command(:ruby))
      end
    end

    def check_bundler(errors)
      success, output = capture('bundle', '--version')
      if success
        ok(t('environment.checked', name: 'Bundler', version: version_of(output)&.join('.') || output))
      else
        errors << t('environment.bundler_missing', command: 'gem install bundler')
      end
    end

    # The gems themselves, and this is the check that was missing (BT-02).
    #
    # Ruby, Bundler and Node being present says nothing about whether the
    # dependencies are installed — and "not installed yet" is the **normal**
    # state right after unpacking, as is "the lockfile changed" right after an
    # update. Without this check the first symptom is a stack trace from
    # `bundle exec` at some later moment, which is exactly what BT-02 exists to
    # replace.
    #
    # `bundle check` is asked rather than the files being looked at: it knows
    # about platform-specific gems and about native extensions built for a
    # different Ruby ABI, and a gem compiled for 3.3 that does not load on 3.4
    # is precisely the case somebody hits after upgrading their Ruby.
    def check_lockfile(errors)
      return if File.file?(lockfile)

      errors << t('environment.lockfile_missing_check', path: lockfile, command: install_hint)
    end

    def check_gems(errors)
      return unless File.file?(lockfile)

      success, output = capture('bundle', 'check', env: bundle_env)
      if success
        ok(t('environment.checked', name: 'Gems', version: t('environment.gems_complete')))
      else
        errors << t('environment.gems_missing',
                    detail: first_meaningful_line(output),
                    command: install_hint)
      end
    end

    # The first **sentence**, not the first line.
    #
    # Bundler wraps its output at the terminal width, so the first line of a
    # platform complaint ended mid-list: "Your bundle only supports platforms
    # [\"aarch64-linux-gnu\", \"aarch64-linux-musl\"," — and the part that named
    # the actual cause ("but your local platform is x64-mingw-ucrt") was in the
    # piece that got cut off. Joined back together and shortened at a word.
    def first_meaningful_line(output)
      sentence = String(output).lines.map(&:strip).reject(&:empty?).join(' ')
      return sentence if sentence.length <= 160

      "#{sentence[0, 160].rpartition(' ').first} …"
    end

    # In a delivered installation the way to repair this is `install`, in the
    # development tree it is `bundle install`. Saying the wrong one would send
    # somebody down a path that does not exist for them.
    #
    # The same holds for the two spellings of the script. Naming both and
    # letting the reader pick was a way of naming the wrong one as well, and on
    # Windows the wrong one came first.
    def install_hint
      return 'bundle install' unless delivered?

      windows? ? 'scripts\\install.bat' : 'scripts/install.sh'
    end

    def delivered? = File.basename(app_dir) == 'app'

    def check_node(errors)
      success, output = capture('node', '--version')
      unless success
        errors << t('environment.node_missing', command: install_command(:node))
        return
      end

      actual = version_of(output)
      if node_suitable?(actual)
        ok(t('environment.checked', name: 'Node.js', version: output))
      else
        errors << t('environment.node_unsuitable',
                    actual: output,
                    expected: NODE_DESCRIPTION,
                    command: install_command(:node))
      end
    end

    # ^20.19.0 means: at least 20.19.0 but still major version 20.
    # >=22.12.0 has no upper bound.
    def node_suitable?(actual)
      return false if actual.nil?

      NODE_RANGES.any? do |range|
        next false unless (actual <=> range[:from]) >= 0

        range[:major].nil? || actual[0] == range[:major]
      end
    end

    def check_npm(errors)
      success, output = capture('npm', '--version')
      if success
        ok(t('environment.checked', name: 'npm', version: output))
      else
        errors << t('environment.npm_missing', command: install_command(:node))
      end
    end

    # Only a note, see the file header.
    def check_sqlite(notes)
      success, output = capture('sqlite3', '--version')
      unless success
        notes << t('environment.sqlite_missing')
        return
      end

      actual = version_of(output)
      if at_least?(actual, SQLITE_COMFORT)
        ok(t('environment.checked', name: 'sqlite3 (system)', version: actual.join('.')))
      else
        notes << t('environment.sqlite_old', actual: actual&.join('.'), expected: SQLITE_COMFORT.join('.'))
      end
    end

    # --- platform specific installation commands --------------------------

    def install_command(what)
      commands = case platform
                 when :debian
                   { ruby: 'sudo apt install ruby-full  (Debian 12 ships only 3.1 — use rbenv or ruby-build there)',
                     node: 'sudo apt install nodejs npm  (only if the version fits, otherwise nodesource or nvm)' }
                 when :fedora
                   { ruby: 'sudo dnf install ruby ruby-devel', node: 'sudo dnf install nodejs npm' }
                 when :arch
                   { ruby: 'sudo pacman -S ruby', node: 'sudo pacman -S nodejs npm' }
                 when :macos
                   { ruby: 'brew install ruby', node: 'brew install node' }
                 when :windows
                   { ruby: 'RubyInstaller with DevKit from https://rubyinstaller.org/',
                     node: 'https://nodejs.org/ (LTS) or: winget install OpenJS.NodeJS.LTS' }
                 else
                   { ruby: 'https://www.ruby-lang.org/en/documentation/installation/',
                     node: 'https://nodejs.org/' }
                 end
      commands[what]
    end

    def platform
      return :windows if windows?
      return :macos   if RbConfig::CONFIG['host_os'] =~ /darwin/

      if File.exist?('/etc/os-release')
        content = File.read('/etc/os-release')
        return :debian if content.match?(/\b(debian|ubuntu|linuxmint|raspbian)\b/i)
        return :fedora if content.match?(/\b(fedora|rhel|centos|rocky|almalinux)\b/i)
        return :arch   if content.match?(/\b(arch|manjaro|endeavouros)\b/i)
      end

      :unknown
    end
  end
end

exit PromptAtelier::CheckEnvironment.run(ARGV) if $PROGRAM_NAME == __FILE__
