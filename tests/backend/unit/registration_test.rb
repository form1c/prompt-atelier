# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'services/registration'
require 'services/audit'

# Self-registration, below the endpoint (FA-107).
class RegistrationTest < PromptAtelier::TestCase
  Subject = PromptAtelier::Registration

  def setup
    super
    @dir = migrated_dir('registration')
  end

  # A configuration is a hash lookup by dotted key — the real one answers the
  # same way, and building a Configuration here would drag in a whole
  # installation for one string.
  def config(values = {}) = values

  # --- the three modes ------------------------------------------------------

  def test_the_delivered_state_is_off
    refute Subject.enabled?(config)
    refute Subject.enabled?(config('security.registration' => 'off'))
    assert_equal 'off', Subject.mode(nil), 'and a caller without configuration at all'
  end

  def test_approval_is_a_mode_of_its_own_and_not_a_second_switch
    assert Subject.enabled?(config('security.registration' => 'approval'))
    assert Subject.approval_required?(config('security.registration' => 'approval'))

    assert Subject.enabled?(config('security.registration' => 'open'))
    refute Subject.approval_required?(config('security.registration' => 'open'))
  end

  # A value the configuration would have refused at startup. Reaching here it
  # must not be read as "something other than off, so on".
  def test_an_unknown_value_is_read_as_off
    refute Subject.enabled?(config('security.registration' => 'vielleicht'))
  end

  # --- what it creates ------------------------------------------------------

  def test_with_approval_the_account_is_created_waiting_and_locked
    with_db(@dir) do |db|
      PromptAtelier::Fixture.build(db)
      user = register(db, { 'security.registration' => 'approval' })

      refute_nil user[:pending_since], 'FA-107: it waits'
      assert_equal 'locked', user[:status],
                   'the login gate stays the one condition it always was'
    end
  end

  def test_with_open_the_account_is_created_ready_to_use
    with_db(@dir) do |db|
      PromptAtelier::Fixture.build(db)
      user = register(db, { 'security.registration' => 'open' })

      assert_nil user[:pending_since]
      assert_equal 'active', user[:status]
    end
  end

  # FA-602 on the third path that creates accounts. Without it the newcomer
  # has nowhere to save and could not be deleted cleanly either (FA-606).
  def test_a_registered_account_has_a_place_to_write_from_the_first_moment
    with_db(@dir) do |db|
      PromptAtelier::Fixture.build(db)
      user = register(db, { 'security.registration' => 'open' })

      personal = db[:memberships].join(:workspaces, id: :workspace_id)
                                 .where(Sequel[:memberships][:user_id] => user[:id],
                                        Sequel[:workspaces][:is_personal] => true).count
      assert_equal 1, personal
    end
  end

  def test_it_is_recorded_with_the_address_it_came_from
    with_db(@dir) do |db|
      PromptAtelier::Fixture.build(db)
      register(db, { 'security.registration' => 'open' }, ip: '203.0.113.9')

      entry = db[:audit_logs].where(action: PromptAtelier::Audit::USER_REGISTERED).first
      refute_nil entry, 'the one path by which strangers enter must leave a trace (SEC-09)'
      assert_equal '203.0.113.9', entry[:ip]
    end
  end

  # --- the three refusals ---------------------------------------------------

  def test_switched_off_it_refuses_even_when_asked_directly
    with_db(@dir) do |db|
      PromptAtelier::Fixture.build(db)
      error = assert_raises(PromptAtelier::Accounts::Refused) { register(db, {}) }

      assert_equal :registration_disabled, error.code
      assert_equal 6, db[:users].count, 'and writes nothing'
    end
  end

  # The trap this guard exists for: FA-909 offers the setup page only while
  # there is no account at all. The first person to register would end it
  # without becoming an administrator, leaving an instance with users,
  # content and nobody able to administer it.
  def test_before_the_first_setup_nobody_may_register
    with_db(@dir) do |db|
      assert_equal 0, db[:users].count, 'the premise: this instance is not set up yet'

      error = assert_raises(PromptAtelier::Accounts::Refused) do
        register(db, { 'security.registration' => 'open' })
      end
      assert_equal :setup_pending, error.code
      assert_equal 0, db[:users].count
    end
  end

  def test_too_many_from_one_address_in_an_hour_are_refused
    with_db(@dir) do |db|
      PromptAtelier::Fixture.build(db)
      settings = { 'security.registration' => 'open', 'security.registrations_per_hour' => 2 }

      2.times { |n| register(db, settings, email: "neu#{n}@example.test", ip: '203.0.113.9') }

      error = assert_raises(PromptAtelier::Accounts::Refused) do
        register(db, settings, email: 'neu9@example.test', ip: '203.0.113.9')
      end
      assert_equal :too_many_registrations, error.code
      assert_equal 2, error.detail[:per_hour], 'the message names the limit it hit'
    end
  end

  # The limit is per address, not for everybody. Without this a single busy
  # office would shut the door on the rest of the instance.
  def test_the_limit_belongs_to_one_address_only
    with_db(@dir) do |db|
      PromptAtelier::Fixture.build(db)
      settings = { 'security.registration' => 'open', 'security.registrations_per_hour' => 1 }

      register(db, settings, email: 'eins@example.test', ip: '203.0.113.9')
      user = register(db, settings, email: 'zwei@example.test', ip: '198.51.100.4')

      refute_nil user, 'another address has its own budget'
    end
  end

  # An hour, counted from the entry — not "since the top of the hour", which
  # would let twice the limit through around every full hour.
  def test_what_is_older_than_an_hour_no_longer_counts
    with_db(@dir) do |db|
      PromptAtelier::Fixture.build(db)
      settings = { 'security.registration' => 'open', 'security.registrations_per_hour' => 1 }
      long_ago = Time.now - 3601

      register(db, settings, email: 'alt@example.test', ip: '203.0.113.9', now: long_ago)
      user = register(db, settings, email: 'neu@example.test', ip: '203.0.113.9')

      refute_nil user
    end
  end

  # Chosen at 3599 rather than at, say, half an hour: both readings of "an
  # hour" agree in the middle of the window and part company only at its edge.
  def test_what_is_inside_the_hour_still_counts
    with_db(@dir) do |db|
      PromptAtelier::Fixture.build(db)
      settings = { 'security.registration' => 'open', 'security.registrations_per_hour' => 1 }

      register(db, settings, email: 'alt@example.test', ip: '203.0.113.9', now: Time.now - 3599)

      assert_raises(PromptAtelier::Accounts::Refused) do
        register(db, settings, email: 'neu@example.test', ip: '203.0.113.9')
      end
    end
  end

  private

  def register(db, settings, email: 'neu@example.test', ip: '203.0.113.9', now: Time.now)
    Subject.register(db, name: 'Neu', email: email, password: 'Testpasswort-2026!',
                         config: settings, ip: ip, now: now)
  end
end
