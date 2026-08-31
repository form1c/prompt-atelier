# frozen_string_literal: true

require_relative '../../test_helper'
require 'open3'
require 'services/prompts'
require 'services/workspaces'

# scripts/seed_demo — example data for a development installation.
#
# The one script that is meant to change the database it finds. That is why it
# is tested at all, and why every case here is about the promise it makes: it
# adds what the package holds, it can be run twice, and it takes back exactly
# what it put in.
#
# Started as a subprocess against a throwaway installation. Calling the module
# in this process would test a copy of the logic with a different notion of
# where the installation is — and the installation directory is the whole
# point of a script that writes.
class SeedDemoTest < PromptAtelier::TestCase
  def test_it_puts_the_package_into_a_workspace_of_its_own
    dir = installation

    output = seed(dir, '--yes')

    assert_match(/Created #{shipped_prompts} prompts/, output)
    with_db(dir) do |db|
      workspace = db[:workspaces].first(name: 'Beispiele')
      refute_nil workspace, 'the package names the workspace it belongs in'
      assert_equal shipped_prompts, db[:prompts].where(workspace_id: workspace[:id]).count
      assert_equal 10, db[:keywords].where(workspace_id: workspace[:id]).count
    end
  end

  # The prompts have to arrive as prompts, not as rows: variables recognised,
  # tags assigned, default keywords attached. They go through the same service
  # the API uses, so this is what proves the package fits it.
  def test_the_prompts_arrive_complete
    dir = installation
    seed(dir, '--yes')

    with_db(dir) do |db|
      prompt = db[:prompts].first(title: 'Blogartikel-Generator')
      refute_nil prompt

      variables = db[:prompt_variables].where(prompt_id: prompt[:id]).order(:position).all
      assert_equal %w[thema zielgruppe laenge], variables.map { |row| row[:key] }
      assert variables.first[:required], 'thema is required — TF-401 needs such a case'
      assert_equal "Einsteiger\nFortgeschrittene\nProfis", variables[1][:options]

      assert_includes PromptAtelier::Prompts.tag_names(db, prompt[:id]), 'seo'
      assert_includes PromptAtelier::Prompts.keyword_names(db, prompt[:id]), 'formal'
    end
  end

  # NT-3 asks for about fifty prompts and two keywords to switch on. Both
  # figures are what makes "find a particular one" mean anything, so they are
  # stated here rather than left to whoever edits the package next.
  def test_the_package_carries_enough_for_the_user_test
    dir = installation
    seed(dir, '--yes')

    with_db(dir) do |db|
      assert_operator db[:prompts].count, :>=, 40
      assert_operator db[:keywords].count, :>=, 5
      assert_operator db[:prompt_variables].count, :>=, 40
    end
  end

  def test_a_second_run_changes_nothing
    dir = installation
    seed(dir, '--yes')
    before = counts(dir)

    output = seed(dir, '--yes')

    assert_match(/Created 0 prompts/, output)
    assert_match(/#{shipped_prompts} prompts were already there/, output)
    assert_equal before, counts(dir)
  end

  def test_remove_takes_back_exactly_what_was_added
    dir = installation
    empty = counts(dir)
    seed(dir, '--yes')

    output = seed(dir, '--remove')

    assert_match(/Removed #{shipped_prompts} example prompts/, output)
    # Down to the labels: an unused tag or keyword left behind would clutter
    # the very screens the test is about.
    assert_equal empty, counts(dir)
  end

  # The counter-check to the line above: a keyword that has meanwhile been put
  # on somebody's own prompt stays. Removing it would silently change what
  # that prompt renders.
  def test_remove_keeps_a_keyword_that_is_still_in_use
    dir = installation
    seed(dir, '--yes')

    own = with_db(dir) do |db|
      workspace = db[:workspaces].first(name: 'Beispiele')
      keyword = db[:keywords].first(workspace_id: workspace[:id], name: 'formal')
      id = db[:prompts].insert(workspace_id: workspace[:id], owner_id: db[:users].first[:id],
                               title: 'Eigener Prompt', body: 'Text.', visibility: 'private',
                               status: 'active', created_at: Time.now, updated_at: Time.now)
      db[:prompt_keywords].insert(prompt_id: id, keyword_id: keyword[:id])
      id
    end

    seed(dir, '--remove')

    with_db(dir) do |db|
      assert_equal 1, db[:prompts].where(id: own).count, 'a prompt without the marker is not ours to delete'
      refute_nil db[:keywords].first(name: 'formal'), 'still in use, so it stays'
    end
  end

  def test_it_refuses_while_the_schema_is_behind
    dir = installation
    # The state somebody is really in after pulling a new version: the tables
    # are there, a step is not.
    with_db(dir) { |db| db[:schema_migrations].where(version: '002_utc_timestamps').delete }

    output = seed(dir, '--yes', expect_failure: true)

    assert_match(/schema is not up to date/, output)
    assert_match(/migrate/, output)
    assert_equal 0, with_db(dir) { |db| db[:prompts].count }
  end

  def test_it_refuses_without_a_database_at_all
    dir = installation(migrate: false)

    output = seed(dir, '--yes', expect_failure: true)

    assert_match(/no database/, output)
    assert_match(/migrate/, output)
  end

  # The same rule as reset_admin_password (BT-13): with several instance
  # administrators the script stops and names them rather than picking one.
  def test_it_stops_when_the_account_is_ambiguous
    dir = installation
    with_db(dir) do |db|
      db[:users].insert(email: 'zweiter@test', name: 'Zweiter', password_hash: 'x',
                        is_instance_admin: true, created_at: Time.now, updated_at: Time.now)
    end

    output = seed(dir, '--yes', expect_failure: true)

    assert_match(/Several instance administrators/, output)
    assert_match(/zweiter@test/, output)
    assert_equal 0, with_db(dir) { |db| db[:prompts].count }, 'and it writes nothing'
  end

  # Without --yes it asks, and an empty answer is a no — the safe direction
  # for a script that changes a database somebody is working in. It leaves
  # with a non-zero code, because it did not do what it was called for.
  def test_without_a_confirmation_it_writes_nothing
    dir = installation

    output = seed(dir, input: "\n", expect_failure: true)

    assert_match(/Aborted/, output)
    assert_equal 0, with_db(dir) { |db| db[:prompts].count }
  end

  def test_a_yes_at_the_prompt_is_enough
    dir = installation

    seed(dir, input: "j\n")

    assert_operator with_db(dir) { |db| db[:prompts].count }, :>, 40
  end

  private

  # How many prompts the delivered package holds — read from it rather than
  # written down here. A number in a test is a number somebody has to keep in
  # step with the data, and the day it is wrong the test says "the script is
  # broken" about a package that simply gained an example (AP-23 added four).
  def shipped_prompts
    JSON.parse(File.read(File.join(CODE_ROOT, 'examples', 'examples.json'),
                         encoding: 'UTF-8'))['prompts'].size
  end

  def installation(migrate: true)
    dir = build_installation(app_dir_name: 'backend', migrate: migrate)
    FileUtils.cp_r(File.join(CODE_ROOT, 'scripts'), dir)
    FileUtils.cp_r(File.join(CODE_ROOT, 'examples'), dir)
    seed_account(dir) if migrate
    dir
  end

  def seed_account(dir)
    with_db(dir) do |db|
      now = Time.now
      id = db[:users].insert(email: 'admin@test', name: 'Thomas', password_hash: 'x',
                             is_instance_admin: true, created_at: now, updated_at: now)
      PromptAtelier::Workspaces.create_personal(db, db[:users][id: id], now: now)
    end
  end

  def seed(dir, *arguments, input: '', expect_failure: false)
    output, status = Open3.capture2e(
      { 'BUNDLE_GEMFILE' => File.join(dir, 'backend', 'Gemfile') },
      RbConfig.ruby, File.join(dir, 'scripts', 'lib', 'seed_demo.rb'), *arguments,
      stdin_data: input
    )

    if expect_failure
      refute status.success?, "the script should have refused:\n#{output}"
    else
      assert status.success?, "the script failed:\n#{output}"
    end
    output
  end

  def counts(dir)
    with_db(dir) do |db|
      %i[prompts prompt_variables prompt_tags prompt_keywords tags keywords].to_h do |table|
        [table, db[table].count]
      end
    end
  end
end
