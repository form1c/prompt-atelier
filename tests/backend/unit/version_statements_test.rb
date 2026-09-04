# frozen_string_literal: true

require_relative '../../test_helper'
require 'json'
require 'version'

# TF-680 — the version is stated in one place and repeated in several.
#
# `backend/version.rb` is the source. npm insists on a `version` field of its
# own in both package files, and the manuals name the archive in their examples.
# None of those repetitions had anything holding them to the source, so raising
# the number in one place and leaving the others behind went unnoticed — which
# is how a release ends up shipping an archive whose name disagrees with the
# version the running instance reports.
class VersionStatementsTest < PromptAtelier::TestCase
  VERSION = PromptAtelier::VERSION

  # `promptatelier-1.2.3-universal`, the shape the manuals use in their
  # examples. Only a version that follows the product name counts, so a Ruby
  # series or a schema number in the same sentence is not mistaken for one.
  ARCHIVE = /promptatelier-(\d+\.\d+\.\d+)-/

  # `Prompt Atelier 1.2.3` in the head table of a manual.
  NAMED = /Prompt Atelier (\d+\.\d+\.\d+)/

  def test_tf680_both_package_files_state_the_version_of_the_source
    %w[package.json frontend/package.json].each do |name|
      stated = JSON.parse(File.read(File.join(CODE_ROOT, name)))['version']

      assert_equal VERSION, stated, "#{name} disagrees with backend/version.rb"
    end
  end

  def test_tf680_no_document_names_a_different_version
    offenders = documents.flat_map do |path|
      text = File.read(path, encoding: 'UTF-8')
      (text.scan(ARCHIVE) + text.scan(NAMED)).flatten.uniq
        .reject { |found| found == VERSION }
        .map { |found| "#{relative(path)}: #{found}" }
    end

    assert_empty offenders.sort, "a document names a version other than #{VERSION}"
  end

  # The counter-check. Without it the sweep would pass over a tree in which the
  # patterns match nothing at all, and prove exactly nothing.
  def test_tf680_the_sweep_finds_the_statements_it_is_looking_for
    found = documents.sum do |path|
      text = File.read(path, encoding: 'UTF-8')
      text.scan(ARCHIVE).size + text.scan(NAMED).size
    end

    assert_operator found, :>, 5, 'no version statement was read, so the check above proves nothing'
  end

  # TF-699 — the changelog names the version that is being built.
  #
  # **The one invariant `backend/version.rb` can be checked against.** Every
  # other case in this file compares *against* that file, so a forgotten bump
  # there leaves them all green. The changelog is the second place a release
  # is written down by hand, and the two have to agree.
  #
  # It catches both halves of the same slip: a version raised without a
  # changelog entry, and a changelog entry written without raising the version.
  def test_tf699_the_newest_changelog_entry_names_the_current_version
    assert_equal VERSION, changelog_versions.first,
                 'the newest entry of CHANGELOG.md and backend/version.rb disagree'
  end

  # And the entries descend. An entry inserted in the wrong place would
  # otherwise pass the case above whenever it happened to land on top.
  def test_tf699_the_changelog_entries_descend
    parts = changelog_versions.map { |v| v.split('.').map(&:to_i) }

    assert_operator parts.size, :>=, 1, 'no version headings found at all'
    assert_equal parts.sort.reverse, parts, "out of order: #{changelog_versions.inspect}"
  end

  # The counter-check: without it the two cases above would pass over a file in
  # which the pattern matches nothing.
  def test_tf699_the_changelog_is_actually_read
    refute_empty changelog_versions, 'no `## [x.y.z]` heading was found'
  end

  private

  def changelog_versions
    File.read(File.join(CODE_ROOT, 'CHANGELOG.md'), encoding: 'UTF-8')
        .scan(/^## \[(\d+\.\d+\.\d+)\]/).flatten
  end


  # The delivered documents. `CHANGELOG.md` is left out on purpose: it names
  # every released version by design, and older entries have to keep standing.
  def documents
    (Dir.glob(File.join(CODE_ROOT, 'doc', '*.md')) +
     Dir.glob(File.join(CODE_ROOT, 'README*.md'))).sort
  end

  def relative(path) = path.delete_prefix("#{CODE_ROOT}/")
end
