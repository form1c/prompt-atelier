# frozen_string_literal: true

require_relative '../../test_helper'

# Every case number a test carries has to be a case the test concept knows.
#
# **Why this exists, and why it exists late.** `Testkonzept.md` is the register:
# it says what each numbered case is for, which requirement it serves, and what
# it must not be softened into. The suite refers to those numbers in comments
# and in method names, and until now **nothing compared the two**.
#
# What that cost, measured when the packages were reviewed: thirteen numbers
# were in use that the register did not know — `TF-460f` and `TF-460g` since
# AP-18, `TF-536` to `TF-538` and `TF-540` to `TF-546` since AP-22 and AP-23.
# Each of them named a case in the code, and each of them was invisible to the
# completeness rule the plan states about itself.
#
# The project already has exactly this check for the acceptance criteria
# (`acceptance_protocol_test`), and the reasoning is the same one written there:
# the list exists twice, and what keeps it honest is the comparison.
#
# **Only this direction is checked, and that is deliberate.** The other one —
# every case of the register appears in the code — would report about 180
# numbers, because a test does not have to write its number down to be the
# test. Turning that into a rule would mean labelling everything to satisfy a
# check rather than to help a reader, and a check nobody can satisfy is a check
# that gets switched off.
class TestCaseRegisterTest < PromptAtelier::TestCase
  CONCEPT = PromptAtelier::TestSupport.project_document('Testkonzept.md')

  def setup
    super
    skip PromptAtelier::TestSupport.document_missing('Testkonzept.md') if CONCEPT.nil?
  end

  # `(?<![A-Za-z])` is not decoration: without it, the last five characters of
  # `UTF-16` — which a comment about code units in `rendering.test.js` really
  # contains — read as a case number, and the check would demand a register
  # entry for a case nobody meant.
  #
  # Written without the offending string spelled out, because this file is one
  # of the files the sweep reads. An example inside a check is part of what the
  # check measures; the first version of this comment tripped it.
  NUMBER = /(?<![A-Za-z])TF-\d+[a-z]?/

  def test_every_case_number_in_the_suite_is_one_the_register_knows
    known = CONCEPT.scan(NUMBER).uniq
    refute_empty known, 'the register was not read at all, so this proves nothing'

    used = Dir.glob(File.join(CODE_ROOT, 'tests', '**', '*.{rb,js}'))
              .reject { |path| path.include?('node_modules') }
              .flat_map { |path| File.read(path, encoding: 'UTF-8').scan(NUMBER) }
              .uniq

    refute_empty used, 'no case numbers found in the suite either'

    assert_empty (used - known).sort,
                 'a number in the suite that the test concept does not define'
  end
end
