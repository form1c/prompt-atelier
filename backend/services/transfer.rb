# frozen_string_literal: true

require 'json'
require 'time'
require 'yaml'
require_relative 'prompts'
require_relative 'catalog'
require_relative 'normalization'

module PromptAtelier
  # Import and export (FA-801 to FA-804, Requirements chapter 17).
  #
  # The promise that shapes everything here is FA-804: a JSON export read back
  # into an empty instance yields the same content. So the format is a content
  # image and never a system image — no accounts, no sessions, no favourites,
  # no revisions, no internal identifiers (17.1). What travels is what somebody
  # wrote; what stays behind is what this installation happens to know about
  # them.
  #
  # Two formats with two different promises, and the difference is not a
  # detail:
  #
  #   * **JSON** is the removal van. Lossless, keeps timestamps and the full
  #     keyword definitions.
  #   * **Markdown** is the filing cabinet. One readable file per prompt, no
  #     timestamps, keywords by name only — and therefore *not* lossless
  #     (FA-803, 17.2). Saying so plainly is part of the requirement.
  module Transfer
    FORMAT  = 'promptatelier-export'

    # Raised to 2 in AP-18, when the domain values inside a file changed from
    # German to English. Files of both versions are read; only the current one
    # is written.
    VERSION = 2
    READABLE_VERSIONS = [1, 2].freeze

    # The spellings a version 1 file carries. An export is somebody's backup,
    # and A-10 (export, import into an empty instance, identical contents) has
    # to keep holding for a file written before the rename — otherwise the
    # promise silently shrinks to files made from today on.
    #
    # Applied to **every** incoming file rather than only to `"version": 1`.
    # A Markdown export states no version at all (17.2), so a rule hung on
    # that field would miss precisely the format that cannot carry it. The
    # mapping is safe to apply twice: no English value is a key in it.
    LEGACY_VALUES = {
      'visibility' => { 'privat' => 'private', 'instanz' => 'instance' },
      'status'     => { 'entwurf' => 'draft', 'aktiv' => 'active', 'archiviert' => 'archived' },
      'type'       => { 'mehrzeilig' => 'multiline', 'auswahl' => 'select', 'zahl' => 'number' }
    }.freeze

    # The name the product carried before it was called Prompt Atelier. Files
    # written under it are still read, and that is not politeness: an export is
    # somebody's backup, and a rename of the product must not make yesterday's
    # file unreadable. Written is only the current marker — otherwise the old
    # name would live on in every new file.
    #
    # ⚠ This string is **data**, not a name. A blanket rename across the source
    # must leave it alone; it did not, the first time, and the compatibility it
    # exists for was gone in the same commit that introduced it.
    FORMER_FORMATS = %w[promptstorage-export].freeze

    def self.readable_format?(value)
      value == FORMAT || FORMER_FORMATS.include?(value)
    end

    # 10 MB, SEC-12. Checked before anything is parsed — a limit that only
    # applies after reading is not a limit, it is a report.
    MAX_BYTES = 10 * 1024 * 1024

    # What a collision may be answered with (FA-802). `overwrite` is absent
    # from the list a caller gets when the target holds more than one prompt of
    # that title: there would be no way to say *which* one.
    DECISIONS = %w[skip copy overwrite].freeze

    # A keyword collides on its **name**, and the name is not a label the way
    # a prompt title is: `prompt_keywords` resolves the `default_keywords` of
    # an imported prompt through it, and the schema holds it unique per
    # workspace. So "copy" is missing here on purpose. A copy would need a
    # different name, and then no imported prompt would reference it. It would
    # be a definition nothing uses.
    #
    # `overwrite` has no revision behind it either, because keywords have no
    # revisions. That is why the preview hands over the old and the new text
    # of a collision instead of a count: the decision has to be made in sight
    # of what it replaces.
    KEYWORD_DECISIONS = %w[skip overwrite].freeze

    # The fields 17.1 lists for a prompt. Anything else in a file is unknown
    # and is reported rather than silently dropped (TF-343).
    PROMPT_FIELDS = %w[title description body visibility status model_hint
                       tags default_keywords variables created_at updated_at].freeze
    VARIABLE_FIELDS = %w[key label type default_value options required position].freeze
    KEYWORD_FIELDS  = %w[name description text position sort_order].freeze

    class Refused < StandardError
      attr_reader :code, :detail

      def initialize(code, detail = {})
        @code = code
        @detail = detail
        super(code.to_s)
      end
    end

    class << self
      # --- export (FA-801, FA-804) -----------------------------------------

      # +owner_id+ restricts the export to that person's own prompts. That is
      # the ◐ of the permission matrix for `prompt.export`, and it is decided
      # by **ownership**, not by what may be read: an editor may read more than
      # belongs to them, and an export of everything readable would make the
      # distinction between ◐ and ● meaningless (FA-801).
      def export(db, workspace_id:, owner_id: nil, prompt_ids: nil, now: Time.now)
        rows = exportable(db, workspace_id, owner_id, prompt_ids)
        prompts = rows.map { |row| exported_prompt(db, row) }

        {
          'format' => FORMAT,
          'version' => VERSION,
          'exported_at' => now.iso8601,
          'workspace' => { 'name' => db[:workspaces].where(id: workspace_id).get(:name) },
          'keywords' => exported_keywords(db, workspace_id, rows, owner_id),
          'prompts' => prompts
        }
      end

      def exportable(db, workspace_id, owner_id, prompt_ids)
        rows = db[:prompts].where(workspace_id: workspace_id, deleted_at: nil)
        rows = rows.where(owner_id: owner_id) unless owner_id.nil?
        rows = rows.where(id: Array(prompt_ids)) unless prompt_ids.nil?

        rows.order(:title).all
      end

      # For a full workspace export: every keyword, because the file is meant
      # to rebuild the workspace. For an export limited to one person's own
      # prompts: the keywords those prompts use, so the file stands on its own
      # without handing over a catalogue that was not asked for (TF-346).
      def exported_keywords(db, workspace_id, rows, owner_id)
        keywords = db[:keywords].where(workspace_id: workspace_id)
        unless owner_id.nil?
          used = db[:prompt_keywords].where(prompt_id: rows.map { |row| row[:id] }).select_map(:keyword_id)
          keywords = keywords.where(id: used)
        end

        keywords.order(:position, :sort_order, :name).all.map do |keyword|
          KEYWORD_FIELDS.to_h { |field| [field, keyword[field.to_sym]] }
        end
      end

      def exported_prompt(db, row)
        {
          'title' => row[:title],
          'description' => row[:description],
          'body' => row[:body],
          'visibility' => row[:visibility],
          'status' => row[:status],
          'model_hint' => row[:model_hint],
          'tags' => Prompts.tag_names(db, row[:id]),
          'default_keywords' => Prompts.default_keywords(db, row[:id]).map { |keyword| keyword[:name] },
          'variables' => exported_variables(db, row[:id]),
          'created_at' => row[:created_at]&.iso8601,
          'updated_at' => row[:updated_at]&.iso8601
        }
      end

      # `options` travels as a **list**, not as the newline-separated text the
      # column holds (17.1). The database keeps one shape and the file another,
      # and this is the one place that knows both.
      def exported_variables(db, prompt_id)
        db[:prompt_variables].where(prompt_id: prompt_id).order(:position).all.map do |variable|
          {
            'key' => variable[:key],
            'label' => variable[:label],
            'type' => variable[:type],
            'default_value' => variable[:default_value],
            'options' => option_list(variable[:options]),
            'required' => variable[:required] == true,
            'position' => variable[:position]
          }
        end
      end

      def option_list(stored)
        return nil if stored.nil? || stored.to_s.strip.empty?

        stored.to_s.split("\n").map(&:strip).reject(&:empty?)
      end

      # Workspace and day, so a folder of exports can be sorted and told apart.
      # Built from the same slug rule as the Markdown file names (14.2).
      def export_filename(package, extension: 'json')
        slug = slug_for(package.dig('workspace', 'name'))
        day = Time.parse(package['exported_at']).strftime('%Y-%m-%d')

        "#{slug}-#{day}.#{extension}"
      end

      # --- Markdown export (FA-803, 17.2) ----------------------------------

      # One file per prompt, named after the title. Deliberately **not**
      # lossless: no timestamps, and keywords by name only. A caller who needs
      # a complete move takes JSON, and the answer says so by simply not
      # carrying the fields.
      def export_markdown(db, workspace_id:, owner_id: nil, prompt_ids: nil)
        rows = exportable(db, workspace_id, owner_id, prompt_ids)
        used = Hash.new(0)

        rows.map do |row|
          prompt = exported_prompt(db, row)
          name = unique_filename(used, filename_for(prompt['title']))
          { 'name' => name, 'content' => markdown_document(prompt) }
        end
      end

      # The slug rule of 14.2, the same one workspaces use. Two prompts whose
      # titles differ only in punctuation would otherwise overwrite each other
      # on disk — which is why the counter below exists and is not optional.
      def filename_for(title) = "#{slug_for(title, fallback: 'prompt')}.md"

      def slug_for(text, fallback: 'promptatelier')
        Normalization.slug(text, fallback: fallback)
      end

      def unique_filename(used, name)
        used[name] += 1
        return name if used[name] == 1

        "#{name.sub(/\.md\z/, '')}-#{used[name] - 1}.md"
      end

      def markdown_document(prompt)
        front = prompt.slice('title', 'description', 'visibility', 'status', 'model_hint',
                             'tags', 'default_keywords')
                      .reject { |_, value| value.nil? }
        front['variables'] = prompt['variables'].map { |variable| variable.compact }

        "#{YAML.dump(front)}---\n\n#{prompt['body']}\n"
      end

      # --- reading a file (FA-802) -----------------------------------------

      # Turns a file into a package, or refuses with a reason that names what
      # is wrong. "Ungültige Datei" alone leaves the user with a file and no
      # idea what to do about it (FA-802, TF-342).
      #
      # Both formats end up in the same shape, so everything downstream — the
      # preview, the collision rules, the writing — exists once. A second path
      # for Markdown would be a second place for the rules to be almost the
      # same.
      def parse(content)
        text = content.to_s
        raise Refused, :empty_file if text.strip.empty?
        raise Refused.new(:file_too_large, { limit: MAX_BYTES }) if text.bytesize > MAX_BYTES

        text.lstrip.start_with?('{') ? parse_json(text) : parse_markdown(text)
      end

      def parse_json(text)
        data = begin
          JSON.parse(text)
        rescue JSON::ParserError => e
          # The parser's own message names line and column, which is the one
          # thing that helps with a file somebody edited by hand. It is not an
          # internal detail in the sense of SEC-13 — it describes the input,
          # not this application.
          raise Refused.new(:malformed_json, { reason: e.message.lines.first.to_s.strip })
        end

        raise Refused, :not_an_export unless data.is_a?(Hash) && readable_format?(data['format'])
        unless READABLE_VERSIONS.include?(data['version'])
          raise Refused.new(:unsupported_version, { version: data['version'] })
        end
        # **A file without prompts is not an empty file.** A full workspace
        # export carries every keyword of that workspace whether or not a
        # prompt uses one, so a workspace holding only keywords exports to
        # exactly this shape. Refusing it here meant the application wrote a
        # file it could not read back, which is the one thing FA-804 promises
        # it never does.
        #
        # Refused is the file that carries neither, because there is nothing
        # to preview and nothing to write.
        prompts  = data['prompts']
        keywords = data['keywords']
        raise Refused, :not_an_export unless prompts.nil? || prompts.is_a?(Array)
        raise Refused, :not_an_export unless keywords.nil? || keywords.is_a?(Array)
        raise Refused, :no_content if Array(prompts).empty? && Array(keywords).empty?

        package(prompts, keywords, data.dig('workspace', 'name'))
      end

      # One Markdown document is one prompt (17.2). The keyword **names** are
      # in the frontmatter and their definitions are not — which is exactly
      # the loss FA-803 is honest about, and it shows up here as a package
      # with prompts and no keywords.
      def parse_markdown(text)
        front, body = split_frontmatter(text)
        data = begin
          YAML.safe_load(front, permitted_classes: [], aliases: false)
        rescue Psych::Exception => e
          raise Refused.new(:malformed_frontmatter, { reason: e.message.lines.first.to_s.strip })
        end

        raise Refused, :not_an_export unless data.is_a?(Hash) && !data['title'].to_s.strip.empty?

        package([data.merge('body' => body)], [], nil)
      end

      def split_frontmatter(text)
        # \A--- on its own line, then everything up to the next such line.
        match = text.match(/\A---\s*\n(.*?)\n---\s*\n(.*)\z/m)
        raise Refused, :no_frontmatter if match.nil?

        [match[1], match[2].strip]
      end

      # Everything a file may carry, sorted into what is understood and what is
      # not. Unknown fields are **named**, not dropped in silence (TF-343): a
      # file from a newer version is usable, and the report says what was left
      # behind rather than letting the user find out later.
      def package(prompts, keywords, workspace_name)
        unknown = []
        entries = Array(prompts).each_with_index.map do |entry, index|
          raise Refused.new(:prompt_not_an_object, { index: index }) unless entry.is_a?(Hash)
          raise Refused.new(:prompt_without_title, { index: index }) if entry['title'].to_s.strip.empty?
          raise Refused.new(:prompt_without_body, { index: index }) if entry['body'].to_s.strip.empty?

          unknown.concat(entry.keys - PROMPT_FIELDS)
          unknown.concat(Array(entry['variables']).flat_map { |v| v.is_a?(Hash) ? v.keys - VARIABLE_FIELDS : [] })
          entry
        end

        definitions = Array(keywords).select { |entry| entry.is_a?(Hash) && !entry['name'].to_s.strip.empty? }
        unknown.concat(definitions.flat_map { |entry| entry.keys - KEYWORD_FIELDS })

        {
          'workspace_name' => workspace_name,
          'keywords' => definitions,
          'prompts' => entries,
          'unknown_fields' => unknown.uniq.sort
        }
      end

      # --- the preview (FA-802, W-8) ---------------------------------------

      # Nothing is written here, and that is the whole point: "Ein Import, der
      # stillschweigend 200 Prompts überschreibt, ist ein Datenverlustereignis"
      # (W-8). The answer says per entry what would happen and what may be
      # decided.
      #
      # Entries are addressed by their **position in the file**, not by their
      # title. A file may well carry the same title twice — FA-204 produces
      # "… (Kopie)" and somebody exports both — and a decision keyed by title
      # would then apply to a row nobody meant.
      def preview(db, workspace_id:, package:)
        existing = titles_in(db, workspace_id)

        entries = package['prompts'].each_with_index.map do |entry, index|
          matches = existing[collision_key(entry['title'])] || []
          { 'index' => index, 'title' => entry['title'].to_s.strip,
            'state' => state_for(matches), 'decisions' => allowed_decisions(matches),
            'candidates' => matches }
        end

        {
          'prompts' => entries,
          'new_count' => entries.count { |entry| entry['state'] == 'new' },
          'collision_count' => entries.count { |entry| entry['state'] != 'new' },
          'keywords' => keyword_report(db, workspace_id, package),
          'unknown_fields' => package['unknown_fields']
        }
      end

      # The comparison key of FA-802: the title inside the target workspace,
      # without regard to case or surrounding spaces (TF-341c).
      def collision_key(title) = title.to_s.strip.downcase

      def titles_in(db, workspace_id)
        db[:prompts].where(workspace_id: workspace_id, deleted_at: nil)
                    .select(:id, :title, :updated_at).all
                    .group_by { |row| collision_key(row[:title]) }
                    .transform_values do |rows|
                      rows.map { |row| { 'id' => row[:id], 'title' => row[:title],
                                         'updated_at' => row[:updated_at]&.iso8601 } }
                    end
      end

      def state_for(matches)
        return 'new' if matches.empty?

        matches.size == 1 ? 'collision' : 'ambiguous'
      end

      # With more than one candidate, "overwrite" is not offered — there would
      # be no way to say which one is meant (FA-802). The preview names the
      # candidates with their change dates instead, so the decision can be made
      # by hand afterwards.
      def allowed_decisions(matches)
        return [] if matches.empty?

        matches.size == 1 ? DECISIONS : DECISIONS - ['overwrite']
      end

      # Which keywords the file needs, and which of them this workspace has.
      # A Markdown file carries names and no definitions, so the missing ones
      # stay missing and are reported (17.2, same rule as FA-204).
      def keyword_report(db, workspace_id, package)
        needed = package['prompts'].flat_map { |entry| Array(entry['default_keywords']) }
                                   .map { |name| name.to_s.strip }.reject(&:empty?).uniq
        here = db[:keywords].where(workspace_id: workspace_id).all
                            .to_h { |row| [row[:name], row] }
        provided = package['keywords'].map { |entry| entry['name'].to_s.strip }

        {
          'to_create' => (provided - here.keys).sort,
          'missing' => (needed - here.keys - provided).sort,
          'conflicts' => keyword_conflicts(package, here)
        }
      end

      # **The case that used to disappear.** A keyword whose name is already
      # taken here was neither created nor reported: it was in `to_create`
      # because it exists, and not in `missing` because the file provides it.
      # It fell between the two lists, and the definition in the file was gone
      # without a word. That is the silence FA-802 is written against.
      #
      # Addressed by position in the file, like a prompt, and for the same
      # reason: it is the one handle that cannot mean two things.
      def keyword_conflicts(package, here)
        package['keywords'].each_with_index.filter_map do |entry, index|
          name = entry['name'].to_s.strip
          row = here[name]
          next if row.nil?

          incoming = KEYWORD_FIELDS.to_h { |field| [field, entry[field]] }
          existing = KEYWORD_FIELDS.to_h { |field| [field, row[field.to_sym]] }

          { 'index' => index, 'name' => name,
            'decisions' => KEYWORD_DECISIONS,
            # Named rather than left to the screen to work out: an import of
            # forty keywords that changes none of them should not read as forty
            # decisions waiting to be made.
            'identical' => comparable(incoming) == comparable(existing),
            'existing' => existing, 'incoming' => incoming }
        end
      end

      # `sort_order` arrives from JSON as a number and from the database as one
      # too, but a hand-written file may carry it as a string, and `position`
      # may differ only in surrounding space. Comparing the raw values would
      # report a difference that no reader could see.
      def comparable(fields)
        fields.transform_values { |value| value.nil? ? nil : value.to_s.strip }
      end

      # --- writing (FA-802, SEC-12) ----------------------------------------

      # One transaction for the whole file. SEC-12 asks for it and TF-412
      # checks it: a file that turns out to be unusable at prompt 40 of 51
      # must leave nothing behind, or the user is left with a half-imported
      # workspace and no way to tell which half.
      #
      # +decisions+ maps the position in the file to one of DECISIONS. What is
      # not mentioned and collides is **skipped** — the safe answer, and the
      # only one that cannot destroy something by omission.
      def import(db, workspace_id:, owner_id:, package:, decisions: {}, keyword_decisions: {},
                 now: Time.now)
        plan = preview(db, workspace_id: workspace_id, package: package)
        report = { 'created' => [], 'overwritten' => [], 'skipped' => [],
                   'keywords_created' => [], 'keywords_overwritten' => [], 'keywords_skipped' => [],
                   'keywords_missing' => plan['keywords']['missing'],
                   'unknown_fields' => package['unknown_fields'] }

        db.transaction do
          apply_keywords(db, workspace_id, package, plan, keyword_decisions, report, now: now)
          catalogue = db[:keywords].where(workspace_id: workspace_id).to_hash(:name, :id)

          plan['prompts'].each do |entry|
            apply(db, workspace_id, owner_id, package['prompts'][entry['index']],
                  entry, decisions[entry['index'].to_s] || decisions[entry['index']],
                  catalogue, report, now)
          end
        end

        report
      end

      # Runs before the prompts, because the catalogue the prompts resolve
      # their `default_keywords` through is read afterwards. A keyword that is
      # overwritten here keeps its row and its id, so a prompt pointing at it
      # points at the new definition without anything having to be relinked.
      def apply_keywords(db, workspace_id, package, plan, decisions, report, now:)
        wanted = plan['keywords']['to_create']
        conflicts = plan['keywords']['conflicts'].to_h { |entry| [entry['index'], entry] }

        package['keywords'].each_with_index do |entry, index|
          name = entry['name'].to_s.strip
          conflict = conflicts[index]

          if conflict.nil?
            next unless wanted.include?(name)

            Catalog.create_keyword(db, workspace_id, entry, now: now)
            report['keywords_created'] << name
          elsif keyword_overwrite?(conflict, decisions[index.to_s] || decisions[index])
            Catalog.update_keyword(db, db[:keywords][workspace_id: workspace_id, name: name],
                                   entry, now: now)
            report['keywords_overwritten'] << name
          else
            report['keywords_skipped'] << name
          end
        end
      end

      # Same rule as for a prompt, and the same reason: no decision means skip,
      # and a decision the preview did not offer is refused rather than
      # reinterpreted into something the caller did not ask for.
      def keyword_overwrite?(conflict, decision)
        return false if decision.nil? || decision == 'skip'

        raise Refused.new(:decision_not_available, { title: conflict['name'], decision: decision }) \
          unless conflict['decisions'].include?(decision)

        decision == 'overwrite'
      end

      def apply(db, workspace_id, owner_id, source, entry, decision, catalogue, report, now)
        return report['skipped'] << entry['title'] if skipping?(entry, decision)

        if decision == 'overwrite' && entry['state'] == 'collision'
          overwrite(db, entry['candidates'].first['id'], source, catalogue, owner_id, now)
          report['overwritten'] << entry['title']
        else
          title = decision == 'copy' ? "#{entry['title']} (Kopie)" : entry['title']
          create(db, workspace_id, owner_id, source, title, catalogue, now)
          report['created'] << title
        end
      end

      # A collision with no decision is skipped, and an "overwrite" that the
      # preview did not offer is refused rather than quietly reinterpreted:
      # the caller asked for something specific, and doing something else with
      # their data is worse than refusing.
      def skipping?(entry, decision)
        return false if entry['state'] == 'new'
        return true if decision.nil? || decision == 'skip'

        raise Refused.new(:decision_not_available, { title: entry['title'], decision: decision }) \
          unless entry['decisions'].include?(decision)

        false
      end

      def create(db, workspace_id, owner_id, source, title, catalogue, now)
        id = Prompts.create(db, workspace_id: workspace_id, owner_id: owner_id,
                                attributes: attributes_for(source, title, catalogue), now: now)
        stamp(db, id, source)
        id
      end

      # FA-802 and Leitprinzip 2: overwriting writes a revision of the previous
      # state first. `Prompts.update` does that by itself when something
      # changed — going around it would be a second implementation of FA-701,
      # and the one that forgets.
      def overwrite(db, prompt_id, source, catalogue, actor_id, now)
        prompt = db[:prompts][id: prompt_id]
        Prompts.update(db, prompt, attributes: attributes_for(source, prompt[:title], catalogue),
                                   actor_id: actor_id, now: now)
        stamp(db, prompt_id, source)
      end

      # The timestamps of 17.1, restored after the write rather than passed
      # through it. `Prompts.create` and `.update` set them to now, which is
      # right for everything they normally do — and wrong for an import, whose
      # promise is that the prompt comes back as it was (FA-804).
      #
      # A Markdown file carries no timestamps; then nothing is restored and the
      # new ones stand, which is exactly what 17.2 announces.
      def stamp(db, prompt_id, source)
        values = { created_at: parse_time(source['created_at']),
                   updated_at: parse_time(source['updated_at']) }.compact
        db[:prompts].where(id: prompt_id).update(values) unless values.empty?
      end

      def parse_time(value)
        return nil if value.nil? || value.to_s.strip.empty?

        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      def attributes_for(source, title, catalogue)
        {
          'title' => title,
          'description' => source['description'],
          'body' => source['body'],
          'visibility' => modernise('visibility', source['visibility'] || 'private'),
          'status' => modernise('status', source['status'] || 'draft'),
          'model_hint' => source['model_hint'],
          'tags' => Array(source['tags']),
          'variables' => Array(source['variables']).map { |variable| modernise_variable(variable) },
          'keyword_ids' => Array(source['default_keywords'])
                             .filter_map { |name| catalogue[name.to_s.strip] }
        }.compact
      end

      # A value in the spelling of its file, in the spelling of today. Unknown
      # values are handed on untouched — refusing them is the job of the
      # validation further in, which names the field and the value; swallowing
      # them here would turn a typo into a silent default.
      def modernise(field, value)
        LEGACY_VALUES.fetch(field, {}).fetch(value, value)
      end

      def modernise_variable(variable)
        return variable unless variable.is_a?(Hash) && variable.key?('type')

        variable.merge('type' => modernise('type', variable['type']))
      end
    end
  end
end
