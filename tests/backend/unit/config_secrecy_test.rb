# frozen_string_literal: true

require_relative '../../test_helper'
require 'start_development'

# TF-517 — the configuration file must not be readable by anyone else on the
# machine (SEC-20).
#
# The reason used to be given as "it carries the session secret". That value is
# gone (AP-22): nothing ever read it, and sessions are carried by a random
# token whose hash the database holds (SEC-03). The rule stands without it, and
# on a firmer footing — the file holds `trusted_proxies`, and whoever can widen
# that list lifts the sign-in limit of SEC-07 and can write any address they
# like into the audit log.
#
# The rule has two halves and only one of them was ever covered. That the
# application *complains* about open permissions is tested in
# configuration_test.rb. That the file it *creates itself* is closed in the
# first place was never checked — and creating it wrongly is the more likely
# mistake, because it happens once, silently, on a machine nobody looks at.
class ConfigSecrecyTest < PromptAtelier::TestCase
  Script = PromptAtelier::StartDevelopment

  def setup
    super
    skip 'file modes are a POSIX concept' if Gem.win_platform?
    @dir = install_dir('secrecy')
    FileUtils.mkdir_p(File.join(@dir, 'config'))
    FileUtils.cp(File.join(CODE_ROOT, 'config', 'config.example.yml'),
                 File.join(@dir, 'config', 'config.example.yml'))
  end

  def test_tf517_the_created_configuration_is_readable_by_its_owner_only
    path = create_config

    assert_equal 0o600, File.stat(path).mode & 0o777,
                 'group and others must have no access at all'
  end

  # The mode has to be part of the create call. A File.write followed by a
  # chmod leaves the file world-readable in between — briefly, but that is
  # precisely the window the requirement is about. Proven by watching the
  # mode the file has the moment it first exists, not after the fact.
  def test_tf517_the_file_is_never_readable_even_for_an_instant
    path = File.join(@dir, 'config', 'config.yml')
    seen = []
    watching = true

    watcher = Thread.new do
      while watching
        begin
          seen << (File.stat(path).mode & 0o777)
        rescue Errno::ENOENT
          # not created yet — keep looking
        end
      end
    end

    create_config
    watching = false
    watcher.join

    refute_empty seen, 'the watcher never saw the file — the test would prove nothing'
    assert seen.all? { |mode| mode == 0o600 },
           "the file was readable by others at some point: #{seen.uniq.map { |m| m.to_s(8) }}"
  end

  # The counter-check for the two above: the file really was written, and by
  # this code. Without it they would both pass over a create call that quietly
  # did nothing.
  def test_tf517_the_created_file_is_the_template_with_every_key
    content = File.read(create_config)

    assert_includes content, 'idle_timeout_days'
    assert_includes content, 'trusted_proxies'
  end

  # An existing file is left alone — whoever edited it chose a port, trusted a
  # proxy, set a language, and a restart may not throw that away.
  def test_an_existing_configuration_is_not_overwritten
    path = create_config
    before = File.read(path)

    create_config

    assert_equal before, File.read(path)
  end

  private

  def create_config
    Script.stub(:root, @dir) do
      Script.stub(:say, nil) do
        Script.stub(:ok, nil) do
          Script.ensure_configuration
        end
      end
    end
    File.join(@dir, 'config', 'config.yml')
  end
end
