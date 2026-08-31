# frozen_string_literal: true

# scripts/lib/import_all.rb — fill a fresh instance from an export (18.5, FA-804a)
#
# Into an **empty** instance only. Merging into one that is in use asks
# questions no script can answer — is "Marketing" here the same workspace as
# there, is the same address the same person? That is what the per-workspace
# import is for (FA-802), and there a human stands next to it.
#
# Accounts arrive **without** a password. Each gets a one-time password that
# this script prints once and stores nowhere in readable form, exactly as
# FA-901 does it. A file that carried credentials would be copied around and
# stay on three laptops.

require 'json'
require_relative 'common'

module PromptAtelier
  module ImportAll
    extend Script

    module_function

    def run(argv = [])
      source = argv.find { |argument| !argument.start_with?('--') }
      if source.nil?
        bad(t('relocate.import_usage'))
        return 1
      end

      activate_gems!
      require File.join(app_dir, 'services', 'configuration')
      require File.join(app_dir, 'services', 'database')
      require File.join(app_dir, 'services', 'relocation')

      config = Configuration.load(root: root)
      heading(t('relocate.import_title'))

      package = read(source)
      return 1 if package.nil?

      Database.open(config.database_path) do |db|
        created = Relocation.import(db, package, actor_name: 'import_all')
        report(created)
      end
      0
    rescue Relocation::Refused => e
      bad(t("relocate.#{e.message}"))
      1
    rescue Configuration::Error => e
      puts
      e.problems.each { |line| bad(line) }
      1
    end

    def read(source)
      JSON.parse(File.read(File.expand_path(source), encoding: 'UTF-8'))
    rescue Errno::ENOENT
      bad(t('relocate.not_found', path: source))
      nil
    rescue JSON::ParserError => e
      bad(t('relocate.unreadable', reason: e.message.lines.first.to_s.strip))
      nil
    end

    # Printed once, in a block that is meant to be copied out of the terminal
    # before it scrolls away. There is no second chance: the passwords exist
    # in readable form only here.
    def report(created)
      ok(t('relocate.imported', count: created.size))
      puts
      say(t('relocate.passwords_once'))
      created.each { |entry| say(format('  %-40s %s', entry['email'], entry['password'])) }
      puts
      say(t('relocate.passwords_change'))
    end
  end
end

exit PromptAtelier::ImportAll.run(ARGV) if $PROGRAM_NAME == __FILE__
