# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'app'

# TF-533 over HTTP — the language a real request ends up speaking (AP-19, 11.7).
#
# The unit cases beside this one check `I18n.negotiate` on its own. What only
# a request can show is that the chain is actually **wired**: that the header
# reaches it, that the profile of whoever is signed in outranks it, and that
# an operator who wrote a language into config.yml is not overruled by a
# browser.
#
# **Empty means nothing was chosen** — in config.yml and in `users.locale`
# alike. That sentinel is the whole reason the chain can fall through, and it
# is what the first draft got wrong: it tried to tell a deliberate `en` from an
# inherited one with `Configuration#from_template?`, which would have been
# wrong in every real installation, because `install` copies the whole template
# into config.yml and every line in it then looks deliberate.
class LanguageChoiceTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  def app = PromptAtelier::App

  def teardown
    Thread.current[PromptAtelier::I18n::CURRENT] = nil
    super
  end


  def test_an_instance_without_a_language_follows_the_browser
    boot(locale: '')

    # As asked, region and all: the answer names what the browser wanted, and
    # the browser resolves it against the language files it carries (AP-22).
    assert_equal 'de-DE', spoken_language(accept: 'de-DE,de;q=0.9,en;q=0.8')
    assert_equal 'de', spoken_language(accept: 'de;q=0.9,en;q=0.8')
  end

  def test_an_instance_with_a_language_is_not_overruled_by_the_browser
    boot(locale: 'de')

    assert_equal 'de', spoken_language(accept: 'en-GB,en;q=0.9'),
                 'what the operator wrote wins over the header'
  end

  # With a language written into config.yml the header never gets a turn —
  # step 2 of 11.7 comes before step 3 — and that holds whether the header
  # names a language this instance could speak (`fr`), one nobody has (`zz`)
  # or something that is not a language code at all.
  def test_a_header_that_names_nothing_installed_changes_nothing
    boot(locale: 'de')

    ['fr', 'zz', '../../etc/passwd', ''].each do |header|
      assert_equal 'de', spoken_language(accept: header), "#{header.inspect} must change nothing"
    end
  end

  # `users.locale` is written empty at creation, so a new account follows the
  # instance rather than the column default of migration 001 — which is `de`
  # and would pin every account on an English instance to German.
  def test_a_new_account_has_chosen_no_language
    boot(locale: 'de')

    with_db(@dir) do |db|
      user = PromptAtelier::Accounts.create(db, name: 'Neu', email: 'neu@example.test',
                                                password: 'ein-langes-kennwort-12')
      assert_equal '', user[:locale],
                   'empty is what lets the chain of 11.7 fall through to the instance'
      refute PromptAtelier::I18n.available?(user[:locale])
    end
  end

  private

  # `App.reset!` before every boot, and it is not tidiness: `App.database` is
  # memoised, so a second `boot!` in the same process keeps the **first**
  # database. Left out, all four cases below share one instance — the failed
  # sign-ins add up across them and the fourth is answered with the lockout of
  # SEC-07 instead of the sentence it came for. Found exactly that way.
  def boot(locale:)
    PromptAtelier::App.reset!
    @dir = migrated_dir("language-#{locale.empty? ? 'none' : locale}")
    write_config(@dir, valid_config.merge('locale' => locale))
    PromptAtelier::App.boot!(root: @dir)
    PromptAtelier::RateLimit.reset!
    with_db(@dir) { |db| PromptAtelier::Fixture.build(db) }
  end

  # The language the server settled on, read off `Content-Language`.
  #
  # The first version of this helper read it off the **sentence** in the
  # answer, and that stopped working the moment the server stopped writing
  # sentences (AP-19). Reading the header is the better check anyway: it is
  # what the interface itself goes by, so this case now exercises the same
  # path the browser takes rather than a side effect of it.
  def spoken_language(accept:)
    header 'Accept-Language', accept
    post '/api/v1/auth/login', JSON.generate(email: 'martin@example.test', password: 'falsch'),
         { 'CONTENT_TYPE' => 'application/json' }

    last_response.headers['Content-Language'] || '(keine Kopfzeile)'
  end
end
