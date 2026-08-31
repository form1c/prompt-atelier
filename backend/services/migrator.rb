# frozen_string_literal: true

require_relative 'database'
require_relative 'migration'
require_relative 'backup'
require_relative 'i18n'

module PromptAtelier
  # Applies schema steps (Requirements 18.9).
  #
  #   1. compare the database against the shipped migrations
  #   2. if anything is pending: create a backup FIRST — not optional
  #   3. run the pending steps in one transaction, ascending by version
  #   4. on error: full rollback, the backup stays, abort naming the step
  #   5. on success: record the new state and report what ran
  #
  # Step 2 is the one that must not be skipped for convenience. A migration
  # that goes wrong without a backup taken beforehand leaves no way back, and
  # that is precisely the situation in which one is needed.
  class Migrator
    class Error < StandardError
      attr_reader :version, :backup_path

      def initialize(message, version: nil, backup_path: nil)
        @version     = version
        @backup_path = backup_path
        super(message)
      end
    end

    Result = Struct.new(:applied, :backup_path, :already_current, keyword_init: true) do
      def nothing_to_do? = applied.empty?
    end

    attr_reader :database_path, :migrations_dir, :backup_dir

    def initialize(database_path:, migrations_dir:, backup_dir:)
      @database_path  = database_path
      @migrations_dir = migrations_dir
      @backup_dir     = backup_dir
    end

    # Everything the shipped code knows about.
    def available
      @available ||= Migration.all(migrations_dir)
    end

    def available_versions = available.map(&:version)

    # What the database says has been applied. An empty or absent database
    # counts as "nothing applied" rather than an error — that is the normal
    # state before the first run.
    def applied_versions
      return [] unless File.exist?(database_path)

      Database.open(database_path) do |db|
        next [] unless db.table_exists?(:schema_migrations)

        db[:schema_migrations].order(:version).select_map(:version)
      end
    end

    def pending
      done = applied_versions
      available.reject { |m| done.include?(m.version) }
    end

    # Steps the database has but the code does not know — the database is
    # newer than the application (TF-624, TF-431).
    def unknown_applied
      applied_versions - available_versions
    end

    def run
      steps = pending

      # No backup when there is nothing to do (TF-622). A backup on every
      # start would fill the disk and hide the ones that matter.
      return Result.new(applied: [], backup_path: nil, already_current: true) if steps.empty?

      backup_path = File.exist?(database_path) ? create_backup : nil

      Database.open(database_path) do |db|
        # One connection for the whole run. The pragma below is per connection
        # and must be set on the very one the transaction then uses; Sequel
        # hands the same connection to every synchronize in this thread.
        db.synchronize do |conn|
          run_steps(db, conn, steps, backup_path)
        end
      end

      Result.new(applied: steps.map(&:version), backup_path: backup_path, already_current: false)
    end

    private

    # **Why foreign keys are switched off around the transaction and not
    # inside it.**
    #
    # A step that changes a `CHECK` constraint has to rebuild its table —
    # SQLite cannot alter one. The rebuild drops the old table, and with
    # foreign keys on, `DROP TABLE` performs an implicit delete that fires
    # `ON DELETE CASCADE`. Measured on this schema: dropping `prompts` runs
    # through and leaves `prompt_variables`, `prompt_revisions`,
    # `prompt_tags` and `favorites` empty — **without an error**, because a
    # cascade is not a violation. The same measurement showed `PRAGMA
    # foreign_keys` inside a transaction is silently ignored (it still reads 1
    # afterwards), and that `defer_foreign_keys` defers the *check*, not the
    # *actions*.
    #
    # So the pragma is set here, before the transaction opens, and only when a
    # step asks for it. The price is that nothing is enforced while the steps
    # run, which is why `PRAGMA foreign_key_check` follows inside the
    # transaction: a genuine orphan then still rolls the whole run back.
    def run_steps(db, conn, steps, backup_path)
      relaxed = steps.any?(&:foreign_keys_off?)
      conn.execute('PRAGMA foreign_keys = OFF') if relaxed

      db.transaction do
        steps.each { |step| apply(db, step, backup_path) }
        verify_references(db, steps, backup_path) if relaxed
      end
    ensure
      # Back on for every later user of this connection — it returns to the
      # pool, and a connection without foreign keys would break R-06 quietly.
      conn.execute('PRAGMA foreign_keys = ON') if relaxed
    end

    def verify_references(db, steps, backup_path)
      broken = db.fetch('PRAGMA foreign_key_check').all
      return if broken.empty?

      raise Error.new(
        "Migration #{steps.last.version} hinterlässt #{broken.length} verwaiste Verweise " \
        "(zuerst: #{broken.first.inspect})",
        version: steps.last.version,
        backup_path: backup_path
      )
    end

    def create_backup
      # English like every other identifier and file name. The former German
      # label is still recognised by the rotation in scripts/lib/backup.rb, so
      # a backup taken before the rename does not become a file that rotation
      # deletes.
      Backup.create(database_path, backup_dir, label: 'before-migration')
    rescue Backup::Error => e
      raise Error, "Backup vor der Migration fehlgeschlagen: #{e.message}"
    end

    def apply(db, step, backup_path)
      execute_script(db, step.sql)
      db[:schema_migrations].insert(version: step.version, applied_at: Time.now)
    rescue Sequel::DatabaseError, SQLite3::Exception => e
      raise Error.new(
        "Migration #{step.version} fehlgeschlagen: #{e.message}",
        version: step.version,
        backup_path: backup_path
      )
    end

    # A migration is a script of several statements, and trigger bodies
    # contain semicolons. Splitting on ';' would tear them apart, so the
    # statement boundaries are left to SQLite itself via execute_batch.
    def execute_script(db, sql)
      db.synchronize { |conn| conn.execute_batch(sql) }
    end
  end
end
