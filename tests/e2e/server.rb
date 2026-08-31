# frozen_string_literal: true

# The instance the browser tests run against (test concept 3.2).
#
# Built from scratch on every run, in test-results/, on a port of its own.
# Nothing here may touch the installation being developed against: not
# project/data/promptatelier.db, which holds the developer's own work, and not
# project/backend/public/, which is where a real build lands. Both would be
# overwritten silently, and the loss would only show up much later.
#
# It serves the built interface and the API from one origin, as the delivered
# installation does (18.8). That is not convenience: the cookie rules from
# SEC-03 and the CSRF check from SEC-05 both depend on origin, and a test
# across two of them would prove the wrong thing.

require 'fileutils'
require 'json'
require 'securerandom'
require 'yaml'

CODE_ROOT = File.expand_path('../..', __dir__)

$LOAD_PATH.unshift(File.join(CODE_ROOT, 'backend'))
$LOAD_PATH.unshift(File.join(CODE_ROOT, 'tests'))
# For the measurement stock, see MEASURE_PROMPTS below.
$LOAD_PATH.unshift(File.join(CODE_ROOT, 'scripts', 'lib'))

ENV['BUNDLE_GEMFILE'] ||= File.join(CODE_ROOT, 'backend', 'Gemfile')
require 'bundler/setup'

require 'rack'
require 'puma'
require 'puma/configuration'
require 'puma/launcher'

require 'app'
require 'services/migrator'
require 'services/prompts'
require 'services/accounts'
require 'services/workspaces'
require 'fixtures/instance'
require 'bench'

