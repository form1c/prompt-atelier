# frozen_string_literal: true

require 'json'

module PromptAtelier
  # User-facing texts, loaded from locales/<language>.json.
  #
  # NFA-15 and E-12 require that no user-facing text lives in the code. That
  # applies from the very first line: even the messages printed when the
  # configuration check fails come from here. Any exception would be exactly
  # the place where a later translation breaks.
  #
  # Deliberately implemented without a gem: the requirement is a lookup table
  # with placeholders — no pluralisation, no date formatting.
  module I18n
    class UnknownTextError < StandardError; end

    # What an instance speaks when nobody has said otherwise (AP-19). Was 'de'
    # until the interface learned to switch.
    DEFAULT_LANGUAGE = 'en'

    # Where the language of the **current request** is kept. Puma answers with
    # up to eight threads, so a process-wide value is a race — measured, not
    # assumed: two threads setting 'de' and 'fr' in a loop, and every single
    # read of the first came back in the other's language. A thread-local costs
    # nothing and cannot be read by the wrong request.
    CURRENT = :prompt_atelier_language

    # Built once per language and then never touched again. Set up here, at
    # load time, rather than lazily inside a method — a `||=` on first use is
    # itself the race this module exists to avoid.
    @tables = {}.freeze
    @mutex  = Mutex.new

    # The table every language is laid over.
    #
    # It holds what the **console** prints — the scripts, the startup abort,
    # the configuration check — and it holds it in English. Those messages are
    # read by whoever installs and operates the instance, on someone else's
    # machine, and they get pasted into search engines and issue trackers. An
    # English sentence finds answers there; a German one finds nothing.
    #
    # Everything the **browser** shows stays in the language file (E-12). The
    # two audiences are different, and so is the medium: a console has no
    # locale to ask.
    BASE_LANGUAGE = 'en'

    class << self
      # Directory holding the locale files. Set explicitly at startup so this
      # module never has to guess where it lives.
      attr_writer :directory

      def directory
        @directory ||= File.expand_path('../locales', __dir__)
      end

      # The language of this request, or the instance default when nothing has
      # been chosen for it — a script, a background sweep, the startup abort.
      def language
        Thread.current[CURRENT] || default_language
      end

      def default_language
        @default_language ||= DEFAULT_LANGUAGE
      end

      # The instance default, set once at startup from `config.yml`. If no
      # matching file exists the previous language is kept and +false+ is
      # returned; the caller decides whether that is an error. At startup it is
      # (the configuration check reports it), at runtime aborting would be out
      # of proportion.
      def default_language=(code)
        return false unless available?(code)

        @default_language = code.to_s
        true
      end

      # Runs the block in +code+. Anything the block prints, raises or answers
      # is in that language; afterwards the thread is exactly as it was.
      #
      # `ensure` and not a plain assignment at the end: a request that raises
      # would otherwise leave its language behind on a **pooled** thread, and
      # the next request on that thread would answer in a language nobody
      # asked for.
      def with_language(code)
        previous = Thread.current[CURRENT]
        Thread.current[CURRENT] = available?(code) ? code.to_s : nil
        yield
      ensure
        Thread.current[CURRENT] = previous
      end

      # The language of a request, in the order of 11.7:
      #
      #   1. the profile of whoever is signed in
      #   2. `locale` from config.yml — but only when the operator really wrote
      #      it there. The template carries a value too, and if that counted,
      #      step 3 could never happen and the header would be dead code
      #   3. `Accept-Language` — the step that decides the **first** screen,
      #      before any profile exists
      #   4. the base language
      #
      # Every candidate goes through +offered?+, and **not** through
      # +available?+ — that is the whole point, and it was wrong until AP-22
      # made it show.
      #
      # `available?` asks whether this directory holds a file. This directory
      # holds what the **console** prints, and the console speaks English
      # (E-12): after AP-19 there is no reason for a second file here at all.
      # The language that is being negotiated belongs to the **interface**, and
      # its files live in the bundle the browser loads, where the server cannot
      # count them.
      #
      # Tied to the files here, the chain answered `en` to a browser asking for
      # French while the interface had `fr.json` in the bundle — measured. So
      # the server checks the **shape** and relays the answer in
      # `Content-Language`; the browser, which knows what it carries, falls
      # back to English for a language it does not have (TF-532). One authority
      # per question, and the question is not the server's.
      #
      # The shape check is not a formality: `Accept-Language` is input from the
      # caller (SEC-04) and the result goes into a response header.
      def negotiate(profile: nil, configured: nil, accept_language: nil)
        candidates = [profile, configured, *preferred_from(accept_language)]
        candidates.compact.find { |code| offered?(code) } || BASE_LANGUAGE
      end

      # `de-DE,de;q=0.9,en;q=0.8` in the order the browser meant, each tag
      # followed by its primary subtag — a browser asking for `de-AT` should
      # get German when only `de.json` exists.
      def preferred_from(header)
        return [] if header.nil? || header.to_s.empty?

        header.to_s.split(',').filter_map { |part| weighted_tag(part) }
              .sort_by { |_tag, quality| -quality }
              .flat_map { |tag, _| [tag, tag.split('-').first] }
              .uniq
      end

      # A code this instance will carry: well formed, and nothing more.
      #
      # Empty is not a code — it is what "nobody has chosen here" looks like in
      # `config.yml` and in `users.locale`, and it has to fall through to the
      # next step of 11.7 rather than count as an answer.
      #
      # The pattern is narrow on purpose. Whatever passes here ends up in a
      # `Content-Language` header and in a column, so it may not carry a comma,
      # a newline or a path segment.
      def offered?(code)
        return false if code.nil? || code.to_s.empty?

        code.to_s.match?(/\A[a-z]{2}(-[A-Za-z]{2,4})?\z/)
      end

      # Whether **this** directory holds a table for a code — the console's
      # table, not the interface's. Used where a file is really about to be
      # read; for the question "may this instance speak that language", see
      # +offered?+.
      def available?(code)
        return false unless offered?(code)

        File.file?(File.join(directory, "#{code}.json"))
      end

      def available_languages
        Dir.glob(File.join(directory, '*.json')).map { |p| File.basename(p, '.json') }.sort
      end

      # Looks up a text. +key+ is a dotted path such as 'config.invalid_value'.
      # Placeholders of the form {name} are filled from +replacements+.
      #
      # A missing key is a programming error and fails loudly: silently
      # falling back to the key name would leak translation gaps all the way
      # to the user.
      def t(key, **replacements)
        value = key.to_s.split('.').reduce(texts) do |node, part|
          node.is_a?(Hash) ? node[part] : nil
        end

        raise UnknownTextError, "Unknown text key: #{key}" unless value.is_a?(String)

        interpolate(value, replacements)
      end

      # Like +t+ but never raises. For places that must still print something
      # even when the locale file is damaged — for instance the startup abort.
      def t_safe(key, fallback, **replacements)
        t(key, **replacements)
      rescue StandardError
        interpolate(fallback, replacements)
      end

      def reload!
        mutex.synchronize { @tables = {}.freeze }
      end

      private

      def texts = table_for(language)

      # The table of one language, built once and then frozen.
      #
      # **The read path takes no lock**, and it does not need one: a table is
      # never changed after it is built, and a new one is added by replacing
      # the whole registry with a new frozen Hash. No thread ever reads a Hash
      # that another is writing into — the worst case is two threads building
      # the same table at once, and the mutex settles that.
      def table_for(code)
        known = @tables
        return known[code] if known.key?(code)

        mutex.synchronize do
          return @tables[code] if @tables.key?(code)

          @tables = @tables.merge(code => build(code)).freeze
        end
        @tables[code]
      end

      # The base table with the language laid over it. A key the language file
      # does not carry is answered from the base — which is how the console
      # namespaces stay English while the interface speaks another language,
      # without a second lookup path through the code.
      #
      # Merged deeply, so a language may override a single entry of a
      # namespace without having to repeat the whole namespace. Replacing per
      # namespace would let a translation of one sentence take the other sixty
      # of that namespace with it.
      def build(code)
        base = read(BASE_LANGUAGE)
        deep_freeze(code == BASE_LANGUAGE ? base : deep_merge(base, read(code)))
      end

      def mutex = @mutex

      def deep_freeze(value)
        case value
        when Hash  then value.each_value { |inner| deep_freeze(inner) }.freeze
        when Array then value.each { |inner| deep_freeze(inner) }.freeze
        else value.freeze
        end
      end

      # One `de;q=0.9` entry. A malformed quality is not a reason to drop the
      # tag — browsers do send `q=` without a number — so it counts as 1.0 and
      # `available?` still has the last word on the tag itself.
      def weighted_tag(part)
        tag, *parameters = part.strip.split(';')
        return nil if tag.nil? || tag.empty? || tag == '*'

        quality = parameters.filter_map { |p| p[/\Aq=([\d.]+)\z/, 1] }.first
        [tag.strip, (Float(quality) rescue 1.0)]
      end

      def read(code)
        path = File.join(directory, "#{code}.json")
        return {} unless File.file?(path)

        JSON.parse(File.read(path, encoding: 'UTF-8'))
      end

      def deep_merge(lower, upper)
        lower.merge(upper) do |_key, a, b|
          a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b
        end
      end

      def interpolate(template, replacements)
        return template if replacements.empty?

        template.gsub(/\{(\w+)\}/) do
          name = Regexp.last_match(1).to_sym
          replacements.key?(name) ? replacements[name].to_s : Regexp.last_match(0)
        end
      end
    end
  end
end
