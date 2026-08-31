# frozen_string_literal: true

# scripts/lib/manifest.rb — what a delivery package consists of (18.2, 18.8)
#
# Separated from `build` for the same reason `service_unit` is separated from
# `service_install`: **the contents are a value, the copying is an action.** A
# test can read this on any machine, without Node, without a build, in
# milliseconds — and the question this file answers ("what actually has to be
# in the package?") is the one that gets answered wrongly by omission. A file
# that was forgotten leaves no trace in a build log; it shows up as a broken
# installation at somebody else's desk.
#
# The second list matters as much as the first. `EXCLUDED` names what is
# deliberately left out and why, and a test asserts that none of it ever
# appears in a built tree. Without it "we don't ship node_modules" would be a
# sentence in a document rather than a property of the archive.
#
# **The scripts are split in two.** The operating scripts go along; `build`,
# `run_tests` and `start_development` do not. That is not tidiness: `tests/` is
# not part of a delivery, so a delivered `run_tests` would find no test files,
# skip everything and report "all tests that ran have passed" — a script that
# announces success having checked nothing. `build` and `start_development`
# need Node, which is expressly not a prerequisite for operation (18.3).

module PromptAtelier
  # Deliberately without `extend Script`: the roots are passed in, so this
  # module works just as well against a scratch source tree as against the one
  # it lives in.
  module Manifest
    # The fourteen pairs an installed instance can use (18.5). `start_portable`
    # is on the list because `install` names it in its closing line — a
    # delivery without it would end by pointing at a file that is not there.
    # `measure` is on it because the acceptance rule in Testkonzept 14 asks for
    # the numbers of chapter 12 to be taken on real systems and expressly not
    # in the development environment — a measuring tool that stayed behind
    # would make that rule unfulfillable.
    OPERATING_SCRIPTS = %w[
      backup check_environment export_all import_all install measure migrate
      package reset_admin_password restore seed_demo service_install
      service_uninstall start_portable
    ].freeze

    # The three that stay behind, see the file header.
    DEVELOPMENT_SCRIPTS = %w[build run_tests start_development].freeze

    # The Ruby files behind them, including the helpers that are not scripts of
    # their own. Written out rather than derived, so that adding a helper is a
    # decision somebody makes; `manifest_test` computes the closure over
    # `require_relative` and fails when the two disagree.
    # `archive` and `manifest` are delivered because `package` uses them: an
    # installation has to be able to turn itself back into an archive, which is
    # how a machine without a network gets one (18.3).
    # `bench` and `bench_server` travel for the same reason as `archive`:
    # `measure` cannot do its work without them, and a script that is delivered
    # without the files it requires fails on the first line rather than the
    # last.
    # `service_run` is the entry point of the Windows service. It has no
    # launcher of its own because nobody calls it by hand: the service manager
    # starts it, and it is delivered for that reason alone.
    OPERATING_LIBS = (OPERATING_SCRIPTS +
                      %w[archive bench bench_server common manifest
                         service_run service_unit]).sort.freeze

    # Directories that exist in the package but hold nothing yet. Without them
    # the structure of 18.2 would only be complete after the first run, and
    # `install` would be creating directories it should be finding.
    EMPTY_DIRS = ['data', 'data/backups', 'data/logs'].freeze

    # What never goes in, and the reason. Checked against the built tree, not
    # only stated here (TF-633).
    EXCLUDED = {
      'node_modules'      => 'result of building, not part of running (18.3)',
      'tests'             => 'the test suites are not delivered',
      'frontend'          => 'sources of the frontend; the built files are in app/public',
      'release'           => 'output of the build itself',
      'config/config.yml' => 'the settings of the developing machine, mode 0600 (SEC-20)',
      'data'              => 'the database of the developing machine'
    }.freeze

    # The Bundler configuration the package carries, which is **not** a copy of
    # the one in the development tree.
    #
    # `deployment` makes the lockfile binding and points Bundler at
    # `vendor/bundle` **beside the Gemfile**, which is how the vendored gems in
    # `app/vendor/bundle` are found at all (18.3). `without` keeps the test
    # gems out of the fallback: a machine whose platform does not match runs
    # `bundle install`, and fetching minitest onto a server that carries no
    # tests would be a download nobody asked for.
    BUNDLE_CONFIG = <<~CONFIG
      ---
      BUNDLE_DEPLOYMENT: "true"
      BUNDLE_WITHOUT: "development:test"
    CONFIG

    module_function

    # The package, as a list of steps. +code+ is the development installation
    # directory (`project/`), which is also the repository, +project+ the
    # directory above it, where `tools/` lives.
    #
    # `required: true` means a missing source aborts the build. That is the
    # default for everything an installation cannot do without — and `tools/`
    # is the one entry where it is false, because NSSM is a third-party program
    # that cannot be fetched from here. Its absence is a note, and `build` says
    # what it costs (R-10).
    def plan(code:, project:)
      [
        # backend/ becomes app/ (18.2). `vendor` is handled separately because
        # it depends on the archive shape; `.bundle` is written rather than
        # copied, see BUNDLE_CONFIG.
        { kind: :dir, from: File.join(code, 'backend'), to: 'app',
          except: %w[vendor .bundle], required: true },

        { kind: :scripts, from: File.join(code, 'scripts'), to: 'scripts',
          required: true },

        { kind: :file, from: File.join(code, 'config', 'config.example.yml'),
          to: 'config/config.example.yml', required: true },

        # The example package for the empty state (BT-17).
        { kind: :dir, from: File.join(code, 'examples'), to: 'examples',
          except: [], required: true },

        # Third-party tools; under Windows NSSM for the service (18.6).
        { kind: :dir, from: File.join(project, 'tools'), to: 'tools',
          except: [], required: false },

        # Everything a downloaded archive needs in order to be usable on its
        # own. Whoever unpacks it has no repository, so the manuals and the
        # licence have to travel with it. Before this entry the archive held
        # no explanatory document at all except the proxy templates.
        { kind: :file, from: File.join(code, 'README.md'), to: 'README.md', required: true },
        { kind: :file, from: File.join(code, 'README.de.md'), to: 'README.de.md', required: true },
        { kind: :file, from: File.join(code, 'LICENSE.md'), to: 'LICENSE.md', required: true },

        # Linked from the README, so they have to travel with it. Without them
        # an unpacked archive would carry three dead links.
        { kind: :file, from: File.join(code, 'CHANGELOG.md'), to: 'CHANGELOG.md', required: true },
        { kind: :file, from: File.join(code, 'CONTRIBUTING.md'), to: 'CONTRIBUTING.md', required: true },
        { kind: :file, from: File.join(code, 'SECURITY.md'), to: 'SECURITY.md', required: true },

        # The manuals and the reverse proxy templates for HTTPS operation
        # (SEC-14, 18.6). `doc/` is inside the repository since the split of
        # public from private documents.
        { kind: :dir, from: File.join(code, 'doc'), to: 'doc',
          except: [], required: true },

        # Screenshots referenced by the README. Optional, because the README is
        # readable without them and a build must not fail over a picture.
        { kind: :dir, from: File.join(code, 'img'), to: 'img',
          except: [], required: false },

        { kind: :write, contents: BUNDLE_CONFIG, to: 'app/.bundle/config', required: true },

        *EMPTY_DIRS.map { |dir| { kind: :empty, to: dir, required: true } }
      ]
    end

    # The files under `scripts/` that go along: both launchers of every
    # operating script and the Ruby behind them.
    def script_files
      OPERATING_SCRIPTS.flat_map { |name| ["#{name}.sh", "#{name}.bat"] }.sort +
        OPERATING_LIBS.map { |name| File.join('lib', "#{name}.rb") }
    end
  end
end
