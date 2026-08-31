# frozen_string_literal: true

require_relative '../../test_helper'

# TF-547 — what the console prints is English (AP-19, E-12).
#
# **The rule had no guard, and it had drifted.** Since AP-19 the shipped
# interface language is English and the console speaks English only — the
# German backend locale file was deleted for exactly that reason. Nothing
# checked it, and four German strings were sitting in production code when the
# packages were reviewed:
#
#   configuration.rb   "(not set)" in German      on every invalid value
#   schema_guard.rb    "(none)" in German         when the schema is too new
#   schema_guard.rb    "(empty)" in German        when the schema is too old
#   run_tests.rb       "no test files" in German  when a suite is skipped
#
# Each of them reached an operator's screen in the middle of an English
# sentence, and each was invisible to `one_language_test`, which guards the
# German **domain values** of the schema and not German prose. The words are
# described rather than quoted here on purpose: this file is one of the files
# both sweeps read, and an example inside a check is part of what it measures.
#
# **What this check is, and what it is not.** It reads the string literals of
# the production sources — the surface the console prints from — and refuses
# the German words it knows. It cannot prove a string is English; no test can.
# It is a net with a stated mesh size, and the size was chosen by what actually
# got through: `leer` is in the list because a first version of this list
# without it found three of the four. Whoever adds a German word not listed
# here will not be caught, and that is the honest limit of the thing.
#
# The other half of the surface — the locale file itself — is guarded by
# `i18n_languages_test`, and the two together are the whole of it: a string
# either comes from `backend/locales/en.json` or is a literal in these files.
class ConsoleLanguageTest < PromptAtelier::TestCase
  # Only the sources that print. Tests are excluded on purpose: they assert on
  # German display texts of the frontend (E-12) and would drown the signal.
  ROOTS = ['backend', 'scripts/lib'].freeze

  # `backend/migrations/` is excluded, and not for convenience. A migration is
  # a record of a state the database once had: 001 creates the schema with the
  # German status values that migration 005 later renamed. It prints nothing,
  # and rewriting it to satisfy this check would falsify the history every
  # later step is built on. The same reasoning stands behind PERMITTED in
  # `one_language_test` — whose sweep, incidentally, reads this file too, so
  # the words themselves must not be written out here.
  EXCLUDED = %r{/migrations/}

  # High-signal German words. Deliberately no `die`, `das`, `der` — they are
  # English words too, and a check that cries wolf gets switched off.
  #
  # The German **domain values** of the schema are deliberately absent as well.
  # `one_language_test` owns those, and listing them here would put the same
  # word under two sweeps that read each other's source: writing one down made
  # the other one red, which is how this division of labour was settled.
  GERMAN = %w[
    nicht keine kein leer Datei Dateien Fehler wurde wird werden
    und oder aber sonst nichts etwas damit dieser diese eine einer eines
    kann kann_nicht muss müssen sind ist war
    Sitzung Anwendung Verzeichnis Nutzer Passwort Sprache Zeile
    vorhanden fehlt bereits wieder immer gelöscht geändert
    für über möglich ungültig
  ].freeze

  WORD = /\b(?:#{GERMAN.join('|')})\b/i

  # Matches a single-quoted or double-quoted literal on one line. Deliberately
  # simple: a heredoc or a multi-line literal is not what this is hunting, and
  # a parser here would be a second implementation of Ruby to maintain.
  LITERAL = /'([^'\n]{3,})'|"([^"\n]{3,})"/

  def test_tf547_no_german_string_literal_reaches_the_console
    offenders = production_files.flat_map { |path| german_literals_in(path) }

    assert_empty offenders,
                 "German in a string the console prints:\n  #{offenders.join("\n  ")}"
  end

  # The counter-check. Without it the case above passes just as happily when
  # the glob is wrong, the roots have moved or the pattern matches nothing at
  # all — an empty sweep is the cheapest green there is.
  def test_tf547_the_sweep_really_reads_the_sources_and_the_pattern_really_bites
    files = production_files

    assert_operator files.size, :>, 30, 'the sweep found almost no sources — it is not looking where it thinks'
    assert_includes files.map { |f| File.basename(f) }, 'configuration.rb'
    assert_includes files.map { |f| File.basename(f) }, 'run_tests.rb'

    planted = "note('keine Testdateien')"

    assert_match WORD, planted[LITERAL, 1].to_s,
                 'the pattern does not even match the string this test was written for'
  end

  private

  def production_files
    ROOTS.flat_map { |root| Dir.glob(File.join(CODE_ROOT, root, '**', '*.rb')) }
         .reject { |path| path.include?('/vendor/') || path.match?(EXCLUDED) }
         .sort
  end

  def german_literals_in(path)
    File.readlines(path, encoding: 'UTF-8').each_with_index.flat_map do |line, index|
      next [] if line.strip.start_with?('#')

      code = line.split('#').first.to_s
      code.scan(LITERAL).flatten.compact
          .select { |literal| literal.match?(WORD) }
          .map { |literal| "#{path.sub("#{CODE_ROOT}/", '')}:#{index + 1}: #{literal.strip}" }
    end
  end
end
