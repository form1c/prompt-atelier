# frozen_string_literal: true

module PromptAtelier
  # Tags and keywords — the two things that belong to a workspace rather than
  # to a prompt (FA-401 to FA-404, FA-503, FA-504).
  #
  # They share a module because they share the property that shapes every rule
  # here: `UNIQUE (workspace_id, name)`. A name identifies them inside their
  # workspace and nowhere else, which is why duplicating and moving a prompt
  # has to resolve them by name, and why deleting one has to say what it takes
  # with it.
  module Catalog
    NAME_LIMIT = 40
    KEYWORD_TEXT_LIMIT = 5_000
    KEYWORDS_PER_WORKSPACE = 200
    POSITIONS = %w[prepend append].freeze

    class Refused < StandardError
      attr_reader :code, :fields

      def initialize(code, fields = {})
        @code = code
        @fields = fields
        super(code.to_s)
      end
    end

    class << self
      # --- tags (FA-503, FA-504) -------------------------------------------

      # With the usage count, because that is what makes the list useful for
      # filtering and what a deletion dialogue needs (FA-504).
      def tags(db, workspace_id)
        db[:tags].where(workspace_id: workspace_id)
                 .select(:id, :name,
                         db[:prompt_tags].where(tag_id: Sequel[:tags][:id])
                           .join(:prompts, id: :prompt_id).where(deleted_at: nil)
                           .select { Sequel.lit(%q{count(*)}) }.as(:usage_count))
                 .order(:name).all
      end

      def create_tag(db, workspace_id, name, now: Time.now)
        clean = checked_name(name)
        existing = db[:tags].first(workspace_id: workspace_id, name: clean)
        return existing[:id] if existing

        db[:tags].insert(workspace_id: workspace_id, name: clean, created_at: now)
      end

      # TF-406: the assignments go, the prompts stay. A tag is a label, not
      # part of the content — deleting it must never touch a prompt text.
      def delete_tag(db, tag_id)
        affected = db[:prompt_tags].where(tag_id: tag_id).count
        db[:tags].where(id: tag_id).delete
        affected
      end

      # --- keywords (FA-401, FA-404) ---------------------------------------

      def keywords(db, workspace_id)
        db[:keywords].where(workspace_id: workspace_id)
                     .select(:id, :name, :description, :text, :position, :sort_order)
                     .order(:position, :sort_order, :name).all
      end

      def create_keyword(db, workspace_id, attributes, now: Time.now)
        values = validated_keyword(attributes, required: true)
        if db[:keywords].where(workspace_id: workspace_id).count >= KEYWORDS_PER_WORKSPACE
          raise Refused.new(:too_many_keywords_in_workspace, { limit: KEYWORDS_PER_WORKSPACE })
        end
        raise Refused.new(:name_taken, { name: values[:name] }) if named(db, workspace_id, values[:name])

        db[:keywords].insert(values.merge(workspace_id: workspace_id, created_at: now, updated_at: now))
      end

      def update_keyword(db, keyword, attributes, now: Time.now)
        values = validated_keyword(attributes, required: false)
        if values[:name] && values[:name] != keyword[:name]
          clash = named(db, keyword[:workspace_id], values[:name])
          raise Refused.new(:name_taken, { name: values[:name] }) if clash
        end

        db[:keywords].where(id: keyword[:id]).update(values.merge(updated_at: now))
        db[:keywords][id: keyword[:id]]
      end

      # FA-404 in two steps, and the first one is the point: how many prompts
      # would be affected. Deleting straight away would silently change what
      # those prompts render, which is the kind of change nobody notices until
      # the output is wrong.
      def keyword_usage(db, keyword_id)
        db[:prompt_keywords].join(:prompts, id: :prompt_id)
                            .where(Sequel[:prompt_keywords][:keyword_id] => keyword_id)
                            .where(Sequel[:prompts][:deleted_at] => nil)
                            .order(Sequel[:prompts][:title_sort])
                            .select_map([Sequel[:prompts][:id], Sequel[:prompts][:title]])
      end

      def delete_keyword(db, keyword_id)
        affected = keyword_usage(db, keyword_id)
        db[:keywords].where(id: keyword_id).delete
        affected
      end

      def named(db, workspace_id, name)
        db[:keywords].first(workspace_id: workspace_id, name: name)
      end

      # --- validation (14.3) ------------------------------------------------

      def checked_name(name)
        clean = name.to_s.strip
        raise Refused.new(:name_invalid, { limit: NAME_LIMIT }) if clean.empty? || clean.length > NAME_LIMIT

        clean
      end

      def validated_keyword(attributes, required:)
        values = {}
        problems = {}

        if attributes.key?('name') || required
          begin
            values[:name] = checked_name(attributes['name'])
          rescue Refused
            problems[:name] = { limit: NAME_LIMIT, minimum: 1 }
          end
        end

        if attributes.key?('text') || required
          text = attributes['text'].to_s
          if text.empty? || text.length > KEYWORD_TEXT_LIMIT
            problems[:text] = { limit: KEYWORD_TEXT_LIMIT, minimum: 1, actual: text.length }
          else
            values[:text] = text
          end
        end

        if attributes.key?('position') || required
          position = attributes['position'].to_s
          POSITIONS.include?(position) ? values[:position] = position : problems[:position] = { allowed: POSITIONS }
        end

        values[:description] = attributes['description'].to_s if attributes.key?('description')
        values[:sort_order] = attributes['sort_order'].to_i if attributes.key?('sort_order')
        values[:sort_order] = 10 if required && !values.key?(:sort_order)

        raise Refused.new(:validation_failed, problems) unless problems.empty?

        values
      end
    end
  end
end
