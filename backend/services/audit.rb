# frozen_string_literal: true

require 'json'
require 'time'

module PromptAtelier
  # The audit log (SEC-09).
  #
  # SEC-09 lists the operations that must be recorded and calls that list a
  # lower bound, not a complete enumeration. The constants below name what is
  # recorded today; adding one is a line here plus a call.
  #
  # There is no delete and exactly one kind of update: the collapsed entry of
  # `collapse_failed_login`, which counts instead of repeating itself. Nothing
  # is editable through the interface (SEC-09, TF-522), which is enforced by
  # there being no code that could — not by a permission check that someone
  # might loosen.
  module Audit
    LOGIN_SUCCEEDED   = 'login.succeeded'
    LOGIN_FAILED      = 'login.failed'
    LOGIN_FAILED_MANY = 'login.failed.collapsed'
    LOGOUT            = 'logout'
    PASSWORD_CHANGED  = 'password.changed'
    PROFILE_CHANGED   = 'profile.changed'
    SETUP_COMPLETED   = 'setup.completed'
    USER_CREATED      = 'user.created'
    USER_REGISTERED   = 'user.registered'
    USER_APPROVED     = 'user.approved'
    USER_LOCKED       = 'user.locked'
    USER_UNLOCKED     = 'user.unlocked'
    USER_DELETED      = 'user.deleted'
    SETTINGS_CHANGED  = 'settings.changed'

    # Everything the log can say, for the filter of FA-908. Listed rather than
    # gathered with SELECT DISTINCT: a filter built from what happens to be in
    # the table offers nothing for an event that has not occurred yet, so the
    # entry a search is most likely aimed at would be the one option missing.
    ACTIONS = [
      LOGIN_SUCCEEDED, LOGIN_FAILED, LOGIN_FAILED_MANY, LOGOUT,
      PASSWORD_CHANGED, PROFILE_CHANGED, SETUP_COMPLETED,
      USER_CREATED, USER_REGISTERED, USER_APPROVED,
      USER_LOCKED, USER_UNLOCKED, USER_DELETED, SETTINGS_CHANGED,
      'user.password_reset', 'user.instance_admin_changed',
      'password.reset_by_console',
      'workspace.created', 'workspace.renamed', 'workspace.deleted',
      'membership.added', 'membership.role_changed', 'membership.removed',
      'prompt.purged', 'prompt.exported', 'import.completed',
      'self_disclosure.requested'
    ].freeze

    module_function

    # +actor+ may be a user row or nil — a failed login has no actor, and that
    # is exactly the case worth recording.
    #
    # actor_name is stored alongside actor_id on purpose: SEC-17 drops the id
    # when an account is deleted, and without the name the entry would say
    # that somebody did something.
    def record(db, action, actor: nil, target_type: nil, target_id: nil,
               meta: nil, ip: nil, now: Time.now)
      db[:audit_logs].insert(
        actor_id: actor && actor[:id],
        actor_name: actor && actor[:name],
        action: action,
        target_type: target_type,
        target_id: target_id,
        meta_json: meta && JSON.generate(meta),
        ip: ip,
        created_at: now
      )
    end

    # A failed login records the address that was tried, never the password
    # and never whether the account exists — the entry must not answer a
    # question the response deliberately refuses to answer (SEC-07).
    def record_failed_login(db, email:, ip:, now: Time.now)
      record(db, LOGIN_FAILED, meta: { email: email.to_s.downcase }, ip: ip, now: now)
    end

    # --- once the lockout has taken hold (SEC-07) ---------------------------
    #
    # Up to the lockout threshold every failure gets its own line. Past it they
    # are counted into a single one per window instead.
    #
    # Two reasons, and the second is the one that made this necessary. The log
    # is bounded by time, not by count, so an attacker whose attempts are
    # already being refused went on costing one row per request at whatever
    # rate they could send — around 8.6 million a day at a hundred requests a
    # second. And a hundred refusals are enough to push every administrative
    # entry out of the hundred that a screen shows, so the log stayed complete
    # and became useless at the same time.
    #
    # **Counted, not dropped.** Simply falling silent would make an attacker
    # with fifty thousand attempts indistinguishable from a colleague who
    # mistyped five times — and telling those two apart is what the log is
    # for. The count is the entire content of the entry.
    #
    # The threshold is not a new number. It is the lockout of SEC-07: from the
    # moment an attempt is refused before it is even checked, every further one
    # carries the same information as the last, which is precisely when a line
    # of its own stops being worth anything.
    def collapse_failed_login(db, key:, kind:, ip:, window_seconds:, now: Time.now)
      since = now - window_seconds
      # Keyed by address rather than by account when the address is what is
      # locked: one attacker trying five thousand accounts is one burst, and
      # keying it per account would put the row count back where it started.
      existing = db[:audit_logs]
                 .where(action: LOGIN_FAILED_MANY, target_type: kind.to_s)
                 .where { created_at > since }
                 .reverse(:id).first

      return open_collapsed(db, key: key, kind: kind, ip: ip, now: now) if existing.nil?
      return open_collapsed(db, key: key, kind: kind, ip: ip, now: now) unless same_key?(existing, key)

      meta = JSON.parse(existing[:meta_json].to_s)
      meta['count'] = meta['count'].to_i + 1
      meta['last_at'] = now.utc.iso8601

      db[:audit_logs].where(id: existing[:id]).update(meta_json: JSON.generate(meta))
    end

    def open_collapsed(db, key:, kind:, ip:, now:)
      record(db, LOGIN_FAILED_MANY, target_type: kind.to_s, ip: ip, now: now,
                 meta: { 'key' => key, 'count' => 1,
                         'first_at' => now.utc.iso8601, 'last_at' => now.utc.iso8601 })
    end

    def same_key?(entry, key)
      JSON.parse(entry[:meta_json].to_s)['key'] == key
    rescue JSON::ParserError
      false
    end
  end
end
