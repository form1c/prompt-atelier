# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../../backend/services/prompts'
require_relative '../../../backend/services/transfer'

# TF-460 to TF-463b — migration 005, the step that translates the domain
# values (AP-18).
#
# **Every case here starts from a database in the old format.** A test that
# migrated an empty installation would pass while doing nothing: the whole
# risk of this step is in the rows that already exist — the snapshots, the
# children hanging off `prompts` and `users`, and an FTS index keyed by ids
# that must survive a table being replaced underneath it.
class EnglishDomainValuesTest < PromptAtelier::TestCase
  def setup
    super
    @extra_dirs = []
  end

  def teardown
    @extra_dirs.each { |dir| FileUtils.rm_rf(dir) }
    super
  end

  # --- TF-460: the values, the constraints, the snapshots -------------------

  def test_tf460_every_domain_value_is_english_afterwards
    dir = stocked_installation('tf460')
    migrator_for(dir).run

    with_db(dir) do |db|
      assert_equal %w[active locked], db[:users].order(:email).select_map(:status).uniq.sort
      assert_equal %w[instance private workspace],
                   db[:prompts].select_map(:visibility).uniq.sort
      assert_equal %w[active archived draft], db[:prompts].select_map(:status).uniq.sort
      assert_equal %w[multiline number select text],
                   db[:prompt_variables].select_map(:type).uniq.sort
    end
  end

  def test_tf460_the_constraints_refuse_the_old_words
    dir = stocked_installation('tf460b')
    migrator_for(dir).run

    with_db(dir) do |db|
      workspace = db[:workspaces].first[:id]
      owner     = db[:users].first[:id]

      refused = {
        'prompts.visibility' => -> { insert_prompt_row(db, workspace, owner, visibility: 'privat') },
        'prompts.status'     => -> { insert_prompt_row(db, workspace, owner, status: 'entwurf') },
        'users.status'       => -> { db[:users].where(id: owner).update(status: 'aktiv') }
      }

      refused.each do |what, attempt|
        assert_raises(Sequel::DatabaseError, "#{what} must refuse the German value") { attempt.call }
      end

      prompt = db[:prompts].first[:id]
      assert_raises(Sequel::DatabaseError, 'prompt_variables.type must refuse the German value') do
        db[:prompt_variables].insert(prompt_id: prompt, key: 'x', type: 'zahl')
      end
    end
  end

  # The trap the whole step exists for: a snapshot keeps the old values inside
  # its JSON, and FA-702 writes them straight back into the column.
  def test_tf460_the_snapshots_travel_with_the_columns
    dir = stocked_installation('tf460c')
    migrator_for(dir).run

    with_db(dir) do |db|
      snapshots = db[:prompt_revisions].select_map(:snapshot_json).map { |json| JSON.parse(json) }
      refute_empty snapshots, 'a stock without revisions would prove nothing here'

      assert_equal ['draft'], snapshots.map { |s| s['status'] }.uniq
      assert_equal ['private'], snapshots.map { |s| s['visibility'] }.uniq
      assert_equal %w[multiline number select text],
                   snapshots.flat_map { |s| s['variables'].map { |v| v['type'] } }.uniq.sort
    end
  end

  # And the consequence, end to end: undo on a prompt written before the
  # migration. Without step 6 this raises a CHECK violation — weeks later, on
  # a screen that has nothing to do with migrations.
  def test_tf460_undo_still_works_on_a_prompt_from_before_the_migration
    dir = stocked_installation('tf460d')
    migrator_for(dir).run

    with_db(dir) do |db|
      prompt = db[:prompts].where(title: 'Bericht').first
      db[:prompts].where(id: prompt[:id]).update(title: 'Bericht, geändert')

      restored = PromptAtelier::Prompts.undo(db, db[:prompts][id: prompt[:id]], actor_id: prompt[:owner_id])

      assert_equal 'Bericht', restored[:title], 'the old title must come back'
      assert_equal 'draft', restored[:status], 'and with the value the snapshot carried'
      assert_equal 'private', restored[:visibility]
      assert_equal %w[multiline number select text],
                   db[:prompt_variables].where(prompt_id: prompt[:id]).select_map(:type).sort
    end
  end

  # The escaping argument the text replacement rests on, tested with the one
  # prompt that could break it: a body that literally contains the member the
  # migration searches for.
  def test_tf460_a_prompt_that_talks_about_json_is_left_alone
    dir = stocked_installation('tf460e')
    migrator_for(dir).run

    with_db(dir) do |db|
      prompt = db[:prompts].where(title: 'JSON-Köder').first
      assert_equal BAIT, prompt[:body], 'the body must survive the replacement byte for byte'

      snapshot = JSON.parse(db[:prompt_revisions].where(prompt_id: prompt[:id]).first[:snapshot_json])
      assert_equal BAIT, snapshot['body'], 'and so must the copy of it inside the snapshot'
      assert_equal 'draft', snapshot['status'], 'while the real member is translated'
    end
  end

  # --- TF-460f: the cascade, which is what makes this step dangerous --------

  # `DROP TABLE prompts` with foreign keys on fires ON DELETE CASCADE and takes
  # every child with it — silently, because a cascade is not a violation.
  # Measured: without `foreign_keys: :off` on the step this test loses all four
  # counts below. It is the reason the migrator learned to set that pragma.
  def test_tf460f_nothing_hanging_off_the_rebuilt_tables_is_lost
    dir = stocked_installation('tf460f')

    before = with_db(dir) { |db| child_counts(db) }
    before.each { |table, count| refute_equal 0, count, "#{table} must hold rows before the migration" }

    migrator_for(dir).run

    after = with_db(dir) { |db| child_counts(db) }
    assert_equal before, after, 'the rebuild must not take a single child row with it'
  end

  # --- TF-461: the index after the table was replaced under it --------------

  def test_tf461_the_search_still_finds_what_it_found_before
    dir = stocked_installation('tf461')
    wanted = with_db(dir) { |db| search(db, 'Grosse') }
    refute_empty wanted, 'a search that found nothing beforehand would prove nothing'

    migrator_for(dir).run

    with_db(dir) do |db|
      assert_equal wanted, search(db, 'Grosse'), 'FA-501 must survive the table rebuild'
      assert_equal wanted, search(db, 'Größe')
      db.run("INSERT INTO prompts_fts(prompts_fts, rank) VALUES('integrity-check', 1)")
    end
  end

  def test_tf461_the_triggers_keep_maintaining_the_index
    dir = stocked_installation('tf461b')
    migrator_for(dir).run

    with_db(dir) do |db|
      workspace = db[:workspaces].first[:id]
      owner     = db[:users].first[:id]

      fresh = insert_prompt(db, workspace, owner, title: 'Nachträglich', body: 'Rumpf')
      assert_equal [fresh], search(db, 'Nachtraeglich'), 'the insert trigger must be back'

      db[:prompts].where(id: fresh).update(title: 'Völlig anders')
      assert_equal [fresh], search(db, 'Voellig'), 'and the update trigger too'
      assert_empty search(db, 'Nachtraeglich'), 'the old term must be gone from the index'

      # A tag rename goes through the third trigger, the one that is not
      # attached to `prompts` and therefore survived the drop — but carried
      # the old normalisation rule inside it.
      tag = db[:tags].insert(workspace_id: workspace, name: 'Entwürfe', created_at: Time.now)
      db[:prompt_tags].insert(prompt_id: fresh, tag_id: tag)
      assert_equal [fresh], search(db, 'Entwuerfe')

      db[:tags].where(id: tag).update(name: 'Łódź')
      assert_includes search(db, 'lodz'), fresh,
                      'the tag triggers must carry the new rule, not the one from 001'

      db.run("INSERT INTO prompts_fts(prompts_fts, rank) VALUES('integrity-check', 1)")
    end
  end

  # --- TF-463b: the four letters -------------------------------------------

  def test_tf463b_letters_with_a_stroke_are_found_without_them
    dir = stocked_installation('tf463b')
    with_db(dir) do |db|
      assert_empty search(db, 'lodz'), 'before the migration this is exactly what fails'
    end

    migrator_for(dir).run

    with_db(dir) do |db|
      polish = db[:prompts].where(title: 'Łódź').first[:id]
      danish = db[:prompts].where(title: 'Rød grød').first[:id]

      assert_equal [polish], search(db, 'lodz'), 'ł must fold to l'
      assert_equal [danish], search(db, 'rod'), 'ø must fold to o'
      assert_equal [polish], search(db, 'Łódź'), 'and the spelling with the letters still works'
    end
  end

  # The counter-proof. Four new rows in a table that also produces the trigger
  # SQL is exactly the change that can quietly break the rules already there.
  def test_tf463b_the_old_rules_are_undamaged
    dir = stocked_installation('tf463c')
    migrator_for(dir).run

    with_db(dir) do |db|
      big = db[:prompts].where(title: 'Größe').first[:id]
      assert_equal [big], search(db, 'grosse'), 'FA-501: Grosse must still find Größe'
      assert_equal [big], search(db, 'groesse'), 'and Groesse as well'

      cafe = db[:prompts].where(title: 'Café').first[:id]
      assert_equal [cafe], search(db, 'cafe'), 'the tokenizer must still fold the accent'
    end
  end

  # --- TF-462: files written before the rename ------------------------------

  # An export is somebody's backup. A-10 (export, import into an empty
  # instance, identical contents) has to keep holding for a file written
  # before AP-18 — otherwise the promise quietly shrinks to files made from
  # today on.
  def test_tf462_a_version_1_file_still_imports_and_arrives_in_english
    dir = stocked_installation('tf462')
    migrator_for(dir).run

    with_db(dir) do |db|
      workspace = db[:workspaces].first[:id]
      owner     = db[:users].first[:id]

      package = PromptAtelier::Transfer.parse(JSON.generate(version_1_file))
      report  = PromptAtelier::Transfer.import(db, workspace_id: workspace,
                                               owner_id: owner, package: package)
      assert_equal ['Aus der alten Fassung'], report['created'],
                   "the import must go through: #{report.inspect}"

      imported = db[:prompts].where(title: 'Aus der alten Fassung').first
      assert_equal 'instance', imported[:visibility], 'instanz must arrive as instance'
      assert_equal 'archived', imported[:status], 'archiviert must arrive as archived'
      assert_equal %w[multiline number select],
                   db[:prompt_variables].where(prompt_id: imported[:id]).select_map(:type).sort
    end
  end

  def test_tf462_the_export_writes_the_current_version
    dir = stocked_installation('tf462b')
    migrator_for(dir).run

    with_db(dir) do |db|
      package = PromptAtelier::Transfer.export(db, workspace_id: db[:workspaces].first[:id])

      assert_equal 2, package['version'], 'a new file must carry the new version'
      assert_includes PromptAtelier::Transfer::READABLE_VERSIONS, 1,
                      'and the old one must stay readable'
      refute_empty package['prompts']
      assert_empty package['prompts'].map { |p| p['status'] } & %w[entwurf aktiv archiviert],
                   'no German value may leave the house in a new file'
    end
  end

  # A version this application has never written stays refused. Without this
  # the reading side would accept anything and fail somewhere deeper, on a
  # field it does not understand.
  def test_tf462_an_unknown_version_is_still_refused
    error = assert_raises(PromptAtelier::Transfer::Refused) do
      PromptAtelier::Transfer.parse(JSON.generate(version_1_file.merge('version' => 99)))
    end
    assert_equal :unsupported_version, error.code
    assert_equal 99, error.detail[:version]
  end

  # --- TF-460g: the guard --------------------------------------------------

  # A mutation probe on the migration itself. With one replacement removed the
  # snapshots come out half translated — the failure FA-702 would hit weeks
  # later. The guard has to turn that into a failed migration here and now,
  # and the run has to roll back whole.
  def test_tf460g_a_missed_snapshot_aborts_the_whole_run
    dir = stocked_installation('tf460g')
    crippled = migrations_without_the_status_replacement

    error = assert_raises(PromptAtelier::Migrator::Error) do
      migrator_for(dir, migrations: crippled).run
    end
    assert_match(/005_english_domain_values/, error.message)

    with_db(dir) do |db|
      assert_equal 'entwurf', db[:prompts].where(title: 'Bericht').get(:status),
                   'a failed migration must leave the database exactly as it was'
      assert_equal %w[001_initial 002_utc_timestamps 003_registration 004_settings],
                   db[:schema_migrations].order(:version).select_map(:version)
    end
  end

  private

  BAIT = 'Antworte als JSON, etwa {"status":"entwurf","visibility":"privat"}.'

  # A file exactly as the application wrote it before AP-18 — spelled out
  # here rather than produced by the exporter, because the exporter now emits
  # the new format and could never make this file again.
  def version_1_file
    {
      'format' => PromptAtelier::Transfer::FORMAT,
      'version' => 1,
      'exported_at' => '2026-08-01T10:00:00+00:00',
      'workspace' => { 'name' => 'Marketing' },
      'keywords' => [],
      'prompts' => [{
        'title' => 'Aus der alten Fassung',
        'description' => 'Vor der Umstellung geschrieben',
        'body' => 'Schreibe über {{ort}} in {{ton}}, {{menge}} Zeilen.',
        'visibility' => 'instanz',
        'status' => 'archiviert',
        'tags' => [],
        'variables' => [
          { 'key' => 'ort', 'label' => 'Ort', 'type' => 'mehrzeilig', 'position' => 0 },
          { 'key' => 'ton', 'label' => 'Ton', 'type' => 'auswahl',
            'options' => %w[sachlich locker], 'position' => 1 },
          { 'key' => 'menge', 'label' => 'Menge', 'type' => 'zahl', 'position' => 2 }
        ]
      }]
    }
  end

  CHILDREN = %i[prompt_variables prompt_revisions prompt_tags favorites memberships].freeze

  def child_counts(db) = CHILDREN.to_h { |table| [table, db[table].count] }

  def insert_prompt_row(db, workspace, owner, **attributes)
    now = Time.now
    db[:prompts].insert({
      workspace_id: workspace, owner_id: owner, title: 'Probe', body: 'Rumpf',
      created_at: now, updated_at: now
    }.merge(attributes))
  end

  # An installation at 004 — the last German state — with rows in every table
  # this migration touches or endangers.
  def stocked_installation(name)
    dir = install_dir(name)
    write_config(dir, valid_config)
    migrator_for(dir, migrations: migrations_up_to_004).run
    with_db(dir) { |db| stock(db) }
    dir
  end

  def stock(db)
    now = Time.now
    workspace = db[:workspaces].insert(name: 'Marketing', slug: 'marketing',
                                       created_at: now, updated_at: now)
    owner = db[:users].insert(email: 'anna@example.test', name: 'Anna', password_hash: 'x',
                              status: 'aktiv', created_at: now, updated_at: now)
    # A locked account, so `users.status` has both values to translate.
    db[:users].insert(email: 'bernd@example.test', name: 'Bernd', password_hash: 'x',
                      status: 'gesperrt', created_at: now, updated_at: now)
    db[:memberships].insert(user_id: owner, workspace_id: workspace, role: 'owner', created_at: now)

    titles = {
      'Bericht'   => %w[privat entwurf],
      'Größe'     => %w[workspace aktiv],
      'Café'      => %w[instanz archiviert],
      'Łódź'      => %w[privat entwurf],
      'Rød grød'  => %w[privat entwurf],
      'JSON-Köder' => %w[privat entwurf]
    }

    prompts = titles.to_h do |title, (visibility, status)|
      id = db[:prompts].insert(
        workspace_id: workspace, owner_id: owner, title: title,
        body: title == 'JSON-Köder' ? BAIT : "Rumpf zu #{title}",
        visibility: visibility, status: status, created_at: now, updated_at: now
      )
      [title, id]
    end

    # All four variable types on one prompt, so none of them is missing from
    # the translation and from the snapshot below.
    %w[text mehrzeilig auswahl zahl].each_with_index do |type, position|
      db[:prompt_variables].insert(prompt_id: prompts['Bericht'], key: "v#{position}",
                                   type: type, position: position)
    end

    tag = db[:tags].insert(workspace_id: workspace, name: 'Blog', created_at: now)
    db[:prompt_tags].insert(prompt_id: prompts['Größe'], tag_id: tag)
    db[:favorites].insert(user_id: owner, prompt_id: prompts['Größe'], created_at: now)

    # Revisions written the way the application writes them, so the snapshot
    # under test is the real format and not one this file invented.
    [prompts['Bericht'], prompts['JSON-Köder']].each do |id|
      PromptAtelier::Prompts.record_revision(db, db[:prompts][id: id], actor_id: owner, now: now)
    end

    age_the_normalisation(db)
  end

  # The normalisation rule as it stood **before** AP-18, written out rather
  # than derived.
  #
  # Without this the stock would not be a database from before the migration
  # at all: `001_initial.rb` builds its triggers from the current
  # Normalization::REPLACEMENTS, so a freshly created installation already
  # carries the four new letters and TF-463b would pass over a state that
  # cannot exist in the field. Reading the historic rule out of the live table
  # would reintroduce exactly that — a fixture that follows the code it is
  # supposed to hold still against.
  HISTORIC_REPLACEMENTS = [
    ['Ä', 'a'], ['Ö', 'o'], ['Ü', 'u'], ['ẞ', 'ss'],
    ['ä', 'a'], ['ö', 'o'], ['ü', 'u'], ['ß', 'ss'],
    ['ae', 'a'], ['oe', 'o'], ['ue', 'u']
  ].freeze

  def historic_sql(column)
    HISTORIC_REPLACEMENTS.reduce("lower(#{column})") do |inner, (from, to)|
      "replace(#{inner}, '#{from}', '#{to}')"
    end
  end

  # Puts the mirror columns and the index back on the old rule, in the order
  # the index demands: empty it with the values it was filled from, rewrite
  # the columns, fill it again.
  def age_the_normalisation(db)
    columns = 'title_norm, description_norm, body_norm, tags_text'
    db.run("INSERT INTO prompts_fts(prompts_fts, rowid, #{columns}) " \
           "SELECT 'delete', id, #{columns} FROM prompts")
    db.run(<<~SQL)
      UPDATE prompts SET
        title_norm       = #{historic_sql('title')},
        description_norm = #{historic_sql("coalesce(description,'')")},
        body_norm        = #{historic_sql('body')},
        tags_text        = (SELECT coalesce(group_concat(#{historic_sql('t.name')}, ' '), '')
                              FROM prompt_tags pt JOIN tags t ON t.id = pt.tag_id
                             WHERE pt.prompt_id = prompts.id)
    SQL
    db.run("INSERT INTO prompts_fts(rowid, #{columns}) SELECT id, #{columns} FROM prompts")
  end

  def migrations_up_to_004 = link_migrations('upto004') { |name| name < '005' }

  # The same directory with one replacement taken out of step 6, for the
  # mutation probe. Written as a copy of the real file rather than a stub, so
  # what is under test is the shipped migration minus one line.
  def migrations_without_the_status_replacement
    dir = link_migrations('crippled') { |name| name < '005' }
    source = File.read(File.join(migrations_dir, '005_english_domain_values.rb'))

    crippled = source.sub("['\"status\":\"entwurf\"',     '\"status\":\"draft\"'],\n", '')
    refute_equal source, crippled, 'the probe must actually remove the replacement'

    # The copy lives elsewhere, so its `require_relative` would look for the
    # services beside itself. Pointed at the real ones instead — everything
    # below that line stays the shipped migration.
    crippled = crippled.gsub(%r{require_relative '\.\./services/(\w+)'}) do
      "require '#{File.join(CODE_ROOT, 'backend', 'services', Regexp.last_match(1))}'"
    end

    File.write(File.join(dir, '005_english_domain_values.rb'), crippled)
    dir
  end

  def link_migrations(label)
    dir = File.join(PromptAtelier::TestSupport.scratch_dir, "migr-#{label}-#{rand(100_000)}")
    FileUtils.mkdir_p(dir)
    @extra_dirs << dir

    Dir.children(migrations_dir).select { |name| name.end_with?('.rb') }.each do |name|
      next unless yield(name)

      FileUtils.ln_s(File.join(migrations_dir, name), File.join(dir, name))
    end
    dir
  end
end
