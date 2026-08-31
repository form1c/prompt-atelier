# frozen_string_literal: true

# scripts/lib/package.rb — turn **this installation** into an archive for
# another machine of the same kind (18.3, 18.8)
#
# The answer to a question that comes up as soon as one machine has internet
# and the next one does not: install once where the network is, then carry the
# result over.
#
# `build` cannot do this. It runs in the source tree, needs Node, and is not
# delivered. This one runs in an installation and needs nothing but Ruby —
# because everything it packs is already lying there: the libraries were
# installed by `install`, and the interface came with the archive.
#
# **It produces a package for this platform and this Ruby series**, no other.
# The libraries carry compiled parts; that is a fact about them, not a
# shortcoming here. The file name says which machine it is for.
#
# **Three things are deliberately left behind, and they are the reason this
# script exists rather than a folder being zipped up by hand:**
#
#   * `config/config.yml` — it describes **this** machine and is protected
#     accordingly (SEC-20): address, port, paths, and `trusted_proxies`, which
#     is a way to lift the sign-in limit. Copied along, whoever
#     received the file could sign themselves into the original.
#   * `data/` — the database, the backups, the logs. Somebody's prompts are not
#     part of an installation package, and 6.2 promises they do not travel.
#   * every trace of use — the package is a fresh instance, and `install` on
#     the other side asks for its own administrator.

require 'fileutils'
require 'rbconfig'
require_relative 'common'
require_relative 'archive'
require_relative 'manifest'

module PromptAtelier
  module Package
    extend Script

    # What is taken from the installation. `app` carries the libraries and the
    # built interface; the rest is what 18.2 lists beside it.
    FROM_INSTALLATION = %w[app scripts examples tools doc].freeze

    # Never, under any circumstances. Checked again on the finished tree, not
    # only avoided while copying — an exclusion that is only a rule in the code
    # is one nobody can verify afterwards.
    #
    # `data/` itself is **not** on this list: the directory belongs in the
    # package, empty, so the structure of 18.2 is complete from the moment of
    # unpacking. What must not be in it is a **file**.
    NEVER = ['config/config.yml'].freeze

    module_function

    def run(argv = [])
      heading(t('package.title'))

      target = argv.find { |argument| !argument.start_with?('--') } || default_target
      return 1 unless usable?

      name = package_name
      stage = File.join(target, name)
      FileUtils.rm_rf(stage)

      collect(stage)
      write_version(stage)
      return 1 unless nothing_private_travelled?(stage)

      archives(name, stage, target, argv)
      FileUtils.rm_rf(stage) unless argv.include?('--keep-tree')
      finish(target)
      0
    end

    # --- what has to be there ------------------------------------------------

    # A package made from a half-installed instance would be a package that
    # installs a half-installed instance. The two things that must be there are
    # the libraries and the built interface — everything else came with the
    # archive this installation was made from.
    def usable?
      missing = []
      missing << t('package.no_gems') unless Dir.exist?(File.join(app_dir, 'vendor', 'bundle'))
      missing << t('package.no_interface') unless File.file?(File.join(app_dir, 'public', 'index.html'))
      return true if missing.empty?

      missing.each { |line| bad(line) }
      say(t('package.run_install_first'))
      false
    end

    # --- collecting ----------------------------------------------------------

    def collect(stage)
      FileUtils.mkdir_p(stage)

      FROM_INSTALLATION.each do |name|
        source = File.join(root, name)
        next note(t('package.skipping', name: name)) unless Dir.exist?(source)

        FileUtils.cp_r(source, File.join(stage, name))
      end

      # The template, and **only** the template. See NEVER above.
      FileUtils.mkdir_p(File.join(stage, 'config'))
      FileUtils.cp(config_template, File.join(stage, 'config', 'config.example.yml'))

      Manifest::EMPTY_DIRS.each { |dir| FileUtils.mkdir_p(File.join(stage, dir)) }
      ok(t('package.collected'))
    end

    # --- the check that makes the promise verifiable -------------------------

    # Looked for in the finished tree rather than trusted to the copying above.
    # The copying is where the mistake would be made, so it cannot also be the
    # place that certifies itself.
    def nothing_private_travelled?(stage)
      strays = NEVER.map { |name| File.join(stage, name) }.select { |path| File.exist?(path) }
      strays += Dir.glob(File.join(stage, 'data', '**', '*')).select { |path| File.file?(path) }
      strays += Dir.glob(File.join(stage, '**', '*.db'))
      strays.uniq!
      return true if strays.empty?

      strays.each { |path| bad(t('package.private_file', path: path.delete_prefix("#{stage}/"))) }
      FileUtils.rm_rf(stage)
      false
    end

    # --- VERSION -------------------------------------------------------------

    # Rewritten rather than copied: the package is now bound to **this**
    # machine's platform and Ruby series, whatever the archive said that this
    # installation came from. A universal archive installed here and packed up
    # again is a vendored package, and the file has to say so.
    def write_version(stage)
      lines = package_info.merge(
        'shape' => 'vendored',
        'platform' => Gem::Platform.local.to_s,
        'ruby' => RbConfig::CONFIG['ruby_version'],
        'gems' => 'bundled in app/vendor/bundle',
        'packed' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
        'packed_from' => 'an installed instance'
      )
      lines['version'] ||= '0.0.0'
      lines['product'] ||= 'Prompt Atelier'

      File.write(File.join(stage, 'VERSION'),
                 lines.map { |key, value| format("%-12s %s\n", "#{key}:", value) }.join)
    end

    # --- archives ------------------------------------------------------------

    def archives(name, stage, target, argv)
      moment = Time.now.utc
      formats = argv.include?('--zip') ? ['zip'] : %w[zip tar.gz]

      formats.each do |format|
        path = File.join(target, "#{name}.#{format}")
        writer = format == 'zip' ? :zip : :tar_gz
        Archive.public_send(writer, root: stage, base: name, into: path, mtime: moment)
        ok(t('package.written', path: path, size: human_size(File.size(path))))
      end
    end

    # --- values --------------------------------------------------------------

    def package_name
      "promptatelier-#{package_info['version'] || '0.0.0'}-#{Gem::Platform.local}-ruby#{RbConfig::CONFIG['ruby_version']}"
    end

    # Beside the installation, not inside it. Inside, the next run would pack
    # its own output, and the one after that would pack that.
    def default_target = File.expand_path('..', root)

    def human_size(bytes)
      return format('%.1f kB', bytes / 1024.0) if bytes < 1024 * 1024

      format('%.1f MB', bytes / (1024.0 * 1024))
    end

    def finish(target)
      puts
      ok(t('package.done', path: target))
      say(t('package.done_hint'))
    end
  end
end

exit PromptAtelier::Package.run(ARGV) if $PROGRAM_NAME == __FILE__
