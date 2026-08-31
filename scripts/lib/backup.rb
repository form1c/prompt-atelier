# frozen_string_literal: true

# scripts/lib/backup.rb — a consistent copy while the application runs
# (18.5, 18.10, BT-11, NFA-12)
#
# **Copying the database file is not a backup.** In WAL mode the most recent
# changes live in a side file, so a copy of the `.db` alone is unusable or —
# worse — silently incomplete. It even passes `PRAGMA integrity_check`, which
# means the loss is discovered on the day somebody needs the backup.
# `VACUUM INTO` writes one complete, consistent file instead, without stopping
# anything.
#
# Written, then **read back**. A backup nobody has verified is a guess, and
# the moment to find out is now rather than during a restore.

require 'fileutils'
require_relative 'common'

module PromptAtelier
  module BackupScript
    extend Script

    # The name the delivered backups carry (18.10). Anything else in the
    # directory belongs to somebody else and is left alone.
    LABEL = 'promptatelier'

    # Backups `migrate` took before a schema change. They are excluded from
    # rotation on purpose: the reason to keep one is the schema change, not
    # its age, and the day an update goes wrong is the day it is wanted.
    #
    # The former German label is still recognised — a rename of the product
    # must not turn yesterday's safety net into a file that rotation deletes.
    MIGRATION_LABELS = %w[before-migration vor-migration].freeze

    module_function

    def run(argv = [])
      activate_gems!
      require File.join(app_dir, 'services', 'configuration')
      require File.join(app_dir, 'services', 'backup')

      config = Configuration.load(root: root)
      heading(t('backup.title'))

      directory = File.join(File.dirname(config.database_path), 'backups')
      path = create(config, directory)
      return 1 if path.nil?

      rotate(directory, keep: config['backup.keep'].to_i) unless argv.include?('--no-rotate')
      0
    rescue Configuration::Error => e
      puts
      e.problems.each { |line| bad(line) }
      1
    end

    def create(config, directory)
      path = Backup.create(config.database_path, directory, label: LABEL)

      # Verified before it is announced. Announcing first and checking after
      # would leave a line on the screen saying a backup exists when it does
      # not (BT-11).
      unless Backup.usable?(path)
        FileUtils.rm_f(path)
        bad(t('backup.unusable'))
        return nil
      end

      ok(t('backup.created', path: path, size: human_size(File.size(path))))
      path
    rescue Backup::Error => e
      bad(t('backup.failed', reason: e.message))
      nil
    end

    # Keeps the newest +keep+ of **our own** backups. Everything else in the
    # directory — the migration backups, somebody's manual copy — is none of
    # this script's business.
    def rotate(directory, keep:)
      return if keep <= 0

      own = Dir.glob(File.join(directory, "#{LABEL}-*.db")).sort
      surplus = own.size - keep
      return if surplus <= 0

      own.first(surplus).each { |path| FileUtils.rm_f(path) }
      note(t('backup.rotated', count: surplus, keep: keep))
    end

    def human_size(bytes)
      return "#{bytes} B" if bytes < 1024
      return format('%.1f kB', bytes / 1024.0) if bytes < 1024 * 1024

      format('%.1f MB', bytes / (1024.0 * 1024))
    end
  end
end

exit PromptAtelier::BackupScript.run(ARGV) if $PROGRAM_NAME == __FILE__
