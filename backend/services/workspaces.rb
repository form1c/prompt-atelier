# frozen_string_literal: true

require_relative 'normalization'
require_relative 'access'

module PromptAtelier
  # Workspaces and memberships (FA-601 to FA-608, FA-602).
  #
  # The rules that live here are the ones that must hold no matter which
  # endpoint is called. Two of them exist to keep a user from being locked out
  # of their own data:
  #
  #   * a personal workspace is created with every account (FA-602) and can
  #     never be deleted or have its membership changed (FA-606) — it is the
  #     one place a user is always able to write
  #   * a team workspace never loses its last owner (FA-603), because an
  #     ownerless workspace could not be administered by anyone again
  module Workspaces
    NAME_LIMIT = 100

    class Refused < StandardError
      attr_reader :code

      def initialize(code, message = nil)
        @code = code
        super(message || code.to_s)
      end
    end

    class << self
      # --- creating --------------------------------------------------------

      # The personal workspace of a new account. Called from every path that
      # creates a user — first-run setup and the administrator's account
      # creation — so FA-602 cannot be true on one path and false on another.
      def create_personal(db, user, now: Time.now)
        create(db, name: personal_name(user), owner_id: user[:id], personal: true, now: now)
      end

      def create(db, name:, owner_id:, personal: false, now: Time.now)
        clean = normalise_name(name)
        id = db[:workspaces].insert(
          name: clean, slug: slug_for(db, clean), is_personal: personal,
          created_at: now, updated_at: now
        )
        db[:memberships].insert(user_id: owner_id, workspace_id: id, role: 'owner', created_at: now)
        id
      end

      def personal_name(user) = "Persönlich-#{user[:name]}"

      # Slugs follow the rule from Requirements 15.1. A collision gets a
      # counter rather than an error — the name is the user's, the slug is
      # ours.
      #
      # `Normalization.slug` and not `normalize`: the search rule folds the
      # German digraphs, which is right for finding things and wrong for a
      # name somebody reads. `Año nuevo` came out as `a-o-nuvo` (AP-23).
      def slug_for(db, name, suffix: nil)
        base = Normalization.slug(name, fallback: 'workspace')
        candidate = suffix ? "#{base}-#{suffix}" : base
        return candidate unless db[:workspaces].where(slug: candidate).count.positive?

        slug_for(db, name, suffix: (suffix || 0) + 1)
      end

      def normalise_name(name)
        clean = name.to_s.strip
        raise Refused, :name_required if clean.empty?
        raise Refused, :name_too_long if clean.length > NAME_LIMIT

        clean
      end

      # --- renaming (FA-608) -----------------------------------------------

      # Personal workspaces may be renamed — deliberately, unlike deleting.
      def rename(db, workspace_id, name, now: Time.now)
        db[:workspaces].where(id: workspace_id)
                       .update(name: normalise_name(name), updated_at: now)
      end

      # --- deleting (FA-606) -----------------------------------------------

      def delete(db, workspace_id, confirmation: nil)
        workspace = db[:workspaces][id: workspace_id]
        raise Refused, :not_found if workspace.nil?
        raise Refused, :personal_workspace if workspace[:is_personal]

        # FA-606 asks for the name as confirmation, because the contents go
        # with it. Checked on the server: a dialogue in the browser is not a
        # safeguard, only a reminder.
        unless confirmation.nil? || confirmation == workspace[:name]
          raise Refused, :confirmation_mismatch
        end

        db[:workspaces].where(id: workspace_id).delete
      end

      # --- membership (FA-603) ---------------------------------------------

      def members(db, workspace_id)
        db[:memberships]
          .join(:users, id: :user_id)
          .where(Sequel[:memberships][:workspace_id] => workspace_id)
          .select(Sequel[:memberships][:user_id], Sequel[:memberships][:role],
                  Sequel[:users][:name], Sequel[:users][:email])
          .order(Sequel[:users][:name])
          .all
      end

      # Which account is meant. FA-603 asks for existing accounts to be added,
      # and the screen has to name one somehow.
      #
      # An identifier is no help there: it cannot be typed from memory, and it
      # cannot be looked up either — the account list belongs to the instance
      # administrator (Requirements 6.2), and handing it to every workspace
      # owner would widen the matrix by a side door. The e-mail address is what
      # someone adding a colleague actually knows, so that is what this takes.
      #
      # It is also the narrower disclosure of the two. Either way the endpoint
      # answers whether an account exists, but an address has to be known
      # before it can be asked about, while identifiers can be counted upwards.
      #
      # Compared without regard to case, like every other use of the address
      # (`COLLATE NOCASE`, Requirements 14.1).
      def resolve_member(db, user_id: nil, email: nil)
        return user_id.to_i unless user_id.nil? || user_id.to_s.strip.empty?

        address = email.to_s.strip.downcase
        raise Refused, :unknown_user if address.empty?

        db[:users].where(Sequel.function(:lower, :email) => address).get(:id) ||
          raise(Refused, :unknown_user)
      end

      def add_member(db, workspace_id, user_id, role, now: Time.now)
        guard_personal!(db, workspace_id)
        raise Refused, :unknown_role unless Access::ROLES.include?(role)
        raise Refused, :unknown_user if db[:users].where(id: user_id).empty?
        raise Refused, :already_member if membership(db, workspace_id, user_id)

        db[:memberships].insert(user_id: user_id, workspace_id: workspace_id,
                                role: role, created_at: now)
      end

      def change_role(db, workspace_id, user_id, role)
        guard_personal!(db, workspace_id)
        raise Refused, :unknown_role unless Access::ROLES.include?(role)

        existing = membership(db, workspace_id, user_id)
        raise Refused, :not_a_member if existing.nil?
        guard_last_owner!(db, workspace_id, user_id) if existing[:role] == 'owner' && role != 'owner'

        db[:memberships].where(id: existing[:id]).update(role: role)
      end

      def remove_member(db, workspace_id, user_id)
        guard_personal!(db, workspace_id)
        existing = membership(db, workspace_id, user_id)
        raise Refused, :not_a_member if existing.nil?
        guard_last_owner!(db, workspace_id, user_id) if existing[:role] == 'owner'

        db[:memberships].where(id: existing[:id]).delete
      end

      def membership(db, workspace_id, user_id)
        db[:memberships].first(workspace_id: workspace_id, user_id: user_id)
      end

      # --- the two guards --------------------------------------------------

      # FA-606: a personal workspace has exactly one member, for ever. Adding,
      # removing or demoting would break the guarantee of FA-602 by a side
      # door rather than by deleting.
      def guard_personal!(db, workspace_id)
        return unless db[:workspaces].where(id: workspace_id).get(:is_personal)

        raise Refused, :personal_workspace
      end

      # FA-603: the last owner may not step down before naming a successor.
      # Counted, not assumed — "there is surely someone else" is how a
      # workspace ends up without anyone who can administer it.
      def guard_last_owner!(db, workspace_id, user_id)
        others = db[:memberships]
                 .where(workspace_id: workspace_id, role: 'owner')
                 .exclude(user_id: user_id)
                 .count
        raise Refused, :last_owner if others.zero?
      end

      # The workspace this person last chose, or their personal one.
      #
      # TF-308g is the case that shapes this: someone can be removed from the
      # workspace that is still recorded as their last choice. Returning it
      # anyway would greet them with a 404 on the screen they land on, so the
      # membership is checked here rather than assumed. The personal workspace
      # is the fallback because FA-602 guarantees it exists.
      def selected_for(db, user)
        chosen = user[:last_workspace_id]
        return chosen if chosen && membership(db, chosen, user[:id])

        db[:memberships].join(:workspaces, id: :workspace_id)
                        .where(Sequel[:memberships][:user_id] => user[:id],
                               Sequel[:workspaces][:is_personal] => true)
                        .get(Sequel[:workspaces][:id])
      end

      # Every workspace the user belongs to, with their role — the payload of
      # GET /workspaces (FA-605).
      def for_user(db, user_id)
        db[:memberships]
          .join(:workspaces, id: :workspace_id)
          .where(Sequel[:memberships][:user_id] => user_id)
          .select(Sequel[:workspaces][:id], Sequel[:workspaces][:name],
                  Sequel[:workspaces][:slug], Sequel[:workspaces][:is_personal],
                  Sequel[:memberships][:role])
          .order(Sequel.desc(Sequel[:workspaces][:is_personal]), Sequel[:workspaces][:name])
          .all
      end
    end
  end
end
