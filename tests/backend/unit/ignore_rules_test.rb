# frozen_string_literal: true

require_relative '../../test_helper'

# TF-700 — what `.gitignore` keeps out of the repository, asked of git itself.
#
# **Nothing checked this until now, and it had a real gap.** `playwright-report/`
# was missing from the list: the Playwright configuration sends traces and test
# instances to `../test-results`, but the HTML report of a run with `CI` set is
# resolved against the directory of the configuration file and lands in the
# repository. That was found by running a build, not by a test, and only after
# the file had been publishable for weeks.
#
# **Asked of git, not read as text.** A case that greps `.gitignore` for the
# string `release/` proves that somebody typed it. It does not know about
# negations, ordering, or a pattern that matches nothing because a parent
# directory is excluded first. `git check-ignore` answers the question the
# repository will actually answer.
#
# The repository below is created for this case in the throwaway workspace and
# goes away with the rest of the run. The one this project lives in is never
# touched.
class IgnoreRulesTest < PromptAtelier::TestCase
  # Everything that must stay out. Each of these either holds data of the
  # developing machine, is restorable from a lock file, or is produced by a
  # run. The comment names why, because a bare list invites deletion.
  KEPT_OUT = {
    'node_modules/x.js'                  => 'restorable from package-lock.json',
    'frontend/node_modules/x.js'         => 'the same inside the npm workspace',
    'backend/vendor/bundle/x.rb'         => 'restorable from Gemfile.lock',
    'backend/.bundle/config'             => 'the local Bundler setting of one machine',
    '.bundle/config'                     => 'the same, when Bundler ran from the root',
    'config/config.yml'                  => 'the settings of the developing machine',
    'data/promptatelier.db'              => 'the database of the developing machine',
    'data/logs/service.log'              => 'what a service wrote while running',
    'release/promptatelier-1.0.1.zip'    => 'a build result, it belongs on the release page',
    'backend/public/assets/x.js'         => 'the built interface',
    'playwright-report/index.html'       => 'the HTML report of a run with CI set',
    'blob-report/x.zip'                  => 'another output of the browser tests',
    'test-results/x.png'                 => 'and another',
    'tools/nssm.exe'                     => 'a third-party program, fetched at install time'
  }.freeze

  # **The half that keeps the case honest.** Without it a `.gitignore` holding
  # a single `*` would pass everything above.
  KEPT_IN = %w[
    README.md
    CHANGELOG.md
    .gitignore
    config/config.example.yml
    backend/version.rb
    backend/app.rb
    doc/installation.md
    scripts/lib/service_run.rb
    examples/examples.json
    tests/vectors/rendering.json
    img/PromptAtelier-Login.jpg
    frontend/src/main.js
  ].freeze

  def setup
    super
    @repo = install_dir('ignore_probe')
    FileUtils.mkdir_p(@repo)
    @usable = system('git', 'init', '-q', @repo, out: File::NULL, err: File::NULL)
    return unless @usable

    FileUtils.cp(File.join(CODE_ROOT, '.gitignore'), @repo)
  end

  def test_tf700_everything_that_must_stay_out_is_kept_out
    skip('git is not available here') unless @usable

    offenders = KEPT_OUT.reject { |path, _| ignored?(create(path)) }
                        .map { |path, why| "#{path} would be committed (#{why})" }

    assert_empty offenders.sort
  end

  def test_tf700_everything_the_application_needs_is_kept_in
    skip('git is not available here') unless @usable

    offenders = KEPT_IN.select { |path| ignored?(create(path)) }
                       .map { |path| "#{path} is excluded and the application needs it" }

    assert_empty offenders.sort
  end

  # And the check itself has to work. `git check-ignore` answers with an exit
  # code, and a broken invocation answers "not ignored" for everything, which
  # would make the first case pass over an empty `.gitignore`.
  def test_tf700_the_check_can_tell_the_two_apart
    skip('git is not available here') unless @usable

    assert ignored?(create('data/promptatelier.db')), 'the check never says yes'
    refute ignored?(create('README.md')), 'the check never says no'
  end

  private

  def create(relative)
    path = File.join(@repo, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "x\n")
    relative
  end

  def ignored?(relative)
    system('git', '-C', @repo, 'check-ignore', '-q', relative,
           out: File::NULL, err: File::NULL)
  end
end
