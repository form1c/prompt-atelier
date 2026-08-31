# frozen_string_literal: true

# scripts/lib/seed_demo.rb — example data for a development installation
#
# Written for NT-3: the core workflow W-1 is to be tried against a realistic
# stock, and "find a particular prompt among about fifty" says nothing with
# six of them. The prompts come from examples/examples.json, the sample
# package the delivery carries anyway (BT-17, FA-802) — so this script needs
# no data of its own and the package gets exercised long before the import of
# AP-14 exists.
#
# **This one writes into the installation it is started from.** Every other
# script in this directory leaves the developer's database alone, and the test
# suites go out of their way to; this one is meant to change it, which is why
# it says which file it is about to touch and asks before doing it.
#
# Everything it creates is marked and can be taken back:
#
#   seed_demo             puts the package into the workspace "Beispiele"
#   seed_demo --remove    deletes exactly what it put there
#
# Nothing outside that workspace is ever touched.

require 'json'
require_relative 'common'

module PromptAtelier
  module SeedDemo
    extend Script

    # Every prompt from the package carries this tag in addition to its own.
    # It is what --remove goes by: a title could have been changed, a tag that
    # nobody else uses could not have been added by accident.
    MARKER = 'beispiel'

    module_function

    def run(argv = [])
      options = parse(argv)

      activate_gems!
      require File.join(app_dir, 'services', 'configuration')
      require File.join(app_dir, 'services', 'database')
      require File.join(app_dir, 'services', 'migrator')
      require File.join(app_dir, 'services', 'prompts')
      require File.join(app_dir, 'services', 'catalog')
      require File.join(app_dir, 'services', 'workspaces')
      require File.join(app_dir, 'services', 'transfer')

      config = Configuration.load(root: root)
      I18n.default_language = config['locale']

      heading(t('seed.title'))
      say(t('seed.database', path: config.database_path))

      return 1 unless usable?(config)

      package = load_package
      return 1 if package.nil?

      Database.open(config.database_path) do |db|
        return 1 unless schema_current?(db)

        owner = account(db, options[:email])
        return 1 if owner.nil?

        workspace_name = options[:workspace] || package['workspace_name']
        options[:remove] ? remove(db, workspace_name) : add(db, package, owner, workspace_name, options)
      end
    rescue Configuration::Error => e
      puts
      e.problems.each { |line| bad(line) }
      1
    end

    # --- adding ------------------------------------------------------------

    # The writing itself is `Transfer.import` — the same code path a person
    # takes on the import screen (FA-802). It used to be a second
    # implementation here, and the two agreed only by coincidence: both
    # skipped an existing title, both reused an existing keyword. Two
    # implementations that agree today are two that can part tomorrow, and the
    # one nobody exercises is this one.
    #
    # What stays here is what is peculiar to seeding, and it is expressed as a
    # change to the **package** rather than as options on the import: every
    # prompt gets the marker tag that `--remove` goes by, and the two fields
    # the example package leaves open are filled in the way a demo wants them
    # (visible in the workspace, not a draft). The import keeps knowing only
    # about the format.
    def add(db, package, owner, workspace_name, options)
      workspace_id = workspace_for(db, owner, workspace_name)
      say(t('seed.workspace', name: workspace_name))
      say(t('seed.account', email: owner[:email]))

      return 1 unless confirmed?(options)

      report = Transfer.import(db, workspace_id: workspace_id, owner_id: owner[:id],
                                   package: marked(package))

      puts
      ok(t('seed.created', count: report['created'].size, workspace: workspace_name))
      note(t('seed.skipped', count: report['skipped'].size)) if report['skipped'].any?
      say(t('seed.hint_remove'))
      0
    end

    # A collision without a decision is skipped (FA-802), which is exactly what
    # this script wants: running it twice must not double the stock, and must
    # not overwrite anything either — by then it may have been edited on
    # purpose.
    def marked(package)
      prompts = package['prompts'].map do |prompt|
        prompt.merge(
          'tags' => (Array(prompt['tags']) + [MARKER]).uniq,
          'visibility' => prompt['visibility'] || 'workspace',
          'status' => prompt['status'] || 'active'
        )
      end

      package.merge('prompts' => prompts)
    end

    # --- removing ----------------------------------------------------------

    def remove(db, workspace_name)
      workspace = db[:workspaces].first(name: workspace_name)
      tag = workspace && db[:tags].first(workspace_id: workspace[:id], name: MARKER)

      if tag.nil?
        note(t('seed.nothing_to_remove', workspace: workspace_name))
        return 0
      end

      ids = db[:prompt_tags].where(tag_id: tag[:id]).select_map(:prompt_id)
      # Deleted outright rather than moved to the trash: this is stock for
      # trying things out, and a trash full of it would be in the way of the
      # one test case that is about the trash.
      db[:prompts].where(id: ids).delete

      keywords = remove_unused(db, :keywords, workspace[:id], keyword_names, :keyword_id, :prompt_keywords)
      tags = remove_unused(db, :tags, workspace[:id], tag_names, :tag_id, :prompt_tags)

      puts
      ok(t('seed.removed', count: ids.size, workspace: workspace_name))
      note(t('seed.removed_labels', keywords: keywords, tags: tags)) if (keywords + tags).positive?
      # The workspace itself stays. Deleting one takes its name as
      # confirmation for a reason (FA-606), and by now it may hold prompts
      # that were never part of the package.
      0
    end

    # The labels the package brought along — but only those nothing uses any
    # more. One that has meanwhile been put on somebody's own prompt stays:
    # removing a keyword would silently change what that prompt renders, and
    # removing a tag would take it off a prompt that is not ours to change
    # (TF-406).
    def remove_unused(db, table, workspace_id, names, foreign_key, join_table)
      return 0 if names.empty?

      candidates = db[table].where(workspace_id: workspace_id, name: names).select_map(:id)
      in_use = db[join_table].where(foreign_key => candidates).select_map(foreign_key).uniq

      db[table].where(id: candidates - in_use).delete
    end

    def keyword_names
      Array(load_package&.dig('keywords')).map { |keyword| keyword['name'] }
    end

    def tag_names
      (Array(load_package&.fetch('prompts', nil)).flat_map { |prompt| Array(prompt['tags']) } + [MARKER]).uniq
    end

    # --- surroundings ------------------------------------------------------

    def load_package
      path = File.join(root, 'examples', 'examples.json')
      unless File.file?(path)
        bad(t('seed.package_missing', path: path))
        return nil
      end

      # Through the importer's own reader, so a damaged package is refused
      # here for the same reason and with the same wording it would be on the
      # import screen — and never half-written.
      Transfer.parse(File.read(path, encoding: 'UTF-8'))
    rescue Transfer::Refused => e
      bad(t('seed.package_broken', path: path, reason: e.code.to_s))
      nil
    end

    def usable?(config)
      return true if File.file?(config.database_path)

      bad(t('seed.no_database', path: config.database_path))
      false
    end

    def schema_current?(db)
      pending = Migrator.new(database_path: db.opts[:database],
                             migrations_dir: File.join(app_dir, 'migrations'),
                             backup_dir: File.join(root, 'data', 'backups')).pending
      return true if pending.empty?

      bad(t('seed.schema_outdated', versions: pending.map(&:version).join(', ')))
      false
    end

    # The account the prompts belong to. Without an address the single
    # instance administrator is taken; with several of them the script stops
    # rather than picking one — the same rule as reset_admin_password (BT-13).
    def account(db, email)
      if email
        found = db[:users].first(email: email)
        bad(t('seed.unknown_account', email: email)) if found.nil?
        return found
      end

      admins = db[:users].where(is_instance_admin: true).all
      return admins.first if admins.size == 1

      if admins.empty?
        bad(t('seed.no_admin'))
      else
        bad(t('seed.ambiguous', emails: admins.map { |user| user[:email] }.join(', ')))
      end
      nil
    end

    # An existing workspace of that name, or a new one owned by the account.
    def workspace_for(db, owner, name)
      existing = db[:workspaces].first(name: name)
      return existing[:id] if existing

      Workspaces.create(db, name: name, owner_id: owner[:id])
    end

    def confirmed?(options)
      return true if options[:yes]

      puts
      say(t('seed.confirm'))
      answer = $stdin.gets.to_s.strip.downcase
      return true if %w[j ja y yes].include?(answer)

      note(t('seed.aborted'))
      false
    end

    def parse(argv)
      {
        remove: argv.include?('--remove'),
        yes: argv.include?('--yes'),
        email: value_of(argv, '--email'),
        workspace: value_of(argv, '--workspace')
      }
    end

    def value_of(argv, name)
      index = argv.index(name)
      index && argv[index + 1]
    end
  end
end

exit PromptAtelier::SeedDemo.run(ARGV) if $PROGRAM_NAME == __FILE__
