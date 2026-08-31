# frozen_string_literal: true

require 'yaml'
require 'set'
require_relative 'i18n'
require_relative 'trusted_proxy'

module PromptAtelier
  # Loads and validates config/config.yml (Requirements 18.4).
  #
  # Three rules shape the design:
  #
  #   1. A missing value falls back to the default in config.example.yml. The
  #      template is therefore not just documentation but the single source of
  #      the defaults — it cannot drift from the application, because the
  #      application reads it.
  #   2. An invalid value aborts startup, naming the key and the expected
  #      range. No silent substitution: someone who mistypes a port should be
  #      told, not quietly moved back to 9292.
  #   3. Relative paths resolve against the installation directory, not
  #      against this file's directory and not against the working directory
  #      of the calling process (NFA-19, BT-05).
  class Configuration
    # Startup abort. Carries every problem found, not just the first one —
    # otherwise the operator would have to repair the file one line per run.
    class Error < StandardError
      attr_reader :problems

      def initialize(problems)
        @problems = Array(problems)
        super(@problems.join("\n"))
      end
    end

    LOG_LEVELS         = %w[debug info warn error].freeze
    REGISTRATION_MODES = %w[off approval open].freeze

    # Validation rules per key. Keys use dotted paths matching the structure
    # of config.example.yml.
    RULES = {
      'server.host'                         => :host,
      'server.port'                         => :port,
      'server.base_url'                     => :url,
      'server.trusted_proxies'              => :proxy_list,
      'database.path'                       => :path,
      'database.wal'                        => :boolean,
      'session.idle_timeout_days'           => :positive_integer,
      'session.absolute_timeout_days'       => :positive_integer,
      'security.argon2.memory_mib'          => :positive_integer,
      'security.argon2.iterations'          => :positive_integer,
      'security.argon2.parallelism'         => :positive_integer,
      'security.login_attempts_per_account' => :positive_integer,
      'security.login_attempts_per_ip'      => :positive_integer,
      'security.lockout_minutes'            => :positive_integer,
      'security.force_https'                => :boolean,
      'security.registration'               => :registration_mode,
      'security.registrations_per_hour'     => :positive_integer,
      'backup.keep'                         => :positive_integer,
      'retention.revisions_per_prompt'      => :positive_integer,
      'retention.revisions_min_days'        => :non_negative_integer,
      'retention.trash_days'                => :positive_integer,
      'retention.audit_months'              => :positive_integer,
      'retention.audit_max_entries'         => :positive_integer,
      'retention.login_attempts_days'       => :positive_integer,
      'logging.level'                       => :log_level,
      'logging.path'                        => :path,
      'logging.rotate_mb'                   => :positive_integer,
      'logging.keep_files'                  => :positive_integer,
      'locale'                              => :locale
    }.freeze

    # Checks one value against the rule of its key, without a whole
    # installation around it. Used by the settings that are editable in the
    # administration (FA-910): the rules for those live here and nowhere else,
    # so a value typed into a form and a value written into config.yml are
    # judged by the same measure.
    #
    # Returns nil when acceptable, otherwise the description of what was
    # expected.
    def self.check_value(key, value)
      kind = RULES[key.to_s]
      raise ArgumentError, "No validation rule for #{key}" if kind.nil?

      case kind
      when :port
        return nil if integer?(value) && value.between?(1, 65_535)

        I18n.t('config.expected.port')
      when :positive_integer
        return nil if integer?(value) && value.positive?

        I18n.t('config.expected.positive_integer')
      when :non_negative_integer
        return nil if integer?(value) && !value.negative?

        I18n.t('config.expected.non_negative_integer')
      when :boolean
        return nil if [true, false].include?(value)

        I18n.t('config.expected.boolean')
      when :host
        return nil if value.is_a?(String) && !value.strip.empty?

        I18n.t('config.expected.host')
      when :path
        return nil if value.is_a?(String) && !value.strip.empty?

        I18n.t('config.expected.string')
      when :url
        return nil if value.is_a?(String) && value.match?(%r{\Ahttps?://\S+\z})

        I18n.t('config.expected.url')
      when :log_level
        return nil if LOG_LEVELS.include?(value)

        I18n.t('config.expected.log_level', levels: LOG_LEVELS.join(', '))
      when :registration_mode
        return nil if REGISTRATION_MODES.include?(value)

        I18n.t('config.expected.registration_mode', modes: REGISTRATION_MODES.join(', '))
      when :proxy_list
        # A mistyped block must abort rather than be dropped: silently
        # trusting nobody looks like working configuration until the day
        # somebody reads the audit log and finds the proxy's own address in
        # every line.
        return nil if value.is_a?(Array) && value.all? { |entry| TrustedProxy.valid_entry?(entry) }

        I18n.t('config.expected.proxy_list')
      when :locale
        # Empty means "no language chosen for this instance" (11.7): each
        # visitor gets what their browser asks for. `install` writes the whole
        # template into config.yml, so an empty line is what an operator who
        # decided nothing actually ends up with — the alternative, telling a
        # deliberate `en` from an inherited one, cannot be done from the file.
        return nil if value.to_s.empty?
        # The shape, not a file in `app/locales/` — that directory is the
        # console's, and the interface's languages travel in the bundle where
        # this check cannot see them. Tied to the files here, `locale: fr` was
        # refused at startup while the interface had French (AP-22).
        return nil if I18n.offered?(value)

        I18n.t('config.expected.locale')
      else
        raise ArgumentError, "Unknown validation kind #{kind} for #{key}"
      end
    end

    # true and false are not Integers in Ruby, but "port: yes" is a common
    # YAML mistake, so check explicitly rather than relying on duck typing.
    def self.integer?(value)
      value.is_a?(Integer) && !value.is_a?(TrueClass) && !value.is_a?(FalseClass)
    end

    attr_reader :root, :values, :source

    # Loads the configuration.
    #
    # +root+            installation directory (base for all relative paths)
    # +file+            alternative path to config.yml, for tests
    # +template+        alternative path to config.example.yml, for tests
    def self.load(root:, file: nil, template: nil)
      new(root: root, file: file, template: template).tap(&:validate!)
    end

    def initialize(root:, file: nil, template: nil)
      @root            = File.expand_path(root)
      @source          = file     || File.join(@root, 'config', 'config.yml')
      @template_path   = template || File.join(@root, 'config', 'config.example.yml')
      @problems        = []
      @notes           = []

      @defaults = read(@template_path, template: true)
      own       = File.exist?(@source) ? read(@source, template: false) : {}
      @values   = deep_merge(@defaults, own)
      @explicit = flatten(own).keys.to_set
    end

    # Raises Error if anything is wrong, after collecting every problem.
    def validate!
      raise Error, @problems unless @problems.empty?

      check_unknown_keys
      check_values
      check_permissions

      raise Error, @problems unless @problems.empty?

      self
    end

    def notes
      @notes.dup
    end

    # Was the key set in config.yml, or does it come from the template?
    # TF-614 uses this to prove that missing values are filled in.
    def from_template?(key)
      !@explicit.include?(key)
    end

    # Value lookup: configuration['server.port']
    def [](key)
      key.to_s.split('.').reduce(@values) do |node, part|
        node.is_a?(Hash) ? node[part] : nil
      end
    end

    # Resolves a configured path against the installation directory. Absolute
    # paths are taken unchanged (18.4).
    def path(key)
      value = self[key].to_s
      return value if value.empty?

      absolute?(value) ? File.expand_path(value) : File.expand_path(value, @root)
    end

    def database_path = path('database.path')
    def log_path      = path('logging.path')

    def address
      "http://#{self['server.host']}:#{self['server.port']}"
    end

    private

    def absolute?(value)
      # On Windows "C:/..." is absolute without starting with a slash.
      value.start_with?('/') || value.match?(%r{\A[A-Za-z]:[\\/]}) || value.start_with?('\\\\')
    end

    def read(path, template:)
      unless File.exist?(path)
        key = template ? 'config.template_missing' : 'config.file_missing'
        @problems << I18n.t(key, path: path)
        return {}
      end

      content = YAML.safe_load(File.read(path, encoding: 'UTF-8'), permitted_classes: [], aliases: false)
      unless content.is_a?(Hash)
        @problems << I18n.t('config.not_a_mapping', path: path)
        return {}
      end

      content
    rescue Psych::SyntaxError, SystemCallError => e
      @problems << I18n.t('config.unreadable', path: path, reason: e.message)
      {}
    end

    def deep_merge(lower, upper)
      lower.merge(upper) do |_key, a, b|
        a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b
      end
    end

    # Turns a nested mapping into flat dotted paths.
    def flatten(mapping, prefix = nil)
      mapping.each_with_object({}) do |(key, value), result|
        next if key.to_s.start_with?('_')

        path = [prefix, key].compact.join('.')
        if value.is_a?(Hash)
          result.merge!(flatten(value, path))
        else
          result[path] = value
        end
      end
    end

    # Without this, a typo in config.yml would silently use the default: the
    # change would have no effect and the reason would stay invisible.
    # Requirements 18.4 does not demand this check; the strictness is a
    # deliberate addition and is justified in the developer handbook.
    def check_unknown_keys
      allowed = flatten(@defaults).keys.to_set
      (@explicit - allowed).sort.each do |key|
        @problems << I18n.t('config.unknown_key', key: key, path: @source)
      end
    end

    def check_values
      RULES.each do |key, kind|
        value = self[key]
        expected = validate_value(key, value, kind)
        next unless expected

        @problems << I18n.t('config.invalid_value',
                            key: key,
                            path: @source,
                            actual: describe(value),
                            expected: expected)
      end
    end

    def describe(value)
      value.nil? ? I18n.t('config.not_set') : value.inspect
    end

    # One rule per key, kept on the class so that a value typed into the
    # administration form is judged exactly as one written into config.yml.
    def validate_value(key, value, kind)
      self.class.check_value(key, value)
    end

    # SEC-20: the file names the proxies this instance believes, and whoever
    # can widen that list lifts the sign-in limit. Overly open permissions are
    # a note, not an abort — Windows has no equivalent, and aborting there
    # would be unfounded.
    def check_permissions
      return unless File.exist?(@source)
      return if Gem.win_platform?

      mode = File.stat(@source).mode & 0o777
      return if (mode & 0o077).zero?

      @notes << I18n.t('config.permissions_too_open',
                       path: @source, mode: format('%04o', mode))
    end
  end
end
