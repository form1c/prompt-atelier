# frozen_string_literal: true

require_relative '../../test_helper'

# TF-552 — every work package of the plan appears in the plan's own overview.
#
# **Why this exists.** `Umsetzungsplan.md` carries the list of packages twice:
# the table in section 4, and one written-out section per package further down.
# The table is what anybody reads to answer "are we done" — and it was wrong.
# Eight packages had a section and no row: `AP-10a`, `AP-15a` to `AP-15c`, and
# `AP-16a` to `AP-16d`. Six of them were signed off as completed in their own
# heading. Whoever counted the table got 26 packages where there were 34.
#
# It is the same shape as the two checks that already exist here — the register
# of test cases (`test_case_register_test`) and the acceptance criteria
# (`acceptance_protocol_test`) — and it is written for the same reason, stated
# in both of them: the list exists twice, and what keeps it honest is the
# comparison. This one was simply never made, which is how the plan came to
# understate its own scope by eight packages.
class PlanPackagesTest < PromptAtelier::TestCase
  PLAN = PromptAtelier::TestSupport.project_document('Umsetzungsplan.md')

  def setup
    super
    skip PromptAtelier::TestSupport.document_missing('Umsetzungsplan.md') if PLAN.nil?
  end

  # A written-out package: a level-two heading naming it.
  SECTION = /^## (AP-\d+[a-z]?) /
  # A row of the overview table in section 4.
  ROW = /^\| \*\*(AP-\d+[a-z]?)\*\*/

  # Rows that deliberately have no section of their own. Both are coverage
  # reviews whose findings are written into the prose around the table rather
  # than into a package of their own — they produced no new scope, only closed
  # gaps in earlier packages. Named here so that a third one has to be a
  # decision somebody makes, not something that slips in.
  ROWS_WITHOUT_SECTION = %w[AP-05a AP-08a].freeze

  def test_tf552_every_written_out_package_has_a_row_in_the_overview
    missing = (sections - rows).sort

    assert_empty missing,
                 'a package is written out but missing from the table everybody reads'
  end

  def test_tf552_every_row_of_the_overview_names_a_real_package
    unexplained = (rows - sections - ROWS_WITHOUT_SECTION).sort

    assert_empty unexplained,
                 'the table promises a package that is described nowhere'
  end

  # The counter-check for both. Without it they pass just as happily when a
  # pattern stops matching — two empty sets are equal, and an empty sweep is
  # the cheapest green there is.
  def test_tf552_both_lists_were_actually_read
    assert_operator sections.size, :>, 20, 'the sections were not found — the pattern is wrong'
    assert_operator rows.size, :>, 20, 'the table was not found — the pattern is wrong'
    assert_includes sections, 'AP-01'
    assert_includes rows, 'AP-01'
    assert_includes sections, 'AP-16a', 'the sub-packages have to be seen, they are the ones that went missing'
  end

  private

  def sections = PLAN.scan(SECTION).flatten.uniq
  def rows     = PLAN.scan(ROW).flatten.uniq
end
