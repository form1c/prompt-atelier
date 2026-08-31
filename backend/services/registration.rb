# frozen_string_literal: true

require_relative 'accounts'
require_relative 'audit'

module PromptAtelier
  # Self-registration (FA-107).
  #
  # Why it exists at all in a self-hosted product: the application sends no
  # e-mail (E-13). Without registration the administrator must not only create
  # every account but also carry the one-time password to its owner over some
  # channel outside the application — by phone, by chat, on a note. Letting
  # people enter themselves does not save a few clicks, it removes the
  # handover: the password is chosen by the only person who should ever know
  # it.
  #
  # What it costs, and what the three modes are for: **an account is not only
  # a login, it is an audience.** Whoever holds one sees everything shared
  # instance-wide (E-10, FA-509). `off` is therefore what is delivered, and
  # `approval` is what the screen offers first when it is switched on.
  #
  # One setting with three values rather than two switches. Two would allow
  # "registration off, activate automatically", which means nothing — and a
  # setting that can be configured meaninglessly eventually is.
  module Registration
    MODES        = %w[off approval open].freeze
    DEFAULT_MODE = 'off'

    # Registrations from one address per hour. The meter is the audit log,
    # which already records every registration with its address (SEC-09) — a
    # second table would only be a second thing to keep in step.
    PER_IP_PER_HOUR = 5
    WINDOW_SECONDS  = 3600

    module_function

    # An unknown value is not an error here — the configuration refuses those
    # at startup (18.4). This is the fallback for callers without a
    # configuration at all: scripts and tests, where "off" is the safe answer.
    def mode(config)
      value = config && config['security.registration']
      MODES.include?(value) ? value : DEFAULT_MODE
    end

    def enabled?(config)           = mode(config) != 'off'
    def approval_required?(config) = mode(config) == 'approval'

    def per_hour(config)
      (config && config['security.registrations_per_hour']) || PER_IP_PER_HOUR
    end

    # Creates the account, or raises Accounts::Refused. Field-level complaints
    # about name, address and password stay at the endpoint, which answers them
    # per field the way every other form does; what is decided here are the
    # three rules that are about registration itself.
    def register(db, name:, email:, password:, config: nil, ip: nil, now: Time.now)
      raise Accounts::Refused, :registration_disabled unless enabled?(config)

      # Otherwise the first person to arrive takes the instance out of its
      # setup state without becoming an administrator — and FA-909 only ever
      # offers the setup page while there is no account at all. The instance
      # would then have users, content, and nobody able to administer it, with
      # no way back through the interface.
      raise Accounts::Refused, :setup_pending if db[:users].count.zero?

      raise Accounts::Refused.new(:too_many_registrations, { per_hour: per_hour(config) }) \
        if flooding?(db, ip: ip, config: config, now: now)

      pending = approval_required?(config)
      user = Accounts.create(db, name: name, email: email, password: password,
                                 pending: pending, now: now)
      Audit.record(db, Audit::USER_REGISTERED, actor: user, target_type: 'user',
                   target_id: user[:id], meta: { pending: pending }, ip: ip, now: now)

      user
    end

    # Counted over successful registrations rather than over attempts: those
    # are what cost something. A rejected form costs a comparison, an accepted
    # one costs an Argon2id run of 64 MiB — and that run is serialised
    # (Password::LOCK, 18.4), so a loop on this endpoint would not fill the
    # instance with accounts, it would put every real login in a queue behind
    # itself.
    def flooding?(db, ip:, config: nil, now: Time.now)
      return false if ip.nil?

      window = now - WINDOW_SECONDS
      db[:audit_logs].where(action: Audit::USER_REGISTERED, ip: ip)
                     .where { created_at > window }.count >= per_hour(config)
    end
  end
end
