# frozen_string_literal: true

# scripts/lib/build.rb — from the source tree to a delivery package (18.5,
# 18.8, BT-08, NFA-20)
#
# Three steps that happen once, and the first two are refusals:
#
#   1. prerequisites — Node, npm, the gems, both lockfiles
#   2. tests         — everything, including the browser tests; a failure ends
#                      the run here (BT-08)
#   3. frontend      — npm ci, then the Vite build into backend/public
#
# Then, **per archive shape**: staging from the manifest, the vendored gems
# where they belong, the VERSION file, and the two archives.
#
# The headings said "Step 1 of 7" to "Step 3 of 7" and then stopped, because
# steps 4 to 7 run twice. A log that ends its numbering at three of seven reads
# like a run that broke off — reported after a build that had in fact finished.
#
# **Two shapes come out of one build, and that is not indecision.** The gems
# `sqlite3`, `argon2`, `ffi`, `nio4r` and `puma` carry native extensions: a
# vendored `vendor/bundle` belongs to one platform **and** one Ruby ABI. Built
# here it is worth nothing on Windows and nothing under Ruby 3.4. So:
#
#   * **vendored** — carries the gems. Installs without a network, which is the
#     normal case behind a company firewall (18.3). Its name says which
#     platform and which Ruby it is for, because somebody who has to find that
#     out by installing has already lost the afternoon.
#   * **universal** — carries none. Runs everywhere; `install` fetches the gems
#     once. Without this shape a Windows package could not be built from a
#     Linux machine at all, and NT-5 asks for exactly that.
#
# **Ruby itself goes into neither** (18.3). Shipping an interpreter means
# patching it when a vulnerability is published, and that is a promise this
# project cannot keep — a bundled Ruby with a known hole is worse than a system
# Ruby the distribution maintains.
#
# **Reproducibility** (NFA-20) is honoured through `SOURCE_DATE_EPOCH`: set it,
# and two builds of one source produce byte-identical archives. Unset, the only
# difference is the build date, in the VERSION file and in the timestamps.

require 'fileutils'
require 'rbconfig'
require_relative 'common'
require_relative 'archive'
require_relative 'manifest'

