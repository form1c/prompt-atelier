# frozen_string_literal: true

# scripts/lib/export_all.rb — take a whole instance out (18.5, FA-804a)
#
# A script and not a button, and that is the point. An instance administrator
# reads no foreign prompt content (6.2); a control that handed him everything
# would undo that promise more quietly than any other route. Running this
# needs access to the machine — which anybody who could read the database
# already has.
#
# The file carries **no password hashes** (see services/relocation.rb). For a
# complete, exact copy of an instance there is `backup`; this is the format
# for moving to another one.

require 'json'
require_relative 'common'

module PromptAtelier
  module ExportAll
    extend Script

    module_function

    def run(argv = [])
      activate_gems!
      require File.join(app_dir, 'services', 'configuration')
      require File.join(app_dir, 'services', 'database')
      require File.join(app_dir, 'services', 'relocation')

      config = Configuration.load(root: root)
      heading(t('relocate.export_title'))

      target = target_path(argv, config)
      Database.open(config.database_path) do |db|
        package = Relocation.export(db)
        File.write(target, JSON.pretty_generate(package))

        ok(t('relocate.exported', path: target,
                                  users: package['users'].size,
                                  workspaces: package['workspaces'].size))
      end
      say(t('relocate.export_note'))
      0
    rescue Configuration::Error => e
      puts
      e.problems.each { |line| bad(line) }
      1
    end

    def target_path(argv, config)
      named = argv.find { |argument| !argument.start_with?('--') }
      return File.expand_path(named) if named

      File.join(File.dirname(config.database_path),
                "instance-#{Time.now.strftime('%Y%m%d-%H%M%S')}.json")
    end
  end
end

exit PromptAtelier::ExportAll.run(ARGV) if $PROGRAM_NAME == __FILE__
