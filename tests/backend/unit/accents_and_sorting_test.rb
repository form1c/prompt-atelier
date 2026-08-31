# frozen_string_literal: true

require_relative '../../test_helper'

# TF-544 and TF-546 — migration 006 (AP-23).
#
# **Every case starts from a database in the old state.** A test that migrated
# an empty installation would pass while doing nothing: the whole risk of this
# step is in the rows that already exist, in an FTS index that has to be
# emptied and refilled around them, and in a column that has to be computed
# for every one of them.
#
# The awkward part is producing that old state at all. `001_initial` builds its
# triggers from the **current** normalisation table, so a freshly created test
# database already spells `œ` the new way — the same trap AP-18 fell into with
# TF-463b. The historic rule is therefore written out below and the mirror
# columns are put back on it by hand, exactly as a real instance from before
# this step would have them.
class AccentsAndSortingTest < PromptAtelier::TestCase
  def setup
    super
    @extra_dirs = []
  end

  def teardown
    @extra_dirs.each { |dir| FileUtils.rm_rf(dir) }
    super
  end

  # --- TF-544: what the step has to repair ---------------------------------

  def test_tf544_the_sorting_column_arrives_filled_for_every_row
    dir = aged_installation('tf544')
    migrator_for(dir).run

    with_db(dir) do |db|
      rows = db[:prompts].select_map(%i[title title_sort]).to_h

      assert_equal 'abaco',           rows['Ábaco']
      assert_equal 'coeur de metier', rows['Cœur de métier']
      assert_equal 'ano nuevo',       rows['Año nuevo']
      assert_equal 'zebra',           rows['Zebra']
      refute(rows.values.any?(&:empty?), 'not one title may be left without a sort key')
    end
  end

  # The reason the step exists at all: before it, `Cœur` was indexed as `cœur`
  # and `coeur` as `cour`, so whoever typed one spelling never found the other.
  def test_tf544_the_index_finds_afterwards_what_it_could_not_find_before
    dir = aged_installation('tf544b')

    with_db(dir) do |db|
      # Asked the way an instance of that vintage would have asked — with the
      # rule its index was built from. The counter-check is not a formality:
      # "finds nothing" is also what a search that is broken outright returns,
      # and then the assertion below would hold for the wrong reason.
      assert_equal ['Cœur de métier'], historic_search(db, 'cœur'),
                   'the index has to work at all before this proves anything'

      assert_empty historic_search(db, 'coeur'),
                   'and back then the spelling did not find the ligature'

      # Asked with today's rule it finds nothing either way: the code has moved
      # and the database has not. That is what this step is for, and it is why
      # a schema older than the code is refused at startup (NFA-18).
      assert_empty search(db, 'coeur')
      assert_empty search(db, 'cœur')
    end

    migrator_for(dir).run

    with_db(dir) do |db|
      assert_equal ['Cœur de métier'], search(db, 'coeur'),
                   'the spelling has to find the ligature'
      assert_equal ['Cœur de métier'], search(db, 'cœur'),
                   'and the ligature itself still finds it'
    end
  end

  # The counter-direction, and the one that guards a promise rather than a
  # feature: FA-501 is about German, and none of this may weaken it.
  def test_tf544_the_german_search_promise_survives_the_step
    dir = aged_installation('tf544c')
    migrator_for(dir).run

    with_db(dir) do |db|
      %w[grosse groesse größe].each do |term|
        assert_equal ['Größe'], search(db, term), "#{term} has to find the umlaut prompt"
      end
    end
  end

  # A trigger that was not replaced would leave the next write on the old rule
  # — and nothing would say so until somebody searched months later.
  def test_tf544_a_row_written_afterwards_follows_the_new_rule
    dir = aged_installation('tf544d')
    migrator_for(dir).run

    with_db(dir) do |db|
      insert_prompt(db, 'Sœur et frère')

      assert_equal ['Sœur et frère'], search(db, 'soeur')
      assert_equal 'soeur et frere', db[:prompts].first(title: 'Sœur et frère')[:title_sort]
    end
  end

  # --- TF-546: the order of a list -----------------------------------------

  # By bytes the same six titles come back as
  #
  #   ["Anfang", "Zebra", "apple", "Ábaco", "Éclair", "Œuvre"]
  #
  # — capitals, then lower case, then everything accented. Wrong for German
  # already; with three accent-rich languages it stops being an order at all.
  def test_tf546_the_list_sorts_alphabetically_and_not_by_bytes
    dir = aged_installation('tf546')
    migrator_for(dir).run

    with_db(dir) do |db|
      order = db[:prompts].order(:title_sort).select_map(:title)

      assert_equal ['Ábaco', 'Anfang', 'Año nuevo', 'apple', 'Cœur de métier',
                    'Éclair', 'Größe', 'Œuvre', 'Zebra'],
                   order
    end
  end

  # And the index the order is meant to use really exists — without it the
  # case above would still pass and every listing would sort by scanning.
  def test_tf546_the_order_has_an_index_to_read
    dir = aged_installation('tf546b')
    migrator_for(dir).run

    with_db(dir) do |db|
      plan = db.fetch('EXPLAIN QUERY PLAN SELECT id FROM prompts ' \
                      'WHERE workspace_id = 1 ORDER BY title_sort').all.map { |row| row[:detail] }.join(' ')

      assert_includes plan, 'index_prompts_workspace_title_sort'
      refute_includes plan, 'TEMP B-TREE', 'the order must come from the index, not from a sort'
    end
  end

  # --- the guard ------------------------------------------------------------

  # The mutation probe as a case of its own: a step that half worked has to
  # abort. Without the guard, a forgotten `title_sort` would leave a database
  # that looks migrated and sorts by nothing.
  def test_a_half_done_step_aborts_instead_of_finishing
    dir = aged_installation('guard')

    error = assert_raises(StandardError) do
      migrator_for(dir, migrations: migrations_without_the_sort_key).run
    end

    assert_match(/CHECK|constraint/i, error.message)
  end

  private

  # The rule as it stood before AP-23: no ligatures. Written out rather than
  # read from the live table — reading it there would give a fixture that
  # follows the code it is supposed to hold still against.
  HISTORIC_REPLACEMENTS = [
    ['Ä', 'a'], ['Ö', 'o'], ['Ü', 'u'], ['ẞ', 'ss'],
    ['ä', 'a'], ['ö', 'o'], ['ü', 'u'], ['ß', 'ss'],
    ['Ø', 'o'], ['Ł', 'l'], ['Đ', 'd'], ['Æ', 'a'],
    ['ø', 'o'], ['ł', 'l'], ['đ', 'd'], ['æ', 'a'],
    ['ae', 'a'], ['oe', 'o'], ['ue', 'u']
  ].freeze

  TITLES = ['Zebra', 'Ábaco', 'Œuvre', 'Anfang', 'Éclair', 'apple',
            'Cœur de métier', 'Año nuevo', 'Größe'].freeze

  def historic_sql(column)
    HISTORIC_REPLACEMENTS.reduce("lower(#{column})") do |inner, (from, to)|
      "replace(#{inner}, '#{from}', '#{to}')"
    end
  end

  # An installation as it stood before this step: everything up to 005, filled,
  # and with the mirror columns put back on the old rule.
  def aged_installation(name)
    dir = install_dir(name)
    write_config(dir, valid_config)
    migrator_for(dir, migrations: migrations_up_to_005).run
    with_db(dir) do |db|
      stock(db)
      age_the_normalisation(db)
    end
    dir
  end

  def stock(db)
    now = Time.now
    db[:workspaces].insert(id: 1, name: 'Marketing', slug: 'marketing',
                           created_at: now, updated_at: now)
    db[:users].insert(id: 1, email: 'anna@example.test', name: 'Anna', password_hash: 'x',
                      status: 'active', locale: '', created_at: now, updated_at: now)

    TITLES.each { |title| insert_prompt(db, title) }
  end

  def insert_prompt(db, title)
    now = Time.now
    db[:prompts].insert(workspace_id: 1, owner_id: 1, title: title,
                        body: "Ein Text zu #{title}.", visibility: 'private',
                        status: 'active', created_at: now, updated_at: now)
  end

  # Puts the mirror columns and the index back on the old rule, in the order
  # the index demands: empty it with the values it was filled from, rewrite the
  # columns, fill it again.
  def age_the_normalisation(db)
    columns = 'title_norm, description_norm, body_norm, tags_text'
    db.run("INSERT INTO prompts_fts(prompts_fts, rowid, #{columns}) " \
           "SELECT 'delete', id, #{columns} FROM prompts")
    db.run(<<~SQL)
      UPDATE prompts SET
        title_norm       = #{historic_sql('title')},
        description_norm = #{historic_sql("coalesce(description,'')")},
        body_norm        = #{historic_sql('body')}
    SQL
    db.run("INSERT INTO prompts_fts(rowid, #{columns}) SELECT id, #{columns} FROM prompts")
  end

  # The same question asked with the rule of the old instance, so "before" and
  # "after" are compared on their own terms rather than through today's.
  def historic_search(db, term)
    folded = HISTORIC_REPLACEMENTS.reduce(term.downcase) { |result, (from, to)| result.gsub(from, to) }
    matching(db, folded)
  end

  def search(db, term)
    matching(db, PromptAtelier::Normalization.normalize(term))
  end

  def matching(db, normalised)
    db.fetch(<<~SQL, "#{normalised}*").all.map { |row| row[:title] }
      SELECT p.title FROM prompts_fts f JOIN prompts p ON p.id = f.rowid
       WHERE prompts_fts MATCH ? ORDER BY p.title
    SQL
  end

  def migrations_up_to_005 = link_migrations('upto005') { |name| name < '006' }

  # The shipped step minus the one assignment that fills the sort key, so the
  # guard has something to catch. A copy of the real file rather than a stub:
  # what runs is the delivered migration minus one line.
  def migrations_without_the_sort_key
    dir = link_migrations('crippled') { |name| name < '006' }
    source = File.read(File.join(migrations_dir, '006_accents_and_sorting.rb'))

    crippled = source.sub("      title_sort       = \#{fold.call('title')},\n", '')
    refute_equal source, crippled, 'the probe must actually remove the assignment'

    crippled = crippled.gsub("require_relative '../services/", "require_relative '#{backend_dir}/services/")
    File.write(File.join(dir, '006_accents_and_sorting.rb'), crippled)
    dir
  end

  def backend_dir = File.expand_path('../../../backend', __dir__)

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
