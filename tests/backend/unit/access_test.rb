# frozen_string_literal: true

require_relative '../../test_helper'
require 'services/access'

# TF-201 — the permission matrix from Requirements 6.2, all 120 combinations.
#
# The matrix is restated here as a literal table rather than derived from
# Access::ACTIONS. That is the point: a test generated from the same source it
# checks proves only that the source equals itself. This table is transcribed
# from the document, so a typo in the implementation shows up as a difference
# between two independently written tables.
#
# The reference object of each group is fixed by test concept 6.2: prompt
# actions refer to P-WS in Marketing, content and workspace actions to the
# workspace Marketing, instance actions to the instance.
class AccessTest < PromptAtelier::TestCase
  A = PromptAtelier::Access

  # ● allowed · ◐ own objects only · ○ refused
  # Columns: viewer, editor, admin, owner, instance administrator
  MATRIX = {
    'prompt.read'         => %i[yes yes yes yes none],
    'prompt.render'       => %i[yes yes yes yes none],
    'prompt.favorite'     => %i[yes yes yes yes none],
    'prompt.create'       => %i[no  yes yes yes none],
    'prompt.update'       => %i[no  own yes yes none],
    'prompt.delete'       => %i[no  own yes yes none],
    'prompt.duplicate'    => %i[yes yes yes yes none],
    'prompt.move'         => %i[no  own yes yes none],
    'prompt.visibility'   => %i[no  own yes yes none],
    'trash.view'          => %i[no  own_only yes yes none],
    'trash.restore'       => %i[no  own yes yes none],
    'trash.purge'         => %i[no  no  yes yes none],
    'keyword.write'       => %i[no  yes yes yes none],
    'tag.create'          => %i[no  yes yes yes none],
    'prompt.export'       => %i[no  own_only yes yes forbidden],
    'prompt.import'       => %i[no  no  yes yes forbidden],
    'member.manage'       => %i[no  no  yes yes forbidden],
    'member.grant_owner'  => %i[no  no  no  yes forbidden],
    'workspace.rename'    => %i[no  no  yes yes yes],
    'workspace.delete'    => %i[no  no  no  yes yes],
    'user.manage'         => %i[no  no  no  no  yes],
    'user.reset_password' => %i[no  no  no  no  yes],
    'user.grant_admin'    => %i[no  no  no  no  yes],
    'audit.read'          => %i[no  no  no  no  yes]
  }.freeze

  COLUMNS = %w[viewer editor admin owner instance].freeze

  def test_tf201_the_matrix_covers_the_twenty_four_actions_of_chapter_six_two
    assert_equal 24, MATRIX.size
    assert_equal MATRIX.keys.sort, A::ACTIONS.keys.sort,
                 'implementation and document must name the same actions'
    assert_equal 120, MATRIX.size * COLUMNS.size
  end

  def test_tf201_every_one_of_the_hundred_and_twenty_combinations_matches
    checked = 0

    MATRIX.each do |action, expectations|
      COLUMNS.each_with_index do |column, index|
        expected = expectations[index]
        checked += 1

        assert_equal verdicts_for(expected), actual_verdicts(action, column),
                     "#{action} / #{column}: document says #{expected}"
      end
    end

    assert_equal 120, checked
  end

  # --- what the symbols mean ------------------------------------------------

  # ● — allowed regardless of who owns the object.
  # ◐ — two different things, deliberately kept apart. On a single object it
  #     means refused for other people's (:own). On a list or an export the
  #     call succeeds and the result is narrowed (:own_only) — collapsing the
  #     two would hide exactly the distinction footnote 3 of the matrix makes.
  # ○ — refused. For someone holding a role that is 403; for someone with no
  #     relationship to the workspace it is 404, because the object must not
  #     be shown to exist.
  def verdicts_for(expected)
    case expected
    when :yes       then { own: :allow,          other: :allow }
    when :own       then { own: :allow,          other: :forbidden }
    when :own_only  then { own: :allow_own_only, other: :allow_own_only }
    when :no        then { own: :forbidden,      other: :forbidden }
    when :forbidden then { own: :forbidden,      other: :forbidden }
    when :none      then { own: :not_found,      other: :not_found }
    end
  end

  def actual_verdicts(action, column)
    instance_admin = column == 'instance'
    role = instance_admin ? nil : column
    scope = A::ACTIONS.fetch(action)[:scope]

    # The reference prompt P-WS has visibility 'workspace', so it does not
    # exist for a non-member — which the instance administrator is. Workspaces
    # do exist for him; whether he is told so is decided by the action, not by
    # visibility, which is why only prompt-bound actions are hidden here.
    visible = !(instance_admin && scope == :prompt)

    %i[own other].to_h do |ownership|
      [ownership, A.verdict(action, role: role, instance_admin: instance_admin,
                                    owns: ownership == :own, visible: visible)]
    end
  end

  # --- the parts the matrix alone does not state ----------------------------

  # ◐ on a list is not the same verdict as ◐ on a single object: the call
  # succeeds and the result is narrowed. Collapsing the two in the table above
  # would have hidden that, so it is pinned separately.
  def test_an_editor_may_export_but_only_their_own
    assert_equal :allow_own_only,
                 A.verdict('prompt.export', role: 'editor', owns: false)
    assert_equal :allow,
                 A.verdict('prompt.export', role: 'admin', owns: false)
  end

  def test_an_editor_sees_only_their_own_prompts_in_the_trash
    assert_equal :allow_own_only, A.verdict('trash.view', role: 'editor')
    assert_equal :allow,          A.verdict('trash.view', role: 'owner')
  end

  # Someone with no relationship must not be able to tell an existing
  # workspace from one that was never there.
  def test_a_stranger_gets_not_found_rather_than_forbidden
    %w[prompt.create keyword.write tag.create member.manage].each do |action|
      assert_equal :not_found, A.verdict(action, role: nil),
                   "#{action} must not disclose that the workspace exists"
    end
  end

  # The exception the document makes: on administrative actions the instance
  # administrator already sees every workspace (FA-907), so hiding it there
  # would protect nothing.
  def test_the_instance_administrator_is_refused_openly_on_administration
    assert_equal :forbidden, A.verdict('member.manage', role: nil, instance_admin: true)
    assert_equal :forbidden, A.verdict('prompt.import', role: nil, instance_admin: true)
  end

  # ... but not on content. There the 404 stands even for him.
  def test_the_instance_administrator_still_gets_not_found_on_content
    assert_equal :not_found, A.verdict('keyword.write', role: nil, instance_admin: true)
    assert_equal :not_found, A.verdict('tag.create', role: nil, instance_admin: true)
  end

  # --- visibility (SEC-06, FA-604, TF-203) ----------------------------------

  SABINE = 1
  ANNA   = 2

  def prompt(visibility:, owner: SABINE, deleted: nil)
    { id: 7, workspace_id: 3, owner_id: owner, visibility: visibility, deleted_at: deleted }
  end

  def test_a_private_prompt_is_visible_to_its_owner_alone
    private_prompt = prompt(visibility: 'private')

    assert A.prompt_visible?(private_prompt, SABINE, 'owner')
    refute A.prompt_visible?(private_prompt, ANNA, 'editor')
  end

  # The most important line of TF-203. Anna administers the workspace and may
  # do nearly everything in it — but 'private' stays private in front of her
  # too. The matrix says "read a prompt (according to visibility)", and this is
  # what that parenthesis costs.
  def test_a_private_prompt_stays_hidden_from_the_workspace_administrator
    refute A.prompt_visible?(prompt(visibility: 'private'), ANNA, 'admin')
    refute A.prompt_visible?(prompt(visibility: 'private'), ANNA, 'owner')
  end

  def test_a_workspace_prompt_is_visible_to_every_member_and_nobody_else
    shared = prompt(visibility: 'workspace')

    A::ROLES.each { |role| assert A.prompt_visible?(shared, ANNA, role), role }
    refute A.prompt_visible?(shared, ANNA, nil), 'a non-member must not see it'
  end

  def test_an_instance_prompt_is_visible_without_any_membership
    assert A.prompt_visible?(prompt(visibility: 'instance'), ANNA, nil)
  end

  # Deleted means "in the trash" (FA-703). It must not come back through the
  # ordinary read path, not even for its owner — the trash has its own
  # endpoints and its own permissions.
  def test_a_prompt_in_the_trash_is_not_visible_through_the_normal_path
    %w[private workspace instance].each do |visibility|
      refute A.prompt_visible?(prompt(visibility: visibility, deleted: Time.now), SABINE, 'owner'),
             "#{visibility} in the trash must not be readable"
    end
  end

  def test_a_missing_prompt_is_not_visible
    refute A.prompt_visible?(nil, SABINE, 'owner')
  end

  # An outsider becomes a guest only through 'instance'. Anything else leaves
  # them without a role, which is what produces the 404.
  def test_the_guest_position_arises_only_from_instance_visibility
    assert_equal A::GUEST, A.role_towards(prompt(visibility: 'instance'), ANNA, nil)
    assert_nil   A.role_towards(prompt(visibility: 'workspace'), ANNA, nil)
    assert_equal 'editor', A.role_towards(prompt(visibility: 'instance'), ANNA, 'editor'),
                 'a membership always wins over the guest position'
  end

  # --- the guest position (FA-604) ------------------------------------------

  # The matrix in chapter 6.2 has five columns, and none of them is "reader of
  # an instance-wide prompt without membership". That position exists all the
  # same — FA-604 grants it — and it is the one an outsider actually occupies.
  # A mutation probe showed the 120 combinations above stay green while a guest
  # is handed the right to edit, which is why these two tests exist.
  GUEST_MAY = %w[prompt.read prompt.render prompt.favorite prompt.duplicate].freeze

  def test_a_guest_may_read_render_favourite_and_duplicate
    GUEST_MAY.each do |action|
      assert_equal :allow, A.verdict(action, role: A::GUEST),
                   "FA-604 grants #{action} on an instance-wide prompt"
    end
  end

  def test_a_guest_may_do_nothing_else_whatsoever
    (A::ACTIONS.keys - GUEST_MAY).each do |action|
      refute_equal :allow, A.verdict(action, role: A::GUEST, owns: true),
                   "#{action} must not be open to a non-member"
      refute_equal :allow_own_only, A.verdict(action, role: A::GUEST, owns: true),
                   "#{action} must not be open to a non-member"
    end
  end

  # Ownership must not be a way around the missing membership: a prompt of
  # one's own that has been moved into a foreign workspace is still foreign.
  def test_owning_the_object_does_not_promote_a_guest
    %w[prompt.update prompt.delete prompt.move trash.purge].each do |action|
      assert_equal :forbidden, A.verdict(action, role: A::GUEST, owns: true), action
    end
  end
end
