# frozen_string_literal: true

require_relative '../../test_helper'
require 'net/http'
require 'socket'
require 'open3'

# TF-645b, TF-645c, TF-645d — the counter-checks from the startup readiness
# review (Requirements appendix A.5, findings P-1, P-2, P-4).
#
# These tests really start Puma. That is the point: all three defects looked
# plausible on paper and only showed themselves when the process ran. A test
# that stubs the start would reproduce exactly the blind spot that let four
# review rounds pass over them.
class StartupTest < PromptAtelier::TestCase
  BOOT_TIMEOUT = 25 # seconds

  # --- TF-645d: same puma.rb in both layouts ------------------------------

  def test_tf645d_the_same_puma_rb_works_in_the_development_layout
    dir = build_installation(app_dir_name: 'backend')

    with_server(dir) do |port|
      assert_equal({ 'status' => 'ok' }, fetch_json(port, '/health'))
    end
  end

  def test_tf645d_the_same_puma_rb_works_in_the_delivery_layout
    dir = build_installation(app_dir_name: 'app')

    with_server(dir) do |port|
      assert_equal({ 'status' => 'ok' }, fetch_json(port, '/health'))
    end
  end

  # The file must be byte-identical in both layouts — that is the actual
  # promise of 18.2. Copying it with an edit would defeat the purpose.
  def test_tf645d_puma_rb_is_byte_identical_in_both_layouts
    development = build_installation(app_dir_name: 'backend')
    delivery    = build_installation(app_dir_name: 'app')

    assert_equal File.read(File.join(development, 'backend', 'config', 'puma.rb')),
                 File.read(File.join(delivery, 'app', 'config', 'puma.rb'))
  end

  # Counter-check to the former layout: without config/ next to the
  # application directory, path resolution points nowhere.
  def test_tf645d_missing_config_directory_aborts_with_a_readable_message
    dir = build_installation(app_dir_name: 'backend')
    FileUtils.rm_rf(File.join(dir, 'config'))

    output = start_and_capture(dir, 'backend')

    refute_match(/Listening on/, output, 'must not start')
    assert_match(/config\.yml|install/i, output,
                 'the message must say what is missing')
  end

  # --- Binding address -----------------------------------------------------

  # puma.rb must apply the template defaults, not read config.yml raw. With
  # server.host absent the bind string would become "tcp://:9292" and Puma
  # would listen on 0.0.0.0 — the application reachable from the whole network
  # although the configuration never said so.
  def test_tf645e_incomplete_server_section_still_binds_to_the_default_host
    dir = build_installation(app_dir_name: 'backend')
    # config.yml deliberately carries only the port, no host.
    refute File.read(File.join(dir, 'config', 'config.yml')).include?('host'),
           'this test is only meaningful without an explicit host'

    output = capture_boot_banner(dir, 'backend')

    assert_match(%r{Listening on http://127\.0\.0\.1:}, output)
    refute_match(%r{Listening on http://0\.0\.0\.0:}, output,
                 'must not fall back to all interfaces')
  end

  # --- TF-640: the gems come from the bundle, not from the system ---------

  # Deployment mode is what makes a delivery package self-contained. The risk
  # it guards against is invisible on this machine: a system-wide puma would
  # satisfy every start here, and the package would first fail on a machine
  # that has none — after delivery, in front of the operator.
  #
  # An empty GEM_HOME with GEM_PATH unset is that machine, without the minutes
  # a real `bundle install` from scratch would cost. Whether the install
  # itself succeeds on a bare system stays a manual case (BT-18, section 10);
  # what is decidable here is decided here.
  def test_tf640_puma_and_rackup_resolve_without_any_system_gems
    output, status = bundle_without_system_gems('list')

    assert status.success?, "bundle list failed: #{output}"
    assert_match(/^\s*\*\s*puma\s/, output, 'puma has to be part of the bundle')
    assert_match(/^\s*\*\s*rackup\s/, output,
                 'rackup too — without it puma binds but serves nothing, see TF-645c')
    refute_match(/could not find|warning/i, output, 'no warning and no abort')
  end

  def test_tf640_the_resolved_gems_really_live_under_vendor_bundle
    script = 'require "puma"; require "rackup"; ' \
             'puts Gem.loaded_specs["puma"].full_gem_path; ' \
             'puts Gem.loaded_specs["rackup"].full_gem_path'
    output, status = bundle_without_system_gems('exec', 'ruby', '-e', script)

    assert status.success?, output
    paths = output.lines.map(&:strip).reject(&:empty?).last(2)

    assert_equal 2, paths.size, "expected two gem paths, got: #{output}"
    paths.each do |path|
      assert_includes path, File.join('vendor', 'bundle'),
                      "#{path} was resolved from outside the bundle"
    end
  end

  # Deployment mode without a lockfile aborts the install — the combination
  # that cost an afternoon in AP-01.
  def test_tf640_deployment_mode_is_configured_and_has_its_lockfile
    config = File.read(File.join(CODE_ROOT, 'backend', '.bundle', 'config'))

    assert_match(/BUNDLE_DEPLOYMENT:\s*["']?true/, config)
    assert_path_exists File.join(CODE_ROOT, 'backend', 'Gemfile.lock')
  end

  # --- TF-646b: reachable under the installation's own name ----------------

  # Sinatra 4 ships Rack::Protection::HostAuthorization. In development it
  # permits only localhost, *.localhost, *.test and bare IP addresses, and
  # answers everything else with a plain-text "Host not permitted" — not the
  # documented JSON error, so the frontend would show something unhelpful.
  #
  # The delivered start runs in production, where the restriction is lifted.
  # Nothing said so anywhere, and an installation that refused its own
  # hostname would look like a network or proxy fault rather than a setting.
  # This test states the guarantee so a future `set :host_authorization`
  # cannot take it away unnoticed.
  def test_tf646b_an_installation_answers_under_its_own_hostname
    dir = build_installation(app_dir_name: 'backend')

    with_server(dir, 'backend') do |port|
      ['promptatelier.intern', 'prompts.example.com', '192.168.1.50'].each do |host|
        response = get_with_host(port, '/health', host)

        assert_equal '200', response.code,
                     "must answer under #{host}, got #{response.code}: #{response.body[0, 80]}"
      end
    end
  end

  # Counter-check. Without it the test above would keep passing even if the
  # protection had been removed from the stack entirely — it only proves
  # something because the very same call really is refused elsewhere.
  def test_tf646b_the_same_call_is_refused_in_development
    dir = build_installation(app_dir_name: 'backend')

    with_server(dir, 'backend', rack_env: 'development') do |port|
      response = get_with_host(port, '/health', 'promptatelier.intern')

      assert_equal '403', response.code,
                   'if this is no longer refused, the production test proves nothing'
      assert_equal '200', get_with_host(port, '/health', 'localhost').code,
                   'localhost stays reachable, which is what development is for'
    end
  end

  # --- TF-613 through the real start path ---------------------------------

  # The unit test in configuration_test.rb proves that Configuration rejects
  # the value. This proves the operator actually gets to *see* that, because
  # the rejection happens on the path Puma really takes. NT-0 showed the two
  # are not the same thing: the message was produced but drowned in output
  # while the rest of the environment carried on starting.
  def test_tf613_invalid_port_aborts_the_real_start_with_a_readable_message
    dir = build_installation(app_dir_name: 'backend')
    write_config(dir, valid_config.merge('server' => { 'host' => '127.0.0.1', 'port' => 70_000 }))

    output = start_and_capture(dir, 'backend')

    assert_match(/server\.port/, output,            'must name the offending key')
    assert_match(/1 to 65535/, output,             'must state the expected range')
    assert_match(/70000/, output,                   'must show the rejected value')
    refute_match(/Listening on/, output,            'must not start anyway')
  end

  # exit! instead of exit: Puma loads config.ru inside a rescue and would
  # otherwise append "Unable to load application: SystemExit: exit" — a line
  # that says nothing and pushes the real message out of sight.
  def test_tf613_the_abort_is_not_followed_by_puma_noise
    dir = build_installation(app_dir_name: 'backend')
    write_config(dir, valid_config.merge('server' => { 'host' => '127.0.0.1', 'port' => 70_000 }))

    output = start_and_capture(dir, 'backend')

    refute_match(/Unable to load application/, output)
    refute_match(/SystemExit/, output)
  end

  def test_unknown_key_aborts_the_real_start
    dir = build_installation(app_dir_name: 'backend')
    write_config(dir, valid_config.merge('server' => { 'host' => '127.0.0.1',
                                                       'port' => 9292,
                                                       'prot' => 1234 }))

    output = start_and_capture(dir, 'backend')

    assert_match(/server\.prot/, output)
    refute_match(/Listening on/, output)
  end

  # --- TF-623 / TF-624 through the real start path ------------------------

  # schema_guard_test.rb proves the check fires. This proves the operator gets
  # to see it: the message has to survive the way out through Puma, and the
  # server must not come up regardless. NT-0 showed those are separate
  # questions — a check can be correct and still reach nobody.
  def test_tf623_an_unmigrated_database_refuses_to_start_and_says_so
    dir = build_installation(app_dir_name: 'backend', migrate: false)

    output = start_and_capture(dir, 'backend')

    assert_match(/migrate/i, output,     'the message must name the remedy')
    refute_match(/Listening on/, output, 'the server must not come up')
    refute_match(/Unable to load application/, output)
  end

  def test_tf624_a_database_newer_than_the_code_refuses_to_start
    dir = build_installation(app_dir_name: 'backend')
    PromptAtelier::Database.open(File.join(dir, 'data', 'promptatelier.db')) do |db|
      db[:schema_migrations].insert(version: '999_from_the_future', applied_at: Time.now)
    end

    output = start_and_capture(dir, 'backend')

    assert_match(/999_from_the_future/, output)
    refute_match(/Listening on/, output)
  end

  def test_a_migrated_database_starts_normally
    dir = build_installation(app_dir_name: 'backend')

    with_server(dir) do |port|
      assert_equal({ 'status' => 'ok' }, fetch_json(port, '/health'))
    end
  end

  # --- TF-645b: BUNDLE_GEMFILE --------------------------------------------

  def test_tf645b_without_bundle_gemfile_the_start_fails
    dir = build_installation(app_dir_name: 'backend')

    output = start_and_capture(dir, 'backend', with_gemfile_env: false)

    assert_match(/Could not locate Gemfile/i, output)
    refute_match(/Listening on/, output)
  end

  def test_tf645b_with_bundle_gemfile_the_start_succeeds
    dir = build_installation(app_dir_name: 'backend')

    with_server(dir) do |port|
      assert_equal({ 'status' => 'ok' }, fetch_json(port, '/health'))
    end
  end

  # --- TF-645c: the rackup line -------------------------------------------

  def test_tf645c_without_the_rackup_line_puma_binds_but_serves_nothing
    dir  = build_installation(app_dir_name: 'backend')
    puma = File.join(dir, 'backend', 'config', 'puma.rb')

    # Remove exactly the one line and nothing else.
    content = File.read(puma)
    stripped = content.lines.reject { |l| l.start_with?('rackup ') }.join
    refute_equal content, stripped, 'the rackup line must exist to be removed'
    File.write(puma, stripped)

    output = start_and_capture(dir, 'backend')

    assert_match(/No application configured/i, output,
                 'this is the exact failure the rackup line prevents')
  end

  private

  # --- building a throwaway installation ----------------------------------

  # --- starting and stopping ----------------------------------------------

  def start_command(dir, app_dir_name)
    ['bundle', 'exec', 'puma', '-C', File.join(dir, app_dir_name, 'config', 'puma.rb')]
  end

  # Note the explicit nil: the test process itself usually runs with
  # BUNDLE_GEMFILE set, and spawn merges the given hash into the parent
  # environment rather than replacing it. Without nil the child would inherit
  # the variable and TF-645b would silently prove nothing.
  def start_env(dir, app_dir_name, with_gemfile_env:, rack_env: 'production')
    {
      'RACK_ENV'       => rack_env,
      'BUNDLE_GEMFILE' => with_gemfile_env ? File.join(dir, app_dir_name, 'Gemfile') : nil
    }
  end

  # Starts the server, yields the port, and always stops it again.
  def with_server(dir, app_dir_name = nil, rack_env: 'production')
    app_dir_name ||= %w[backend app].find { |n| Dir.exist?(File.join(dir, n)) }
    port = configured_port(dir)

    read_end, write_end = IO.pipe
    pid = spawn(start_env(dir, app_dir_name, with_gemfile_env: true, rack_env: rack_env),
                *start_command(dir, app_dir_name),
                chdir: dir, out: write_end, err: write_end)
    write_end.close

    begin
      assert wait_for_port(port), "server did not come up on port #{port}"
      yield port
    ensure
      stop_process(pid)
      read_end.close
    end
  end

  # Starts the server expecting it to fail, and returns everything it printed.
  #
  # Time-boxed on purpose: a defect may either abort the process or leave it
  # bound to the port doing nothing. The second case would hang the suite, so
  # the reader is drained until the deadline and the process killed either way.
  def start_and_capture(dir, app_dir_name, with_gemfile_env: true)
    read_end, write_end = IO.pipe
    pid = spawn(start_env(dir, app_dir_name, with_gemfile_env: with_gemfile_env),
                *start_command(dir, app_dir_name),
                chdir: dir, out: write_end, err: write_end)
    write_end.close

    output   = +''
    deadline = Time.now + BOOT_TIMEOUT
    while Time.now < deadline
      break if Process.waitpid(pid, Process::WNOHANG)

      ready = IO.select([read_end], nil, nil, 0.2)
      output << read_end.read_nonblock(4096, exception: false).to_s if ready
    end

    stop_process(pid)
    output << read_end.read.to_s
    output
  ensure
    read_end&.close
  end

  # Starts the server, waits for its banner, and stops it again. Used where
  # only Puma's own output matters, not an HTTP response.
  def capture_boot_banner(dir, app_dir_name)
    port = configured_port(dir)
    read_end, write_end = IO.pipe
    pid = spawn(start_env(dir, app_dir_name, with_gemfile_env: true),
                *start_command(dir, app_dir_name),
                chdir: dir, out: write_end, err: write_end)
    write_end.close

    wait_for_port(port)
    output = +''
    while (ready = IO.select([read_end], nil, nil, 0.3))
      chunk = read_end.read_nonblock(4096, exception: false)
      break if chunk.nil? || chunk == :wait_readable

      output << chunk
      break if output.include?('Listening on')
    end
    _ = ready

    stop_process(pid)
    output
  ensure
    read_end&.close
  end

  def wait_for_port(port)
    deadline = Time.now + BOOT_TIMEOUT
    while Time.now < deadline
      begin
        TCPSocket.new('127.0.0.1', port).close
        return true
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
        sleep 0.2
      end
    end
    false
  end

  def fetch_json(port, path)
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}#{path}"))
    JSON.parse(response.body)
  end

  # Runs a bundler command as a machine with no gems of its own would: GEM_HOME
  # points at an empty directory and GEM_PATH is removed entirely, so anything
  # that resolves has to come out of vendor/bundle.
  def bundle_without_system_gems(*arguments)
    empty = install_dir('no-system-gems')
    FileUtils.mkdir_p(empty)

    Open3.capture2e(
      { 'GEM_HOME' => empty, 'GEM_PATH' => nil,
        'BUNDLE_GEMFILE' => File.join(CODE_ROOT, 'backend', 'Gemfile') },
      'bundle', *arguments, chdir: CODE_ROOT
    )
  end

  # Connects to the local port but claims a different name, the way a browser
  # does when the installation is reached under its hostname.
  def get_with_host(port, path, host)
    Net::HTTP.start('127.0.0.1', port) do |http|
      http.request(Net::HTTP::Get.new(path, { 'Host' => host }))
    end
  end

  def stop_process(pid)
    Process.kill('TERM', pid)
    30.times do
      return if Process.waitpid(pid, Process::WNOHANG)

      sleep 0.1
    end
    Process.kill('KILL', pid)
    Process.waitpid(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end
