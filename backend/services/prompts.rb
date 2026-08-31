# frozen_string_literal: true

require 'json'
require_relative 'rendering'
require_relative 'workspaces'

module PromptAtelier
  # Everything that happens to a prompt (FA-201 to FA-207, FA-301, FA-7xx).
  #
  # The service owns three things the endpoints must not decide for
  # themselves, because each of them has to hold on every path:
  #
  #   * the field and quantity limits of chapter 14.3 — checked on the server,
  #     since the interface can only ever be a reminder (SEC-08)
  #   * which variables a prompt has: derived from the text, never from what
  #     the client sends (FA-301)
  #   * when a revision comes into being: on every real change and on nothing
  #     else (FA-701)
  module Prompts
    LIMITS = {
      title: 1..200, description: 0..1_000, body: 1..100_000,
      model_hint: 0..200, default_value: 0..2_000
    }.freeze

    MAX_VARIABLES = 50
    MAX_OPTIONS   = 100
    MAX_TAGS      = 20
    MAX_KEYWORDS_PER_RENDER = 20
    MAX_RENDERED  = 200_000

    VISIBILITIES = %w[private workspace instance].freeze
    STATUSES     = %w[draft active archived].freeze
    VARIABLE_TYPES = %w[text multiline select number].freeze

    # The fields a revision holds. FA-701 asks for the complete previous state,
    # so the list is spelled out rather than "everything in the row" — a new
    # column must be a decision, not an accident.
    SNAPSHOT_FIELDS = %i[title description body visibility status model_hint].freeze

    class Refused < StandardError
      attr_reader :code, :fields

      def initialize(code, fields = {})
        @code = code
        @fields = fields
        super(code.to_s)
      end
    end

    class << self
      # --- writing ---------------------------------------------------------

      # In a transaction, and not as a precaution: the checks that can still
      # refuse — too many variables, too many tags, an option list past its
      # limit — run *after* the row exists, because they need the id. Without
      # the transaction a refused create left the prompt behind: the caller
      # got 422 and the library gained an entry nobody asked for. Measured,
      # not feared. SEC-12 states the same rule for imports; it holds here for
      # the same reason.
      def create(db, workspace_id:, owner_id:, attributes:, now: Time.now)
        values = validated(attributes, required: true)

        db.transaction do
          id = db[:prompts].insert(
            values.merge(workspace_id: workspace_id, owner_id: owner_id,
                         created_at: now, updated_at: now)
          )
          synchronise_variables(db, id, values[:body], attributes['variables'])
          assign_tags(db, id, workspace_id, attributes['tags'], now: now)
          assign_keywords(db, id, workspace_id, attributes['keyword_ids'])
          id
        end
      end

      # FA-701: the previous state is kept before the change, and only when
      # something actually changed. A save that alters nothing must not fill
      # the history with copies — otherwise "undo" walks back through states
      # nobody ever saw.
      def update(db, prompt, attributes:, actor_id:, now: Time.now)
        values = validated(attributes, required: false)

        # Same reason as in create, and worse here: a refusal partway through
        # would leave the prompt changed, a revision written, and the
        # variables belonging to neither state.
        db.transaction do
          changed = values.any? { |field, value| prompt[field] != value }
          variables_changed = variables_would_change?(db, prompt, values.fetch(:body, prompt[:body]),
                                                      attributes['variables'])

          record_revision(db, prompt, actor_id: actor_id, now: now) if changed || variables_changed

          db[:prompts].where(id: prompt[:id]).update(values.merge(updated_at: now)) unless values.empty?
          synchronise_variables(db, prompt[:id], values.fetch(:body, prompt[:body]), attributes['variables'])
          assign_tags(db, prompt[:id], prompt[:workspace_id], attributes['tags'], now: now) if attributes.key?('tags')
          if attributes.key?('keyword_ids')
            assign_keywords(db, prompt[:id], prompt[:workspace_id], attributes['keyword_ids'])
          end

          changed || variables_changed
        end
      end

      # --- validation (14.3) ------------------------------------------------

      # Reports every offending field at once. Returning only the first would
      # make the caller correct one thing, submit again, and be refused for the
      # next — the same reasoning as for the configuration check.
      def validated(attributes, required:)
        problems = {}
        values = {}

        text_field(values, problems, attributes, 'title', :title, required: required)
        text_field(values, problems, attributes, 'description', :description, required: false)
        text_field(values, problems, attributes, 'body', :body, required: required)
        text_field(values, problems, attributes, 'model_hint', :model_hint, required: false)

        enum_field(values, problems, attributes, 'visibility', :visibility, VISIBILITIES)
        enum_field(values, problems, attributes, 'status', :status, STATUSES)

        raise Refused.new(:validation_failed, problems) unless problems.empty?

        values
      end

      def text_field(values, problems, attributes, key, field, required:)
        unless attributes.key?(key)
          problems[field] = :required if required
          return
        end

        value = attributes[key].to_s
        range = LIMITS.fetch(field)
        if value.length < range.min || value.length > range.max
          # The message names the limit and the actual length (TF-428) —
          # "too long" without a number leaves the user guessing.
          problems[field] = { limit: range.max, minimum: range.min, actual: value.length }
        else
          values[field] = value
        end
      end

      def enum_field(values, problems, attributes, key, field, allowed)
        return unless attributes.key?(key)

        value = attributes[key].to_s
        allowed.include?(value) ? values[field] = value : problems[field] = { allowed: allowed }
      end

      # --- variables (FA-301, TF-402, TF-403) -------------------------------

      # The set of variables follows from the text and from nothing else. A
      # client may send metadata for them — label, type, default — but not
      # their existence: an entry without an occurrence disappears (TF-403),
      # and an occurrence without an entry is created (TF-402).
      def synchronise_variables(db, prompt_id, body, provided)
        keys = Rendering.variable_keys(body)
        raise Refused.new(:too_many_variables, { limit: MAX_VARIABLES, actual: keys.size }) if keys.size > MAX_VARIABLES

        metadata = index_provided(provided)
        db[:prompt_variables].where(prompt_id: prompt_id).exclude(key: keys).delete

        ordered(keys, metadata).each_with_index do |key, position|
          attributes = variable_attributes(metadata[key], position)
          existing = db[:prompt_variables].first(prompt_id: prompt_id, key: key)

          if existing
            db[:prompt_variables].where(id: existing[:id]).update(attributes)
          else
            db[:prompt_variables].insert(attributes.merge(prompt_id: prompt_id, key: key))
          end
        end
      end

      # FA-302 lists the order of the fields among the things that are
      # editable, so a position that arrives with the metadata counts. A key
      # without one keeps the place its occurrence in the text gives it.
      #
      # The occurrence index is the tie-breaker as well, which makes the
      # comparison a total order — `sort_by` is not stable in Ruby, and a
      # result that depends on the sort's internals would differ from run to
      # run for two variables claiming the same place.
      #
      # Whatever arrives, the stored positions come out as 0..n-1 without gaps.
      # The set of variables still follows from the text alone (FA-301); only
      # their order is the author's to decide.
      def ordered(keys, metadata)
        keys.each_with_index
            .sort_by { |key, index| [wanted_position(metadata[key], index), index] }
            .map(&:first)
      end

      # Integer(…, exception: false) rather than a type check: a client that
      # sends "2" means 2, and treating it as "no opinion" would silently
      # scramble the order it asked for.
      def wanted_position(entry, fallback)
        wanted = entry && Integer(entry['position'], exception: false)
        wanted || fallback
      end

      def index_provided(provided)
        Array(provided).each_with_object({}) do |entry, table|
          next unless entry.is_a?(Hash)

          table[entry['key'].to_s] = entry
        end
      end

      def variable_attributes(entry, position)
        entry ||= {}
        options = Array(entry['options']).map(&:to_s)
        raise Refused.new(:too_many_options, { limit: MAX_OPTIONS }) if options.size > MAX_OPTIONS

        default = entry['default_value'].to_s
        if default.length > LIMITS[:default_value].max
          raise Refused.new(:validation_failed, { default_value: { limit: LIMITS[:default_value].max, actual: default.length } })
        end

        type = VARIABLE_TYPES.include?(entry['type'].to_s) ? entry['type'].to_s : 'text'
        {
          label: entry['label'].to_s.empty? ? nil : entry['label'].to_s,
          type: type,
          default_value: default.empty? ? nil : default,
          options: options.empty? ? nil : options.join("\n"),
          required: entry['required'] == true,
          position: position
        }
      end

      # Whether the variable set or its metadata would come out different.
      # Needed because FA-701 counts a changed variable as a change even when
      # the prompt's own columns stayed the same.
      def variables_would_change?(db, prompt, body, provided)
        current = db[:prompt_variables].where(prompt_id: prompt[:id]).order(:position)
                    .select(:key, :label, :type, :default_value, :options, :required, :position).all
        keys = Rendering.variable_keys(body)
        metadata = index_provided(provided)

        wanted = keys.each_with_index.map do |key, position|
          variable_attributes(metadata[key], position).merge(key: key)
        end

        current.map { |row| row.sort.to_h } != wanted.map { |row| row.sort.to_h }
      end

      # --- revisions (FA-701, FA-702) ---------------------------------------

      def record_revision(db, prompt, actor_id:, now: Time.now, comment: nil)
        db[:prompt_revisions].insert(
          prompt_id: prompt[:id], snapshot_json: JSON.generate(snapshot(db, prompt)),
          comment: comment, changed_by: actor_id, created_at: now
        )
      end

      def snapshot(db, prompt)
        SNAPSHOT_FIELDS.to_h { |field| [field, prompt[field]] }.merge(
          variables: db[:prompt_variables].where(prompt_id: prompt[:id]).order(:position)
                       .select(:key, :label, :type, :default_value, :options, :required, :position).all,
          tag_names: tag_names(db, prompt[:id]),
          keyword_names: keyword_names(db, prompt[:id])
        )
      end

      # FA-702: restoring is itself a change, so the state being overwritten
      # becomes a revision in its turn. That is what makes undo reversible
      # (TF-334) rather than a one-way door.
      def undo(db, prompt, actor_id:, now: Time.now)
        latest = db[:prompt_revisions].where(prompt_id: prompt[:id]).reverse(:id).first
        raise Refused, :no_revision if latest.nil?

        record_revision(db, prompt, actor_id: actor_id, now: now, comment: 'undo')
        state = JSON.parse(latest[:snapshot_json])

        db[:prompts].where(id: prompt[:id]).update(
          SNAPSHOT_FIELDS.to_h { |field| [field, state[field.to_s]] }.merge(updated_at: now)
        )
        restore_variables(db, prompt[:id], state['variables'])
        restore_tags(db, prompt, state['tag_names'], now: now)
        restore_keywords(db, prompt, state['keyword_names'])

        db[:prompt_revisions].where(id: latest[:id]).delete
        db[:prompts][id: prompt[:id]]
      end

      def restore_variables(db, prompt_id, variables)
        db[:prompt_variables].where(prompt_id: prompt_id).delete
        Array(variables).each_with_index do |entry, position|
          db[:prompt_variables].insert(
            prompt_id: prompt_id, key: entry['key'], label: entry['label'],
            type: entry['type'], default_value: entry['default_value'],
            options: entry['options'], required: entry['required'] == true,
            position: entry['position'] || position
          )
        end
      end

      # --- tags and keywords -------------------------------------------------

      def tag_names(db, prompt_id)
        db[:prompt_tags].join(:tags, id: :tag_id)
                        .where(Sequel[:prompt_tags][:prompt_id] => prompt_id)
                        .order(Sequel[:tags][:name]).select_map(Sequel[:tags][:name])
      end

      # The same thing for a whole page of results, in one query instead of
      # one per row. The library shows the tags on every line (11.3), so a
      # page of 50 would otherwise cost 50 round trips for this alone — and
      # NFA-02 allows 200 ms for the entire answer.
      def tag_names_for(db, prompt_ids)
        return {} if Array(prompt_ids).empty?

        rows = db[:prompt_tags].join(:tags, id: :tag_id)
                               .where(Sequel[:prompt_tags][:prompt_id] => Array(prompt_ids))
                               .order(Sequel[:tags][:name])
                               .select_map([Sequel[:prompt_tags][:prompt_id], Sequel[:tags][:name]])

        rows.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(id, name), result|
          result[id] << name
        end
      end

      # How many variables a prompt has — the `{{n}}` on the line, which tells
      # the reader at a glance whether filling in is needed (11.3).
      def variable_counts(db, prompt_ids)
        return {} if Array(prompt_ids).empty?

        db[:prompt_variables].where(prompt_id: Array(prompt_ids))
                             .group_and_count(:prompt_id)
                             .to_hash(:prompt_id, :count)
      end

      # The keywords attached to a prompt, with everything the rendering
      # pipeline needs (chapter 8). Ordered as the pipeline orders them, so a
      # reader of the answer sees the sequence that will be produced.
      def default_keywords(db, prompt_id)
        db[:prompt_keywords].join(:keywords, id: :keyword_id)
                            .where(Sequel[:prompt_keywords][:prompt_id] => prompt_id)
                            .order(Sequel[:keywords][:sort_order], Sequel[:keywords][:name])
                            .select(Sequel[:keywords][:id], Sequel[:keywords][:name],
                                    Sequel[:keywords][:text], Sequel[:keywords][:position],
                                    Sequel[:keywords][:sort_order])
                            .all
      end

      def keyword_names(db, prompt_id)
        db[:prompt_keywords].join(:keywords, id: :keyword_id)
                            .where(Sequel[:prompt_keywords][:prompt_id] => prompt_id)
                            .order(Sequel[:keywords][:name]).select_map(Sequel[:keywords][:name])
      end

      # Tags belong to a workspace, so they are matched by name and created
      # where they are missing (FA-204). Passing ids instead would break the
      # moment a prompt crosses a workspace boundary.
      def assign_tags(db, prompt_id, workspace_id, names, now: Time.now)
        return if names.nil?

        wanted = Array(names).map { |name| name.to_s.strip }.reject(&:empty?).uniq
        raise Refused.new(:too_many_tags, { limit: MAX_TAGS, actual: wanted.size }) if wanted.size > MAX_TAGS

        db[:prompt_tags].where(prompt_id: prompt_id).delete
        wanted.each do |name|
          tag_id = db[:tags].first(workspace_id: workspace_id, name: name)&.fetch(:id) ||
                   db[:tags].insert(workspace_id: workspace_id, name: name, created_at: now)
          db[:prompt_tags].insert(prompt_id: prompt_id, tag_id: tag_id)
        end
      end

      def restore_tags(db, prompt, names, now: Time.now)
        assign_tags(db, prompt[:id], prompt[:workspace_id], names, now: now)
      end

      def assign_keywords(db, prompt_id, workspace_id, keyword_ids)
        return if keyword_ids.nil?

        allowed = db[:keywords].where(workspace_id: workspace_id, id: Array(keyword_ids)).select_map(:id)
        db[:prompt_keywords].where(prompt_id: prompt_id).delete
        allowed.each { |id| db[:prompt_keywords].insert(prompt_id: prompt_id, keyword_id: id) }
      end

      def restore_keywords(db, prompt, names)
        ids = db[:keywords].where(workspace_id: prompt[:workspace_id], name: Array(names)).select_map(:id)
        assign_keywords(db, prompt[:id], prompt[:workspace_id], ids)
      end

      # --- trash (FA-703) ----------------------------------------------------

      # deleted_by is kept beside owner_id because the two come apart: an admin
      # may delete someone else's prompt, and its owner has to be able to find
      # it again; an editor may delete their own and wants it back themselves.
      def move_to_trash(db, prompt, actor_id:, now: Time.now)
        db[:prompts].where(id: prompt[:id]).update(deleted_at: now, deleted_by: actor_id, updated_at: now)
      end

      # What this person may see in the trash of this workspace. An editor sees
      # what they deleted *or* what belongs to them — both halves are needed,
      # for the two cases above.
      def trash_for(db, workspace_id, user_id, role)
        rows = db[:prompts].where(workspace_id: workspace_id).exclude(deleted_at: nil)
        rows = rows.where(Sequel.|({ deleted_by: user_id }, { owner_id: user_id })) unless %w[admin owner].include?(role)

        rows.order(Sequel.desc(:deleted_at)).all
      end

      # FA-703: the prompt comes back with the metadata it had. Visibility and
      # status are untouched by deleting precisely so that restoring needs no
      # guesswork.
      def restore(db, prompt, now: Time.now)
        db[:prompts].where(id: prompt[:id]).update(deleted_at: nil, deleted_by: nil, updated_at: now)
      end

      def purge(db, prompt)
        db[:prompt_revisions].where(prompt_id: prompt[:id]).delete
        db[:prompts].where(id: prompt[:id]).delete
      end

      # --- duplicating (FA-204) ----------------------------------------------

      # Returns the new id and the keywords that could not be carried over.
      # Naming them is part of the requirement: silently dropping a keyword
      # would leave the copy rendering differently from the original with no
      # sign of why.
      def duplicate(db, source, target_workspace_id:, actor_id:, now: Time.now)
        id = db[:prompts].insert(
          workspace_id: target_workspace_id, owner_id: actor_id,
          title: "#{source[:title]} (Kopie)", description: source[:description],
          body: source[:body], model_hint: source[:model_hint],
          # A copy starts private and as a draft, whoever made it. Inheriting
          # the visibility would publish it into the target workspace as a
          # side effect of copying.
          visibility: 'private', status: 'draft',
          created_at: now, updated_at: now
        )

        copy_variables(db, source[:id], id)
        assign_tags(db, id, target_workspace_id, tag_names(db, source[:id]), now: now)
        [id, transfer_keywords(db, source[:id], id, target_workspace_id)]
      end

      def copy_variables(db, source_id, target_id)
        db[:prompt_variables].where(prompt_id: source_id).order(:position).each do |row|
          db[:prompt_variables].insert(row.reject { |key, _| key == :id }.merge(prompt_id: target_id))
        end
      end

      # Keywords are workspace-bound (UNIQUE (workspace_id, name)), so they are
      # matched by name in the target. What has no counterpart there is dropped
      # and reported back.
      def transfer_keywords(db, source_id, target_id, target_workspace_id)
        wanted = keyword_names(db, source_id)
        found  = db[:keywords].where(workspace_id: target_workspace_id, name: wanted)
                              .select_map(%i[id name])

        found.each { |id, _| db[:prompt_keywords].insert(prompt_id: target_id, keyword_id: id) }
        wanted - found.map { |_, name| name }
      end

      # --- moving (FA-207) ---------------------------------------------------

      # Unlike duplicating, this keeps the owner, the variables, the revisions
      # and the favourites — it is the same prompt in a different place.
      #
      # Visibility 'workspace' falls back to 'private'. Without that a prompt
      # would become readable to a different group of people as a side effect
      # of being moved, and FA-207 requires that release to stay a deliberate
      # act. 'instance' is left alone: it is already visible to everyone, so
      # moving it widens nothing.
      def move(db, prompt, target_workspace_id:, now: Time.now)
        reset = prompt[:visibility] == 'workspace'

        db[:prompts].where(id: prompt[:id]).update(
          workspace_id: target_workspace_id,
          visibility: reset ? 'private' : prompt[:visibility],
          updated_at: now
        )

        moved = db[:prompts][id: prompt[:id]]
        assign_tags(db, prompt[:id], target_workspace_id, tag_names(db, prompt[:id]), now: now)
        dropped = transfer_keywords_in_place(db, prompt[:id], target_workspace_id)

        { prompt: moved, visibility_reset: reset, dropped_keywords: dropped }
      end

      def transfer_keywords_in_place(db, prompt_id, target_workspace_id)
        wanted = keyword_names(db, prompt_id)
        db[:prompt_keywords].where(prompt_id: prompt_id).delete
        found = db[:keywords].where(workspace_id: target_workspace_id, name: wanted).select_map(%i[id name])

        found.each { |id, _| db[:prompt_keywords].insert(prompt_id: prompt_id, keyword_id: id) }
        wanted - found.map { |_, name| name }
      end

      # --- rendering (FA-401, 14.3) -----------------------------------------

      # Which keywords a caller may switch on. The prompt's own are always
      # allowed — FA-604 grants that even to someone outside the workspace,
      # since they are part of what the prompt is. Anything else has to come
      # from a workspace the caller belongs to; otherwise this endpoint would
      # be a way of reading a foreign keyword collection one id at a time.
      def permitted_keywords(db, prompt, requested, member_workspace_ids)
        requested = Array(requested).map(&:to_i).uniq
        return [] if requested.empty?

        attached = db[:prompt_keywords].where(prompt_id: prompt[:id]).select_map(:keyword_id)
        rows = db[:keywords].where(id: requested).all
        raise Refused, :unknown_keyword if rows.size != requested.size

        rows.each do |row|
          next if attached.include?(row[:id])
          next if member_workspace_ids.include?(row[:workspace_id])

          raise Refused, :foreign_keyword
        end
        rows
      end

      def render(db, prompt, values:, keywords:)
        if keywords.size > MAX_KEYWORDS_PER_RENDER
          raise Refused.new(:too_many_keywords, { limit: MAX_KEYWORDS_PER_RENDER, actual: keywords.size })
        end

        variables = db[:prompt_variables].where(prompt_id: prompt[:id]).order(:position).all
        result = Rendering.render(body: prompt[:body], variables: variables.map { |v| v.merge(value: values[v[:key]]) },
                                  keywords: keywords)

        if result.text.length > MAX_RENDERED
          raise Refused.new(:rendered_too_long, { limit: MAX_RENDERED, actual: result.text.length })
        end

        result
      end
    end
  end
end
