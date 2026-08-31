# frozen_string_literal: true

require_relative '../../test_helper'

# TF-534 — every code the server can send has a sentence, in every language
# that is delivered (AP-19, 11.7, 15.2).
#
# Since AP-19 the server answers with a **code** and the interface writes the
# sentence. That divides one statement across two files, and the failure mode
# is silent in the worst way: the code arrives, the lookup finds nothing, and
# the person is shown the fallback — "an unexpected error occurred" — for a
# situation the application understood perfectly well.
#
# **The codes are read out of the server's own source**, not from a list kept
# here. A list would be an copy, and a copy is the thing that goes stale: a new
# refusal would be added on one side, the copy would stay as it was, and this
# case would keep passing while the new code had no sentence anywhere.
#
# It also guards the direction that caught a real mistake. Codes are flattened
# out of what used to be namespaces (`transfer.malformed_json`,
# `error.malformed_json` …), so **two situations can collide on one word**. The
# first version of AP-19 let exactly that through: a damaged import file was
# reported with the sentence about a damaged request body, telling the reader
# to check something they never sent.
class AnswerCodesTest < PromptAtelier::TestCase
  APP = File.read(File.join(CODE_ROOT, 'backend', 'app.rb'), encoding: 'UTF-8')

  ALL_SERVICES = Dir.glob(File.join(CODE_ROOT, 'backend', 'services', '*.rb'))
                    .to_h { |path| [File.basename(path, '.rb'), File.read(path, encoding: 'UTF-8')] }

  # Only the services the **application** actually reaches. A service the
  # routes never mention is a console service — `Relocation` is one, used by
  # `export_all` and `import_all` and by nothing else — and its refusals are
  # printed by a script, in the language of the console (E-12). Demanding a
  # browser sentence for them would be demanding a translation nobody reads.
  #
  # Derived rather than listed: a list would need maintaining, and the day a
  # console service grew a route the list would still say it had none.
  SERVICES = ALL_SERVICES.select do |name, _source|
    APP.include?(name.split('_').map(&:capitalize).join)
  end

  # Where a code can come from, in the source itself:
  #
  #   halt_with(404, 'not_found')          a refusal decided in the route
  #   error_body('x', …) / code: 'x'       written into an answer by hand
  #   raise Refused, :name_taken           a service refusal, surfaced by its
  #   raise Refused.new(:x, …)             handler as `e.code.to_s`
  FROM_APP = [
    /halt_with\(\s*\d+,\s*'([a-z_]+)'/,
    /code:\s*'([a-z_]+)'/
  ].freeze

  FROM_SERVICES = [
    /raise\s+\w*Refused,\s*:([a-z_]+)/,
    /raise\s+\w*Refused\.new\(\s*:([a-z_]+)/,
    /Refused,\s*:([a-z_]+)/
  ].freeze

  # Codes that never reach a reader as a sentence. Named rather than skipped
  # quietly, and each with the reason it is not a sentence.
  SILENT = {
    'validation_failed' => 'the wrapper of field errors; the fields carry the words',
    'unexpected' => 'the interface writes this one for itself when it has nothing else'
  }.freeze

  def test_every_code_the_server_can_send_has_a_sentence
    languages.each do |code, table|
      missing = server_codes.reject { |name| table.dig('server', name) }
      assert_empty missing.sort,
                   "#{code}.json has no sentence for: #{missing.sort.join(', ')}"
    end
  end

  def test_every_field_code_has_a_sentence
    languages.each do |code, table|
      missing = field_codes.reject { |name| table.dig('field', name) }
      assert_empty missing.sort,
                   "#{code}.json has no sentence for the field code: #{missing.sort.join(', ')}"
    end
  end

  # The scan has to actually find something. A pattern that stopped matching —
  # a rename of `halt_with`, say — would leave every assertion above true over
  # an empty set, which is the failure this whole file exists to prevent.
  def test_the_scan_finds_the_codes_it_is_looking_for
    assert_operator server_codes.size, :>=, 40, 'the scan of the source found almost nothing'
    assert_includes server_codes, 'not_found'
    assert_includes server_codes, 'last_owner', 'a service refusal has to be found too'
    assert_includes field_codes, 'email_taken'
  end

  # The counter-direction, and the one that caught a real mistake: two
  # situations must not share a code. They would share a sentence, and one of
  # the two would then be described by words that belong to the other.
  def test_no_two_situations_share_a_code
    from_services = SERVICES.flat_map do |name, source|
      FROM_SERVICES.flat_map { |pattern| source.scan(pattern).flatten.map { |code| [code, name] } }
    end

    shared = from_services.group_by(&:first)
                          .transform_values { |pairs| pairs.map(&:last).uniq }
                          .select { |code, services| services.size > 1 && !SILENT.key?(code) }

    assert_empty shared,
                 'these codes are raised by more than one service and would share one sentence: ' \
                 "#{shared.inspect}"
  end

  private

  def languages
    Dir.glob(File.join(CODE_ROOT, 'frontend', 'src', 'locales', '*.json'))
       .to_h { |path| [File.basename(path, '.json'), JSON.parse(File.read(path, encoding: 'UTF-8'))] }
  end

  def server_codes
    @server_codes ||= begin
      from_app = FROM_APP.flat_map { |pattern| APP.scan(pattern).flatten }
      from_services = SERVICES.values.flat_map do |source|
        FROM_SERVICES.flat_map { |pattern| source.scan(pattern).flatten }
      end
      (from_app + from_services).uniq - SILENT.keys - field_codes
    end
  end

  # A field code never stands on its own — it is the value of a field in
  # `error.fields`. Read out of the places that build that hash.
  def field_codes
    @field_codes ||= (
      APP.scan(/problems\[:?\w+\]\s*=\s*'([a-z_]+)'/).flatten +
      APP.scan(/halt_validation\([^)]*=>\s*'([a-z_]+)'/).flatten +
      APP.scan(/halt_validation\(\s*\w+:\s*'([a-z_]+)'/).flatten +
      SERVICES.fetch('password', '').scan(/code:\s*'([a-z_]+)'/).flatten +
      SERVICES.fetch('settings', '').scan(/\[key,\s*'([a-z_]+)'\]/).flatten
    ).uniq
  end
end
