# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'time'

require_relative 'accounts'
require_relative 'audit'
require_relative 'transfer'
require_relative 'workspaces'

module PromptAtelier
  # Moving a whole instance to another one (FA-804a, 18.5).
  #
  # Deliberately **not** available in the browser. An instance administrator
  # reads no foreign prompt content (6.2); a button that hands him everything
  # would undo that promise more quietly than any other route — no membership,
  # no visible act. So this is a thing the operator does **on the machine**,
  # like `reset_admin_password` (BT-13).
  #
  # Three rules shape the format, and each of them is a refusal to promise
  # something a script cannot keep:
  #
  #   * **No password hashes.** A file that carries credentials gets copied
  #     around and stays on three laptops. Accounts arrive without one; each
  #     gets a one-time password the script prints once.
  #   * **No audit log.** Another instance's entries in your log would be a
  #     fiction. The import writes one entry about itself instead.
  #   * **Into an empty instance only.** Merging asks questions no script can
  #     answer — is "Marketing" here the same workspace as there, is the same
  #     address the same person? Merging is what the per-workspace import is
  #     for (FA-802), and there a human stands next to it.
  module Relocation
    FORMAT  = 'promptatelier-instance'
    VERSION = 1

    INITIAL_PASSWORD_BYTES = 20

    class Refused < StandardError; end

    class << self
      # --- export -----------------------------------------------------------

      def export(db, now: Time.now)
        {
          'format' => FORMAT,
          'version' => VERSION,
          'exported_at' => now.iso8601,
          'users' => exported_users(db),
          'workspaces' => exported_workspaces(db)
        }
      end

      # Name, address and the instance flag — enough to recreate the person,
      # nothing that would let anybody sign in as them.
      def exported_users(db)
        db[:users].order(:email).all.map do |user|
          {
            'email' => user[:email],
            'name' => user[:name],
            'is_instance_admin' => user[:is_instance_admin] == true,
            'status' => user[:status]
          }
        end
      end

      # The personal workspaces are left out: they belong to an account and
      # are created with it (FA-602). Exporting them would produce a second
      # personal workspace for everybody on the other side.
      def exported_workspaces(db)
        db[:workspaces].where(is_personal: false).order(:name).all.map do |workspace|
          Transfer.export(db, workspace_id: workspace[:id]).merge(
            'name' => workspace[:name],
            'members' => exported_members(db, workspace[:id])
          )
        end
      end

      def exported_members(db, workspace_id)
        db[:memberships].join(:users, id: :user_id)
                        .where(Sequel[:memberships][:workspace_id] => workspace_id)
                        .select(Sequel[:users][:email], Sequel[:memberships][:role])
                        .order(Sequel[:users][:email]).all
                        .map { |row| { 'email' => row[:email], 'role' => row[:role] } }
      end

      # --- import -----------------------------------------------------------

      # Returns the accounts that were created together with their one-time
      # passwords — printed once by the caller and stored nowhere in readable
      # form, exactly as FA-901 does it.
      def import(db, package, actor_name: nil, now: Time.now)
        check_format!(package)
        check_empty!(db)

        created = nil
        db.transaction do
          created = create_users(db, package['users'], now)
          create_workspaces(db, package['workspaces'], now)
          Audit.record(db, 'import.completed', now: now,
                           meta: { users: created.size,
                                   workspaces: Array(package['workspaces']).size,
                                   from: package['exported_at'], by: actor_name })
        end

        created
      end

      def check_format!(package)
        raise Refused, :not_an_instance_export unless package.is_a?(Hash) && package['format'] == FORMAT
        raise Refused, :unsupported_version unless package['version'].to_i == VERSION
        raise Refused, :no_users if Array(package['users']).empty?
      end

      # The one precondition, and the reason it is a refusal rather than a
      # merge: with content already present, every collision becomes a
      # question about identity that a script would have to guess at.
      def check_empty!(db)
        raise Refused, :instance_not_empty if db[:users].count.positive?
      end

      def create_users(db, users, now)
        Array(users).map do |entry|
          password = SecureRandom.alphanumeric(INITIAL_PASSWORD_BYTES)
          account = Accounts.create(
            db, name: entry['name'], email: entry['email'], password: password,
                must_change_password: true, instance_admin: entry['is_instance_admin'] == true,
                now: now
          )
          # A locked account stays locked: whoever was shut out on the old
          # instance should not walk in through the move.
          db[:users].where(id: account[:id]).update(status: 'locked') if entry['status'] == 'locked'

          { 'email' => account[:email], 'password' => password }
        end
      end

      def create_workspaces(db, workspaces, now)
        Array(workspaces).each do |entry|
          owner = owner_of(db, entry)
          workspace_id = Workspaces.create(db, name: entry['name'], owner_id: owner[:id], now: now)

          add_members(db, workspace_id, entry['members'], owner, now)
          # The prompts travel through the ordinary import, so there is one
          # definition of what a prompt file means (FA-802) — and the
          # collision handling is unreachable here anyway: the instance was
          # empty a moment ago.
          Transfer.import(db, workspace_id: workspace_id, owner_id: owner[:id],
                             package: entry, now: now)
        end
      end

      # The first owner named in the file, or the first administrator. A
      # workspace without an owner cannot be created, and guessing "whoever
      # comes first" would hand somebody a workspace they never had.
      def owner_of(db, entry)
        email = Array(entry['members']).find { |member| member['role'] == 'owner' }&.dig('email')
        found = email && db[:users].where(Sequel.function(:lower, :email) => email.to_s.downcase).first

        found || db[:users].where(is_instance_admin: true).first || db[:users].first
      end

      def add_members(db, workspace_id, members, owner, now)
        Array(members).each do |member|
          user = db[:users].where(Sequel.function(:lower, :email) => member['email'].to_s.downcase).first
          next if user.nil? || user[:id] == owner[:id]

          Workspaces.add_member(db, workspace_id, user[:id], member['role'], now: now)
        end
      end
    end
  end
end
