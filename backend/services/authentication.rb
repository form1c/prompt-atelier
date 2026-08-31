# frozen_string_literal: true

require 'sequel'
require_relative 'password'
require_relative 'sessions'
require_relative 'rate_limit'
require_relative 'audit'
require_relative 'i18n'

module PromptAtelier
  # Signing in (FA-101, FA-104, SEC-07).
  #
  # The whole point of this class is that every failing path costs the same
  # and says the same. Unknown address, wrong password, locked account —
  # a caller cannot tell them apart, neither from the message nor from the
  # time it took.
  module Authentication
    Result = Struct.new(:user, :token, :error, keyword_init: true) do
      def success? = !user.nil?
    end

    module_function

    def log_in(db, email:, password:, ip: nil, user_agent: nil, config: nil, now: Time.now)
      address = email.to_s.strip.downcase

      # Checked before anything expensive happens. A locked-out attacker must
      # not be able to make the server spend 130 ms of Argon2 per request —
      # that would turn the limit into an amplifier.
      #
      # Past this point the attempt costs nothing to refuse, and until now it
      # still cost one audit row per request — a row an attacker could go on
      # producing at request speed. From the lockout onwards they are counted
      # into one entry per window instead (SEC-07).
      reason = RateLimit.lockout_reason(db, email: address, ip: ip, config: config, now: now)
      if reason
        Audit.collapse_failed_login(
          db, kind: reason, ip: ip, now: now,
              key: reason == :ip ? ip.to_s : address,
              window_seconds: RateLimit.window_minutes(config) * 60
        )
        return failure('auth.too_many_attempts',
                       minutes: RateLimit.window_minutes(config))
      end

      user = db[:users].where(Sequel.function(:lower, :email) => address).first

      # No account: still spend one full Argon2id run against a fixed hash, so
      # the answer takes as long as a real check (SEC-07). Without it the
      # identical message would be worthless — the response time would say
      # what the message refuses to.
      unless user
        Password.verify_dummy(password)
        RateLimit.record_attempt(db, email: address, ip: ip, now: now)
        Audit.record_failed_login(db, email: address, ip: ip, now: now)
        return failure('auth.invalid_credentials')
      end

      unless Password.verify(password, user[:password_hash])
        RateLimit.record_attempt(db, email: address, ip: ip, now: now)
        Audit.record_failed_login(db, email: address, ip: ip, now: now)
        return failure('auth.invalid_credentials')
      end

      # A locked account is told so — FA-101 asks for that explicitly, and it
      # is not a leak: the caller already proved they know the password.
      #
      # The gate stays the single condition it always was. What differs is the
      # sentence: somebody who registered a minute ago and is waiting to be let
      # in must not read that their account has been locked — they would look
      # for a mistake of their own where there is none (FA-107).
      unless user[:status] == 'active'
        Audit.record_failed_login(db, email: address, ip: ip, now: now)
        return failure(user[:pending_since] ? 'auth.account_pending' : 'auth.account_locked')
      end

      RateLimit.clear_attempts(db, email: address)

      # SEC-04: a new session on every login. Reusing one would leave a token
      # valid that may have been captured before.
      token, = Sessions.create(db, user_id: user[:id], ip: ip,
                                   user_agent: user_agent, config: config, now: now)

      db[:users].where(id: user[:id]).update(last_login_at: now, updated_at: now)
      Audit.record(db, Audit::LOGIN_SUCCEEDED, actor: user, ip: ip, now: now)

      Result.new(user: db[:users][id: user[:id]], token: token)
    end

    def log_out(db, token, actor: nil, ip: nil, now: Time.now)
      # FA-102: the session is dropped server side, not merely forgotten by
      # the browser. Deleting only the cookie would leave a token that still
      # works for anyone who copied it.
      Sessions.destroy(db, token)
      Audit.record(db, Audit::LOGOUT, actor: actor, ip: ip, now: now)
    end

    # FA-105: changing your own password keeps this session and drops every
    # other one of yours.
    def change_password(db, user:, current:, replacement:, token:, ip: nil, now: Time.now)
      return failure('password.wrong_current') unless Password.verify(current, user[:password_hash])

      violations = Password.policy_violations(replacement)
      return failure_with(violations.first) unless violations.empty?

      db[:users].where(id: user[:id]).update(
        password_hash: Password.create(replacement),
        must_change_pw: false,
        updated_at: now
      )
      Sessions.destroy_others_for(db, user[:id], token)
      Audit.record(db, Audit::PASSWORD_CHANGED, actor: user, ip: ip, now: now)

      Result.new(user: db[:users][id: user[:id]])
    end

    # The refusal as a code and its parameters (AP-19, 15.2). `key` used to be
    # a text key and is now the code itself — the two were the same string
    # anyway, which is why the change is a rename and not a redesign.
    def failure(key, **replacements)
      Result.new(error: { code: key.to_s.split('.').last, params: replacements })
    end

    # For a refusal the policy already put into shape, because it may report
    # several rules at once.
    def failure_with(message)
      Result.new(error: message)
    end
  end
end
