# frozen_string_literal: true

require_relative '../../test_helper'
require 'services/workspaces'

# TF-205 and TF-206 at the level where the rules live — the endpoints are
# checked separately in permissions_test.rb.
#
# Both rules exist to stop a user being locked out of their own data: the
# personal workspace is the one place they can always write (FA-602, FA-606),
# and a team workspace that lost its last owner could never be administered
# again (FA-603).
class WorkspacesTest < PromptAtelier::TestCase
  W = PromptAtelier::Workspaces

  def setup
    super
    @dir = migrated_dir('workspaces')
  end

  def with_people
    with_db(@dir) do |db|
      sabine = create_user(db, 'sabine@test', 'Sabine')
      anna   = create_user(db, 'anna@test', 'Anna')
      marketing = W.create(db, name: 'Marketing', owner_id: sabine)
      yield db, sabine, anna, marketing
    end
  end

  # --- FA-602: every account gets a place to write --------------------------

  def test_a_new_account_receives_a_personal_workspace_it_owns
    with_db(@dir) do |db|
      user_id = create_user(db, 'martin@test', 'Martin')
      id = W.create_personal(db, db[:users][id: user_id])

      workspace = db[:workspaces][id: id]
      assert_equal 'Persönlich-Martin', workspace[:name]
      assert workspace[:is_personal]
      assert_equal 'owner', W.membership(db, id, user_id)[:role]
    end
  end

  def test_the_slug_follows_the_umlaut_rule_of_fa501
    with_db(@dir) do |db|
      user_id = create_user(db, 'jorg@test', 'Jörg')
      id = W.create_personal(db, db[:users][id: user_id])

      assert_equal 'personlich-jorg', db[:workspaces][id: id][:slug]
    end
  end

  # Two people with the same name are not an error, and neither is a second
  # workspace called "Marketing". The name belongs to the user, the slug to us.
  def test_a_colliding_slug_gets_a_counter_rather_than_an_error
    with_db(@dir) do |db|
      owner = create_user(db, 'a@test', 'A')
      first  = W.create(db, name: 'Marketing', owner_id: owner)
      second = W.create(db, name: 'Marketing', owner_id: owner)

      assert_equal 'marketing',   db[:workspaces][id: first][:slug]
      assert_equal 'marketing-1', db[:workspaces][id: second][:slug]
      assert_equal 'Marketing',   db[:workspaces][id: second][:name]
    end
  end

  # --- TF-205: the personal workspace is protected --------------------------

  # TF-425 states the same rule among the edge cases.
  def test_tf205_and_tf425_a_personal_workspace_cannot_be_deleted
    with_db(@dir) do |db|
      user_id = create_user(db, 'martin@test', 'Martin')
      id = W.create_personal(db, db[:users][id: user_id])

      error = assert_raises(W::Refused) { W.delete(db, id) }
      assert_equal :personal_workspace, error.code
      assert_equal 1, db[:workspaces].where(id: id).count
    end
  end

  def test_tf205_membership_of_a_personal_workspace_cannot_be_changed
    with_db(@dir) do |db|
      martin = create_user(db, 'martin@test', 'Martin')
      anna   = create_user(db, 'anna@test', 'Anna')
      id = W.create_personal(db, db[:users][id: martin])

      [-> { W.remove_member(db, id, martin) },
       -> { W.change_role(db, id, martin, 'viewer') },
       -> { W.add_member(db, id, anna, 'editor') }].each do |attempt|
        assert_equal :personal_workspace, assert_raises(W::Refused) { attempt.call }.code
      end

      assert_equal 'owner', W.membership(db, id, martin)[:role]
    end
  end

  # Renaming stays allowed — the contrast to deleting is deliberate (FA-608).
  def test_a_personal_workspace_may_be_renamed
    with_db(@dir) do |db|
      user_id = create_user(db, 'martin@test', 'Martin')
      id = W.create_personal(db, db[:users][id: user_id])

      W.rename(db, id, 'Meine Sachen')

      assert_equal 'Meine Sachen', db[:workspaces][id: id][:name]
    end
  end

  # --- TF-206: the last owner ----------------------------------------------

  # TF-407 is the same case seen from the edge-case chapter: the last owner
  # wanting to leave.
  def test_tf206_and_tf407_the_only_owner_cannot_remove_themselves
    with_people do |db, sabine, _anna, marketing|
      assert_equal :last_owner, assert_raises(W::Refused) { W.remove_member(db, marketing, sabine) }.code
      assert_equal 'owner', W.membership(db, marketing, sabine)[:role]
    end
  end

  def test_tf206_the_only_owner_cannot_demote_themselves
    with_people do |db, sabine, _anna, marketing|
      assert_equal :last_owner, assert_raises(W::Refused) { W.change_role(db, marketing, sabine, 'admin') }.code
    end
  end

  def test_tf206_after_naming_a_successor_the_owner_may_leave
    with_people do |db, sabine, anna, marketing|
      W.add_member(db, marketing, anna, 'admin')
      W.change_role(db, marketing, anna, 'owner')
      W.remove_member(db, marketing, sabine)

      assert_nil W.membership(db, marketing, sabine)
      assert_equal 'owner', W.membership(db, marketing, anna)[:role]
    end
  end

  # An admin leaving is not an owner leaving — the guard must not fire on
  # everyone, or nobody could ever be removed.
  def test_a_member_who_is_not_the_last_owner_can_be_removed
    with_people do |db, _sabine, anna, marketing|
      W.add_member(db, marketing, anna, 'editor')
      W.remove_member(db, marketing, anna)

      assert_nil W.membership(db, marketing, anna)
    end
  end

  # --- ordinary refusals ----------------------------------------------------

  def test_names_are_checked
    with_db(@dir) do |db|
      owner = create_user(db, 'a@test', 'A')

      assert_equal :name_required, assert_raises(W::Refused) { W.create(db, name: '  ', owner_id: owner) }.code
      assert_equal :name_too_long,
                   assert_raises(W::Refused) { W.create(db, name: 'x' * 101, owner_id: owner) }.code
    end
  end

  def test_unknown_roles_and_unknown_users_are_refused
    with_people do |db, _sabine, anna, marketing|
      assert_equal :unknown_role, assert_raises(W::Refused) { W.add_member(db, marketing, anna, 'chef') }.code
      assert_equal :unknown_user, assert_raises(W::Refused) { W.add_member(db, marketing, 9999, 'editor') }.code

      W.add_member(db, marketing, anna, 'editor')
      assert_equal :already_member, assert_raises(W::Refused) { W.add_member(db, marketing, anna, 'admin') }.code
    end
  end

  # FA-606 asks for the name as confirmation. Checked on the server, because a
  # dialogue in the browser is a reminder, not a safeguard.
  def test_deleting_a_team_workspace_needs_the_name_when_one_is_given
    with_people do |db, _sabine, _anna, marketing|
      assert_equal :confirmation_mismatch,
                   assert_raises(W::Refused) { W.delete(db, marketing, confirmation: 'Marketng') }.code

      W.delete(db, marketing, confirmation: 'Marketing')
      assert_equal 0, db[:workspaces].where(id: marketing).count
    end
  end

  def test_deleting_takes_the_memberships_with_it
    with_people do |db, sabine, _anna, marketing|
      W.delete(db, marketing)

      assert_equal 0, db[:memberships].where(workspace_id: marketing).count
      assert_equal 1, db[:users].where(id: sabine).count, 'the account itself stays'
    end
  end

  # --- FA-603: naming the account to add ------------------------------------

  # The address, not the identifier. A workspace owner has no account list to
  # pick from — that belongs to the instance administrator (Requirements 6.2)
  # — so the address is the only thing they can be expected to know.
  def test_a_member_is_found_by_e_mail_address
    with_people do |db, _sabine, anna, _marketing|
      assert_equal anna, W.resolve_member(db, email: 'anna@test')
    end
  end

  # `COLLATE NOCASE` everywhere else, and here too. Someone typing an address
  # from a signature line gets whatever capitalisation the sender used.
  def test_the_address_is_compared_without_regard_to_case_or_padding
    with_people do |db, _sabine, anna, _marketing|
      assert_equal anna, W.resolve_member(db, email: '  Anna@TEST  ')
    end
  end

  def test_an_unknown_address_is_refused_rather_than_silently_ignored
    with_people do |db, _sabine, _anna, _marketing|
      refused = assert_raises(W::Refused) { W.resolve_member(db, email: 'niemand@test') }
      assert_equal :unknown_user, refused.code

      # An empty field must not resolve to "the first account" or to nil —
      # nil would reach add_member and insert a membership without a user.
      assert_raises(W::Refused) { W.resolve_member(db, email: '   ') }
      assert_raises(W::Refused) { W.resolve_member(db) }
    end
  end

  # The identifier still works, because the API kept it (15.3) and an import
  # or a script has one to hand.
  def test_an_identifier_is_taken_as_given
    with_people do |db, _sabine, anna, _marketing|
      assert_equal anna, W.resolve_member(db, user_id: anna)
      assert_equal anna, W.resolve_member(db, user_id: anna, email: 'sabine@test')
    end
  end

  def test_for_user_lists_the_workspaces_with_the_role_and_personal_first
    with_people do |db, sabine, _anna, marketing|
      personal = W.create_personal(db, db[:users][id: sabine])

      listed = W.for_user(db, sabine)
      assert_equal [personal, marketing], listed.map { |row| row[:id] }
      assert_equal %w[owner owner], listed.map { |row| row[:role] }
    end
  end

  private

  def create_user(db, email, name)
    now = Time.now
    db[:users].insert(email: email, name: name, password_hash: 'x',
                      created_at: now, updated_at: now)
  end
end
