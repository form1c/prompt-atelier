# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'services/retention'
require 'services/prompts'

# TF-524 and TF-652 — the retention periods of FA-706 and SEC-16.
#
# Checked **on both sides of every limit**, as the test concept asks: a rule
# that only ever sees data past its limit passes just as well when the
# comparison points the wrong way. Every case here has a sibling one day short
# of it.
class RetentionTest < PromptAtelier::TestCase
  R = PromptAtelier::Retention

  DAY = 24 * 60 * 60

  def setup
    super
    @dir = migrated_dir('retention')
    @now = Time.now
  end

  def with_instance
    with_db(@dir) do |db|
      ids = PromptAtelier::Fixture.build(db)
      yield db, ids
    end
  end

  def prompt_with_revisions(db, ids, count:, age_days:)
    id = PromptAtelier::Prompts.create(db, workspace_id: ids[:workspaces][:marketing],
                                           owner_id: ids[:users][:sabine],
                                           attributes: { 'title' => "Viel bearbeitet #{age_days}",
                                                         'body' => 'Text.' })
    count.times do |index|
      db[:prompt_revisions].insert(prompt_id: id, snapshot_json: '{}',
                                   created_at: @now - (age_days * DAY) - index)
    end
    id
  end

  # --- revisions: the minimum age wins over the count -----------------------

  def test_tf524_a_prompt_with_sixty_old_revisions_keeps_the_newest_fifty
    with_instance do |db, ids|
      id = prompt_with_revisions(db, ids, count: 60, age_days: 240)

      R.sweep(db, now: @now)

      assert_equal 50, db[:prompt_revisions].where(prompt_id: id).count
    end
  end

  # The half that a count-only rule would get wrong, and the reason the rule
  # has two halves: fifty is a storage limit, ninety days is a promise about
  # being able to go back.
  def test_tf524_sixty_revisions_from_the_last_ninety_days_all_stay
    with_instance do |db, ids|
      id = prompt_with_revisions(db, ids, count: 60, age_days: 10)

      R.sweep(db, now: @now)

      assert_equal 60, db[:prompt_revisions].where(prompt_id: id).count
    end
  end

  # --- the trash: 30 days, checked on both sides ----------------------------

  def test_tf524_a_prompt_deleted_29_days_ago_stays_in_the_trash
    with_instance do |db, ids|
      id = deleted_prompt(db, ids, days_ago: 29)

      R.sweep(db, now: @now)

      refute_nil db[:prompts][id: id]
    end
  end

  def test_tf524_a_prompt_deleted_31_days_ago_goes_with_its_revisions
    with_instance do |db, ids|
      id = deleted_prompt(db, ids, days_ago: 31)
      db[:prompt_revisions].insert(prompt_id: id, snapshot_json: '{}', created_at: @now)

      R.sweep(db, now: @now)

      assert_nil db[:prompts][id: id]
      assert_equal 0, db[:prompt_revisions].where(prompt_id: id).count
    end
  end

  # --- audit entries: 12 months ---------------------------------------------

  def test_tf524_an_audit_entry_from_eleven_months_ago_stays_and_one_from_thirteen_goes
    with_instance do |db, _ids|
      db[:audit_logs].delete
      db[:audit_logs].insert(action: 'alt', created_at: R.shift_months(@now, -13))
      db[:audit_logs].insert(action: 'juenger', created_at: R.shift_months(@now, -11))

      R.sweep(db, now: @now)

      assert_equal %w[juenger], db[:audit_logs].select_map(:action)
    end
  end

  # The case that tells the two readings apart. "Twelve months" and "twelve
  # times thirty days" agree for anything much older or much younger; they
  # disagree in the five days between 360 and 365. An entry from 362 days ago
  # is **inside** twelve months and outside 360 days — and the first version
  # of this suite used 11 and 13 months, where both readings say the same
  # thing. A mutation probe walked through it.
  def test_tf524_twelve_months_is_a_calendar_statement_and_not_360_days
    with_instance do |db, _ids|
      db[:audit_logs].delete
      db[:audit_logs].insert(action: 'knapp_drin', created_at: @now - (362 * DAY))

      R.sweep(db, now: @now)

      assert_equal %w[knapp_drin], db[:audit_logs].select_map(:action)
    end
  end

  # Twelve months is a calendar statement, not 360 days. The two part company
  # around February and around a leap year, and the document says months.
  def test_the_month_arithmetic_lands_on_a_real_date
    assert_equal Time.new(2025, 2, 28), R.shift_months(Time.new(2025, 3, 31), -1).then { |t|
      Time.new(t.year, t.month, t.day)
    }
    assert_equal Time.new(2024, 2, 29), R.shift_months(Time.new(2024, 3, 31), -1).then { |t|
      Time.new(t.year, t.month, t.day)
    }
  end

  # --- audit entries: the upper bound on their number -----------------------

  # The last brake before a full disk, below the twelve-month rule and never
  # instead of it.
  def test_the_cap_removes_the_oldest_and_leaves_the_number_it_promises
    with_instance do |db, _ids|
      db[:audit_logs].delete
      10.times { |n| db[:audit_logs].insert(action: "e#{n}", created_at: @now - (10 - n)) }

      R.sweep(db, config: { 'retention.audit_max_entries' => 4 }, now: @now)

      assert_equal %w[e6 e7 e8 e9], db[:audit_logs].order(:id).select_map(:action),
                   'the four newest, and the six oldest gone'
    end
  end

  # A cap that fires when it should not would silently shorten the log every
  # single day.
  def test_below_the_cap_nothing_is_removed
    with_instance do |db, _ids|
      db[:audit_logs].delete
      4.times { |n| db[:audit_logs].insert(action: "e#{n}", created_at: @now) }

      R.sweep(db, config: { 'retention.audit_max_entries' => 4 }, now: @now)

      assert_equal 4, db[:audit_logs].count, 'exactly at the limit is not over it'
    end
  end

  # Entries written in the same second have no order by time. The id has one,
  # which is why the trimming goes by it — otherwise which four survive above
  # would be up to SQLite.
  def test_entries_from_the_same_moment_still_have_an_oldest
    with_instance do |db, _ids|
      db[:audit_logs].delete
      moment = @now - 60
      5.times { |n| db[:audit_logs].insert(action: "e#{n}", created_at: moment) }

      R.sweep(db, config: { 'retention.audit_max_entries' => 2 }, now: @now)

      assert_equal %w[e3 e4], db[:audit_logs].order(:id).select_map(:action)
    end
  end

  def test_what_the_cap_removed_is_reported_together_with_what_the_months_removed
    with_instance do |db, _ids|
      db[:audit_logs].delete
      db[:audit_logs].insert(action: 'uralt', created_at: R.shift_months(@now, -13))
      3.times { |n| db[:audit_logs].insert(action: "e#{n}", created_at: @now) }

      removed = R.sweep(db, config: { 'retention.audit_max_entries' => 1 }, now: @now)

      assert_equal 3, removed['audit'], 'one by age, two by number'
      assert_equal 1, db[:audit_logs].count
    end
  end

  # --- sessions and login attempts ------------------------------------------

  def test_tf524_an_expired_session_is_removed_and_a_live_one_is_not
    with_instance do |db, ids|
      db[:sessions].insert(user_id: ids[:users][:sabine], token_hash: 'alt',
                           last_seen_at: @now - DAY, expires_at: @now - 60, created_at: @now - DAY)
      db[:sessions].insert(user_id: ids[:users][:sabine], token_hash: 'frisch',
                           last_seen_at: @now, expires_at: @now + DAY, created_at: @now)

      R.sweep(db, now: @now)

      assert_equal %w[frisch], db[:sessions].select_map(:token_hash)
    end
  end

  def test_tf524_a_login_attempt_from_eight_days_ago_goes_and_one_from_six_stays
    with_instance do |db, _ids|
      db[:login_attempts].insert(email: 'alt@test', ip: '1.2.3.4', attempted_at: @now - (8 * DAY))
      db[:login_attempts].insert(email: 'neu@test', ip: '1.2.3.4', attempted_at: @now - (6 * DAY))

      R.sweep(db, now: @now)

      assert_equal %w[neu@test], db[:login_attempts].select_map(:email)
    end
  end

  # --- the summary ----------------------------------------------------------

  # FA-706 asks for a summary per run. A run that reports nothing cannot be
  # told apart from one that never happened.
  def test_the_run_reports_what_it_removed
    with_instance do |db, ids|
      deleted_prompt(db, ids, days_ago: 31)

      removed = R.sweep(db, now: @now)

      assert_equal 1, removed['prompts']
      assert_equal 0, removed['revisions']
      assert(removed.key?('sessions') && removed.key?('audit') && removed.key?('login_attempts'))
    end
  end

  def test_the_limits_come_from_the_configuration_when_there_is_one
    config = { 'retention.trash_days' => 2 }
    assert_equal 2, R.limits(config)['trash_days']
    assert_equal 50, R.limits(config)['revisions_per_prompt'], 'and the rest fall back'
  end

  private

  def deleted_prompt(db, ids, days_ago:)
    id = PromptAtelier::Prompts.create(db, workspace_id: ids[:workspaces][:marketing],
                                           owner_id: ids[:users][:sabine],
                                           attributes: { 'title' => "Weg seit #{days_ago}",
                                                         'body' => 'Text.' })
    db[:prompts].where(id: id).update(deleted_at: @now - (days_ago * DAY),
                                      deleted_by: ids[:users][:sabine])
    id
  end
end
