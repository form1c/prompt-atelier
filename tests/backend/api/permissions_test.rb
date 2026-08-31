# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../fixtures/instance'
require 'app'

# TF-201 to TF-207 over the API (test concept 6).
#
# Every check runs against the server with a valid session and a valid CSRF
# token: what is being tested is the permission, not the login. The interface
# hides forbidden actions as well, but that is convenience and not protection
# (SEC-06) — so nothing here goes through it.
#
# Twelve of the 24 actions hang on prompt endpoints that arrive in AP-07, and
# export and import on AP-14. Those rows are decided in access_test.rb against
# the same table and are repeated here once their endpoints exist. The rows
# whose endpoints exist today are checked over HTTP below.
class PermissionsTest < PromptAtelier::TestCase
  include Rack::Test::Methods

  A = PromptAtelier::Access
  W = PromptAtelier::Workspaces

  def app = PromptAtelier::App

  def setup
    super
    @dir = migrated_dir('permissions')
    PromptAtelier::App.boot!(root: @dir)
    PromptAtelier::RateLimit.reset!
    @ids = with_app_db { |db| PromptAtelier::Fixture.build(db) }
  end

  def teardown
    PromptAtelier::App.reset!
    PromptAtelier::RateLimit.reset!
    super
  end

  # --- TF-201: the rows whose endpoints exist -------------------------------

  # Reading the member list, managing members, granting the owner role,
  # renaming and deleting a workspace, plus the four instance actions.
  # Thomas gets 403, not 404. Administrative actions are the exception the
  # document makes: he already sees every workspace in his overview (FA-907),
  # so concealing this one would protect nothing.
  MEMBER_MANAGEMENT = {
    lisa: 403, martin: 403, anna: 200, sabine: 200, thomas: 403
  }.freeze

  def test_tf201_reading_the_member_list_follows_the_matrix
    MEMBER_MANAGEMENT.each do |person, expected|
      sign_in(person)
      get "#{prefix}/workspaces/#{marketing}/members"

      assert_equal expected, last_response.status, "#{person} reading members"
    end
  end

  def test_tf201_adding_a_member_follows_the_matrix
    MEMBER_MANAGEMENT.each do |person, expected|
      sign_in(person)
      csrf_post "#{prefix}/workspaces/#{marketing}/members",
                { user_id: @ids[:users][:joerg], role: 'viewer' }

      assert_equal(expected == 200 ? 201 : expected, last_response.status, "#{person} adding a member")
      remove_joerg_again if last_response.status == 201
    end
  end

  # The row that separates admin from owner — the only one in the matrix that
  # does. An admin manages members but must not be able to create an owner.
  def test_tf201_only_an_owner_may_grant_the_owner_role
    { lisa: 403, martin: 403, anna: 403, sabine: 200, thomas: 403 }.each do |person, expected|
      sign_in(person)
      csrf_put "#{prefix}/workspaces/#{marketing}/members/#{@ids[:users][:martin]}",
               { role: 'owner' }

      assert_equal expected, last_response.status, "#{person} granting owner"
      demote_martin_again if last_response.status == 200
    end
  end

  def test_tf201_renaming_a_workspace_follows_the_matrix
    { lisa: 403, martin: 403, anna: 200, sabine: 200, thomas: 200 }.each do |person, expected|
      sign_in(person)
      csrf_put "#{prefix}/workspaces/#{marketing}", { name: "Marketing #{person}" }

      assert_equal expected, last_response.status, "#{person} renaming"
    end
  end

  # ⚠ destructive: the last row really deletes *Marketing*. The fixture is
  # rebuilt for every test case, so that is contained (test concept 4).
  def test_tf201_deleting_a_workspace_follows_the_matrix
    { lisa: 403, martin: 403, anna: 403, sabine: 200 }.each do |person, expected|
      sign_in(person)
      csrf_delete "#{prefix}/workspaces/#{marketing}"

      assert_equal expected, last_response.status, "#{person} deleting"
    end
  end

  def test_tf201_the_instance_administrator_may_delete_any_workspace
    sign_in(:thomas)
    csrf_delete "#{prefix}/workspaces/#{marketing}"

    assert_equal 200, last_response.status
  end

  INSTANCE_ACTIONS = {
    lisa: 403, martin: 403, anna: 403, sabine: 403, thomas: :allowed
  }.freeze

  def test_tf201_instance_actions_are_open_to_the_instance_administrator_alone
    INSTANCE_ACTIONS.each do |person, expected|
      sign_in(person)

      get "#{prefix}/admin/audit"
      assert_equal(expected == :allowed ? 200 : expected, last_response.status, "#{person} audit")

      csrf_post "#{prefix}/admin/users", { name: "Neu #{person}", email: "neu-#{person}@example.test" }
      assert_equal(expected == :allowed ? 201 : expected, last_response.status, "#{person} creating an account")
    end
  end

  # FA-603 over the wire, named by address. The screen has no account list to
  # offer, so this is the path it uses.
  def test_a_member_may_be_added_by_e_mail_address
    sign_in(:sabine)
    csrf_post "#{prefix}/workspaces/#{marketing}/members",
              { email: PromptAtelier::Fixture::PEOPLE[:joerg][:email], role: 'editor' }

    assert_equal 201, last_response.status
    members = JSON.parse(last_response.body)['members']
    assert_includes members.map { |row| row['name'] }, 'Jörg'

    remove_joerg_again
  end

  # An address nobody holds is a typing mistake, and the answer has to say so
  # instead of creating a membership without an account behind it.
  def test_an_unknown_address_is_refused_with_a_reason
    sign_in(:sabine)
    csrf_post "#{prefix}/workspaces/#{marketing}/members",
              { email: 'niemand@example.test', role: 'editor' }

    assert_equal 422, last_response.status
    assert_equal 'unknown_user', JSON.parse(last_response.body).dig('error', 'code')
    with_app_db { |db| assert_equal 4, db[:memberships].where(workspace_id: marketing).count }
  end

  # Adding by address must not become a way around the matrix: the permission
  # is checked before the address is looked at, so an editor cannot use the
  # endpoint to find out whether an account exists.
  def test_adding_by_address_is_refused_before_the_address_is_resolved
    sign_in(:martin)
    csrf_post "#{prefix}/workspaces/#{marketing}/members",
              { email: PromptAtelier::Fixture::PEOPLE[:joerg][:email], role: 'editor' }
    assert_equal 403, last_response.status

    csrf_post "#{prefix}/workspaces/#{marketing}/members",
              { email: 'niemand@example.test', role: 'editor' }
    assert_equal 403, last_response.status, 'the same answer, or the status tells him what exists'
  end

  # --- TF-202: separation between tenants -----------------------------------

  # The core of A-05, run as Jörg, who has no access to *Marketing* at all.
  def test_tf202_a_stranger_is_told_nothing_about_a_foreign_workspace
    sign_in(:joerg)

    get "#{prefix}/workspaces/#{marketing}/members"
    assert_equal 404, last_response.status,
                 'a 403 here would let workspace ids be counted through'

    csrf_put "#{prefix}/workspaces/#{marketing}", { name: 'Meins' }
    assert_equal 404, last_response.status

    csrf_delete "#{prefix}/workspaces/#{marketing}"
    assert_equal 404, last_response.status
  end

  def test_tf202_a_stranger_sees_only_their_own_workspaces
    sign_in(:joerg)
    get "#{prefix}/workspaces"

    names = JSON.parse(last_response.body)['workspaces'].map { |w| w['name'] }
    assert_equal ['Persönlich-Jörg'], names
  end

  # The prompt endpoints arrive in AP-07. Until then the same statement is made
  # where the decision is taken, so the guarantee is not simply unproven in the
  # meantime.
  def test_tf202_the_access_layer_hides_foreign_prompts_from_a_stranger
    with_app_db do |db|
      joerg = db[:users][id: @ids[:users][:joerg]]

      assert_equal :not_found, verdict_for(db, joerg, 'P-WS', 'prompt.read')
      assert_equal :not_found, verdict_for(db, joerg, 'P-PRIV-S', 'prompt.read')
      assert_equal :allow,     verdict_for(db, joerg, 'P-INST', 'prompt.read')
      assert_equal :forbidden, verdict_for(db, joerg, 'P-INST', 'prompt.update')
      assert_equal :forbidden, verdict_for(db, joerg, 'P-INST', 'prompt.move')
      assert_equal :allow,     verdict_for(db, joerg, 'P-INST', 'prompt.duplicate')
    end
  end

  # --- TF-203: the search offers no way round the visibility ----------------

  def test_tf203_a_private_prompt_stays_private_even_before_the_administrator
    with_app_db do |db|
      expectations = { sabine: :allow, martin: :not_found, anna: :not_found,
                       joerg: :not_found, thomas: :not_found }

      expectations.each do |person, expected|
        user = db[:users][id: @ids[:users][person]]
        assert_equal expected, verdict_for(db, user, 'P-PRIV-S', 'prompt.read'),
                     "#{person} reading Sabine's private prompt"
      end
    end
  end

  def test_tf203_the_visibility_filter_excludes_foreign_private_prompts
    with_app_db do |db|
      %i[martin anna joerg thomas].each do |person|
        visible = db[:prompts].where(A.visible_prompts_filter(db, @ids[:users][person])).select_map(:id)

        refute_includes visible, @ids[:prompts]['P-PRIV-S'], "#{person} must not see it"
      end

      sabines = db[:prompts].where(A.visible_prompts_filter(db, @ids[:users][:sabine])).select_map(:id)
      assert_includes sabines, @ids[:prompts]['P-PRIV-S'], 'the owner does see it'
    end
  end

  def test_tf203_the_filter_never_returns_prompts_from_the_trash
    with_app_db do |db|
      %i[sabine martin anna].each do |person|
        visible = db[:prompts].where(A.visible_prompts_filter(db, @ids[:users][person])).select_map(:id)

        refute_includes visible, @ids[:prompts]['P-DEL'], "#{person} sees the trash through the filter"
      end
    end
  end

  # --- TF-204: duplicating needs the right to create ------------------------

  def test_tf204_the_target_workspace_decides_whether_a_copy_may_be_made
    with_app_db do |db|
      lisa = db[:users][id: @ids[:users][:lisa]]

      assert_equal :forbidden, A.for_target_workspace(db, lisa, marketing),
                   'a viewer may read but not put a copy back'
      assert_equal :allow, A.for_target_workspace(db, lisa, @ids[:workspaces][:personal_lisa])
      assert_equal :forbidden, A.for_target_workspace(db, lisa, @ids[:workspaces][:personal_martin]),
                   'and must not learn whether that workspace exists either'

      martin = db[:users][id: @ids[:users][:martin]]
      assert_equal :allow, A.for_target_workspace(db, martin, marketing)
    end
  end

  # A non-existent target answers exactly as a forbidden one. Without this the
  # endpoint would report whether a workspace id is in use.
  def test_tf204_an_unknown_target_is_indistinguishable_from_a_forbidden_one
    with_app_db do |db|
      lisa = db[:users][id: @ids[:users][:lisa]]

      assert_equal A.for_target_workspace(db, lisa, @ids[:workspaces][:personal_martin]),
                   A.for_target_workspace(db, lisa, 999_999)
    end
  end

  # --- TF-205: the personal workspace ---------------------------------------

  def test_tf205_nobody_may_delete_a_personal_workspace
    personal = @ids[:workspaces][:personal_martin]

    { martin: 403, thomas: 403 }.each do |person, expected|
      sign_in(person)
      csrf_delete "#{prefix}/workspaces/#{personal}"

      assert_equal expected, last_response.status, "#{person} deleting a personal workspace"
    end

    with_app_db { |db| assert_equal 1, db[:workspaces].where(id: personal).count }
  end

  def test_tf205_membership_of_a_personal_workspace_is_fixed
    personal = @ids[:workspaces][:personal_martin]
    sign_in(:martin)

    csrf_delete "#{prefix}/workspaces/#{personal}/members/#{@ids[:users][:martin]}"
    assert_equal 403, last_response.status

    csrf_put "#{prefix}/workspaces/#{personal}/members/#{@ids[:users][:martin]}", { role: 'viewer' }
    assert_equal 403, last_response.status
  end

  # TF-425 asks for two things, and until AP-13 only the second was checked.
  # "Die Aktion wird gar nicht erst angeboten" is a statement about what the
  # screen may show, and a screen may only show what the server tells it
  # (SEC-06) — so the workspace list has to say that this one cannot be
  # deleted and its membership cannot be touched.
  #
  # Read off the payload rather than off the matrix on purpose: the matrix
  # grants an owner `workspace.delete` without qualification, and the rule
  # that a personal workspace is exempt lives beside it. A test that consulted
  # the matrix would agree with the wrong half.
  def test_tf425_the_workspace_list_marks_the_personal_one_as_untouchable
    sign_in(:martin)
    get "#{prefix}/workspaces"

    entries = JSON.parse(last_response.body)['workspaces'].to_h { |row| [row['name'], row] }
    personal = entries.fetch("Persönlich-Martin")
    team = entries.fetch('Marketing')

    refute personal.dig('permissions', 'delete'), 'a personal workspace is never deletable'
    refute personal.dig('permissions', 'members'), 'its single membership is fixed (FA-606)'
    assert personal.dig('permissions', 'create'), 'but it is the one place he may always write'

    # The counter-check, or the assertion above would hold for a payload that
    # simply says "no" to everything.
    refute team.dig('permissions', 'delete'), 'an editor may not delete a team workspace either'
    assert team.dig('permissions', 'create')
  end

  # The same list seen by the owner: there the team workspace *is* deletable,
  # and hers still is not. Without this pair, "delete: false everywhere" would
  # pass both.
  def test_the_workspace_list_grants_deletion_to_the_owner_of_a_team_workspace
    sign_in(:sabine)
    get "#{prefix}/workspaces"

    entries = JSON.parse(last_response.body)['workspaces'].to_h { |row| [row['name'], row] }

    assert entries.fetch('Marketing').dig('permissions', 'delete')
    assert entries.fetch('Marketing').dig('permissions', 'members')
    assert entries.fetch('Marketing').dig('permissions', 'grant_owner'), 'only an owner hands out ownership'
    refute entries.fetch("Persönlich-Sabine").dig('permissions', 'delete')
  end

  # An admin manages members but may not make anyone an owner — the separate
  # row of the matrix that `authorize_owner_grant!` enforces. The screen has
  # to leave the option out, so the payload has to distinguish the two.
  def test_the_workspace_list_separates_managing_members_from_granting_ownership
    sign_in(:anna)
    get "#{prefix}/workspaces"

    marketing_row = JSON.parse(last_response.body)['workspaces'].find { |row| row['name'] == 'Marketing' }

    assert marketing_row.dig('permissions', 'members')
    refute marketing_row.dig('permissions', 'grant_owner')
  end

  # `trash.view` is the one entry that answers :allow_own_only rather than
  # :allow. Reading it as "not allowed" would shut an editor out of the trash
  # he is explicitly entitled to (FA-703) — and the endpoint would let him in,
  # so only the screen would be wrong.
  def test_an_editor_is_offered_the_trash_but_not_the_purge
    sign_in(:martin)
    get "#{prefix}/workspaces"

    marketing_row = JSON.parse(last_response.body)['workspaces'].find { |row| row['name'] == 'Marketing' }

    assert marketing_row.dig('permissions', 'trash'), 'an editor sees his own deletions'
    refute marketing_row.dig('permissions', 'purge'), 'purging is admin and owner only (FA-704)'
  end

  # --- TF-206: the last owner of a team workspace ---------------------------

  def test_tf206_the_only_owner_may_not_leave_before_naming_a_successor
    sign_in(:sabine)

    csrf_delete "#{prefix}/workspaces/#{marketing}/members/#{@ids[:users][:sabine]}"
    assert_equal 403, last_response.status
    assert_equal 'last_owner', JSON.parse(last_response.body).dig('error', 'code')

    csrf_put "#{prefix}/workspaces/#{marketing}/members/#{@ids[:users][:sabine]}", { role: 'admin' }
    assert_equal 403, last_response.status

    csrf_put "#{prefix}/workspaces/#{marketing}/members/#{@ids[:users][:anna]}", { role: 'owner' }
    assert_equal 200, last_response.status

    csrf_delete "#{prefix}/workspaces/#{marketing}/members/#{@ids[:users][:sabine]}"
    assert_equal 200, last_response.status
  end

  # --- TF-207: the last instance administrator ------------------------------

  # TF-408 is the same case in the edge-case chapter.
  def test_tf207_and_tf408_the_only_instance_administrator_may_not_step_down
    sign_in(:thomas)
    thomas = @ids[:users][:thomas]

    csrf_put "#{prefix}/admin/users/#{thomas}", { is_instance_admin: false }
    assert_equal 403, last_response.status

    csrf_put "#{prefix}/admin/users/#{@ids[:users][:sabine]}", { is_instance_admin: true }
    assert_equal 200, last_response.status

    csrf_put "#{prefix}/admin/users/#{thomas}", { is_instance_admin: false }
    assert_equal 200, last_response.status

    with_app_db { |db| refute db[:users][id: thomas][:is_instance_admin] }
  end

  # A locked successor is no successor. Counting every account with the flag,
  # active or not, would leave an instance nobody can administer.
  def test_tf207_a_locked_account_does_not_count_as_a_successor
    with_app_db do |db|
      db[:users].where(id: @ids[:users][:sabine])
                .update(is_instance_admin: true, status: 'locked')
    end

    sign_in(:thomas)
    csrf_put "#{prefix}/admin/users/#{@ids[:users][:thomas]}", { is_instance_admin: false }

    assert_equal 403, last_response.status
  end

  # --- FA-602 ---------------------------------------------------------------

  def test_a_newly_created_account_gets_its_personal_workspace
    sign_in(:thomas)
    csrf_post "#{prefix}/admin/users", { name: 'Neu', email: 'neu@example.test' }

    assert_equal 201, last_response.status
    created = JSON.parse(last_response.body)['user']['id']

    with_app_db do |db|
      workspaces = W.for_user(db, created)
      assert_equal 1, workspaces.size
      assert_equal 'Persönlich-Neu', workspaces.first[:name]
      assert_equal 'owner', workspaces.first[:role]
    end
  end

  private

  def prefix = PromptAtelier::App::API_PREFIX
  def marketing = @ids[:workspaces][:marketing]
  def with_app_db(&block) = PromptAtelier::Database.open(database_path(@dir), &block)

  def verdict_for(db, user, label, action)
    A.for_prompt(db, user, db[:prompts][id: @ids[:prompts][label]], action)
  end

  def sign_in(person)
    clear_cookies
    post "#{prefix}/auth/login",
         JSON.generate(email: PromptAtelier::Fixture::PEOPLE[person][:email],
                       password: PromptAtelier::Fixture::PASSWORD),
         'CONTENT_TYPE' => 'application/json'
    assert_equal 200, last_response.status, "could not sign in as #{person}: #{last_response.body}"
  end

  def csrf_token = rack_mock_session.cookie_jar[PromptAtelier::Sessions::CSRF_COOKIE_NAME]

  def csrf_post(path, payload)   = csrf_request(:post, path, payload)
  def csrf_put(path, payload)    = csrf_request(:put, path, payload)
  def csrf_delete(path, payload = nil) = csrf_request(:delete, path, payload)

  def csrf_request(method, path, payload)
    send(method, path, payload.nil? ? '' : JSON.generate(payload),
         'CONTENT_TYPE' => 'application/json', 'HTTP_X_CSRF_TOKEN' => csrf_token.to_s)
  end

  def remove_joerg_again
    with_app_db { |db| db[:memberships].where(workspace_id: marketing, user_id: @ids[:users][:joerg]).delete }
  end

  def demote_martin_again
    with_app_db { |db| db[:memberships].where(workspace_id: marketing, user_id: @ids[:users][:martin]).update(role: 'editor') }
  end
end
