# frozen_string_literal: true

require_relative '../../test_helper'
require 'services/transfer'

# The former name of the product, and the three places it may still stand.
#
# The rename to Prompt Atelier was done with a sweep, and a sweep is exactly
# the kind of change that leaves corners behind — the page title in an HTML
# file, an entry in a word list, a generated lockfile. Three of those were
# found by the client after the sweep had reported itself finished, which is
# the reason this case exists: the next rename gets a list rather than a
# search.
#
# It also guards the other direction, and that is the half that matters more.
# One of the leftovers was **deliberate**: the export format marker of files
# that already exist. The sweep renamed it too, and the backward compatibility
# was gone in the same change that introduced it (FA-804b). A blanket rename
# must not touch these, and a test that only looked for leftovers would have
# been happy about exactly that mistake.
class NamingTest < PromptAtelier::TestCase
  FORMER = /promptstorage/i

  # Every place the former name may still appear, with the reason. Anything
  # else is a leftover.
  PERMITTED = {
    'backend/services/transfer.rb' =>
      'FA-804b: files written under the former marker stay readable',
    'tests/backend/unit/transfer_test.rb' =>
      'the two cases that prove FA-804b, in both directions',
    'backend/wordlists/common_passwords.txt' =>
      'SEC-02 forbids choosing either name as a password, the former one included',
    'tests/backend/unit/naming_test.rb' =>
      'this file'
  }.freeze

  # Neither belongs to the sources: one is somebody elses code, the other is
  # what a test run leaves behind.
  SKIPPED = %w[vendor node_modules .git test-results].freeze

  def test_the_former_name_appears_only_where_it_is_meant_to
    offenders = source_files.reject { |path| PERMITTED.key?(relative(path)) }
                            .select { |path| carries_former_name?(path) }
                            .map { |path| relative(path) }

    refute_empty source_files, 'the sweep found no files at all, so it proved nothing'
    assert_empty offenders.sort,
                 'a leftover of the rename — or a new deliberate exception that belongs in PERMITTED'
  end

  # The counter-check, and the one that would have caught the real mistake:
  # the deliberate exceptions must still be there. A sweep that renamed them
  # away leaves this suite green on the case above and breaks compatibility
  # in silence.
  def test_the_deliberate_exceptions_still_carry_the_former_name
    missing = PERMITTED.keys.reject do |relative_path|
      path = File.join(CODE_ROOT, relative_path)
      File.file?(path) && carries_former_name?(path)
    end

    assert_empty missing,
                 'these carry the former name on purpose; losing it loses what it is for'
  end

  # And the specific one, named rather than left to the list above: an export
  # is somebody's backup.
  def test_the_former_export_marker_is_still_accepted
    assert_includes PromptAtelier::Transfer::FORMER_FORMATS, 'promptstorage-export'
  end

  private

  # Read as bytes, not as text. The former name is ASCII, so this works on any
  # file — and the first version read UTF-8 and **skipped the whole case** when
  # one file in the tree was not valid UTF-8. A skipped case asserts nothing;
  # it merely stops saying so.
  def carries_former_name?(path)
    File.binread(path).match?(FORMER)
  rescue SystemCallError
    false
  end

  def source_files
    Dir.glob(File.join(CODE_ROOT, '**', '*'), File::FNM_DOTMATCH)
       .select { |path| File.file?(path) }
       .reject { |path| SKIPPED.any? { |part| path.include?("/#{part}/") } }
  end

  def relative(path) = path.delete_prefix("#{CODE_ROOT}/")
end
