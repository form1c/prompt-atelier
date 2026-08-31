# frozen_string_literal: true

require_relative '../../test_helper'
require 'app'

# TF-715 / NFA-16 — a server error is traceable afterwards.
#
# **Measured against the requirement, two of its three fields were missing.**
# The log line said when and which class, and nothing else:
#
#     [2026-08-06T21:11:04+02:00] RuntimeError: something went wrong
#
# A report of "it failed at about eleven" could not be tied to that line at
# all. With several people working, `RuntimeError` at 11:04 is not enough to
# find the one — and there was no way to ask "which request was it?", because
# nothing gave a request a name. Nobody had noticed, because nobody had held
# NFA-16 against an actual line until this package.
#
# TF-519 is the mirror of these cases: it checks what must **not** reach the
# caller. Here it is what has to reach the log, plus the one token that
# deliberately travels both ways.
class LoggingTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  def app = PromptAtelier::App

  def setup
    super
    @dir = migrated_dir('logging')
    PromptAtelier::App.boot!(root: @dir)
    PromptAtelier::App.get('/boom-logging') { raise 'ein Fehler zur Ablage' }
  end

  def teardown
    PromptAtelier::App.reset!
    super
  end

  # --- the three fields NFA-16 names ----------------------------------------

  def test_the_line_carries_a_timestamp
    assert_match(/\A\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+\-Z]/, log_of { get '/boom-logging' })
  end

  def test_the_line_carries_the_request_identifier
    logged = log_of { get '/boom-logging' }
    answered = JSON.parse(last_response.body).dig('error', 'request_id')

    refute_nil answered, 'without it in the answer nobody can quote the identifier'
    assert_includes logged, "request=#{answered}",
                    'the log and the answer have to name the same request, or neither is any use'
  end

  # The account, when there is one. The whole point of the field: which of the
  # people working at the time ran into it.
  def test_the_line_carries_the_account_when_somebody_is_signed_in
    user_id = sign_in

    assert_includes log_of { get '/boom-logging' }, "user=#{user_id}"
  end

  # And says so plainly when there is none, rather than leaving the field out.
  # A line with a missing field reads like a line whose field was lost.
  def test_the_line_says_so_when_nobody_is_signed_in
    assert_includes log_of { get '/boom-logging' }, 'user=-'
  end

  # A class name alone rarely says which of forty endpoints it came from.
  def test_the_line_names_the_request_that_failed
    logged = log_of { get '/boom-logging' }

    assert_includes logged, 'GET /boom-logging'
    assert_includes logged, 'RuntimeError: ein Fehler zur Ablage'
  end

  # --- the identifier itself -------------------------------------------------

  # Every answer carries it, not only the failures. Somebody chasing a request
  # that was answered wrongly rather than not at all has nothing to quote
  # otherwise.
  def test_every_answer_carries_the_identifier
    get '/health'

    assert_match(/\A[0-9a-f]{16}\z/, last_response.headers['x-request-id'].to_s)
  end

  def test_two_requests_are_not_the_same_request
    get '/health'
    first = last_response.headers['x-request-id']
    get '/health'

    refute_equal first, last_response.headers['x-request-id']
  end

  # SEC-13 keeps paths, queries and stack frames out of the answer. The
  # identifier is none of those — it is a random token this request invented —
  # and this case states that the distinction is deliberate rather than an
  # oversight.
  def test_the_answer_carries_the_identifier_and_nothing_else_internal
    log_of { get '/boom-logging' }
    body = last_response.body

    refute_includes body, 'ein Fehler zur Ablage'
    refute_includes body, 'RuntimeError'
    refute_includes body, @dir
    assert_match(/\A[0-9a-f]{16}\z/, JSON.parse(body).dig('error', 'request_id').to_s)
  end

  # --- a supplied identifier -------------------------------------------------

  # A reverse proxy stamps its own, and taking it means its log line and ours
  # can be laid side by side. Only from a trusted proxy, though — the same rule
  # `X-Forwarded-For` follows (SEC-07).
  def test_a_trusted_proxy_may_name_the_request
    boot_with_trusted_proxy

    logged = log_of { get '/boom-logging', {}, { 'HTTP_X_REQUEST_ID' => 'vom-proxy-1234' } }

    assert_includes logged, 'request=vom-proxy-1234'
  end

  # The counter-case, and the one that matters: without it the check above
  # would pass just as well with the trust rule removed.
  def test_an_untrusted_caller_may_not_name_the_request
    logged = log_of { get '/boom-logging', {}, { 'HTTP_X_REQUEST_ID' => 'frei-erfunden-1234' } }

    refute_includes logged, 'frei-erfunden-1234',
                    'a header anybody may set is a header anybody may use to forge a trail'
    assert_match(/request=[0-9a-f]{16}/, logged)
  end

  # A header nobody checked would let a caller write newlines into the log and
  # forge lines that look like ours.
  def test_a_supplied_identifier_that_could_forge_a_line_is_discarded
    boot_with_trusted_proxy
    forged = "harmlos\n[2026-08-06T00:00:00+02:00] error request=x user=1 GET / Nothing: nothing"

    logged = log_of { get '/boom-logging', {}, { 'HTTP_X_REQUEST_ID' => forged } }

    refute_includes logged, 'Nothing: nothing'
    assert_match(/request=[0-9a-f]{16}/, logged)
  end

  private

  def log_of(&block)
    _, logged = capture_subprocess_io(&block)
    logged
  end

  def sign_in
    user = nil
    PromptAtelier::App.database.tap do |db|
      user = PromptAtelier::Accounts.create(db, name: 'Anna', email: 'anna@test',
                                                password: 'Ein-gutes-Kennwort-12')
    end
    post '/api/v1/auth/login', JSON.generate(email: 'anna@test', password: 'Ein-gutes-Kennwort-12'),
         { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 200, last_response.status
    user[:id]
  end

  # Rack::Test speaks from 127.0.0.1, so naming it makes this caller the proxy.
  def boot_with_trusted_proxy
    write_config(@dir, valid_config.merge(
                         'server' => { 'host' => '127.0.0.1', 'port' => 9292,
                                       'base_url' => 'http://localhost:9292',
                                       'trusted_proxies' => ['127.0.0.1'] }
                       ))
    PromptAtelier::App.reset!
    PromptAtelier::App.boot!(root: @dir)
    PromptAtelier::App.get('/boom-logging') { raise 'ein Fehler zur Ablage' }
  end
end
