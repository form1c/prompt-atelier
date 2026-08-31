# frozen_string_literal: true

require_relative '../../test_helper'
require 'services/prompts'
require 'services/transfer'

# TF-463 — one language in the source: no German domain value is left (AP-18).
#
# **Why a test and not a search done once.** An incomplete replacement is
# silent. `status: 'aktiv'` in a case that finds nothing after the migration
# becomes a green test over an empty set; a forgotten `'privat'` in a service
# becomes a query that matches no row and refuses nothing. Neither says a word.
# The sweep of AP-18 was carried out by hand, and a sweep is exactly the kind
# of change that leaves corners behind — so what is checked here is the
# **absence** of the old words, over the whole tree, on every run.
#
# It guards the other direction too, and that half matters more. A handful of
# places keep the German spellings **on purpose** — see PERMITTED — and a later
# sweep that tidied them away would leave this file green on the case above
# while breaking the reading of old export files. That is the same mistake
# naming_test.rb was written for after it had already happened once.
class OneLanguageTest < PromptAtelier::TestCase
  OLD_VALUES = %w[
    aktiv gesperrt privat instanz entwurf archiviert
    mehrzeilig auswahl zahl relevanz geaendert titel
  ].freeze

  WORD = OLD_VALUES.join('|')

  # **The three shapes a domain value can take**, and nothing else.
  #
  # Searching for the bare word reported four places that are none of this
  # file's business, and each of them is a kind worth naming:
  #
  #   'Ganz privat'                    a German prompt title — user content
  #   'ist die Anwendung gesperrt'     an assertion on a display text (E-12)
  #   /wieder auf privat gesetzt/      the same, as a pattern
  #   "Kein Keyword aktiv"             a prompt title among the render vectors
  #
  # Widening PERMITTED to cover them would take whole files out of the check —
  # and `prompt_screen.test.js` is 800 lines in which a real leftover could
  # then hide. So the rule is sharpened instead of the exception widened: a
  # value is a **whole** string literal, a query parameter, or a member of a
  # `%w[]` list. Those are the three forms AP-18 actually translated, and a
  # regression would arrive in one of them.
  SHAPES = [
    /(['"])(#{WORD})\1/,           # 'privat'  "privat"  — the whole literal
    /[a-z_]=(#{WORD})(?![[:alnum:]_])/, # status=aktiv, sort=titel
    /%w\[[^\]]*(?<![[:alnum:]_])(#{WORD})(?![[:alnum:]_])[^\]]*\]/ # %w[privat workspace]
  ].freeze

  # Where an old word may still stand, and why. Anything else is a leftover.
  PERMITTED = {
    'backend/migrations/001_initial.rb' =>
      'the schema as it was on the first day — a migration is history, not present tense',
    'backend/migrations/005_english_domain_values.rb' =>
      'the translation itself: WHEN \'aktiv\' THEN \'active\'',
    'backend/services/transfer.rb' =>
      'Transfer::LEGACY_VALUES reads version 1 files, where the words are data',
    'tests/backend/unit/english_domain_values_test.rb' =>
      'migrates a stock in the old format and imports a version 1 file',
    'tests/backend/unit/migrator_test.rb' =>
      'builds a database migrated to 002 only, where the German CHECK still holds',
    'tests/backend/unit/one_language_test.rb' =>
      'this file'
  }.freeze

  # The display stays German (E-12), and so do the documents. Neither is a
  # domain value, and a rule that reached into them would be the rule that
  # broke four sentences of de.json during AP-18.
  SKIPPED = %w[vendor node_modules .git test-results locales public dist].freeze

  # Only what is actually source. `examples/` counts: the package is delivery
  # content and carries the domain values of the format (BT-17, FA-802).
  EXTENSIONS = %w[.rb .js .vue .json .css .html .yml .sh .bat].freeze

  def test_no_german_domain_value_is_left_in_the_source
    offenders = source_files.reject { |path| PERMITTED.key?(relative(path)) }
                            .filter_map do |path|
                              found = german_words_in(path)
                              "#{relative(path)}: #{found.uniq.sort.join(', ')}" unless found.empty?
                            end

    refute_empty source_files, 'the sweep found no files at all, so it proved nothing'
    assert_empty offenders.sort,
                 'a leftover of AP-18 — or a new deliberate exception that belongs in PERMITTED'
  end

  # The counter-check. Without it the case above passes just as happily after
  # somebody has translated the compatibility table away — and then a file
  # written before AP-18 is unreadable, which is precisely what A-10 forbids.
  def test_the_deliberate_exceptions_still_carry_the_old_words
    missing = PERMITTED.keys.reject do |relative_path|
      path = File.join(CODE_ROOT, relative_path)
      File.file?(path) && !german_words_in(path).empty?
    end

    assert_empty missing,
                 'these carry the old spellings on purpose; losing them loses what they are for'
  end

  # And the two that carry the promise, named rather than left to a file list:
  # the values the application writes, and the ones it still reads.
  def test_the_shipped_vocabulary_is_english
    assert_equal %w[private workspace instance], PromptAtelier::Prompts::VISIBILITIES
    assert_equal %w[draft active archived], PromptAtelier::Prompts::STATUSES
    assert_equal %w[text multiline select number], PromptAtelier::Prompts::VARIABLE_TYPES
  end

  def test_a_file_from_before_the_rename_is_still_readable
    legacy = PromptAtelier::Transfer::LEGACY_VALUES

    assert_equal 'private', legacy['visibility']['privat']
    assert_equal 'draft', legacy['status']['entwurf']
    assert_equal 'number', legacy['type']['zahl']
    assert_includes PromptAtelier::Transfer::READABLE_VERSIONS, 1
  end

  private

  # Read as bytes and matched case-sensitively. The old words are lower case
  # as values; `Auswahl` at the start of a German sentence is display text and
  # must not be reported. Reading as text would skip a file that is not valid
  # UTF-8, and a skipped file asserts nothing.
  def german_words_in(path)
    source = File.binread(path).force_encoding('UTF-8').scrub('')
    SHAPES.flat_map { |shape| source.scan(shape) }
          .flatten
          .select { |found| OLD_VALUES.include?(found) }
  rescue SystemCallError
    []
  end

  def source_files
    Dir.glob(File.join(CODE_ROOT, '**', '*'))
       .select { |path| File.file?(path) && EXTENSIONS.include?(File.extname(path)) }
       .reject { |path| SKIPPED.any? { |part| path.include?("/#{part}/") } }
  end

  def relative(path) = path.delete_prefix("#{CODE_ROOT}/")
end
