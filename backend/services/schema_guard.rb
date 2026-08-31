# frozen_string_literal: true

require_relative 'migrator'
require_relative 'i18n'

module PromptAtelier
  # Refuses to start when the database and the code disagree about the schema
  # (Requirements 18.9, NFA-18, BT-10).
  #
  # The check runs in BOTH directions, and the second one is the reason this
  # exists as its own step:
  #
  #   database older than the code   a table or column the code uses is
  #                                  missing. Fails loudly at some later
  #                                  moment instead of at startup.
  #   database newer than the code   someone rolled the application back. The
  #                                  old code does not know the newer columns,
  #                                  writes rows without them, and the data
  #                                  loss is silent — nothing errors out.
  #
  # Refusing to start is the only honest answer to the second case.
  module SchemaGuard
    class Mismatch < StandardError
      attr_reader :kind

      def initialize(message, kind)
        @kind = kind
        super(message)
      end
    end

    module_function

    # Returns the current schema state (the highest applied version) or raises
    # Mismatch. +migrator+ carries the paths.
    def check!(migrator)
      newer = migrator.unknown_applied
      unless newer.empty?
        raise Mismatch.new(
          I18n.t('startup.schema_too_new',
                 actual: newer.last,
                 expected: migrator.available_versions.last || I18n.t('startup.no_migrations')),
          :too_new
        )
      end

      pending = migrator.pending
      unless pending.empty?
        raise Mismatch.new(
          I18n.t('startup.schema_too_old',
                 actual: migrator.applied_versions.last || I18n.t('startup.no_schema'),
                 expected: pending.last.version),
          :too_old
        )
      end

      migrator.applied_versions.last
    end

    # Non-raising variant for /health, which must answer rather than crash.
    def current?(migrator)
      migrator.unknown_applied.empty? && migrator.pending.empty?
    rescue StandardError
      false
    end
  end
end
