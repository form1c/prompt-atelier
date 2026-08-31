# frozen_string_literal: true

require_relative '../../test_helper'
require 'services/rendering'

# TF-540 and TF-541 — what counts as a placeholder (AP-23, Requirements 8.2).
#
# **The rule exists twice**, here and in `frontend/src/util/rendering.js`, and
# it has to. The server substitutes when it renders and when it derives the
# variable set of a prompt; the browser does the same for the live preview and
# for the fields that appear while somebody types. Two notions of "what is a
# variable" would let a prompt carry metadata for something that never renders,
# or render something that has no metadata — and neither would raise anything.
#
# So both sides answer **one** table, `tests/fixtures/placeholder_cases.json`.
# Comparing the two patterns as text would not work: Ruby spells the rule
# `[[:alpha:]]` and JavaScript spells it `\p{L}`, and a comparison that had to
# tolerate that would end up comparing nothing.
class PlaceholderRuleTest < PromptAtelier::TestCase
  R = PromptAtelier::Rendering

  CASES = JSON.parse(
    File.read(File.expand_path('../../fixtures/placeholder_cases.json', __dir__), encoding: 'UTF-8')
  )['cases'].freeze

  def test_the_table_has_both_answers_in_it
    # Without this the case below would pass over an empty file, and the
    # comparison with the browser would be two sides agreeing about nothing.
    assert_operator CASES.size, :>, 10
    assert CASES.any? { |entry| entry['valid'] }
    assert CASES.any? { |entry| !entry['valid'] }
  end

  def test_tf541_accepts_exactly_what_requirements_8_2_accepts
    CASES.each do |entry|
      key = entry['key']
      result = R.render(body: "{{#{key}}}", variables: [{ key: key, value: 'X' }])

      assert_equal entry['valid'], result.text == 'X', "{{#{key}}}: #{entry['why']}"
    end
  end

  def test_whitespace_inside_the_braces_is_allowed
    assert_equal 'X', R.render(body: '{{ name }}', variables: [{ key: 'name', value: 'X' }]).text
  end

  # The keys a prompt derives its variables from have to be the same ones the
  # renderer substitutes — that is the other half of "one notion", and it lives
  # inside this file rather than between the two languages.
  def test_the_variable_set_is_derived_with_the_same_rule
    body = '{{año}} {{2fa}} {{prénom}}'

    assert_equal %w[año prénom], R.variable_keys(body)
  end

  # --- TF-540: what used to be silent ---------------------------------------

  # A placeholder the rule refuses is **reported**. Before AP-23 it was not
  # substituted, not reported as unknown and given no field to fill in — the
  # text simply kept it, and whoever wrote the prompt found out when they
  # pasted it into a model.
  def test_tf540_a_refused_placeholder_is_reported
    result = R.render(body: 'Hallo {{name}}, {{2fa}} und {{mi variable}}',
                      variables: [{ key: 'name', value: 'Martin' }])

    assert_equal ['2fa', 'mi variable'], result.rejected_keys
    assert_includes result.text, '{{2fa}}', 'and it stays in the text as it was written'
  end

  # Widening the key to Unicode letters does not remove the boundary, it moves
  # it — which is why the report is needed whatever the rule says.
  def test_tf540_a_name_in_another_language_is_a_variable_and_not_a_complaint
    result = R.render(body: 'Hola {{año}}, ciao {{città}}',
                      variables: [{ key: 'año', value: '2026' }, { key: 'città', value: 'Roma' }])

    assert_equal 'Hola 2026, ciao Roma', result.text
    assert_empty result.rejected_keys
    assert_empty result.unknown_keys
  end

  def test_tf540_an_escaped_placeholder_is_a_deliberate_literal
    result = R.render(body: 'Literal \\{{2fa}} bleibt')

    assert_empty result.rejected_keys
    assert_equal 'Literal {{2fa}} bleibt', result.text
  end

  # A stray `{{` must not pair with a `}}` far away and report the paragraph
  # between them as one enormous key.
  def test_tf540_braces_do_not_pair_across_lines
    assert_empty R.render(body: "offen {{ hier\nund dort }} zu").rejected_keys
  end
end
