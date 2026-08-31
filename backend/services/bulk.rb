# frozen_string_literal: true

require 'set'

require_relative 'access'
require_relative 'prompts'
require_relative 'audit'

module PromptAtelier
  # Acting on many prompts at once (FA-511, FA-703a).
  #
  # **Partial success is the normal case here, not the exception.** Out of
  # fifty selected prompts a few regularly fail on chapter 6.2 — an editor
  # picked one that belongs to somebody else, an admin picked one from another
  # workspace. An operation that gave up at the first refusal would make the
  # whole feature useless: the person would have to shrink the selection by
  # hand without being told which entries to remove. So what is permitted is
  # carried out, and the rest is **named**.
  #
  # **Named, but only as far as the caller may already see.** A refusal for an
  # id that is not visible carries no title. Otherwise a bulk call would be a
  # way of reading foreign titles one list at a time — and the distinction
  # between "not allowed" and "does not exist" would say which ids are taken
  # (SEC-06). `Access.verdict` answers `:not_found` for both, and this file
  # keeps that answer intact all the way into the report.
  module Bulk
    # An upper bound on one call. FA-510 allows selecting a whole result list,
    # which is a four-figure number in a real library, so the limit has to be
    # well above a page — but not absent: an unbounded list is an unbounded
    # transaction. The interface only offers "select all results" below this,
    # so the number is a promise on both sides rather than a surprise.
    MAX_IDS = 5_000

    # The three shapes a refusal takes. Written out because they travel to the
    # interface, which turns each into a sentence.
    NOT_FOUND = 'not_found'
    FORBIDDEN = 'forbidden'
    REFUSED   = 'refused'

    class << self
      # --- what the caller sent -----------------------------------------------

      # Returns the ids, or a symbol naming what is wrong with them. Checked
      # before anything is looked up: a list that is empty or absurd is a
      # mistake in the caller, and answering it with an empty report would look
      # like a successful run over nothing.
      def ids_from(payload)
        raw = payload['prompt_ids']
        return :not_a_list unless raw.is_a?(Array)

        ids = raw.map { |value| value.to_i }.uniq.reject(&:zero?)
        return :empty if ids.empty?
        return :too_many if ids.length > MAX_IDS

        ids
      end

      # --- the four operations ------------------------------------------------

      # FA-511. The target workspace is checked **once**, by the caller, since
      # it is the same for every prompt; what varies per prompt is whether it
      # may leave where it is.
      def move(db, user, ids, target_workspace_id:)
        over_live(db, user, ids, 'prompt.move') do |prompt|
          result = Prompts.move(db, prompt, target_workspace_id: target_workspace_id)
          # The one fact the person has to be told afterwards, and the reason
          # FA-207 exists: a workspace-visible prompt becomes private again.
          # Counted rather than listed — the interface says it once, before.
          { visibility_reset: result[:visibility_reset] }
        end
      end

      def trash(db, user, ids, actor_id:)
        over_live(db, user, ids, 'prompt.delete') do |prompt|
          Prompts.move_to_trash(db, prompt, actor_id: actor_id)
          {}
        end
      end

      # FA-703a. The deleted ones live under the trash rules of FA-703, not
      # under a prompt's own visibility — an admin has to reach a foreign
      # prompt in the trash to restore or purge it.
      def restore(db, user, ids)
        over_deleted(db, user, ids, 'trash.restore') do |prompt|
          Prompts.restore(db, prompt)
          {}
        end
      end

      # The only irreversible operation of the application, so it is also the
      # only one that writes an audit entry **per prompt** (SEC-09, FA-703a).
      # Afterwards there is nothing left to look at; the entry is all there is.
      def purge(db, user, ids, ip: nil)
        over_deleted(db, user, ids, 'trash.purge') do |prompt|
          Prompts.purge(db, prompt)
          Audit.record(db, 'prompt.purged', actor: user, target_type: 'prompt',
                       target_id: prompt[:id], ip: ip)
          {}
        end
      end

      private

      # --- the two ways of deciding ------------------------------------------

      # Prompts that are not in the trash. **One** query for all of them: a
      # selection of 1.700 would otherwise be 1.700 round trips before the
      # first change is made.
      def over_live(db, user, ids, action, &operation)
        found = db[:prompts].where(id: ids, deleted_at: nil).to_hash(:id)

        collect(ids, lambda { |id|
          prompt = found[id]
          [prompt, prompt.nil? ? :not_found : Access.for_prompt(db, user, prompt, action)]
        }, &operation)
      end

      # Prompts that are in the trash. The visible trash is fetched **once per
      # workspace involved**, because `Prompts.trash_for` is where the rule of
      # FA-703 lives and asking it per prompt would be one query each.
      def over_deleted(db, user, ids, action, &operation)
        rows = db[:prompts].where(id: ids).exclude(deleted_at: nil).to_hash(:id)
        visible = visible_trash(db, user, rows.values)

        collect(ids, lambda { |id|
          prompt = rows[id]
          [prompt, deleted_verdict(db, user, prompt, action, visible)]
        }, &operation)
      end

      def visible_trash(db, user, rows)
        rows.map { |row| row[:workspace_id] }.uniq.flat_map { |workspace_id|
          role = Access.membership_role(db, workspace_id, user[:id])
          Prompts.trash_for(db, workspace_id, user[:id], role).map { |row| row[:id] }
        }.to_set
      end

      def deleted_verdict(db, user, prompt, action, visible)
        return :not_found if prompt.nil? || !visible.include?(prompt[:id])

        Access.verdict(action, role: Access.membership_role(db, prompt[:workspace_id], user[:id]),
                               instance_admin: Access.instance_admin?(user),
                               owns: prompt[:owner_id] == user[:id], visible: true)
      end

      # --- the report ----------------------------------------------------------

      # Walks the ids **in the order they were sent**, so the report can be read
      # against the selection that produced it. Nothing raises out of here: one
      # prompt the service refuses must not take the other forty-nine with it,
      # which is the whole difference between a bulk action and a loop.
      #
      # Only `:allow` counts as permission. `:allow_own_only` is a scope, not a
      # grant on a named object — none of the four actions here carries it, and
      # treating it as a yes would be a grant nobody wrote down.
      def collect(ids, decide)
        done = []
        refused = []

        ids.each do |id|
          prompt, verdict = decide.call(id)
          next refused << refusal(id, prompt, verdict) unless verdict == :allow

          begin
            done << { id: id, title: prompt[:title] }.merge(yield(prompt) || {})
          rescue Prompts::Refused => e
            refused << { id: id, title: prompt[:title], reason: REFUSED, detail: e.code.to_s }
          end
        end

        { done: done, refused: refused }
      end

      def refusal(id, prompt, verdict)
        # No title where the caller may not see the prompt — see the file
        # header. `:not_found` covers both "gone" and "not yours", and the two
        # have to stay indistinguishable.
        return { id: id, title: nil, reason: NOT_FOUND } if verdict == :not_found

        { id: id, title: prompt && prompt[:title], reason: FORBIDDEN }
      end
    end
  end
end
