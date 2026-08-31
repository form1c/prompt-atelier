# frozen_string_literal: true

require_relative '../../test_helper'
require 'app'
require 'benchmark'

# TF-501 to TF-519 — authentication, sessions and the protective layers
# (SEC-01 to SEC-15, FA-101 to FA-105, FA-909).
class SecurityTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  GOOD_PASSWORD = 'korrekt-pferd-batterie-heftklammer'
  OTHER_PASSWORD = 'ganz-anderes-langes-passwort'

  def app = PromptAtelier::App

  def setup
    super
    @dir = migrated_dir('security')
    PromptAtelier::App.boot!(root: @dir)
    PromptAtelier::RateLimit.reset!
    @user = create_user('anna@example.test', GOOD_PASSWORD)
  end

  def teardown
    PromptAtelier::App.reset!
    PromptAtelier::RateLimit.reset!
    super
  end

  # --- TF-501: no password anywhere ---------------------------------------

  def test_tf501_the_stored_hash_is_argon2id_with_the_required_parameters
    hash = with_app_db { |db| db[:users].where(id: @user[:id]).get(:password_hash) }

    assert hash.start_with?('$argon2id$'), "not argon2id: #{hash[0, 20]}"
    # The parameters live in the header, and only together do they prove the
    # procedure SEC-01 asks for. m=65536 KiB is the 64 MiB.
    assert_includes hash, 'm=65536'
    assert_includes hash, 't=3'
    assert_includes hash, 'p=1'
  end

  def test_tf501_no_password_appears_in_the_database_or_in_a_response
    log_in

    with_app_db do |db|
      %i[users sessions audit_logs login_attempts].each do |table|
        dump = db[table].all.map(&:to_s).join(' ')
        refute_includes dump, GOOD_PASSWORD, "password found in #{table}"
      end
    end

    get "#{prefix}/auth/me"
    refute_includes last_response.body, GOOD_PASSWORD
    refute_includes last_response.body, 'password_hash'
  end

  # SEC-03: only the hash of the token is stored. A stolen database dump must
  # not hand over live sessions. Nothing else in the suite notices if this
  # stops being true — everything keeps working when the token is stored as
  # it is, which is exactly why the check has to be explicit.
  def test_the_session_token_is_stored_only_as_a_hash
    token = log_in

    with_app_db do |db|
      stored = db[:sessions].get(:token_hash)

      refute_equal token, stored, 'the raw token must not be in the database'
      assert_equal PromptAtelier::Sessions.hash_token(token), stored
      assert_equal 64, stored.length, 'SHA-256 in hex'
      refute_includes db[:sessions].all.map(&:to_s).join(' '), token
    end
  end

  # --- TF-502, TF-503: the policy (SEC-02) ---------------------------------

  def test_tf502_a_password_of_eleven_characters_is_refused
    log_in
    change_password(current: GOOD_PASSWORD, replacement: 'elf.zeichen')

    assert_equal 422, last_response.status
    assert_includes last_response.body, '12'
  end

  def test_tf503_a_password_from_the_frequency_list_is_refused
    log_in
    change_password(current: GOOD_PASSWORD, replacement: 'Passwort1234')

    assert_equal 422, last_response.status,
                 'twelve characters long, so only the list can catch it'
  end

  # --- TF-504 to TF-506: CSRF (SEC-05) -------------------------------------

  def test_tf504_a_writing_call_without_the_header_is_refused
    log_in
    header 'X-CSRF-Token', nil
    json_post "#{prefix}/auth/password", { current_password: GOOD_PASSWORD,
                                           new_password: OTHER_PASSWORD }

    assert_equal 403, last_response.status
    assert_equal 'csrf_failed', JSON.parse(last_response.body).dig('error', 'code')
  end

  def test_tf505_a_writing_call_with_the_wrong_token_is_refused
    log_in
    header 'X-CSRF-Token', 'falsch'
    json_post "#{prefix}/auth/password", { current_password: GOOD_PASSWORD,
                                           new_password: OTHER_PASSWORD }

    assert_equal 403, last_response.status
  end

  def test_tf506_a_reading_call_needs_no_token
    log_in
    header 'X-CSRF-Token', nil
    get "#{prefix}/auth/me"

    assert_equal 200, last_response.status
  end

  # The login itself cannot require a token — there is no session yet, and
  # demanding one would make the first request impossible.
  def test_the_login_is_exempt_from_the_csrf_check
    header 'X-CSRF-Token', nil
    json_post "#{prefix}/auth/login", { email: 'anna@example.test', password: GOOD_PASSWORD }

    assert_equal 200, last_response.status
  end

  # --- TF-507: locking out (SEC-07, FA-104) --------------------------------

  def test_tf507_the_sixth_attempt_is_refused_even_with_the_right_password
    5.times do
      json_post "#{prefix}/auth/login", { email: 'anna@example.test',
                                          password: 'falsch-aber-lang-genug' }
      assert_equal 401, last_response.status
    end

    json_post "#{prefix}/auth/login", { email: 'anna@example.test', password: GOOD_PASSWORD }

    assert_equal 401, last_response.status, 'the correct password must not help'
    assert_includes last_response.body, 'too_many_attempts'
  end

  def test_a_successful_login_clears_the_attempts_of_that_account
    2.times do
      json_post "#{prefix}/auth/login", { email: 'anna@example.test', password: 'falsch1234567' }
    end
    log_in

    with_app_db do |db|
      assert_equal 0, db[:login_attempts].where(email: 'anna@example.test').count
    end
  end

  # --- TF-508: same message, same duration (SEC-07) ------------------------

  def test_tf508_unknown_address_and_wrong_password_give_the_same_answer
    json_post "#{prefix}/auth/login", { email: 'gibtesnicht@example.test',
                                        password: 'irgendwas-langes' }
    unknown = [last_response.status, JSON.parse(last_response.body)]

    json_post "#{prefix}/auth/login", { email: 'anna@example.test', password: 'falsch-aber-lang' }
    wrong = [last_response.status, JSON.parse(last_response.body)]

    assert_equal unknown, wrong, 'status and message must be indistinguishable'
  end

  # The measurement TF-508 asks for. Ten runs rather than fifty to keep the
  # suite bearable — at 130 ms per Argon2 run fifty would cost 13 seconds.
  # The threshold stays the documented 50 ms.
  def test_tf508_the_two_paths_take_about_the_same_time
    unknown = median_duration { attempt('gibtesnicht@example.test', 'irgendwas-langes') }
    wrong   = median_duration { attempt('anna@example.test', 'falsch-aber-lang') }

    difference = ((unknown - wrong).abs * 1000).round
    assert_operator difference, :<, 50,
                    "median difference #{difference} ms — the dummy hash is what keeps this small"
  end

  # TF-508b: the counter-check. Without the dummy hash the unknown path
  # answers in microseconds while the known one pays a full Argon2 run, and
  # the identical message becomes worthless.
  def test_tf508b_without_the_dummy_hash_the_difference_would_be_obvious
    real  = median_duration { PromptAtelier::Password.verify('x', @user[:password_hash]) }
    faked = median_duration { PromptAtelier::Password.verify_dummy('x') }
    none  = median_duration { false } # what the unknown path would cost without it

    assert_operator ((real - faked).abs * 1000), :<, 50, 'with the dummy hash: indistinguishable'
    assert_operator ((real - none).abs * 1000), :>, 50, 'without it: plainly measurable'
  end

  # --- TF-510: security headers (SEC-11) -----------------------------------

  def test_tf510_every_response_carries_the_required_headers
    get '/health'

    csp = last_response.headers['content-security-policy']
    refute_nil csp
    refute_includes csp, 'unsafe-inline'
    refute_includes csp, 'unsafe-eval'
    assert_equal 'nosniff', last_response.headers['x-content-type-options']
    assert_equal 'same-origin', last_response.headers['referrer-policy']
    assert_equal 'DENY', last_response.headers['x-frame-options']
  end

  # Over plain HTTP the header would be ignored by browsers anyway, and
  # sending it would pin a policy a local installation cannot fulfil.
  def test_hsts_is_sent_over_https_and_withheld_over_http
    get '/health'
    assert_nil last_response.headers['strict-transport-security']

    get '/health', {}, 'HTTPS' => 'on', 'rack.url_scheme' => 'https'
    assert_includes last_response.headers['strict-transport-security'].to_s, 'max-age='
  end

  # --- a deliberate 404 stays a 404 (SEC-06) -------------------------------

  # The 405 handler asks which methods a path accepts and offers them. That is
  # right for a request that matched no route — and wrong for a 404 a route
  # produced on purpose to conceal an object. Found in AP-06: reading the
  # members of a foreign workspace answered "405, try POST" and thereby
  # confirmed the path was real, which is exactly what the 404 is for.
  def test_a_concealing_404_is_not_rewritten_into_a_405
    log_in
    get "#{prefix}/workspaces/999999/members"

    assert_equal 404, last_response.status
    assert_nil last_response.headers['allow'],
               'naming the permitted methods confirms the path exists'
    assert_equal 'not_found', JSON.parse(last_response.body).dig('error', 'code')
  end

  # The counter-check: a path that really does exist for another method still
  # answers 405, so the fix did not simply switch the feature off.
  def test_a_wrong_method_on_an_existing_path_still_answers_405
    get "#{prefix}/auth/logout"

    assert_equal 405, last_response.status
    assert_includes last_response.headers['allow'].to_s, 'POST'
  end

  # --- TF-518: the configuration file is not served (SEC-20) ---------------

  # The application serves the built frontend from backend/public. Everything
  # else on disk has to stay unreachable — config.yml above all: it names the
  # proxies this instance believes, and whoever can read and then widen that
  # list lifts the sign-in limit of SEC-07 and can write any address into the
  # audit log.
  #
  # A distinctive line out of the file is what the answers are searched for. It
  # used to be the session secret, which was ideal for the purpose and has
  # since gone (AP-22) — so one is planted here instead, and the assertion
  # below is what makes sure it really is in the file.
  def test_tf518_neither_the_configuration_nor_the_database_is_reachable
    marker = 'zitronenfalter.example.test'
    path = File.join(@dir, 'config', 'config.yml')
    File.write(path, File.read(path).sub(/^(\s*)base_url:.*/) { "#{$1}base_url: \"http://#{marker}\"" })
    assert_includes File.read(path), marker, 'the marker must be in the file, or this proves nothing'

    [
      '/config/config.yml',
      '/../config/config.yml',
      '/..%2fconfig%2fconfig.yml',
      '/%2e%2e/config/config.yml',
      '/public/../../config/config.yml',
      '/data/promptatelier.db',
      '/backend/services/password.rb',
      '/Gemfile'
    ].each do |path|
      get path

      assert_equal 404, last_response.status, "#{path} must not be served"
      refute_includes last_response.body, marker, "#{path} leaked the configuration"
    end
  end

  # Counter-check. Without it the test above would keep passing if static
  # delivery were switched off altogether — the 404 would then be an accident
  # rather than a refusal, and the frontend would stop being served with it.
  def test_the_public_folder_is_served_at_all
    assert PromptAtelier::App.settings.static,
           'static delivery must be on, otherwise the SPA is not served either'

    probe = File.join(PromptAtelier::App.settings.public_folder, 'tf518-probe.txt')
    File.write(probe, 'reachable')

    get '/tf518-probe.txt'

    assert_equal 200, last_response.status
    assert_equal 'reachable', last_response.body
  ensure
    FileUtils.rm_f(probe.to_s)
  end

  # --- TF-510b: forced HTTPS (SEC-14) --------------------------------------

  # The redirect was written in AP-01 and never executed until now. SEC-14
  # asks for two things at once, and they pull in opposite directions: every
  # plain call must be redirected, yet a local installation must stay usable
  # over http, because the delivered configuration points at localhost and
  # there is no TLS on that port (E-14). Both halves are pinned here.
  def test_tf510b_with_force_https_a_plain_call_is_redirected
    boot_with_force_https

    get 'http://promptatelier.example/health'

    assert_equal 301, last_response.status
    assert_equal 'https://promptatelier.example/health',
                 last_response.headers['location']
  end

  def test_tf510b_the_redirect_keeps_path_and_query
    boot_with_force_https

    get 'http://promptatelier.example/api/v1/prompts?q=blog&sort=title'

    assert_equal 'https://promptatelier.example/api/v1/prompts?q=blog&sort=title',
                 last_response.headers['location']
  end

  def test_tf510b_over_https_there_is_no_redirect_but_there_is_hsts
    boot_with_force_https

    get 'https://promptatelier.example/health', {},
        'HTTPS' => 'on', 'rack.url_scheme' => 'https'

    assert_equal 200, last_response.status
    assert_includes last_response.headers['strict-transport-security'].to_s, 'max-age='
  end

  # A reverse proxy terminates TLS and forwards plain http. Without honouring
  # the forwarded scheme the application would redirect a request that already
  # arrived over https, and the browser would loop until it gave up.
  #
  # The proxy has to be **configured** now (18.4). It was not, and the case
  # passed anyway — which is what made the counter-case below necessary.
  def test_tf510b_a_terminating_proxy_does_not_cause_a_redirect_loop
    boot_with_force_https(trusted: ['127.0.0.1'])

    get 'http://promptatelier.example/health', {}, 'HTTP_X_FORWARDED_PROTO' => 'https'

    assert_equal 200, last_response.status
  end

  # The other half of the same rule (SEC-03, SEC-14). `X-Forwarded-Proto` is
  # written by whoever sends the request; from anybody but a proxy of our own
  # it is a claim, not evidence. Believing it lets a caller switch off the
  # redirect that SEC-14 demands simply by asserting they are already secure —
  # and it decides the `Secure` attribute of the session cookie besides.
  #
  # Worth its own case because Rack's `request.scheme` reads that header by
  # itself: a check written on top of `scheme` looks right and never runs.
  def test_the_forwarded_scheme_is_not_believed_from_a_stranger
    boot_with_force_https

    get 'http://promptatelier.example/health', {}, 'HTTP_X_FORWARDED_PROTO' => 'https'

    assert_equal 301, last_response.status,
                 'nobody is configured as a proxy, so nobody vouches for that header'
    assert_nil last_response.headers['strict-transport-security'],
               'and no policy is pinned over a connection that is not secure'
  end

  def test_tf510b_localhost_stays_reachable_over_http
    boot_with_force_https

    ['http://localhost:9292/health', 'http://127.0.0.1:9292/health'].each do |url|
      get url
      assert_equal 200, last_response.status, "#{url} must not be redirected away"
    end
  end

  def test_without_force_https_nothing_is_redirected
    get 'http://promptatelier.example/health'

    assert_equal 200, last_response.status
  end

  # --- TF-511: the session cookie (SEC-03) ---------------------------------

  # Cookie attribute names are case-insensitive per RFC 6265, and Rack 3
  # emits them lower case. The assertions fold the case rather than pinning a
  # spelling that is not part of the contract.
  def test_tf511_over_http_on_localhost_the_cookie_has_no_secure_flag
    log_in
    cookie = raw_session_cookie.downcase

    assert_includes cookie, 'httponly'
    assert_includes cookie, 'samesite=strict'
    refute_includes cookie, 'secure',
                    'a Secure cookie would never come back over http and nobody could log in'
  end

  def test_tf511b_over_https_the_cookie_carries_secure
    json_post "#{prefix}/auth/login", { email: 'anna@example.test', password: GOOD_PASSWORD },
              'HTTPS' => 'on', 'rack.url_scheme' => 'https'

    assert_includes raw_session_cookie.downcase, 'secure'
  end

  # The exception is for localhost only. A private address range crosses a
  # network and must not be treated as local.
  def test_the_localhost_exception_does_not_extend_to_private_addresses
    request = Rack::Request.new(Rack::MockRequest.env_for('http://192.168.1.5/x'))
    config  = { 'security.force_https' => true }

    assert PromptAtelier::Sessions.secure_cookie?(request, config)
    refute PromptAtelier::Sessions.local_request?(request)
  end

  # --- TF-511c: the cookie outlives the browser (FA-103) --------------------

  # Found in NT-2: closing the tab kept the session, closing the browser
  # ended it. A cookie without an expiry is a session cookie, and a browser
  # throws those away when it closes — whatever FA-103 promises about 14 days.
  def test_tf511c_the_session_cookie_carries_the_window_from_fa103
    log_in

    expires = cookie_expiry(raw_session_cookie)
    refute_nil expires, 'without an expiry the browser ends the session when it closes'
    assert_in_delta Time.now + (14 * 86_400), expires, 120
  end

  # The counter-check to the case above. Without it the assertion would hold
  # just as well for a hard-wired fortnight that ignores the configuration —
  # and an operator who shortens the window would be told one thing by the
  # server and another by their browser.
  def test_tf511c_the_expiry_follows_the_configured_window
    PromptAtelier::App.reset!
    write_config(@dir, valid_config.merge('session' => { 'idle_timeout_days' => 3 }))
    PromptAtelier::App.boot!(root: @dir)
    log_in

    assert_in_delta Time.now + (3 * 86_400), cookie_expiry(raw_session_cookie), 120
  end

  # Both cookies or neither. With the CSRF cookie gone and the session cookie
  # still there, every write would end in 403 and nothing but signing out
  # would get the user back to a working state (SEC-05).
  def test_tf511c_the_csrf_cookie_expires_with_the_session_cookie
    log_in

    assert_in_delta cookie_expiry(raw_session_cookie),
                    cookie_expiry(raw_csrf_cookie), 2
  end

  # FA-103 counts from the last use, not from the sign-in. So the cookie is
  # handed out again on every authenticated call — otherwise a session used
  # daily would still end after a fortnight, on the browser side only, which
  # is the side that decides.
  def test_tf511c_every_authenticated_call_hands_the_cookie_out_again
    log_in

    get "#{prefix}/auth/me"

    assert_equal 200, last_response.status
    assert_in_delta Time.now + (14 * 86_400), cookie_expiry(raw_session_cookie), 120
  end

  # And the window is measured from that call, not from a fixed point. With
  # the two tests above alone this would also hold for an expiry computed
  # once at sign-in and repeated verbatim ever after.
  def test_tf511c_the_window_is_measured_from_the_moment_of_the_call
    request = Rack::Request.new(Rack::MockRequest.env_for('http://localhost/x'))

    early = PromptAtelier::Sessions.cookie_options(request, nil, now: Time.at(1_000_000))
    later = PromptAtelier::Sessions.cookie_options(request, nil, now: Time.at(1_086_400))

    assert_equal 86_400, later[:expires] - early[:expires]
  end

  # And it stops sliding the moment the session is over. A refreshed cookie
  # on a signed-out response would put the browser back to square one on the
  # next call.
  def test_tf511c_a_signed_out_call_is_not_given_a_fresh_cookie
    get "#{prefix}/auth/me"

    assert_equal 401, last_response.status
    assert_empty Array(last_response.headers['set-cookie']).reject(&:empty?)
  end

  # --- TF-512: token renewal (SEC-04) --------------------------------------

  def test_tf512_the_token_is_renewed_on_login_and_on_a_password_change
    first = log_in
    second = log_in
    refute_equal first, second, 'a new session on every login'

    change_password(current: GOOD_PASSWORD, replacement: OTHER_PASSWORD)
    assert_equal 200, last_response.status
  end

  # --- TF-513: dropping sessions -------------------------------------------

  def test_tf513_locking_an_account_invalidates_its_sessions_at_once
    log_in
    with_app_db { |db| db[:users].where(id: @user[:id]).update(status: 'locked') }

    get "#{prefix}/auth/me"
    assert_equal 401, last_response.status
  end

  def test_tf513b_after_logging_out_the_same_token_no_longer_works
    token = log_in
    post_with_csrf "#{prefix}/auth/logout"
    assert_equal 200, last_response.status

    # Server side, not merely the cookie in the browser.
    with_app_db do |db|
      assert_nil PromptAtelier::Sessions.authenticate(db, token)
    end

    set_cookie "#{PromptAtelier::Sessions::COOKIE_NAME}=#{token}"
    get "#{prefix}/auth/me"
    assert_equal 401, last_response.status
  end

  def test_tf513c_a_session_idle_for_fifteen_days_is_over
    token = log_in
    with_app_db do |db|
      db[:sessions].update(last_seen_at: Time.now - (15 * 86_400))
    end

    get "#{prefix}/auth/me"
    assert_equal 401, last_response.status
    with_app_db { |db| assert_equal 0, db[:sessions].count, 'and it is cleaned up' }
    refute_nil token
  end

  # The absolute limit exists because activity alone would keep a session
  # alive forever. Without this case its absence would surface after 90 days
  # of production use.
  def test_tf513d_a_session_older_than_ninety_days_is_over_despite_activity
    log_in
    with_app_db do |db|
      db[:sessions].update(last_seen_at: Time.now, expires_at: Time.now - 60)
    end

    get "#{prefix}/auth/me"
    assert_equal 401, last_response.status
  end

  # TF-410: locking an account drops its sessions at once, but its prompts
  # stay where they are. The visibility half belongs to AP-06; what can be
  # shown here is that locking destroys nothing but access.
  def test_tf410_locking_an_account_drops_its_sessions_but_keeps_its_prompts
    log_in
    prompt_id = with_app_db do |db|
      workspace = db[:workspaces].insert(name: 'Marketing', slug: 'marketing',
                                         created_at: Time.now, updated_at: Time.now)
      db[:prompts].insert(workspace_id: workspace, owner_id: @user[:id],
                          title: 'Geteilt', body: 'Text', visibility: 'workspace',
                          created_at: Time.now, updated_at: Time.now)
    end

    with_app_db { |db| db[:users].where(id: @user[:id]).update(status: 'locked') }

    get "#{prefix}/auth/me"
    assert_equal 401, last_response.status, 'access is gone immediately'

    with_app_db do |db|
      refute_nil db[:prompts][id: prompt_id], 'the prompt survives the lock'
      assert_equal @user[:id], db[:prompts][id: prompt_id][:owner_id]
    end
  end

  # --- TF-514: password change drops the other sessions (FA-105) -----------

  def test_tf514_changing_the_password_keeps_this_session_and_drops_the_others
    other_token = log_in   # a second browser
    this_token  = log_in   # the one we are sitting in

    with_app_db { |db| assert_equal 2, db[:sessions].count }

    change_password(current: GOOD_PASSWORD, replacement: OTHER_PASSWORD)
    assert_equal 200, last_response.status

    with_app_db do |db|
      assert_equal 1, db[:sessions].count
      refute_nil PromptAtelier::Sessions.authenticate(db, this_token), 'this one survives'
      assert_nil PromptAtelier::Sessions.authenticate(db, other_token), 'the other does not'
    end
  end

  # --- TF-515: write rate limit (SEC-19) -----------------------------------

  def test_tf515_writing_calls_are_limited_per_session
    log_in
    statuses = 125.times.map do
      post_with_csrf "#{prefix}/auth/password",
                     { current_password: 'falsch', new_password: 'egal' }
      last_response.status
    end

    assert_includes statuses, 429, 'the limit has to bite before 125 calls'
    assert_equal 429, statuses.last
  end

  # --- TF-519: no internals in an error (SEC-13) ---------------------------

  # SEC-13 has **two** halves, and only the first was checked here: nothing
  # internal reaches the caller. The second — that it reaches the **log** — was
  # not, and its side effect was a line in every green build log that read like
  # a failure and was nobody's evidence:
  #
  #     [2026-08-06T20:45:28+02:00] RuntimeError: geheimes internes Detail
  #
  # Asserted now, so the line is proof rather than noise, and its absence would
  # be a failure: an error that appears nowhere is an error nobody can chase.
  def test_tf519_an_error_reveals_no_paths_queries_or_stack_traces
    PromptAtelier::App.get('/boom-security') { raise 'geheimes internes Detail' }

    _, logged = capture_subprocess_io { get '/boom-security' }

    assert_equal 500, last_response.status
    body = last_response.body
    refute_includes body, 'geheimes internes Detail'
    refute_includes body, @dir
    refute_includes body, 'app.rb'

    assert_includes logged, 'geheimes internes Detail',
                    'the other half of SEC-13: it belongs in the log'
    assert_includes logged, 'RuntimeError', 'with the class, so it can be looked up'
  end

  # --- FA-909: first-run setup ---------------------------------------------

  def test_the_setup_endpoint_is_closed_once_an_account_exists
    get "#{prefix}/setup/status"
    refute JSON.parse(last_response.body)['setup_required']

    json_post "#{prefix}/setup", { name: 'Zweiter', email: 'z@example.test',
                                   password: GOOD_PASSWORD }
    assert_equal 409, last_response.status
  end

  def test_the_first_account_becomes_instance_admin_and_is_logged_in
    @dir = migrated_dir('setup')
    PromptAtelier::App.reset!
    PromptAtelier::App.boot!(root: @dir)
    clear_cookies

    get "#{prefix}/setup/status"
    assert JSON.parse(last_response.body)['setup_required']

    json_post "#{prefix}/setup", { name: 'Erste', email: 'erste@example.test',
                                   password: GOOD_PASSWORD }

    assert_equal 201, last_response.status
    assert JSON.parse(last_response.body).dig('user', 'is_instance_admin')
    refute_empty raw_session_cookie, 'the first admin is signed in straight away'
  end

  def test_the_setup_refuses_a_weak_password
    @dir = migrated_dir('setup_weak')
    PromptAtelier::App.reset!
    PromptAtelier::App.boot!(root: @dir)
    clear_cookies

    json_post "#{prefix}/setup", { name: 'Erste', email: 'erste@example.test', password: 'kurz' }
    assert_equal 422, last_response.status
    with_app_db { |db| assert_equal 0, db[:users].count, 'and no account was created' }
  end

  # --- malformed input ------------------------------------------------------

  # A JavaScript object literal is not JSON — single quotes, unquoted keys.
  # It is the shape someone gets when they paste an object into a REST client
  # or into "edit and resend" instead of stringifying it, and the generic
  # "input incomplete or wrong" sent them hunting for a missing field.
  def test_a_body_that_is_not_json_says_so
    dir = migrated_dir('malformed')
    PromptAtelier::App.reset!
    PromptAtelier::App.boot!(root: dir)
    clear_cookies

    post "#{prefix}/setup",
         "{name:'Jörg', email:'j@example.test', password:'#{GOOD_PASSWORD}'}",
         JSON_HEADERS

    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'malformed_json', body.dig('error', 'code')
    assert_equal 'malformed_json', body.dig('error', 'code')
  end

  # A JSON array is valid JSON but not a payload. Without the type check it
  # would reach the field access and fail as a 500 instead of a 400.
  def test_a_json_array_is_refused_as_a_payload
    post "#{prefix}/auth/login", '["anna", "geheim"]', JSON_HEADERS

    assert_equal 400, last_response.status
    assert_equal 'malformed_json', JSON.parse(last_response.body).dig('error', 'code')
  end

  # SEC-13 still holds: the message says what is wrong with the request, not
  # where the parser stopped or which file it happened in.
  def test_the_malformed_message_reveals_no_internals
    post "#{prefix}/auth/login", '{kaputt', JSON_HEADERS

    body = last_response.body
    refute_includes body, 'app.rb'
    refute_includes body, @dir
    refute_match(/line \d+|column \d+/, body)
  end

  # --- wrong method ---------------------------------------------------------

  # A GET on the login path used to answer 404, which reads as "wrong path"
  # when the path was right and only the verb was wrong.
  def test_a_known_path_with_the_wrong_method_answers_405_and_names_the_right_one
    get "#{prefix}/auth/login"

    assert_equal 405, last_response.status
    assert_equal 'POST', last_response.headers['allow']
    body = JSON.parse(last_response.body)
    assert_equal 'method_not_allowed', body.dig('error', 'code')
    assert_includes body.dig('error', 'params', 'allowed'), 'POST'
  end

  def test_an_unknown_path_still_answers_404
    get "#{prefix}/gibt-es-nicht"

    assert_equal 404, last_response.status
    assert_equal 'not_found', JSON.parse(last_response.body).dig('error', 'code')
    assert_nil last_response.headers['allow']
  end

  # 15.2 keeps 404 for a resource that exists but must not be seen. That rule
  # is about resources; this one is about routes, and which verbs a documented
  # endpoint accepts is public knowledge.
  def test_the_405_names_only_verbs_and_reveals_nothing_about_data
    delete "#{prefix}/auth/me"

    assert_equal 405, last_response.status
    # GET and PUT since FA-106 put the profile behind the same path. The
    # header names verbs and nothing else — that is what this case is about.
    assert_equal 'GET, PUT', last_response.headers['allow']
    refute_includes last_response.body, @dir
  end

  # --- audit (SEC-09) -------------------------------------------------------

  def test_a_successful_and_a_failed_login_are_both_recorded
    post "#{prefix}/auth/login", JSON.generate(email: 'anna@example.test', password: 'falsch12345')
    log_in

    with_app_db do |db|
      actions = db[:audit_logs].select_map(:action)
      assert_includes actions, PromptAtelier::Audit::LOGIN_FAILED
      assert_includes actions, PromptAtelier::Audit::LOGIN_SUCCEEDED

      failed = db[:audit_logs].where(action: PromptAtelier::Audit::LOGIN_FAILED).first
      refute_includes failed.to_s, 'falsch12345', 'never the password'
      refute_nil failed[:created_at]
    end
  end

  private

  def prefix = PromptAtelier::App::API_PREFIX

  # Rack::Test sends a bare string body as form data, and Rack then consumes
  # it while parsing params — request.body.read comes back empty. A real
  # client sends application/json, so the tests do too.
  JSON_HEADERS = { 'CONTENT_TYPE' => 'application/json' }.freeze

  def json_post(path, payload = {}, extra = {})
    post path, JSON.generate(payload), JSON_HEADERS.merge(extra)
  end

  def with_app_db(&block) = PromptAtelier::Database.open(database_path(@dir), &block)

  # Reboots the application against the same installation with SEC-14 turned
  # on. The setting is read at boot, so changing the file alone is not enough.
  def boot_with_force_https(trusted: [])
    PromptAtelier::App.reset!
    write_config(@dir, valid_config.merge(
                         'server' => valid_config['server'].merge('trusted_proxies' => trusted),
                         'security' => { 'force_https' => true }
                       ))
    PromptAtelier::App.boot!(root: @dir)
  end

  def create_user(email, password, admin: false)
    with_app_db do |db|
      now = Time.now
      id = db[:users].insert(
        email: email, name: 'Anna',
        password_hash: PromptAtelier::Password.create(password),
        is_instance_admin: admin, created_at: now, updated_at: now
      )
      db[:users][id: id]
    end
  end

  # A login while already signed in is a writing call on an existing session,
  # so it carries the CSRF token — that is deliberate, see the note on login
  # CSRF in enforce_csrf.
  def log_in(email = 'anna@example.test', password = GOOD_PASSWORD)
    header 'X-CSRF-Token', csrf_token if csrf_token
    json_post "#{prefix}/auth/login", { email: email, password: password }
    assert_equal 200, last_response.status, "login failed: #{last_response.body}"
    rack_mock_session.cookie_jar[PromptAtelier::Sessions::COOKIE_NAME]
  end

  def attempt(email, password)
    json_post "#{prefix}/auth/login", { email: email, password: password }
  end

  def csrf_token = rack_mock_session.cookie_jar[PromptAtelier::Sessions::CSRF_COOKIE_NAME]

  def post_with_csrf(path, payload = {})
    header 'X-CSRF-Token', csrf_token
    json_post path, payload
  end

  def change_password(current:, replacement:)
    post_with_csrf "#{prefix}/auth/password",
                   { current_password: current, new_password: replacement }
  end

  # Rack 3 hands back set-cookie as an Array; Rack 2 joined them with
  # newlines. Both shapes are flattened here so the assertion reads the same.
  def raw_session_cookie = raw_cookie(PromptAtelier::Sessions::COOKIE_NAME)
  def raw_csrf_cookie    = raw_cookie(PromptAtelier::Sessions::CSRF_COOKIE_NAME)

  def raw_cookie(name)
    raw = last_response.headers['set-cookie']
    lines = raw.is_a?(Array) ? raw : raw.to_s.split("\n")
    lines.find { |line| line.start_with?(name) }.to_s
  end

  # The point in time the browser reads out of the header, or nil when there
  # is none — which is what makes a cookie a session cookie.
  def cookie_expiry(raw)
    found = raw[/expires=([^;]+)/i]
    found && Time.parse(Regexp.last_match(1))
  end

  def median_duration(runs: 9)
    runs.times.map { Benchmark.realtime { yield } }.sort[runs / 2]
  end
end
