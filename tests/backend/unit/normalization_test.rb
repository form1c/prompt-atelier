# frozen_string_literal: true

require_relative '../../test_helper'
require 'sqlite3'

# FA-501 — search normalisation.
#
# Two things are proven here: that the rule keeps the promises the requirement
# makes, and that the Ruby and SQL implementations agree character for
# character. The second matters more than it looks: they run in different
# places (query side vs. trigger), and a difference between them means the
# index holds something the query never asks for. The search would then miss
# hits without any error anywhere.
class NormalizationTest < PromptAtelier::TestCase
  N = PromptAtelier::Normalization

  # The table in FA-501, spelled out. Left: the indexed word. Right: every
  # spelling that must find it.
  PROMISES = {
    'Größe' => %w[Grosse Groesse Größe GRÖSSE],
    'Übung' => %w[Ubung Uebung Übung ÜBUNG],
    'für'   => %w[fur fuer für FÜR],
    'Straße' => %w[Strasse Straße STRASSE],
    'Käse'  => %w[Kase Kaese Käse]
  }.freeze

  def test_every_promise_from_fa501_holds
    PROMISES.each do |word, spellings|
      indexed = N.normalize(word)
      spellings.each do |spelling|
        assert indexed.start_with?(N.normalize(spelling)),
               "#{spelling.inspect} must find #{word.inspect} " \
               "(indexed as #{indexed.inspect}, searched as #{N.normalize(spelling).inspect})"
      end
    end
  end

  # The case that made the documented rule fail. Kept as its own test so a
  # regression names itself.
  def test_grosse_finds_groesse
    assert_equal N.normalize('Größe'), N.normalize('Grosse')
    assert_equal N.normalize('Größe'), N.normalize('Groesse')
  end

  def test_case_is_ignored
    assert_equal 'grosse', N.normalize('GRÖSSE')
    assert_equal 'grosse', N.normalize('größe')
  end

  def test_nil_and_empty_are_safe
    assert_equal '', N.normalize(nil)
    assert_equal '', N.normalize('')
  end

  # Accents are deliberately NOT handled here — the tokenizer does it, for
  # indexed text and query alike. Doing it twice would be harmless but would
  # hide where the responsibility lies.
  def test_accents_are_left_to_the_tokenizer
    assert_equal 'café', N.normalize('Café')
  end

  # --- how the umlaut is encoded ------------------------------------------

  # TF-326: the same word can arrive precomposed (Ü = U+00DC) or decomposed
  # (U+0055 U+0308). Both look identical, and macOS hands out the second form
  # when copying. Before the composing step the decomposed term normalised to
  # "übung" — with the combining mark still attached — and found nothing.
  def test_a_decomposed_umlaut_normalises_like_a_precomposed_one
    PROMISES.each_key do |word|
      assert_equal N.normalize(word), N.normalize(word.unicode_normalize(:nfd)),
                   "#{word.inspect} must normalise the same however it is encoded"
    end
  end

  # TF-327: the promises of FA-501 have to hold for the decomposed spellings
  # too, not merely be equal to each other.
  def test_the_promises_hold_for_decomposed_input_as_well
    PROMISES.each do |word, spellings|
      indexed = N.normalize(word)
      spellings.each do |spelling|
        typed = N.normalize(spelling.unicode_normalize(:nfd))
        assert indexed.start_with?(typed),
               "decomposed #{spelling.inspect} must find #{word.inspect} " \
               "(indexed #{indexed.inspect}, searched #{typed.inspect})"
      end
    end
  end

  # TF-328: a search term is user input and may carry broken bytes. Composing
  # is impossible then; refusing to search would be the wrong answer.
  def test_invalid_bytes_do_not_raise
    broken = ["Gr\xF6\xDFe", "\xC3\x28", "\xFF\xFE"].map do |bytes|
      bytes.dup.force_encoding('UTF-8')
    end

    broken.each do |sample|
      result = N.normalize(sample)
      assert_kind_of String, result,
                     "#{sample.bytes.inspect} must come back as a string, not an exception"
    end

    # Counter-check: composing these directly is what would have raised.
    assert_raises(ArgumentError) { broken.first.unicode_normalize(:nfc) }
  end

  # --- one-way, and why that is safe --------------------------------------

  # The normalisation is applied to the indexed text and to the query, never
  # in reverse. There is deliberately no ss -> ß step anywhere, and there
  # cannot be a correct one: "Straße" and "Strasse" both become "strasse", so
  # the original is not recoverable from the normalised form. It does not need
  # to be — the original stays in title/description/body, untouched. The
  # mirror columns exist beside it, for the search alone.
  def test_the_normalised_form_is_not_reversible_and_does_not_have_to_be
    assert_equal N.normalize('Straße'), N.normalize('Strasse')
    assert_equal N.normalize('Grüße'),  N.normalize('Gruesse')
  end

  # A marker such as ß -> "SSS", meant to allow a way back, would separate
  # exactly the spellings FA-501 requires to meet: "Strasse" would stop
  # finding "Straße". Recorded as a test so the idea does not get tried again
  # without noticing what it costs.
  def test_a_reversible_marker_would_break_the_promise_of_fa501
    marker = lambda do |text|
      text.downcase.gsub('ß', 'SSS')
          .gsub('ä', 'a').gsub('ö', 'o').gsub('ü', 'u')
    end

    refute marker.call('Straße').start_with?(marker.call('Strasse')),
           'with a marker the two spellings no longer meet'
    assert N.normalize('Straße').start_with?(N.normalize('Strasse')),
           'without one they do — which is the point'
  end

  # Prefix search only works if a prefix of the input maps to a prefix of the
  # output. Not obvious: ß -> ss lengthens the string and ue -> u shortens it,
  # so a replacement could straddle the point where the user stopped typing.
  def test_normalising_a_prefix_yields_a_prefix_of_the_normalised_word
    %w[Straße Größe Übung Grüße Kaese Poesie Steuer Weißenburg Fußgänger
       Zürich Müßiggang Aussee].each do |word|
      full = N.normalize(word)

      (1..word.length).each do |length|
        typed = N.normalize(word[0, length])
        assert full.start_with?(typed),
               "typing #{word[0, length].inspect} of #{word.inspect} must still match: " \
               "#{typed.inspect} is not a prefix of #{full.inspect}"
      end
    end
  end

  # --- Ruby against SQL ---------------------------------------------------

  SAMPLES = [
    'Größe', 'ÜBUNG', 'für', 'Straße', 'ÄÖÜ', 'ÖL', 'Käse', 'Kaese',
    'Blogartikel', 'GROSSE', 'weiß', 'WEISS', 'Zürich', 'Muenchen',
    'gemäß §3', 'a', '', 'ss', 'ae oe ue', 'Ökosystem'
  ].freeze

  # Stated for precomposed input, which is what SQLite can express. The
  # decomposed case is covered by the next test.
  def test_ruby_and_sql_produce_identical_results
    db = SQLite3::Database.new(':memory:')
    expression = N.sql_expression('?')

    SAMPLES.each do |sample|
      composed  = sample.unicode_normalize(:nfc)
      from_sql  = db.get_first_value("SELECT #{expression}", composed)
      from_ruby = N.normalize(composed)

      assert_equal from_ruby, from_sql,
                   "Ruby and SQL disagree on #{sample.inspect}"
    end
  ensure
    db&.close
  end

  # TF-329: on decomposed input the two sides deliberately part ways. Ruby
  # composes first and folds the umlaut; SQL cannot compose and leaves the
  # combining mark in the mirror column. That is not a defect — the FTS5
  # tokenizer drops combining marks while indexing, so the mirror column is
  # indexed under the same token Ruby produces. This test pins the difference
  # so nobody "repairs" it by removing the composing step; that the two really
  # do meet is proven end to end in the search tests.
  def test_ruby_and_sql_differ_on_decomposed_input_by_design
    db = SQLite3::Database.new(':memory:')
    decomposed = 'Übung'.unicode_normalize(:nfd)

    from_sql = db.get_first_value("SELECT #{N.sql_expression('?')}", decomposed)

    assert_equal 'ubung', N.normalize(decomposed),
                 'Ruby composes first, so the umlaut folds'
    refute_equal 'ubung', from_sql,
                 'SQL cannot compose — it keeps the combining mark'
    assert_equal 'ubung', from_sql.unicode_normalize(:nfd).delete("̈"),
                 'and what the tokenizer indexes is the same token after all'
  ensure
    db&.close
  end

  # The reason the uppercase entries exist at all. If SQLite ever gained a
  # Unicode-aware lower(), this test would still pass — it asserts the
  # outcome, not the mechanism.
  def test_sql_handles_uppercase_umlauts_although_lower_does_not
    db = SQLite3::Database.new(':memory:')

    assert_equal 'ÄÖÜ', db.get_first_value('SELECT lower(?)', 'ÄÖÜ'),
                 'documenting that SQLite lower() is ASCII only'
    assert_equal 'aou', db.get_first_value("SELECT #{N.sql_expression('?')}", 'ÄÖÜ'),
                 'the explicit uppercase replacements have to cover for it'
  ensure
    db&.close
  end

  # --- TF-543: the ligature, and what must not change with it (AP-23) -------

  # `œ` is not a curiosity in French — *cœur*, *sœur*, *œuvre*, *bœuf*. Unicode
  # does not decompose a ligature, so the tokenizer cannot take it apart, and
  # before the rule existed the two spellings were two different values in the
  # index: `cœur` stayed `cœur` while `coeur` became `cour`. Whoever typed one
  # never found the other.
  def test_tf543_a_ligature_and_its_spelling_meet
    { 'Cœur' => 'coeur', 'Œuvre' => 'oeuvre', 'sœur' => 'soeur',
      'Encyclopædia' => 'encyclopaedia' }.each do |ligature, spelled|
      assert_equal N.normalize(spelled), N.normalize(ligature),
                   "#{ligature} and #{spelled} have to meet"
    end
  end

  # The counter-direction, and the one that matters more: FA-501 is a promise
  # about German, and none of AP-23 may weaken it. Without this case the split
  # into LETTERS and DIGRAPHS could quietly drop the digraph group and nothing
  # would say so.
  def test_tf543_the_german_promise_is_untouched
    assert_equal 1, %w[Größe Groesse Grosse].map { |w| N.normalize(w) }.uniq.size
    assert_equal 1, %w[Übung Uebung Ubung].map { |w| N.normalize(w) }.uniq.size
    assert_equal 'grosse', N.normalize('Größe')
  end

  # --- TF-542: identifiers (AP-23) -----------------------------------------

  # What a person sees in a URL and in a file name. Two rules of the search
  # have no place here, and both were measured doing damage:
  #
  #   * accents were not removed at all, because the search leaves that to the
  #     tokenizer — and a slug has no tokenizer. Every accented letter became
  #     a hyphen: `Résumé d'entretien` → `r-sum-d-entretien`
  #   * the German digraphs folded letter pairs that are ordinary in the other
  #     languages: `Año nuevo` → `a-o-nuvo`, `Città e paesi` → `citt-e-pasi`
  def test_tf542_an_identifier_keeps_the_word_a_person_reads
    {
      "Résumé d'entretien"    => 'resume-d-entretien',
      'Año nuevo'             => 'ano-nuevo',
      'Città e paesi'         => 'citta-e-paesi',
      'Cœur de métier'        => 'coeur-de-metier',
      'Prompts für Kündigung' => 'prompts-fur-kundigung',
      'Łódź'                  => 'lodz',
      '«¿Qué tal?»'           => 'que-tal'
    }.each do |name, expected|
      assert_equal expected, N.slug(name, fallback: 'x'), name
    end
  end

  # A name that is nothing but punctuation still has to yield a name.
  def test_tf542_a_name_that_folds_to_nothing_falls_back
    assert_equal 'workspace', N.slug('¿¡«»—', fallback: 'workspace')
    assert_equal 'workspace', N.slug('', fallback: 'workspace')
    assert_equal 'workspace', N.slug(nil, fallback: 'workspace')
  end

  # The two sides of the fold: Ruby decomposes, SQL cannot and names the
  # letters one by one. They have to agree, or a list would sort by one rule
  # and a slug read by another.
  def test_the_fold_says_the_same_in_ruby_and_in_sql
    db = SQLite3::Database.new(':memory:')

    ['Résumé', 'Año', 'Città', 'Cœur', 'Größe', 'Łódź', 'ÄÖÜ', 'Ærø'].each do |word|
      assert_equal N.fold(word), db.get_first_value("SELECT #{N.sql_fold_expression('?')}", word),
                   word
    end
  ensure
    db&.close
  end

  # The counter-check for the case above: the table really was derived, and it
  # really covers the letters the delivered languages are written with.
  def test_the_accent_table_is_derived_and_not_typed
    assert_operator N::ACCENTS.size, :>, 100

    %w[é à ç ñ ò ü ý].each do |letter|
      assert_includes N::ACCENTS.map(&:first), letter, "#{letter} has to be in the derived table"
    end
    assert N::ACCENTS.all? { |_, plain| plain.match?(/\A[a-z]\z/) },
           'every target is one plain lowercase letter'
  end
end
