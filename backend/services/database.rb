# frozen_string_literal: true

require 'sequel'
require 'fileutils'

module PromptAtelier
  # Database connection (Requirements 14.1, 18.4).
  #
  # Every connection sets three pragmas. They are not tuning knobs — the
  # schema assumes them, and SQLite behaves differently without them:
  #
  #   foreign_keys = ON   OFF by default. Without it no ON DELETE CASCADE
  #                       fires and no foreign key is checked at all. Deleting
  #                       a tag would leave its row in prompt_tags, the delete
  #                       trigger would never run, and tags_text would keep a
  #                       tag that no longer exists (R-06).
  #   journal_mode = WAL  Readers do not block the writer (R-03), and it is the
  #                       reason a plain file copy is not a valid backup.
  #
  # journal_mode is persistent in the database file, foreign_keys is per
  # connection and must be set every time.
  #
  # Waiting for a busy database is deliberately NOT done with
  # `PRAGMA busy_timeout`. That installs SQLite's own busy handler, which
  # sleeps inside C without giving up Ruby's global lock. Measured: while one
  # thread waits there, the whole process stops — including the thread holding
  # the write lock, which then cannot commit and release it. Two people saving
  # at the same moment froze the server for the full five seconds and one save
  # failed anyway. The gem's busy_handler_timeout= installs a handler that
  # releases the lock while it waits; the same case then finishes in 302 ms
  # with both writes through. Puma serves requests in threads, so this is the
  # normal case, not an exotic one.
  module Database
    # Timestamps are written and read as UTC (TF-427, migration 002).
    #
    # SQLite has no time type; it stores whatever string it is handed. Without
    # this line Sequel hands it the server's local time with no offset beside
    # it — a value that is ambiguous during the autumn clock change and that
    # every later reader interprets with whatever time zone the machine
    # happens to have. UTC has neither problem, and the offset for the display
    # belongs to the browser anyway (11.6).
    #
    # Set on the Sequel module rather than per connection: it governs the
    # typecast on the way in as well as on the way out, and a connection that
    # disagreed with the others would write rows nobody can read back
    # correctly.
    Sequel.default_timezone = :utc

    PRAGMAS = { foreign_keys: 'ON' }.freeze

    # How long a second writer waits for the first to finish (R-03).
    BUSY_TIMEOUT_MS = 5000

    class << self
      # Opens a connection. +path+ is absolute; the directory is created if
      # missing, so a fresh installation does not need a separate step.
      def connect(path, wal: true)
        FileUtils.mkdir_p(File.dirname(path))

        db = Sequel.connect(
          adapter: 'sqlite',
          database: path,
          # Applied to every connection Sequel opens, including the extra ones
          # a thread pool creates later. Setting them once after connect would
          # leave those without foreign keys — silently.
          after_connect: proc { |conn| apply_pragmas(conn, wal: wal) }
        )
        db.extension(:connection_validator) if db.respond_to?(:extension)
        db
      end

      # Opens a connection, yields it and always closes it again. For scripts
      # and tests, which must not leave a file handle behind — on Windows an
      # open handle prevents the file from being replaced or removed.
      def open(path, wal: true)
        db = connect(path, wal: wal)
        yield db
      ensure
        db&.disconnect
      end

      def apply_pragmas(conn, wal: true)
        # journal_mode is stored in the file itself; setting it on an
        # in-memory database or on every connection is harmless but pointless,
        # so it is skipped when disabled (tests that want the simpler rollback
        # semantics of the default journal).
        conn.execute('PRAGMA journal_mode = WAL') if wal
        PRAGMAS.each { |name, value| conn.execute("PRAGMA #{name} = #{value}") }

        # Must come last and must stay the only way the timeout is set:
        # installing a handler clears any `PRAGMA busy_timeout`, and setting
        # that pragma afterwards would put SQLite's blocking handler back and
        # undo the fix. Verified — `PRAGMA busy_timeout` reads 0 after this
        # line, which is why the tests assert the behaviour, not the value.
        conn.busy_handler_timeout = BUSY_TIMEOUT_MS
      end

      # Reads a pragma back. Used by the tests that prove the settings are
      # actually in force rather than merely written down.
      def pragma(db, name)
        db.fetch("PRAGMA #{name}").single_value
      end
    end
  end
end
