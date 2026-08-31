# frozen_string_literal: true

# scripts/lib/migrate.rb — apply schema steps (18.5, 18.9, BT-09)
#
# Sequence, in this order and not another:
#
#   1. compare the database against the shipped migrations
#   2. nothing pending -> say so and stop, without creating a backup
#   3. something pending -> create a backup BEFORE touching anything
#   4. run the steps in one transaction
#   5. on error -> full rollback, the backup stays, name the failing step
#
# Step 3 is not optional and has no switch to turn it off. A migration that
# goes wrong without a backup taken beforehand leaves no way back, and that is
# exactly the situation in which one is wanted.

require_relative 'common'

module PromptAtelier
  module Migrate
    extend Script

    module_function

    def run(argv = [])
      status_only = argv.include?('--status')

      activate_gems!
      require File.join(app_dir, 'services', 'configuration')
      require File.join(app_dir, 'services', 'migrator')

      config = Configuration.load(root: root)
      I18n.default_language = config['locale']

      migrator = Migrator.new(
        database_path:  config.database_path,
        migrations_dir: File.join(app_dir, 'migrations'),
        backup_dir:     File.join(File.dirname(config.database_path), 'backups')
      )

      heading(t('migrate.title'))
      say(t('migrate.database', path: config.database_path))

      report_state(migrator)
      return 0 if status_only

      newer = migrator.unknown_applied
      unless newer.empty?
        bad(t('migrate.database_newer', versions: newer.join(', ')))
        return 1
      end

      apply(migrator)
    rescue Configuration::Error => e
      puts
      e.problems.each { |line| bad(line) }
      1
    end

    def report_state(migrator)
      applied = migrator.applied_versions
      pending = migrator.pending.map(&:version)

      say(t('migrate.applied', count: applied.size,
                               versions: applied.empty? ? '—' : applied.join(', ')))
      say(t('migrate.pending', count: pending.size,
                               versions: pending.empty? ? '—' : pending.join(', ')))
    end

    def apply(migrator)
      result = migrator.run

      if result.nothing_to_do?
        puts
        ok(t('migrate.nothing_to_do'))
        return 0
      end

      puts
      ok(t('migrate.backup_created', path: result.backup_path)) if result.backup_path
      result.applied.each { |version| ok(t('migrate.step_applied', version: version)) }
      ok(t('migrate.done', count: result.applied.size))
      0
    rescue Migrator::Error => e
      puts
      bad(e.message)
      say(t('migrate.rolled_back'))
      say(t('migrate.backup_kept', path: e.backup_path)) if e.backup_path
      1
    end
  end
end

exit PromptAtelier::Migrate.run(ARGV) if $PROGRAM_NAME == __FILE__
