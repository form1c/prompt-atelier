# frozen_string_literal: true

require_relative '../../test_helper'

# The schema from Requirements 14.1 and the guarantees it is supposed to give.
#
# These are not "does the table exist" tests for their own sake. Each one
# stands for a rule from 14.2 that would otherwise only exist as a sentence in
# a document.
class SchemaTest < PromptAtelier::TestCase
  EXPECTED_TABLES = %i[
    users workspaces memberships prompts prompt_variables tags prompt_tags
    keywords prompt_keywords favorites prompt_revisions sessions audit_logs
    login_attempts schema_migrations
  ].freeze

  def setup
    super
    @dir = migrated_dir('schema')
  end

  # --- structure ----------------------------------------------------------

  def test_every_table_from_the_document_exists
    with_db(@dir) do |db|
      EXPECTED_TABLES.each { |table| assert db.table_exists?(table), "missing table: #{table}" }
    end
  end

  def test_the_fts_table_exists_and_mirrors_the_normalised_columns
    with_db(@dir) do |db|
      sql = db[:sqlite_master].where(name: 'prompts_fts').get(:sql)

      assert_includes sql, 'fts5'
      assert_includes sql, "content='prompts'"
      assert_includes sql, "content_rowid='id'"
      assert_includes sql, "prefix='2 3 4'"
      assert_includes sql, 'remove_diacritics 2'
      # The index must read the mirror columns, not the originals — that is
      # what makes a rebuild safe (14.1).
      assert_includes sql, 'title_norm'
      refute_match(/\btitle\b(?!_norm)/, sql.split('(', 2).last.split(',').first.to_s)
    end
  end

  def test_the_documented_indexes_exist
    with_db(@dir) do |db|
      names = db[:sqlite_master].where(type: 'index').select_map(:name).compact
      %w[idx_memberships_ws idx_prompts_ws idx_prompts_updated idx_prompts_owner
         idx_prompts_deleted idx_prompt_tags_tag idx_prompt_keywords_kw
         idx_revisions_prompt idx_sessions_user idx_audit_created
         idx_attempts_email idx_attempts_ip].each do |index|
        assert_includes names, index
      end
    end
  end

  # --- the three mandatory pragmas ---------------------------------------

  # Not "is it written in the code" but "is it in force on this connection".
  def test_foreign_keys_are_on
    with_db(@dir) do |db|
      assert_equal 1, PromptAtelier::Database.pragma(db, 'foreign_keys').to_i
    end
  end

  def test_journal_mode_is_wal
    with_db(@dir) do |db|
      assert_equal 'wal', PromptAtelier::Database.pragma(db, 'journal_mode').to_s.downcase
    end
  end

  # Deliberately not `PRAGMA busy_timeout`: installing a busy handler clears
  # that value, so it reads 0 here and always will. Asserting it would pin the
  # wrong thing — and did, before the behaviour below was ever measured.
  def test_a_busy_handler_is_installed_rather_than_the_blocking_pragma
    with_db(@dir) do |db|
      assert_equal 0, PromptAtelier::Database.pragma(db, 'busy_timeout').to_i,
                   'a non-zero value here means SQLite\'s own blocking handler is back'
    end
  end

  # Sequel opens further connections lazily. Setting the pragmas once after
  # connecting would leave those without foreign keys — silently, and only
  # under load.
  def test_pragmas_apply_to_every_connection_not_just_the_first
    with_db(@dir) do |db|
      results = 4.times.map do
        Thread.new { db.synchronize { |c| c.get_first_value('PRAGMA foreign_keys') } }
      end.map(&:value)

      assert_equal [1] * 4, results.map(&:to_i)
    end
  end

  # The test above asserts the *value* of busy_timeout. That is not the same
  # as the behaviour: SQLite lets exactly one writer through at a time, and
  # without an effective timeout the second one fails on the spot with
  # "database is locked". Two people saving a prompt in the same second is not
  # an exotic case in a shared library, and the failure would surface as a
  # 500 with no pattern anyone could reproduce.
  def test_a_second_writer_waits_instead_of_failing_at_once
    with_db(@dir) do |holder|
      workspace, owner = seed_owner(holder)

      second = Thread.new do
        sleep 0.05 # let the holder take the write lock first
        with_db(@dir) do |writer|
          insert_prompt(writer, workspace, owner, title: 'From the other side', body: 'x')
        end
      end

      holder.transaction(mode: :immediate) do
        insert_prompt(holder, workspace, owner, title: 'Holding the lock', body: 'x')
        sleep 0.3 # longer than the second writer is willing to wait for nothing
      end

      assert second.value, 'the second write must go through once the lock is free'
      assert_equal 2, holder[:prompts].count
    end
  end

  # The waiting must not cost the rest of the process its turn. SQLite's own
  # busy handler sleeps in C while holding Ruby's global lock: every other
  # thread stops, including the one holding the write lock, which then cannot
  # commit — so the waiter times out on a lock that was meant to be free long
  # ago. Measured before the fix: a holder that meant to release after 300 ms
  # got there after 5058 ms, and a thread doing nothing but reading was frozen
  # for 5057 ms.
  #
  # Puma serves requests in threads, so this is what two people saving at the
  # same moment would have done to the server.
  def test_a_blocked_writer_does_not_freeze_the_rest_of_the_process
    with_db(@dir) do |db|
      workspace, owner = seed_owner(db)
      started = Time.now
      elapsed = -> { ((Time.now - started) * 1000).round }
      reader_ticks = []

      reader = Thread.new do
        6.times do
          reader_ticks << elapsed.call
          db[:prompts].count
          sleep 0.05
        end
      end
      writer = Thread.new do
        sleep 0.05
        insert_prompt(db, workspace, owner, title: 'Second writer', body: 'x')
      end

      db.transaction(mode: :immediate) do
        insert_prompt(db, workspace, owner, title: 'Holds the lock', body: 'x')
        sleep 0.3
      end
      released = elapsed.call
      writer.join
      reader.join

      longest_pause = reader_ticks.each_cons(2).map { |a, b| b - a }.max
      assert_operator released, :<, 2000,
                      "the holder could not commit for #{released} ms — the process was starved"
      assert_operator longest_pause, :<, 2000,
                      "a plain read was blocked for #{longest_pause} ms by someone else waiting"
      assert_equal 2, db[:prompts].count
    end
  end

  # --- CHECK constraints (14.2) -------------------------------------------

  def test_check_constraints_reject_values_outside_the_documented_set
    with_db(@dir) do |db|
      workspace_id, user_id = seed_owner(db)
      now = Time.now

      assert_raises(Sequel::DatabaseError, 'prompts.visibility') do
        db[:prompts].insert(workspace_id: workspace_id, owner_id: user_id, title: 't',
                            body: 'b', visibility: 'oeffentlich',
                            created_at: now, updated_at: now)
      end

      assert_raises(Sequel::DatabaseError, 'prompts.status') do
        db[:prompts].insert(workspace_id: workspace_id, owner_id: user_id, title: 't',
                            body: 'b', status: 'freigegeben',
                            created_at: now, updated_at: now)
      end

      assert_raises(Sequel::DatabaseError, 'memberships.role') do
        db[:memberships].insert(user_id: user_id, workspace_id: workspace_id,
                                role: 'chef', created_at: now)
      end

      assert_raises(Sequel::DatabaseError, 'users.status') do
        db[:users].insert(email: 'x@y.test', name: 'X', password_hash: 'h',
                          status: 'ruhend', created_at: now, updated_at: now)
      end
    end
  end

  def test_email_is_unique_regardless_of_case
    with_db(@dir) do |db|
      now = Time.now
      db[:users].insert(email: 'Anna@Example.test', name: 'Anna', password_hash: 'h',
                        created_at: now, updated_at: now)

      assert_raises(Sequel::UniqueConstraintViolation) do
        db[:users].insert(email: 'anna@example.TEST', name: 'Zweite', password_hash: 'h',
                          created_at: now, updated_at: now)
      end
    end
  end

  # --- foreign keys (14.2) ------------------------------------------------

  def test_deleting_a_workspace_removes_its_contents
    with_db(@dir) do |db|
      workspace_id, user_id = seed_owner(db)
      insert_prompt(db, workspace_id, user_id, title: 'Eins', body: 'Text')

      db[:workspaces].where(id: workspace_id).delete

      assert_equal 0, db[:prompts].count
    end
  end

  # 14.2: deleting a user must NOT take their prompts with them.
  def test_deleting_a_user_is_refused_while_prompts_remain
    with_db(@dir) do |db|
      workspace_id, user_id = seed_owner(db)
      insert_prompt(db, workspace_id, user_id, title: 'Eins', body: 'Text')

      assert_raises(Sequel::ForeignKeyConstraintViolation) do
        db[:users].where(id: user_id).delete
      end
    end
  end
end
