# frozen_string_literal: true

require_relative '../../test_helper'

# TF-529, TF-531 to TF-533 — the language belongs to the request (AP-19).
#
# Until this package the language was a value of the **process**, and the table
# behind it was memoised. That is fine while an instance speaks one language
# and nobody switches; it stops being fine the moment two people with different
# profiles are served at the same time, which is the ordinary case — Puma
# answers with up to eight threads.
#
# **Measured before it was rebuilt**, because "there could be a race" is a
# guess: two threads setting `de` and `fr` in a loop and reading a text back,
# 300 rounds each. Every single read of the first thread came back in the
# other's language. That is the reason for the thread-local, and TF-529 below
# is that measurement turned into a case that stays.
class LanguagePerRequestTest < PromptAtelier::TestCase
  I = PromptAtelier::I18n

  def setup
    super
    @previous_directory = I.directory
    @dir = install_dir('languages')
    FileUtils.mkdir_p(@dir)
    I.directory = @dir
    I.reload!
  end

  def teardown
    I.directory = @previous_directory
    I.reload!
    Thread.current[I::CURRENT] = nil
    super
  end

  # --- TF-529: two languages at the same moment ----------------------------

  # The case the rebuild exists for. Without `Thread.current` this fails at the
  # first hand-off: `Thread.pass` between setting and reading is exactly what a
  # request does when it touches the database.
  def test_tf529_two_threads_in_different_languages_each_keep_their_own
    write('en', 'greeting' => 'hello')
    write('de', 'greeting' => 'hallo')
    write('fr', 'greeting' => 'bonjour')

    expected = { 'de' => 'hallo', 'fr' => 'bonjour' }
    wrong = Hash.new(0)

    threads = expected.map do |code, want|
      Thread.new do
        200.times do
          I.with_language(code) do
            Thread.pass
            wrong[code] += 1 unless I.t('greeting') == want
          end
        end
      end
    end
    threads.each(&:join)

    assert_equal({ 'de' => 0, 'fr' => 0 }, { 'de' => wrong['de'], 'fr' => wrong['fr'] },
                 'a thread must never read the language of another')
  end

  # And the counter-check to that one: the block really is scoped. A test that
  # only proved isolation would also pass if `with_language` did nothing at all
  # and every read fell through to the same default.
  def test_tf529_the_language_belongs_to_the_block_and_is_given_back
    write('en', 'greeting' => 'hello')
    write('de', 'greeting' => 'hallo')
    I.default_language = 'en'

    assert_equal 'hello', I.t('greeting')
    I.with_language('de') { assert_equal 'hallo', I.t('greeting') }
    assert_equal 'hello', I.t('greeting'), 'the thread must be as it was'
  end

  # A request that raises must not leave its language on the thread — the
  # thread goes back into the pool and answers somebody else next.
  def test_tf529_a_raising_request_leaves_no_language_behind
    write('en', 'greeting' => 'hello')
    write('de', 'greeting' => 'hallo')
    I.default_language = 'en'

    assert_raises(RuntimeError) { I.with_language('de') { raise 'while answering' } }
    assert_equal 'hello', I.t('greeting')
    assert_nil Thread.current[I::CURRENT]
  end

  # --- TF-531: a language file that does not carry a key --------------------

  def test_tf531_a_missing_key_comes_from_the_base_table
    write('en', 'menu' => { 'save' => 'Save', 'cancel' => 'Cancel', 'close' => 'Close' })
    write('de', 'menu' => { 'save' => 'Speichern' })

    I.with_language('de') do
      assert_equal 'Speichern', I.t('menu.save'), 'the translated one wins'
      assert_equal 'Cancel', I.t('menu.cancel'), 'and the base answers the rest'
      assert_equal 'Close', I.t('menu.close')
    end
  end

  # The trap this guards: replacing per namespace instead of merging deeply
  # would let one translated sentence take the other two with it. The case
  # above would still pass on `save`; only these two would go missing.
  def test_tf531_translating_one_sentence_does_not_take_its_namespace_along
    write('en', 'menu' => { 'save' => 'Save', 'cancel' => 'Cancel' })
    write('de', 'menu' => { 'save' => 'Speichern' })

    I.with_language('de') do
      refute_nil I.t('menu.cancel')
    end
  end

  # --- TF-532: a language that is not there any more ------------------------

  # Somebody chose `fr`, and this directory has no table for it — which since
  # AP-22 is the **normal** case and not a fault: the console speaks English
  # and needs no second table, while the interface carries French in the
  # bundle. So the choice is relayed rather than overruled, and the lookup here
  # answers from the base instead of raising.
  #
  # The other half of TF-532 — a language *nobody* has, not even the interface
  # — is decided where the files are, in `language_switch.test.js`.
  def test_tf532_a_profile_naming_a_language_without_a_table_here_still_works
    write('en', 'greeting' => 'hello')

    assert_equal 'fr', I.negotiate(profile: 'fr'), 'relayed, not overruled'

    I.with_language('fr') do
      assert_equal 'hello', I.t('greeting'), 'and answers rather than raising'
    end
  end

  # --- TF-533: Accept-Language, and what it must not be able to do ----------

  def test_tf533_the_header_decides_before_a_profile_exists
    write('en', 'greeting' => 'hello')
    write('de', 'greeting' => 'hallo')

    # Relayed as asked, region and all. The server does not know whether the
    # bundle carries `de` or `de-DE`, so trimming here would be a guess — and
    # the side that does know resolves it (`resolve` in i18n/index.js).
    assert_equal 'de-DE', I.negotiate(accept_language: 'de-DE,de;q=0.9,en;q=0.8')
    assert_equal 'de-AT', I.negotiate(accept_language: 'de-AT')
    assert_equal 'en-GB', I.negotiate(accept_language: 'en-GB,en;q=0.9')

    # The primary subtag is still appended behind each tag, and it still
    # earns its place: a region that is not shaped like one is dropped, and
    # the language behind it answers instead of nothing.
    assert_equal 'de', I.negotiate(accept_language: 'de-DEUTSCHLAND,de;q=0.9')
  end

  def test_tf533_the_order_of_11_7_holds
    write('en', 'greeting' => 'hello')
    write('de', 'greeting' => 'hallo')
    write('fr', 'greeting' => 'bonjour')

    assert_equal 'de', I.negotiate(profile: 'de', configured: 'fr', accept_language: 'en'),
                 'the profile has the first say'
    assert_equal 'fr', I.negotiate(profile: nil, configured: 'fr', accept_language: 'en'),
                 'then what the operator wrote in config.yml'
    assert_equal 'en', I.negotiate(profile: nil, configured: nil, accept_language: 'en'),
                 'then the browser'
    assert_equal 'en', I.negotiate, 'and the base when nobody says anything'
  end

  # The header is input from the caller (SEC-04). Whatever comes out of the
  # negotiation goes into a `Content-Language` header and may be written to a
  # profile, so it has to be a language code and nothing else — no separator,
  # no line break, no path segment.
  #
  # `zz` is no longer in this list, and that is the change AP-22 made: it is a
  # well-formed code for a language nobody has, and it is now relayed. Nothing
  # can come of it — the interface answers in English for a language it does
  # not carry — whereas refusing it here would mean the server deciding which
  # languages exist, which is the mistake that hid French.
  def test_tf533_a_hostile_header_changes_nothing_and_loads_nothing
    write('en', 'greeting' => 'hello')
    write('de', 'greeting' => 'hallo')
    File.write(File.join(@dir, 'secret.json'), JSON.generate('greeting' => 'leaked'))

    # `de,en` is deliberately **not** here: in a header a comma is the
    # separator, and "German, then English" is what a browser really sends. It
    # is `offered?` that has to refuse a comma, because there the value is one
    # code — see `i18n_languages_test`.
    ['../../etc/passwd', '../secret', 'secret', 'EN', '', '*',
     "de\r\nX-Injected: y", 'de/../secret'].each do |hostile|
      assert_equal 'en', I.negotiate(accept_language: hostile),
                   "#{hostile.inspect} must not choose a language"
    end

    # And the neighbouring case, found by writing a NUL byte into that list by
    # accident: padding around a valid tag is **stripped** before anything else
    # happens, and Ruby counts NUL as whitespace. So `de\0` selects German —
    # which is right, and worth pinning, because it holds only as long as the
    # trimming happens *before* the shape test. The other way round, a request
    # with a slightly malformed header would silently lose its language.
    assert_equal 'de', I.negotiate(accept_language: "  de  ")
    assert_equal 'de', I.negotiate(accept_language: "de\u0000")

    # And the counter-check that the probe above could actually have found
    # something: the file it tried to reach really is there and really is
    # readable under a name that passes the shape test.
    assert_path_exists File.join(@dir, 'secret.json')
    refute I.available?('secret'), 'the shape test is what refuses it, not the absence of the file'
  end

  private

  def write(code, table)
    File.write(File.join(@dir, "#{code}.json"), JSON.generate(table))
    I.reload!
  end
end
