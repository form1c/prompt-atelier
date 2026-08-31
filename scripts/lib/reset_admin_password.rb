# frozen_string_literal: true

# scripts/lib/reset_admin_password.rb — emergency access from the command line
# (18.5, BT-13, FA-903, E-13)
#
# There is no password reset by e-mail in v1 (E-13). If nobody can sign in any
# more, this is the way back — and it deliberately requires access to the
# machine and to the installation directory, not merely to the network.
#
# Two properties matter and are enforced below:
#
#   * every run is written to the audit log (SEC-09, BT-13), because an
#     emergency path that leaves no trace is indistinguishable from an attack
#   * all sessions of the account are dropped (SEC-15), so a captured token
#     does not survive the reset

# **No `require 'sequel'` here**, and that line is why this file is worth
# reading twice. It stood at the top until AP-17, above `require_relative
# 'common'` — that is, before `activate_gems!` had put the bundled libraries on
# the load path. The launcher of 18.5 calls plain `ruby`, not `bundle exec`, so
# in a delivered installation this script died on its **eighteenth line**:
#
#     cannot load such file -- sequel (LoadError)
#
# The emergency path — the only way back when nobody can sign in any more
# (E-13) — was unusable in every delivery, and nothing had noticed, because
# nothing had ever run it outside a bundle. Found by writing the acceptance
# protocol: A-25 named TF-631, TF-631 named this script, and no test had ever
# started it. `activate_gems!` loads Sequel itself; everything below it uses
# `Sequel.` after that call, never before.
require 'io/console'
require 'securerandom'
require_relative 'common'

module PromptAtelier
  module ResetAdminPassword
    extend Script

    module_function

    def run(argv = [])
      activate_gems!
      require File.join(app_dir, 'services', 'configuration')
      require File.join(app_dir, 'services', 'database')
      require File.join(app_dir, 'services', 'password')
      require File.join(app_dir, 'services', 'sessions')
      require File.join(app_dir, 'services', 'audit')

      config = Configuration.load(root: root)
      I18n.default_language = config['locale']

      heading(t('reset_password.title'))
      # **Which database, before anything is changed.** `seed_demo` has said
      # this since it was written, for the same reason: a script that reaches
      # into a database ought to name the file first. It earned its place here
      # the hard way — a test started this script from the source tree, where
      # `Script.root` resolves to the development installation, and reset the
      # password of a real account. One line would have made that visible in
      # the first second instead of afterwards.
      say(t('reset_password.database', path: config.database_path))

      Database.open(config.database_path) do |db|
        account = pick_account(db, argv)
        return 1 if account.nil?

        password = argv.include?('--generate') ? SecureRandom.alphanumeric(20) : ask_password
        return 1 if password.nil?

        violations = Password.policy_sentences(password)
        unless violations.empty?
          violations.each { |line| bad(line) }
          return 1
        end

        apply(db, account, password)
        report(account, password, generated: argv.include?('--generate'))
      end

      0
    rescue Configuration::Error => e
      puts
      e.problems.each { |line| bad(line) }
      1
    end

    # Without an argument the account is only unambiguous when there is
    # exactly one instance administrator. Guessing would be the wrong kind of
    # convenience here.
    def pick_account(db, argv)
      email = argv.find { |a| a.include?('@') }

      if email
        account = db[:users].where(Sequel.function(:lower, :email) => email.downcase).first
        bad(t('reset_password.unknown_account', email: email)) if account.nil?
        return account
      end

      admins = db[:users].where(is_instance_admin: true).all
      if admins.empty?
        bad(t('reset_password.no_admin'))
        return nil
      end
      if admins.size > 1
        bad(t('reset_password.ambiguous', emails: admins.map { |a| a[:email] }.join(', ')))
        return nil
      end

      admins.first
    end

    def ask_password
      print "   #{t('reset_password.prompt')} "
      first = $stdin.noecho(&:gets)&.chomp
      puts
      print "   #{t('reset_password.repeat')} "
      second = $stdin.noecho(&:gets)&.chomp
      puts

      return first if first && first == second

      bad(t('reset_password.mismatch'))
      nil
    end

    def apply(db, account, password)
      now = Time.now
      db[:users].where(id: account[:id]).update(
        password_hash: Password.create(password),
        must_change_pw: true,
        status: 'active',
        updated_at: now
      )
      # SEC-15: a captured token must not survive the reset.
      Sessions.destroy_all_for(db, account[:id])
      # BT-13: the run itself is recorded. The actor is the account whose
      # password was reset, because there is no signed-in user on this path.
      Audit.record(db, 'password.reset_by_console', actor: account,
                   target_type: 'user', target_id: account[:id], now: now)
    end

    def report(account, password, generated:)
      puts
      ok(t('reset_password.done', email: account[:email]))
      say(t('reset_password.generated', password: password)) if generated
      say(t('reset_password.must_change'))
      say(t('reset_password.sessions_dropped'))
    end
  end
end

exit PromptAtelier::ResetAdminPassword.run(ARGV) if $PROGRAM_NAME == __FILE__
