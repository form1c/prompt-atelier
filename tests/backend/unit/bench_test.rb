# frozen_string_literal: true

require_relative '../../test_helper'
require 'services/password'
require 'services/accounts'
require 'services/workspaces'
require 'services/prompts'
require 'services/search'
require 'bench'

# The stock the measurements of section 11 are taken on (TF-701 to TF-707).
#
# **Why a corpus needs its own tests.** A measurement is a statement about a
# library, and it is worth exactly as much as the library is like a real one.
# Nothing about that is visible in the timings: a query that finds nothing is
# the fastest query there is, and a corpus in which every rare word sits behind
# a permission the measuring account does not have produces a table of small
# numbers and a green report.
#
# That is not hypothetical. The first version of `bench` derived the workspace
# from `index % 2` and the visibility from `index % 4` — which reads like two
# independent decisions and is one, because every index divisible by four is
# even. The consequences, all of them measured rather than reasoned:
#
#   * Marketing held no instance-wide prompt at all
#   * every prompt carrying the common term was private
#   * the case called "search, one hit" found zero, and reported 1.4 ms
#
# The cases below are the ones that would have caught it.
class BenchTest < PromptAtelier::TestCase
  B = PromptAtelier::Bench

  # Small, because these are properties of the construction and not of the
  # size. 400 is enough for every frequency the corpus claims to have.
  SIZE = 400

  def setup
    super
    @dir = migrated_dir('bench')
  end

  # --- the corpus is what it says it is --------------------------------------

  def test_it_writes_the_number_of_prompts_it_was_asked_for
    with_stock do |db, _facts|
      assert_equal SIZE, db[:prompts].count
    end
  end

  # The regression named in the header. Both workspaces have to carry all three
  # visibilities; a corpus in which one workspace never holds an instance-wide
  # prompt cannot exercise FA-509 no matter how long it is measured.
  def test_every_workspace_carries_every_visibility
    with_stock do |db, facts|
      facts[:workspace_ids].each do |workspace_id|
        found = db[:prompts].where(workspace_id: workspace_id).distinct.select_map(:visibility).sort

        assert_equal %w[instance private workspace], found,
                     "workspace #{workspace_id} does not hold all three visibilities"
      end
    end
  end

  # The other half of the same finding: the common term must not have become a
  # synonym for one visibility. Correlated properties make a corpus that looks
  # varied in the source and is not varied in the database.
  def test_the_common_term_is_not_tied_to_one_visibility
    with_stock do |db, facts|
      carriers = db[:prompts].where(Sequel.like(:title, "#{facts[:common_term]}%"))

      refute_operator carriers.count, :<, 20, 'too few carriers to say anything'
      assert_operator carriers.distinct.select_map(:visibility).length, :>=, 2,
                      'every prompt with the common term has the same visibility'
    end
  end

  # --- the needles ------------------------------------------------------------

  # Exactly one hit, and — the part the first version got wrong — a hit the
  # measuring account is allowed to see. Asked through `Search`, with the
  # permission filter in place, because that is the query the measurement runs.
  def test_each_rare_term_is_found_exactly_once_by_the_measuring_account
    with_stock do |db, facts|
      reader = db[:users].first(email: facts[:email])

      facts[:rare_terms].each do |term|
        found = PromptAtelier::Search.count(db, term: term, workspace_ids: facts[:workspace_ids],
                                                visible_for: reader[:id])

        assert_equal 1, found, "#{term} is not a needle for the account that searches for it"
      end
    end
  end

  # FA-501: the search normalises umlauts, so the written-out form has to find
  # the prompts carrying the umlaut. A corpus without them would leave the
  # cheap path as the only one ever measured.
  def test_the_written_out_umlaut_finds_the_prompts_that_carry_it
    with_stock do |db, facts|
      reader = db[:users].first(email: facts[:email])
      found = PromptAtelier::Search.count(db, term: facts[:umlaut_term],
                                              workspace_ids: facts[:workspace_ids],
                                              visible_for: reader[:id])

      assert_operator found, :>, 1, "#{facts[:umlaut_term]} finds nothing, so the case measures nothing"
    end
  end

  # --- the permission filter has something to do -----------------------------

  # If the measuring account could read everything, the measured query would be
  # missing its `WHERE` clause — the cheapest version of the query, and not the
  # one any installation runs.
  def test_the_measuring_account_may_not_read_a_quarter_of_the_stock
    with_stock do |db, facts|
      reader = db[:users].first(email: facts[:email])
      readable = PromptAtelier::Search.count(db, workspace_ids: facts[:workspace_ids],
                                                 visible_for: reader[:id])

      assert_operator readable, :<, SIZE, 'the reader sees everything, so nothing is being filtered'
      assert_operator readable, :>, SIZE / 2, 'the reader sees almost nothing, so the library is empty'
    end
  end

  # --- the same corpus twice --------------------------------------------------

  # Two runs on the same machine have to be comparable, or a regression cannot
  # be told apart from a different draw. Checked on the titles, which is where
  # every one of the random draws ends up.
  def test_the_same_count_yields_the_same_library
    first = with_stock(migrated_dir('bench-a')) { |db, _| db[:prompts].order(:id).select_map(:title) }
    second = with_stock(migrated_dir('bench-b')) { |db, _| db[:prompts].order(:id).select_map(:title) }

    assert_equal first, second
  end

  # --- what the measurement is told -------------------------------------------

  # The facts are the whole interface between the stock and the tool measuring
  # it. A missing key does not fail here, it fails halfway through a run that
  # has already spent minutes seeding.
  def test_the_facts_name_everything_the_measurement_needs
    with_stock do |_db, facts|
      %i[email password workspace_id workspace_ids prompts rare_terms
         common_term umlaut_term].each do |key|
        refute_nil facts[key], "the measurement asks for #{key}"
      end
    end
  end

  def test_the_measuring_account_can_actually_sign_in
    with_stock do |db, facts|
      reader = db[:users].first(email: facts[:email])

      assert PromptAtelier::Password.verify(facts[:password], reader[:password_hash]),
             'the password in the facts does not open the account they name'
    end
  end

  private

  # One stock per case. Slower than sharing one, and deliberately so: several
  # of these cases count rows, and a corpus another case had added to would
  # make the counts describe something nobody built.
  def with_stock(dir = @dir)
    facts = nil
    with_db(dir) do |db|
      facts = B.build(db, prompts: SIZE)
      return yield(db, facts)
    end
  end
end
