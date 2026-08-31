# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'app'

# The log, and what protects it (FA-908, SEC-07, SEC-09).
#
# Two different worries meet here. The table is bounded by **time**, not by
# count, so nothing pushes an old entry out — but a hundred refused logins push
# every administrative entry out of *sight*, and refused attempts used to cost
# one row each at whatever rate an attacker could send.
class AuditTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  def app = PromptAtelier::App

  def setup
    super
    @dir = migrated_dir('audit')
    boot
    @ids = with_app_db { |db| PromptAtelier::Fixture.build(db) }
  end

  def teardown
    PromptAtelier::App.reset!
    PromptAtelier::RateLimit.reset!
    super
  end

  # --- FA-908: filtering ----------------------------------------------------

  def test_the_log_belongs_to_the_instance_administrator
    sign_in(:sabine)
    get "#{prefix}/admin/audit"

    assert_equal 403, last_response.status
  end

  def test_it_can_be_narrowed_to_one_person
    plant
    sign_in(:thomas)

    get "#{prefix}/admin/audit?actor_id=#{@ids[:users][:martin]}"

    assert_equal %w[workspace.created], entries.map { |entry| entry['action'] }.uniq
    assert_equal 1, meta['total']
  end

  def test_it_can_be_narrowed_to_one_kind_of_event
    plant
    sign_in(:thomas)

    get "#{prefix}/admin/audit?action=workspace.deleted"

    assert_equal 1, entries.size
    assert_equal 'workspace.deleted', entries.first['action']
  end

  # An unknown value is refused rather than ignored. A filter that quietly
  # falls back to "everything" cannot fail: the caller is shown the full list
  # and believes it is the narrowed one.
  def test_an_unknown_kind_of_event_is_refused_rather_than_ignored
    plant
    sign_in(:thomas)

    get "#{prefix}/admin/audit?action=workspace.exploded"

    assert_equal 422, last_response.status
    refute json.key?('entries')
  end

  def test_it_can_be_narrowed_to_a_period
    plant
    sign_in(:thomas)

    from = (Time.now - (3 * 86_400)).utc.iso8601
    get "#{prefix}/admin/audit?from=#{CGI.escape(from)}"

    actions = entries.map { |entry| entry['action'] }
    assert_includes actions, 'workspace.deleted', 'from today'
    refute_includes actions, 'workspace.renamed', 'ten days old, outside the period'
  end

  def test_the_upper_end_of_a_period_covers_the_whole_day_it_names
    sign_in(:thomas)
    day = Time.now.utc - (5 * 86_400)
    with_app_db do |db|
      db[:audit_logs].insert(action: 'workspace.created', actor_name: 'X',
                             created_at: Time.utc(day.year, day.month, day.day, 23, 30))
    end

    get "#{prefix}/admin/audit?action=workspace.created&to=#{day.strftime('%Y-%m-%d')}"

    assert_equal 1, entries.size,
                 '"up to the 5th" includes the evening of the 5th, not only its first instant'
  end

  def test_a_date_that_is_no_date_is_refused
    sign_in(:thomas)
    get "#{prefix}/admin/audit?from=irgendwann"

    assert_equal 422, last_response.status
  end

  # A screen showing a hundred of forty thousand must be able to say so, or
  # the filter looks as though it found everything there is.
  def test_the_answer_says_how_many_there_are_beside_the_page_it_returns
    sign_in(:thomas)
    with_app_db do |db|
      130.times { |n| db[:audit_logs].insert(action: 'workspace.created', actor_name: "A#{n}",
                                             created_at: Time.now) }
    end

    get "#{prefix}/admin/audit?action=workspace.created"

    assert_equal 50, entries.size, 'one page, the same size as every other list (15.3)'
    assert_equal 130, meta['total'], 'and the truth about the rest'
    assert_equal 1, meta['page']
  end

  # The half that was missing entirely: without it the newest page was all
  # anybody could reach, and older entries were only findable by guessing the
  # right day in the date filter.
  def test_the_second_page_carries_what_the_first_one_left_out
    sign_in(:thomas)
    with_app_db do |db|
      130.times { |n| db[:audit_logs].insert(action: 'workspace.created', actor_name: "A#{n}",
                                             created_at: Time.now) }
    end

    get "#{prefix}/admin/audit?action=workspace.created&per_page=50"
    first = entries.map { |entry| entry['id'] }

    get "#{prefix}/admin/audit?action=workspace.created&per_page=50&page=2"
    second = entries.map { |entry| entry['id'] }

    assert_equal 50, second.size
    assert_empty first & second, 'no entry appears on both pages'
    assert_operator first.last, :>, second.first, 'and the newest come first'
  end

  def test_the_last_page_is_short_and_not_wrapped_around
    sign_in(:thomas)
    with_app_db do |db|
      db[:audit_logs].delete
      7.times { |n| db[:audit_logs].insert(action: 'workspace.created', actor_name: "A#{n}",
                                           created_at: Time.now) }
    end

    get "#{prefix}/admin/audit?per_page=5&page=2"

    assert_equal 2, entries.size
    assert_equal 7, meta['total']
  end

  def test_the_screen_is_offered_every_kind_of_event_not_only_those_that_happened
    sign_in(:thomas)
    get "#{prefix}/admin/audit"

    assert_includes json['actions'], PromptAtelier::Audit::USER_APPROVED,
                    'a filter built from what is in the table would omit exactly ' \
                    'the entry a search is most likely aimed at'
  end

  # --- SEC-07: the flood ----------------------------------------------------

  # Up to the lockout every failure gets its own line; past it they are
  # counted into one. The threshold is not a new number — it is the moment an
  # attempt is refused before it is even checked, which is precisely when a
  # line of its own stops carrying anything new.
  def test_past_the_lockout_further_attempts_are_counted_rather_than_repeated
    5.times { failed_login('editor@test') }
    individual_before = failed_entries.size

    20.times { failed_login('editor@test') }

    assert_equal individual_before, failed_entries.size,
                 'not one more line for twenty further attempts'
    assert_equal 1, collapsed_entries.size, 'they went into a single entry'
    assert_equal 20, collapsed_meta['count'], 'and it says how many — that is its whole content'
  end

  # Falling silent would make an attacker with fifty thousand attempts look
  # exactly like a colleague who mistyped five times. Telling those two apart
  # is what the log is for.
  def test_the_count_is_what_distinguishes_a_burst_from_a_typo
    5.times { failed_login('editor@test') }
    3.times { failed_login('editor@test') }
    first = collapsed_meta['count']

    40.times { failed_login('editor@test') }

    assert_equal 3, first
    assert_equal 43, collapsed_meta['count']
    assert_operator collapsed_meta['last_at'], :>=, collapsed_meta['first_at']
  end

  # One attacker against five thousand accounts is one burst. Keyed per
  # account it would be five thousand collapsed entries — the very growth the
  # collapsing exists to stop.
  def test_a_spray_across_many_accounts_collapses_under_the_address
    boot(per_ip: 3)

    3.times { |n| failed_login("opfer#{n}@example.test") }
    30.times { |n| failed_login("opfer#{n}@example.test") }

    assert_equal 1, collapsed_entries.size
    assert_equal 'ip', collapsed_entries.first[:target_type]
    assert_equal 30, collapsed_meta['count']
  end

  # Two bursts from two addresses are two events. Merged into one entry the
  # log would say that one of them never happened.
  # Two bursts from two addresses are two events. Merged into one entry the
  # log would say that one of them never happened.
  #
  # A different account per address, and that is not decoration: with the same
  # one, the second burst would trip the **account** limit rather than the
  # address limit and land under a different key for a reason that has nothing
  # to do with what is being checked here.
  def test_two_addresses_do_not_share_one_collapsed_entry
    boot(per_ip: 3, trusted: ['127.0.0.1'])

    4.times { failed_login('eins@example.test', forwarded: '198.51.100.1') }
    4.times { failed_login('zwei@example.test', forwarded: '198.51.100.2') }

    keys = collapsed_entries.map { |row| JSON.parse(row[:meta_json])['key'] }
    assert_equal %w[198.51.100.1 198.51.100.2], keys.sort
  end

  # When both limits have taken hold, the address is the key — one attacker
  # against many accounts has to stay one entry.
  #
  # Both limits at three, and that is the only way to reach the case at all: a
  # refused attempt is **not** counted (it never reaches `record_attempt`), so
  # whichever limit trips first freezes both counters. They can only be over
  # together if they are crossed by the same attempt. With a single limit over,
  # either order would give the same answer and the case would prove nothing.
  def test_when_both_limits_bite_the_wider_bucket_is_the_key
    boot(per_ip: 3, per_account: 3)

    3.times { failed_login('editor@test') }
    with_app_db do |db|
      assert_equal 3, db[:login_attempts].where(ip: '127.0.0.1').count
      assert_equal 3, db[:login_attempts].where(email: 'editor@test').count,
                   'the premise: both limits are over, not just one'
    end

    5.times { failed_login('editor@test') }

    assert_equal 1, collapsed_entries.size
    assert_equal 'ip', collapsed_entries.first[:target_type]
  end

  # --- the forged address (SEC-07, SEC-09) ----------------------------------

  # The defect this replaces: `X-Forwarded-For` was believed from anybody, and
  # its **leftmost** entry — the part a caller writes themselves — was taken.
  # A different value per request left the per-address limit untouched for
  # ever. Different e-mail addresses here, so only the address limit can be
  # what stops it.
  def test_a_made_up_forwarding_header_does_not_buy_a_fresh_budget
    boot(per_ip: 3)

    4.times { |n| failed_login("fremd#{n}@example.test", forwarded: "198.51.100.#{n}") }

    assert_equal 'too_many_attempts', json['error']['code'],
                 'the address that counts is the socket, not the claim'
  end

  # And the other direction, so the case above is not merely asserting that
  # the header is dead code: behind a configured proxy it is evidence, and
  # each client behind it has its own budget.
  def test_behind_a_configured_proxy_the_header_counts
    boot(per_ip: 3, trusted: ['127.0.0.1'])

    4.times { |n| failed_login("fremd#{n}@example.test", forwarded: "198.51.100.#{n}") }

    assert_equal 'invalid_credentials', json['error']['code'],
                 'four different clients, one attempt each'
  end

  def test_the_address_in_the_log_is_the_one_that_really_called
    failed_login('editor@test', forwarded: '198.51.100.77')

    entry = failed_entries.last
    assert_equal '127.0.0.1', entry[:ip]
    refute_equal '198.51.100.77', entry[:ip],
                 'otherwise anybody could leave a colleague’s address in the log'
  end

  private

  def prefix = PromptAtelier::App::API_PREFIX
  def json = JSON.parse(last_response.body)
  def entries = json['entries']
  def meta = json['meta']
  def with_app_db(&block) = PromptAtelier::Database.open(database_path(@dir), &block)

  def boot(per_ip: 20, per_account: 5, trusted: [])
    PromptAtelier::App.reset!
    write_config(@dir, valid_config.merge(
                         'server' => valid_config['server'].merge('trusted_proxies' => trusted),
                         'security' => { 'login_attempts_per_ip' => per_ip,
                                         'login_attempts_per_account' => per_account }
                       ))
    PromptAtelier::App.boot!(root: @dir)
    PromptAtelier::RateLimit.reset!
  end

  def failed_entries
    with_app_db { |db| db[:audit_logs].where(action: PromptAtelier::Audit::LOGIN_FAILED).all }
  end

  def collapsed_entries
    with_app_db { |db| db[:audit_logs].where(action: PromptAtelier::Audit::LOGIN_FAILED_MANY).all }
  end

  def collapsed_meta = JSON.parse(collapsed_entries.first[:meta_json])

  def failed_login(email, forwarded: nil)
    env = { 'CONTENT_TYPE' => 'application/json' }
    env['HTTP_X_FORWARDED_FOR'] = forwarded if forwarded

    post "#{prefix}/auth/login", JSON.generate(email: email, password: 'falsch-falsch-falsch'), env
  end

  # A handful of entries whose person, kind and age differ, so each filter has
  # something it must leave out.
  def plant
    with_app_db do |db|
      db[:audit_logs].insert(actor_id: @ids[:users][:martin], actor_name: 'Martin',
                             action: 'workspace.created', created_at: Time.now)
      db[:audit_logs].insert(actor_id: @ids[:users][:thomas], actor_name: 'Thomas',
                             action: 'workspace.deleted', created_at: Time.now)
      db[:audit_logs].insert(actor_id: @ids[:users][:thomas], actor_name: 'Thomas',
                             action: 'workspace.renamed', created_at: Time.now - (10 * 86_400))
    end
  end

  def sign_in(person)
    clear_cookies
    post "#{prefix}/auth/login",
         JSON.generate(email: PromptAtelier::Fixture::PEOPLE[person][:email],
                       password: PromptAtelier::Fixture::PASSWORD),
         'CONTENT_TYPE' => 'application/json'
    assert_equal 200, last_response.status, "could not sign in as #{person}"
  end
end
