# frozen_string_literal: true

module PromptAtelier
  # A single schema step (Requirements 18.9).
  #
  # Migrations are Ruby files rather than plain .sql because the FTS triggers
  # need the normalisation expression from Normalization — writing it out by
  # hand would create a second place where the search rule lives, and the two
  # would drift apart without anyone noticing until a search stopped matching.
  #
  # There is deliberately no process-wide registry. Loading a directory
  # collects exactly what that directory contains and nothing else. A shared
  # registry would mean one migrator could see another's steps, and the same
  # version loaded from two places — an installation directory and the source
  # tree, say — would collide although both are legitimate.
  class Migration
    # Version strings sort as text, so the numeric prefix is fixed width:
    # '001_initial', '002_...'. Without that, '010' would sort before '002'.
    VERSION_PATTERN = /\A\d{3}_[a-z0-9_]+\z/

    FOREIGN_KEYS = %i[on off].freeze

    class LoadError < StandardError; end

    class << self
      def valid_version?(version) = version.to_s.match?(VERSION_PATTERN)

      # Called from inside a migration file. Only valid while +all+ is
      # loading; outside that it is a programming error rather than something
      # to tolerate quietly.
      #
      # +foreign_keys+ is +:off+ for a step that rebuilds a table other tables
      # point at. See the note on Migrator#run for why that cannot be done
      # from inside the migration's own SQL.
      def register(version, foreign_keys: :on, &block)
        raise LoadError, 'Migration.register outside of Migration.all' if @collecting.nil?
        raise LoadError, "Invalid migration version: #{version}" unless valid_version?(version)
        unless FOREIGN_KEYS.include?(foreign_keys)
          raise LoadError, "Invalid foreign_keys for #{version}: #{foreign_keys.inspect}"
        end
        if @collecting.any? { |m| m.version == version }
          raise LoadError, "Duplicate migration version in one directory: #{version}"
        end

        @collecting << new(version, block, foreign_keys)
      end

      # Loads the migration files of +directory+ and returns those steps in
      # version order.
      #
      # `load`, not `require`: the same file may legitimately be read more
      # than once in one process — a test that builds a throwaway installation
      # does exactly that — and `require` would silently return false the
      # second time, leaving an empty result.
      def all(directory)
        previous    = @collecting
        @collecting = []

        Dir.glob(File.join(directory, '*.rb')).sort.each do |file|
          expected = File.basename(file, '.rb')
          load file
          unless @collecting.any? { |m| m.version == expected }
            raise LoadError, "#{file} does not register a migration called #{expected}"
          end
        end

        @collecting.sort_by(&:version)
      ensure
        @collecting = previous
      end
    end

    attr_reader :version, :foreign_keys

    def initialize(version, block, foreign_keys = :on)
      @version      = version
      @block        = block
      @foreign_keys = foreign_keys
    end

    def foreign_keys_off? = foreign_keys == :off

    # The SQL of this step. Evaluated lazily so a migration file can be loaded
    # without being executed.
    def sql
      @sql ||= @block.call
    end
  end
end
