# frozen_string_literal: true

module PromptAtelier
  # Search normalisation (FA-501).
  #
  # The same text has to be normalised in two places: in Ruby, when a search
  # term is turned into a query, and in SQL, when a trigger fills the mirror
  # columns. Both are defined here so they cannot drift apart — a difference
  # between them would mean the index holds something the query never asks
  # for, and the search would silently miss hits.
  #
  # Why not a custom SQL function registered from Ruby: a trigger calling it
  # would only work on connections that registered it. Neither the FTS5
  # `rebuild` command nor the sqlite3 command line does. Plain SQL keeps both
  # usable without special handling.
  module Normalization
    # Applied in this order, after lowercasing:
    #
    #   1. uppercase umlauts and capital sharp s — see the note on lower()
    #   2. lowercase umlauts and sharp s
    #   3. the digraph spellings ae/oe/ue
    #
    # Step 3 is what makes the promise in FA-501 hold. Mapping only ö -> oe
    # (or only ö -> o) satisfies one spelling and misses the other: with
    # ö -> oe the index holds "groesse", and someone typing "Grosse" finds
    # nothing. Folding both spellings onto the base vowel makes "Größe",
    # "Groesse" and "Grosse" meet at "grosse".
    #
    # The price is deliberate: "Koeffizient" and "Koffizient" collapse, as do
    # "Poesie"/"Posie" and "Zuege"/"Zuge". For a prompt library of this size
    # recall is worth more than that sharpness — a search that fails to find
    # an existing prompt costs more than one extra hit in the list.
    # Letters with a **stroke** are the second group, added in AP-18. The
    # tokenizer (unicode61 remove_diacritics 2) folds é, à, ç and their kin on
    # both sides, so those need no rule here — measured over seven languages,
    # 47 probes, and French, Spanish, Italian and Portuguese came back clean.
    # Two did not:
    #
    #   pl   Łódź   searched: lodz   not found
    #   da   rød    searched: rod    not found
    #
    # Unicode does not decompose a stroke: it is part of the letter, not a
    # diacritic, so `remove_diacritics` cannot take it off. German ß is in the
    # table by hand for exactly that reason. `œ` joined them in AP-23 — it is a
    # **ligature**, which Unicode does not decompose either, and it is not a
    # curiosity in French: *cœur*, *sœur*, *œuvre*, *bœuf*. Measured before the
    # rule existed: `Cœur` was indexed as `cœur` and `coeur` as `cour`, two
    # values that never meet, so whoever typed one spelling never found the
    # other. Still uncovered and knowingly so: `ħ` and `ŧ`.
    # A ligature is **spelled out**, not folded onto one vowel: `œ` becomes
    # `oe`, `æ` becomes `ae`. For the search that changes nothing — the digraph
    # group below runs afterwards and folds `oe` to `o`, so `cœur` and `coeur`
    # still meet at `cour`. For an identifier it changes everything, and the
    # first version got it wrong: `Cœur de métier` came out as `cour-de-metier`
    # instead of `coeur-de-metier`, which is not how anybody writes it.
    LETTERS = [
      ['Ä', 'a'], ['Ö', 'o'], ['Ü', 'u'], ['ẞ', 'ss'],
      ['ä', 'a'], ['ö', 'o'], ['ü', 'u'], ['ß', 'ss'],
      ['Ø', 'o'], ['Ł', 'l'], ['Đ', 'd'], ['Æ', 'ae'], ['Œ', 'oe'],
      ['ø', 'o'], ['ł', 'l'], ['đ', 'd'], ['æ', 'ae'], ['œ', 'oe']
    ].freeze

    # The digraph spellings, and the reason they are a group of their own since
    # AP-23: they are a **German** rule, and they damage the other languages.
    #
    # For the search that is a price worth paying, because the same rule runs
    # over the stored text and over the search term, so both sides meet at the
    # same word — `nuevo` and `nuvo` collapse, and nobody types the second.
    # It costs sharpness, not hits, and FA-501 has already weighed that.
    #
    # For an **identifier** there is no second side to meet: what comes out is
    # what a person sees in a URL and in a file name. `Año nuevo` became
    # `a-o-nuvo` and `Città e paesi` became `citt-e-pasi` — measured. So the
    # slug takes the letters and leaves these alone.
    DIGRAPHS = [['ae', 'a'], ['oe', 'o'], ['ue', 'u']].freeze

    # Order matters. All single letters run before the digraphs, so that ö -> o
    # cannot turn "öe" into an "oe" that the last group folds a second time.
    REPLACEMENTS = (LETTERS + DIGRAPHS).freeze

    # Accented letters and the plain letter behind each, **derived** rather
    # than typed: every code point of Latin-1 Supplement and Latin Extended-A
    # that decomposes into one ASCII letter plus marks. 161 of them, and not
    # one is a chance to make a typo.
    #
    # Needed in two places where the tokenizer cannot help, because there is no
    # tokenizer: an identifier (`Résumé` must not become `r-sum`) and the sort
    # key of a list. Deliberately **not** in the search table — there the
    # tokenizer already folds é, à and ç on both sides, and putting 161 more
    # `replace()` calls into a trigger that runs over a prompt body of up to
    # 200,000 characters would be paid for on every single write.
    ACCENTS = (0x00C0..0x017F).filter_map do |code_point|
      accented = code_point.chr(Encoding::UTF_8)
      plain    = accented.unicode_normalize(:nfd).gsub(/\p{Mn}/, '')
      next unless plain != accented && plain.match?(/\A[A-Za-z]\z/)

      [accented, plain.downcase]
    end.freeze

    module_function

    # normalize(text) per FA-501. Remaining diacritics (é, à, ç …) are handled
    # by the tokenizer (unicode61 remove_diacritics 2), not here — it applies
    # to indexed text and query alike, so "Cafe" finds "Café" without a rule.
    def normalize(text)
      return '' if text.nil?

      REPLACEMENTS.reduce(compose(text.to_s).downcase) do |result, (from, to)|
        result.gsub(from, to)
      end
    end

    # An umlaut can arrive in two encodings: precomposed as one character
    # (Ü = U+00DC) or decomposed as a base letter plus a combining mark
    # (U+0055 U+0308). They look identical on screen. macOS produces the
    # decomposed form when copying, and REPLACEMENTS only matches the first,
    # so without this step a term pasted from there finds nothing at all —
    # not even a prompt stored in that very same form.
    #
    # Only the query side needs this. The mirror columns are filled by SQL,
    # which cannot compose, but the tokenizer drops combining marks while
    # indexing, so both sides meet one step later. That is why the Ruby/SQL
    # comparison below is stated for precomposed input only.
    # Broken bytes are dropped here rather than passed on: downcase raises on
    # invalid UTF-8 just as unicode_normalize does, so letting them through
    # would only move the exception one line further down. A search term is
    # user input and must never be able to raise.
    def compose(text)
      safe = text.valid_encoding? ? text : text.scrub('')
      safe.unicode_normalize(:nfc)
    rescue ArgumentError, Encoding::CompatibilityError
      # Not UTF-8 at all (binary, say). Nothing to compose, nothing to fix.
      safe
    end

    # Text reduced to plain lowercase letters — for an **identifier** and for a
    # **sort key**, not for the search.
    #
    # Two differences to +normalize+, and both are the point:
    #
    #   * the digraphs are left alone, so `nuevo` stays `nuevo`
    #   * the accents come off, because here nothing else will take them off
    #
    # The accents are removed by decomposing and dropping the marks, which
    # covers every language and not only the ones somebody listed. `ACCENTS` is
    # the same rule written out for SQL, where decomposing is not available.
    def fold(text)
      return '' if text.nil?

      stripped = compose(text.to_s).downcase.unicode_normalize(:nfd).gsub(/\p{Mn}/, '')
      LETTERS.reduce(stripped) { |result, (from, to)| result.gsub(from, to) }
    end

    # A name reduced to what may stand in a URL and in a file name (15.1).
    #
    # Built on +fold+ and not on +normalize+: an identifier is read by a person
    # and has no second side to meet, so the German digraph rule has no place
    # in it. Before the split, `Résumé d'entretien` came out as
    # `r-sum-d-entretien` — every accented letter had turned into a hyphen.
    def slug(text, fallback: nil)
      base = fold(text).gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')

      base.empty? ? fallback.to_s : base
    end

    # The same rule as a SQL expression, for use inside triggers.
    # +column+ is inserted verbatim, so it must never come from user input.
    #
    # SQLite's lower() only folds ASCII: lower('ÜBUNG') is 'Übung', and 'ÄÖÜ'
    # comes back unchanged — verified, not assumed. Ruby's downcase in
    # contrast is Unicode-aware. The uppercase entries in REPLACEMENTS bridge
    # that difference: in Ruby they are no-ops because downcase already
    # handled them, in SQL they do the actual work. Both sides end up with the
    # same string, which is the only thing that matters.
    def sql_expression(column)
      sql_for(REPLACEMENTS, column)
    end

    # +fold+ as a SQL expression, for the sort key of a list.
    #
    # SQLite cannot decompose, so the accents are named one by one — from
    # `ACCENTS`, which is derived from Unicode, so the two sides cannot drift
    # apart by a typo. It is a long expression, and that is affordable **here**
    # and nowhere else: it runs over a title of at most a few dozen characters,
    # not over a prompt body.
    def sql_fold_expression(column)
      sql_for(LETTERS + ACCENTS, column)
    end

    def sql_for(table, column)
      table.reduce("lower(#{column})") do |inner, (from, to)|
        "replace(#{inner}, '#{from}', '#{to}')"
      end
    end
  end
end
