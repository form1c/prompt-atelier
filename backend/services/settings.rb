# frozen_string_literal: true

require 'json'

require_relative 'configuration'

module PromptAtelier
  # The settings an administrator may change from the browser (FA-910).
  #
  # Which ones those are is the whole design decision, and it is a short list
  # on purpose — see `migrations/004_settings.rb` for why the operating values
  # are not on it.
  #
  # Two properties make this workable without a restart button:
  #
  #   * The application reads its configuration on **every** request, so a
  #     changed value takes effect with the next one.
  #   * The rules are `Configuration::RULES` — the same ones that judge
  #     config.yml. A value typed into a form and a value written into the file
  #     are measured alike, and there is no second place where "a positive
  #     number" is defined.
  module Settings
    # Ordered as the screen shows them. Every key must appear in
    # Configuration::RULES; a test holds the two together.
    EDITABLE = %w[
      security.registration
      security.registrations_per_hour
      security.login_attempts_per_account
      security.login_attempts_per_ip
      security.lockout_minutes
      retention.revisions_per_prompt
      retention.revisions_min_days
      retention.trash_days
      retention.audit_months
      retention.audit_max_entries
      retention.login_attempts_days
    ].freeze

    class Refused < StandardError
      attr_reader :fields

      def initialize(fields)
        @fields = fields
        super(fields.keys.join(', '))
      end
    end

    # A configuration with the stored settings laid over it.
    #
    # Answers `[]` like Configuration itself, so every existing caller keeps
    # working unchanged — `Registration.mode`, `RateLimit.per_ip`,
    # `Retention.limits` and the rest ask a lookup, not a file.
    class View
      def initialize(configuration, overrides)
        @configuration = configuration
        @overrides = overrides
      end

      def [](key)
        return @overrides[key.to_s] if @overrides.key?(key.to_s)

        @configuration&.[](key)
      end

      # Everything else a Configuration is asked for goes straight through:
      # paths, the installation root, the notes. Only the values are layered.
      def method_missing(name, *args, &block)
        @configuration.respond_to?(name) ? @configuration.send(name, *args, &block) : super
      end

      def respond_to_missing?(name, include_private = false)
        @configuration.respond_to?(name, include_private) || super
      end
    end

    class << self
      # The stored values, keyed by their dotted path.
      #
      # Cached per process and dropped whenever something is written. Without
      # the cache this would be one query on every request; with a cache that
      # is not dropped, a change would take effect on the next restart, which
      # is exactly the property this whole feature exists to avoid.
      def stored(db)
        @stored ||= db[:settings].select_map(%i[key value_json]).to_h do |key, raw|
          [key, JSON.parse(raw)['value']]
        end
      end

      def forget!
        @stored = nil
      end

      def view(db, configuration)
        View.new(configuration, stored(db))
      end

      # What the screen shows: the current value, where it comes from, and the
      # kind of control to draw. "Where it comes from" is not decoration — an
      # administrator who has never touched a setting should be able to tell
      # the shipped default from a decision somebody made.
      def describe(db, configuration)
        current = stored(db)

        EDITABLE.map do |key|
          {
            'key' => key,
            'value' => current.key?(key) ? current[key] : configuration&.[](key),
            'from_file' => !current.key?(key),
            'kind' => Configuration::RULES.fetch(key).to_s,
            'choices' => choices_for(key)
          }
        end
      end

      def choices_for(key)
        return Configuration::REGISTRATION_MODES if Configuration::RULES[key] == :registration_mode

        nil
      end

      # Writes the given values, or raises Refused with a message per field.
      #
      # Everything is checked **before** anything is written: a form with two
      # changes of which one is wrong must not leave the other one applied.
      def update(db, values, actor:, now: Time.now)
        wanted = values.to_h { |key, value| [key.to_s, value] }.slice(*EDITABLE)
        unknown = values.keys.map(&:to_s) - EDITABLE
        problems = unknown.to_h { |key| [key, 'unknown_key'] }

        coerced = {}
        wanted.each do |key, value|
          typed = coerce(key, value)
          complaint = Configuration.check_value(key, typed)
          if complaint
            # The **kind**, not a sentence. The rules and their descriptions
            # live in Configuration, and those descriptions are console
            # English (I18n::BASE_LANGUAGE) — printing them into a German
            # form would be the one place where the two audiences meet and
            # neither is served. The screen knows the kind already, because it
            # draws the control from it, and writes the sentence itself.
            problems[key] = { 'kind' => Configuration::RULES.fetch(key).to_s,
                              'detail' => complaint }
          else
            coerced[key] = typed
          end
        end

        raise Refused, problems unless problems.empty?

        db.transaction do
          coerced.each { |key, value| write(db, key, value, actor, now) }
        end
        forget!

        coerced
      end

      # A form field arrives as a string even when the rule wants a number.
      # Converted here rather than in the endpoint, so the conversion and the
      # rule that judges the result stay side by side.
      def coerce(key, value)
        return value unless Configuration::RULES[key].to_s.end_with?('integer')
        return value if value.is_a?(Integer)
        return value unless value.is_a?(String) && value.strip.match?(/\A-?\d+\z/)

        value.strip.to_i
      end

      def write(db, key, value, actor, now)
        payload = JSON.generate(value: value)
        row = { value_json: payload, updated_at: now, updated_by: actor && actor[:id] }

        # No upsert: SQLite's `ON CONFLICT` needs a version this project does
        # not insist on, and two statements inside the transaction above are
        # just as atomic.
        if db[:settings].where(key: key).count.positive?
          db[:settings].where(key: key).update(row)
        else
          db[:settings].insert(row.merge(key: key))
        end
      end
    end
  end
end
