# frozen_string_literal: true

require_relative '../../test_helper'
require 'app'

# The application shell, served by the application (E-02, 18.8).
#
# **This whole file exists because of a finding, and the finding was made by
# installing the built archive and opening it.** `set :static` answers
# `/assets/…` and `/logo.svg`, but Sinatra does not serve an index file for
# `/`, and it knows nothing of client-side routes. A delivered instance replied
# to `GET /` with the JSON 404 of an API, and a reload on `/prompts/5` did the
# same — the application was reachable and had no user interface.
#
# Every automated test was green. The browser tests ran behind a piece of Rack
# in their own harness that did this job, and its comment claimed the backend
# did it (test concept 3.4, rule 1: a stand-in that is kinder than reality
# tests a fiction). That harness is gone; the browser tests now go through the
# code below.
class InterfaceTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  def app = PromptAtelier::App

  # What a browser sends when it loads a page. It is also the condition the
  # fallback turns on: a program that fetches `/Gemfile` names no media type
  # or sends `*/*`, and gets the answer an API gives (TF-518).
  BROWSER = { 'HTTP_ACCEPT' => 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' }.freeze

  def setup
    super
    @dir = migrated_dir('interface')
    @interface = File.join(@dir, 'public')
    FileUtils.mkdir_p(File.join(@interface, 'assets'))
    File.write(File.join(@interface, 'index.html'), '<!doctype html><title>Prompt Atelier</title>')
    File.write(File.join(@interface, 'assets', 'index-abc.js'), 'console.log(1)')

    PromptAtelier::App.boot!(root: @dir, interface_root: @interface)
  end

  def teardown
    PromptAtelier::App.reset!
    super
  end

  # --- what a browser asks for ----------------------------------------------

  def test_the_root_address_answers_with_the_interface
    get '/', {}, BROWSER

    assert_equal 200, last_response.status
    assert_equal 'text/html', last_response.content_type.split(';').first
    assert_includes last_response.body, '<!doctype html>'
  end

  # A deep link typed into the address bar, or a reload on a screen somebody is
  # already looking at, has to arrive at the same page as a click does. This is
  # the case a single page application lives or dies by.
  def test_a_client_side_route_arrives_at_the_same_page
    get '/prompts/5', {}, BROWSER

    assert_equal 200, last_response.status
    assert_includes last_response.body, '<!doctype html>'
  end

  def test_a_file_of_the_build_is_still_served_as_itself
    get '/assets/index-abc.js'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'console.log'
  end

  # --- and what must stay an API --------------------------------------------

  # The fallback stops at the API. A wrong path below it is a mistake in a
  # program, and a page in reply would hide it behind a 200.
  def test_an_unknown_api_path_still_answers_in_the_error_format
    get '/api/v1/does-not-exist'

    assert_equal 404, last_response.status
    assert_equal 'not_found', JSON.parse(last_response.body).dig('error', 'code')
  end

  def test_the_operational_endpoints_are_untouched
    get '/health'

    assert_equal 200, last_response.status
    assert_equal({ 'status' => 'ok' }, JSON.parse(last_response.body))
  end

  # A missing `/assets/index-abc.js` has to stay a 404. Answering it with the
  # shell hands the browser HTML where it expects JavaScript, and the page then
  # fails with a syntax error pointing at `<!doctype` — three steps away from
  # the real cause, which is a file that was not built.
  def test_a_missing_file_of_the_build_stays_a_missing_file
    get '/assets/index-gone.js', {}, BROWSER

    assert_equal 404, last_response.status
    refute_includes last_response.body, '<!doctype'
  end

  # Only navigation. A POST to a path that does not exist is a program's
  # mistake, not a person's.
  def test_only_get_and_head_reach_the_shell
    post '/prompts/5', {}, BROWSER

    assert_equal 404, last_response.status
    refute_includes last_response.body, '<!doctype'
  end

  # The 405 of AP-06 survives: a documented path with the wrong verb still says
  # which verbs it takes, rather than being swallowed by the catch-all.
  def test_a_wrong_method_on_a_real_endpoint_still_answers_405
    get "#{PromptAtelier::App::API_PREFIX}/auth/login"

    assert_equal 405, last_response.status
    assert_includes last_response.headers['allow'].to_s, 'POST'
  end

  # SEC-06: a hidden object answers 404 so that a stranger cannot tell it from
  # a missing one. That 404 must not turn into a page either.
  def test_a_concealing_404_is_not_replaced_by_a_page
    get "#{PromptAtelier::App::API_PREFIX}/prompts/999999"

    assert_includes [401, 404], last_response.status
    refute_includes last_response.body, '<!doctype'
  end

  # The condition that keeps TF-518 intact. `/Gemfile` carries no extension and
  # is not an API path, so only the missing `text/html` separates a browser
  # showing "not found" inside the application from a script being handed a
  # page where it asked for a file.
  def test_a_client_that_does_not_ask_for_html_gets_the_answer_of_an_api
    get '/Gemfile'

    assert_equal 404, last_response.status
    assert_equal 'not_found', JSON.parse(last_response.body).dig('error', 'code')

    get '/Gemfile', {}, BROWSER

    assert_equal 200, last_response.status
    assert_includes last_response.body, '<!doctype', 'and it is the shell, never the file'
    refute_includes last_response.body, 'sinatra'
  end

  # --- the development tree --------------------------------------------------

  # Before the first build there is no shell, and in development Vite serves
  # the interface anyway. The API then answers as it always did instead of
  # failing on a missing file.
  def test_without_a_built_interface_the_api_answers_as_before
    FileUtils.rm_f(File.join(@interface, 'index.html'))

    get '/', {}, BROWSER

    assert_equal 404, last_response.status
    assert_equal 'not_found', JSON.parse(last_response.body).dig('error', 'code')
  end
end
