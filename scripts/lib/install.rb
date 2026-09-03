# frozen_string_literal: true

# scripts/lib/install.rb — from the unpacked archive to the first sign-in
# (18.5, BT-03, BT-04, BT-05, BT-07, BT-15)
#
# Seven steps, in this order, and each of them says what it did:
#
#   1. prerequisites   — Ruby, Bundler, the gems (check_environment)
#   2. dependencies    — installed only when they are actually missing
#   3. configuration   — created from the template
#   4. database        — the schema steps, with the backup migrate insists on
#   5. administrator   — the first account, so somebody can sign in at all
#   6. operating mode  — portable or service
#   7. start check     — the application really answers on its address
#
# **Every step is idempotent (BT-07), and the third is the one where that
# matters.** A second run must not overwrite a configuration somebody has
# edited — the port they chose, the proxies they trust, the language they set.
# So an existing configuration is kept, and the script says it kept it.
#
# **Nothing here edits a file by hand (BT-03).** Whatever is missing is asked
# for, and every answer has a switch as well, so the whole thing runs
# unattended. Without a terminal it does not fall back to asking: it says
# which switch was missing and stops, because a script that blocks on a
# question nobody can see is worse than one that fails.

require 'fileutils'
require 'io/console'
require 'net/http'
require 'socket'
require 'yaml'
require_relative 'common'

