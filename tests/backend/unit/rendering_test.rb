# frozen_string_literal: true

require_relative '../../test_helper'
require 'services/rendering'

# TF-101 to TF-134 — the rendering pipeline (Requirements chapter 8).
#
# The cases are not written out here. They live in tests/vectors/rendering.json
# and are read from that file, because the Vitest suite in AP-11 reads the very
# same file. Two copies of the expected values would drift apart, and the whole
# point of these vectors is that both implementations answer to one source.
#
# A failure in this suite means one of three things (test concept 5.6):
#   both sides wrong the same way  -> specification misread, fix both
#   only Ruby wrong                -> fix here
#   the two sides differ           -> risk R-01, delivery blocked
class RenderingTest < PromptAtelier::TestCase
  R = PromptAtelier::Rendering

  VECTOR_FILE = File.join(CODE_ROOT, 'tests', 'vectors', 'rendering.json')
  DATA        = JSON.parse(File.read(VECTOR_FILE, encoding: 'UTF-8')).freeze
  VECTORS     = DATA['vectors'].freeze

  # --- the vectors themselves ---------------------------------------------

  # One test method per vector, generated at load time. Generated rather than
  # looped inside a single test so that a failure names the vector — "TF-119
  # failed" is a place to look, "the vector test failed" is not.
  VECTORS.each do |vector|
    id   = vector['id']
    name = id.downcase.tr('-', '_')

    define_method("test_#{name}_#{vector['title'].downcase.gsub(/[^a-z0-9]+/, '_')}") do
      result = render_vector(vector)

      assert_equal vector['expected'], result.text,
                   "#{id} (#{vector['title']}) does not match character for character"

      if vector.key?('unknown_keys')
        assert_equal vector['unknown_keys'], result.unknown_keys,
                     "#{id}: unexpected set of unknown keys"
      end

      if vector.key?('missing_required')
        assert_equal vector['missing_required'], result.missing_required,
                     "#{id}: unexpected set of unbound required variables"
      end
    end
  end

  # --- the vector file as such ---------------------------------------------

  # A-12 promises 34 vectors. If one is dropped the suite above would simply
  # run one test fewer and stay green — silently.
  def test_the_file_holds_exactly_the_34_documented_vectors
    ids = VECTORS.map { |vector| vector['id'] }

    assert_equal 34, ids.size
    assert_equal (101..134).map { |number| "TF-#{number}" }, ids,
                 'TF-101 to TF-134, in order and without gaps'
    assert_equal ids.uniq, ids, 'no duplicates'
  end

  def test_every_vector_carries_a_body_and_an_expectation
    VECTORS.each do |vector|
      refute_nil vector['body'],     "#{vector['id']}: body missing"
      refute_nil vector['expected'], "#{vector['id']}: expected missing"
      refute_empty vector['title'].to_s, "#{vector['id']}: title missing"
    end
  end

  def test_every_named_keyword_is_defined
    VECTORS.each do |vector|
      known = DATA['keywords'].merge(vector['extra_keywords'] || {})
      (vector['keywords'] || []).each do |name|
        refute_nil known[name], "#{vector['id']}: keyword #{name.inspect} is not defined"
      end
    end
  end

  # The fixture set from test concept 4.4, unchanged. If someone edits a
  # keyword text here, several expectations further down become wrong in a way
  # that is hard to trace back.
  def test_the_shared_keywords_match_the_test_concept
    expected = {
      'rolle'   => ['prepend', 10, 'Du bist ein erfahrener Fachautor.'],
      'formal'  => ['append',  10, 'Schreibe in einem sachlichen, förmlichen Ton.'],
      'kurz'    => ['append',  20, 'Fasse dich kurz, höchstens 150 Wörter.'],
      'anhang'  => ['append',  20, 'Nenne am Ende zwei Quellen.'],
      'kontext' => ['prepend', 20, 'Der Text erscheint in einem Fachblog.']
    }

    assert_equal expected.keys.sort, DATA['keywords'].keys.sort
    expected.each do |name, (position, order, text)|
      keyword = DATA['keywords'][name]
      assert_equal position, keyword['position'], name
      assert_equal order,    keyword['sort_order'], name
      assert_equal text,     keyword['text'], name
    end
  end

  # --- properties the vectors do not cover ---------------------------------

  # NFA-14: the pipeline must be usable without the web layer or the database.
  # It is loaded here on its own, so this passes only as long as it stays that
  # way.
  def test_the_pipeline_needs_neither_sinatra_nor_a_database
    source = File.read(File.join(CODE_ROOT, 'backend', 'services', 'rendering.rb'))

    refute_match(/require.*sinatra/, source)
    refute_match(/require.*sequel/i, source)
    refute_match(/require_relative/, source, 'no dependency on other services either')
  end

  def test_rendering_the_same_input_twice_gives_the_same_result
    VECTORS.each do |vector|
      first  = render_vector(vector).text
      second = render_vector(vector).text
      assert_equal first, second, "#{vector['id']} is not deterministic"
    end
  end

  # --- key recognition (8.2), beyond the vectors ---------------------------

  # TF-404 as an edge case: a key with a space is not a variable at all — it
  # produces no warning either, because nothing was recognised.
  def test_tf404_a_key_with_a_space_is_not_a_variable_and_warns_about_nothing
    result = R.render(body: 'Nutze {{Mein Thema}} hier.')

    assert_equal 'Nutze {{Mein Thema}} hier.', result.text
    assert_empty result.unknown_keys
  end

  # 8.2 asks for the lower-casing on **both** sides of the comparison: in the
  # text and in the record. The text is covered by the vectors, the record was
  # covered on neither side — both versions lower-case, neither was ever held
  # to it. Whoever strikes one of the two lines notices it nowhere; that is the
  # construction R-01 warns about, only doubled.
  def test_the_key_of_the_record_is_compared_without_regard_to_case
    result = R.render(body: '{{thema}}', variables: [{ key: 'THEMA', value: 'Kaffee' }])

    assert_equal 'Kaffee', result.text
    assert_empty result.unknown_keys
  end

  def test_keys_are_bounded_to_forty_characters
    fits    = 'a' * 40
    too_big = 'a' * 41

    assert_equal 'X', R.render(body: "{{#{fits}}}",
                               variables: [{ key: fits, value: 'X' }]).text
    # Not a variable, so it stays put and raises no warning.
    result = R.render(body: "{{#{too_big}}}", variables: [{ key: too_big, value: 'X' }])
    assert_equal "{{#{too_big}}}", result.text
    assert_empty result.unknown_keys
  end

  def test_a_hyphen_or_a_dot_does_not_belong_in_a_key
    ['{{mein-thema}}', '{{mein.thema}}', '{{ }}', '{{}}'].each do |text|
      assert_equal text, R.render(body: text).text, "#{text} must stay as it is"
    end
  end

  def test_underscores_and_digits_are_allowed_after_the_first_letter
    result = R.render(body: '{{thema_2}}', variables: [{ key: 'thema_2', value: 'Kaffee' }])

    assert_equal 'Kaffee', result.text
  end

  # The same unknown key twice is one warning, not two — and in the order of
  # first occurrence. Neither implementation pinned this until a mutation
  # probe on the JavaScript side removed the check and every vector stayed
  # green.
  def test_an_unknown_key_is_reported_once_in_order_of_first_occurrence
    result = R.render(body: '{{b}} {{a}} {{b}} {{a}}')

    assert_equal %w[b a], result.unknown_keys
  end

  # --- values --------------------------------------------------------------

  def test_a_missing_binding_falls_back_to_the_default_then_to_empty_text
    with_default = R.render(body: '{{a}}.', variables: [{ key: 'a', default_value: 'D' }])
    without      = R.render(body: '{{a}}.', variables: [{ key: 'a' }])

    assert_equal 'D.', with_default.text
    assert_equal '.',  without.text
  end

  # A value of "0" or "false" is a value. Falling back to the default there
  # would be a classic truthiness bug.
  def test_the_string_zero_counts_as_a_binding
    result = R.render(body: '{{a}}', variables: [{ key: 'a', value: '0', default_value: 'D' }])

    assert_equal '0', result.text
  end

  # --- required variables (8.3) --------------------------------------------

  def test_a_required_variable_with_a_default_is_not_reported_as_missing
    result = R.render(body: '{{a}}',
                      variables: [{ key: 'a', required: true, default_value: 'D' }])

    assert_equal 'D', result.text
    assert_empty result.missing_required
    assert result.complete?
  end

  def test_the_preview_is_produced_even_when_a_required_value_is_missing
    result = R.render(body: 'Schreibe über {{thema}}.',
                      variables: [{ key: 'thema', required: true }])

    assert_equal 'Schreibe über .', result.text, '8.3: the preview is still rendered'
    assert_equal ['thema'], result.missing_required
    refute result.complete?, 'copying is what gets blocked, not the rendering'
  end

  # --- keywords ------------------------------------------------------------

  def test_an_empty_keyword_text_adds_no_separator
    result = R.render(body: 'Text.',
                      keywords: [{ name: 'leer', text: '', position: 'append', sort_order: 10 }])

    assert_equal 'Text.', result.text
  end

  def test_keyword_order_does_not_depend_on_the_order_they_arrive_in
    keywords = [
      { name: 'b', text: 'Zweitens.', position: 'append', sort_order: 20 },
      { name: 'a', text: 'Erstens.',  position: 'append', sort_order: 10 }
    ]

    forwards  = R.render(body: 'Text.', keywords: keywords).text
    backwards = R.render(body: 'Text.', keywords: keywords.reverse).text

    assert_equal "Text.\n\nErstens.\n\nZweitens.", forwards
    assert_equal forwards, backwards
  end

  private

  def render_vector(vector)
    keywords = (vector['keywords'] || []).map do |name|
      definition = (vector['extra_keywords'] || {}).fetch(name) { DATA['keywords'].fetch(name) }
      definition.merge('name' => name)
    end

    PromptAtelier::Rendering.render(
      body: vector['body'],
      variables: vector['variables'] || [],
      keywords: keywords
    )
  end
end
