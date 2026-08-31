# frozen_string_literal: true

# scripts/lib/restore.rb — put a backup back (18.5, 18.10, BT-12)
#
# This is the one script that destroys data on purpose, so three things are
# not optional:
#
#   1. **The backup is checked before anything is overwritten.** Restoring a
#      damaged file over a working database would turn one problem into two,
#      and the second one has no way back.
#   2. **The current state is backed up first.** Whoever restores yesterday
#      usually finds out an hour later that today held something they wanted.
#   3. **The confirmation is the file name**, typed out. A y/n prompt is
#      answered by reflex; a name has to be read first.
#
# The service is not stopped from here. Overwriting the file under a running
# instance would leave it holding a handle on a database that no longer
# exists, so the script says which command to run and refuses while the port
# still answers.

require 'fileutils'
require 'socket'
require_relative 'common'

module PromptAtelier
  module Restore
    extend Script

    module_function

    def run(argv = [])
      source = argv.find { |argument| !argument.start_with?('--') }
      activate_gems!
      require File.join(app_dir, 'services', 'configuration')
      require File.join(app_dir, 'services', 'backup')

      config = Configuration.load(root: root)
      heading(t('restore.title'))

      return list(config) if source.nil?

      path = File.expand_path(source, File.join(File.dirname(config.database_path), 'backups'))
      perform(config, path, confirmed: argv.include?('--yes'))
    rescue Configuration::Error => e
      puts
      e.problems.each { |line| bad(line) }
      1
    end

    # Without an argument the script does the useful half of nothing: it says
    # what there is to restore. Failing with "argument missing" would send
    # somebody to a directory listing they can get from here.
    def list(config)
      directory = File.join(File.dirname(config.database_path), 'backups')
      files = Dir.glob(File.join(directory, '*.db')).sort.reverse

      if files.empty?
        bad(t('restore.none', path: directory))
        return 1
      end

      say(t('restore.available'))
      files.first(15).each { |file| say("  #{File.basename(file)}") }
      say(t('restore.usage'))
      1
    end

    def perform(config, path, confirmed:)
      unless File.file?(path)
        bad(t('restore.not_found', path: path))
        return 1
      end

      # Checked **before** anything is touched. A damaged backup restored over
      # a working database is the one outcome with no way back.
      unless Backup.usable?(path)
        bad(t('restore.damaged', path: path))
        return 1
      end

      return 1 if running?(config)
      return 1 unless confirmed || confirm(path)

      safety = safety_copy(config)
      replace(config, path)

      ok(t('restore.done', path: path))
      say(t('restore.safety', path: safety)) if safety
      0
    end

    # A restore under a running instance leaves it holding a handle on a
    # database that no longer exists — and it would keep writing to it.
    def running?(config)
      TCPSocket.new(config['server.host'], config['server.port']).close
      bad(t('restore.still_running', port: config['server.port']))
      true
    rescue StandardError
      false
    end

    def confirm(path)
      name = File.basename(path)
      unless $stdin.tty?
        bad(t('restore.needs_confirmation', name: name))
        return false
      end

      print("   #{t('restore.ask_confirm', name: name)} ")
      answer = $stdin.gets&.strip
      return true if answer == name

      bad(t('restore.not_confirmed'))
      false
    end

    # The state that is about to be overwritten. Labelled so a directory
    # listing says why it exists.
    def safety_copy(config)
      return nil unless File.file?(config.database_path)

      Backup.create(config.database_path,
                    File.join(File.dirname(config.database_path), 'backups'),
                    label: 'before-restore')
    rescue Backup::Error
      nil
    end

    # The WAL and the shared-memory file belong to the **old** database. Left
    # behind, SQLite would try to replay them onto the restored one — the
    # restore would silently be a mixture of two states.
    def replace(config, path)
      %w[-wal -shm].each { |suffix| FileUtils.rm_f("#{config.database_path}#{suffix}") }
      FileUtils.cp(path, config.database_path)
    end
  end
end

exit PromptAtelier::Restore.run(ARGV) if $PROGRAM_NAME == __FILE__