module PromptAtelier
  module Install
    extend Script

    MODES = %w[portable service].freeze

    # How long the finished installation gets to answer on its address before
    # the check gives up. Generous: the first start builds no caches but does
    # open the database and run the schema guard.
    START_TIMEOUT = 30

    module_function

    # The name of the launcher for this machine. It appeared in four messages
    # and was worked out in only one of them, so three of them told a Windows
    # user to run a shell script that is not there.
    def launcher = windows? ? 'scripts\\start_portable.bat' : 'scripts/start_portable.sh'

    def run(argv = [])
      options = parse(argv)
      return 1 if options.nil?

      heading(t('install.title'))
      say(t('install.directory', path: root))

      steps = [
        -> { prerequisites },
        -> { dependencies },
        -> { configuration(options) },
        -> { database },
        -> { administrator(options) },
        -> { operating_mode(options) },
        -> { start_check }
      ]

      steps.each_with_index do |step, index|
        code = step.call
        return code unless code.zero?

        puts if index < steps.size - 1
      end

      finish
      0
    rescue Interrupt
      puts
      bad(t('install.interrupted'))
      1
    end

    # --- 1. prerequisites ---------------------------------------------------

    # Asked for the operating case: Node and npm are build tools and are not a
    # prerequisite on a machine that only runs the application (18.3).
    #
    # **The gems are left out here, and that is the whole point of step 2.**
    # Until AP-16a this step ran the full check, so a package whose gems do not
    # fit the platform — the normal state of a universal archive, and of any
    # archive on the wrong machine — failed step 1 and the run ended. The
    # promised visible fallback to `bundle install` was in step 2 and was never
    # reached. Reported from a Windows machine, where it is the first thing
    # that happens.
    #
    # What stays fatal here is what step 2 cannot repair: no Ruby, no Bundler,
    # or a package built for another platform **and** carrying its own gems.
    def prerequisites
      require_relative 'check_environment'

      heading(t('install.step_prerequisites'))
      CheckEnvironment.run(%w[--operation-only --skip-gems --no-heading]).zero? ? 0 : 1
    end

    # --- 2. dependencies ----------------------------------------------------

    # Only when they are missing. The delivered archive brings the gems along
    # (18.3), so the normal case is that there is nothing to do — and saying
    # "already there" is more useful than a silent minute of nothing.
    def dependencies
      heading(t('install.step_dependencies'))

      if gems_present?
        ok(t('install.dependencies_present'))
        return 0
      end

      say(t('install.dependencies_slow'))
      say('')

      # **Bundler's own output is passed straight through**, and that is the
      # answer to "can this step say something while it works?".
      #
      # It ran through `capture` before, which swallows everything until the
      # end: on Windows the step compiles a library from source, and the screen
      # showed one line and then nothing at all for several minutes. Somebody
      # watching that cannot tell a slow installation from a hung one.
      #
      # A progress bar was the obvious idea and would have been a lie: nobody
      # knows in advance how many libraries will be fetched, how large they
      # are, or how long a compiler takes. A spinner would only prove the
      # process is alive. Bundler already reports the one thing that is real —
      # which library it is fetching and which it is building — so that is what
      # is shown.
      success = system(bundle_env, 'bundle', 'install', chdir: root)
      puts
      unless success
        bad(t('install.dependencies_failed'))
        return 1
      end

      ok(t('install.dependencies_installed'))
      # **Activated right here, before step 3 asks anything.**
      #
      # Installing the libraries can bring a newer Bundler with it, and Bundler
      # switches versions by **re-executing the whole process**. Left to step 4,
      # that restart happened after the port had been asked for — so the
      # question appeared twice in the log and the run looked like it had begun
      # again. Done here, the restart costs a repetition of two quiet steps
      # ("already installed") and nothing that anybody has to answer twice.
      activate_gems!
      0
    end

    def gems_present?
      success, = capture('bundle', 'check', env: bundle_env)
      success
    end

    # --- 3. configuration ---------------------------------------------------

    def configuration(options)
      heading(t('install.step_configuration'))

      if File.file?(config_file)
        # Kept: whoever ran `install` a second time — usually after an update
        # — chose a port, trusted a proxy, set a language, and none of that
        # may be thrown away by a script that was asked to update.
        ok(t('install.configuration_present', path: config_file))
        return 0
      end

      port = resolve_port(options)
      return 1 if port.nil?

      write_configuration(port)
      ok(t('install.configuration_created', path: config_file))
      0
    end

    # Written from the template so that every key the application knows is
    # present, and with 0600 from the **first** byte rather than by a chmod
    # afterwards: in between, the file would be readable by everybody
    # (SEC-20). It carries `trusted_proxies`, and whoever can widen that list
    # lifts the sign-in limit and can write any address into the audit log.
    def write_configuration(port)
      settings = YAML.safe_load(File.read(config_template, encoding: 'UTF-8'),
                                permitted_classes: [], aliases: false)
      settings['server']['port'] = port
      settings['server']['base_url'] = "http://localhost:#{port}"

      FileUtils.mkdir_p(File.dirname(config_file))
      File.open(config_file, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(YAML.dump(settings))
      end
    end

    # A port that was supplied is checked exactly as one that was typed.
    #
    # It was not, at first: `--port` went straight into the file, and the
    # collision surfaced six steps later as "the application did not answer" —
    # with a configuration already written that could never work. A refusal
    # has to name the reason at the moment it is knowable (BT-15).
    def resolve_port(options)
      return ask_port if options[:port].nil?
      return options[:port] if port_free?(options[:port])

      bad(t('install.port_taken', port: options[:port]))
      nil
    end

    def ask_port
      default = template_port

      loop do
        answer = ask(t('install.ask_port', port: default), default: default)
        return nil if answer.nil?

        port = answer.strip.empty? ? default : answer.to_i
        next bad(t('install.port_invalid')) unless port.between?(1, 65_535)
        return port if port_free?(port)

        bad(t('install.port_taken', port: port))
      end
    end

    def template_port
      YAML.safe_load(File.read(config_template, encoding: 'UTF-8'),
                     permitted_classes: [], aliases: false)
          .dig('server', 'port') || 9292
    end

    # Asked by binding, not by connecting. A connection attempt only finds a
    # port somebody is **listening** on; binding also finds the one that is
    # taken by a service which happens to be down at this moment — and that is
    # the one that would collide half an hour later.
    def port_free?(port, host: '127.0.0.1')
      server = TCPServer.new(host, port)
      server.close
      true
    rescue Errno::EADDRINUSE, Errno::EACCES
      false
    end

    # --- 4. database --------------------------------------------------------

    def database
      heading(t('install.step_database'))

      require_relative 'migrate'
      Migrate.run([]).zero? ? 0 : 1
    end

    # --- 5. administrator ---------------------------------------------------

    # FA-909 offers the same thing in the browser. Both exist on purpose:
    # whoever installs from a terminal should not have to open a browser to
    # finish, and whoever skips it here still finds the setup page.
    def administrator(options)
      heading(t('install.step_administrator'))

      activate_gems!
      require File.join(app_dir, 'services', 'configuration')
      require File.join(app_dir, 'services', 'database')
      require File.join(app_dir, 'services', 'accounts')
      require File.join(app_dir, 'services', 'audit')
      require File.join(app_dir, 'services', 'password')

      config = Configuration.load(root: root)

      Database.open(config.database_path) do |db|
        if db[:users].where(is_instance_admin: true).count.positive?
          ok(t('install.administrator_present'))
          next 0
        end

        details = admin_details(options)
        next 1 if details.nil?

        create_administrator(db, details)
        ok(t('install.administrator_created', email: details[:email]))
        0
      end
    end

    # **Asks again instead of throwing four steps of work away.**
    #
    # Until AP-16b a typo here ended the run: an empty password produced
    # "the password must be at least 12 characters" and the installation
    # stopped — after the configuration had been written, the schema applied
    # and, on Windows, several minutes spent compiling libraries. Reported from
    # a Windows installation, where the natural reaction to four unfamiliar
    # questions is to get one of them wrong.
    #
    # `ask_port` two steps earlier already loops; this step simply did not
    # follow the pattern that stood in the same file.
    #
    # A **switch** that is wrong is a different matter and still ends the run:
    # it comes from a script, nobody is there to correct it, and asking a
    # terminal that does not exist would hang.
    def admin_details(options)
      name  = ask_until(options[:admin_name], t('install.ask_admin_name')) { |value| !value.empty? }
      return nil if name.nil?

      email = ask_until(options[:admin_email], t('install.ask_admin_email')) { |value| valid_email?(value) }
      return nil if email.nil?

      password = ask_password_until(options[:admin_password])
      return nil if password.nil?

      { name: name, email: email, password: password }
    end

    # Asks until the answer is usable, or gives up after ATTEMPTS. Giving up at
    # all matters: a loop that never ends would spin for ever on a terminal
    # that keeps returning nothing at the end of its input.
    ATTEMPTS = 5

    def ask_until(supplied, question)
      unless supplied.nil?
        return supplied.strip if yield(supplied.strip)

        bad(t('install.answer_unusable'))
        return nil
      end

      ATTEMPTS.times do
        answer = ask(question)
        return nil if answer.nil?

        value = answer.strip
        return value if yield(value)

        bad(t('install.answer_empty'))
      end

      bad(t('install.too_many_attempts'))
      nil
    end

    def ask_password_until(supplied)
      unless supplied.nil?
        return supplied if Password.policy_violations(supplied).empty?

        Password.policy_sentences(supplied).each { |line| bad(line) }
        return nil
      end

      ATTEMPTS.times do
        password = ask_password
        return nil if password.nil?

        violations = Password.policy_sentences(password)
        return password if violations.empty?

        violations.each { |line| bad(line) }
      end

      bad(t('install.too_many_attempts'))
      nil
    end

    # The same rule the application applies (14.1), so an address accepted here
    # is one that can sign in afterwards.
    def valid_email?(value)
      value.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
    end

    def create_administrator(db, details)
      user = Accounts.create(db, name: details[:name], email: details[:email],
                                 password: details[:password], instance_admin: true)
      # The same entry the setup page writes (SEC-09). An instance whose first
      # account appeared without a trace would be missing exactly the record
      # that says where it came from.
      Audit.record(db, Audit::SETUP_COMPLETED, actor: user,
                       target_type: 'user', target_id: user[:id])
    end

    # --- 6. operating mode --------------------------------------------------

    # The service itself is set up by `service_install` — called from here
    # (18.6) rather than reimplemented, and still a script of its own because
    # that is the way to change one's mind later without running the whole
    # installer again (BT-04).
    #
    # A service that cannot be registered does **not** fail the installation.
    # Everything that matters is in place by now, the portable start works,
    # and the reason is on the screen. Undoing six good steps because systemd
    # is missing would be the wrong answer to "this machine has no systemd".
    def operating_mode(options)
      heading(t('install.step_mode'))

      mode = options[:mode] || ask_mode
      return 1 if mode.nil?

      if mode == 'service'
        require_relative 'service_install'
        note(t('install.mode_service_failed', command: launcher)) unless ServiceInstall.run([]).zero?
      else
        say(t('install.mode_portable_hint', command: launcher))
      end
      0
    end

    def ask_mode
      loop do
        answer = ask(t('install.ask_mode'), default: 'portable')
        return nil if answer.nil?
        return 'portable' if answer.strip.empty?

        chosen = MODES.find { |mode| mode.start_with?(answer.strip.downcase) }
        return chosen if chosen

        bad(t('install.mode_invalid', modes: MODES.join(', ')))
      end
    end

    # --- 7. start check -----------------------------------------------------

    # The step that turns "everything went well" into "it answers". A run that
    # ends without it can leave every file in place and an instance that never
    # starts — and the person would find out at the moment they wanted to sign
    # in, with no idea which of the six steps before was to blame.
    def start_check
      heading(t('install.step_start'))

      config = Configuration.load(root: root)
      pid = spawn_application

      begin
        if reachable?(config, pid)
          ok(t('install.start_ok', url: address_of(config)))
          0
        else
          bad(t('install.start_failed', command: launcher))
          1
        end
      ensure
        stop(pid)
      end
    end

    # **The same entry point the service uses, and for two reasons.**
    #
    # The first is measured. `bundle` resolves to `bundle.bat` on Windows, and
    # a batch file is run by a `cmd.exe` that starts Puma as a child of its
    # own. `stop` below then kills the wrapper and leaves Puma holding the
    # port, so the next thing to want that port cannot have it. Reported from a
    # Windows machine, where the leftover process had to be ended by hand.
    #
    # The second is that a check which starts the application differently from
    # the way it will really be started checks the wrong thing. Going through
    # `service_run.rb` makes the last step of the installation exercise exactly
    # what the service does.
    def spawn_application
      spawn(RbConfig.ruby, File.join(root, 'scripts', 'lib', 'service_run.rb'),
            chdir: root, out: File::NULL, err: File::NULL)
    end

    # Asks the application, not the socket. A bound port proves that something
    # is listening; `/health` proves that this something is the application and
    # that it reached its database (18.6).
    def reachable?(config, pid, timeout: START_TIMEOUT)
      deadline = Time.now + timeout

      while Time.now < deadline
        return false if finished?(pid)
        return true if healthy?(config)

        sleep 0.3
      end
      false
    end

    def healthy?(config)
      Net::HTTP.start(config['server.host'], config['server.port'], open_timeout: 1,
                                                                    read_timeout: 2) do |http|
        http.get('/health').code == '200'
      end
    rescue StandardError
      false
    end

    def finished?(pid)
      !Process.waitpid(pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      true
    end

    def stop(pid)
      Process.kill(windows? ? :KILL : :TERM, pid)
      Process.waitpid(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def address_of(config)
      config['server.base_url'] || "http://#{config['server.host']}:#{config['server.port']}"
    end

    # --- closing ------------------------------------------------------------

    def finish
      config = Configuration.load(root: root)

      puts
      ok(t('install.done'))
      say(t('install.done_start', command: launcher))
      say(t('install.done_url', url: address_of(config)))
    end

    # --- input --------------------------------------------------------------

    # Without a terminal there is nobody to answer, and waiting would hang a
    # pipeline for ever. Naming the switch that would have supplied the answer
    # is the difference between a script that failed and one that told you how
    # to succeed (BT-15).
    # **A question that shows a default answers itself when nobody is there.**
    #
    # Without a terminal this used to print the question, default and all, and
    # then refuse. Measured in a Debian machine: a non-interactive installation
    # without `--port` stopped **after** step 2, so eighteen gems had been
    # fetched and four compiled before anything said what was missing. In a
    # deployment or a pipeline, which is what the switches exist for, that
    # reads like a failure.
    #
    # A question without a default still refuses. There is no sensible default
    # for the name, the address or the password of the first account.
    def ask(question, default: nil)
      unless $stdin.tty?
        if default.nil?
          bad(t('install.needs_answer', question: question))
          return nil
        end

        say(t('install.using_default', value: default))
        return default.to_s
      end

      print("   #{question} ")
      $stdin.gets&.chomp
    end

    # Returns the password, or nil only when there is nobody to ask. Two
    # entries that differ are a slip, not a reason to stop — the caller asks
    # again.
    def ask_password
      unless $stdin.tty?
        bad(t('install.needs_password'))
        return nil
      end

      first = read_hidden(t('install.ask_admin_password'))
      again = read_hidden(t('install.ask_admin_password_repeat'))
      return first if first == again

      bad(t('install.password_mismatch'))
      ''
    end

    def read_hidden(question)
      print("   #{question} ")
      value = $stdin.noecho(&:gets)&.chomp
      puts
      value
    end

    # --- arguments ----------------------------------------------------------

    SWITCHES = {
      '--port' => :port, '--mode' => :mode, '--admin-name' => :admin_name,
      '--admin-email' => :admin_email, '--admin-password' => :admin_password
    }.freeze

    def parse(argv)
      options = {}
      argv.each do |argument|
        name, value = argument.split('=', 2)
        key = SWITCHES[name]
        next unless key && value

        options[key] = key == :port ? value.to_i : value
      end

      return nil unless valid?(options)

      options
    end

    def valid?(options)
      if options[:mode] && !MODES.include?(options[:mode])
        bad(t('install.mode_invalid', modes: MODES.join(', ')))
        return false
      end
      if options[:port] && !options[:port].between?(1, 65_535)
        bad(t('install.port_invalid'))
        return false
      end

      true
    end
  end
end

exit PromptAtelier::Install.run(ARGV) if $PROGRAM_NAME == __FILE__
