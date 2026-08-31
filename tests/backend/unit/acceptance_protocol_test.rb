# frozen_string_literal: true

require_relative '../../test_helper'

# The acceptance protocol against the criteria it is meant to sign off.
#
# **Why a test over a document.** Chapter 21 of the requirements grows — A-02b
# and A-30 to A-32 were added during the work. A protocol that does not carry a
# criterion signs it off by silence: no line is missing, only an assurance, and
# nobody misses an assurance. The other way round, a row for a criterion that
# no longer exists is a signature under nothing.
#
# The same thought as in `manifest_test`: the list exists twice, and what keeps
# it honest is the comparison.
class AcceptanceProtocolTest < PromptAtelier::TestCase
  REQUIREMENTS = PromptAtelier::TestSupport.project_document('Requirements.md')
  PROTOCOL     = PromptAtelier::TestSupport.project_document('Abnahmeprotokoll.md')

  def setup
    super
    skip PromptAtelier::TestSupport.document_missing('Requirements.md') if REQUIREMENTS.nil?
    skip PromptAtelier::TestSupport.document_missing('Abnahmeprotokoll.md') if PROTOCOL.nil?
  end

  # Only the table rows of chapter 21, not every mention in prose.
  def criteria_in_requirements
    REQUIREMENTS.scan(/^\| (A-\d+[a-z]?) \|/).flatten.uniq.sort
  end

  def criteria_in_protocol
    PROTOCOL.scan(/^\| (A-\d+[a-z]?) \|/).flatten.uniq.sort
  end

  def test_the_protocol_lists_every_criterion_the_requirements_name
    expected = criteria_in_requirements

    refute_empty expected, 'no criteria found at all, so this case says nothing'
    assert_equal expected, criteria_in_protocol,
                 'a criterion with no row in the protocol is signed off by silence'
  end

  # 32 plus A-02b. The number is written down so that a thirty-fourth is a
  # decision somebody makes rather than something that happens in passing.
  def test_there_are_thirty_three_criteria
    assert_equal 33, criteria_in_requirements.length
  end

  # Every row has to say **what** established the criterion. A row without one
  # is a tick with no reason behind it — the very thing this protocol exists to
  # prevent.
  def test_every_row_names_a_way_the_criterion_was_established
    rows = PROTOCOL.lines.select { |line| line.match?(/^\| A-\d+[a-z]? \|/) }

    without = rows.reject { |row| row.match?(/TF-\d+|NT-\d+|Beobachtung|Zeilen dieser Tabelle/) }

    assert_empty without.map { |row| row[/A-\d+[a-z]?/] },
                 'these rows claim a result without naming what produced it'
  end

  # And every row has to carry a result. "bestanden" and "offen" are the two
  # permitted ones; anything else is a row somebody will later read as passed.
  def test_every_row_carries_a_result
    rows = PROTOCOL.lines.select { |line| line.match?(/^\| A-\d+[a-z]? \|/) }

    unresolved = rows.reject { |row| row.match?(/bestanden|offen/) }

    assert_empty unresolved.map { |row| row[/A-\d+[a-z]?/] }
  end

  # The two observations of people cannot be established by whoever built the
  # thing, and this case says so whatever their current state is.
  #
  # It used to assert that both were **open**, which held until the day they
  # were not: the client ran NT-6 and the case turned red over a success. A
  # test that encodes today's status has to be edited every time the status
  # changes, and a test that is edited to make it pass has stopped testing.
  # What is durable is the **source**: these two may only ever be marked by an
  # observation, never by the suite.
  def test_the_two_observations_may_only_be_established_by_watching_people
    %w[A-02 A-02b].each do |id|
      row = PROTOCOL.lines.find { |line| line.start_with?("| #{id} |") }

      refute_nil row, "#{id} is missing from the protocol"
      assert_includes row, 'NT-6', "#{id} is an observation of people"
      refute_match(/bestanden \d{4}-\d{2}-\d{2}\s*\|/, row,
                   "#{id} carries a bare date, which is how the suite marks the criteria it " \
                   'can establish itself — this one needs a person and has to name them')
    end
  end
end
