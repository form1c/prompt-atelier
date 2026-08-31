# frozen_string_literal: true

require_relative '../../test_helper'
require 'open3'
require 'zlib'

# `build` against a throwaway source tree (18.8, BT-08, NFA-20).
#
# Run as a process, like `install`, and for the same reason: what is under test
# is a script somebody types, including the exit code and the sentence it
# leaves on the screen.
#
# **npm is a stand-in.** `npm ci` would need a network and minutes; here a
# small program on the PATH answers for it and writes the two files a Vite
# build would have written. That keeps the case about `build` — and it makes
# the failing frontend testable at all, which a real npm would not.
#
# Every case but two passes `--skip-tests`. Not out of haste: without it a
# build started from inside the suite would start the suite again. The two
# exceptions are the pair that proves the test gate works — one with a failing
# test file in the throwaway tree, one with a passing one.
class BuildTest < PromptAtelier::TestCase
  REAL_BACKEND = File.join(CODE_ROOT, 'backend')
  PROJECT_ROOT = File.expand_path('..', CODE_ROOT)

  # A fixed moment for the reproducibility cases. Any value will do; that it is
  # a value is the point.
  EPOCH = '1780000000'

  def setup
    super
    @project, @code = source_tree
  end

  # --- the test gate (BT-08, TF-632) ----------------------------------------

  # An archive built over a failing test is one nobody can tell apart from a
  # good one — it is the same shape, the same size, and it installs.
  def test_bt08_a_failing_test_stops_the_build_and_writes_no_archive
    write_scratch_test(passing: false)

    status, output = build('--shape=universal', '--format=tar.gz')

    refute_equal 0, status, output
    assert_includes output, 'tests failed'
    assert_empty archives, 'a failing run must leave nothing behind that looks like a release'
  end

  # The counter-case. Without it the one above would also pass over a `build`
  # that refused every time, and the gate would be indistinguishable from a
  # broken build.
  def test_bt08_the_same_build_runs_through_when_the_tests_pass
    write_scratch_test(passing: true)

    status, output = build('--shape=universal', '--format=tar.gz', '--keep-tree')

    assert_equal 0, status, output
    assert_equal 1, archives.size
    assert_match(/^tests:\s+passed$/, File.read(File.join(stage, 'VERSION')),
                 'and the package records that they really ran')
  end

  # --- what is in the package (TF-633) --------------------------------------

  def test_tf633_the_package_carries_the_structure_of_18_2
    status, output = build('--shape=universal', '--format=tar.gz', '--skip-tests', '--keep-tree')
    assert_equal 0, status, output

    %w[app/app.rb app/config/puma.rb app/public/index.html app/Gemfile app/Gemfile.lock
       app/.bundle/config scripts/install.sh scripts/lib/install.rb
       config/config.example.yml examples/examples.json VERSION].each do |name|
      assert_path_exists File.join(stage, name)
    end
    assert Dir.exist?(File.join(stage, 'doc', 'examples')), 'the proxy templates travel (18.6)'
  end

  # 18.2 asks for a structure that is complete from the moment of unpacking.
  def test_tf633_the_data_directories_exist_and_are_empty
    build('--shape=universal', '--format=tar.gz', '--skip-tests', '--keep-tree')

    assert_equal %w[backups logs], Dir.children(File.join(stage, 'data')).sort
    %w[data/backups data/logs].each do |name|
      assert_empty Dir.children(File.join(stage, name)), "#{name} must arrive empty"
    end
  end

  # The other half of TF-633, and the half that is easy to get wrong by
  # accident: `node_modules` is 88 MB of build tools, `tests/` is not part of a
  # delivery, and `config/config.yml` describes the machine
  # that built the package (SEC-20).
  def test_tf633_nothing_that_belongs_to_the_developing_machine_travels
    build('--shape=universal', '--format=tar.gz', '--skip-tests', '--keep-tree')
    inside = Dir.glob(File.join(stage, '**', '*'), File::FNM_DOTMATCH)
                .map { |path| path.delete_prefix("#{stage}/") }

    refute_includes inside, 'node_modules'
    refute_includes inside, 'tests'
    refute_includes inside, 'frontend'
    refute_includes inside, 'release'
    refute_includes inside, 'config/config.yml'
    refute(inside.any? { |name| name.end_with?('promptatelier.db') })
  end

  # The operating scripts, not the development ones. A delivered `run_tests`
  # would find no test files, skip every suite and report success.
  def test_the_delivered_scripts_are_the_operating_ones_only
    build('--shape=universal', '--format=tar.gz', '--skip-tests', '--keep-tree')

    assert_path_exists File.join(stage, 'scripts', 'start_portable.sh')
    assert_path_exists File.join(stage, 'scripts', 'backup.bat')
    refute_path_exists File.join(stage, 'scripts', 'run_tests.sh')
    refute_path_exists File.join(stage, 'scripts', 'lib', 'build.rb')
  end

  # The archive is what actually leaves the machine, so the entries are read
  # out of it rather than out of the directory it was made from.
  def test_the_archive_holds_the_same_files_under_one_top_level_directory
    build('--shape=universal', '--format=tar.gz', '--skip-tests', '--keep-tree')
    names = tar_names(archives.first)

    assert(names.all? { |name| name.start_with?("#{File.basename(stage)}/") },
           'unpacking must produce one directory, not a shower of files')
    assert_includes names, "#{File.basename(stage)}/VERSION"
    assert_includes names, "#{File.basename(stage)}/data/backups/"
  end

  # --- a second build (BT-07) -----------------------------------------------

  # A leftover from an earlier build would travel into the archive as though it
  # belonged there — a file that was removed from the manifest weeks ago and is
  # still delivered.
  def test_no_leftover_from_an_earlier_build_survives_into_the_next
    build('--shape=universal', '--format=tar.gz', '--skip-tests', '--keep-tree')
    File.write(File.join(stage, 'leftover.txt'), 'from an earlier build')

    build('--shape=universal', '--format=tar.gz', '--skip-tests', '--keep-tree')

    refute_path_exists File.join(stage, 'leftover.txt')
  end

  # --- reproducibility (NFA-20, TF-633b) ------------------------------------

  # The claim of 18.8 at its strongest: not "the same file list" but the same
  # archive, down to the byte. `SOURCE_DATE_EPOCH` is the convention for asking
  # a build for that, and honouring it is what turns NFA-20 into something a
  # checksum settles.
  def test_tf633b_the_same_source_produces_the_same_archive
    build('--shape=universal', '--format=tar.gz', '--skip-tests', epoch: EPOCH)
    first = File.binread(archives.first)
    FileUtils.rm_f(archives)

    build('--shape=universal', '--format=tar.gz', '--skip-tests', epoch: EPOCH, keep: true)

    assert_equal first, File.binread(archives.first)
    # And the given moment is really the one that was used. Without this the
    # case above would also hold for a build that ignored SOURCE_DATE_EPOCH and
    # simply happened to run twice inside the same second.
    assert_match(/^built:\s+#{Time.at(EPOCH.to_i).utc.strftime('%Y-%m-%dT%H:%M:%SZ')}$/,
                 File.read(File.join(stage, 'VERSION')))
  end

  # Without this the case above would also pass over a build that wrote the
  # same archive no matter what went into it.
  def test_tf633b_a_changed_source_produces_a_different_archive
    build('--shape=universal', '--format=tar.gz', '--skip-tests', epoch: EPOCH)
    first = File.binread(archives.first)
    FileUtils.rm_f(archives)

    File.write(File.join(@code, 'examples', 'examples.json'), '{"format":"changed"}')
    build('--shape=universal', '--format=tar.gz', '--skip-tests', epoch: EPOCH)

    refute_equal first, File.binread(archives.first)
  end

  # --- VERSION ---------------------------------------------------------------

  def test_the_version_file_says_what_the_package_is
    build('--shape=universal', '--format=tar.gz', '--skip-tests', '--keep-tree')
    version = File.read(File.join(stage, 'VERSION'))

    assert_match(/^version:\s+\d+\.\d+\.\d+$/, version)
    assert_match(/^shape:\s+universal$/, version)
    assert_match(/^built:\s+\d{4}-\d{2}-\d{2}T/, version)
    # `unknown` rather than a guess: this project is not always kept in a
    # repository, and a made-up commit would be worse than none — it is the
    # field somebody uses to find the source a package came from.
    assert_match(/^commit:\s+\S+/, version)
  end

  # A shortcut that lives only in a console line nobody kept is a shortcut that
  # gets forgotten. It belongs in the package itself.
  def test_a_skipped_test_run_is_written_into_the_package
    build('--shape=universal', '--format=tar.gz', '--skip-tests', '--keep-tree')

    assert_match(/^tests:\s+skipped$/, File.read(File.join(stage, 'VERSION')))
  end

  # --- the two shapes --------------------------------------------------------

  # The universal shape carries no gems, and says so where somebody will read
  # it. Its whole reason for existing is that a Windows package cannot be built
  # from a Linux machine: native extensions belong to one platform and one Ruby
  # ABI.
  def test_the_universal_shape_carries_no_gems_and_names_no_platform
    build('--shape=universal', '--format=tar.gz', '--skip-tests', '--keep-tree')
    version = File.read(File.join(stage, 'VERSION'))

    refute Dir.exist?(File.join(stage, 'app', 'vendor')), 'no gems in the universal shape'
    assert_match(/^platform:\s+any$/, version)
    assert_includes version, 'installed by install'
    assert_includes File.basename(stage), 'universal'
  end

  # And the vendored shape carries them together with the two facts that decide
  # whether they are usable at all. A package whose name did not say which
  # platform and which Ruby it was built for would be found out by installing
  # it, which is an afternoon.
  def test_the_vendored_shape_carries_the_gems_and_names_platform_and_ruby
    status, output = build('--shape=vendored', '--format=tar.gz', '--skip-tests', '--keep-tree')
    assert_equal 0, status, output

    version = File.read(File.join(stage, 'VERSION'))
    assert Dir.exist?(File.join(stage, 'app', 'vendor', 'bundle')), 'the gems have to be there'
    assert_match(/^platform:\s+\S+$/, version)
    assert_match(/^ruby:\s+\d+\.\d+\.\d+$/, version)
    assert_includes File.basename(stage), Gem::Platform.local.to_s
    assert_includes File.basename(stage), "ruby#{RbConfig::CONFIG['ruby_version']}"
  end

  # --- refusals that have to be readable (BT-15) ----------------------------

  # A required source that is not there stops the build and is named. The
  # alternative is a package that is quietly missing its manuals and its proxy
  # templates, and nobody notices until somebody unpacks it.
  def test_a_missing_required_source_stops_the_build_and_names_it
    FileUtils.rm_rf(File.join(@code, 'doc'))

    status, output = build('--shape=universal', '--format=tar.gz', '--skip-tests')

    refute_equal 0, status
    assert_includes output, 'doc'
    assert_empty archives
  end

  # `tools/` is the one entry that may be missing — NSSM cannot be fetched from
  # a build machine. But it costs something, and the note says what: without it
  # the Windows service setup falls back to a scheduled task on **every**
  # machine, which turns R-10 from a possibility into a certainty.
  def test_missing_third_party_tools_costs_a_note_and_not_the_build
    FileUtils.rm_rf(File.join(@project, 'tools'))

    status, output = build('--shape=universal', '--format=tar.gz', '--skip-tests')

    assert_equal 0, status, output
    assert_includes output, 'scheduled task'
    assert_equal 1, archives.size
  end

  # 18.8 asks the build to stop when a lockfile does not match the source. A
  # missing one is the sharpest version of that: `npm install` would write a
  # new one and the package would not be the one that was tested.
  def test_a_missing_npm_lockfile_stops_the_build
    FileUtils.rm_f(File.join(@code, 'package-lock.json'))

    status, output = build('--shape=universal', '--format=tar.gz', '--skip-tests')

    refute_equal 0, status
    assert_includes output, 'package-lock.json'
  end

  # A frontend build that runs but produces nothing must not become a package
  # with an empty `app/public/` — the instance would answer on its port and
  # show a blank page.
  def test_a_frontend_build_that_produces_nothing_is_a_failure
    stub_npm(builds: false)

    status, output = build('--shape=universal', '--format=tar.gz', '--skip-tests')

    refute_equal 0, status
    assert_includes output, 'index.html'
    assert_empty archives
  end

  def test_an_unknown_shape_is_refused_and_names_the_choices
    status, output = build('--shape=nachher', '--skip-tests')

    refute_equal 0, status
    assert_includes output, 'vendored, universal, both'
  end

  private

  # --- driving the script ----------------------------------------------------

  def build(*switches, epoch: nil, keep: false)
    environment = { 'PATH' => "#{File.join(@project, 'stubs')}:#{ENV.fetch('PATH', '')}",
                    'BUNDLE_GEMFILE' => File.join(@code, 'backend', 'Gemfile') }
    environment['SOURCE_DATE_EPOCH'] = epoch if epoch
    switches += ['--keep-tree'] if keep

    output, status = Open3.capture2e(
      environment, RbConfig.ruby, File.join(@code, 'scripts', 'lib', 'build.rb'), *switches,
      chdir: @code
    )
    [status.exitstatus, output]
  end

  def release_dir = File.join(@code, 'release')

  def archives = Dir.glob(File.join(release_dir, '*.{tar.gz,zip}')).sort

  # The one staged tree `--keep-tree` left behind.
  def stage
    Dir.glob(File.join(release_dir, '*')).find { |path| File.directory?(path) }
  end

  # --- the throwaway source tree --------------------------------------------

  # Development shape: `project/` with `backend/` and `doc/`, beside a working
  # directory that holds `tools/`. Since the split of public from private
  # documents, `doc/` is inside `project/` and travels with the package.
  def source_tree
    workspace = install_dir('build')
    code = File.join(workspace, 'project')

    copy_backend(File.join(code, 'backend'))
    FileUtils.cp_r(File.join(CODE_ROOT, 'scripts'), code)
    FileUtils.mkdir_p(File.join(code, 'config'))
    FileUtils.cp(File.join(CODE_ROOT, 'config', 'config.example.yml'), File.join(code, 'config'))
    FileUtils.cp_r(File.join(CODE_ROOT, 'examples'), code)
    %w[package.json package-lock.json].each do |name|
      FileUtils.cp(File.join(CODE_ROOT, name), code)
    end

    # What a downloaded archive needs in order to stand on its own.
    %w[README.md README.de.md LICENSE.md CHANGELOG.md CONTRIBUTING.md SECURITY.md].each { |name| FileUtils.cp(File.join(CODE_ROOT, name), code) }
    FileUtils.mkdir_p(File.join(code, 'doc', 'examples'))
    FileUtils.cp(Dir.glob(File.join(CODE_ROOT, 'doc', '*.md')), File.join(code, 'doc'))
    FileUtils.cp(Dir.glob(File.join(CODE_ROOT, 'doc', 'examples', '*')),
                 File.join(code, 'doc', 'examples'))

    FileUtils.mkdir_p(File.join(workspace, 'tools'))
    File.write(File.join(workspace, 'tools', 'README.txt'), 'nssm.exe belongs here')

    @project = workspace
    stub_npm
    [workspace, code]
  end

  def copy_backend(target)
    FileUtils.mkdir_p(target)
    %w[app.rb config.ru version.rb Gemfile Gemfile.lock].each do |name|
      FileUtils.cp(File.join(REAL_BACKEND, name), target)
    end
    %w[services locales config migrations models routes wordlists].each do |name|
      FileUtils.cp_r(File.join(REAL_BACKEND, name), target)
    end
    FileUtils.cp_r(File.join(REAL_BACKEND, '.bundle'), target)
    # Linked rather than copied: what is under test is the build, not
    # `bundle install`. The link itself must never reach an archive, which is
    # one of the things `Archive.entries` refuses.
    FileUtils.ln_s(File.join(REAL_BACKEND, 'vendor'), File.join(target, 'vendor'))
  end

  # The stand-in for npm. `--version` answers the prerequisite check, `ci` does
  # nothing, and `run build` writes what a Vite build would have written.
  def stub_npm(builds: true)
    stubs = File.join(@project, 'stubs')
    FileUtils.mkdir_p(stubs)
    path = File.join(stubs, 'npm')

    File.write(path, <<~SHELL)
      #!/bin/sh
      case "$1" in
        --version) echo "10.9.0" ;;
        run)
          if [ "#{builds}" = "true" ] && [ "$3" = "build" ]; then
            mkdir -p backend/public/assets
            printf '<!doctype html><title>Prompt Atelier</title>' > backend/public/index.html
            printf 'body{margin:0}' > backend/public/assets/app-1a2b3c.css
          fi
          ;;
      esac
      exit 0
    SHELL
    File.chmod(0o755, path)
  end

  # A test file inside the throwaway tree, so that `run_tests` has something to
  # run that is not this suite. Deliberately without the shared helper: it has
  # to load in a fraction of a second.
  def write_scratch_test(passing:)
    dir = File.join(@code, 'tests', 'backend', 'unit')
    FileUtils.mkdir_p(dir)

    File.write(File.join(dir, 'scratch_test.rb'), <<~RUBY)
      require 'minitest/autorun'
      class ScratchTest < Minitest::Test
        def test_the_gate
          #{passing ? 'assert true' : "flunk 'deliberately failing, to prove build stops'"}
        end
      end
    RUBY
  end

  # --- reading a tar file ----------------------------------------------------

  def tar_names(path)
    raw = Zlib::GzipReader.open(path) { |gz| gz.read.b }
    names = []
    offset = 0

    while offset + 512 <= raw.bytesize
      header = raw[offset, 512]
      break if header.each_byte.all?(&:zero?)

      prefix = header[345, 155].split("\0").first.to_s
      name   = header[0, 100].split("\0").first.to_s
      size   = header[124, 12].split("\0").first.to_s.to_i(8)

      names << (prefix.empty? ? name : "#{prefix}/#{name}")
      offset += 512 + ((size + 511) / 512) * 512
    end
    names
  end
end
