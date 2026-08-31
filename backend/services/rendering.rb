# frozen_string_literal: true

module PromptAtelier
  # The rendering pipeline — Requirements chapter 8, normative.
  #
  # This is the one place in the system where the same logic has to exist
  # twice: here for POST /prompts/:id/render, and in JavaScript for the live
  # preview. Both must produce **character-identical** output (NFA-14, R-01).
  # The 34 vectors in tests/vectors/rendering.json are read by both sides from
  # the same file; a difference shows up in the test run instead of at the
  # user, where it would mean the preview shows something other than what a
  # later model call receives.
  #
  # Deliberately free of any dependency on the web layer or the database: it
  # takes plain data and returns plain data. That is what makes it testable in
  # isolation, and it is required by NFA-14.
  module Rendering
    # What may stand between the braces, per 8.2: a letter followed by up to 39
    # letters, digits or underscores.
    #
    # **Letters, not ASCII letters** — changed in AP-23. The prompt text is the
    # user's content, not our implementation: whoever writes on Spanish names
    # their variable in Spanish. `{{año}}`, `{{prénom}}` and `{{città}}` used
    # to be no variables at all, and — worse — no error either. They were not
    # recognised, so they could not be reported as unknown; the placeholder
    # simply stood in the finished text, and the editor offered no field to
    # fill it in. Measured, not supposed.
    #
    # The length bound is part of the pattern, not a check afterwards: a key of
    # 41 characters is not a variable at all (14.3), so it must not even be
    # recognised as one. It counts **characters**, which is what `{0,39}` does
    # on a Ruby string.
    KEY = /[[:alpha:]][[:alnum:]_]{0,39}/

    # A variable reference: optionally escaped, optional inner whitespace, key
    # per 8.2.
    REFERENCE = /(\\)?\{\{[ \t]*(#{KEY})[ \t]*\}\}/

    # Something that was meant to be a reference and is not one.
    #
    # This exists because the failure it catches is **silent**. `{{2fa}}` and
    # `{{mi variable}}` do not match `REFERENCE`, so they are not substituted,
    # not reported as unknown, and not shown as a field — the text simply keeps
    # them, and whoever wrote the prompt finds out when they paste it into a
    # model. Widening the key to Unicode letters does not close that: it moves
    # the boundary, it does not remove it.
    #
    # The inner part is bounded and excludes braces, so a `{{` somewhere in a
    # long text cannot pair up with a `}}` a thousand characters later and
    # report the paragraph between them.
    CANDIDATE = /(\\)?\{\{([^{}\n]{0,80})\}\}/
    ESCAPED_OPENING = '\{{'
    BLOCK_SEPARATOR = "\n\n"

    # What the caller gets back. +text+ is the finished prompt; the other two
    # drive the preview (8.3) and the warnings in the render response (15.3).
    Result = Struct.new(:text, :unknown_keys, :missing_required, :rejected_keys,
                        keyword_init: true) do
      def complete? = missing_required.empty?
    end

    module_function

    # +body+       the prompt text
    # +variables+  metadata and bindings, each responding to key/value/
    #              default_value/required (symbol keys in a Hash also work)
    # +keywords+   active keywords, each with name/text/position/sort_order
    def render(body:, variables: [], keywords: [])
      table = variable_table(variables)

      substituted, unknown = substitute(body.to_s, table)   # step 2
      unescaped            = resolve_escapes(substituted)   # step 2b
      with_keywords        = apply_keywords(unescaped, keywords) # step 3
      normalized           = normalize(with_keywords)       # step 4

      Result.new(
        text: normalized,
        unknown_keys: unknown,
        missing_required: missing_required(table),
        rejected_keys: rejected_keys(body.to_s)
      )
    end

    # The placeholders somebody wrote that 8.2 does not accept — read from the
    # **original** text, before anything was substituted, because that is where
    # they still stand exactly as they were typed.
    #
    # An escaped one is not a mistake but a deliberate literal, and a valid one
    # is not a mistake either; what is left is what nobody will ever be able to
    # fill in.
    def rejected_keys(body)
      body.scan(CANDIDATE).filter_map do |escaped, inner|
        next if escaped

        candidate = inner.strip
        candidate unless candidate.match?(/\A#{KEY}\z/)
      end.uniq
    end

    # --- step 2: variables --------------------------------------------------

    # One pass, no recursion. A value that itself contains {{...}} stays as it
    # is — otherwise a variable value could smuggle in foreign variables or
    # cause an endless loop (8.2).
    #
    # Escaped references are stepped over here and only lose their backslash
    # in step 2b. Doing both at once would make the order of the two rules
    # unobservable, and the JavaScript side could get it wrong unnoticed.
# The keys a text actually references, lower-cased and in order of first
# occurrence. FA-301 derives the variable set of a prompt from this and
# from nothing else, so it has to use the very same pattern the renderer
# uses — two separate notions of "what is a variable" would let a prompt
# carry metadata for something that never renders, or render something
# that has no metadata.
#
# An escaped reference is not one (\{{x}} stays literal text), which is
# why the backslash group is consulted here as well.
def variable_keys(body)
  body.to_s.scan(REFERENCE).reject { |escaped, _| escaped }
      .map { |_, key| key.downcase }.uniq
end

    def substitute(body, table)
      unknown = []

      result = body.gsub(REFERENCE) do
        escaped = Regexp.last_match(1)
        key     = Regexp.last_match(2).downcase
        whole   = Regexp.last_match(0)

        next whole if escaped

        entry = table[key]
        if entry.nil?
          unknown << key unless unknown.include?(key)
          next whole
        end

        value_for(entry)
      end

      [result, unknown]
    end

    # User input, or the default when the input is empty, or empty text when
    # there is no default either (8.1 step 2). An empty input and no input at
    # all behave the same — the requirement says "falls Eingabe leer".
    def value_for(entry)
      value = entry[:value]
      return value.to_s unless value.nil? || value.to_s.empty?

      entry[:default_value].to_s
    end

    # --- step 2b: escapes ---------------------------------------------------

    # Applies to the **whole** result of step 2, including substituted values
    # (8.2). A position-dependent rule would be nearly impossible to implement
    # identically in two languages, and it is harmless here because no further
    # substitution follows.
    def resolve_escapes(text)
      text.gsub(ESCAPED_OPENING, '{{')
    end

    # --- step 3: keywords ---------------------------------------------------

    # Keyword texts are added here and never pass through steps 2 or 2b. A
    # {{placeholder}} inside a keyword stays untouched, and so does a
    # backslash before it — keywords are plain text blocks (E-05).
    def apply_keywords(text, keywords)
      sorted  = sort_keywords(keywords)
      prepend = block_for(sorted, 'prepend')
      append  = block_for(sorted, 'append')

      # The reject is belt and braces: step 4 would collapse the extra blank
      # lines an empty block leaves behind anyway. Verified by mutation — the
      # vectors stay green without it. Kept because the intermediate result is
      # then what 8.1 describes, which matters when reading a failure.
      [prepend, text, append].reject { |part| part.nil? || part.empty? }
                             .join(BLOCK_SEPARATOR)
    end

    # By sort_order, then by name. The second key is what makes the result
    # deterministic when two keywords share an order (TF-120); without it the
    # output would depend on the order they happen to arrive in.
    def sort_keywords(keywords)
      keywords.map { |keyword| symbolize(keyword) }
              .sort_by { |keyword| [keyword[:sort_order].to_i, keyword[:name].to_s] }
    end

    def block_for(sorted, position)
      sorted.select { |keyword| keyword[:position].to_s == position }
            .map { |keyword| keyword[:text].to_s }
            .reject(&:empty?)
            .join(BLOCK_SEPARATOR)
    end

    # --- step 4: normalisation ----------------------------------------------

    # The order of these four is load-bearing, and TF-134 is the vector that
    # proves it: with "A\n\n   \n\nB" — a line of nothing but spaces between
    # two blank ones — stripping first yields "A\n\nB", collapsing first
    # yields "A\n\n\n\nB". Without that vector the rule would have been
    # documented but untested; a mutation probe found the gap.
    def normalize(text)
      text
        .gsub(/\r\n?/, "\n")      # unify line endings
        .gsub(/[ \t]+$/, '')      # trailing whitespace per line
        .gsub(/\n{3,}/, "\n\n")   # at most one blank line in a row
        .sub(/\A\n+/, '')         # leading blank lines
        .sub(/\n+\z/, '')         # trailing blank lines
    end

    # --- helpers ------------------------------------------------------------

    def variable_table(variables)
      variables.each_with_object({}) do |variable, table|
        entry = symbolize(variable)
        key   = entry[:key].to_s.downcase
        next if key.empty?

        table[key] = entry
      end
    end

    # Required, and neither bound nor given a default (8.3). The preview is
    # still produced; the caller disables copying.
    def missing_required(table)
      table.select { |_key, entry| entry[:required] && value_for(entry).empty? }.keys
    end

    def symbolize(record)
      return record if record.is_a?(Hash) && record.keys.all?(Symbol)

      if record.is_a?(Hash)
        record.to_h { |key, value| [key.to_sym, value] }
      else
        %i[key value default_value required name text position sort_order]
          .each_with_object({}) do |field, result|
            result[field] = record.public_send(field) if record.respond_to?(field)
          end
      end
    end
  end
end
