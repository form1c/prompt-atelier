# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'app'

# AP-08: the library endpoint, tags and keywords.
#
# TF-310 to TF-322 are repeated here against the real endpoint, as the plan
# foresees. The unit tests in search_test.rb prove the rule; these prove that
# the endpoint applies it — and, more importantly, that it applies the
# visibility rule with it. A search that ignored SEC-06 would be a way round
# every permission the previous packages established (FA-502).
class LibraryTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  def app = PromptAtelier::App

  def setup
    super
    @dir = migrated_dir('library')
    PromptAtelier::App.boot!(root: @dir)
    PromptAtelier::RateLimit.reset!
    @ids = with_app_db do |db|
      ids = PromptAtelier::Fixture.build(db)
      seed_library(db, ids)
      ids
    end
  end

  def teardown
    PromptAtelier::App.reset!
    PromptAtelier::RateLimit.reset!
    super
  end

  # --- TF-310 to TF-317 against the endpoint --------------------------------

  def test_tf310_and_tf311_a_prefix_finds_the_word_it_starts_whatever_the_case
    sign_in(:sabine)

    # The fixture prompts of 4.3 carry "Blogartikel" in their body too, so
    # this asserts what must be found rather than an exact set — pinning the
    # set would break every time a fixture gains a word.
    %w[blog Blog BLOG].each do |term|
      found = titles_for(term)
      assert_includes found, "Blogartikel-Generator", term
      assert_includes found, "Blog-Beitrag Artikel", term
    end
    assert_equal titles_for("blog"), titles_for("BLOG"), "case is ignored"
  end

  def test_tf312_and_tf313_the_normalisation_reaches_the_endpoint
    sign_in(:sabine)

    %w[fur fuer für Grosse Groesse Größe Ubung Uebung Übung].each do |term|
      refute_empty titles_for(term), "#{term} must find the umlaut prompt"
    end
  end

  # The case the whole normalisation exists for, over HTTP this time.
  def test_tf313_grosse_finds_groesse_through_the_api
    sign_in(:sabine)

    assert_includes titles_for('Grosse'), 'Maßangaben'
    assert_includes titles_for('Grosse'), 'Massangaben'
  end

  def test_tf314_two_words_are_and_connected
    sign_in(:sabine)

    assert_equal ['Blog-Beitrag Artikel'], titles_for('blog artikel')
  end

  def test_tf315_a_tag_name_is_searchable
    sign_in(:sabine)

    assert_includes titles_for('seo'), 'Blogartikel-Generator'
  end

  # TF-316 and TF-419: query syntax is text, and it never produces an error.
  def test_tf316_special_characters_never_produce_an_error
    sign_in(:sabine)

    ['"* OR 1=1', 'NEAR(a b)', '((((', "O'Brien", '***', 'DROP TABLE prompts;--',
     '<script>alert(1)</script>', '%_%'].each do |term|
      get "#{prefix}/prompts?workspace_id=#{marketing}&q=#{CGI.escape(term)}"

      assert_equal 200, last_response.status, "#{term.inspect} produced #{last_response.status}"
    end

    with_app_db { |db| refute_equal 0, db[:prompts].count, 'and nothing was destroyed' }
  end

  def test_tf317_a_term_that_matches_nothing_returns_an_empty_list
    sign_in(:sabine)

    assert_empty titles_for('xyzniemals')
  end

  # A term with no searchable word must not empty the library either.
  def test_a_term_of_punctuation_alone_lists_everything
    sign_in(:sabine)

    refute_empty titles_for('***')
  end

  # --- TF-320: tag filtering is AND ----------------------------------------

  def test_tf320_filtering_by_two_tags_requires_both
    sign_in(:sabine)
    seo, content = tag_ids('seo', 'content')

    assert_includes titles_with_tags([seo]), 'Blogartikel-Generator'
    assert_includes titles_with_tags([content]), 'Blog-Beitrag Artikel'
    assert_equal ['Blogartikel-Generator'], titles_with_tags([seo, content]),
                 'both tags, not either'
  end

  # --- FA-502: the search is no way round the visibility --------------------

  # TF-203 over the wire. P-PRIV-S carries a string that occurs nowhere else,
  # which is the only way to tell a correct empty result from an accidental one.
  def test_the_search_never_reveals_a_foreign_private_prompt
    { sabine: 1, martin: 0, anna: 0, joerg: 0, thomas: 0 }.each do |person, expected|
      sign_in(person)
      get "#{prefix}/prompts?workspace_id=all&q=Zitronenfalter-Geheimnis"

      assert_equal expected, JSON.parse(last_response.body)['prompts'].size,
                   "#{person} searching for the private content"
    end
  end

  def test_the_search_does_not_return_prompts_from_the_trash
    sign_in(:sabine)
    get "#{prefix}/prompts?workspace_id=#{marketing}&q=P-DEL"

    assert_empty JSON.parse(last_response.body)['prompts']
  end

  # --- FA-509: the cross-workspace view -------------------------------------

  def test_workspace_id_all_shows_instance_wide_prompts_of_foreign_workspaces
    sign_in(:joerg)
    get "#{prefix}/prompts?workspace_id=all"

    ids = JSON.parse(last_response.body)['prompts'].map { |p| p['id'] }
    assert_includes ids, prompt('P-INST'), 'instance-wide is what this view is for'
    refute_includes ids, prompt('P-WS'),     'workspace-visible stays inside'
    refute_includes ids, prompt('P-PRIV-S'), 'private stays private'
    refute_includes ids, prompt('P-EDIT')
    refute_includes ids, prompt('P-ARCH')
  end

  def test_workspace_id_all_still_shows_ones_own_private_prompts
    sign_in(:joerg)
    get "#{prefix}/prompts?workspace_id=all"

    assert_includes JSON.parse(last_response.body)['prompts'].map { |p| p['id'] }, prompt('P-JOERG')
  end

  def test_a_missing_workspace_parameter_is_refused
    sign_in(:sabine)
    get "#{prefix}/prompts"

    assert_equal 422, last_response.status
  end

  # `all` is the only value that skips the workspace permission, and it does so
  # because there is no single workspace to ask about. Naming a workspace the
  # caller has nothing to do with must still be refused — otherwise every
  # listing would quietly become the cross-workspace view.
  def test_naming_a_foreign_workspace_is_still_refused
    sign_in(:joerg)
    get "#{prefix}/prompts?workspace_id=#{marketing}"

    assert_equal 404, last_response.status
  end

  # FA-205 through this endpoint: without an explicit filter the library
  # leaves archived prompts out. The filter test above only proves the
  # opposite direction.
  def test_archived_prompts_stay_out_of_the_unfiltered_library
    sign_in(:sabine)
    get "#{prefix}/prompts?workspace_id=#{marketing}"

    ids = JSON.parse(last_response.body)['prompts'].map { |p| p['id'] }
    refute_includes ids, prompt('P-ARCH')
    assert_includes ids, prompt('P-WS'), 'and the rest is there'
  end

  # --- FA-506, FA-507: filters, sorting, paging -----------------------------

  def test_favorites_only_narrows_the_list_to_the_callers_own_favourites
    sign_in(:martin)
    csrf(:post, "#{prefix}/prompts/#{prompt('P-WS')}/favorite")

    get "#{prefix}/prompts?workspace_id=#{marketing}&favorites_only=true"
    assert_equal [prompt('P-WS')], JSON.parse(last_response.body)['prompts'].map { |p| p['id'] }

    sign_in(:sabine)
    get "#{prefix}/prompts?workspace_id=#{marketing}&favorites_only=true"
    assert_empty JSON.parse(last_response.body)['prompts'], 'favourites belong to the person'
  end

  def test_filtering_by_visibility_and_status
    sign_in(:sabine)

    get "#{prefix}/prompts?workspace_id=#{marketing}&visibility=instance"
    assert_equal [prompt('P-INST')], JSON.parse(last_response.body)['prompts'].map { |p| p['id'] }

    get "#{prefix}/prompts?workspace_id=#{marketing}&status=archived"
    assert_equal [prompt('P-ARCH')], JSON.parse(last_response.body)['prompts'].map { |p| p['id'] }
  end

  # FA-507. The yardstick used to be `titles.sort_by(&:downcase)` — Ruby's
  # byte order with the capitals folded, which is exactly the rule this sort
  # replaced in AP-23. It would now demand "Massangaben" before "Maßangaben",
  # because `ß` has the higher code point, and that is not an order anybody
  # means. So the claims are written out instead of computed.
  def test_sorting_by_title_is_alphabetical_and_folds_case_and_umlauts
    sign_in(:sabine)
    get "#{prefix}/prompts?workspace_id=#{marketing}&sort=title"

    titles = JSON.parse(last_response.body)['prompts'].map { |p| p['title'] }
    at = ->(title) { titles.index(title) or flunk("#{title} is not in the list") }

    assert_operator at['Blog-Beitrag Artikel'], :<, at['Blogartikel-Generator']
    assert_operator at['Blogartikel-Generator'], :<, at['Maßangaben']
    assert_operator at['Massangaben'], :<, at['P-EDIT'], 'and case does not decide'

    # `ß` counts as `ss` (DIN 5007), so the two spellings share one sort key
    # and stand next to each other — whichever way the tie-breaker falls.
    assert_equal 1, (at['Maßangaben'] - at['Massangaben']).abs,
                 'two spellings of one word do not belong apart'
  end

  def test_paging_reports_the_total_and_returns_one_page
    sign_in(:sabine)
    get "#{prefix}/prompts?workspace_id=#{marketing}&per_page=2&page=1"

    body = JSON.parse(last_response.body)
    assert_equal 2, body['prompts'].size
    assert_operator body['meta']['total'], :>, 2, 'the total describes the whole result, not the page'
    assert_equal 1, body['meta']['page']

    get "#{prefix}/prompts?workspace_id=#{marketing}&per_page=2&page=2"
    second = JSON.parse(last_response.body)['prompts'].map { |p| p['id'] }
    refute_equal body['prompts'].map { |p| p['id'] }, second, 'page two is a different page'
  end

  # --- what a line in the library needs (11.3, AP-10) -----------------------

  # Every field 11.3 puts on a line, from one call. Fetching them per row
  # afterwards would be four more requests per prompt and would put the
  # 200 ms of NFA-02 out of reach before the first user arrives.
  def test_a_line_carries_tags_author_and_the_number_of_variables
    sign_in(:sabine)

    row = row_for('Blogartikel-Generator')

    assert_equal %w[content seo], row['tags'].sort
    assert_equal 'Sabine', row['owner_name']
    assert_equal 2, row['variable_count'], 'thema and zielgruppe'
    assert_equal 'Marketing', row['workspace_name']
    assert_equal false, row['workspace_is_personal']
  end

  # The flag beside the name, and why it has to travel with it.
  #
  # A personal workspace keeps a German name in the database — `Workspaces`
  # writes `Persönlich-<Name>` when an account is made — and the interface
  # shows a translated label for it instead (AP-19). With only the name on the
  # row, the library printed `Persönlich-Martin` under a switcher reading
  # "Personal workspace": one workspace, two names, and nothing to say they
  # are the same place. The browser cannot work the flag out for itself.
  def test_a_line_says_whether_it_came_from_a_personal_workspace
    sign_in(:joerg)

    personal = with_app_db { |db| db[:workspaces].first(is_personal: true, name: 'Persönlich-Jörg') }
    refute_nil personal, 'the fixture has to have a personal workspace, or this proves nothing'

    row = row_for('P-JOERG', query: "workspace_id=#{personal[:id]}")

    assert_equal personal[:name], row['workspace_name'], 'the stored name is untouched'
    assert_equal true, row['workspace_is_personal'], 'and the flag says what it is'
  end

  # The counter-check: a prompt without any of them says so with empty values
  # rather than leaving the fields out. A line that has to tell "no tags" from
  # "field missing" would decide it in the interface, and differently in each
  # place that asks.
  def test_a_line_without_tags_or_variables_still_carries_the_fields
    sign_in(:sabine)

    row = row_for('Blog-Beitrag Artikel')

    assert_equal ['content'], row['tags']
    assert_equal 0, row['variable_count']
    refute_nil row['owner_name']
  end

  # FA-505: the star belongs to the person looking, not to the prompt.
  def test_the_favourite_mark_is_per_person
    sign_in(:sabine)
    csrf(:post, "#{prefix}/prompts/#{prompt('Blogartikel-Generator')}/favorite")

    assert_equal 200, last_response.status
    assert row_for('Blogartikel-Generator')['favorite']

    sign_in(:martin)

    refute row_for('Blogartikel-Generator')['favorite'],
           'a favourite of one person must not appear as one for another'
  end

  # 15.1: ISO 8601 with a time zone. Ruby renders a Time as
  # "2026-08-02 10:52:30 +0200" by default — a space instead of the T and no
  # colon in the offset. Chrome parses that, Safari returns Invalid Date, and
  # the library would show a date in one browser and nothing in the other
  # (NFA-10, TF-427).
  def test_timestamps_are_iso8601_with_a_time_zone
    sign_in(:sabine)

    stamp = row_for('Blogartikel-Generator')['updated_at']

    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:[+-]\d{2}:\d{2}|Z)\z/, stamp)
    assert_in_delta Time.now, Time.iso8601(stamp), 120
  end

  # The rule holds wherever a time leaves the application, not only in the
  # library. Without this the next endpoint would be free to answer in Ruby's
  # own rendering again.
  def test_the_rule_holds_for_every_answer_that_carries_a_time
    sign_in(:sabine)

    get "#{prefix}/prompts/#{prompt('Blogartikel-Generator')}"
    detail = JSON.parse(last_response.body)['prompt']

    assert_match(/T\d{2}:\d{2}:\d{2}/, detail['updated_at'])

    csrf(:delete, "#{prefix}/prompts/#{prompt('Blog-Beitrag Artikel')}")
    get "#{prefix}/trash?workspace_id=#{marketing}"
    trashed = JSON.parse(last_response.body)['prompts'].first

    assert_match(/T\d{2}:\d{2}:\d{2}/, trashed['deleted_at'])
  end

  # --- the found place is marked (FA-501) -----------------------------------

  # The acceptance criterion of FA-501 says the hits appear with the found
  # place marked. The function for it has existed since AP-04 — and was called
  # from nowhere until AP-10, which is why nothing noticed.
  def test_a_hit_names_where_the_term_was_found
    sign_in(:sabine)

    row = row_for('Blogartikel-Generator', query: "workspace_id=#{marketing}&q=blog")

    # Whole words, in the original text: "Blogartikel" from position 0.
    assert_equal [[0, 11]], row['highlights']['title']
  end

  # The reason the ranges come from the server: the rule for what counts as a
  # match is the normalisation of FA-501. A browser comparing on its own would
  # mark something else than was found — and this is the case it would get
  # wrong.
  def test_the_marking_follows_the_normalisation_and_not_the_letters
    sign_in(:sabine)

    # Different letters, same word after the normalisation of FA-501. A
    # comparison in the browser would find nothing here and mark nothing,
    # while the server had every reason to return the row.
    row = row_for('Maßangaben', query: "workspace_id=#{marketing}&q=Massangaben")

    assert_equal [[0, 'Maßangaben'.length]], row['highlights']['title']
  end

  # Without a term there is nothing to mark, and empty ranges on every line
  # would be noise in every answer.
  def test_without_a_search_term_nothing_is_marked
    sign_in(:sabine)

    assert_equal({}, row_for('Blogartikel-Generator')['highlights'])
  end

  # --- filters belong in the query, not behind it (FA-506) ------------------

  # The heading of the library shows `meta.total` next to the list (11.3).
  # While the filters were applied to the returned page, the two described
  # different sets: the count included rows the filter then removed.
  def test_the_count_describes_the_same_set_as_the_page
    sign_in(:sabine)
    csrf(:post, "#{prefix}/prompts/#{prompt('Blogartikel-Generator')}/favorite")

    payload = list("workspace_id=#{marketing}&favorites_only=true")

    assert_equal 1, payload['meta']['total']
    assert_equal payload['prompts'].size, payload['meta']['total']
    assert_equal ['Blogartikel-Generator'], payload['prompts'].map { |row| row['title'] }
  end

  # And the page has to be filled from the filtered set, not from an unfiltered
  # one that is then thinned out. With one match behind six non-matches, a page
  # of five came back empty while the match sat on the second page — the exact
  # shape of the defect.
  def test_a_filtered_page_is_filled_from_the_matches
    sign_in(:sabine)
    csrf(:post, "#{prefix}/prompts/#{prompt('Massangaben')}/favorite")

    payload = list("workspace_id=#{marketing}&favorites_only=true&per_page=5&page=1")

    assert_equal ['Massangaben'], payload['prompts'].map { |row| row['title'] }
    assert_equal 1, payload['meta']['total']
  end

  # The same rule for the status filter, which is what 11.3 rests on: archived
  # prompts appear only when they are asked for, and the count says so too.
  def test_the_archive_filter_counts_what_it_shows
    sign_in(:sabine)
    with_app_db do |db|
      db[:prompts].where(id: prompt('Blog-Beitrag Artikel')).update(status: 'archived')
    end

    without = list("workspace_id=#{marketing}")
    with    = list("workspace_id=#{marketing}&status=archived")

    refute_includes without['prompts'].map { |row| row['title'] }, 'Blog-Beitrag Artikel'
    assert_equal without['prompts'].size, without['meta']['total']

    # P-ARCH from the fixture is archived as well, so this asserts what has to
    # be there rather than an exact set — pinning the set would break the day
    # the fixture gains another archived prompt.
    assert_includes with['prompts'].map { |row| row['title'] }, 'Blog-Beitrag Artikel'
    assert with['prompts'].all? { |row| row['status'] == 'archived' }
    assert_equal with['prompts'].size, with['meta']['total']
  end

  # --- tags (FA-503, TF-406) ------------------------------------------------

  def test_the_tag_list_carries_the_usage_count
    sign_in(:sabine)
    get "#{prefix}/tags?workspace_id=#{marketing}"

    seo = JSON.parse(last_response.body)['tags'].find { |t| t['name'] == 'seo' }
    assert_equal 1, seo['usage_count']
  end

  # TF-406: the assignments go, the prompts stay. A tag is a label, never part
  # of the content.
  # The prompt that has to survive is the *tagged* one. Checking any other
  # would pass even if deleting a tag took its prompts with it — a mutation
  # probe showed exactly that.
  def test_tf406_deleting_a_tag_removes_the_assignments_and_leaves_the_prompts
    seo, = tag_ids('seo')
    tagged = prompt('Blogartikel-Generator')
    body_before, count_before = with_app_db do |db|
      [db[:prompts][id: tagged][:body], db[:prompts].count]
    end

    sign_in(:sabine)
    csrf(:delete, "#{prefix}/tags/#{seo}")

    assert_equal 200, last_response.status
    assert_equal 1, JSON.parse(last_response.body)['removed_assignments']
    with_app_db do |db|
      assert_equal 1, db[:prompts].where(id: tagged).count, 'the tagged prompt itself must survive'
      assert_equal body_before, db[:prompts][id: tagged][:body], 'and its text must be untouched'
      assert_equal count_before, db[:prompts].count, 'and no other prompt may go either'
      assert_equal 0, db[:prompt_tags].where(tag_id: seo).count
      assert_equal %w[content], PromptAtelier::Prompts.tag_names(db, tagged), 'the other tag stays'
    end
  end

  def test_a_viewer_may_not_create_a_tag
    sign_in(:lisa)
    csrf(:post, "#{prefix}/tags", { workspace_id: marketing, name: 'neu' })

    assert_equal 403, last_response.status
  end

  def test_a_stranger_is_told_nothing_about_a_foreign_tag_list
    sign_in(:joerg)
    get "#{prefix}/tags?workspace_id=#{marketing}"

    assert_equal 404, last_response.status
  end

  # --- keywords (FA-401, FA-404, TF-405) ------------------------------------

  def test_a_keyword_name_is_unique_within_the_workspace
    sign_in(:sabine)
    csrf(:post, "#{prefix}/keywords",
         { workspace_id: marketing, name: 'formal', text: 'Noch einmal.', position: 'append' })

    assert_equal 409, last_response.status
  end

  def test_the_same_name_is_free_again_in_another_workspace
    sign_in(:sabine)
    csrf(:post, "#{prefix}/keywords",
         { workspace_id: @ids[:workspaces][:personal_sabine], name: 'formal',
           text: 'Meine eigene Fassung.', position: 'append' })

    assert_equal 201, last_response.status
  end

  # --- TF-548: editing a keyword (FA-401) -----------------------------------

  # **FA-401 says "anlegen, bearbeiten, löschen", and `bearbeiten` had no test
  # of any kind.** `PUT /keywords/:id` existed, `Catalog.update_keyword`
  # existed, and neither was reached by a single case: the whole method body
  # was unrun in a coverage measurement of the suite. Proven by deleting the
  # duplicate-name check on the edit path — every test stayed green.
  #
  # The acceptance criterion of FA-401 is a single sentence about a name that
  # already exists, and creating was the only half anybody had checked. This is
  # the same lesson as the one written into the project's own rules: a case
  # that carries a requirement's number owes that requirement every clause.
  def test_tf548_a_keyword_can_be_edited
    keyword = keyword_id('formal')
    sign_in(:sabine)

    csrf(:put, "#{prefix}/keywords/#{keyword}",
         { name: 'foermlich', text: 'Neue Fassung.', position: 'prepend' })

    assert_equal 200, last_response.status
    with_app_db do |db|
      row = db[:keywords].first(id: keyword)
      assert_equal 'foermlich', row[:name]
      assert_equal 'Neue Fassung.', row[:text]
      assert_equal 'prepend', row[:position]
    end
  end

  def test_tf548_editing_onto_an_existing_name_is_refused
    sign_in(:sabine)
    # Made here rather than taken from the fixture: the case needs a *second*
    # keyword to collide with, and a case that needs something has to bring it.
    csrf(:post, "#{prefix}/keywords",
         { workspace_id: marketing, name: 'knapp', text: 'Kurz.', position: 'append' })
    assert_equal 201, last_response.status
    keyword = keyword_id('knapp')

    csrf(:put, "#{prefix}/keywords/#{keyword}", { name: 'formal' })

    assert_equal 409, last_response.status
    with_app_db do |db|
      assert_equal 'knapp', db[:keywords].first(id: keyword)[:name], 'nothing may have been written'
    end
  end

  # The counter-check, and it is not a formality: a clash test that also fires
  # when a keyword keeps its own name would make renaming impossible, and the
  # case above would not notice.
  def test_tf548_saving_a_keyword_under_its_own_name_is_no_clash
    keyword = keyword_id('formal')
    sign_in(:sabine)

    csrf(:put, "#{prefix}/keywords/#{keyword}", { name: 'formal', text: 'Nur der Text ist neu.' })

    assert_equal 200, last_response.status
  end

  # --- TF-549: the limits of Requirements 14.3 ------------------------------

  # The limits table is normative ("serverseitig geprüft", SEC-08) and four of
  # its rows had no test at all. They were **implemented** — a probe refused
  # every one of them — so what was missing was the guard, not the behaviour.
  # Two of them are checked here, where the answer an operator sees is decided.
  def test_tf549_a_keyword_name_over_forty_characters_is_refused
    sign_in(:sabine)
    csrf(:post, "#{prefix}/keywords",
         { workspace_id: marketing, name: 'x' * 41, text: 'Ein Text.', position: 'append' })

    assert_equal 422, last_response.status
  end

  def test_tf549_forty_characters_are_still_accepted
    sign_in(:sabine)
    csrf(:post, "#{prefix}/keywords",
         { workspace_id: marketing, name: 'x' * 40, text: 'Ein Text.', position: 'append' })

    assert_equal 201, last_response.status, 'the limit is 40, not 39'
  end

  def test_tf549_the_two_hundred_and_first_keyword_in_a_workspace_is_refused
    with_app_db do |db|
      now = Time.now
      existing = db[:keywords].where(workspace_id: marketing).count
      (200 - existing).times do |i|
        db[:keywords].insert(workspace_id: marketing, name: "fuellwort-#{i}", text: 'x',
                             position: 'append', sort_order: 0, created_at: now, updated_at: now)
      end
    end
    sign_in(:sabine)

    csrf(:post, "#{prefix}/keywords",
         { workspace_id: marketing, name: 'einer-zu-viel', text: 'Ein Text.', position: 'append' })

    assert_equal 422, last_response.status
    with_app_db { |db| assert_equal 200, db[:keywords].where(workspace_id: marketing).count }
  end

  # TF-405: the count comes first, the deletion second. Removing it straight
  # away would change what three prompts render, without anyone being told.
  def test_tf405_deleting_a_used_keyword_names_the_affected_prompts_first
    keyword = keyword_id('formal')
    sign_in(:sabine)

    csrf(:delete, "#{prefix}/keywords/#{keyword}")
    assert_equal 409, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 3, body['affected_prompts'].size
    assert_equal 'confirmation_required', body['error']['code']
    # The count is in the list itself, and the list is what the screen shows —
    # it names the prompts, which a number never could.
    assert_equal 3, body['affected_prompts'].size

    with_app_db { |db| assert_equal 1, db[:keywords].where(id: keyword).count, 'nothing deleted yet' }
  end

  def test_tf405_after_confirmation_the_keyword_and_its_assignments_go
    keyword = keyword_id('formal')
    bodies_before = with_app_db { |db| db[:prompts].select_map(%i[id body]) }
    sign_in(:sabine)

    csrf(:delete, "#{prefix}/keywords/#{keyword}", { confirm: true })

    assert_equal 200, last_response.status
    assert_equal 3, JSON.parse(last_response.body)['removed_assignments']
    with_app_db do |db|
      assert_equal 0, db[:keywords].where(id: keyword).count
      assert_equal 0, db[:prompt_keywords].where(keyword_id: keyword).count
      assert_equal bodies_before, db[:prompts].select_map(%i[id body]), 'the prompt texts are untouched'
    end
  end

  def test_an_editor_may_write_keywords_and_a_viewer_may_not
    sign_in(:martin)
    csrf(:post, "#{prefix}/keywords",
         { workspace_id: marketing, name: 'neu-martin', text: 'Text.', position: 'append' })
    assert_equal 201, last_response.status

    sign_in(:lisa)
    csrf(:post, "#{prefix}/keywords",
         { workspace_id: marketing, name: 'neu-lisa', text: 'Text.', position: 'append' })
    assert_equal 403, last_response.status
  end

  # TF-426: a stranger sees the keyword list of their own workspace, never the
  # foreign one — the standard keywords of a foreign prompt reach them only
  # through the prompt itself (FA-604, proven in prompt_api_test.rb).
  def test_tf426_a_stranger_cannot_read_a_foreign_keyword_list
    sign_in(:joerg)

    get "#{prefix}/keywords?workspace_id=#{marketing}"
    assert_equal 404, last_response.status

    get "#{prefix}/keywords?workspace_id=#{@ids[:workspaces][:personal_joerg]}"
    assert_equal 200, last_response.status
    assert_empty JSON.parse(last_response.body)['keywords']
  end

  def test_a_keyword_beyond_the_text_limit_is_refused_with_the_numbers
    sign_in(:sabine)
    csrf(:post, "#{prefix}/keywords",
         { workspace_id: marketing, name: 'zulang', text: 'x' * 5_001, position: 'append' })

    assert_equal 422, last_response.status
    fields = JSON.parse(last_response.body).dig('error', 'fields')
    assert_equal 5_000, fields.dig('text', 'limit')
    assert_equal 5_001, fields.dig('text', 'actual')
  end

  # --- W-1 end to end (definition of done for AP-08) ------------------------

  # Find, open, render, receive the result — with an HTTP tool alone, no
  # interface involved. This is what the plan asks AP-08 to make possible.
  def test_w1_search_open_render_and_receive_the_finished_prompt
    sign_in(:sabine)

    get "#{prefix}/prompts?workspace_id=#{marketing}&q=blogartikel"
    found = JSON.parse(last_response.body)['prompts'].first
    refute_nil found, 'the search finds it'

    get "#{prefix}/prompts/#{found['id']}"
    detail = JSON.parse(last_response.body)['prompt']
    assert_equal %w[thema zielgruppe], detail['variables'].map { |v| v['key'] }

    csrf(:post, "#{prefix}/prompts/#{found['id']}/render",
         { values: { 'thema' => 'Bienen', 'zielgruppe' => 'Einsteiger' },
           keyword_ids: [keyword_id('formal')] })

    assert_equal 200, last_response.status
    result = JSON.parse(last_response.body)
    assert result['complete'], 'no required variable left open'
    assert_includes result['text'], 'Bienen'
    assert_includes result['text'], 'Einsteiger'
    assert_includes result['text'], 'Förmlich.', 'the keyword was applied'
  end

  private

  def prefix = PromptAtelier::App::API_PREFIX
  def marketing = @ids[:workspaces][:marketing]
  def prompt(label) = @ids[:prompts][label]
  def with_app_db(&block) = PromptAtelier::Database.open(database_path(@dir), &block)

  # The search fixtures of test concept 4.6, plus the tags and the keyword the
  # cases above need. They live beside the permission fixture rather than in
  # it: only this suite needs them, and TF-314 in particular requires wording
  # that would otherwise pollute every other test.
  def seed_library(db, ids)
    marketing = ids[:workspaces][:marketing]
    sabine = ids[:users][:sabine]
    now = Time.now

    {
      'Blogartikel-Generator' => 'Schreibe einen Blogartikel über {{thema}} für {{zielgruppe}}.',
      'Blog-Beitrag Artikel'  => 'Ein Text für Einsteiger.',
      'Maßangaben'            => 'Die Größe spielt eine Rolle. Eine Übung für alle.',
      'Massangaben'           => 'Die Groesse spielt eine Rolle. Eine Uebung fuer alle.'
    }.each do |title, body|
      id = db[:prompts].insert(workspace_id: marketing, owner_id: sabine, title: title,
                               body: body, visibility: 'workspace', status: 'active',
                               created_at: now, updated_at: now)
      ids[:prompts][title] = id
      PromptAtelier::Prompts.synchronise_variables(db, id, body, nil)
    end

    PromptAtelier::Prompts.assign_tags(db, ids[:prompts]['Blogartikel-Generator'], marketing,
                                       %w[seo content], now: now)
    PromptAtelier::Prompts.assign_tags(db, ids[:prompts]['Blog-Beitrag Artikel'], marketing,
                                       %w[content], now: now)

    formal = db[:keywords].insert(workspace_id: marketing, name: 'formal', text: 'Förmlich.',
                                  position: 'append', sort_order: 10,
                                  created_at: now, updated_at: now)
    [ids[:prompts]['Blogartikel-Generator'], ids[:prompts]['P-WS'], ids[:prompts]['P-INST']].each do |prompt_id|
      db[:prompt_keywords].insert(prompt_id: prompt_id, keyword_id: formal)
    end
  end

  def list(query)
    get "#{prefix}/prompts?#{query}"
    assert_equal 200, last_response.status, last_response.body[0, 200]
    JSON.parse(last_response.body)
  end

  # One line of the library, by its title.
  def row_for(title, query: "workspace_id=#{marketing}")
    get "#{prefix}/prompts?#{query}"
    assert_equal 200, last_response.status, last_response.body[0, 200]
    found = JSON.parse(last_response.body)['prompts'].find { |row| row['title'] == title }
    refute_nil found, "#{title} is not in the list"
    found
  end

  def titles_for(term)
    get "#{prefix}/prompts?workspace_id=#{marketing}&q=#{CGI.escape(term)}"
    assert_equal 200, last_response.status, last_response.body[0, 200]
    JSON.parse(last_response.body)['prompts'].map { |p| p['title'] }.sort
  end

  def titles_with_tags(ids)
    query = ids.map { |id| "tags[]=#{id}" }.join('&')
    get "#{prefix}/prompts?workspace_id=#{marketing}&#{query}"
    JSON.parse(last_response.body)['prompts'].map { |p| p['title'] }.sort
  end

  def tag_ids(*names)
    with_app_db { |db| names.map { |name| db[:tags].first(workspace_id: marketing, name: name)[:id] } }
  end

  def keyword_id(name)
    with_app_db { |db| db[:keywords].first(workspace_id: marketing, name: name)[:id] }
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
