# frozen_string_literal: true

module PromptAtelier
  # Rate limiting (SEC-07, SEC-19, FA-104).
  #
  # Login attempts are counted in the database, because the limit has to
  # survive a restart — otherwise anyone could reset it by making the process
  # crash. The write and export limits live in memory: they protect against a
  # runaway client, not against a determined attacker, and a restart resetting
  # them is acceptable.
  module RateLimit
    # SEC-07: 5 per account in 15 minutes, 20 per IP address in 15 minutes.
    WINDOW_MINUTES       = 15
    ATTEMPTS_PER_ACCOUNT = 5
    ATTEMPTS_PER_IP      = 20

    # SEC-19: 120 writing calls per minute and session, 5 imports/exports per
    # minute and user.
    WRITES_PER_MINUTE  = 120
    EXPORTS_PER_MINUTE = 5

    module_function

    # --- login attempts (SEC-07) --------------------------------------------

    def record_attempt(db, email:, ip:, now: Time.now)
      db[:login_attempts].insert(email: email.to_s.downcase, ip: ip, attempted_at: now)
    end

    # True when this account or this address has spent its attempts.
    #
    # Checked BEFORE the password is verified, so a locked account costs an
    # attacker a request and not a full Argon2id run — otherwise the limit
    # would be an amplifier rather than a brake.
    def locked_out?(db, email:, ip:, config: nil, now: Time.now)
      !lockout_reason(db, email: email, ip: ip, config: config, now: now).nil?
    end

    # Which of the two limits took hold: :ip, :account, or nil. The caller
    # needs to know because the audit entry is collapsed under that key
    # (Audit.collapse_failed_login), and the two buckets are different sizes.
    #
    # The address is asked first, and deliberately. Somebody spraying one
    # password across five thousand accounts trips the address limit long
    # before any single account limit; keyed per account that would be five
    # thousand collapsed entries instead of one, which is the very growth the
    # collapsing exists to stop.
    def lockout_reason(db, email:, ip:, config: nil, now: Time.now)
      window = now - (window_minutes(config) * 60)

      unless ip.nil?
        by_ip = db[:login_attempts].where(ip: ip).where { attempted_at > window }.count
        return :ip if by_ip >= per_ip(config)
      end

      by_account = db[:login_attempts]
                   .where(email: email.to_s.downcase)
                   .where { attempted_at > window }.count
      return :account if by_account >= per_account(config)

      nil
    end

    # After a successful login the account's failed attempts are cleared, so a
    # user who mistyped twice and then got it right does not carry the count
    # around for another quarter of an hour.
    #
    # The IP counter is deliberately NOT cleared: one successful login must
    # not wipe the evidence of nineteen failures from the same address.
    def clear_attempts(db, email:)
      db[:login_attempts].where(email: email.to_s.downcase).delete
    end

    def window_minutes(config) = (config && config['security.lockout_minutes']) || WINDOW_MINUTES
    def per_account(config) = (config && config['security.login_attempts_per_account']) || ATTEMPTS_PER_ACCOUNT
    def per_ip(config) = (config && config['security.login_attempts_per_ip']) || ATTEMPTS_PER_IP

    # --- in-memory counters (SEC-19) ----------------------------------------

    COUNTERS = {}
    COUNTER_LOCK = Mutex.new

    # Counts one event for +key+ and says whether the limit is now exceeded.
    # A sliding window of timestamps rather than a counter with a reset: a
    # fixed window lets twice the limit through at the boundary.
    def exceeded?(key, limit:, window: 60, now: Time.now)
      COUNTER_LOCK.synchronize do
        events = COUNTERS[key] ||= []
        events.reject! { |at| at <= now - window }
        events << now
        events.size > limit
      end
    end

    def writes_exceeded?(session_id, limit: WRITES_PER_MINUTE, now: Time.now)
      exceeded?(['write', session_id], limit: limit, now: now)
    end

    def exports_exceeded?(user_id, limit: EXPORTS_PER_MINUTE, now: Time.now)
      exceeded?(['export', user_id], limit: limit, now: now)
    end

    # Tests need a clean slate; so does a long-running process that should not
    # accumulate keys for sessions that ended.
    def reset!
      COUNTER_LOCK.synchronize { COUNTERS.clear }
    end
  end
end
