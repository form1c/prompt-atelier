# frozen_string_literal: true

require 'sinatra/base'
require 'json'
require 'date'
require 'time'
require 'securerandom'

require_relative 'services/i18n'
require_relative 'services/configuration'
require_relative 'services/database'
require_relative 'services/migrator'
require_relative 'services/schema_guard'
require_relative 'services/password'
require_relative 'services/sessions'
require_relative 'services/rate_limit'
require_relative 'services/audit'
require_relative 'services/authentication'
require_relative 'services/access'
require_relative 'services/workspaces'
require_relative 'services/prompts'
require_relative 'services/bulk'
require_relative 'services/search'
require_relative 'services/catalog'
require_relative 'services/transfer'
require_relative 'services/accounts'
require_relative 'services/registration'
require_relative 'services/settings'
require_relative 'services/retention'
require_relative 'services/trusted_proxy'
require_relative 'version'

module PromptAtelier
  # The application as a pure JSON API (E-02).
  class App < Sinatra::Base
    # --- Base settings ---------------------------------------------------

    # Where the built interface lies in a delivered installation: beside the
    # application, as `app/public/` (18.2). Named rather than written twice,
    # because `reset!` has to be able to put it back — a test that boots with
    # an interface of its own would otherwise leave the setting pointing at a
    # directory it has just deleted, and the next suite in the same process
    # would fail for a reason that has nothing to do with it.
    DEFAULT_INTERFACE_ROOT = File.expand_path('public', __dir__)

    configure do
      set :root,          File.expand_path(__dir__)
      set :public_folder, DEFAULT_INTERFACE_ROOT
      set :static,        true
      set :default_content_type, 'application/json'

      # SEC-13: never leak stack traces or paths to the client.
      set :show_exceptions, false
      set :dump_errors,     false
      set :raise_errors,    false

      disable :logging
    end

    API_PREFIX = '/api/v1'

    # SEC-05: only these methods require a CSRF token. A GET that changes
    # something would be a bug of its own.
    WRITING_METHODS = %w[POST PUT PATCH DELETE].freeze

    # SEC-11. No unsafe-inline and no unsafe-eval — Vite's production build
    # needs neither, and allowing them would make the policy decorative.
    CONTENT_SECURITY_POLICY = [
      "default-src 'self'",
      "script-src 'self'",
      "style-src 'self'",
      "img-src 'self' data:",
      "font-src 'self'",
      "connect-src 'self'",
      "object-src 'none'",
      "frame-ancestors 'none'",
      "base-uri 'self'",
      "form-action 'self'"
    ].join('; ').freeze

    # --- Boot ------------------------------------------------------------

    class << self
      attr_accessor :configuration, :schema_version, :last_sweep

      # +interface_root+ moves the directory the built interface is served
      # from. The delivered installation needs nothing here — `app/public/` is
      # beside the application. The browser tests build outside the source
      # tree, because `backend/public/` is where a real build lands and a test
      # run must not overwrite it; they point this at their own directory and
      # are then served by exactly the code an installed instance runs.
      def boot!(root:, interface_root: nil)
        self.configuration = Configuration.load(root: root)

        # **A connection from a previous life is dropped here** (AP-21).
        #
        # `database` is memoised, and it used to survive a second `boot!`. The
        # new configuration then said one thing and every write went somewhere
        # else — measured: booted at A, booted again at B, and `database.opts`
        # still named A while `configuration.database_path` named B.
        #
        # In production this never bit, because `boot!` runs once. In a test
        # process it is the difference between an assertion about the
        # application and an assertion about nothing: the fixture writes the
        # same ids into every installation, so a sign-in succeeds, a deletion
        # reports 200, and the row the test looks at is untouched — because it
        # was never the row the application had.
        drop_stale_connection

        I18n.default_language = configuration['locale']
        self.schema_version = SchemaGuard.check!(migrator)
        set :public_folder, File.expand_path(interface_root) if interface_root
        configuration
      end

      def migrator
        Migrator.new(
          database_path:  configuration.database_path,
          migrations_dir: File.expand_path('migrations', __dir__),
          backup_dir:     File.join(File.dirname(configuration.database_path), 'backups')
        )
      end

      # One connection for the process, opened on first use. Sequel keeps its
      # own pool behind it; opening a fresh connection per request would pay
      # the pragma setup every time.
      def database
        @database ||= Database.connect(configuration.database_path,
                                       wal: configuration['database.wal'] != false)
      end

      # Only when it really is stale. Reconnecting on every boot would throw
      # away a healthy pool for nothing, and `boot!` is also called to reload
      # a configuration that points at the same file.
      def drop_stale_connection
        return if @database.nil?
        return if @database.opts[:database] == configuration.database_path

        @database.disconnect
        @database = nil
      end

      def reset!
        set :public_folder, DEFAULT_INTERFACE_ROOT
        @database&.disconnect
        @database = nil
        self.configuration = nil
        self.schema_version = nil
        self.last_sweep = nil
        # The settings are cached per process; a test that starts over with a
        # different database must not inherit the previous one's values.
        Settings.forget!
      end
    end

    # --- Every request ---------------------------------------------------

    before do
      # NFA-16 wants an error to be traceable by timestamp, account and
      # request. The first two are to hand when something goes wrong; the third
      # has to be decided **here**, before anything can fail, or there is
      # nothing to put in the log line and nothing for the person to quote.
      assign_request_id

      # SEC-14: redirect plain HTTP to HTTPS when the instance is meant to run
      # behind TLS. Done before anything else, so no credential is read from a
      # request that should not have been answered at all.
      redirect_to_https if redirect_to_https?

      apply_security_headers
      authenticate_request

      # After the account is known, because the profile has the first say
      # (11.7), and before anything that can refuse — the CSRF check and the
      # rate limit both answer with a sentence.
      choose_language

      refresh_session_cookies if authenticated?
      enforce_csrf if writing?
      enforce_write_rate_limit if writing?
      enforce_transfer_rate_limit

      sweep_if_due
    end

    # The thread goes back into Puma's pool, and nothing on it should still be
    # holding the language of a request that is over. The `before` filter above
    # would overwrite it anyway; this is so that a background sweep or a
    # console on the same thread reads the instance default rather than
    # whatever the last visitor happened to speak.
    after do
      Thread.current[I18n::CURRENT] = nil
    end

    # --- Operational endpoints (15.3) ------------------------------------

    get '/health' do
      operational? ? json_response(200, status: 'ok') : json_response(503, status: 'error')
    end

    get '/version' do
      halt_with(401, 'unauthorized') unless authenticated?

      json_response(200, app: PromptAtelier::VERSION, schema: self.class.schema_version)
    end

    # --- Setup (FA-909) ---------------------------------------------------

    get "#{API_PREFIX}/setup/status" do
      json_response(200, setup_required: setup_required?)
    end

    # Available exactly once. Afterwards it answers 409 rather than 404: the
    # difference matters to a client that wants to know whether it arrived too
    # late or asked for something that never existed.
    post "#{API_PREFIX}/setup" do
      halt_with(409, 'setup_done') unless setup_required?

      payload = json_body
      problems = {}
      problems[:name]  = 'name_required' if payload['name'].to_s.strip.empty?
      problems[:email] = 'email_invalid' unless valid_email?(payload['email'])

      violations = Password.policy_violations(payload['password'])
      problems[:password] = violations.first unless violations.empty?

      halt_validation(problems) unless problems.empty?

      # FA-602 is part of creating an account, not of this endpoint — see
      # Accounts.create, which the three paths that make accounts all use.
      user = Accounts.create(db, name: payload['name'], email: payload['email'],
                                 password: payload['password'], instance_admin: true)
      Audit.record(db, Audit::SETUP_COMPLETED, actor: user, target_type: 'user',
                   target_id: user[:id], ip: client_ip)

      start_session(user)
      json_response(201, user: public_user(user))
    end

    # --- Registration (FA-107) ---------------------------------------------

    # Asked by the login screen before it decides whether to offer a way in.
    # Public on purpose: it says what the screen is about to show anyway, and
    # nothing about who exists.
    get "#{API_PREFIX}/auth/registration" do
      json_response(200, registration: {
                      enabled: Registration.enabled?(effective_config),
                      approval_required: Registration.approval_required?(effective_config)
                    })
    end

    post "#{API_PREFIX}/auth/register" do
      payload = json_body
      problems = {}
      problems[:name]  = 'name_required' if payload['name'].to_s.strip.empty?
      problems[:email] = 'email_invalid' unless valid_email?(payload['email'])
      # Answered honestly, and that is a decision rather than an oversight: it
      # does tell a stranger that an address is in use. The alternative — the
      # usual "we have sent you an e-mail" — is a sentence this application
      # cannot make true (E-13), so an honest person whose address is already
      # registered would be left with a form that appears to work and never
      # does. What limits the enumeration instead is the hourly cap per
      # address in Registration.
      if problems[:email].nil? && address_taken?(payload['email'])
        problems[:email] = 'email_taken'
      end

      violations = Password.policy_violations(payload['password'])
      problems[:password] = violations.first unless violations.empty?

      halt_validation(problems) unless problems.empty?

      user = with_account_refusal do
        Registration.register(db, name: payload['name'], email: payload['email'],
                                  password: payload['password'], ip: client_ip,
                                  config: effective_config)
      end

      # Whoever is let in straight away is signed in straight away; whoever has
      # to wait is not signed in at all and is told so. Handing out a session
      # that every following call would refuse would be the worse of the two.
      if Accounts.pending?(user)
        json_response(201, pending: true, code: 'registered_pending')
      else
        start_session(user)
        json_response(201, pending: false, user: public_user(user))
      end
    end

    # --- Authentication (15.3) --------------------------------------------

    post "#{API_PREFIX}/auth/login" do
      payload = json_body
      result = Authentication.log_in(
        db,
        email: payload['email'], password: payload['password'],
        ip: client_ip, user_agent: request.user_agent,
        config: effective_config
      )

      # One status and one code for every failure. Distinguishing them here
      # would undo what Authentication is careful to hide — SEC-07 keeps
      # "no such account" and "wrong password" indistinguishable.
      unless result.success?
        halt_with(401, result.error[:code], **result.error.fetch(:params, {}))
      end

      start_session(result.user, token: result.token)
      json_response(200, user: public_user(result.user))
    end

    post "#{API_PREFIX}/auth/logout" do
      Authentication.log_out(db, session_token, actor: current_user, ip: client_ip)
      clear_session_cookies
      json_response(200, status: 'ok')
    end

    get "#{API_PREFIX}/auth/me" do
      halt_with(401, 'unauthorized') unless authenticated?

      json_response(200, user: public_user(current_user))
    end

    post "#{API_PREFIX}/auth/password" do
      halt_with(401, 'unauthorized') unless authenticated?

      payload = json_body
      result = Authentication.change_password(
        db, user: current_user, current: payload['current_password'],
            replacement: payload['new_password'], token: session_token, ip: client_ip
      )
      halt_validation({ password: result.error }) unless result.success?

      json_response(200, status: 'ok', code: 'password_changed')
    end

    # FA-106. The address stays unique across the instance; changing it does
    # **not** discard the sessions, because it does not hand access to anybody
    # else — unlike a password change (SEC-15).
    put "#{API_PREFIX}/auth/me" do
      require_authentication!

      payload = json_body
      problems = {}
      problems[:name] = 'name_required' if payload['name'].to_s.strip.empty?
      # The format is checked on a **changed** address only. `valid_email?`
      # insists on a dot in the domain, so an account carrying `chef@intranet`
      # — put there by an import or straight into the database — could never
      # save its profile again, not even to change nothing but the name. The
      # check exists to keep new bad addresses out, not to trap people behind
      # one they already have.
      if changed_address?(payload['email'])
        problems[:email] = 'email_invalid' unless valid_email?(payload['email'])
        if problems[:email].nil? && taken_by_somebody_else?(payload['email'])
          problems[:email] = 'email_taken'
        end
      end
      halt_validation(problems) unless problems.empty?

      # Recorded because an address change is a change of who signs in. SEC-09
      # names a lower bound and this was not on it, so nothing wrote it down —
      # and a stolen session that quietly moves the login to another address
      # would have left no trace at all. The old address is in the entry; the
      # new one is in the account.
      address_moved = changed_address?(payload['email'])

      db[:users].where(id: current_user[:id]).update(
        name: payload['name'].to_s.strip, email: payload['email'].to_s.strip,
        locale: chosen_locale(payload), updated_at: Time.now
      )
      Audit.record(db, Audit::PROFILE_CHANGED, actor: current_user, target_type: 'user',
                   target_id: current_user[:id], ip: client_ip,
                   meta: address_moved ? { previous_email: current_user[:email] } : nil)

      json_response(200, user: public_user(db[:users][id: current_user[:id]]))
    end

    # SEC-18. In the user's own profile and **not** through an administrator:
    # chapter 6.2 says an instance administrator sees no foreign content, and
    # an administrative disclosure endpoint would undo that in one line.
    get "#{API_PREFIX}/auth/me/data-export" do
      require_authentication!

      Audit.record(db, 'self_disclosure.requested', actor: current_user, target_type: 'user',
                   target_id: current_user[:id], ip: client_ip)

      json_response(200, disclosure: self_disclosure)
    end

    # --- Workspaces (15.3, FA-601 to FA-608) -------------------------------

    get "#{API_PREFIX}/workspaces" do
      require_authentication!

      json_response(200, workspaces: Workspaces.for_user(db, current_user[:id]).map { |row| public_workspace(row) },
                         selected_workspace_id: Workspaces.selected_for(db, current_user))
    end

    # FA-605: which workspace someone last worked in is kept on the server,
    # not in the browser. TF-308f is the reason — signing in on a second
    # device has to land in the same place, and localStorage cannot do that.
    put "#{API_PREFIX}/workspaces/selection" do
      require_authentication!
      workspace_id = json_body['workspace_id'].to_i
      authorize!(Access.for_workspace(db, current_user, workspace_id, 'prompt.read'))

      db[:users].where(id: current_user[:id]).update(last_workspace_id: workspace_id, updated_at: Time.now)
      json_response(200, selected_workspace_id: workspace_id)
    end

    post "#{API_PREFIX}/workspaces" do
      require_authentication!

      id = with_refusal { Workspaces.create(db, name: json_body['name'], owner_id: current_user[:id]) }
      Audit.record(db, 'workspace.created', actor: current_user,
                   target_type: 'workspace', target_id: id, ip: client_ip)

      json_response(201, workspace: public_workspace(db[:workspaces][id: id].merge(role: 'owner')))
    end

    put "#{API_PREFIX}/workspaces/:id" do
      workspace = authorized_workspace('workspace.rename')

      with_refusal { Workspaces.rename(db, workspace[:id], json_body['name']) }
      Audit.record(db, 'workspace.renamed', actor: current_user,
                   target_type: 'workspace', target_id: workspace[:id], ip: client_ip)

      # With the caller's role, so the answer looks like the entries of
      # GET /workspaces and the screen can put it in their place. Without it
      # the renamed workspace would come back stripped of its permissions and
      # the buttons that were there a moment ago would disappear.
      json_response(200, workspace: public_workspace(with_role(db[:workspaces][id: workspace[:id]])))
    end

    delete "#{API_PREFIX}/workspaces/:id" do
      workspace = authorized_workspace('workspace.delete')

      with_refusal { Workspaces.delete(db, workspace[:id], confirmation: json_body_if_any['confirm_name']) }
      Audit.record(db, 'workspace.deleted', actor: current_user,
                   target_type: 'workspace', target_id: workspace[:id], ip: client_ip)

      json_response(200, status: 'ok')
    end

    # --- Members (FA-603) ---------------------------------------------------

    # Reading the member list is an administrative action, so it takes the same
    # permission as changing it. Someone with no relationship to the workspace
    # gets 404 rather than 403 — otherwise the endpoint would answer "does
    # workspace 47 exist?" for anyone who cares to count upwards.
    get "#{API_PREFIX}/workspaces/:id/members" do
      workspace = authorized_workspace('member.manage')

      json_response(200, members: Workspaces.members(db, workspace[:id]))
    end

    # The body names the account either by `user_id` or by `email`; see
    # Workspaces.resolve_member for why the address is the one a screen uses.
    post "#{API_PREFIX}/workspaces/:id/members" do
      workspace = authorized_workspace('member.manage')
      payload = json_body
      authorize_owner_grant!(workspace, payload['role'])

      user_id = with_refusal do
        Workspaces.resolve_member(db, user_id: payload['user_id'], email: payload['email'])
      end
      with_refusal { Workspaces.add_member(db, workspace[:id], user_id, payload['role']) }
      record_membership_change('membership.added', workspace, user_id, payload['role'])

      json_response(201, members: Workspaces.members(db, workspace[:id]))
    end

    put "#{API_PREFIX}/workspaces/:id/members/:uid" do
      workspace = authorized_workspace('member.manage')
      payload = json_body
      authorize_owner_grant!(workspace, payload['role'])

      with_refusal { Workspaces.change_role(db, workspace[:id], params['uid'].to_i, payload['role']) }
      record_membership_change('membership.role_changed', workspace, params['uid'], payload['role'])

      json_response(200, members: Workspaces.members(db, workspace[:id]))
    end

    delete "#{API_PREFIX}/workspaces/:id/members/:uid" do
      workspace = authorized_workspace('member.manage')

      with_refusal { Workspaces.remove_member(db, workspace[:id], params['uid'].to_i) }
      record_membership_change('membership.removed', workspace, params['uid'], nil)

      json_response(200, members: Workspaces.members(db, workspace[:id]))
    end

    # --- Prompts (15.3, FA-201 to FA-207, FA-3xx, FA-7xx) -------------------

    # Workspace-bound list calls demand ?workspace_id= (15.1). Without it the
    # server would have to guess a scope, and guessing is how a query ends up
    # reaching further than the caller may see.
    # The library and the search are one endpoint (15.3). Without a term it
    # lists, with one it searches — the filters, the sort and the paging work
    # the same either way, and the visibility rule is applied inside the query
    # for both (FA-501, FA-502, FA-504, FA-506, FA-507, FA-509).
    get "#{API_PREFIX}/prompts" do
      scope = prompt_scope
      page, per_page = paging

      rows  = Search.find(db, **library_query(scope), sort: params['sort'],
                              limit: per_page, offset: (page - 1) * per_page)
      total = Search.count(db, **library_query(scope))

      json_response(200, prompts: prompt_summaries(rows),
                         meta: { total: total, page: page, per_page: per_page })
    end

    # --- acting on many at once (FA-511, FA-703a) ---------------------------
    #
    # **One call, not a loop in the browser**, and the first of three reasons
    # decides it on its own: SEC-19 allows 120 writing calls per minute and
    # session. Five hundred single calls would run into `429` partway through,
    # leaving half the selection moved and no report saying where it stopped.
    #
    # The other two: the split into "done" and "refused with a reason" arises
    # where the permission check already happens, instead of being a second and
    # differing reading of the same rules in the interface — and every id is
    # checked **individually** against chapter 6.2, with one uniform answer for
    # foreign and non-existent alike.
    #
    # These four sit **above** `/prompts/:id`, because `bulk` would otherwise
    # be read as an id and every call would end in "prompt 0 not found".

    # The identifiers of a whole result list, for the second control of FA-510
    # ("alle 1.717 Treffer auswählen").
    #
    # Its own endpoint rather than the library with a bigger page: 15.1 caps a
    # page at 200 deliberately, and raising that would mean sending seventeen
    # hundred full prompt rows — titles, descriptions, tags, highlights — in
    # order to arrive at seventeen hundred integers. This answers with the
    # integers.
    #
    # The same visibility rule as the library itself (FA-507), because it is
    # the same query: what cannot be listed cannot be selected either.
    get "#{API_PREFIX}/prompts/ids" do
      scope = prompt_scope

      rows = Search.find(db, **library_query(scope), sort: params['sort'],
                             limit: Bulk::MAX_IDS, offset: 0)
      json_response(200, ids: rows.map { |row| row[:id] }, limit: Bulk::MAX_IDS)
    end

    post "#{API_PREFIX}/prompts/bulk/move" do
      ids = bulk_ids
      target = json_body['workspace_id'].to_i
      authorize!(Access.for_target_workspace(db, current_user, target))

      bulk_response(Bulk.move(db, current_user, ids, target_workspace_id: target))
    end

    post "#{API_PREFIX}/prompts/bulk/trash" do
      ids = bulk_ids

      bulk_response(Bulk.trash(db, current_user, ids, actor_id: current_user[:id]))
    end

    post "#{API_PREFIX}/trash/bulk/restore" do
      ids = bulk_ids

      bulk_response(Bulk.restore(db, current_user, ids))
    end

    post "#{API_PREFIX}/trash/bulk/purge" do
      ids = bulk_ids

      bulk_response(Bulk.purge(db, current_user, ids, ip: client_ip))
    end

    post "#{API_PREFIX}/prompts" do
      workspace_id = required_workspace_id(json_body['workspace_id'])
      authorize!(Access.for_workspace(db, current_user, workspace_id, 'prompt.create'))

      id = with_prompt_refusal do
        Prompts.create(db, workspace_id: workspace_id, owner_id: current_user[:id], attributes: json_body)
      end
      json_response(201, prompt: public_prompt(db, db[:prompts][id: id]))
    end

    get "#{API_PREFIX}/prompts/:id" do
      prompt = authorized_prompt('prompt.read')

      json_response(200, prompt: public_prompt(db, prompt, full: true))
    end

    put "#{API_PREFIX}/prompts/:id" do
      prompt = authorized_prompt('prompt.update')

      with_prompt_refusal { Prompts.update(db, prompt, attributes: json_body, actor_id: current_user[:id]) }
      json_response(200, prompt: public_prompt(db, db[:prompts][id: prompt[:id]], full: true))
    end

    delete "#{API_PREFIX}/prompts/:id" do
      prompt = authorized_prompt('prompt.delete')

      Prompts.move_to_trash(db, prompt, actor_id: current_user[:id])
      json_response(200, status: 'ok')
    end

    post "#{API_PREFIX}/prompts/:id/undo" do
      prompt = authorized_prompt('prompt.update')

      restored = with_prompt_refusal { Prompts.undo(db, prompt, actor_id: current_user[:id]) }
      json_response(200, prompt: public_prompt(db, restored, full: true))
    end

    # The target decides, and it answers 403 whether it is foreign, forbidden
    # or not there at all — see Access.for_target_workspace.
    post "#{API_PREFIX}/prompts/:id/duplicate" do
      prompt = authorized_prompt('prompt.duplicate')
      target = json_body['workspace_id'].to_i
      authorize!(Access.for_target_workspace(db, current_user, target))

      id, dropped = with_prompt_refusal do
        Prompts.duplicate(db, prompt, target_workspace_id: target, actor_id: current_user[:id])
      end
      json_response(201, prompt: public_prompt(db, db[:prompts][id: id], full: true),
                         dropped_keywords: dropped)
    end

    post "#{API_PREFIX}/prompts/:id/move" do
      prompt = authorized_prompt('prompt.move')
      target = json_body['workspace_id'].to_i
      authorize!(Access.for_target_workspace(db, current_user, target))

      result = with_prompt_refusal { Prompts.move(db, prompt, target_workspace_id: target) }
      json_response(200, prompt: public_prompt(db, result[:prompt], full: true),
                         visibility_reset: result[:visibility_reset],
                         dropped_keywords: result[:dropped_keywords])
    end

    post "#{API_PREFIX}/prompts/:id/render" do
      prompt = authorized_prompt('prompt.render')
      payload = json_body

      result = with_prompt_refusal do
        keywords = Prompts.permitted_keywords(db, prompt, payload['keyword_ids'],
                                              Access.workspace_ids(db, current_user[:id]))
        Prompts.render(db, prompt, values: (payload['values'] || {}), keywords: keywords)
      end

      json_response(200, text: result.text, unknown_keys: result.unknown_keys,
                         rejected_keys: result.rejected_keys,
                         missing_required: result.missing_required, complete: result.complete?)
    end

    # FA-505: a favourite belongs to the person, not to the prompt. Storing it
    # on the prompt would let members overwrite each other's.
    post "#{API_PREFIX}/prompts/:id/favorite" do
      prompt = authorized_prompt('prompt.favorite')

      unless db[:favorites].where(user_id: current_user[:id], prompt_id: prompt[:id]).count.positive?
        db[:favorites].insert(user_id: current_user[:id], prompt_id: prompt[:id], created_at: Time.now)
      end
      json_response(200, favorite: true)
    end

    delete "#{API_PREFIX}/prompts/:id/favorite" do
      prompt = authorized_prompt('prompt.favorite')

      db[:favorites].where(user_id: current_user[:id], prompt_id: prompt[:id]).delete
      json_response(200, favorite: false)
    end

    # --- Trash (FA-703) -----------------------------------------------------

    get "#{API_PREFIX}/trash" do
      workspace_id = required_workspace_id
      authorize!(Access.for_workspace(db, current_user, workspace_id, 'trash.view'))

      rows = Prompts.trash_for(db, workspace_id, current_user[:id],
                               Access.membership_role(db, workspace_id, current_user[:id]))
      json_response(200, prompts: trash_entries(rows))
    end

    post "#{API_PREFIX}/trash/:id/restore" do
      prompt = authorized_prompt('trash.restore', deleted: true)

      Prompts.restore(db, prompt)
      json_response(200, prompt: public_prompt(db, db[:prompts][id: prompt[:id]], full: true))
    end

    delete "#{API_PREFIX}/trash/:id" do
      prompt = authorized_prompt('trash.purge', deleted: true)

      Prompts.purge(db, prompt)
      Audit.record(db, 'prompt.purged', actor: current_user, target_type: 'prompt',
                   target_id: prompt[:id], ip: client_ip)
      json_response(200, status: 'ok')
    end

    # --- Import and export (15.3, FA-801 to FA-804) --------------------------

    # The scope follows the verdict, not the request: `:allow_own_only` is the
    # ◐ of the matrix, and it means the file holds this person's own prompts
    # (FA-801). Deciding it here rather than from a parameter is the point —
    # a client that asked for the whole workspace would otherwise get it.
    post "#{API_PREFIX}/export" do
      workspace_id = required_workspace_id(json_body['workspace_id'])
      verdict = authorize!(Access.for_workspace(db, current_user, workspace_id, 'prompt.export'))
      mine = verdict == :allow_own_only ? current_user[:id] : nil
      chosen = json_body['prompt_ids']

      Audit.record(db, 'prompt.exported', actor: current_user, target_type: 'workspace',
                   target_id: workspace_id, ip: client_ip)

      if json_body['format'].to_s == 'markdown'
        files = Transfer.export_markdown(db, workspace_id: workspace_id, owner_id: mine, prompt_ids: chosen)
        json_response(200, format: 'markdown', files: files)
      else
        package = Transfer.export(db, workspace_id: workspace_id, owner_id: mine, prompt_ids: chosen)
        # The name is decided here for the same reason the Markdown file names
        # are: it follows the slug rule of 14.2, which is the normalisation of
        # FA-501. A browser building it from the workspace name would be a
        # second implementation of that rule.
        json_response(200, format: 'json', filename: Transfer.export_filename(package), package: package)
      end
    end

    # W-8: nothing is written here, and the screen cannot skip it — the import
    # below runs the very same plan again and refuses a decision the plan does
    # not offer.
    post "#{API_PREFIX}/import/preview" do
      workspace_id, package = import_request

      json_response(200, preview: Transfer.preview(db, workspace_id: workspace_id, package: package))
    end

    post "#{API_PREFIX}/import" do
      workspace_id, package = import_request

      report = with_transfer_refusal do
        Transfer.import(db, workspace_id: workspace_id, owner_id: current_user[:id],
                            package: package, decisions: json_body['decisions'] || {},
                            keyword_decisions: json_body['keyword_decisions'] || {})
      end
      # SEC-09 names the import by name. The export is logged too, although
      # the list does not demand it: it carries the entire content of a
      # workspace out of the instance, which is exactly the event an operator
      # wants to be able to look up afterwards. The list is a lower bound.
      Audit.record(db, 'import.completed', actor: current_user, target_type: 'workspace',
                   target_id: workspace_id, ip: client_ip,
                   meta: { created: report['created'].size, overwritten: report['overwritten'].size,
                           skipped: report['skipped'].size,
                           keywords_created: report['keywords_created'].size,
                           keywords_overwritten: report['keywords_overwritten'].size })

      json_response(200, report: report)
    end

    # --- Tags and keywords (15.3, FA-401 to FA-404, FA-503) ------------------

    get "#{API_PREFIX}/tags" do
      workspace_id = authorized_catalog_workspace('prompt.read')

      json_response(200, tags: Catalog.tags(db, workspace_id))
    end

    post "#{API_PREFIX}/tags" do
      workspace_id = authorized_catalog_workspace('tag.create', from_body: true)

      id = with_catalog_refusal { Catalog.create_tag(db, workspace_id, json_body['name']) }
      json_response(201, tag: db[:tags][id: id])
    end

    # TF-406: the assignments go, the prompts stay. A tag is a label, never
    # part of the content.
    delete "#{API_PREFIX}/tags/:id" do
      tag = db[:tags][id: params['id'].to_i]
      authorize!(tag.nil? ? :not_found : Access.for_workspace(db, current_user, tag[:workspace_id], 'tag.create'))

      json_response(200, removed_assignments: Catalog.delete_tag(db, tag[:id]))
    end

    get "#{API_PREFIX}/keywords" do
      workspace_id = authorized_catalog_workspace('prompt.read')

      json_response(200, keywords: Catalog.keywords(db, workspace_id))
    end

    post "#{API_PREFIX}/keywords" do
      workspace_id = authorized_catalog_workspace('keyword.write', from_body: true)

      id = with_catalog_refusal { Catalog.create_keyword(db, workspace_id, json_body) }
      json_response(201, keyword: db[:keywords][id: id])
    end

    put "#{API_PREFIX}/keywords/:id" do
      keyword = authorized_keyword

      updated = with_catalog_refusal { Catalog.update_keyword(db, keyword, json_body) }
      json_response(200, keyword: updated)
    end

    # FA-404 in two steps. Without `confirm=true` nothing is deleted and the
    # answer names the affected prompts — deleting straight away would change
    # what those prompts render, silently.
    delete "#{API_PREFIX}/keywords/:id" do
      keyword = authorized_keyword
      affected = Catalog.keyword_usage(db, keyword[:id])

      unless json_body_if_any['confirm'] == true
        halt 409, { 'content-type' => 'application/json' },
             # `confirmation_required` names the **situation**, and that is what
             # the interface branches on. The sentence with the count is built
             # there out of `affected_prompts` — it lists the prompts by name,
             # which a number never could.
             JSON.generate(error: { code: 'confirmation_required' },
                           affected_prompts: affected.map { |id, title| { id: id, title: title } })
      end

      Catalog.delete_keyword(db, keyword[:id])
      json_response(200, removed_assignments: affected.size)
    end

    # --- Instance administration (15.3) -------------------------------------

    post "#{API_PREFIX}/admin/users" do
      authorize!(Access.for_instance(current_user, 'user.manage'))

      payload = json_body
      problems = {}
      problems[:name]  = 'name_required' if payload['name'].to_s.strip.empty?
      problems[:email] = 'email_invalid' unless valid_email?(payload['email'])
      problems[:email] = 'email_taken' if address_taken?(payload['email'])
      halt_validation(problems) unless problems.empty?

      initial = SecureRandom.alphanumeric(Accounts::INITIAL_PASSWORD_BYTES)
      user = Accounts.create(db, name: payload['name'], email: payload['email'],
                                 password: initial, must_change_password: true,
                                 instance_admin: payload['is_instance_admin'] == true)
      Audit.record(db, Audit::USER_CREATED, actor: current_user, target_type: 'user',
                   target_id: user[:id], ip: client_ip)

      # Shown exactly once — it is not stored anywhere in readable form.
      json_response(201, user: public_user(user), initial_password: initial)
    end

    # FA-906. Searchable by name or address, with the two counts the deletion
    # dialogue of FA-904 will need a moment later.
    get "#{API_PREFIX}/admin/users" do
      authorize!(Access.for_instance(current_user, 'user.manage'))

      json_response(200, users: Accounts.list(db, term: params['q']))
    end

    # FA-902. The sessions go with it (SEC-15) — a lock that leaves an open
    # session running is a lock in name only.
    post "#{API_PREFIX}/admin/users/:id/lock" do
      target = admin_target_user

      with_account_refusal { Accounts.lock(db, target) }
      Audit.record(db, 'user.locked', actor: current_user, target_type: 'user',
                   target_id: target[:id], ip: client_ip)

      json_response(200, user: Accounts.public_account(db[:users][id: target[:id]]))
    end

    post "#{API_PREFIX}/admin/users/:id/unlock" do
      target = admin_target_user

      with_account_refusal { Accounts.unlock(db, target) }
      Audit.record(db, Audit::USER_UNLOCKED, actor: current_user, target_type: 'user',
                   target_id: target[:id], ip: client_ip)

      json_response(200, user: Accounts.public_account(db[:users][id: target[:id]]))
    end

    # FA-107. Its own endpoint rather than a second use of `unlock`, although
    # the row change is the same: admitting somebody for the first time and
    # lifting a lock one imposed oneself are decided on different grounds and
    # belong in the log under different names.
    post "#{API_PREFIX}/admin/users/:id/approve" do
      target = admin_target_user

      with_account_refusal { Accounts.approve(db, target) }
      Audit.record(db, Audit::USER_APPROVED, actor: current_user, target_type: 'user',
                   target_id: target[:id], ip: client_ip)

      json_response(200, user: Accounts.public_account(db[:users][id: target[:id]]))
    end

    # FA-903, the only way back from a forgotten password (E-13). The answer
    # carries the one-time password **once**; it is stored nowhere in readable
    # form, and how it reaches the user is the operator's decision.
    post "#{API_PREFIX}/admin/users/:id/reset-password" do
      target = admin_target_user
      authorize!(Access.for_instance(current_user, 'user.reset_password'))

      initial = Accounts.reset_password(db, target)
      Audit.record(db, 'user.password_reset', actor: current_user, target_type: 'user',
                   target_id: target[:id], ip: client_ip)

      json_response(200, initial_password: initial)
    end

    # FA-904. `prompts_action` is 'delete' or 'transfer', and with the latter
    # a `successor_id`. Asked and never assumed: removing an account is an
    # administrative act, removing their work is a content decision.
    delete "#{API_PREFIX}/admin/users/:id" do
      target = admin_target_user
      payload = json_body_if_any

      with_account_refusal do
        Accounts.delete(db, target, prompts_action: payload['prompts_action'],
                                    successor_id: payload['successor_id'])
      end
      Audit.record(db, 'user.deleted', actor: current_user, target_type: 'user',
                   target_id: target[:id], ip: client_ip,
                   meta: { prompts_action: payload['prompts_action'] })

      json_response(200, status: 'ok')
    end

    put "#{API_PREFIX}/admin/users/:id" do
      authorize!(Access.for_instance(current_user, 'user.grant_admin'))

      target = db[:users][id: params['id'].to_i]
      halt_with(404, 'not_found') if target.nil?

      payload = json_body
      unless payload['is_instance_admin'].nil?
        with_refusal { guard_last_instance_admin!(target, payload['is_instance_admin']) }
        db[:users].where(id: target[:id])
                  .update(is_instance_admin: payload['is_instance_admin'] == true, updated_at: Time.now)
        Audit.record(db, 'user.instance_admin_changed', actor: current_user,
                     target_type: 'user', target_id: target[:id], ip: client_ip)
      end

      json_response(200, user: public_user(db[:users][id: target[:id]]))
    end

    # FA-907: the instance administrator sees every workspace with its owner
    # and its sizes — and no content. The counts are what he needs to
    # administer; the prompts themselves stay out of reach (chapter 6.2).
    get "#{API_PREFIX}/admin/workspaces" do
      authorize!(Access.for_instance(current_user, 'user.manage'))

      json_response(200, workspaces: db[:workspaces].order(:name).all.map { |row| admin_workspace(row) })
    end

    # TF-308c: the one place he writes to a foreign workspace. Renaming needs
    # no sight of the contents, which is why it is the only such action.
    put "#{API_PREFIX}/admin/workspaces/:id" do
      workspace = admin_target_workspace('workspace.rename')

      with_refusal { Workspaces.rename(db, workspace[:id], json_body['name']) }
      Audit.record(db, 'workspace.renamed', actor: current_user, target_type: 'workspace',
                   target_id: workspace[:id], ip: client_ip)

      json_response(200, workspace: public_workspace(db[:workspaces][id: workspace[:id]]))
    end

    delete "#{API_PREFIX}/admin/workspaces/:id" do
      workspace = admin_target_workspace('workspace.delete')

      with_refusal { Workspaces.delete(db, workspace[:id], confirmation: json_body_if_any['confirm_name']) }
      Audit.record(db, 'workspace.deleted', actor: current_user, target_type: 'workspace',
                   target_id: workspace[:id], ip: client_ip)

      json_response(200, status: 'ok')
    end

    # --- product settings (FA-910) ------------------------------------------

    get "#{API_PREFIX}/admin/settings" do
      authorize!(Access.for_instance(current_user, 'user.manage'))

      json_response(200, settings: Settings.describe(db, self.class.configuration))
    end

    # Nothing here needs a restart: the application reads its configuration on
    # every request. That is the reason these values are editable at all —
    # a setting that took effect only after a restart would need a restart
    # button, and a restart button is exactly what an application must not
    # have (see migrations/004_settings.rb).
    put "#{API_PREFIX}/admin/settings" do
      authorize!(Access.for_instance(current_user, 'user.manage'))

      changed = begin
        Settings.update(db, json_body['settings'] || {}, actor: current_user)
      rescue Settings::Refused => e
        halt_validation(e.fields)
      end

      # The values go into the entry. A change to who may register or to how
      # long a log is kept is exactly the kind of decision one wants to be
      # able to look up later (SEC-09).
      Audit.record(db, Audit::SETTINGS_CHANGED, actor: current_user, target_type: 'instance',
                   ip: client_ip, meta: changed) unless changed.empty?

      json_response(200, settings: Settings.describe(db, self.class.configuration))
    end

    # FA-908. Filterable by person, action and period — which the first
    # version was not: it showed the newest hundred and offered nothing to
    # narrow them. That was not merely incomplete, it was the whole weakness
    # of the log. Nothing pushes an entry out of the table (it is bounded by
    # time, not by count), but a hundred refused logins push every
    # administrative entry out of *sight*, and an administrator looks at the
    # log precisely when something has happened.
    get "#{API_PREFIX}/admin/audit" do
      authorize!(Access.for_instance(current_user, 'audit.read'))

      page, per_page = paging
      rows = audit_filtered(db[:audit_logs])
      total = rows.count

      entries = rows.reverse(:id).limit(per_page).offset((page - 1) * per_page)
                    .select(:id, :actor_id, :actor_name, :action, :target_type,
                            :target_id, :meta_json, :ip, :created_at).all

      # The same paging shape as every other list (15.3). The first version
      # invented `limit` and a flat `total` — two conventions in one interface
      # is one too many, and the screen could reach nothing beyond the newest
      # hundred: a filter by date was the only way to older entries, and it
      # required guessing the day.
      json_response(200, entries: entries, actions: Audit::ACTIONS,
                         meta: { total: total, page: page, per_page: per_page })
    end

    # --- The interface ----------------------------------------------------

    # The single page application, for every address a browser can be at
    # (E-02, 18.8).
    #
    # **This was missing, and only installing the built archive showed it.**
    # `set :static` serves `/assets/…` and `/logo.svg`, but Sinatra does not
    # answer `/` with an index file, and it knows nothing of client-side
    # routes: a delivered instance replied to `GET /` with the JSON 404 of an
    # API, and a reload on `/prompts/5` did the same. Every automated test was
    # green — the browser tests ran behind a piece of Rack in their own harness
    # that did this job and, in a comment, said the backend did it.
    #
    # Deliberately the **last** route: `pass` hands anything that is not a
    # browser navigation back to the 404 and 405 handling below, so nothing
    # about the API changes.
    get '/*' do
      pass unless interface_navigation?

      shell = interface_shell
      pass if shell.nil?

      content_type 'text/html'
      shell
    end

    # The pattern of the route just defined. Taken from Sinatra's own table
    # rather than written out a second time: `allowed_methods_for` has to leave
    # this one route out, and a copied `'/*'` would go on matching after
    # somebody changed the route above it.
    INTERFACE_PATTERN = routes['GET'].last.first

    # --- Error handling ---------------------------------------------------

    # A path that exists but not for this method answers 405 with an Allow
    # header, not 404.
    #
    # Sinatra reaches not_found for both cases, and answering 404 sends the
    # caller looking for the right path when the path was right and only the
    # verb was wrong — GET on /auth/login instead of POST is the obvious
    # example. This does not weaken the rule from 15.2 that a hidden resource
    # answers 404: that rule is about *resources*, this is about *routes*, and
    # which verbs a documented endpoint accepts is public knowledge anyway.
    not_found do
      # Sinatra runs this block for every 404, including the ones a route
      # produced deliberately. Those must be left exactly as they are: the
      # concealing 404 of SEC-06 exists so a stranger cannot tell an existing
      # object from a missing one, and answering "405, try POST instead"
      # confirms the path is real. The rewrite below is only for a request
      # that matched no route at all.
      allowed = @deliberate_not_found ? [] : allowed_methods_for(request.path_info)

      if allowed.empty?
        json_response(404, error: { code: 'not_found' })
      else
        headers 'allow' => allowed.join(', ')
        json_response(405, error: {
                        code: 'method_not_allowed',
                        params: { method: request.request_method, allowed: allowed.join(', ') }
                      })
      end
    end

    # NFA-16 and SEC-13, which pull in opposite directions and are both served
    # by the same line: **everything into the log, one opaque token out**.
    #
    # Until AP-17 the log said only when and what class — neither who nor which
    # request. A report of "it failed at about eleven" could then not be tied
    # to a line at all, and with several people working, `RuntimeError` at
    # 11:04 is not enough to find the one. Measured against the requirement
    # rather than against the code, two of its three fields were missing.
    #
    # The identifier travels back to the caller as well, and that is not a
    # breach of SEC-13: it is a random token this request invented, not a path,
    # a query or a stack frame. It is the whole difference between "something
    # went wrong" and a sentence somebody can quote into a support message.
    error do
      exception = env['sinatra.error']
      warn error_line(exception) if exception
      json_response(500, error: { code: 'server_error', request_id: request_id })
    end

    private

    def db = self.class.database

    # --- the interface ------------------------------------------------------

    # Paths the application answers itself. Everything below them keeps the
    # behaviour of an API: a wrong path is a 404 in the documented error
    # format, not a page.
    API_PATHS = [API_PREFIX, '/health', '/version'].freeze

    # Four conditions, and each keeps a different mistake out of the fallback:
    #
    #   * **only GET and HEAD** — a POST to a path that does not exist is a
    #     mistake in a program, and handing it a page would hide it.
    #   * **not an API path** — below those, a wrong path stays a 404 in the
    #     documented error format.
    #   * **no file extension** — a missing `/assets/index-abc.js` has to stay
    #     a 404. Answering it with the shell gives the browser HTML where it
    #     expects JavaScript, and the page then fails with a syntax error
    #     pointing at `<!doctype`, three steps from the real cause.
    #   * **`text/html` asked for by name** — this is what separates a person
    #     navigating from a program fetching. A browser always names it when
    #     it loads a page; `curl` sends `*/*` and a script usually nothing at
    #     all, and both get the answer an API gives. Without this condition
    #     `GET /Gemfile` would answer 200 (with the shell, not the file) and
    #     TF-518 would have to be weakened to allow it.
    def interface_navigation?
      return false unless request.get? || request.head?
      return false if API_PATHS.any? { |prefix| request.path_info.start_with?(prefix) }
      return false unless File.extname(request.path_info).empty?

      request.accept.any? { |entry| entry.to_s.start_with?('text/html') }
    end

    # Nil when there is nothing to serve — in the development tree, where Vite
    # serves the interface and `backend/public/` may be empty until the first
    # build. The API then answers as it always did instead of failing on a
    # missing file.
    def interface_shell
      path = File.join(settings.public_folder.to_s, 'index.html')
      return nil unless File.file?(path)

      File.read(path)
    end

    # --- authorisation (SEC-06) --------------------------------------------

    def require_authentication!
      halt_with(401, 'unauthorized') unless authenticated?
    end

    # Turns a verdict from the access layer into an answer. The 404 is not a
    # nicety: telling someone "forbidden" about an object they cannot see
    # already tells them it exists (test concept 6.1).
    def authorize!(verdict)
      case verdict
      when :allow, :allow_own_only then verdict
      when :forbidden then halt_with(403, 'forbidden')
      else halt_with(404, 'not_found')
      end
    end

    # Resolves the workspace from the path and decides the action in one step,
    # so no route can look one up without asking permission for it.
    def authorized_workspace(action)
      require_authentication!
      id = params['id'].to_i
      authorize!(Access.for_workspace(db, current_user, id, action))

      db[:workspaces][id: id]
    end

    # Handing out the owner role is its own row in the matrix: an admin manages
    # members but cannot make anyone an owner, not even by way of a role
    # change. Checked separately because the endpoint is shared.
    def authorize_owner_grant!(workspace, role)
      return unless role == 'owner'

      authorize!(Access.for_workspace(db, current_user, workspace[:id], 'member.grant_owner'))
    end

    # Resolves the prompt from the path and decides the action in one step.
    #
    # A prompt in the trash is invisible on the ordinary path and visible on
    # the trash path — so the trash endpoints say which they mean, instead of
    # the access layer having to guess it from the action name.
    #
    # The line below is deliberately redundant, and a mutation probe confirmed
    # it: removing it changes no answer, because Access.prompt_visible? already
    # refuses a deleted prompt on the ordinary path and the trash list already
    # refuses a live one on the trash path. It stays as a second barrier — but
    # nobody should mistake it for the only one.
    # --- bulk actions (FA-511, FA-703a) -------------------------------------

    # The list of ids, or a refusal. Checked **before** anything is looked up:
    # an empty list answered with an empty report would read like a successful
    # run over nothing, which is the shape of a bug nobody investigates.
    def bulk_ids
      require_authentication!
      outcome = Bulk.ids_from(json_body)
      return outcome if outcome.is_a?(Array)

      halt_validation({ prompt_ids: outcome })
    end

    # `done` and `refused`, plus the counts the interface puts in its sentence.
    # The counts are computed here rather than in the browser so that the
    # report and the summary can never disagree.
    def bulk_response(result)
      json_response(200,
                    done: result[:done],
                    refused: result[:refused],
                    counts: { done: result[:done].length,
                              refused: result[:refused].length,
                              visibility_reset: result[:done].count { |entry| entry[:visibility_reset] } })
    end

    def authorized_prompt(action, deleted: false)
      require_authentication!
      prompt = db[:prompts][id: params['id'].to_i]
      prompt = nil if !prompt.nil? && prompt[:deleted_at].nil? != !deleted

      authorize!(prompt_verdict(prompt, action, deleted: deleted))
      prompt
    end

    # For a deleted prompt the visibility question is answered by the trash
    # rules of FA-703, not by the prompt's own visibility: an admin has to
    # reach a foreign prompt in the trash to be able to purge it.
    def prompt_verdict(prompt, action, deleted:)
      return :not_found if prompt.nil?
      return Access.for_prompt(db, current_user, prompt, action) unless deleted

      role = Access.membership_role(db, prompt[:workspace_id], current_user[:id])
      return :not_found unless Prompts.trash_for(db, prompt[:workspace_id], current_user[:id], role)
                                      .any? { |row| row[:id] == prompt[:id] }

      Access.verdict(action, role: role, instance_admin: Access.instance_admin?(current_user),
                             owns: prompt[:owner_id] == current_user[:id])
    end

    # 15.1: the workspace-bound list calls demand the parameter. Missing means
    # 422 — a default would silently pick a scope for the caller.
    def required_workspace_id(from_body = nil)
      value = from_body || params['workspace_id']
      halt_validation({ workspace_id: :required }) if value.nil? || value.to_s.strip.empty?

      value.to_i
    end

    # --- the library and its filters (FA-506, FA-507, FA-509) ---------------

    # Which workspaces the listing covers. `all` is the cross-workspace view
    # of FA-509 and passes nil, so Search restricts by visibility alone —
    # which is what makes instance-wide prompts findable at all. Anything else
    # is a single workspace and needs the usual permission.
    def prompt_scope
      raw = params['workspace_id']
      halt_validation({ workspace_id: :required }) if raw.nil? || raw.to_s.strip.empty?
      return nil if raw == 'all'

      workspace_id = raw.to_i
      authorize!(Access.for_workspace(db, current_user, workspace_id, 'prompt.read'))
      [workspace_id]
    end

    def paging
      page = [params['page'].to_i, 1].max
      per_page = params['per_page'].to_i
      per_page = 50 if per_page <= 0
      [page, [per_page, 200].min]
    end

    def requested_tag_ids
      Array(params['tags'] || params['tags[]']).map(&:to_i).reject(&:zero?)
    end

    # Filters that need no index and would only make the query harder to read.
    # FA-205 lives here: archived prompts stay out of the library until they
    # are asked for by name.
    # The filters of FA-506, as one set of arguments for both the page and the
    # count. They used to be applied to the returned page instead, and that was
    # wrong in a way the library screen made visible: `meta.total` counted rows
    # the filter then removed, so the heading said 47 while the list showed 3,
    # and page two could be empty with matches sitting further down.
    def library_query(scope)
      {
        term: params['q'], workspace_ids: scope, tag_ids: requested_tag_ids,
        visible_for: current_user[:id],
        status: params['status'], visibility: params['visibility'],
        owner_id: params['owner_id'],
        favorites_of: params['favorites_only'] == 'true' ? current_user[:id] : nil
      }
    end

    # --- tags and keywords ---------------------------------------------------

    def authorized_catalog_workspace(action, from_body: false)
      workspace_id = required_workspace_id(from_body ? json_body['workspace_id'] : nil)
      authorize!(Access.for_workspace(db, current_user, workspace_id, action))
      workspace_id
    end

    def authorized_keyword
      require_authentication!
      keyword = db[:keywords][id: params['id'].to_i]
      authorize!(keyword.nil? ? :not_found : Access.for_workspace(db, current_user, keyword[:workspace_id], 'keyword.write'))

      keyword
    end

    # --- import and export (FA-801 to FA-804, SEC-12) -----------------------

    # The size is checked on the **declared length of the request**, before a
    # single byte is parsed. SEC-12 says "bevor irgendetwas geschrieben wird",
    # and TF-344 sharpens it to "vor dem Einlesen": a 10-MB limit that first
    # parses 40 MB of JSON has already spent the memory it was meant to save.
    #
    # `Transfer.parse` checks the payload again on the extracted content. Two
    # checks, and neither is redundant: this one sees the request, that one
    # sees what the request actually carried.
    def import_request
      halt_with(413, 'file_too_large') \
        if request.content_length.to_i > Transfer::MAX_BYTES

      workspace_id = required_workspace_id(json_body['workspace_id'])
      authorize!(Access.for_workspace(db, current_user, workspace_id, 'prompt.import'))

      [workspace_id, with_transfer_refusal { Transfer.parse(json_body['content']) }]
    end

    # A refused file is a 422 with a reason, never a 500. The reason names what
    # is wrong with the file — FA-802 asks for "konkretem Grund", and "ungültige
    # Datei" leaves the user holding a file and no idea what to do with it.
    def with_transfer_refusal
      yield
    rescue Transfer::Refused => e
      status_code = e.code == :file_too_large ? 413 : 422
      halt status_code, { 'content-type' => 'application/json' },
           JSON.generate(error: error_body(TRANSFER_CODE.fetch(e.code, e.code).to_s,
                                           e.detail.transform_keys(&:to_sym)),
                         detail: e.detail)
    end

    # One code of the transfer collides with a general one, and the collision
    # is not cosmetic: `malformed_json` as a general refusal is about the
    # **request body**, and reporting a damaged import file with that sentence
    # tells the reader to check something they never sent. Codes have to be
    # unique across the whole answer surface, because the sentence is chosen by
    # the code alone (TF-534).
    TRANSFER_CODE = { malformed_json: :file_malformed_json }.freeze

    def with_catalog_refusal
      yield
    rescue Catalog::Refused => e
      status_code = e.code == :name_taken ? 409 : 422
      halt status_code, { 'content-type' => 'application/json' },
           JSON.generate(error: { code: e.code.to_s, fields: e.fields })
    end

    def with_prompt_refusal
      yield
    rescue Prompts::Refused => e
      status_code = e.code == :validation_failed ? 422 : PROMPT_REFUSAL_STATUS.fetch(e.code, 422)
      halt status_code, { 'content-type' => 'application/json' },
           JSON.generate(error: { code: e.code.to_s, fields: e.fields })
    end

    PROMPT_REFUSAL_STATUS = {
      foreign_keyword: 403, unknown_keyword: 422, no_revision: 422
    }.freeze

    # A page of the library, with everything a line in 11.3 shows: tags, the
    # author, the number of variables, and the workspace the prompt comes from.
    #
    # Each of those is fetched once for the whole page rather than once per
    # row. Per row it would be four extra queries times fifty lines, and
    # NFA-02 gives the whole answer 200 ms — the sort of cost that is invisible
    # with the six prompts of a test fixture and obvious with a real library.
    def prompt_summaries(rows)
      return [] if rows.empty?

      ids   = rows.map { |row| row[:id] }
      tags  = Prompts.tag_names_for(db, ids)
      sizes = Prompts.variable_counts(db, ids)
      marked = db[:favorites].where(user_id: current_user[:id], prompt_id: ids).select_map(:prompt_id)
      owners = db[:users].where(id: rows.map { |row| row[:owner_id] }.compact.uniq).to_hash(:id, :name)
      spaces = workspace_labels(rows)

      rows.map do |row|
        public_prompt(db, row, favorite: marked.include?(row[:id])).merge(
          tags: tags[row[:id]] || [],
          variable_count: sizes[row[:id]] || 0,
          owner_name: owners[row[:owner_id]],
          workspace_name: spaces.dig(row[:workspace_id], :name),
          workspace_is_personal: spaces.dig(row[:workspace_id], :is_personal),
          highlights: highlights_for(row)
        )
      end
    end

    # A page of the trash (FA-703). Three things a line there shows that the
    # ordinary payload does not carry: **who** deleted it, **where** it came
    # from, and what may still be done with it.
    #
    # The first is why this exists at all. `deleted_by` is a user id, and a
    # line reading "gelöscht von 4" answers nobody's question — the requirement
    # asks for the deleting user, and a name is what that means. Resolved here
    # in one query for the whole page rather than one per row, like
    # `prompt_summaries` does for the library.
    #
    # `restore` is decided per row and not per workspace: an editor may restore
    # what belongs to them but not what an admin deleted of someone else's, so
    # a single answer for the whole list would be wrong for half of it.
    def trash_entries(rows)
      return [] if rows.empty?

      names = db[:users].where(id: rows.map { |row| row[:deleted_by] }.compact.uniq).to_hash(:id, :name)
      spaces = workspace_labels(rows)

      rows.map do |row|
        public_prompt(db, row).merge(
          deleted_by_name: names[row[:deleted_by]],
          workspace_name: spaces.dig(row[:workspace_id], :name),
          workspace_is_personal: spaces.dig(row[:workspace_id], :is_personal),
          permissions: trash_permissions(row)
        )
      end
    end

    # The workspaces a page of rows came from, by id, with the one thing the
    # browser cannot work out for itself: whether a workspace is somebody's
    # personal one.
    #
    # **Why the flag travels with the name.** The personal workspace carries a
    # German name in the database — `Workspaces.create` writes
    # `Persönlich-<Name>` the moment an account is made — and the interface
    # shows a translated label instead (AP-19, `util/workspace.js`). Without
    # the flag, the library and the trash have only the stored name, so the
    # same workspace read "Persönlicher Workspace" in the switcher and
    # "Persönlich-Martin" three lines below. One workspace, two names, and
    # nothing to tell a user they are the same thing.
    def workspace_labels(rows)
      db[:workspaces]
        .where(id: rows.map { |row| row[:workspace_id] }.uniq)
        .select(:id, :name, :is_personal)
        .to_hash(:id)
        .transform_values { |row| { name: row[:name], is_personal: row[:is_personal] == true } }
    end

    TRASH_ACTIONS = %w[trash.restore trash.purge].freeze

    def trash_permissions(row)
      role = Access.membership_role(db, row[:workspace_id], current_user[:id])

      TRASH_ACTIONS.to_h do |action|
        verdict = Access.verdict(action, role: role, instance_admin: Access.instance_admin?(current_user),
                                         owns: row[:owner_id] == current_user[:id])
        [action.sub('trash.', ''), verdict == :allow]
      end
    end

    # FA-501 promises the hits with the found place marked. The ranges are
    # computed on the server because the rule that decides what counts as a
    # match is the normalisation of FA-501 — the same one the index was built
    # with. A browser guessing at it with its own comparison would mark
    # something else than was found, and "Größe" for the term "Grosse" would
    # be exactly the case it got wrong.
    #
    # Positions in the **original** text, as pairs of start and length. Not
    # marked-up text: prompt content is never HTML (SEC-10), and handing over
    # a string with tags in it would be the one place where that stops being
    # true.
    def highlights_for(row)
      term = params['q']
      return {} if term.to_s.strip.empty?

      {
        title: Search.highlight_ranges(row[:title], term),
        description: Search.highlight_ranges(row[:description], term)
      }
    end

    def public_prompt(db, row, full: false, favorite: nil)
      base = {
        id: row[:id], workspace_id: row[:workspace_id], owner_id: row[:owner_id],
        title: row[:title], description: row[:description], visibility: row[:visibility],
        status: row[:status], model_hint: row[:model_hint],
        deleted_at: row[:deleted_at], deleted_by: row[:deleted_by],
        favorite: favorite.nil? ? favorite?(row[:id]) : favorite,
        updated_at: row[:updated_at]
      }
      return base unless full

      base.merge(
        body: row[:body],
        variables: db[:prompt_variables].where(prompt_id: row[:id]).order(:position)
                     .select(:key, :label, :type, :default_value, :options, :required, :position).all,
        tags: Prompts.tag_names(db, row[:id]),
        # The default keywords in full, not just by name.
        #
        # The preview in the browser renders locally (NFA-14), so it needs the
        # text, the position and the order — otherwise it would leave out
        # exactly what the server puts in, and the two renderings would differ
        # on the screen that exists to show them agreeing.
        #
        # This matters most for a prompt from a foreign workspace (TF-426):
        # its keywords cannot be read from the catalogue there. Handing them
        # over here gives away nothing that was not available already — the
        # render endpoint applies these very keywords for this very reader.
        keywords: Prompts.default_keywords(db, row[:id]),
        revision_count: db[:prompt_revisions].where(prompt_id: row[:id]).count,
        permissions: permissions_for(row)
      )
    end

    # What this person may do with this prompt.
    #
    # The interface needs it to leave out what is not allowed rather than
    # offer it and be refused (11.4). It is **not** protection — every one of
    # these actions is checked again when it is called (SEC-06) — but a menu
    # that lists what cannot be done explains nothing, and greying an entry
    # out explains even less.
    #
    # Computed here from the same matrix the endpoints use, never in the
    # browser: a second copy of the permission rules is a second place for
    # them to be wrong, and the wrong one would be the one nobody tests.
    MENU_ACTIONS = %w[prompt.update prompt.delete prompt.duplicate prompt.move
                      prompt.visibility].freeze

    def permissions_for(row)
      MENU_ACTIONS.to_h do |action|
        [action.sub('prompt.', ''), Access.for_prompt(db, current_user, row, action) == :allow]
      end
    end

    def favorite?(prompt_id)
      db[:favorites].where(user_id: current_user[:id], prompt_id: prompt_id).count.positive?
    end

    # Maps a refusal from the domain services onto a status code. Kept in one
    # place so a new rule cannot accidentally answer 500.
    REFUSAL_STATUS = {
      not_found: 404, personal_workspace: 403, last_owner: 403, last_instance_admin: 403,
      name_required: 422, name_too_long: 422, confirmation_mismatch: 422,
      unknown_role: 422, unknown_user: 422, already_member: 422, not_a_member: 404
    }.freeze

    # DELETE carries a body only when a confirmation is required (FA-606).
    # An absent body is normal there and must not be a validation error.
    def json_body_if_any
      return {} if request.body.nil? || request.content_length.to_i.zero?

      json_body
    end

    def with_refusal
      yield
    rescue Workspaces::Refused => e
      halt_with(REFUSAL_STATUS.fetch(e.code, 422), e.code.to_s)
    end

    # FA-905: the last instance administrator may not take the flag off
    # themselves. Counted rather than assumed — an instance with nobody who can
    # administer it needs the command line to recover (BT-13).
    def guard_last_instance_admin!(target, requested)
      return if requested == true
      return unless target[:is_instance_admin]

      others = db[:users].where(is_instance_admin: true).exclude(id: target[:id])
                         .where(status: 'active').count
      raise Workspaces::Refused, :last_instance_admin if others.zero?
    end

    def record_membership_change(action, workspace, user_id, role)
      Audit.record(db, action, actor: current_user, target_type: 'workspace',
                   target_id: workspace[:id], ip: client_ip,
                   meta: { user_id: user_id.to_i, role: role }.compact)
    end

    # --- the daily clear-out (FA-706) ---------------------------------------

    # Triggered by the application itself and not by an external scheduler.
    # E-14 allows four ways of running this — portable and as a service, on two
    # operating systems — and a cron entry would exist in one of them. A
    # cleanup that only some installations get is worse than none, because
    # nobody can say which ones have it.
    #
    # It runs at most once a day, on the first request after the day turned.
    # A request is the only clock a portable installation has: no request, no
    # growth worth clearing.
    def sweep_if_due
      today = Date.today
      return if self.class.last_sweep == today

      # Marked as done **before** the work, not after. A failing sweep must
      # not be retried on every request for the rest of the day — that would
      # turn one broken run into a broken installation (TF-429).
      self.class.last_sweep = today
      removed = Retention.sweep(db, config: effective_config)

      warn "[#{Time.now.iso8601}] retention: #{JSON.generate(removed)}" if removed.values.any?(&:positive?)
    rescue StandardError => e
      # A locked database skips the run and the application carries on
      # (TF-429). The next day tries again.
      #
      # The wording says that, because this line ends up in a log somebody
      # reads later — and in a build log, where it appeared during a perfectly
      # green run and read like a failure. A line that is not a problem must
      # not look like one, or the next reader skims past one that is.
      warn "[#{Time.now.iso8601}] note: housekeeping run skipped (#{e.class}), " \
           'the application carries on and tries again on the next occasion'
    end

    # --- administration (FA-901 to FA-906, SEC-18) --------------------------

    def admin_target_user
      authorize!(Access.for_instance(current_user, 'user.manage'))
      target = db[:users][id: params['id'].to_i]
      halt_with(404, 'not_found') if target.nil?

      target
    end

    def changed_address?(email)
      email.to_s.strip.downcase != current_user[:email].to_s.downcase
    end

    # Only ever asked about an address that **changed**, so "somebody else" is
    # the only thing it can find — the caller's own row carries the old one.
    # An `exclude(id: current_user)` stood here and a mutation probe showed it
    # could go without a test noticing; it was guarding a case the check above
    # already rules out.
    def taken_by_somebody_else?(email)
      db[:users].where(Sequel.function(:lower, :email) => email.to_s.strip.downcase).count.positive?
    end

    # Which refusal is which kind of "no". Everything unlisted is a complaint
    # about the input and answers 422; the four here are not — being turned
    # away because the feature is off, because the instance has no
    # administrator yet, or because too many accounts came from one address in
    # an hour has nothing to do with what was typed into the form.
    ACCOUNT_REFUSAL_STATUS = {
      last_instance_admin: 403,
      registration_disabled: 403,
      setup_pending: 409,
      too_many_registrations: 429
    }.freeze

    REFUSAL_CODE = {
      403 => 'forbidden', 409 => 'conflict',
      429 => 'rate_limited', 422 => 'validation_failed'
    }.freeze

    def with_account_refusal
      yield
    rescue Accounts::Refused => e
      status_code = ACCOUNT_REFUSAL_STATUS.fetch(e.code, 422)
      halt status_code, { 'content-type' => 'application/json' },
           JSON.generate(error: error_body(e.code.to_s, e.detail))
    end

    def address_taken?(email)
      db[:users].where(Sequel.function(:lower, :email) => email.to_s.strip.downcase)
                .count.positive?
    end

    # --- the audit filter (FA-908) ------------------------------------------

    def audit_filtered(rows)
      rows = rows.where(actor_id: params['actor_id'].to_i) if params['actor_id'].to_s.match?(/\A\d+\z/)
      rows = rows.where(action: audit_action) if audit_action

      from = audit_moment('from')
      to   = audit_moment('to')
      rows = rows.where { created_at >= from } if from
      rows = rows.where { created_at <= to } if to

      rows
    end

    # An unknown action is refused rather than ignored. A filter that silently
    # falls back to "everything" is a filter that cannot fail — the caller sees
    # a full list and believes it is the filtered one.
    def audit_action
      value = params['action'].to_s.strip
      return nil if value.empty?

      halt_validation(action: 'unknown_action') unless Audit::ACTIONS.include?(value)

      value
    end

    # Accepts a full ISO 8601 moment **with offset**, which is what the screen
    # sends: the boundaries of a day belong to the reader's time zone, and the
    # browser is the only party that knows it (11.6). A bare date is accepted
    # too, for a call made by hand, and is then read as UTC — `to` covering
    # that whole day rather than its first instant, because "up to the 3rd"
    # naturally includes the 3rd.
    def audit_moment(key)
      value = params[key].to_s.strip
      return nil if value.empty?

      return Time.iso8601(value) if value.include?('T')

      day = Date.iso8601(value)
      moment = Time.utc(day.year, day.month, day.day)
      key == 'to' ? moment + 86_399 : moment
    rescue ArgumentError, Date::Error
      halt_validation(key.to_sym => 'bad_date')
    end

    # SEC-18, and the list is the requirement's: account, memberships, own
    # prompts **with their content**, favourites, and the audit entries about
    # this person. Assembled here rather than reusing the export of FA-801,
    # which answers a different question — that one is about a workspace and
    # what may be taken out of it, this one is about a person and everything
    # held on them.
    def self_disclosure
      {
        account: public_user(current_user).merge(created_at: current_user[:created_at]&.iso8601),
        memberships: db[:memberships].join(:workspaces, id: :workspace_id)
                       .where(Sequel[:memberships][:user_id] => current_user[:id])
                       .select(Sequel[:workspaces][:name], Sequel[:memberships][:role],
                               Sequel[:memberships][:created_at]).all,
        prompts: db[:prompts].where(owner_id: current_user[:id])
                   .select(:title, :description, :body, :visibility, :status,
                           :created_at, :updated_at, :deleted_at).all,
        favorites: db[:favorites].join(:prompts, id: :prompt_id)
                     .where(Sequel[:favorites][:user_id] => current_user[:id])
                     .select_map(Sequel[:prompts][:title]),
        audit_entries: db[:audit_logs].where(actor_id: current_user[:id])
                         .select(:action, :target_type, :target_id, :ip, :created_at)
                         .reverse(:id).all
      }
    end

    # Resolves a workspace for an administrative action. Deliberately does not
    # go through authorized_workspace: that one refuses a non-member with 404
    # for content actions, and here the instance administrator is entitled to
    # act on a workspace he is not a member of.
    def admin_target_workspace(action)
      require_authentication!
      workspace = db[:workspaces][id: params['id'].to_i]
      authorize!(workspace.nil? ? :not_found : Access.for_workspace(db, current_user, workspace[:id], action))

      workspace
    end

    # FA-907: counts, never content.
    def admin_workspace(row)
      {
        id: row[:id], name: row[:name], slug: row[:slug], is_personal: row[:is_personal] == true,
        owner: db[:memberships].join(:users, id: :user_id)
                 .where(Sequel[:memberships][:workspace_id] => row[:id],
                        Sequel[:memberships][:role] => 'owner')
                 .get(Sequel[:users][:name]),
        member_count: db[:memberships].where(workspace_id: row[:id]).count,
        prompt_count: db[:prompts].where(workspace_id: row[:id], deleted_at: nil).count
      }
    end

    # What a workspace may be used for, from the same matrix the endpoints
    # consult. The target list of "duplicate" and "move" needs it (TF-308): a
    # viewer may read a workspace and may not create anything in it, and a
    # target nobody may write to is a choice that can only end in a refusal.
    #
    # Derived from the role rather than re-stated — the browser must not carry
    # a second copy of the rules, because the copy is the one nobody tests
    # (SEC-06). Same reason as `permissions_for` on a prompt.
    #
    # The keys are short and the actions are the matrix's. Spelling them out
    # beats deriving the key from the action name: `trash.view` and
    # `trash.purge` would both reduce to something unhelpful, and a mapping
    # that has to be read twice is a mapping that gets read wrong once.
    WORKSPACE_ACTIONS = {
      'create' => 'prompt.create',
      'keywords' => 'keyword.write',
      'trash' => 'trash.view',
      'purge' => 'trash.purge',
      'members' => 'member.manage',
      'grant_owner' => 'member.grant_owner',
      'rename' => 'workspace.rename',
      'delete' => 'workspace.delete',
      'export' => 'prompt.export',
      'import' => 'prompt.import'
    }.freeze

    def workspace_permissions(row)
      return nil if row[:role].nil?

      granted = WORKSPACE_ACTIONS.transform_values do |action|
        Access.verdict(action, role: row[:role]) != :forbidden
      end
      personal_locks(granted, row)
    end

    # FA-606 and TF-425: the personal workspace cannot be deleted and its
    # single membership cannot be changed — not by its owner, not by an
    # instance administrator. That rule lives in `Workspaces.guard_personal!`
    # and answers 403 there; it is repeated here because the matrix cannot
    # express it and the screen has to know.
    #
    # "Repeated" is the honest word, and it is why this reads off `is_personal`
    # rather than restating the reasoning: the requirement says the action is
    # not to be offered at all. An offered button that always fails would be
    # the alternative, and TF-425 asks for the opposite.
    def personal_locks(granted, row)
      return granted unless row[:is_personal] == true

      granted.merge('delete' => false, 'members' => false, 'grant_owner' => false)
    end

    # A workspace row with the caller's membership role in it, which is the
    # shape `public_workspace` needs to say anything about permissions. Nil
    # for an instance administrator who is not a member — and then the answer
    # carries neither role nor permissions, which is the truth about him.
    def with_role(row)
      return nil if row.nil?

      row.merge(role: Access.membership_role(db, row[:id], current_user[:id]))
    end

    def public_workspace(row)
      {
        id: row[:id], name: row[:name], slug: row[:slug],
        is_personal: row[:is_personal] == true, role: row[:role],
        permissions: workspace_permissions(row)
      }.compact
    end

    # Which verbs this application would accept for +path+. HEAD is left out:
    # Sinatra derives it from GET, and listing it would suggest a route that
    # was never written.
    def allowed_methods_for(path)
      self.class.routes.reject { |verb, _| verb == 'HEAD' }
          .select { |_verb, entries| entries.any? { |pattern,| answers?(pattern, path) } }
          .keys.sort
    end

    # The catch-all that serves the interface matches every path, so it is left
    # out here. Counted in, **every** unknown address would answer "405, try
    # GET" — including the concealing 404 of SEC-06, which would then confirm
    # that a hidden object exists.
    def answers?(pattern, path)
      pattern != INTERFACE_PATTERN && pattern.match(path)
    end

    # --- request helpers --------------------------------------------------

    def writing? = WRITING_METHODS.include?(request.request_method)

    # Never `request.ip`: Rack decides for itself which addresses count as
    # proxies (every private range), and that guess is not the operator's
    # configuration. REMOTE_ADDR is the one value nobody but the network can
    # set.
    def client_ip
      TrustedProxy.client_ip(peer: request.env['REMOTE_ADDR'],
                             forwarded: request.env['HTTP_X_FORWARDED_FOR'],
                             trusted: trusted_proxies)
    end

    # --- the request identifier (NFA-16) ------------------------------------

    # Short, opaque, one per request. Eight bytes: long enough that two
    # requests of the same day do not collide, short enough that somebody can
    # read it off a screen and type it into a message.
    REQUEST_ID_BYTES = 8

    # What a proxy-supplied identifier may look like. Anything else is
    # discarded and a fresh one made — an unchecked header would let a caller
    # write newlines into the log and forge lines that look like ours.
    SAFE_REQUEST_ID = /\A[\w-]{1,64}\z/

    def assign_request_id
      @request_id = inherited_request_id || SecureRandom.hex(REQUEST_ID_BYTES)
      headers 'x-request-id' => @request_id
    end

    def request_id = @request_id

    # A reverse proxy in front of the instance usually stamps its own
    # identifier, and taking it means one line in its log and one here can be
    # laid side by side. Accepted **only from a trusted proxy** (SEC-07), for
    # the same reason `X-Forwarded-For` is: a header anybody may set is a
    # header anybody may use to make two unrelated requests look like one.
    def inherited_request_id
      supplied = request.env['HTTP_X_REQUEST_ID']
      return nil if supplied.nil? || !supplied.match?(SAFE_REQUEST_ID)
      return nil unless TrustedProxy.trusted_peer?(request.env['REMOTE_ADDR'], trusted_proxies)

      supplied
    end

    # Timestamp, account, request, and then what happened — the three fields
    # NFA-16 names, in front of the detail SEC-13 keeps out of the answer.
    # The method and path are there too: a class name alone rarely says which
    # of forty endpoints it came from.
    def error_line(exception)
      "[#{Time.now.iso8601}] error request=#{request_id} " \
        "user=#{current_user ? current_user[:id] : '-'} " \
        "#{request.request_method} #{request.path_info} " \
        "#{exception.class}: #{exception.message}"
    end

    # The configuration with the stored settings laid over it (FA-910).
    #
    # Deliberately **not** called `settings`: Sinatra defines a method of that
    # name on every request, and shadowing it takes the framework's own
    # options away from it — including `reload_templates`, which is asked for
    # on the way into every route. Found by seventeen suites failing at once.
    #
    # Used wherever a **product** value is read — registration, the login
    # limits, the retention periods. Operating values are read from
    # `self.class.configuration` directly: they are not editable here, and
    # going through this layer would suggest they were.
    def effective_config = Settings.view(db, self.class.configuration)

    def trusted_proxies = self.class.configuration&.[]('server.trusted_proxies')

    # Reads the request body as JSON.
    #
    # A malformed body gets its own message rather than the generic
    # "input incomplete or wrong". Saying which of the two is the case costs
    # nothing and reveals nothing — SEC-13 is about internals such as paths
    # and stack traces, not about telling a client that its body is not JSON.
    # The generic message sent a caller looking for a missing field when the
    # actual problem was single quotes.
    def json_body
      body = request.body.read
      request.body.rewind
      return {} if body.to_s.empty?

      parsed = JSON.parse(body)
      halt_with(400, 'malformed_json') unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      halt_with(400, 'malformed_json')
    end

    def valid_email?(value)
      value.to_s.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/) && value.to_s.length.between?(3, 254)
    end

    # --- headers (SEC-11, SEC-14) ------------------------------------------

    def apply_security_headers
      headers 'content-security-policy'   => CONTENT_SECURITY_POLICY,
              'x-content-type-options'    => 'nosniff',
              'referrer-policy'           => 'same-origin',
              'x-frame-options'           => 'DENY'

      # SEC-14: only over a connection that is actually secure. Sending HSTS
      # over plain HTTP is ignored by browsers and would pin a policy the
      # local installation cannot fulfil.
      return unless https?

      headers 'strict-transport-security' => 'max-age=31536000; includeSubDomains'
    end

    # The same trust boundary as `client_ip`. `X-Forwarded-Proto` decides the
    # `Secure` attribute and, through `redirect_to_https?`, whether SEC-14's
    # redirect happens at all — a caller who simply claims `https` would
    # otherwise switch the redirect off for themselves.
    #
    # Deliberately **not** `request.scheme`. Rack reads the forwarded headers
    # inside that method, so a trust check written on top of it looks correct
    # and never runs: the first line answers "https" before the check is
    # reached. The first version of this method did exactly that, and the
    # counter-case in the suite is what showed it. What is asked instead are
    # the two values the *server* sets and no caller can.
    def https?
      return true if request.env['rack.url_scheme'] == 'https' || request.env['HTTPS'] == 'on'
      return false unless forwarded_https?

      TrustedProxy.trusted_peer?(request.env['REMOTE_ADDR'], trusted_proxies)
    end

    def forwarded_https?
      request.env['HTTP_X_FORWARDED_PROTO'].to_s.split(',').first.to_s.strip == 'https' ||
        request.env['HTTP_X_FORWARDED_SSL'] == 'on' ||
        request.env['HTTP_X_FORWARDED_SCHEME'].to_s.strip == 'https'
    end

    def redirect_to_https?
      return false if https?
      return false unless self.class.configuration
      return false unless self.class.configuration['security.force_https']

      # The exception from SEC-03 applies here too: a local installation is
      # reachable over http on purpose, and redirecting it to a port that
      # serves nothing would make it unusable.
      !Sessions.local_request?(request)
    end

    def redirect_to_https
      target = "https://#{request.host_with_port.sub(/:80\z/, '')}#{request.fullpath}"
      redirect target, 301
    end

    # --- authentication ----------------------------------------------------

    def authenticate_request
      @current_user = nil
      @session_row  = nil
      token = session_token
      return if token.nil?

      found = Sessions.authenticate(db, token, config: self.class.configuration)
      return if found.nil?

      @current_user = found[:user]
      @session_row  = found[:session]
    end

    def session_token = request.cookies[Sessions::COOKIE_NAME]
    def current_user  = @current_user
    def authenticated? = !@current_user.nil?

    # The language of this request (11.7, AP-19).
    #
    # Assigned on **every** request, which is what makes it safe on a pooled
    # thread: a value left behind by the request before cannot survive, because
    # this line overwrites it whether or not anything was chosen. The `after`
    # filter below is tidiness for whoever else uses the thread, not the
    # safeguard.
    #
    # An empty `locale` in config.yml, and an empty `users.locale`, both mean
    # "nothing chosen here" and fall through on their own — `available?` says
    # no to an empty string. That is why neither needs a flag beside it: the
    # first attempt used `Configuration#from_template?` to tell a deliberate
    # `en` from an inherited one, and it would have been wrong in every real
    # installation, because `install` copies the whole template into
    # config.yml and every line in it then looks deliberate.
    # The language a profile update asks for (11.7).
    #
    # A malformed code is **kept out** rather than refused: the choice on the
    # screen comes from the files the interface carries, so anything else is
    # either a stale tab or somebody poking at the endpoint. Neither is worth a
    # validation error on a form the person did not fill in — the account
    # simply keeps the language it had.
    #
    # Checked with +offered?+ and not +available?+: the interface's languages
    # live in the bundle, not in `app/locales/`. Against the files here, saving
    # French in a profile was **dropped without a word** while the chooser
    # offered it — the screen switched, the next reload undid it (AP-22).
    #
    # An empty string is a real answer and means "nothing chosen": follow the
    # instance and the browser behind it.
    def chosen_locale(payload)
      return current_user[:locale] unless payload.key?('locale')

      wanted = payload['locale'].to_s
      return '' if wanted.empty?

      I18n.offered?(wanted) ? wanted : current_user[:locale]
    end

    def choose_language
      chosen = I18n.negotiate(
        profile: current_user && current_user[:locale],
        configured: self.class.configuration&.[]('locale'),
        accept_language: request.env['HTTP_ACCEPT_LANGUAGE']
      )
      Thread.current[I18n::CURRENT] = chosen

      # And the browser is told, on every answer (11.7). It must not repeat
      # this negotiation for itself: it cannot see config.yml, so an instance
      # set to `de` would answer in German inside an English interface, and
      # nothing would report the disagreement. `Content-Language` is the
      # standard place to say it and reaches even a 401 on the sign-in screen,
      # which is the one moment there is no profile to ask.
      headers 'Content-Language' => chosen
    end

    def start_session(user, token: nil)
      token ||= begin
        created, = Sessions.create(db, user_id: user[:id], ip: client_ip,
                                       user_agent: request.user_agent,
                                       config: self.class.configuration)
        created
      end

      write_session_cookies(token)
      token
    end

    # FA-103: the browser is given the same window the server applies, and it
    # is renewed on every authenticated call so the two slide together. A
    # cookie without an expiry would end the session when the browser closes,
    # whatever the server had promised (found in NT-2).
    def refresh_session_cookies
      write_session_cookies(session_token)
    end

    def write_session_cookies(token)
      options = Sessions.cookie_options(request, self.class.configuration)

      response.set_cookie(Sessions::COOKIE_NAME, options.merge(value: token))

      # SEC-05: the CSRF token travels in a cookie the browser script CAN
      # read, because the script has to send it back in a header. Its value is
      # not a secret — the protection is that a foreign origin can neither
      # read the cookie nor set the header.
      #
      # It carries the same expiry as the session cookie. With the shorter of
      # the two gone, the session would still be there and every write would
      # end in 403 — a state nothing recovers from except signing out.
      response.set_cookie(Sessions::CSRF_COOKIE_NAME,
                          options.merge(value: Sessions.hash_token(token), httponly: false))
    end

    def clear_session_cookies
      [Sessions::COOKIE_NAME, Sessions::CSRF_COOKIE_NAME].each do |name|
        response.delete_cookie(name, path: '/')
      end
    end

    # --- CSRF (SEC-05) -----------------------------------------------------

    # Double submit: the header has to repeat what the cookie says. A foreign
    # site can make the browser send the cookie, but it cannot read it and
    # therefore cannot set the header.
    #
    # Unauthenticated writes — login and setup — are exempt: there is no
    # session to protect yet, and demanding a token would make the first
    # request impossible.
    #
    # A login while a session already exists is NOT exempt. Login CSRF is a
    # real attack: a foreign site signs the victim into the attacker's account
    # so that everything the victim then saves lands there.
    def enforce_csrf
      return unless authenticated?

      expected = request.cookies[Sessions::CSRF_COOKIE_NAME]
      provided = request.env['HTTP_X_CSRF_TOKEN']

      return if expected && provided && secure_compare(expected, provided)

      halt_with(403, 'csrf_failed')
    end

    # Constant time. A short-circuiting == would leak the token one character
    # at a time to anyone able to measure.
    #
    # No functional test can observe this: replacing it with == keeps every
    # assertion green, which a mutation probe confirmed. The property is a
    # timing one, and a timing assertion on a few microseconds would be a
    # source of flaky failures rather than of confidence. It is noted here
    # instead — the one place in AP-05 that rests on review, not on a test.
    def secure_compare(one, two)
      return false unless one.bytesize == two.bytesize

      one.bytes.zip(two.bytes).reduce(0) { |sum, (a, b)| sum | (a ^ b) }.zero?
    end

    def enforce_write_rate_limit
      return unless authenticated?
      return unless RateLimit.writes_exceeded?(@session_row[:id])

      halt_with(429, 'rate_limited')
    end

    # The second half of SEC-19: import and export at most 5 per minute and
    # **user**. It was written as `RateLimit.exports_exceeded?` and then called
    # from nowhere — the function existed, the limit did not, and the register
    # had a case for it (TF-516) that nobody had implemented. Measured before
    # this line was added: eight exports in a row, eight times 200.
    #
    # Per user, not per session, and that is the point of a separate counter:
    # the write limit of 120 keys on the session, so a second sign-in doubles
    # it. These calls are the expensive ones — a whole workspace serialised —
    # and the self-disclosure of SEC-18 is a `GET`, which `writing?` does not
    # cover at all.
    # `/import/preview` is deliberately **not** here. 15.3 defines it as the
    # call that reads a file and **writes nothing**, and W-8 requires a preview
    # before every import — so counting it against the same five would leave a
    # user two and a half imports a minute and make the documented workflow the
    # thing that hits the ceiling. Measured: with the preview counted, four of
    # the browser cases went red.
    TRANSFER_PATHS = [
      %r{\A#{API_PREFIX}/export\z},
      %r{\A#{API_PREFIX}/import\z},
      %r{\A#{API_PREFIX}/auth/me/data-export\z}
    ].freeze

    def enforce_transfer_rate_limit
      return unless authenticated?
      return unless TRANSFER_PATHS.any? { |pattern| request.path_info.match?(pattern) }
      return unless RateLimit.exports_exceeded?(@current_user[:id])

      halt_with(429, 'rate_limited')
    end

    # --- responses ---------------------------------------------------------

    def json_response(status_code, body)
      status status_code
      content_type 'application/json'
      JSON.generate(with_iso_times(body))
    end

    # Requirements 15.1: ISO 8601 with a time zone. Ruby's default rendering
    # of a Time is `2026-08-02 10:52:30 +0200` — a space instead of the `T`
    # and no colon in the offset. That is not ISO 8601, and it is not a matter
    # of taste: `new Date(…)` parses it in Chrome and returns Invalid Date in
    # Safari, so the library would show "vor 2 Tagen" in one browser and
    # nothing in the other, against NFA-10.
    #
    # Done here because every answer leaves through this one method. Doing it
    # at each endpoint would work until the next endpoint forgets.
    def with_iso_times(value)
      case value
      when Time     then value.iso8601
      when DateTime then value.to_time.iso8601
      when Date     then value.iso8601
      when Hash     then value.transform_values { |entry| with_iso_times(entry) }
      when Array    then value.map { |entry| with_iso_times(entry) }
      else value
      end
    end

    # A refusal, as a **code and its parameters** — never as a sentence
    # (15.2, AP-19).
    #
    # The server used to write the sentence itself, which meant it had to know
    # the reader's language and meant the same situation was written down
    # twice: once in `backend/locales/` and once in the interface for the
    # cases the browser decides on its own. The two could drift apart with
    # nothing to notice. Now there is one place a sentence lives, and it is
    # the side that knows who is reading.
    def halt_with(status_code, code, **params)
      # Tells the not_found handler that this 404 was a decision, not a miss.
      @deliberate_not_found = true if status_code == 404

      halt status_code,
           { 'content-type' => 'application/json' },
           JSON.generate(error: error_body(code, params))
    end

    # +fields+ maps a field to the code that describes what is wrong with it,
    # optionally with parameters: `{ email: 'email_taken' }` or
    # `{ password: { code: 'too_short', params: { minimum: 12 } } }`.
    def halt_validation(fields)
      halt 422,
           { 'content-type' => 'application/json' },
           JSON.generate(error: { code: 'validation_failed', fields: fields })
    end

    def error_body(code, params)
      body = { code: code }
      # Left out when there are none, so an answer does not carry an empty
      # object that a reader has to decide is meaningless.
      params.empty? ? body : body.merge(params: params)
    end

    # Never includes password_hash. Not by filtering it out afterwards but by
    # listing what goes out — a new column then defaults to invisible.
    def public_user(user)
      {
        id: user[:id],
        email: user[:email],
        name: user[:name],
        is_instance_admin: user[:is_instance_admin] == true || user[:is_instance_admin] == 1,
        must_change_password: user[:must_change_pw] == true || user[:must_change_pw] == 1,
        locale: user[:locale]
      }
    end

    def setup_required? = db[:users].count.zero?

    def operational?
      return false if self.class.configuration.nil?

      database_writable? && SchemaGuard.current?(self.class.migrator)
    end

    def database_writable?
      db.fetch('PRAGMA quick_check').single_value == 'ok' &&
        !db.fetch('PRAGMA query_only').single_value.to_i.positive?
    rescue StandardError
      false
    end
  end
end
