# frozen_string_literal: true

require_relative '../../test_helper'
require 'json'
require 'services/rendering'
require 'services/prompts'

# TF-449 — the shipped example package, checked for soundness.
#
# `examples/examples.json` is delivery content (BT-17, FA-802): `seed_demo`
# writes it in, and from AP-14 on it is imported. What was checked so far is
# **that** writing it in works — not whether its content hangs together.
#
# The difference is the one between a fault in a script and a fault in data. A
# `{{zielgrupe}}` in the text with no record belonging to it is created
# cleanly, read back cleanly, and produces a warning about an unknown
# placeholder for every user who opens that prompt. Nothing in the test run
# would have said so.
#
# What counts is the same detection as in operation: `Rendering.variable_keys`.
# Two ideas of what a placeholder is would be exactly the kind of divergence
# this case is meant to uncover.
class ExamplePackageTest < PromptAtelier::TestCase
  PACKAGE = JSON.parse(File.read(File.join(CODE_ROOT, 'examples', 'examples.json'), encoding: 'UTF-8')).freeze

  def test_it_carries_what_the_user_test_needs
    assert_operator PACKAGE['prompts'].size, :>=, 40
    assert_operator PACKAGE['keywords'].size, :>=, 5
    refute_nil PACKAGE.dig('workspace', 'name')
  end

  # The actual check: text and records have to cover each other. In both
  # directions — a placeholder without a record produces a warning for the
  # user, a record without a placeholder a form field with no effect.
  def test_every_placeholder_has_a_record_and_every_record_a_placeholder
    PACKAGE['prompts'].each do |prompt|
      in_text     = PromptAtelier::Rendering.variable_keys(prompt['body'])
      as_declared = Array(prompt['variables']).map { |variable| variable['key'] }

      assert_equal in_text.sort, as_declared.sort,
                   "#{prompt['title']}: Platzhalter im Text und Variablen des Prompts weichen ab"
    end
  end

  def test_every_variable_is_well_formed
    PACKAGE['prompts'].each do |prompt|
      Array(prompt['variables']).each do |variable|
        label = "#{prompt['title']} / #{variable['key']}"

        # Against the shipped rule, not against a copy of it. This line used to
        # carry its own `\A[a-z][a-z0-9_]{0,39}\z` — a **third** spelling of
        # 8.2 beside the two renderers — and it duly refused `{{prénom}}` on
        # the day the rule was widened (AP-23). The subject here is the data,
        # so the rule has to come from where the application keeps it.
        assert_match(/\A#{PromptAtelier::Rendering::KEY}\z/, variable['key'],
                     "#{label}: Schlüssel verletzt 8.2")
        assert_includes PromptAtelier::Prompts::VARIABLE_TYPES, variable['type'], "#{label}: unbekannter Typ"
        refute_nil variable['position'], "#{label}: ohne Position ist die Reihenfolge Zufall"
      end
    end
  end

  # A select variable without a selection is a field in which nothing stands
  # and nothing can stand (FA-302).
  #
  # In the exchange format the options are a **list** (17.1), in the `options`
  # column one line per option (14.1). Both are laid down that way, and the
  # conversion belongs to `Prompts.create`. What is checked here is the list —
  # and explicitly as a list, because a string of lines at this point would
  # arrive on import as **one** option.
  def test_every_selection_offers_something_to_select
    selections = PACKAGE['prompts'].flat_map do |prompt|
      Array(prompt['variables']).select { |variable| variable['type'] == 'select' }
                                .map { |variable| [prompt['title'], variable] }
    end

    refute_empty selections, 'ohne eine einzige Auswahlvariable prüft dieser Fall nichts'

    selections.each do |title, variable|
      label   = "#{title} / #{variable['key']}"
      options = variable['options']

      assert_kind_of Array, options, "#{label}: Optionen gehören nach 17.1 als Liste ins Paket"
      assert_operator options.size, :>=, 2, "#{label}: weniger als zwei Optionen"
      assert(options.none? { |option| option.to_s.strip.empty? }, "#{label}: leere Option")
    end
  end

  # The counter-check to the format question: whatever is not a select carries
  # no options either. A text field with options would be a record promising
  # something no form displays.
  def test_only_selections_carry_options
    PACKAGE['prompts'].each do |prompt|
      Array(prompt['variables']).each do |variable|
        next if variable['type'] == 'select'

        assert_nil variable['options'], "#{prompt['title']} / #{variable['key']}: Optionen ohne Auswahl"
      end
    end
  end

  # A default keyword the package does not contain is quietly left out when
  # writing in — the prompt would arrive without the block it was written
  # for.
  def test_every_default_keyword_is_part_of_the_package
    known = PACKAGE['keywords'].map { |keyword| keyword['name'] }

    PACKAGE['prompts'].each do |prompt|
      Array(prompt['default_keywords']).each do |name|
        assert_includes known, name, "#{prompt['title']}: Standard-Keyword #{name} fehlt im Paket"
      end
    end
  end

  def test_every_keyword_is_usable
    PACKAGE['keywords'].each do |keyword|
      assert_includes %w[prepend append], keyword['position'], "#{keyword['name']}: Position nach 8.1"
      refute keyword['text'].to_s.strip.empty?, "#{keyword['name']}: ein Baustein ohne Text baut nichts"
    end
  end

  # The titles are the way to a prompt — in the search, and in the script that
  # skips existing ones on a second run. Two identical titles turn that second
  # run into a guessing game.
  def test_the_titles_are_distinct
    titles = PACKAGE['prompts'].map { |prompt| prompt['title'] }

    assert_equal titles.uniq.size, titles.size, "doppelte Titel: #{titles.tally.select { |_, n| n > 1 }.keys}"
  end

  # And the shapes for which the preview does work of its own (8.3.1): a
  # variable alone on its line. Were the package to shrink to nothing but
  # single-line texts, TF-448 would lose its subject without going red.
  def test_it_keeps_the_shapes_the_preview_is_tested_against
    own_line = PACKAGE['prompts'].count { |prompt| prompt['body'].include?("\n\n{{") }
    multiline = PACKAGE['prompts'].flat_map { |p| Array(p['variables']) }
                                 .count { |variable| variable['type'] == 'multiline' }

    assert_operator own_line, :>=, 10
    assert_operator multiline, :>=, 5
  end
end
