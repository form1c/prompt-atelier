# frozen_string_literal: true

require_relative 'normalization'
require_relative 'access'

module PromptAtelier
  # Full text search over prompts (FA-501, FA-504).
  #
  # Two things have to happen to a search term before it reaches SQLite, and
  # neither is optional:
  #
  #   1. the same normalisation the indexed text went through, or the query
  #      asks for something the index does not contain (FA-501)
  #   2. neutralisation of the FTS5 query language, or the user is writing
  #      queries instead of searching
  #
  # The second is not cosmetic. Passing a term through raw makes SQLite raise
  # for something as ordinary as an unbalanced quote:
  #
  #   MATCH '"* OR 1=1'   ->  SQLite3::SQLException: unterminated string
  #
  # FA-501 requires that a special character never produces an error, so every
  # word is quoted and everything between the words is dropped.
  module Search
    # bm25 weights, one per FTS column: title, description, body, tags.
    # Higher weight means a hit there counts for more (FA-501, "Gewichtung:
    # Titel vor Beschreibung vor Text"). Tags sit between description and
    # body: someone who tags a prompt "seo" means it more deliberately than
    # someone who mentions seo somewhere in a long text.
    WEIGHTS = { title: 10.0, description: 5.0, body: 1.0, tags: 3.0 }.freeze

    # bm25 returns negative numbers, more negative meaning a better match, so
    # results are ordered ascending. Naming it in one place avoids the
    # reflex to write DESC.
    RANK_EXPRESSION = "bm25(prompts_fts, #{WEIGHTS.values.join(', ')})"

    module_function

    # The normalised words of a term. Everything that is not a letter or a
    # digit separates words and is otherwise discarded — that is what turns
    # query syntax into nothing.
    def terms(term)
      Normalization.normalize(term.to_s).scan(/[[:alnum:]]+/)
    end

    # The FTS5 MATCH expression, or nil when the term carries no searchable
    # word at all. nil means "no text filter", not "no results": a search box
    # holding only spaces should not empty the library.
    #
    # Each word becomes a quoted prefix token. Quoting makes FTS5 read it as a
    # string rather than as syntax; the trailing * is the prefix rule from
    # FA-501. Several tokens are implicitly AND-connected, which is exactly
    # what FA-501 asks for.
    def match_expression(term)
      words = terms(term)
      return nil if words.empty?

      words.map { |word| %("#{word}"*) }.join(' ')
    end

    # Searches and returns prompt rows, best match first.
    #
    # +workspace_ids+ restricts to those workspaces. It is deliberately a
    # required-feeling parameter rather than an optional one: leaving it out
    # searches everything, and in a multi-tenant schema that is the mistake
    # worth making hard to make by accident (SEC-06). The permission layer in
    # AP-06 decides what goes in here.
    # +visible_for+ is the id of the person searching. Passing it applies the
    # visibility rule of SEC-06 inside the query, which is the only place it
    # can work: filtering afterwards would make LIMIT and the ranking count
    # rows the caller may not see, so page one could come back half empty
    # while matches exist further down.
    #
    # It is deliberately not optional-by-default in spirit — FA-502 says the
    # search must not become a way round the visibility, and TF-203 is the
    # case where a private prompt is searched for by its content.
    def find(db, term: nil, workspace_ids: nil, tag_ids: nil, visible_for: nil,
             status: nil, visibility: nil, owner_id: nil, favorites_of: nil,
             sort: nil, include_deleted: false, limit: 50, offset: 0)
      query = build(db, term: term, workspace_ids: workspace_ids, tag_ids: tag_ids,
                        visible_for: visible_for, status: status, visibility: visibility,
                        owner_id: owner_id, favorites_of: favorites_of,
                        include_deleted: include_deleted)
      return [] if query.nil?

      order = order_for(sort, query[:expression]) || query[:order]
      sql = "SELECT p.* FROM #{query[:source]} WHERE #{query[:conditions].join(' AND ')} " \
            "ORDER BY #{order} LIMIT ? OFFSET ?"

      db.fetch(sql, *query[:values], limit, offset).all
    end

    # How many rows the same query would return without LIMIT — the
    # `meta.total` of 15.1. Built from the same pieces so the count cannot
    # describe a different result set than the page does.
    def count(db, term: nil, workspace_ids: nil, tag_ids: nil, visible_for: nil,
              status: nil, visibility: nil, owner_id: nil, favorites_of: nil,
              include_deleted: false)
      query = build(db, term: term, workspace_ids: workspace_ids, tag_ids: tag_ids,
                        visible_for: visible_for, status: status, visibility: visibility,
                        owner_id: owner_id, favorites_of: favorites_of,
                        include_deleted: include_deleted)
      return 0 if query.nil?

      db.fetch("SELECT count(*) AS total FROM #{query[:source]} WHERE #{query[:conditions].join(' AND ')}",
               *query[:values]).single_value
    end

    # Source, conditions and values — everything both of the two above need.
    # Returns nil when the answer can only be empty.
    #
    # Not marked private: `module_function` is in force in this module, and a
    # `private` under it produces an instance method without the module method
    # beside it — the two callers above would then not find it. Meant to be
    # internal all the same.
    #
    # **Every filter belongs in here, not behind it.** Filtering the returned
    # page afterwards would let LIMIT and the ranking count rows that the
    # filter then removes: `meta.total` would describe a different set than
    # the page, and page one could come back half empty while matches sit
    # further down. Found when the library screen started showing the count.
    def build(db, term:, workspace_ids:, tag_ids:, visible_for:, status:,
              visibility:, owner_id:, favorites_of:, include_deleted:)
      expression = match_expression(term)
      conditions = []
      values     = []

      if expression
        source = 'prompts_fts JOIN prompts p ON p.id = prompts_fts.rowid'
        conditions << 'prompts_fts MATCH ?'
        values << expression
        order = "#{RANK_EXPRESSION} ASC"
      else
        source = 'prompts p'
        order  = 'p.updated_at DESC, p.id DESC'
      end

      conditions << 'p.deleted_at IS NULL' unless include_deleted

      if workspace_ids
        ids = Array(workspace_ids)
        # SQLite happens to accept "IN ()" and treat it as always false, so
        # this guard is not what makes an empty list find nothing — verified.
        # It stays because relying on that leniency would be relying on a
        # non-standard extension for a security-relevant condition (SEC-06).
        return nil if ids.empty?

        conditions << "p.workspace_id IN (#{ids.map { '?' }.join(', ')})"
        values.concat(ids)
      end

      if tag_ids && !Array(tag_ids).empty?
        ids = Array(tag_ids)
        # All of them, not any of them (FA-504, TF-320). HAVING count over the
        # matched rows is what turns OR into AND.
        conditions << <<~SQL.strip
          p.id IN (SELECT prompt_id FROM prompt_tags
                    WHERE tag_id IN (#{ids.map { '?' }.join(', ')})
                    GROUP BY prompt_id HAVING count(*) = #{ids.size})
        SQL
        values.concat(ids)
      end

      # 11.3: archived prompts appear only when they are asked for. Without a
      # status the library shows the rest; with one it shows exactly that one.
      if status
        conditions << 'p.status = ?'
        values << status
      elsif !include_deleted
        conditions << "p.status <> 'archived'"
      end

      if visibility
        conditions << 'p.visibility = ?'
        values << visibility
      end

      if owner_id
        conditions << 'p.owner_id = ?'
        values << owner_id.to_i
      end

      # FA-505: favourites belong to the person, never to the prompt.
      if favorites_of
        conditions << 'p.id IN (SELECT prompt_id FROM favorites WHERE user_id = ?)'
        values << favorites_of
      end

      if visible_for
        fragment, own = Access.visible_prompts_condition(db, visible_for, table: 'p')
        conditions << "(#{fragment})"
        values.concat(own)
      end

      { source: source, conditions: conditions, values: values,
        order: order, expression: expression }
    end

    # FA-507. Relevance is only meaningful with a search term; asking for it
    # without one falls back to the default rather than failing, because the
    # interface keeps the sort setting while the term is being cleared.
    # `title_sort` and not `title COLLATE NOCASE`: SQLite compares bytes, and
    # `NOCASE` folds the ASCII range and nothing else. Measured on the raw
    # column:
    #
    #   ["Anfang", "Zebra", "apple", "Ábaco", "Éclair", "Œuvre"]
    #
    # Capitals first, then lower case, then everything accented at the end —
    # wrong for German already, and with three accent-rich languages it stops
    # looking like an order at all. `title_sort` is the title folded to plain
    # lowercase letters (migration 006), and it carries an index.
    SORTS = {
      'relevance' => nil,
      'changed' => 'p.updated_at DESC, p.id DESC',
      'title' => 'p.title_sort ASC, p.id ASC'
    }.freeze

    def order_for(sort, expression)
      return nil if sort.nil? || !SORTS.key?(sort)
      return expression ? nil : SORTS['changed'] if sort == 'relevance'

      SORTS[sort]
    end

    # --- highlighting (14.1) -------------------------------------------------

    # Ranges [start, length] in the ORIGINAL text that a search term matches.
    #
    # Not produced with snippet() or highlight(): those return the normalised
    # text, so the user would be shown "grosse" where the prompt says "Größe"
    # (14.1). Instead the original is split into words, each word is put
    # through the same normalisation, and whole words are reported.
    #
    # Whole words rather than the matched prefix on purpose. Mapping a
    # position in the normalised string back to the original is not
    # well-defined — "ß" becomes two characters, "ue" becomes one — so any
    # character-exact answer would need an index map that both the Ruby and
    # the JavaScript side would have to reproduce identically. Highlighting
    # the whole word avoids that entirely and reads better anyway: for "blog"
    # the eye wants "Blogartikel" marked, not just its first four letters.
    def highlight_ranges(text, term)
      needles = terms(term)
      return [] if needles.empty? || text.to_s.empty?

      ranges = []
      text.to_s.scan(/[[:alnum:]]+/) do
        match      = Regexp.last_match
        normalized = Normalization.normalize(match[0])
        next unless needles.any? { |needle| normalized.start_with?(needle) }

        ranges << [match.begin(0), match[0].length]
      end
      ranges
    end
  end
end