module PromptAtelier
  module Build
    extend Script

    SHAPES  = %w[vendored universal both].freeze
    FORMATS = %w[tar.gz zip both].freeze

    module_function

    def run(argv = [])
      options = parse(argv)
      return 1 if options.nil?

      heading(t('build.title'))
      say(t('build.version', version: version))

      return 1 unless prerequisites
      return 1 unless tests(options)
      return 1 unless frontend

      shapes(options).each { |shape| return 1 unless package(shape, options) }

      finish
      0
    end

    # --- 1. prerequisites -----------------------------------------------------

    # The full check, not the operating one: building needs Node and npm, and a
    # machine without them should hear that now rather than in step 3, in an
    # npm error message.
    def prerequisites
      require_relative 'check_environment'

      heading(t('build.step_prerequisites'))
      return false unless CheckEnvironment.run(%w[--no-heading]).zero?

      # 18.8 asks the build to stop when a lockfile does not match the source.
      # For the gems `bundle check` inside check_environment has already said
      # so. For npm it is `npm ci` in step 3 that refuses — but only if the
      # lockfile is there at all, and a missing one would otherwise turn into a
      # silent `npm install` that writes a new one.
      unless File.file?(File.join(root, 'package-lock.json'))
        bad(t('build.lockfile_missing', path: File.join(root, 'package-lock.json')))
        return false
      end

      true
    end

    # --- 2. tests -------------------------------------------------------------

    # BT-08. The browser tests run too: they are the only ones that exercise
    # the built frontend the way a user meets it, and a package is exactly the
    # thing nobody re-checks afterwards.
    def tests(options)
      heading(t('build.step_tests'))

      if options[:skip_tests]
        # Recorded in VERSION as well, further down. A shortcut that lives only
        # in a console line nobody kept is a shortcut that gets forgotten.
        note(t('build.tests_skipped'))
        return true
      end

      require_relative 'run_tests'
      return true if RunTests.run(%w[--e2e]).zero?

      bad(t('build.tests_failed'))
      false
    end

    # --- 3. frontend ----------------------------------------------------------

    # Runs in `project/`, not in `project/frontend/`: the lockfile of the workspace
    # lives there (18.2). `npm ci` rather than `npm install`, so the lockfile
    # stays authoritative (NFA-20) — `install` would quietly rewrite it and the
    # build would no longer be the one that was tested.
    def frontend
      heading(t('build.step_frontend'))

      return false unless step(t('build.npm_ci'), npm, 'ci')
      return false unless step(t('build.vite'), npm, 'run', '--silent', 'build')

      index = File.join(root, 'backend', 'public', 'index.html')
      unless File.file?(index)
        bad(t('build.frontend_empty', path: File.dirname(index)))
        return false
      end

      ok(t('build.frontend_done', path: File.dirname(index)))
      true
    end

    # Run in the installation directory, not wherever the build was started
    # from. `Script.capture` has no place to say that, so this is the one call
    # site that reaches for Open3 itself.
    def step(description, *command)
      say(description)
      output, status = Open3.capture2e(*command, chdir: root)
      return true if status.success?

      bad(t('build.command_failed', command: command.join(' ')))
      say(output.to_s.lines.last(5).join.strip) unless output.to_s.strip.empty?
      false
    rescue Errno::ENOENT
      bad(t('build.command_failed', command: command.join(' ')))
      false
    end

    def npm = windows? ? 'npm.cmd' : 'npm'

    # --- 4 to 7. one package --------------------------------------------------

    def package(shape, options)
      name  = package_name(shape)
      stage = File.join(release_dir, name)

      heading(t('build.step_package', name: name))

      # Removed first, and this is not tidiness: a leftover tree from an
      # earlier build would carry files the manifest no longer names, and they
      # would travel into the archive as though they belonged there.
      FileUtils.rm_rf(stage)
      return false unless stage_files(stage)
      return false unless gems(shape, stage)

      write_version(shape, stage, options)
      archives(name, stage, options)
      FileUtils.rm_rf(stage) unless options[:keep_tree]
      true
    end

    def stage_files(stage)
      Manifest.plan(code: root, project: project_root).each do |item|
        next if carry_out(item, stage)

        bad(t('build.source_missing', path: item[:from], target: item[:to]))
        return false
      end
      true
    end

    # Returns false only for a **required** source that is not there. An
    # optional one that is missing is a note with its consequence spelled out:
    # `tools/` without NSSM means the Windows service falls back to a scheduled
    # task on every machine, which turns R-10 from a possibility into a
    # certainty.
    def carry_out(item, stage)
      target = File.join(stage, item[:to])

      case item[:kind]
      when :empty   then FileUtils.mkdir_p(target)
      when :write   then write_file(target, item[:contents])
      when :file    then copy_file(item, target)
      when :dir     then copy_dir(item, target)
      when :scripts then copy_scripts(item, target)
      end
    end

    def write_file(target, contents)
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, contents)
      true
    end

    def copy_file(item, target)
      return report_missing(item) unless File.file?(item[:from])

      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(item[:from], target)
      true
    end

    def copy_dir(item, target)
      return report_missing(item) unless Dir.exist?(item[:from])

      FileUtils.mkdir_p(target)
      Dir.children(item[:from]).sort.each do |name|
        next if item[:except].include?(name)

        FileUtils.cp_r(File.join(item[:from], name), File.join(target, name))
      end
      true
    end

    # The operating scripts only. What stays behind and why is in
    # `manifest.rb`; here it is a copy of a list.
    def copy_scripts(item, target)
      return report_missing(item) unless Dir.exist?(item[:from])

      Manifest.script_files.each do |name|
        source = File.join(item[:from], name)
        next unless File.file?(source)

        FileUtils.mkdir_p(File.dirname(File.join(target, name)))
        FileUtils.cp(source, File.join(target, name))
      end
      true
    end

    def report_missing(item)
      return false if item[:required]

      note(t('build.optional_missing', path: item[:from]))
      note(t('build.optional_missing_tools')) if item[:to] == 'tools'
      true
    end

    # --- 5. the gems ----------------------------------------------------------

    def gems(shape, stage)
      return true if shape == 'universal'

      source = File.join(root, 'backend', 'vendor', 'bundle')
      unless Dir.exist?(source)
        bad(t('build.gems_missing', path: source))
        return false
      end

      target = File.join(stage, 'app', 'vendor', 'bundle')
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp_r(source, target)
      ok(t('build.gems_copied', platform: platform, ruby: ruby_abi))
      true
    end

    # --- 6. VERSION -----------------------------------------------------------

    # Written as `key: value` lines: readable by a person who unpacked an
    # archive and wants to know what they have, and parsable by anything that
    # has to compare two of them.
    def write_version(shape, stage, options)
      lines = {
        'product'  => 'Prompt Atelier',
        'version'  => version,
        'built'    => build_time.strftime('%Y-%m-%dT%H:%M:%SZ'),
        'commit'   => commit,
        'shape'    => shape,
        'platform' => shape == 'vendored' ? platform : 'any',
        'ruby'     => shape == 'vendored' ? ruby_abi : ">= #{CheckEnvironment::RUBY_MINIMUM.join('.')}",
        'gems'     => shape == 'vendored' ? 'bundled in app/vendor/bundle' : 'installed by install',
        'tests'    => options[:skip_tests] ? 'skipped' : 'passed'
      }

      File.write(File.join(stage, 'VERSION'),
                 lines.map { |key, value| format("%-9s %s\n", "#{key}:", value) }.join)
    end

    # `unknown` rather than a guess. A commit line that was made up would be
    # worse than none, because it is the field somebody uses to find out which
    # source a package came from.
    #
    # **Asked in `root`, not in `project_root`.** The repository is the
    # development installation directory itself. `project_root` is the working
    # folder one level above it, which is deliberately **not** a repository:
    # that is where everything private lives. Asking there found nothing and
    # answered `unknown` for every build, including builds made minutes after a
    # commit. Reported by the operator, who saw `commit: unknown` in an archive
    # whose source was committed.
    def commit
      success, output = capture('git', '-C', root, 'rev-parse', '--short', 'HEAD')
      return 'unknown' unless success && !output.to_s.strip.empty?

      clean, changes = capture('git', '-C', root, 'status', '--porcelain')
      dirty = clean && !changes.to_s.strip.empty?
      dirty ? "#{output.strip} (with uncommitted changes)" : output.strip
    end

    # --- 7. the archives ------------------------------------------------------

    def archives(name, stage, options)
      formats(options).each do |format|
        path = File.join(release_dir, "#{name}.#{format}")
        writer = format == 'zip' ? :zip : :tar_gz
        Archive.public_send(writer, root: stage, base: name, into: path, mtime: build_time)
        ok(t('build.archive_written', path: path, size: human_size(File.size(path))))
      end
    end

    # --- the values everything above reads ------------------------------------

    def version
      @version ||= begin
        require File.join(app_dir, 'version')
        PromptAtelier::VERSION
      end
    end

    # One timestamp for the whole run: the VERSION line, both archives and
    # every entry inside them. `SOURCE_DATE_EPOCH` is the convention for asking
    # a build to be reproducible, and honouring it is what turns NFA-20 from a
    # claim into something a checksum settles.
    def build_time
      @build_time ||= begin
        given = ENV.fetch('SOURCE_DATE_EPOCH', nil)
        given.to_s.match?(/\A\d+\z/) ? Time.at(given.to_i).utc : Time.now.utc
      end
    end

    def platform    = Gem::Platform.local.to_s
    def ruby_abi    = RbConfig::CONFIG['ruby_version']
    def project_root = File.expand_path('..', root)
    def release_dir = File.join(root, 'release')

    def package_name(shape)
      return "promptatelier-#{version}-universal" if shape == 'universal'

      "promptatelier-#{version}-#{platform}-ruby#{ruby_abi}"
    end

    def shapes(options)
      options[:shape] == 'both' ? %w[vendored universal] : [options[:shape]]
    end

    def formats(options)
      options[:format] == 'both' ? %w[tar.gz zip] : [options[:format]]
    end

    def human_size(bytes)
      return format('%.1f kB', bytes / 1024.0) if bytes < 1024 * 1024

      format('%.1f MB', bytes / (1024.0 * 1024))
    end

    def finish
      puts
      ok(t('build.done', path: release_dir))
    end

    # --- arguments ------------------------------------------------------------

    def parse(argv)
      options = { shape: 'both', format: 'both', skip_tests: false, keep_tree: false }

      argv.each do |argument|
        name, value = argument.split('=', 2)
        case name
        when '--shape'      then options[:shape]  = value
        when '--format'     then options[:format] = value
        when '--skip-tests' then options[:skip_tests] = true
        when '--keep-tree'  then options[:keep_tree]  = true
        end
      end

      return nil unless valid?(options)

      FileUtils.mkdir_p(release_dir)
      options
    end

    def valid?(options)
      unless SHAPES.include?(options[:shape])
        bad(t('build.shape_invalid', shapes: SHAPES.join(', ')))
        return false
      end
      unless FORMATS.include?(options[:format])
        bad(t('build.format_invalid', formats: FORMATS.join(', ')))
        return false
      end

      true
    end
  end
end

exit PromptAtelier::Build.run(ARGV) if $PROGRAM_NAME == __FILE__
