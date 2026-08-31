# frozen_string_literal: true

require_relative '../../test_helper'

# TF-613 and TF-614 from the test concept (section 10.2), plus the path
# resolution rules from Requirements 18.4 that NFA-19 and BT-05 depend on.
class ConfigurationTest < PromptAtelier::TestCase
  # --- TF-613: invalid configuration -------------------------------------

  def test_tf613_invalid_port_aborts_naming_key_and_range
    dir = install_dir('tf613')
    write_config(dir, valid_config.merge('server' => { 'port' => 70_000 }))

    error = assert_raises(PromptAtelier::Configuration::Error) do
      PromptAtelier::Configuration.load(root: dir)
    end

    message = error.problems.join("\n")
    assert_includes message, 'server.port',
                    'the message must name the offending key'
    assert_includes message, '1 to 65535',
                    'the message must state the expected range'
    assert_includes message, '70000',
                    'the message must show the rejected value'
  end

  def test_tf613_port_zero_and_negative_are_rejected
    [0, -1].each do |port|
      dir = install_dir('tf613b')
      write_config(dir, valid_config.merge('server' => { 'port' => port }))

      assert_raises(PromptAtelier::Configuration::Error, "port #{port} must be rejected") do
        PromptAtelier::Configuration.load(root: dir)
      end
    end
  end

  # A frequent YAML mistake: "port: yes" parses as true, not as a number.
  # Without an explicit check Ruby would happily interpolate it into the bind
  # string and Puma would fail much later with an unhelpful message.
  def test_tf613_boolean_where_a_number_is_expected_is_rejected
    dir = install_dir('tf613c')
    write_config(dir, raw: <<~YAML)
      server:
        port: yes
    YAML

    error = assert_raises(PromptAtelier::Configuration::Error) do
      PromptAtelier::Configuration.load(root: dir)
    end
    assert_includes error.problems.join, 'server.port'
  end

  def test_tf613_unknown_log_level_is_rejected_and_lists_the_valid_ones
    dir = install_dir('tf613d')
    write_config(dir, valid_config.merge('logging' => { 'level' => 'verbose' }))

    error = assert_raises(PromptAtelier::Configuration::Error) do
      PromptAtelier::Configuration.load(root: dir)
    end
    message = error.problems.join
    assert_includes message, 'logging.level'
    assert_includes message, 'debug, info, warn, error'
  end

  # What `locale` is checked against, and what it deliberately is **not**.
  #
  # It used to demand a file in `app/locales/`. That directory holds what the
  # console prints and nothing else; the interface carries its own languages
  # in the bundle, where this check cannot see them. Tied to the files, the
  # rule refused `locale: fr` at startup on an instance whose interface had
  # French — measured in AP-22.
  #
  # So the shape is checked and the set is not. A code the interface does not
  # carry is not an error: the interface answers in English and says so on the
  # first screen. What must still be refused is anything that is not a code —
  # the value ends up in a `Content-Language` header.
  def test_tf613_a_locale_that_is_not_a_language_code_is_rejected
    ['de,en', "de\r\nX: y", '../en', 'english', 'DE'].each do |value|
      dir = install_dir("tf613e-#{value.bytes.sum}")
      write_config(dir, valid_config.merge('locale' => value))

      error = assert_raises(PromptAtelier::Configuration::Error, value.inspect) do
        PromptAtelier::Configuration.load(root: dir)
      end
      assert_includes error.problems.join, 'locale'
    end
  end

  def test_tf613_a_locale_the_server_has_no_table_for_is_accepted
    dir = install_dir('tf613e-ok')
    write_config(dir, valid_config.merge('locale' => 'fr'))

    assert_equal 'fr', PromptAtelier::Configuration.load(root: dir)['locale']
  end

  def test_tf613_every_problem_is_reported_not_only_the_first
    dir = install_dir('tf613f')
    write_config(dir, valid_config.merge(
                        'server'  => { 'port' => 70_000 },
                        'logging' => { 'level' => 'verbose' },
                        'backup'  => { 'keep' => -5 }
                      ))

    error = assert_raises(PromptAtelier::Configuration::Error) do
      PromptAtelier::Configuration.load(root: dir)
    end

    assert_operator error.problems.size, :>=, 3,
                    'the operator should not have to repair the file one line per run'
  end

  # A typo would otherwise silently fall back to the default: the change would
  # have no effect and the reason would stay invisible. Deliberate addition
  # beyond Requirements 18.4, documented in the developer handbook.
  # --- the two settings added with self-registration (FA-107, SEC-07) ------

  def test_an_unknown_registration_mode_is_rejected_and_the_valid_ones_are_named
    dir = install_dir('registration-mode')
    write_config(dir, valid_config.merge('security' => { 'registration' => 'vielleicht' }))

    error = assert_raises(PromptAtelier::Configuration::Error) do
      PromptAtelier::Configuration.load(root: dir)
    end

    assert_includes error.problems.join("\n"), 'security.registration'
    assert_includes error.problems.join("\n"), 'off, approval, open'
  end

  def test_the_three_registration_modes_are_accepted
    %w[off approval open].each do |mode|
      dir = install_dir('registration-ok')
      write_config(dir, valid_config.merge('security' => { 'registration' => mode }))

      configuration = PromptAtelier::Configuration.load(root: dir)
      assert_equal mode, configuration['security.registration']
    end
  end

  # A mistyped block must abort rather than be quietly dropped. Silently
  # trusting nobody looks like a working configuration until somebody reads
  # the log and finds the proxy's own address in every single line.
  def test_a_proxy_entry_that_is_no_address_aborts_naming_the_key
    dir = install_dir('proxies')
    write_config(dir, valid_config.merge(
                        'server' => valid_config['server'].merge(
                          'trusted_proxies' => ['10.0.0.0/8', 'kein-netz']
                        )
                      ))

    error = assert_raises(PromptAtelier::Configuration::Error) do
      PromptAtelier::Configuration.load(root: dir)
    end

    assert_includes error.problems.join("\n"), 'server.trusted_proxies'
  end

  def test_addresses_and_blocks_are_accepted_and_an_empty_list_is_the_delivered_state
    dir = install_dir('proxies-ok')
    write_config(dir, valid_config.merge(
                        'server' => valid_config['server'].merge(
                          'trusted_proxies' => ['127.0.0.1', '10.0.0.0/8', '2001:db8::/32']
                        )
                      ))

    assert_equal 3, PromptAtelier::Configuration.load(root: dir)['server.trusted_proxies'].size

    bare = install_dir('proxies-default')
    write_config(bare, valid_config)
    assert_empty PromptAtelier::Configuration.load(root: bare)['server.trusted_proxies'],
                 'delivered, nobody is believed'
  end

  # A single value where a list belongs is the mistake this catches: YAML
  # accepts `trusted_proxies: 10.0.0.0/8` happily, and the address would then
  # be read character by character.
  def test_a_single_address_instead_of_a_list_is_rejected
    dir = install_dir('proxies-scalar')
    write_config(dir, valid_config.merge(
                        'server' => valid_config['server'].merge('trusted_proxies' => '10.0.0.0/8')
                      ))

    assert_raises(PromptAtelier::Configuration::Error) do
      PromptAtelier::Configuration.load(root: dir)
    end
  end

  # The template is the list of permitted keys (`check_unknown_keys`), and
  # RULES is the list of checked ones. The two are maintained by hand and can
  # drift in one direction **silently**: a key in the template without a rule
  # is accepted with any value at all — a port as a word, a retention period
  # as `false`. The other direction is loud (a rule without a template key
  # validates nil and aborts the start), so only this one needs a test.
  def test_every_key_of_the_template_is_validated
    template = YAML.safe_load(File.read(PromptAtelier::TestSupport.template_path))
    unchecked = flat_keys(template).reject { |key| PromptAtelier::Configuration::RULES.key?(key) }

    assert_empty unchecked,
                 'a key without a rule takes any value at all — including one that breaks the start'
  end

  def flat_keys(mapping, prefix = nil)
    mapping.flat_map do |key, value|
      path = [prefix, key].compact.join('.')
      value.is_a?(Hash) ? flat_keys(value, path) : [path]
    end
  end

  def test_unknown_key_is_rejected
    dir = install_dir('unknown')
    write_config(dir, valid_config.merge('server' => { 'prot' => 9292 }))

    error = assert_raises(PromptAtelier::Configuration::Error) do
      PromptAtelier::Configuration.load(root: dir)
    end
    assert_includes error.problems.join, 'server.prot'
  end

  # --- TF-614: incomplete configuration -----------------------------------

  def test_tf614_missing_values_fall_back_to_the_template_and_start_succeeds
    dir = install_dir('tf614')
    # Only one value is set; everything else must come from the template.
    write_config(dir, { 'server' => { 'base_url' => 'http://example.test' } })

    config = PromptAtelier::Configuration.load(root: dir)

    assert_equal 9292,        config['server.port']
    assert_equal '127.0.0.1', config['server.host']
    assert_equal 'info',      config['logging.level']
    assert_equal 'http://example.test', config['server.base_url'], 'and the one that was set stands'
    assert_equal 14,          config['backup.keep']
    assert_equal true,        config['database.wal']
  end

  def test_tf614_from_template_distinguishes_explicit_from_inherited
    dir = install_dir('tf614b')
    write_config(dir, valid_config.merge('server' => { 'port' => 9500 }))

    config = PromptAtelier::Configuration.load(root: dir)

    refute config.from_template?('server.port'),   'explicitly set'
    assert config.from_template?('logging.level'), 'inherited from the template'
  end

  def test_tf614_an_entirely_missing_config_yml_still_starts
    dir = install_dir('tf614c') # no config.yml written at all

    config = PromptAtelier::Configuration.load(root: dir)

    assert_equal 9292, config['server.port']
  end

  # The template is the single source of the defaults. If it is gone, guessing
  # would be worse than stopping.
  def test_missing_template_aborts
    dir = install_dir('no_template')
    FileUtils.rm(File.join(dir, 'config', 'config.example.yml'))
    write_config(dir, valid_config)

    error = assert_raises(PromptAtelier::Configuration::Error) do
      PromptAtelier::Configuration.load(root: dir)
    end
    assert_includes error.problems.join, 'config.example.yml'
  end

  def test_broken_yaml_is_reported_with_the_file_name
    dir = install_dir('broken')
    write_config(dir, raw: "server:\n  port: [unclosed\n")

    error = assert_raises(PromptAtelier::Configuration::Error) do
      PromptAtelier::Configuration.load(root: dir)
    end
    assert_includes error.problems.join, 'config.yml'
  end

  # --- Path resolution (18.4, NFA-19, BT-05) ------------------------------

  def test_relative_paths_resolve_against_the_installation_directory
    dir = install_dir('paths')
    write_config(dir, valid_config)

    config = PromptAtelier::Configuration.load(root: dir)

    assert_equal File.join(dir, 'data', 'promptatelier.db'), config.database_path
    assert_equal File.join(dir, 'data', 'logs'),             config.log_path
  end

  # The decisive counter-check for BT-05: the result must not depend on where
  # the process happens to be running.
  def test_relative_paths_do_not_depend_on_the_working_directory
    dir = install_dir('cwd')
    write_config(dir, valid_config)

    from_here = PromptAtelier::Configuration.load(root: dir).database_path
    from_tmp  = Dir.chdir(Dir.tmpdir) do
      PromptAtelier::Configuration.load(root: dir).database_path
    end

    assert_equal from_here, from_tmp
  end

  def test_absolute_paths_are_taken_unchanged
    dir      = install_dir('absolute')
    elsewhere = File.join(Dir.tmpdir, 'promptatelier-elsewhere.db')
    write_config(dir, valid_config.merge('database' => { 'path' => elsewhere }))

    config = PromptAtelier::Configuration.load(root: dir)

    assert_equal elsewhere, config.database_path
  end

  def test_open_permissions_are_a_note_not_an_abort
    skip 'no POSIX permissions on Windows' if Gem.win_platform?

    dir  = install_dir('perms')
    path = write_config(dir, valid_config)
    File.chmod(0o644, path)

    config = PromptAtelier::Configuration.load(root: dir)

    refute_empty config.notes
    assert_includes config.notes.join, '0644'
  end
end
