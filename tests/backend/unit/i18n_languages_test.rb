# frozen_string_literal: true

require_relative '../../test_helper'
require 'services/password'

# What `app/locales/` is for, and what it is **not** for (E-12, BT-16, AP-22).
#
# It holds what the **console** prints: the scripts, the configuration check,
# the startup abort. Those lines are read by whoever installs and operates an
# instance, often on somebody else's machine, and they get pasted into search
# engines when something goes wrong. An English sentence finds answers there.
#
# **It does not hold the interface.** Since AP-19 the server answers `code` +
# `params` and never a sentence; every sentence a person reads is carried by
# the browser, in `frontend/src/locales/`. The directory here kept nine
# interface namespaces long after nothing read them — and this file was what
# made them look alive, asserting that `auth.invalid_credentials` says "nicht
# richtig" over a table no code touched. A test that pins dead weight is worse
# than the dead weight: it turns the clean-up into a red build.
#
# What is checked now is what still holds: the console speaks English, and it
# does so **whatever language the instance is set to** — which was not true
# either. `password.*` sat in `de.json` and in the base, so `install` printed
# its password rules in German on an instance with `locale: de`, in the middle
# of an otherwise English session. Measured, then removed.
class I18nLanguagesTest < PromptAtelier::TestCase
  I18n = PromptAtelier::I18n

  def console_namespaces
    JSON.parse(File.read(File.join(I18n.directory, 'en.json'), encoding: 'UTF-8'))
        .keys.reject { |key| key.start_with?('_') }
  end

  def teardown
    I18n.default_language = PromptAtelier::I18n::DEFAULT_LANGUAGE
    I18n.reload!
    super
  end

  # The rule, stated as the thing that can actually go wrong: an instance set
  # to another language must not change a single console line.
  def test_the_console_speaks_english_in_every_language_the_instance_is_set_to
    %w[en de fr it es].each do |language|
      I18n.default_language = language
      I18n.reload!

      assert_equal 'Checking prerequisites', I18n.t('environment.title'), "with locale #{language}"
      assert_includes I18n.t('migrate.title'), 'schema', "with locale #{language}"
      assert_includes I18n.t('config.aborted'), 'Startup aborted', "with locale #{language}"
    end
  end

  # The one that came back. `Password.policy_sentences` is called by `install`
  # and by `reset_admin_password` and by nothing else — it is console output,
  # and it used to follow the instance language because the sentence lived in
  # two places at once.
  def test_the_password_rules_of_the_console_stay_english
    %w[en de fr].each do |language|
      I18n.default_language = language
      I18n.reload!

      sentences = PromptAtelier::Password.policy_sentences('kurz')

      refute_empty sentences
      assert_includes sentences.first, 'at least', "with locale #{language}"
    end
  end

  # No second table on the server, and the reason spelled out rather than
  # implied: a file here would be console text in another language, which is
  # the thing E-12 forbids. The interface's languages are somewhere else
  # entirely — the check for those is `language_switch.test.js`.
  def test_the_directory_holds_the_base_table_and_nothing_else
    assert_equal [PromptAtelier::I18n::BASE_LANGUAGE], I18n.available_languages
  end

  # And every console namespace is still reachable through it. Without this,
  # the case above would also pass over a directory somebody emptied.
  def test_every_console_namespace_is_reachable
    refute_empty console_namespaces, 'the base table was not read at all'

    console_namespaces.each do |namespace|
      assert I18n.send(:texts).key?(namespace), "#{namespace} is not reachable at all"
    end
  end

  # The scripts of AP-16 by name, so that a namespace that quietly disappeared
  # would be noticed here rather than as an empty line on somebody's console.
  def test_the_scripts_of_the_delivery_have_their_texts
    %w[install service backup restore relocate build portable].each do |namespace|
      assert_includes console_namespaces, namespace
    end

    assert_includes I18n.t('build.tests_failed'), 'tests failed'
    assert_includes I18n.t('portable.stop_hint'), 'Ctrl+C'
  end

  # --- which languages an instance may be set to (AP-22) --------------------

  # The distinction the negotiation turns on, and the one that was wrong: what
  # this instance may **speak** is not what this directory **holds**. The
  # interface carries its own languages in the bundle, where the server cannot
  # count them.
  def test_a_language_may_be_offered_without_a_table_on_the_server
    assert I18n.offered?('fr'), 'the interface has French; the server has no reason to refuse it'
    refute I18n.available?('fr'), 'and it has no console table for it, which is right'

    # The most specific tag the request asked for, untrimmed. The server does
    # not know whether the bundle carries `fr` or `fr-FR`, so it relays and
    # lets the side that has the files decide (`resolve` in i18n/index.js).
    assert_equal 'fr-FR', I18n.negotiate(accept_language: 'fr-FR,fr;q=0.9')
    assert_equal 'fr', I18n.negotiate(accept_language: 'fr;q=0.9')
  end

  # The counter-direction. `offered?` is what the value of a header and of a
  # column is checked against, so it has to refuse what must never end up
  # there — anything with a separator in it above all.
  def test_a_code_that_is_not_a_code_is_refused
    ['', nil, 'english', 'de,en', "de\r\nX: y", '../en', 'DE'].each do |value|
      refute I18n.offered?(value), value.inspect
    end
  end
end
