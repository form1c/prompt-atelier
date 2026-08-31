# frozen_string_literal: true

require 'fileutils'
require_relative 'database'

module PromptAtelier
  # Creating a consistent backup while the application is running (NFA-12).
  #
  # A plain file copy of promptatelier.db is NOT a backup. The database runs
  # in WAL mode, so the most recent changes live in a side file; a copy of the
  # .db alone is unusable or — worse — silently incomplete. It even passes
  # PRAGMA integrity_check, so the loss is only discovered when the backup is
  # needed. VACUUM INTO writes one complete, consistent file instead.
  #
  # AP-15 adds rotation, the `backup` script and restore. What is here is the
  # part `migrate` needs: one command, one file.
  module Backup
    class Error < StandardError; end

    # VACUUM cannot run inside a transaction.
    class << self
      # Writes a backup of +database_path+ into +directory+ and returns its
      # path. +label+ becomes part of the file name so the reason is visible
      # in a directory listing.
      def create(database_path, directory, label: 'backup', now: Time.now)
        raise Error, "Database not found: #{database_path}" unless File.exist?(database_path)

        FileUtils.mkdir_p(directory)
        target = File.join(directory, file_name(label, now))
        raise Error, "Backup already exists: #{target}" if File.exist?(target)

        Database.open(database_path) do |db|
          # Sequel quotes the string properly; the path may contain spaces.
          db.run("VACUUM INTO #{db.literal(target)}")
        end

        raise Error, "Backup was not written: #{target}" unless File.exist?(target)

        target
      end

      def file_name(label, now)
        "#{label}-#{now.strftime('%Y%m%d-%H%M%S')}.db"
      end

      # Reads a backup and confirms it can be opened and queried. A backup
      # that has never been verified is a guess.
      def usable?(path)
        Database.open(path, wal: false) do |db|
          db.fetch('PRAGMA integrity_check').single_value == 'ok' &&
            db.fetch("SELECT count(*) AS c FROM sqlite_master WHERE type = 'table'").first[:c].positive?
        end
      rescue StandardError
        false
      end
    end
  end
end
