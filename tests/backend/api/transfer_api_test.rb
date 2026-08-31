# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'app'

# Import and export over HTTP (FA-801 to FA-804, SEC-12).
#
# The rules themselves are checked in transfer_test.rb. What can only be
# checked here is what the endpoints decide: who may export what, that the size
# limit refuses a file **before** it is read, and that the preview is not
# something a client can skip.
class TransferApiTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  def app = PromptAtelier::App

  def setup
    super
    @dir = migrated_dir('transfer-api')
    PromptAtelier::App.boot!(root: @dir)
    PromptAtelier::RateLimit.reset!
    @ids = with_app_db { |db| PromptAtelier::Fixture.build(db) }
  end

  def teardown
    PromptAtelier::App.reset!
    PromptAtelier::RateLimit.reset!
    super
  end

  # --- TF-346 and the matrix over the wire ----------------------------------

  # `prompt.export` is ○ for a viewer, ◐ for an editor and ● above. The ◐ is
  # the interesting one: it is not a refusal but a **narrower answer**, and a
  # client cannot widen it by asking differently.
  def test_the_export_scope_follows_the_matrix_and_not_the_request
    sign_in(:lisa)
    csrf(:post, "#{prefix}/export", { workspace_id: marketing })
    assert_equal 403, last_response.status, 'a viewer exports nothing'

    sign_in(:martin)
    csrf(:post, "#{prefix}/export", { workspace_id: marketing })
    assert_equal 200, last_response.status
    titles = exported['prompts'].map { |entry| entry['title'] }
    assert_equal %w[P-DRAFT P-EDIT], titles.sort, 'an editor gets his own'

    sign_in(:sabine)
    csrf(:post, "#{prefix}/export", { workspace_id: marketing })
    assert_operator exported['prompts'].size, :>, 2, 'an owner gets the workspace'
  end

  def test_the_export_carries_the_format_marker_and_version
    sign_in(:sabine)
    csrf(:post, "#{prefix}/export", { workspace_id: marketing })

    assert_equal PromptAtelier::Transfer::FORMAT, exported['format']
    assert_equal PromptAtelier::Transfer::VERSION, exported['version']
    refute_nil exported['exported_at']
    assert_equal 'Marketing', exported.dig('workspace', 'name')
  end

  def test_markdown_comes_back_as_one_file_per_prompt
    sign_in(:sabine)
    csrf(:post, "#{prefix}/export", { workspace_id: marketing, format: 'markdown' })

    payload = JSON.parse(last_response.body)
    assert_equal 'markdown', payload['format']
    assert(payload['files'].all? { |file| file['name'].end_with?('.md') })
    assert(payload['files'].all? { |file| file['content'].start_with?('---') })
  end

  # --- SEC-12 and TF-344: the size limit ------------------------------------

  # "Ablehnung vor dem Einlesen". Checked on the declared length of the
  # request, so the 11 MB never become 11 MB of parsed objects — a limit that
  # only applies after parsing has already spent what it was meant to save.
  def test_tf344_a_file_over_ten_megabytes_is_refused_before_it_is_read
    sign_in(:sabine)
    oversized = JSON.generate({ workspace_id: marketing, content: 'x' * (11 * 1024 * 1024) })

    post "#{prefix}/import/preview", oversized,
         'CONTENT_TYPE' => 'application/json', 'HTTP_X_CSRF_TOKEN' => csrf_token.to_s

    assert_equal 413, last_response.status
    assert_equal 'file_too_large', JSON.parse(last_response.body).dig('error', 'code')
  end

  # The counter-check that the limit really applies **before** the body is
  # parsed, and not merely somewhere. The body is both oversized and broken
  # JSON: with the check in front the answer is "too large", without it the
  # parser gets there first and answers "malformed". Same status code either
  # way, so only the code tells the two apart — and a mutation probe walked
  # straight through the first version of this test.
  def test_tf344_the_limit_applies_before_the_body_is_parsed
    sign_in(:sabine)
    broken_and_oversized = "{ \"workspace_id\": #{marketing}, \"content\": \"#{'x' * (11 * 1024 * 1024)}"

    post "#{prefix}/import/preview", broken_and_oversized,
         'CONTENT_TYPE' => 'application/json', 'HTTP_X_CSRF_TOKEN' => csrf_token.to_s

    assert_equal 'file_too_large', JSON.parse(last_response.body).dig('error', 'code'),
                 'the size is checked before the JSON is read'
  end

  # --- FA-802: no writing without a preview ---------------------------------

  def test_the_preview_writes_nothing
    sign_in(:sabine)
    before = with_app_db { |db| db[:prompts].where(workspace_id: marketing).count }

    csrf(:post, "#{prefix}/import/preview", { workspace_id: marketing, content: JSON.generate(package) })

    assert_equal 200, last_response.status
    assert_equal 1, JSON.parse(last_response.body).dig('preview', 'new_count')
    assert_equal before, with_app_db { |db| db[:prompts].where(workspace_id: marketing).count }
  end

  # Importing is ● for admin and owner and ○ for everybody else — an editor
  # may create prompts one at a time and not pour a file into the workspace.
  def test_importing_follows_the_matrix
    { lisa: 403, martin: 403, anna: 200, sabine: 200 }.each do |person, expected|
      sign_in(person)
      csrf(:post, "#{prefix}/import", { workspace_id: marketing, content: JSON.generate(package) })

      assert_equal expected, last_response.status, "#{person} importing"
    end
  end

  def test_a_damaged_file_is_refused_with_a_reason_and_a_code
    sign_in(:sabine)
    csrf(:post, "#{prefix}/import", { workspace_id: marketing, content: '{ "format": ' })

    assert_equal 422, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'file_malformed_json', body.dig('error', 'code')
    refute_empty body.dig('error', 'code')
  end

  # The layer between the screen and the service. Removing `keyword_decisions:`
  # from the endpoint leaves every service test green, because the service is
  # then simply called with its default — and the choice the user made in the
  # browser is silently dropped on the way.
  # TF-347d over HTTP
  def test_the_endpoint_carries_the_keyword_decision_through
    sign_in(:sabine)
    with_app_db do |db|
      PromptAtelier::Catalog.create_keyword(db, marketing, {
        'name' => 'formal', 'text' => 'Schreibe sachlich.',
        'position' => 'append', 'sort_order' => 10
      })
    end

    csrf(:post, "#{prefix}/import",
         { workspace_id: marketing, content: JSON.generate(keyword_package('Sei knapp.')),
           keyword_decisions: { '0' => 'overwrite' } })

    assert_equal 200, last_response.status
    assert_equal ['formal'], JSON.parse(last_response.body).dig('report', 'keywords_overwritten')
    assert_equal 'Sei knapp.',
                 with_app_db { |db| db[:keywords][workspace_id: marketing, name: 'formal'][:text] }
  end

  # Without a decision the existing definition stands, and the report says so
  # rather than leaving the caller to assume it was taken over.
  # TF-347c over HTTP
  def test_without_a_decision_the_endpoint_skips_and_says_so
    sign_in(:sabine)
    with_app_db do |db|
      PromptAtelier::Catalog.create_keyword(db, marketing, {
        'name' => 'formal', 'text' => 'Schreibe sachlich.',
        'position' => 'append', 'sort_order' => 10
      })
    end

    csrf(:post, "#{prefix}/import",
         { workspace_id: marketing, content: JSON.generate(keyword_package('Sei knapp.')) })

    assert_equal ['formal'], JSON.parse(last_response.body).dig('report', 'keywords_skipped')
    assert_equal 'Schreibe sachlich.',
                 with_app_db { |db| db[:keywords][workspace_id: marketing, name: 'formal'][:text] }
  end

  def test_an_import_is_recorded_in_the_audit_log
    sign_in(:sabine)
    with_app_db { |db| db[:audit_logs].delete }
    csrf(:post, "#{prefix}/import", { workspace_id: marketing, content: JSON.generate(package) })

    entry = with_app_db { |db| db[:audit_logs].first(action: 'import.completed') }
    refute_nil entry, 'SEC-09 names the import by name'
    assert_equal 1, JSON.parse(entry[:meta_json])['created']
  end

  # --- TF-516: the transfer rate limit (SEC-19) -----------------------------

  # **This case was in the register and had never been written**, and the
  # limit it describes had never been built. `RateLimit.exports_exceeded?`
  # stood in the source, complete, with its own constant — and was called from
  # nowhere. Measured before the fix: eight exports in a row, eight times 200.
  #
  # That is the shape worth remembering. A missing feature usually shows up as
  # a missing function; this one had the function, so every reading of the code
  # said the limit was there.
  def test_tf516_the_sixth_export_in_a_minute_is_refused
    sign_in(:sabine)

    statuses = 6.times.map do
      csrf(:post, "#{prefix}/export", { workspace_id: marketing })
      last_response.status
    end

    assert_equal [200, 200, 200, 200, 200, 429], statuses,
                 'SEC-19 allows five per minute and user'
  end

  # The counter-check to the case above, and the reason the counter is keyed by
  # user rather than by session: the write limit of 120 hangs on the session,
  # so signing in twice doubles it. Whoever signs in again must not get five
  # more exports.
  def test_tf516_the_limit_follows_the_person_not_the_session
    sign_in(:sabine)
    5.times { csrf(:post, "#{prefix}/export", { workspace_id: marketing }) }

    sign_in(:sabine)
    csrf(:post, "#{prefix}/export", { workspace_id: marketing })

    assert_equal 429, last_response.status, 'a second sign-in is not a fresh allowance'
  end

  # Importing shares the allowance — SEC-19 names both in one breath, and an
  # import is the more expensive of the two. Without this case the regular
  # expression could lose its import branch and the case above would stay green.
  def test_tf516_importing_shares_the_same_allowance
    sign_in(:sabine)
    5.times { csrf(:post, "#{prefix}/export", { workspace_id: marketing }) }

    csrf(:post, "#{prefix}/import", { workspace_id: marketing, content: JSON.generate(package) })

    assert_equal 429, last_response.status
  end

  # And the preview is **not** in the allowance. 15.3 defines it as the call
  # that writes nothing, and W-8 demands one before every import — counted, it
  # would leave two and a half imports a minute and make the prescribed way of
  # working the thing that trips the limit. Found by running the browser suite:
  # four cases went red with the preview counted.
  def test_tf516_the_preview_does_not_use_up_the_allowance
    sign_in(:sabine)
    8.times do
      csrf(:post, "#{prefix}/import/preview", { workspace_id: marketing, content: JSON.generate(package) })
    end

    assert_equal 200, last_response.status, 'a preview writes nothing and costs nothing'

    csrf(:post, "#{prefix}/import", { workspace_id: marketing, content: JSON.generate(package) })

    refute_equal 429, last_response.status, 'the import after them must still go through'
  end

  # The self-disclosure of SEC-18 is a `GET`, so the write limit never saw it
  # at all — it was the one transfer of the three with no ceiling whatsoever.
  def test_tf516_the_self_disclosure_is_covered_too
    sign_in(:sabine)
    statuses = 6.times.map do
      get "#{prefix}/auth/me/data-export"
      last_response.status
    end

    assert_equal 429, statuses.last, 'a GET is still a whole-account export'
  end

  # And the counter-check that keeps all four honest: an ordinary call is not
  # caught by the transfer limit. Without it a pattern matching everything
  # would satisfy every case above and break the whole application.
  def test_tf516_ordinary_calls_are_not_caught_by_the_transfer_limit
    sign_in(:sabine)
    statuses = 8.times.map do
      get "#{prefix}/workspaces"
      last_response.status
    end

    assert_equal [200] * 8, statuses, 'only the transfers are limited'
  end

  # --- the shipped example package as a test bed ----------------------------

  # 51 prompts somebody actually wrote, through the importer that will read
  # them in a real installation. Invented files cover what one thought of;
  # this one covers what is really in the box (TF-448, TF-449).
  def test_the_shipped_example_package_imports_as_it_stands
    sign_in(:sabine)
    content = File.read(File.join(CODE_ROOT, 'examples', 'examples.json'))

    csrf(:post, "#{prefix}/import", { workspace_id: marketing, content: content })
    assert_equal 200, last_response.status, last_response.body

    report = JSON.parse(last_response.body)['report']
    # Counted out of the package, not written down here: an example added to
    # the delivery must not read as a broken importer (AP-23 added four).
    assert_equal JSON.parse(content)['prompts'].size, report['created'].size
    assert_empty report['keywords_missing'], 'the package defines every keyword it uses'
    assert_empty report['unknown_fields'], 'and carries no field the format does not know'
  end

  private

  def prefix = PromptAtelier::App::API_PREFIX
  def marketing = @ids[:workspaces][:marketing]
  def with_app_db(&block) = PromptAtelier::Database.open(database_path(@dir), &block)
  def exported = JSON.parse(last_response.body)['package']

  def package
    {
      'format' => PromptAtelier::Transfer::FORMAT, 'version' => 1,
      'prompts' => [{ 'title' => 'Aus einer Datei', 'body' => 'Ein Text.' }]
    }
  end

  # A file of keywords alone, which a workspace holding no prompts exports to.
  def keyword_package(text)
    {
      'format' => PromptAtelier::Transfer::FORMAT, 'version' => 2, 'prompts' => [],
      'keywords' => [{ 'name' => 'formal', 'text' => text,
                       'position' => 'append', 'sort_order' => 10 }]
    }
  end

  def sign_in(person)
    clear_cookies
    post "#{prefix}/auth/login",
         JSON.generate(email: PromptAtelier::Fixture::PEOPLE[person][:email],
                       password: PromptAtelier::Fixture::PASSWORD),
         'CONTENT_TYPE' => 'application/json'
    assert_equal 200, last_response.status, "could not sign in as #{person}"
  end

  def csrf_token = rack_mock_session.cookie_jar[PromptAtelier::Sessions::CSRF_COOKIE_NAME]

  def csrf(method, path, payload = nil)
    send(method, path, payload.nil? ? '' : JSON.generate(payload),
         'CONTENT_TYPE' => 'application/json', 'HTTP_X_CSRF_TOKEN' => csrf_token.to_s)
  end
end
