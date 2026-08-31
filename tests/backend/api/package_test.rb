# frozen_string_literal: true

require_relative '../../test_helper'
require 'open3'
require 'zlib'

# `package` — an installation turns itself back into an archive (18.3, 18.8).
#
# **The question it answers came from operating the thing:** one machine has a
# network and the next one does not. Install where the network is, pack the
# result, carry it over. `build` cannot do that — it runs in the source tree,
# needs Node and is not delivered; this one needs nothing but Ruby, because
# everything it packs is already lying in the installation.
#
# The cases below fall into two halves, and the second is the important one:
# what must **not** travel. A package that carried `config.yml` would give
# every instance made from it the settings of somebody else's machine — and whoever received
# the file could sign themselves into the original.
class PackageTest < PromptAtelier::TestCase
  def setup
    super
    @dir = installed_instance
    # A directory of its own per case. The first attempt used the shared parent
    # of the throwaway installations, and an archive from an earlier case was
    # still lying there — "nothing was written" was then true of the run and
    # false of the directory.
    @target = install_dir('package-out')
  end

  # --- what travels ----------------------------------------------------------

  def test_the_archive_carries_a_complete_installation
    status, output = run_package
    assert_equal 0, status, output

    inside = tar_names(archive('tar.gz'))
    %w[app/app.rb app/public/index.html app/Gemfile app/Gemfile.lock
       app/vendor/bundle/marker.txt scripts/install.sh scripts/lib/install.rb
       config/config.example.yml VERSION].each do |name|
      assert_includes inside, "#{package_name}/#{name}"
    end
  end

  def test_the_empty_directories_are_there_so_the_structure_is_complete
    run_package

    inside = tar_names(archive('tar.gz'))
    assert_includes inside, "#{package_name}/data/backups/"
    assert_includes inside, "#{package_name}/data/logs/"
  end

  # The package is bound to **this** machine now, whatever the archive said
  # that this installation came from. A universal archive installed here and
  # packed up again is a vendored package, and the file has to say so.
  def test_the_version_file_describes_the_machine_it_was_packed_on
    run_package
    version = File.read(File.join(@target, package_name, 'VERSION'))

    assert_match(/^shape:\s+vendored$/, version)
    assert_match(/^platform:\s+#{Regexp.escape(Gem::Platform.local.to_s)}$/, version)
    assert_match(/^ruby:\s+#{Regexp.escape(RbConfig::CONFIG['ruby_version'])}$/, version)
    assert_match(/^packed_from:\s+an installed instance$/, version)
  end

  def test_the_file_name_says_which_machine_it_is_for
    run_package

    assert_includes package_name, Gem::Platform.local.to_s
    assert_includes package_name, "ruby#{RbConfig::CONFIG['ruby_version']}"
  end

  # --- what must not travel --------------------------------------------------

  # The one that matters most. `config.yml` describes **this** machine
  # (SEC-20): its address, its paths, and the proxies it believes. Handed on
  # inside a package it would tell whoever received it how the original is
  # reachable and which senders it trusts — and every instance made from that
  # package would start out configured for somebody else's network.
  def test_the_configuration_stays_behind
    run_package

    inside = tar_names(archive('tar.gz'))
    refute_includes inside, "#{package_name}/config/config.yml"
    assert_includes inside, "#{package_name}/config/config.example.yml",
                    'but the template travels, or install has nothing to work from'

    # And nowhere else either — read as bytes, because the tree holds binary
    # files too and `File.read` on one of those must not decide the case.
    unpacked = Dir.glob(File.join(@target, package_name, '**', '*'), File::FNM_DOTMATCH)
                  .select { |path| File.file?(path) }
    refute(unpacked.any? { |path| File.binread(path).include?(@marker) },
           'and its contents are nowhere else either')
  end

  # 6.2: an instance administrator reads no foreign prompt. A package that
  # carried the database would hand over every one of them.
  def test_the_database_and_the_backups_stay_behind
    run_package

    inside = tar_names(archive('tar.gz'))
    refute(inside.any? { |name| name.end_with?('.db') })
    refute(inside.any? { |name| name.include?('/data/') && !name.end_with?('/') })
  end

  # The refusal is checked on the **finished tree**, not left to the copying.
  # The copying is where the mistake would be made, so it cannot also be the
  # place that certifies itself — and a check that only exists as a rule in the
  # code is one nobody can verify afterwards.
  def test_a_private_file_that_slipped_through_stops_the_run
    # Made to slip through by putting a database where the collector does not
    # look for one: inside app/, which is copied whole.
    FileUtils.mkdir_p(File.join(@dir, 'app', 'leftover'))
    File.write(File.join(@dir, 'app', 'leftover', 'old.db'), 'not yours')

    status, output = run_package

    refute_equal 0, status
    assert_includes output, 'Refused'
    assert_empty Dir.glob(File.join(@target, '*.tar.gz')), 'and nothing was written'
  end

  # --- refusals --------------------------------------------------------------

  # A package made from a half-installed instance installs a half-installed
  # instance. Both halves are checked, because either alone would let the other
  # through.
  def test_an_installation_without_libraries_is_refused
    FileUtils.rm_rf(File.join(@dir, 'app', 'vendor'))

    status, output = run_package

    refute_equal 0, status
    assert_includes output, 'libraries are not in this installation'
    assert_includes output, 'Run install first'
  end

  def test_an_installation_without_the_built_interface_is_refused
    FileUtils.rm_f(File.join(@dir, 'app', 'public', 'index.html'))

    status, output = run_package

    refute_equal 0, status
    assert_includes output, 'interface is not in this installation'
  end

  private

  def package_name
    "promptatelier-9.9.9-#{Gem::Platform.local}-ruby#{RbConfig::CONFIG['ruby_version']}"
  end

  def archive(format) = File.join(@target, "#{package_name}.#{format}")

  def run_package
    output, status = Open3.capture2e(
      script_env,
      RbConfig.ruby, File.join(@dir, 'scripts', 'lib', 'package.rb'), @target, '--keep-tree',
      chdir: @dir
    )
    [status.exitstatus, output]
  end

  # An installation as `install` leaves one: application, libraries, built
  # interface, configuration **with a recognisable line in it**, and a database. The last two
  # are what the cases above watch for.
  def installed_instance
    dir = install_dir('package')
    app = File.join(dir, 'app')
    FileUtils.mkdir_p(File.join(app, 'public'))
    FileUtils.mkdir_p(File.join(app, 'vendor', 'bundle'))

    source = File.join(CODE_ROOT, 'backend')
    %w[app.rb config.ru version.rb Gemfile Gemfile.lock].each do |name|
      FileUtils.cp(File.join(source, name), File.join(app, name))
    end
    %w[services locales config migrations].each { |name| FileUtils.cp_r(File.join(source, name), app) }
    File.write(File.join(app, 'public', 'index.html'), '<!doctype html>')
    # Stands in for the real vendored tree, which is 29 MB and irrelevant here:
    # what is under test is whether it travels, not what is in it.
    File.write(File.join(app, 'vendor', 'bundle', 'marker.txt'), 'gems live here')

    FileUtils.cp_r(File.join(CODE_ROOT, 'scripts'), dir)
    FileUtils.cp_r(File.join(CODE_ROOT, 'examples'), dir)

    # A line that occurs nowhere else in the tree, so "is it in the package"
    # has one unambiguous answer.
    @marker = 'zitronenfalter.example.test'
    write_config(dir, valid_config.merge(
                        'server' => valid_config['server'].merge('base_url' => "http://#{@marker}")
                      ))
    migrate_installation(dir)
    File.write(File.join(dir, 'VERSION'), "product:  Prompt Atelier\nversion:  9.9.9\nshape:    universal\n")
    dir
  end

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
