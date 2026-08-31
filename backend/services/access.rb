# frozen_string_literal: true

module PromptAtelier
  # The single place where "may this person do this?" is decided (SEC-06, R-04).
  #
  # Requirements 6.2 states the rule as a table of 24 actions by 5 roles. It is
  # kept here as a table too, rather than as conditions spread through the
  # endpoints: a matrix scattered over twenty routes cannot be read as a whole,
  # and a gap in it looks like ordinary code. TF-201 runs the same 120
  # combinations against this table.
  #
  # Two decisions are made here and nowhere else:
  #
  #   * whether an object exists *for this user at all* — deciding 404 over 403
  #     is part of the protection, not cosmetics: a 403 on an invisible object
  #     already discloses that it exists (test concept 6.1)
  #   * whether a permitted action covers every object or only the user's own
  module Access
    # Roles from Requirements 6.1, weakest first.
    ROLES = %w[viewer editor admin owner].freeze

    # A user who is not a member of the workspace but is looking at a prompt
    # with visibility 'instance'. Not a role in the database — it is the
    # position FA-604 describes: read, render, copy and duplicate, nothing
    # else. Without it a non-member could not read an instance-wide prompt,
    # which is the entire point of that visibility.
    GUEST = 'guest'

    # Verdicts a rule can produce.
    #   :yes      — allowed
    #   :own      — allowed only on objects the user owns (◐ on a single object)
    #   :own_only — allowed, but the result is limited to the user's own
    #               objects (◐ on a list or an export)
    #   :no       — refused
    #
    # The instance column is separate because the flag is not a role: it grants
    # the actions marked :yes and nothing else. It never *removes* anything —
    # an instance administrator reading an instance-wide prompt is an ordinary
    # reader like everyone else. The ○ in the document's instance column means
    # "the flag grants nothing here", not "this person is worse off".
    ACTIONS = {
      # --- prompt-bound (Requirements 6.2, rows 1 to 12) -------------------
      'prompt.read'       => { scope: :prompt, guest: :yes, viewer: :yes, editor: :yes,  admin: :yes, owner: :yes, instance: :no },
      'prompt.render'     => { scope: :prompt, guest: :yes, viewer: :yes, editor: :yes,  admin: :yes, owner: :yes, instance: :no },
      'prompt.favorite'   => { scope: :prompt, guest: :yes, viewer: :yes, editor: :yes,  admin: :yes, owner: :yes, instance: :no },
      'prompt.update'     => { scope: :prompt, guest: :no,  viewer: :no,  editor: :own,  admin: :yes, owner: :yes, instance: :no },
      'prompt.delete'     => { scope: :prompt, guest: :no,  viewer: :no,  editor: :own,  admin: :yes, owner: :yes, instance: :no },
      'prompt.duplicate'  => { scope: :prompt, guest: :yes, viewer: :yes, editor: :yes,  admin: :yes, owner: :yes, instance: :no },
      'prompt.move'       => { scope: :prompt, guest: :no,  viewer: :no,  editor: :own,  admin: :yes, owner: :yes, instance: :no },
      'prompt.visibility' => { scope: :prompt, guest: :no,  viewer: :no,  editor: :own,  admin: :yes, owner: :yes, instance: :no },
      'trash.restore'     => { scope: :prompt, guest: :no,  viewer: :no,  editor: :own,  admin: :yes, owner: :yes, instance: :no },
      'trash.purge'       => { scope: :prompt, guest: :no,  viewer: :no,  editor: :no,   admin: :yes, owner: :yes, instance: :no },

      # --- workspace-bound content (rows 4, 10, 13 to 16) ------------------
      'prompt.create'     => { scope: :workspace, viewer: :no, editor: :yes, admin: :yes, owner: :yes, instance: :no },
      'trash.view'        => { scope: :workspace, viewer: :no, editor: :own_only, admin: :yes, owner: :yes, instance: :no },
      'keyword.write'     => { scope: :workspace, viewer: :no, editor: :yes, admin: :yes, owner: :yes, instance: :no },
      'tag.create'        => { scope: :workspace, viewer: :no, editor: :yes, admin: :yes, owner: :yes, instance: :no },
      'prompt.export'     => { scope: :workspace, viewer: :no, editor: :own_only, admin: :yes, owner: :yes, instance: :forbidden },
      'prompt.import'     => { scope: :workspace, viewer: :no, editor: :no,  admin: :yes, owner: :yes, instance: :forbidden },

      # --- workspace administration (rows 17 to 20) ------------------------
      'member.manage'     => { scope: :workspace, viewer: :no, editor: :no, admin: :yes, owner: :yes, instance: :forbidden },
      'member.grant_owner' => { scope: :workspace, viewer: :no, editor: :no, admin: :no, owner: :yes, instance: :forbidden },
      'workspace.rename'  => { scope: :workspace, viewer: :no, editor: :no, admin: :yes, owner: :yes, instance: :yes },
      'workspace.delete'  => { scope: :workspace, viewer: :no, editor: :no, admin: :no,  owner: :yes, instance: :yes },

      # --- instance-wide (rows 21 to 24) -----------------------------------
      'user.manage'         => { scope: :instance, instance: :yes },
      'user.reset_password' => { scope: :instance, instance: :yes },
      'user.grant_admin'    => { scope: :instance, instance: :yes },
      'audit.read'          => { scope: :instance, instance: :yes }
    }.freeze

    class << self
      # --- visibility ------------------------------------------------------

      # Whether the prompt exists for this user at all. Everything that follows
      # depends on it: an invisible object answers 404 before any permission is
      # even consulted.
      #
      # Note what is deliberately absent: the instance administrator flag. It
      # grants no view of foreign content (Requirements 6.2). He can make
      # himself a member, and that leaves a trace (SEC-09).
      def prompt_visible?(prompt, user_id, role)
        return false if prompt.nil?
        return false unless prompt[:deleted_at].nil?
        return true  if prompt[:visibility] == 'instance'
        return false if role.nil?
        return prompt[:owner_id] == user_id if prompt[:visibility] == 'private'

        true
      end

      # The role this user holds towards this prompt: their membership, or
      # GUEST when the prompt is instance-wide and they are not a member.
      def role_towards(prompt, user_id, membership_role)
        return membership_role unless membership_role.nil?
        return GUEST if prompt && prompt[:visibility] == 'instance'

        nil
      end

      # --- the decision ----------------------------------------------------

      # Returns :allow, :allow_own_only, :forbidden or :not_found.
      #
      # +role+ is the membership role, GUEST, or nil for no relationship at
      # all. +owns+ says whether the object belongs to the user, which is what
      # separates ◐ from ●.
      def verdict(action, role:, instance_admin: false, owns: false, visible: true)
        rule = ACTIONS.fetch(action)

        return instance_verdict(rule, instance_admin) if rule[:scope] == :instance
        return :not_found unless visible

        flag = instance_admin ? rule[:instance] : :no
        return :allow if flag == :yes

        case rule[role&.to_sym]
        when :yes      then :allow
        when :own      then owns ? :allow : :forbidden
        when :own_only then :allow_own_only
        else                fallback(rule, flag, role)
        end
      end

      # What a refusal looks like when the role grants nothing.
      #
      # Someone without any relationship to the workspace must not learn that
      # it exists — 404. The instance administrator is the exception the
      # document makes explicitly for administrative actions: he already sees
      # every workspace in his overview (FA-907), so hiding it from him there
      # would protect nothing and only confuse. On content actions the 404
      # stands even for him (test concept 6.2, footnote 3).
      def fallback(rule, flag, role)
        return :forbidden if flag == :forbidden
        return :not_found if role.nil?

        :forbidden
      end

      # Instance-wide actions know no roles and no objects: the flag decides,
      # and nothing else does. Reading only the rule here — and forgetting to
      # ask whether the caller actually carries the flag — would have handed
      # every viewer the account administration. Caught by TF-201.
      def instance_verdict(rule, instance_admin)
        instance_admin && rule[:instance] == :yes ? :allow : :forbidden
      end

      # --- lookups ---------------------------------------------------------

      def membership_role(db, workspace_id, user_id)
        db[:memberships].where(workspace_id: workspace_id, user_id: user_id).get(:role)
      end

      def instance_admin?(user) = user && user[:is_instance_admin] == true

      # Every workspace the user belongs to. The one query every list endpoint
      # filters through (SEC-06).
      def workspace_ids(db, user_id)
        db[:memberships].where(user_id: user_id).select_map(:workspace_id)
      end

      # "Prompts this user may see", as a SQL fragment plus its values.
      #
      # There are two consumers: the list endpoints, which build Sequel
      # datasets, and the search, which builds raw SQL because FTS5 MATCH and
      # bm25 have no dataset form. Both take the rule from here rather than
      # each stating it in their own dialect — SEC-06 asks for one place, and
      # FA-501 already showed what two implementations of one rule cost.
      #
      # +table+ is the alias the query uses for `prompts`.
      def visible_prompts_condition(db, user_id, table: 'prompts')
        mine = workspace_ids(db, user_id)
        return ["#{table}.deleted_at IS NULL AND #{table}.visibility = 'instance'", []] if mine.empty?

        list = mine.map { '?' }.join(', ')
        [
          "#{table}.deleted_at IS NULL AND (" \
          "#{table}.visibility = 'instance' " \
          "OR (#{table}.workspace_id IN (#{list}) AND #{table}.visibility <> 'private') " \
          "OR (#{table}.workspace_id IN (#{list}) AND #{table}.owner_id = ?))",
          mine + mine + [user_id]
        ]
      end

      # The same rule for a Sequel dataset. A thin wrapper on purpose: it must
      # not become a second statement of the rule.
      def visible_prompts_filter(db, user_id, table: 'prompts')
        sql, values = visible_prompts_condition(db, user_id, table: table)
        Sequel.lit(sql, *values)
      end

      # --- convenience for endpoints ---------------------------------------

      # Decides an action on a concrete prompt in one call, so an endpoint
      # never has to assemble the pieces — and cannot assemble them wrongly.
      def for_prompt(db, user, prompt, action)
        return :not_found if prompt.nil?

        membership = membership_role(db, prompt[:workspace_id], user[:id])
        visible    = prompt_visible?(prompt, user[:id], membership)
        role       = role_towards(prompt, user[:id], membership)

        verdict(action, role: role, instance_admin: instance_admin?(user),
                        owns: prompt[:owner_id] == user[:id], visible: visible)
      end

      def for_workspace(db, user, workspace_id, action)
        role = membership_role(db, workspace_id, user[:id])
        exists = db[:workspaces].where(id: workspace_id).count.positive?

        verdict(action, role: role, instance_admin: instance_admin?(user),
                        owns: false, visible: exists)
      end

      def for_instance(user, action)
        verdict(action, role: nil, instance_admin: instance_admin?(user))
      end

      # The target workspace of a duplicate or a move (footnote 1 and 2 of the
      # matrix). Deliberately answers :forbidden and never :not_found, which is
      # the opposite of the rule everywhere else — and for the same reason
      # behind that rule.
      #
      # Here the object of the request is the prompt, and it is visible. The
      # target is named in the body. Answering 404 for an unknown workspace and
      # 403 for a known one would turn this endpoint into a way of asking "does
      # workspace 47 exist?" and reading the answer off the status code. One
      # uniform 403 for every unusable target — non-existent, foreign, or
      # merely not permitted — tells the caller nothing at all. Test concept
      # TF-204 fixes this: Lisa aiming at Martin's personal workspace gets 403,
      # not 404.
      def for_target_workspace(db, user, workspace_id)
        return :forbidden if workspace_id.nil?

        for_workspace(db, user, workspace_id, 'prompt.create') == :allow ? :allow : :forbidden
      end
    end
  end
end
