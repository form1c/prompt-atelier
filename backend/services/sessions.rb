# frozen_string_literal: true

require 'securerandom'
require 'digest'
require 'time'

module PromptAtelier
  # Session handling (SEC-03, SEC-04, SEC-15, FA-102, FA-103).
  #
  # The token the browser holds is never stored. Only its SHA-256 goes into
  # the database, so a stolen database dump does not hand over live sessions
  # (SEC-03).
  module Sessions
    # SEC-03 asks for at least 256 bits of entropy. 32 random bytes are
    # exactly that; hex doubles the length but not the entropy.
    TOKEN_BYTES = 32

    COOKIE_NAME      = 'promptatelier_session'
    CSRF_COOKIE_NAME = 'promptatelier_csrf'

    module_function

    def generate_token = SecureRandom.hex(TOKEN_BYTES)

    # SHA-256 rather than Argon2: the token already carries 256 bits of
    # entropy, so there is nothing to brute-force and nothing to slow down.
    # Using a password hash here would cost 130 ms on *every* request.
    def hash_token(token) = Digest::SHA256.hexdigest(token.to_s)

    # Creates a session and returns [token, row]. The token is returned once
    # and never retrievable again.
    def create(db, user_id:, ip: nil, user_agent: nil, config: nil, now: Time.now)
      token = generate_token
      id = db[:sessions].insert(
        user_id: user_id,
        token_hash: hash_token(token),
        ip: ip,
        user_agent: user_agent,
        last_seen_at: now,
        expires_at: absolute_expiry(config, now),
        created_at: now
      )
      [token, db[:sessions][id: id]]
    end

    # Looks up a live session and refreshes last_seen_at.
    #
    # Returns nil for anything not usable — unknown token, expired by either
    # rule, or an account that is no longer active. The caller cannot tell
    # these apart, and neither can an attacker.
    def authenticate(db, token, config: nil, now: Time.now)
      return nil if token.nil? || token.to_s.empty?

      session = db[:sessions].where(token_hash: hash_token(token)).first
      return nil if session.nil?

      if expired?(session, config, now)
        db[:sessions].where(id: session[:id]).delete
        return nil
      end

      user = db[:users].where(id: session[:user_id]).first
      # SEC-15: a locked account loses access immediately, without waiting for
      # its sessions to be cleaned up somewhere else.
      return nil if user.nil? || user[:status] != 'active'

      db[:sessions].where(id: session[:id]).update(last_seen_at: now)
      { session: session, user: user }
    end

    # FA-103: 14 days of inactivity, 90 days absolute. Both are checked —
    # the absolute one exists precisely because activity alone would let a
    # session live forever.
    def expired?(session, config, now = Time.now)
      return true if session[:expires_at] && to_time(session[:expires_at]) <= now

      last_seen = to_time(session[:last_seen_at])
      last_seen.nil? || last_seen + (idle_days(config) * 86_400) <= now
    end

    IDLE_DAYS_DEFAULT = 14

    def idle_days(config)
      (config && config['session.idle_timeout_days']) || IDLE_DAYS_DEFAULT
    end

    def absolute_expiry(config, now = Time.now)
      days = (config && config['session.absolute_timeout_days']) || 90
      now + (days * 86_400)
    end

    # --- revocation ---------------------------------------------------------

    def destroy(db, token)
      db[:sessions].where(token_hash: hash_token(token)).delete
    end

    # SEC-15: locking, an administrator password reset and account deletion
    # all drop every session of that account.
    def destroy_all_for(db, user_id)
      db[:sessions].where(user_id: user_id).delete
    end

    # FA-105: changing your own password keeps the session you are sitting in
    # and drops the rest.
    def destroy_others_for(db, user_id, keep_token)
      db[:sessions].where(user_id: user_id)
                   .exclude(token_hash: hash_token(keep_token))
                   .delete
    end

    # --- cookies (SEC-03) ---------------------------------------------------

    # Whether the session cookie may carry Secure.
    #
    # A cookie marked Secure is never sent back over HTTP. The shipped
    # configuration listens on http://localhost (18.4), so setting it
    # unconditionally would mean nobody can log in after a standard
    # installation — the server sets the cookie, the browser never returns it,
    # every following call is a 401.
    #
    # The order of the three rules is the whole point:
    #
    #   1. an https request is genuinely secure -> always set it
    #   2. plain http to localhost -> never set it, the browser would keep the
    #      cookie to itself and every following call would be a 401
    #   3. otherwise follow force_https
    #
    # Rule 2 is narrow on purpose: localhost, 127.0.0.1 and ::1 only. A
    # private address range such as 192.168.x.x is NOT covered — traffic there
    # crosses a network, and SEC-14 wants HTTPS for it.
    def secure_cookie?(request, config)
      return true  if request.scheme == 'https'
      return false if local_request?(request)

      config ? config['security.force_https'] == true : false
    end

    def local_request?(request)
      host = request.host.to_s.downcase
      %w[localhost 127.0.0.1 ::1].include?(host)
    end

    # The attributes every session cookie carries. One place for all of them,
    # because a cookie that differs between being handed out and being
    # refreshed is a cookie the browser treats as two.
    def cookie_options(request, config, now: Time.now)
      {
        path: '/',
        httponly: true,
        same_site: :strict,
        secure: secure_cookie?(request, config),
        expires: cookie_expiry(config, now)
      }
    end

    # FA-103 says a session ends after 14 days without use. Without an expiry
    # the browser makes that promise its own way: it throws the cookie away
    # when it closes, and the session is over at the end of the day no matter
    # what the server thinks.
    #
    # Found in NT-2 — closing the tab kept the session, closing the browser
    # did not. So the cookie is given the same window the server applies, and
    # it is renewed on every authenticated call: the window slides with use,
    # exactly like `last_seen_at` on the server side. The two would otherwise
    # drift apart, and the browser's copy is the one that decides.
    def cookie_expiry(config, now = Time.now)
      now + (idle_days(config) * 86_400)
    end

    def to_time(value)
      case value
      when Time    then value
      when String  then Time.parse(value)
      when nil     then nil
      else value.respond_to?(:to_time) ? value.to_time : nil
      end
    rescue ArgumentError
      nil
    end
  end
end