module PromptAtelier
  module E2E
    PORT     = Integer(ENV.fetch('PROMPTATELIER_E2E_PORT', '9393'))

    # How many prompts the measurement stock holds, or zero for the ordinary
    # browser tests.
    #
    # **The browser measurements need a real library, and the fixture is six
    # prompts.** TF-702 asks how long the library takes to appear at 5.000 of
    # them (A-04), and a screen listing six answers a question nobody asked.
    # The stock comes from `scripts/lib/bench.rb` — the same corpus the
    # server-side measurements use, so both halves of chapter 12 are measured
    # over one library rather than over two that merely sound alike.
    #
    # Zero by default, because seeding 5.000 prompts costs a minute and the
    # regression suite has no use for them.
    MEASURE_PROMPTS = ENV.fetch('PROMPTATELIER_E2E_PROMPTS', '0').to_i
    EMAIL    = ENV.fetch('PROMPTATELIER_E2E_EMAIL', 'editor@test')
    PASSWORD = ENV.fetch('PROMPTATELIER_E2E_PASSWORD', Fixture::PASSWORD)

    class << self
      def run
        directory = prepare_directory
        build_interface(File.join(directory, 'public'))
        migrate(directory)
        # The interface is served by the **application**, exactly as in a
        # delivered installation. It used to be served by a few lines of Rack
        # in this file, and those lines did a job the backend did not do at
        # all: a delivered instance answered `GET /` with a JSON 404. Every
        # browser test was green over a harness that was kinder than reality.
        App.boot!(root: directory,
                  interface_root: File.join(directory, 'public'))
        seed(directory)

        serve(directory)
      end

      private

      def results_dir
        ENV.fetch('PROMPTATELIER_TEST_RESULTS', File.expand_path('../test-results', CODE_ROOT))
      end

      def prepare_directory
        directory = File.join(results_dir, 'e2e')
        FileUtils.rm_rf(directory)
        FileUtils.mkdir_p(File.join(directory, 'config'))
        FileUtils.mkdir_p(File.join(directory, 'data'))

        FileUtils.cp(File.join(CODE_ROOT, 'config', 'config.example.yml'),
                     File.join(directory, 'config', 'config.example.yml'))
        write_configuration(directory)
        directory
      end

      def write_configuration(directory)
        settings = {
          'server' => { 'host' => '127.0.0.1', 'port' => PORT,
                        'base_url' => "http://127.0.0.1:#{PORT}" },
          # Said out loud since AP-19. An instance that keeps quiet takes the
          # language from `Accept-Language`, and Playwright sends whatever its
          # engine defaults to — the browser cases assert German sentences, so
          # the instance under test declares German rather than depending on a
          # header that differs between Chromium, Firefox and WebKit.
          'locale' => 'de',
          # The default cost is deliberate everywhere else (SEC-01). Here it
          # would put a second on every sign-in of every browser test for no
          # gain — the subject is the screen, not the hashing.
          #
          # Registration stands on `approval` rather than on the delivered
          # `off` (FA-107): it is the setting an operator is meant to choose,
          # and it is the only one under which the whole of W-7 can be walked
          # — register, wait, be let in, sign in. `open` would skip the middle
          # two, which are the parts worth watching.
          # **Except when measuring.** TF-702 times the way from clicking
          # "Anmelden" to the library being on screen, and the password check
          # is part of that way. Measured at a reduced cost it would be a
          # number about a configuration nobody is delivered.
          'security' => { 'argon2' => argon2_cost, 'registration' => 'approval' }
        }
        path = File.join(directory, 'config', 'config.yml')
        File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(YAML.dump(settings))
        end
      end

      # The delivered cost while measuring, a cheap one otherwise. The cheap
      # one is deliberate everywhere else (SEC-01): it would otherwise put a
      # second on every sign-in of every browser test for no gain — the subject
      # there is the screen, not the hashing.
      def argon2_cost
        return {} if MEASURE_PROMPTS.positive?

        { 'memory_mib' => 16, 'iterations' => 1 }
      end

      def migrate(directory)
        Migrator.new(
          database_path: File.join(directory, 'data', 'promptatelier.db'),
          migrations_dir: File.join(CODE_ROOT, 'backend', 'migrations'),
          backup_dir: File.join(directory, 'data', 'backups')
        ).run
      end

      # The starting state from test concept 4.1 to 4.3 — the same one the
      # backend suites use. A browser test that invented its own accounts
      # would be describing a second instance nobody else knows about.
      def seed(directory)
        App.database.tap do |db|
          ids = Fixture.build(db)
          seed_library_prompt(db, ids)
          seed_measurement_stock(db, directory)
        end

        # The browser side reads its credentials from here instead of
        # repeating them. One source, and a changed fixture password shows up
        # as a changed file rather than as a puzzling sign-in failure.
        # Two accounts, because two levels of the matrix have screens now.
        # The top-level pair stays where it was so the files that only need
        # "somebody signed in" keep working; `admin` is the instance
        # administrator that W-7 needs (TF-356).
        File.write(File.join(directory, 'account.json'),
                   JSON.generate(email: EMAIL, password: PASSWORD,
                                 admin: { email: Fixture::PEOPLE[:thomas][:email], password: PASSWORD }))
      end

      # The measurement stock, and the account that reads it. Written out the
      # same way the credentials are, so the browser side has one source for
      # both instead of a second copy of the same three names.
      def seed_measurement_stock(db, directory)
        return if MEASURE_PROMPTS <= 0

        warn "Seeding #{MEASURE_PROMPTS} prompts for the measurement ..."
        facts = Bench.build(db, prompts: MEASURE_PROMPTS)
        File.write(File.join(directory, 'bench.json'), JSON.generate(facts))
        warn 'Measurement stock complete.'
      end

      # One prompt with everything a line of the library shows (11.3):
      # description, tags, and two variables. The fixture of 4.3 fills only
      # the fields the permission checks need — deliberately, but it means a
      # browser test could not tell an empty `variable_count` from a broken
      # one. Created through the real service, so the variables and tags come
      # about the way they do in use.
      def seed_library_prompt(db, ids)
        marketing = ids[:workspaces][:marketing]
        keyword_id = db[:keywords].insert(
          workspace_id: marketing, name: 'formal', text: 'Schreibe in einem sachlichen Ton.',
          position: 'append', sort_order: 10, created_at: Time.now, updated_at: Time.now
        )

        prompt_id = Prompts.create(
          db,
          workspace_id: marketing,
          owner_id: ids[:users][:sabine],
          attributes: {
            'title' => 'Blogartikel-Generator',
            'description' => 'Erstellt SEO-Artikel zu beliebigem Thema',
            'body' => 'Schreibe einen Blogartikel über {{thema}} für {{zielgruppe}}.',
            'visibility' => 'workspace',
            'tags' => %w[seo content],
            # `thema` is required and `zielgruppe` is a selection: without
            # them the browser tests could not reach TF-401 (copying blocked)
            # or FA-302 (a selection field with exactly these options) — the
            # two cases where the screen has to do something other than show
            # a text box.
            'variables' => [
              { 'key' => 'thema', 'label' => 'Thema', 'type' => 'text', 'required' => true },
              { 'key' => 'zielgruppe', 'label' => 'Zielgruppe', 'type' => 'select',
                'options' => %w[Einsteiger Fortgeschrittene], 'default_value' => 'Einsteiger' }
            ],
            'keyword_ids' => [keyword_id]
          }
        )

        attach(db, prompt_id, keyword_id)
        seed_multiline_prompt(db, marketing, ids[:users][:sabine])
      end

      # The rescue belongs to this one statement and not, as it did, to the
      # whole method. `Prompts.create` attaches the keyword itself, so the
      # insert below raises every time — which meant everything written after
      # it was jumped over and never ran. Found by adding a second prompt here
      # and watching the browser fail to find it.
      def attach(db, prompt_id, keyword_id)
        db[:prompt_keywords].insert(prompt_id: prompt_id, keyword_id: keyword_id)
      rescue Sequel::UniqueConstraintViolation
        nil
      end

      # A multi-line variable standing alone between blank lines — the shape a
      # prompt of this kind almost always has, and the one the browser-against-
      # server comparison never had.
      #
      # It is where the two implementations of step 4 are furthest apart: Ruby's
      # `$` already means the end of a line, JavaScript's needs the m flag. A
      # single-line prompt cannot tell the two apart, so the comparison passed
      # while saying nothing about the case that matters (TF-441).
      def seed_multiline_prompt(db, workspace_id, owner_id)
        Prompts.create(
          db,
          workspace_id: workspace_id,
          owner_id: owner_id,
          attributes: {
            'title' => 'Protokoll deuten',
            'description' => 'Liest einen Protokollauszug',
            'body' => "Deute diesen Auszug:\n\n{{auszug}}\n\nWas ist passiert?",
            'visibility' => 'workspace',
            'tags' => %w[technik],
            'variables' => [
              { 'key' => 'auszug', 'label' => 'Auszug', 'type' => 'multiline', 'required' => true }
            ]
          }
        )
      end

      # Vite is called directly rather than through `npm run build`: the
      # script in package.json writes to backend/public/, and npm hands
      # `--outDir` on in a way that vite reads as the project root — the build
      # then looks for index.html inside the target directory and fails.
      def build_interface(target)
        FileUtils.mkdir_p(target)
        command = [npx, 'vite', 'build', '--config',
                   File.join('frontend', 'vite.config.js'),
                   '--outDir', target, '--emptyOutDir', '--logLevel', 'warn']
        Dir.chdir(CODE_ROOT) do
          raise 'Building the interface failed' unless system(*command)
        end
      end

      def npx = Gem.win_platform? ? 'npx.cmd' : 'npx'

      def serve(_directory)
        configuration = Puma::Configuration.new do |puma|
          puma.bind "tcp://127.0.0.1:#{PORT}"
          puma.app App
          puma.environment 'production'
          puma.threads 1, 8
        end

        Puma::Launcher.new(configuration, events: Puma::Events.new).run
      end
    end
  end
end

PromptAtelier::E2E.run if $PROGRAM_NAME == __FILE__
