# frozen_string_literal: true

require_relative '../../test_helper'
require 'services/settings'

# The settings an administrator may change from the browser (FA-910).
class SettingsTest < PromptAtelier::TestCase
  Subject = PromptAtelier::Settings

  def setup
    super
    @dir = migrated_dir('settings')
    Subject.forget!
  end

  def teardown
    Subject.forget!
    super
  end

  # --- what is editable and what is not ------------------------------------

  # The list is short on purpose. Operating values — address, port, paths, the
  # trusted proxies — describe the machine: a wrong one takes the
  # instance off the network, and some of them grant rights (widening
  # `trusted_proxies` disables the login limit and lets anybody write any
  # address into the very log this screen shows).
  def test_no_operating_value_is_editable
    forbidden = %w[
      server.host server.port server.base_url server.trusted_proxies
      database.path security.force_https
      security.argon2.memory_mib logging.path locale
    ]

    assert_empty Subject::EDITABLE & forbidden
  end

  # Every editable key must have a rule, or it would be written unchecked —
  # the rules are Configuration's, so that a value typed into a form and one
  # written into config.yml are judged alike.
  def test_every_editable_key_is_one_the_configuration_knows_how_to_check
    without_rule = Subject::EDITABLE.reject { |key| PromptAtelier::Configuration::RULES.key?(key) }

    assert_empty without_rule
  end

  # --- reading --------------------------------------------------------------

  def test_without_a_stored_value_the_file_answers
    with_db(@dir) do |db|
      view = Subject.view(db, 'retention.trash_days' => 30)

      assert_equal 30, view['retention.trash_days']
    end
  end

  def test_a_stored_value_wins_over_the_file
    with_db(@dir) do |db|
      Subject.update(db, { 'retention.trash_days' => 45 }, actor: nil)
      view = Subject.view(db, 'retention.trash_days' => 30)

      assert_equal 45, view['retention.trash_days']
    end
  end

  # Everything else passes straight through. Without this the layer would have
  # to know every key the application asks for, and a forgotten one would read
  # as "not configured" rather than as its actual value.
  def test_a_key_that_is_not_editable_still_comes_from_the_file
    with_db(@dir) do |db|
      view = Subject.view(db, 'server.port' => 9292)

      assert_equal 9292, view['server.port']
    end
  end

  # --- writing --------------------------------------------------------------

  def test_it_says_which_values_come_from_the_file_and_which_were_decided
    with_db(@dir) do |db|
      Subject.update(db, { 'retention.trash_days' => 45 }, actor: nil)
      described = Subject.describe(db, 'retention.trash_days' => 30, 'retention.audit_months' => 12)

      changed = described.find { |entry| entry['key'] == 'retention.trash_days' }
      untouched = described.find { |entry| entry['key'] == 'retention.audit_months' }

      refute changed['from_file'], 'somebody decided this'
      assert untouched['from_file'], 'and nobody has touched this one'
    end
  end

  def test_a_value_out_of_range_is_refused_with_the_expected_range_named
    with_db(@dir) do |db|
      error = assert_raises(Subject::Refused) do
        Subject.update(db, { 'retention.trash_days' => 0 }, actor: nil)
      end

      # The kind, not a sentence: the server's own descriptions are the
      # console English of the scripts, and this value is shown in a German
      # form. The screen writes the sentence from the kind.
      assert_equal 'positive_integer', error.fields['retention.trash_days']['kind']
    end
  end

  def test_a_value_of_the_wrong_kind_is_refused
    with_db(@dir) do |db|
      assert_raises(Subject::Refused) do
        Subject.update(db, { 'security.registration' => 'vielleicht' }, actor: nil)
      end
    end
  end

  # A key not on the list must be refused rather than stored: stored, it would
  # sit in the table looking like a setting and doing nothing, and the next
  # reader would wonder why it has no effect.
  def test_a_key_that_is_not_editable_is_refused
    with_db(@dir) do |db|
      error = assert_raises(Subject::Refused) do
        Subject.update(db, { 'server.port' => 1234 }, actor: nil)
      end

      assert error.fields.key?('server.port')
      assert_equal 0, db[:settings].count
    end
  end

  # The whole form, or none of it. A form with two changes of which one is
  # wrong must not leave the other applied — the person would repair the
  # complaint, submit again, and never learn that half of it had already gone
  # through.
  def test_one_bad_value_leaves_the_others_unwritten
    with_db(@dir) do |db|
      assert_raises(Subject::Refused) do
        Subject.update(db, { 'retention.trash_days' => 45, 'retention.audit_months' => 0 },
                       actor: nil)
      end

      assert_equal 0, db[:settings].count
    end
  end

  # A form field arrives as text even when the rule wants a number.
  def test_a_number_typed_into_a_form_arrives_as_a_number
    with_db(@dir) do |db|
      Subject.update(db, { 'retention.trash_days' => '45' }, actor: nil)

      assert_equal 45, Subject.view(db, {})['retention.trash_days']
    end
  end

  def test_text_that_is_no_number_is_still_refused
    with_db(@dir) do |db|
      assert_raises(Subject::Refused) do
        Subject.update(db, { 'retention.trash_days' => 'bald' }, actor: nil)
      end
    end
  end

  def test_writing_the_same_key_twice_replaces_it_rather_than_adding_a_second_row
    with_db(@dir) do |db|
      Subject.update(db, { 'retention.trash_days' => 45 }, actor: nil)
      Subject.update(db, { 'retention.trash_days' => 60 }, actor: nil)

      assert_equal 1, db[:settings].where(key: 'retention.trash_days').count
      assert_equal 60, Subject.view(db, {})['retention.trash_days']
    end
  end

  # The cache exists so that this is not a query per request. What must not
  # happen is that a change takes effect only after a restart — that is the
  # very property the whole feature exists to avoid.
  def test_a_change_is_in_force_immediately_and_not_after_a_restart
    with_db(@dir) do |db|
      Subject.view(db, {})['retention.trash_days'] # fills the cache
      Subject.update(db, { 'retention.trash_days' => 45 }, actor: nil)

      assert_equal 45, Subject.view(db, {})['retention.trash_days']
    end
  end
end
