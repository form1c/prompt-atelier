# frozen_string_literal: true

# scripts/lib/bench.rb — the stock the measurements of section 11 are taken on
#
# 5.000 prompts, and 20.000 for NFA-08. Two properties decide whether a number
# measured on it means anything, and both are easy to get wrong:
#
#   * **Variety.** Five thousand copies of one prompt make full text search
#     look magnificent: one term, one posting list, one page of results. Real
#     libraries have a long tail of rare words, and that tail is what a search
#     index is actually asked about. The corpus below is assembled from word
#     pools so that terms occur at every frequency from "once" to "in half the
#     library" — and the measurement asks about all of them, not only the
#     comfortable one.
#   * **Determinism.** Two runs on the same machine must be comparable, or a
#     regression cannot be told from a different draw. Everything comes from
#     `Random.new(SEED)`, so the same count always produces the same library,
#     on any machine and in any Ruby.
#
# The stock is built through **the real services** (`Prompts.create`), not by
# inserting rows. Anything else would skip the normalisation of FA-501 and the
# FTS triggers, and the search would then be measured over an index that no
# installation ever has.

require 'securerandom'

module PromptAtelier
  module Bench
    # Fixed, so that the same count yields the same library. Written out rather
    # than derived from the clock — a "random" corpus makes every measurement a
    # measurement of a different thing.
    SEED = 20_260_806

    # The password every bench account carries. It has to pass the policy of
    # SEC-02, because these accounts are created the way any account is.
    PASSWORD = 'Messplatz-2026-Kennwort'

    # How many prompts share one transaction. One transaction per prompt makes
    # 20.000 fsyncs; one for all of them holds a write lock for minutes and
    # loses everything on an interruption.
    BATCH = 500

    # The two workspaces the measurements read from. A third comes into being
    # by itself: every account gets a personal one (FA-602).
    WORKSPACES = ['Marketing', 'Vertrieb'].freeze

    # --- the word pools -------------------------------------------------------
    #
    # German with umlauts throughout, because the search normalises them
    # (FA-501) and a corpus without them would measure the cheap path only.

    TASKS = %w[
      Blogartikel Produktbeschreibung Pressemitteilung Stellenanzeige Angebot
      Zusammenfassung Übersetzung Gesprächsleitfaden Schulungsunterlage Prüfbericht
      Kündigungsschreiben Marktanalyse Störungsmeldung Änderungsantrag Übergabeprotokoll
    ].freeze

    SUBJECTS = %w[
      Fassadendämmung Warenwirtschaft Kältetechnik Grünpflege Lohnbuchhaltung
      Zerspanung Oberflächenschutz Netzersatzanlage Fördertechnik Wärmepumpe
      Aktenführung Güterverkehr Löschanlage Hüttentechnik Bühnenbau
    ].freeze

    AUDIENCES = ['Einsteiger', 'Fachkräfte', 'Geschäftsführung', 'Auszubildende',
                 'Behörden', 'Endkunden', 'Zulieferer'].freeze

    TONES = %w[sachlich freundlich knapp ausführlich werblich amtlich].freeze

    TAGS = %w[
      seo content vertrieb technik recht personal einkauf qualität
      schulung support marketing finanzen logistik entwicklung
    ].freeze

    # The needles. Each occurs in exactly one prompt of any corpus size, and
    # the measurement asks for them: a term with one hit and a term with
    # thousands stress the index in opposite ways, and only asking both says
    # whether the 200 ms of NFA-02 hold.
    #
    # They are put into prompts the measuring account is **allowed to read**.
    # The first draft left that to the general distribution, and the general
    # distribution put every one of them behind `visibility: private` of another
    # owner: the case called "search, one hit" measured a search with no hit at
    # all, and reported the fastest number in the table. Found by counting what
    # the queries returned instead of trusting that they returned something.
    RARE_TERMS = %w[Zwetschgenkuchen Rüsselkäfer Löschzugverband Übergabepunkt].freeze

    # A term in the title of roughly every eighth prompt — the other end of the
    # scale, where the index finds a great deal and the paging has to do the
    # work.
    COMMON_TERM = 'Blogartikel'

    # A subject with an umlaut, asked for in its written-out form
    # (`Gruenpflege`). It is in about one title in fifteen, so it exercises the
    # normalisation of FA-501 over a **part** of the library. A term that is in
    # every prompt would be measuring the library page again under another
    # name.
    UMLAUT_SUBJECT = 'Grünpflege'

    module_function

    # Builds the stock in an already migrated database. Returns the facts the
    # measurement needs afterwards: which account to sign in as, which
    # workspace to read, which terms to ask for.
    #
    # +progress+ is called with the number written so far. Seeding 20.000
    # prompts takes minutes, and a script that says nothing for minutes is one
    # people stop (the finding behind `install` step 2).
    def build(db, prompts:, progress: nil)
      random = Random.new(SEED)
      people = create_people(db)
      spaces = create_workspaces(db, people)
      keywords = create_keywords(db, spaces)

      written = 0
      while written < prompts
        count = [BATCH, prompts - written].min
        db.transaction do
          count.times { |offset| create_prompt(db, spaces, people, keywords, written + offset, random) }
        end
        written += count
        progress&.call(written)
      end

      facts(spaces, people, prompts)
    end

    # What the measurement needs to know about the stock it is about to read.
    def facts(spaces, people, prompts)
      {
        email: people[:reader][:email],
        # The load measurement writes, and it writes as the **owner** of the
        # prompts in the stock. An editor may save them too, but an owner is
        # the ordinary case and the one whose permission check is shortest —
        # under load the subject is the write itself, not the check in front of
        # it.
        author_email: people[:author][:email],
        password: PASSWORD,
        workspace_id: spaces['Marketing'],
        workspace_ids: spaces.values,
        prompts: prompts,
        rare_terms: RARE_TERMS,
        common_term: COMMON_TERM,
        umlaut_term: 'Gruenpflege'
      }
    end

    # --- accounts and workspaces ---------------------------------------------

    # Three accounts, and the differences between them are the ones the
    # measurement depends on:
    #
    #   reader  is a member of both workspaces — the ordinary case, and the
    #           one the timings are taken as
    #   author  owns most of the prompts, so `visibility: private` has an owner
    #           other than the reader and the permission filter of FA-507
    #           really has something to exclude
    #   admin   exists because an instance without one is not a real instance
    #
    # A corpus in which the reader may see everything would measure a query
    # without its `WHERE` clause.
    def create_people(db)
      {
        reader: Accounts.create(db, name: 'Messleserin', email: 'reader@bench.test', password: PASSWORD),
        author: Accounts.create(db, name: 'Messautor', email: 'author@bench.test', password: PASSWORD),
        admin: Accounts.create(db, name: 'Messadmin', email: 'admin@bench.test',
                               password: PASSWORD, instance_admin: true)
      }
    end

    def create_workspaces(db, people)
      WORKSPACES.to_h do |name|
        id = Workspaces.create(db, name: name, owner_id: people[:author][:id])
        Workspaces.add_member(db, id, people[:reader][:id], 'editor')
        [name, id]
      end
    end

    # Two keywords per workspace, one prepended and one appended, so that a
    # rendered prompt in the stock has the shape the pipeline of section 8
    # actually produces.
    def create_keywords(db, spaces)
      now = Time.now
      spaces.transform_values do |workspace_id|
        [
          db[:keywords].insert(workspace_id: workspace_id, name: 'kontext',
                               text: 'Du bist ein erfahrener Fachredakteur.',
                               position: 'prepend', sort_order: 10,
                               created_at: now, updated_at: now),
          db[:keywords].insert(workspace_id: workspace_id, name: 'ton',
                               text: 'Schreibe in einem sachlichen Ton.',
                               position: 'append', sort_order: 20,
                               created_at: now, updated_at: now)
        ]
      end
    end

    # --- the prompts ----------------------------------------------------------

    # One prompt, built from the pools.
    #
    # **The properties are drawn independently of one another**, and that is
    # not a detail. The first draft derived workspace from `index % 2` and
    # visibility from `index % 4`, which reads like two decisions and is one:
    # every even index went to Marketing, and `index % 4 == 0` is a subset of
    # the even ones, so Marketing held not a single instance-wide prompt and
    # every prompt carrying the common term was private. The corpus looked
    # varied in the source and was not varied in the database. Frequencies that
    # come out of one counter are frequencies that agree with each other.
    def create_prompt(db, spaces, people, keywords, index, random)
      workspace_name = WORKSPACES[index % WORKSPACES.length]
      workspace_id = spaces[workspace_name]
      task = TASKS[index % TASKS.length]
      needle = RARE_TERMS[index]

      Prompts.create(
        db,
        workspace_id: workspace_id,
        owner_id: people[:author][:id],
        attributes: {
          'title' => title_for(index, task, needle, random),
          'description' => description_for(task, random),
          'body' => body_for(task, index, random),
          # A needle nobody may read is no needle. See RARE_TERMS.
          'visibility' => needle ? 'workspace' : visibility_for(random),
          'status' => status_for(random),
          'tags' => tags_for(random),
          'variables' => VARIABLES,
          'keyword_ids' => index.even? ? [keywords[workspace_name].first] : []
        }
      )
    end

    # Roughly every eighth title carries the common term, every corpus carries
    # each rare term exactly once — the two ends of the frequency scale, placed
    # on purpose rather than hoped for.
    def title_for(index, task, needle, random)
      subject = SUBJECTS[random.rand(SUBJECTS.length)]
      common = random.rand(8).zero?
      return "#{task} #{subject} #{needle} ##{index}" if needle

      "#{common ? COMMON_TERM : task} für #{subject} ##{index}"
    end

    def description_for(task, random)
      "Erzeugt einen #{task} für #{AUDIENCES[random.rand(AUDIENCES.length)]}, " \
        "#{TONES[random.rand(TONES.length)]} formuliert."
    end

    # Multi-line, with two variables and a blank line between the blocks — the
    # shape prompts actually have. A one-line body would make every stored text
    # about the same length and the index far smaller than a real one.
    def body_for(task, index, random)
      subject = SUBJECTS[random.rand(SUBJECTS.length)]
      <<~BODY
        Du schreibst einen #{task} zum Thema {{thema}}.

        Zielgruppe: {{zielgruppe}}. Fachgebiet: #{subject}.
        Halte dich an #{TONES[random.rand(TONES.length)]}e Formulierungen und
        gliedere den Text in Abschnitte mit Zwischenüberschriften.

        Vermeide Füllwörter. Nenne am Ende drei Prüffragen zur Qualitätssicherung.
        Bezugsnummer #{index}.
      BODY
    end

    # The same two variables everywhere: they are not what is being measured,
    # and varying them would only make the corpus harder to describe.
    VARIABLES = [
      { 'key' => 'thema', 'label' => 'Thema', 'type' => 'text', 'required' => true },
      { 'key' => 'zielgruppe', 'label' => 'Zielgruppe', 'type' => 'select',
        'options' => AUDIENCES, 'default_value' => 'Einsteiger' }
    ].freeze

    # About a quarter is private and therefore invisible to the measuring
    # account. Without that share the permission filter of FA-507 would have
    # nothing to exclude, and the measured query would be a simpler one than
    # the application ever runs.
    def visibility_for(random)
      case random.rand(4)
      when 0 then 'private'
      when 1 then 'instance'
      else 'workspace'
      end
    end

    def status_for(random)
      case random.rand(10)
      when 0 then 'draft'
      when 1 then 'archived'
      else 'active'
      end
    end

    def tags_for(random)
      TAGS.sample(random.rand(1..3), random: random)
    end
  end
end
