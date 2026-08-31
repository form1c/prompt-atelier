# frozen_string_literal: true

# Shared setup for all Minitest suites (test concept 3.2).
#
# Every test run works inside PROMPTATELIER_TEST_RESULTS, which points to
# test-results/ outside project/. No test may touch project/data/ — that directory
# holds the developer's own database.

ENV['RACK_ENV'] ||= 'test'

require 'minitest/autorun'
require 'rack/test'
require 'fileutils'
require 'tmpdir'
require 'json'
require 'yaml'
# build_installation picks a free port, so the helper carries its own
# dependency for it. It used to rely on the suite that first used it having
# required socket — which held until the helper was shared.
require 'socket'

CODE_ROOT = File.expand_path('..', __dir__)

$LOAD_PATH.unshift(File.join(CODE_ROOT, 'backend'))
$LOAD_PATH.unshift(File.join(CODE_ROOT, 'scripts', 'lib'))

require 'services/i18n'
require 'services/configuration'
require 'services/normalization'
require 'services/database'
require 'services/migrator'
require 'services/schema_guard'

module PromptAtelier
  module TestSupport
    # The project documents live **outside** the repository, in the
    # `documentation/` directory beside it. They are the requirements, the test
    # concept and the plan, and they are deliberately not published: a clone
    # therefore does not have them.
    #
    # Being outside the repository is what makes them private. No ignore rule
    # is involved, and none can be got wrong.
    #
    # Three cases compare the source against those documents. They must not
    # break a run that legitimately cannot see them, and they must not pass
    # silently either. Hence nil here and an explicit skip at the case.
    def self.project_document(name)
      path = File.expand_path(File.join('..', 'documentation', name), CODE_ROOT)
      return nil unless File.file?(path)

      File.read(path, encoding: 'UTF-8')
    end

    # The sentence every one of those cases skips with, so the reason is the
    # same wherever it appears.
    def self.document_missing(name)
      "#{name} is not present. The project documents are outside the repository " \
        'and a clone does not carry them.'
    end

    # Scratch area outside project/. Falls back to the default location so the
    # suite also runs when invoked directly instead of through run_tests.
    def self.scratch_dir
      @scratch_dir ||= begin
        dir = ENV.fetch('PROMPTATELIER_TEST_RESULTS',
                        File.expand_path('../test-results', CODE_ROOT))
        FileUtils.mkdir_p(File.join(dir, 'tmp'))
        File.join(dir, 'tmp')
      end
    end

    def self.template_path
      File.join(CODE_ROOT, 'config', 'config.example.yml')
    end

    # Builds a throwaway installation directory containing config/ and data/,
    # so path resolution can be exercised exactly as in a real installation.
    def self.install_dir(name)
      dir = File.join(scratch_dir, "#{name}-#{Process.pid}-#{rand(100_000)}")
      FileUtils.mkdir_p(File.join(dir, 'config'))
      FileUtils.mkdir_p(File.join(dir, 'data'))
      FileUtils.cp(template_path, File.join(dir, 'config', 'config.example.yml'))
      dir
    end

    # Writes a config.yml into an installation directory. +overrides+ is a
    # nested hash merged over the template.
    def self.write_config(dir, overrides = {}, raw: nil)
      path = File.join(dir, 'config', 'config.yml')

      if raw
        File.write(path, raw)
      else
        File.write(path, YAML.dump(deep_stringify(overrides)))
      end

      File.chmod(0o600, path) unless Gem.win_platform?
      path
    end

    # The environment a script is started with when a test starts it.
    #
    # **Testbed rule 12, generalised.** The rule says a child inherits the test
    # run's environment and that this can replace the subject. Three suites
    # answered it by clearing four names — `RUBYOPT`, `BUNDLE_GEMFILE`,
    # `GEM_HOME`, `GEM_PATH` — and four is not all of them. Under Bundler 4 a
    # `bundle exec` also leaves `BUNDLE_BIN_PATH`, `BUNDLE_LOCKFILE`,
    # `BUNDLER_VERSION` and `BUNDLER_SETUP` behind, and a child that keeps them
    # loads the **parent's** Bundler against the **parent's** lockfile. Here it
    # showed as `LoadError: cannot load such file -- sequel` from a script that
    # runs perfectly well from a shell; in the other suites it has so far been
    # harmless, which is the worse half of the finding.
    #
    # Derived instead of listed, so the next variable Bundler invents is
    # covered by construction. Removing means passing an explicit nil: the hash
    # given to `Open3` is merged **over** the parent environment, so anything
    # not named is inherited.
    OWNED_BY_BUNDLER = /\A(BUNDLE|BUNDLER|GEM_|RUBYOPT|RUBYLIB)/

    def self.script_env(extra = {})
      ENV.keys.grep(OWNED_BY_BUNDLER).to_h { |name| [name, nil] }.merge(extra)
    end

    def self.deep_stringify(value)
      case value
      when Hash  then value.to_h { |k, v| [k.to_s, deep_stringify(v)] }
      when Array then value.map { |v| deep_stringify(v) }
      else value
      end
    end
  end

  # Base class for tests that need an isolated installation directory.
  class TestCase < Minitest::Test
    def setup
      @install_dirs = []
      # The suite checks the German texts, so it says so rather than relying on
      # what a fresh installation happens to speak — that is English since
      # AP-19, and a test that inherited it would be checking a different
      # language than the one its assertions are written in.
      I18n.default_language = 'de'
    end

    def teardown
      @install_dirs.each { |dir| FileUtils.rm_rf(dir) }
    end

    def install_dir(name = 'inst')
      dir = TestSupport.install_dir(name)
      @install_dirs << dir
      dir
    end

    def write_config(dir, overrides = {}, raw: nil)
      TestSupport.write_config(dir, overrides, raw: raw)
    end

    # See TestSupport::OWNED_BY_BUNDLER — the environment a script gets when a
    # test starts it, free of everything this test run's own Bundler put there.
    def script_env(extra = {}) = TestSupport.script_env(extra)

    # A complete, valid configuration — the starting point for tests that want
    # to change exactly one value.
    def valid_config
      {
        'server'   => { 'host' => '127.0.0.1', 'port' => 9292,
                        'base_url' => 'http://localhost:9292' },
        # Said out loud, the way an operator would say it. Since AP-19 an
        # instance that keeps quiet gets the language of the browser, and the
        # assertions in this suite are written in German — so the installation
        # under test declares German instead of inheriting whatever the header
        # of the moment asks for.
        'locale'   => 'de'
      }
    end

    # Copies the real sources into a scratch installation directory, optionally
    # renaming backend/ to app/ — which is what `build` does (18.8).
    def build_installation(app_dir_name:, migrate: true)
      dir = install_dir("startup-#{app_dir_name}")
      target = File.join(dir, app_dir_name)
      FileUtils.mkdir_p(target)

      source = File.join(CODE_ROOT, 'backend')
      %w[app.rb config.ru version.rb Gemfile Gemfile.lock].each do |name|
        FileUtils.cp(File.join(source, name), File.join(target, name))
      end
      # `wordlists` is on the list because the password policy reads it at the
      # moment it checks a password (SEC-02) — leaving it out turns any script
      # that sets a password into `Errno::ENOENT` on a file the real delivery
      # always carries. Found when `reset_admin_password` was exercised for the
      # first time.
      %w[services locales config migrations wordlists].each do |name|
        FileUtils.cp_r(File.join(source, name), target)
      end

      # Reuse the already installed gems instead of running bundle install for
      # every test: the point here is the start, not the installation.
      FileUtils.cp_r(File.join(source, '.bundle'), target) if Dir.exist?(File.join(source, '.bundle'))
      FileUtils.ln_s(File.join(source, 'vendor'), File.join(target, 'vendor'))

      write_config(dir, valid_config.merge('server' => { 'port' => free_port }))
      migrate_installation(dir) if migrate
      dir
    end

    # Applies the schema to a throwaway installation.
    #
    # Uses the migrations from the source tree, not the copies inside the
    # installation. The copies are there because a delivery package has to carry
    # them — the server started from that directory runs its own `migrate`. But
    # loading them *in this process* would re-evaluate services/normalization.rb
    # and services/migration.rb from the copy and redefine their constants,
    # which floods the run with warnings and, worse, leaves two versions of the
    # same class around. The schema is identical either way.
    def migrate_installation(dir)
      PromptAtelier::Migrator.new(
        database_path:  File.join(dir, 'data', 'promptatelier.db'),
        migrations_dir: File.join(CODE_ROOT, 'backend', 'migrations'),
        backup_dir:     File.join(dir, 'data', 'backups')
      ).run
    end

    def configured_port(dir)
      YAML.safe_load(File.read(File.join(dir, 'config', 'config.yml')),
                     permitted_classes: [], aliases: false).dig('server', 'port')
    end

    def free_port
      server = TCPServer.new('127.0.0.1', 0)
      port   = server.addr[1]
      server.close
      port
    end

    # --- database helpers -------------------------------------------------

    def migrations_dir
      File.join(CODE_ROOT, 'backend', 'migrations')
    end

    def migrator_for(dir, migrations: migrations_dir)
      Migrator.new(
        database_path:  File.join(dir, 'data', 'promptatelier.db'),
        migrations_dir: migrations,
        backup_dir:     File.join(dir, 'data', 'backups')
      )
    end

    # A fresh installation directory with the schema applied. Returns the
    # directory; the database sits at data/promptatelier.db as in a real
    # installation, so path resolution is exercised too.
    def migrated_dir(name = 'db')
      dir = install_dir(name)
      write_config(dir, valid_config)
      migrator_for(dir).run
      dir
    end

    def database_path(dir) = File.join(dir, 'data', 'promptatelier.db')

    # Opens the migrated database and yields it, always closing afterwards.
    def with_db(dir, &block)
      Database.open(database_path(dir), &block)
    end

    # Minimal owner and workspace, because prompts cannot exist without them.
    def seed_owner(db)
      now = Time.now
      workspace_id = db[:workspaces].insert(
        name: 'Marketing', slug: 'marketing', created_at: now, updated_at: now
      )
      user_id = db[:users].insert(
        email: 'anna@example.test', name: 'Anna', password_hash: 'x',
        created_at: now, updated_at: now
      )
      [workspace_id, user_id]
    end

    def insert_prompt(db, workspace_id, owner_id, title:, body:, description: nil)
      now = Time.now
      db[:prompts].insert(
        workspace_id: workspace_id, owner_id: owner_id,
        title: title, description: description, body: body,
        created_at: now, updated_at: now
      )
    end

    # Search the way the application will: the term goes through the same
    # normalisation as the indexed text, then a prefix match (FA-501).
    def search(db, term)
      query = Normalization.normalize(term)
      db.fetch('SELECT rowid FROM prompts_fts WHERE prompts_fts MATCH ?', "#{query}*")
        .map { |row| row[:rowid] }
    end
  end
end
