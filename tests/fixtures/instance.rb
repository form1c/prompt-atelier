# frozen_string_literal: true

require 'services/password'
require 'services/workspaces'

module PromptAtelier
  # The starting state from test concept 4.1 to 4.3.
  #
  # Built per test case, never once per run. Several cases destroy what others
  # depend on — TF-205 deletes the workspace *Marketing* in its last line,
  # TF-206 moves ownership, TF-207 moves the instance administrator flag. With
  # a shared state every later result would depend on execution order, and a
  # green run would prove nothing (test concept 4).
  #
  # Returns a hash of names to ids, so a test reads as the document does:
  # people by name, prompts by their label from 4.3.
  module Fixture
    PASSWORD = 'Testpasswort-2026!'

    # Hashing six passwords with Argon2 costs about a second per test case.
    # The hash is identical for all of them, so it is computed once for the
    # whole run — the passwords are not what these tests are about.
    def self.password_hash
      @password_hash ||= Password.create(PASSWORD)
    end

    PEOPLE = {
      thomas: { email: 'admin@test',  name: 'Thomas', instance_admin: true },
      sabine: { email: 'owner@test',  name: 'Sabine' },
      anna:   { email: 'wsadmin@test', name: 'Anna' },
      martin: { email: 'editor@test', name: 'Martin' },
      lisa:   { email: 'viewer@test', name: 'Lisa' },
      joerg:  { email: 'fremd@test',  name: 'Jörg' }
    }.freeze

    MARKETING_ROLES = { sabine: 'owner', anna: 'admin', martin: 'editor', lisa: 'viewer' }.freeze

    def self.build(db, now: Time.now)
      ids = { users: {}, workspaces: {}, prompts: {} }

      PEOPLE.each do |key, person|
        ids[:users][key] = db[:users].insert(
          email: person[:email], name: person[:name], password_hash: password_hash,
          is_instance_admin: person.fetch(:instance_admin, false), status: 'active',
          created_at: now, updated_at: now
        )
        ids[:workspaces][:"personal_#{key}"] =
          Workspaces.create_personal(db, db[:users][id: ids[:users][key]], now: now)
      end

      marketing = Workspaces.create(db, name: 'Marketing', owner_id: ids[:users][:sabine], now: now)
      ids[:workspaces][:marketing] = marketing
      MARKETING_ROLES.each do |key, role|
        next if role == 'owner'

        Workspaces.add_member(db, marketing, ids[:users][key], role, now: now)
      end

      seed_prompts(db, ids, marketing, now)
      ids
    end

    # The prompts of 4.3. Only the fields the permission checks depend on are
    # filled — variables, tags and keywords belong to AP-07 and AP-08.
    def self.seed_prompts(db, ids, marketing, now)
      users = ids[:users]

      # The last column is who deleted it. `deleted_by` is kept beside
      # `owner_id` because the two come apart (FA-703), and a deleted row
      # without it is a state the application cannot produce: every path into
      # the trash goes through `Prompts.move_to_trash`, which always records
      # the actor. Leaving it empty here made the fixture the only place where
      # a prompt lay in the trash with nobody having put it there — and a
      # screen reading the deleting user off it would have shown a blank.
      {
        'P-PRIV-S' => [marketing, :sabine, 'private',   'active',   nil, nil],
        'P-WS'     => [marketing, :sabine, 'workspace', 'active',   nil, nil],
        'P-INST'   => [marketing, :sabine, 'instance',  'active',   nil, nil],
        'P-EDIT'   => [marketing, :martin, 'workspace', 'active',   nil, nil],
        'P-DRAFT'  => [marketing, :martin, 'private',   'draft',    nil, nil],
        'P-ARCH'   => [marketing, :sabine, 'workspace', 'archived', nil, nil],
        'P-DEL'    => [marketing, :martin, 'workspace', 'active',   now, :martin],
        'P-PLAIN'  => [marketing, :sabine, 'workspace', 'active',   nil, nil],
        'P-JOERG'  => [ids[:workspaces][:personal_joerg], :joerg, 'private', 'active', nil, nil]
      }.each do |label, (workspace, owner, visibility, status, deleted, deleted_by)|
        ids[:prompts][label] = db[:prompts].insert(
          workspace_id: workspace, owner_id: users[owner], title: label,
          body: body_for(label), visibility: visibility, status: status,
          deleted_at: deleted, deleted_by: users[deleted_by],
          created_at: now, updated_at: now
        )
      end
    end

    # P-PRIV-S carries the marker from TF-203: the search must not find it for
    # anyone but Sabine, and a unique string is the only way to tell a correct
    # empty result from an accidental one.
    def self.body_for(label)
      return 'Zitronenfalter-Geheimnis — nur für Sabine.' if label == 'P-PRIV-S'

      "Schreibe einen Blogartikel über {{thema}} für {{zielgruppe}}. (#{label})"
    end
  end
end
