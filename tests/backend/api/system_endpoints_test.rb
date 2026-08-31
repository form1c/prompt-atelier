# frozen_string_literal: true

require_relative '../../test_helper'
require 'app'

# TF-643 and TF-643b: the two operational endpoints from Requirements 15.3.
#
# Exercised through Rack::Test rather than a real server, so they run fast and
# without a free port. That the endpoints also answer over a *started* Puma is
# proven separately by StartupTest, which is the point of TF-645b to TF-645d.
class SystemEndpointsTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  def app
    PromptAtelier::App
  end

  # A migrated database, because /health checks it since AP-02 — booting
  # against an empty directory would now fail the start lock, which is the
  # intended behaviour and belongs in schema_guard_test.rb.
  def setup
    super
    @dir = migrated_dir('endpoints')
    PromptAtelier::App.boot!(root: @dir)
  end

  def teardown
    PromptAtelier::App.reset!
    super
  end

  # --- TF-643 -------------------------------------------------------------

  def test_tf643_health_answers_200_with_status_ok
    get '/health'

    assert_equal 200, last_response.status
    assert_equal 'application/json', last_response.content_type.split(';').first
    assert_equal({ 'status' => 'ok' }, JSON.parse(last_response.body))
  end

  # The endpoint is reachable from outside as soon as the application runs.
  # Anything beyond the bare state would be an information leak (15.3).
  def test_tf643_health_reveals_no_internals
    get '/health'

    body = JSON.parse(last_response.body)
    assert_equal %w[status], body.keys
    refute_match(/#{Regexp.escape(@dir)}/, last_response.body,
                 'no paths in the response')
  end

  def test_tf643_health_needs_no_authentication
    get '/health'

    assert_equal 200, last_response.status
  end

  # --- TF-643b ------------------------------------------------------------

  def test_tf643b_version_without_authentication_is_401
    get '/version'

    assert_equal 401, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'unauthorized', body.dig('error', 'code')
  end

  # The version string helps an attacker pick matching exploits, so it must
  # not leak through the error path either.
  def test_tf643b_the_401_does_not_contain_the_version
    get '/version'

    refute_includes last_response.body, PromptAtelier::VERSION
  end

  # --- Error format (15.2) ------------------------------------------------

  def test_unknown_route_answers_404_in_the_documented_error_format
    get '/does-not-exist'

    assert_equal 404, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'not_found', body.dig('error', 'code')
    refute_empty body.dig('error', 'code').to_s
  end

  # SEC-13: no stack traces, no paths. Sinatra would happily render both in
  # development mode, which is exactly why show_exceptions is off.
  def test_server_errors_reveal_neither_stack_trace_nor_paths
    PromptAtelier::App.get('/boom') { raise 'internal detail that must not leak' }

    _, logged = capture_subprocess_io { get '/boom' }

    assert_equal 500, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'server_error', body.dig('error', 'code')
    refute_includes last_response.body, 'internal detail'
    refute_includes last_response.body, __FILE__
    # The other half of SEC-13 (see the same case in `security_test`): what the
    # caller must not see, the operator must. Asserted, so the line this
    # produces is evidence instead of noise in a green build log.
    assert_includes logged, 'internal detail that must not leak'
  end
end
