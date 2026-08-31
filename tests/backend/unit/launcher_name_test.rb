# frozen_string_literal: true

require_relative '../../test_helper'
require 'json'
require 'install'

# TF-682 — The name of the launcher differs by platform, and a message that spells one
# of them out is wrong on the other half of the supported systems.
#
# **This was reported from a Windows machine, not found here.** The installer
# finished and then said "start the application with scripts/start_portable.sh"
# on a system where that file does not exist. Three of the four messages that
# name the launcher worked it out nowhere, and the run that produced them was
# green: nothing in the suite reads what the installer says.
class LauncherNameTest < PromptAtelier::TestCase
  TEXTS = JSON.parse(File.read(File.join(CODE_ROOT, 'backend', 'locales', 'en.json')))

  # Messages that name the launcher take it as a placeholder. Any that spell it
  # out are wrong on one platform, whichever one they spell out.
  #
  # `service.no_systemd` is the exception and stays: systemd exists on Linux
  # only, so the sentence is never read on Windows.
  PERMITTED = { 'service.no_systemd' => 'systemd is Linux only, the sentence never reaches Windows' }.freeze

  def test_no_message_spells_out_a_launcher_that_only_one_platform_has
    offenders = paths(TEXTS).reject { |key, _| PERMITTED.key?(key) }
                            .select { |_, value| value.match?(/start_portable\.(sh|bat)/) }
                            .map { |key, value| "#{key}: #{value}" }

    assert_empty offenders.sort,
                 'name the launcher through a placeholder, not in the sentence'
  end

  # The counter-check: without it the sweep would pass over a table in which no
  # message mentions the launcher at all, and prove nothing.
  def test_the_sweep_reads_the_table_it_is_checking
    assert_operator paths(TEXTS).size, :>, 100, 'the text table was not read'
    assert paths(TEXTS).any? { |key, _| PERMITTED.key?(key) },
           'the permitted message is gone, so the exception above is stale'
  end

  def test_the_launcher_is_named_per_platform
    windows = with_platform(true) { PromptAtelier::Install.send(:launcher) }
    other   = with_platform(false) { PromptAtelier::Install.send(:launcher) }

    assert_equal 'scripts\\start_portable.bat', windows
    assert_equal 'scripts/start_portable.sh', other
  end

  private

  def paths(node, prefix = '')
    return [[prefix, node]] unless node.is_a?(Hash)

    node.flat_map { |key, value| paths(value, prefix.empty? ? key : "#{prefix}.#{key}") }
  end

  # `windows?` comes from the shared Script module. Replaced for the length of
  # the block rather than shelling out to a second platform.
  def with_platform(windows)
    subject = PromptAtelier::Install
    subject.define_singleton_method(:windows?) { windows }
    yield
  ensure
    subject.singleton_class.send(:remove_method, :windows?)
  end
end
