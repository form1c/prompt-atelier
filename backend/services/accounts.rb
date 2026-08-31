# frozen_string_literal: true

require 'securerandom'

require_relative 'password'
require_relative 'sessions'
require_relative 'workspaces'

module PromptAtelier
  # Accounts, as the instance administrator sees them (FA-901 to FA-906).
  #
  # Everything here touches a person's access, and two rules run through all of
  # it:
  #
  #   * **A lost account must not take content with it by accident.** Locking
  #     leaves the prompts where they are (FA-902); deleting asks what should
  #     happen to them (FA-904). Neither decides on the user's behalf.
  #   * **A change to access ends the sessions it applied to** (SEC-15).
  #     Locking, resetting a password and deleting all discard them at once —
  #     a lock that leaves an open session running is a lock in name only.
  module Accounts
    # Long enough to be safe and short enough to read out over the phone,
    # which is how it will travel (FA-903 leaves the channel to the operator).
    INITIAL_PASSWORD_BYTES = 20

    PROMPT_ACTIONS = %w[delete transfer].freeze

    class Refused < StandardError
      attr_reader :code, :detail

      def initialize(code, detail = {})
        @code = code
        @detail = detail
        super(code.to_s)
      end
    end

    class << self
      # --- creating (FA-901, FA-107, FA-602) ---------------------------------

      # The one place an account comes into being. Three paths lead here —
      # first setup, the administrator's form and self-registration — and they
      # differ only in the arguments. Kept together because of the line that is
      # easy to forget on a new path: FA-602 wants a place to write from the
      # first moment, and an account without a personal workspace can neither
      # save anything nor be deleted cleanly (FA-606).
      #
      # +pending+ marks an account that registered itself while the instance
      # asks for approval. It is locked like any other locked account — the
      # login gate is the single condition it always was — and the timestamp
      # only decides what the person is told and how the entry is listed.
      def create(db, name:, email:, password:, now: Time.now,
                 pending: false, must_change_password: false, instance_admin: false)
        id = db[:users].insert(
          email: email.to_s.strip, name: name.to_s.strip,
          password_hash: Password.create(password),
          must_change_pw: must_change_password,
          is_instance_admin: instance_admin,
          status: pending ? 'locked' : 'active',
          pending_since: pending ? now : nil,
          # **Empty means "has not chosen"** (AP-19, 11.7), and it is written
          # here rather than left to the column default.
          #
          # `users.locale` carries `DEFAULT 'de'` from migration 001, back when
          # an instance spoke one language and the column never varied. Left
          # alone, every account created on an English instance would be
          # pinned to German by a default nobody chose — and a pinned value is
          # indistinguishable from a decision, so the chain of 11.7 could never
          # fall through to the instance or the browser.
          #
          # An empty string rather than a schema step to make the column
          # nullable: `offered?('')` is false, so it falls through on its
          # own, and the rows that already exist keep saying `de` — which is
          # what those people are actually reading.
          locale: '',
          created_at: now, updated_at: now
        )
        user = db[:users][id: id]
        Workspaces.create_personal(db, user, now: now)

        user
      end

      # --- the list (FA-906) -----------------------------------------------

      # Name, address, status, last sign-in and the two counts. The counts are
      # what make the list useful before deleting: "3 Workspaces, 41 Prompts"
      # is the question FA-904 is about to ask, answered in advance.
      #
      # Counted in one query per column rather than per row — the same reason
      # as in the library (NFA-02).
      def list(db, term: nil)
        # Whoever is waiting comes first. Without e-mail (E-13) the
        # application cannot call the administrator, so the only way a pending
        # registration gets noticed is by being where he already looks — and a
        # newcomer sorted under "M" behind forty colleagues is a person who
        # concludes the tool is broken.
        rows = db[:users].order(Sequel.desc(Sequel.~(pending_since: nil)), :name)
        rows = matching(rows, term) unless term.to_s.strip.empty?

        prompts = db[:prompts].where(deleted_at: nil).group_and_count(:owner_id).to_hash(:owner_id, :count)
        spaces  = db[:memberships].group_and_count(:user_id).to_hash(:user_id, :count)

        rows.all.map do |user|
          public_account(user).merge(
            'prompt_count' => prompts[user[:id]] || 0,
            'workspace_count' => spaces[user[:id]] || 0
          )
        end
      end

      # Name or address, without regard to case. SQLite's own `lower()` is
      # ASCII-only (see the note in normalization.rb), which is good enough
      # here: a search field is a convenience, not a rule anything depends on.
      def matching(rows, term)
        pattern = "%#{term.to_s.strip.downcase}%"

        rows.where(Sequel.|(Sequel.like(Sequel.function(:lower, :name), pattern),
                            Sequel.like(Sequel.function(:lower, :email), pattern)))
      end

      # Never the password hash. Not by filtering it out afterwards but by
      # naming what goes out — a new column must be a decision.
      def public_account(user)
        {
          'id' => user[:id], 'name' => user[:name], 'email' => user[:email],
          'status' => user[:status], 'is_instance_admin' => user[:is_instance_admin] == true,
          'must_change_password' => user[:must_change_pw] == true,
          'pending_since' => user[:pending_since]&.iso8601,
          'last_login_at' => user[:last_login_at]&.iso8601,
          'created_at' => user[:created_at]&.iso8601
        }
      end

      # A registration waiting to be let in (FA-107). Locked and waiting are
      # the same thing to the login gate and two different things to everybody
      # else, which is the whole reason the column exists.
      def pending?(user) = !user[:pending_since].nil?

      # --- locking (FA-902) -------------------------------------------------

      # The prompts stay exactly where they are and stay visible to whoever may
      # see them (TF-410). A lock is about the person, not about their work.
      def lock(db, user, now: Time.now)
        raise Refused, :already_locked if user[:status] == 'locked'

        guard_last_instance_admin!(db, user) if user[:is_instance_admin]

        db[:users].where(id: user[:id]).update(status: 'locked', updated_at: now)
        Sessions.destroy_all_for(db, user[:id])
      end

      # Refuses a waiting registration on purpose, although the row change
      # would be identical. Letting somebody in for the first time and lifting
      # a lock one imposed oneself are different administrative acts: they are
      # decided on different grounds, they belong in the log under different
      # names, and a single button for both would record the wrong one.
      def unlock(db, user, now: Time.now)
        raise Refused, :approval_required if pending?(user)
        raise Refused, :not_locked unless user[:status] == 'locked'

        db[:users].where(id: user[:id]).update(status: 'active', updated_at: now)
      end

      # --- approving a registration (FA-107) --------------------------------

      def approve(db, user, now: Time.now)
        raise Refused, :not_pending unless pending?(user)

        db[:users].where(id: user[:id])
                  .update(status: 'active', pending_since: nil, updated_at: now)
      end

      # --- resetting a password (FA-903) ------------------------------------

      # Returns the one-time password. It is shown once and stored nowhere in
      # readable form — the caller hands it over by a channel this application
      # neither knows nor could secure.
      def reset_password(db, user, now: Time.now)
        initial = SecureRandom.alphanumeric(INITIAL_PASSWORD_BYTES)
        db[:users].where(id: user[:id]).update(
          password_hash: Password.create(initial), must_change_pw: true, updated_at: now
        )
        # SEC-15: whoever held a session under the old password loses it. Doing
        # this after the change and not before leaves no window in which the
        # old one still works.
        Sessions.destroy_all_for(db, user[:id])

        initial
      end

      # --- deleting (FA-904, SEC-17) ----------------------------------------

      # +prompts_action+ is 'delete' or 'transfer'; the latter needs a
      # successor. Asked rather than assumed: deleting somebody's account is
      # an administrative act, deleting their work is a content decision, and
      # the two do not have to point the same way.
      #
      # What survives is the audit trail. `actor_id` is cleared and
      # `actor_name` stays, so administrative acts remain readable after the
      # person is gone (SEC-17).
      def delete(db, user, prompts_action:, successor_id: nil, now: Time.now)
        raise Refused.new(:unknown_prompts_action, { allowed: PROMPT_ACTIONS }) \
          unless PROMPT_ACTIONS.include?(prompts_action.to_s)

        guard_last_instance_admin!(db, user)
        successor = resolve_successor(db, user, prompts_action, successor_id)

        db.transaction do
          if successor then rehome(db, user, successor, now) else db[:prompts].where(owner_id: user[:id]).delete end

          # FA-606 says it plainly: the personal workspace disappears with the
          # account and at no other time. It goes after the prompts have been
          # dealt with, because the cascade would take with it anything still
          # standing in it.
          db[:workspaces].where(id: personal_workspace_of(db, user)).delete

          db[:audit_logs].where(actor_id: user[:id]).update(actor_id: nil)
          db[:users].where(id: user[:id]).delete
        end
      end

      def resolve_successor(db, user, prompts_action, successor_id)
        return nil unless prompts_action.to_s == 'transfer'

        raise Refused, :successor_required if successor_id.nil?
        raise Refused, :successor_is_the_same if successor_id.to_i == user[:id]

        successor = db[:users][id: successor_id.to_i]
        raise Refused, :unknown_successor if successor.nil?

        successor
      end

      # Handing the prompts over, in two steps that are easy to get wrong
      # together.
      #
      # **Where they live** comes first. A prompt in the deleted account's own
      # personal workspace has to leave it — that workspace is about to go
      # (FA-606) — and it cannot move into the successor's personal one by
      # membership, because a personal workspace never takes a second member.
      # So it is moved outright, into the one place the successor is certain
      # to be able to write.
      #
      # **Who owns them** comes second, and for the prompts that stay in a
      # team workspace the successor has to be a member of it — an inherited
      # prompt he cannot see would be inherited in name only.
      def rehome(db, user, successor, now)
        mine = personal_workspace_of(db, user)
        target = personal_workspace_of(db, successor)
        db[:prompts].where(owner_id: user[:id], workspace_id: mine)
                    .update(workspace_id: target, updated_at: now)

        elsewhere = db[:prompts].where(owner_id: user[:id]).exclude(workspace_id: target)
                                .select_map(:workspace_id).uniq
        elsewhere.each do |workspace_id|
          next if Workspaces.membership(db, workspace_id, successor[:id])

          Workspaces.add_member(db, workspace_id, successor[:id], 'editor', now: now)
        end

        db[:prompts].where(owner_id: user[:id]).update(owner_id: successor[:id], updated_at: now)
      end

      def personal_workspace_of(db, user)
        db[:memberships].join(:workspaces, id: :workspace_id)
                        .where(Sequel[:memberships][:user_id] => user[:id],
                               Sequel[:workspaces][:is_personal] => true)
                        .get(Sequel[:workspaces][:id])
      end

      # FA-905 for the two paths that can remove the last one without saying
      # so: locking him out and deleting him. The flag being taken away
      # deliberately is guarded at the endpoint; these two would do it as a
      # side effect, which is worse.
      def guard_last_instance_admin!(db, user)
        return unless user[:is_instance_admin]

        others = db[:users].where(is_instance_admin: true, status: 'active')
                           .exclude(id: user[:id]).count
        raise Refused, :last_instance_admin if others.zero?
      end
    end
  end
end
