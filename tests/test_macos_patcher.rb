require "json"
require "digest"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "socket"
require "stringio"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
PATCHER_PATH = File.join(ROOT, "claude-easy/scripts/macos/patch_profiles.rb")
ROUTE_VERIFIER_PATH = File.join(ROOT, "claude-easy/scripts/macos/verify_routes.rb")
RESULT_CONTRACT_PATH = File.join(ROOT, "claude-easy/scripts/macos/result_contract.rb")
OPERATION_LOCK_PATH = File.join(ROOT, "claude-easy/scripts/macos/operation_lock.rb")
USAGE_PROFILE_STATE_PATH = File.join(
  ROOT, "claude-easy/scripts/macos/usage_profile_state.rb"
)
SAFE_UPDATE_RUNTIME_CRASH_PROBE_PATH = File.join(
  ROOT, "tests/fixtures/macos_safe_update_runtime_crash_probe.rb"
)
POLICY_PATH = File.join(ROOT, "claude-easy/references/policy.json")
MAIN_GROUP_FIXTURES = File.join(ROOT, "tests/fixtures/main_group_cases.json")
PATCHER_AVAILABLE = File.file?(PATCHER_PATH) && File.file?(POLICY_PATH)
CHILD_COVERAGE_DIRECTORY_ENV = "CLAUDE_EASY_CHILD_COVERAGE_DIRECTORY"
CHILD_COVERAGE_RUNNER = <<~'RUBY'
  require "coverage"
  require "digest"

  entrypoint = ARGV.shift
  output_path = ENV.fetch("CLAUDE_EASY_CHILD_COVERAGE_OUTPUT")
  Coverage.start(lines: true, branches: true)
  at_exit do
    coverage = Coverage.result
    digests = coverage.each_key.to_h do |path|
      [path, File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil]
    end
    File.binwrite(output_path, Marshal.dump({ coverage: coverage, digests: digests }))
  end
  $PROGRAM_NAME = entrypoint
  load entrypoint
RUBY

require PATCHER_PATH if PATCHER_AVAILABLE
require ROUTE_VERIFIER_PATH if File.file?(ROUTE_VERIFIER_PATH)
require OPERATION_LOCK_PATH if File.file?(OPERATION_LOCK_PATH)

class MacosPatcherTest < Minitest::Test
  def setup
    skip "patcher not implemented" unless PATCHER_AVAILABLE
    @policy = JSON.parse(File.read(POLICY_PATH)) if PATCHER_AVAILABLE
  end

  def test_route_targets_are_observed_in_parallel_and_any_failure_fails_batch
    requester = lambda do |_method, endpoint, _body = nil|
      payload = case endpoint
                when "/proxies"
                  { "proxies" => {
                    "Proxy" => { "type" => "Selector", "now" => "node-main" },
                    "AI" => { "type" => "Selector", "now" => "node-ai" },
                    "node-main" => { "type" => "Shadowsocks" },
                    "node-ai" => { "type" => "Shadowsocks" }
                  } }
                when "/rules"
                  { "rules" => [{ "type" => "MATCH", "proxy" => "Proxy" }] }
                when "/providers/proxies"
                  { "providers" => {} }
                when "/connections"
                  { "connections" => [] }
                end
      [200, JSON.generate(payload)]
    end
    active = 0
    max_active = 0
    mutex = Mutex.new
    observer = lambda do |_controller, url, _pattern, *_options|
      mutex.synchronize do
        active += 1
        max_active = [max_active, active].max
      end
      sleep 0.05
      url.include?("grok.com") ? nil : { "chains" => ["node-ai", "AI"], "providerChains" => [] }
    ensure
      mutex.synchronize { active -= 1 }
    end

    original_requester = ClaudeEasy.method(:controller_requester)
    original_proxy = ClaudeEasy.method(:runtime_loopback_proxy)
    original_observer = ClashRouteVerifier.method(:observe_connection)
    ClaudeEasy.define_singleton_method(:controller_requester) { requester }
    ClaudeEasy.define_singleton_method(:runtime_loopback_proxy) { "http://127.0.0.1:7890" }
    ClashRouteVerifier.define_singleton_method(:observe_connection, observer)
    refute ClashRouteVerifier.run(details: { checks: [] }, observation_seconds: 1)
  ensure
    ClaudeEasy.define_singleton_method(:controller_requester, original_requester) if original_requester
    ClaudeEasy.define_singleton_method(:runtime_loopback_proxy, original_proxy) if original_proxy
    ClashRouteVerifier.define_singleton_method(:observe_connection, original_observer) if original_observer
    assert_operator max_active, :>=, 2
  end

  def test_storage_preference_requires_a_boolean_plist_value
    status = Struct.new(:success?).new(true)
    preference_domain = ClaudeEasy::AUTO_UPDATE_DOMAINS.first
    plist = "ignored"
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict>
        <key>kUserEnableiCloud</key><string>false</string>
      </dict></plist>
    XML
    runner = lambda do |*_args, **_kwargs|
      [xml, "", status]
    end

    ClaudeEasy.stub(:defaults_export_domain, { domain: preference_domain, plist: plist }) do
      assert_equal(
        [:invalid, nil],
        ClaudeEasy.storage_preference_state(runner: runner, preference_domain: preference_domain)
      )
    end
  end

  def test_missing_storage_preference_uses_unique_local_active_profile
    Dir.mktmpdir do |home|
      local = File.join(home, ".config", "clash.meta")
      FileUtils.mkdir_p(local)
      File.write(File.join(local, "active.yaml"), "proxies: []\n")

      Dir.stub(:home, home) do
        ClaudeEasy.stub(:clashx_app_paths, []) do
          ClaudeEasy.stub(:selected_profile_name, "active") do
            ClaudeEasy.stub(:storage_preference_state, [:missing, nil]) do
              assert_equal :local, ClaudeEasy.storage_mode
              assert_equal [local], ClaudeEasy.default_profile_directories(
                home: home, app_paths: [], selected: "active"
              )
            end

            ClaudeEasy.stub(:storage_preference_state, [:invalid, nil]) do
              assert_equal :unknown, ClaudeEasy.storage_mode
              assert_empty ClaudeEasy.default_profile_directories(
                home: home, app_paths: [], selected: "active"
              )
            end

            cloud = File.join(
              home, "Library", "Mobile Documents", "iCloud~com~metacubex~ClashX", "Documents"
            )
            FileUtils.mkdir_p(cloud)
            File.write(File.join(cloud, "active.yaml"), "proxies: []\n")
            ClaudeEasy.stub(:storage_preference_state, [:missing, nil]) do
              assert_equal :unknown, ClaudeEasy.storage_mode
              assert_empty ClaudeEasy.default_profile_directories(
                home: home, app_paths: [], selected: "active"
              )
            end
          end
        end
      end
    end
  end

  def clashx_native_fetch_integration_script
    script = ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT.dup
    identity_start = script.index("var primaryApplications =")
    request_start = script.index("var url =", identity_start)
    raise "ClashX identity block not found" unless identity_start && request_start

    script[identity_start...request_start] = 'var userAgent = "ClashX Meta/integration-test";' + "\n"
    script.gsub!('urlText.match(/^https:\\/\\//)', 'urlText.match(/^http:\\/\\//)')
    script.gsub!('unwrap(nextURL.scheme).toLowerCase() !== "https"',
                 'unwrap(nextURL.scheme).toLowerCase() !== "http"')
    script.gsub!('unwrap(finalURL.scheme).toLowerCase() !== "https"',
                 'unwrap(finalURL.scheme).toLowerCase() !== "http"')
    script
  end

  def run_clashx_native_fetch_integration(max_bytes: 1024, &server_behavior)
    listener = TCPServer.new("127.0.0.1", 0)
    server = Thread.new do
      Thread.current.report_on_exception = false
      server_behavior.call(listener)
    rescue IOError
      nil
    end
    Open3.capture3(
      "/usr/bin/osascript", "-l", "JavaScript", "-e", clashx_native_fetch_integration_script,
      stdin_data: "2\n#{max_bytes}\nhttp://127.0.0.1:#{listener.addr[1]}/subscription\n",
      binmode: true
    )
  ensure
    listener&.close
    server&.join(1)
    server&.kill if server&.alive?
  end

  def write_http_fixture_response(listener, status:, headers: {}, body: "", include_content_length: true)
    client = listener.accept
    request = +""
    request << client.readpartial(1024) until request.include?("\r\n\r\n")
    fields = { "Connection" => "close" }.merge(headers)
    fields["Content-Length"] = body.bytesize if include_content_length
    client.write(
      "HTTP/1.1 #{status}\r\n#{fields.map { |key, value| "#{key}: #{value}\r\n" }.join}\r\n#{body}"
    )
    client.close
  end

  def test_next_run_recovers_runtime_killed_after_active_reload
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      runtime_state = File.join(directory, "runtime-state.json")
      gate_seen = File.join(directory, "reload-gated")
      original_config = base_config
      original_config["proxy-groups"].reject! { |group| group["name"] == "AI" }
      original_config["rules"] = ["GEOSITE,CN,DIRECT", "MATCH,Main"]
      original = YAML.dump(original_config)
      File.binwrite(profile, original)
      File.write(runtime_state, JSON.generate("Main" => "Taiwan"))
      ready_reader, ready_writer = IO.pipe
      gate_reader, gate_writer = IO.pipe
      child_id = nil
      provider_name = @policy.fetch("cn_domain_provider").fetch("name")
      requester = lambda do |method, endpoint, body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          selections = JSON.parse(File.read(runtime_state))
          proxies = selections.to_h do |name, selected|
            [name, {
              "type" => "Selector", "now" => selected,
              "all" => ["Taiwan", "Japan"]
            }]
          end
          [200, JSON.generate("proxies" => proxies)]
        when ["PUT", "/configs?force=true"]
          path = JSON.parse(body).fetch("path")
          config = ClaudeEasy.load_yaml(File.read(path))
          marker = config.fetch("rule-providers", {}).key?(provider_name) ? "candidate" : "original"
          selections = ClaudeEasy.selectable_groups(config).to_h do |group|
            [group.fetch("name"), "Japan"]
          end
          File.write(runtime_state, JSON.generate(selections))
          if marker == "candidate" && !File.exist?(gate_seen)
            File.write(gate_seen, "1")
            ready_writer.write(".")
            ready_writer.flush
            gate_reader.read(1)
          end
          [204, ""]
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => true })]
        when ["GET", "/providers/proxies"]
          [200, JSON.generate("providers" => {})]
        else
          if method == "PUT" && endpoint.start_with?("/proxies/")
            selections = JSON.parse(File.read(runtime_state))
            group = endpoint.delete_prefix("/proxies/")
            selections[group] = JSON.parse(body).fetch("name")
            File.write(runtime_state, JSON.generate(selections))
            [204, ""]
          elsif method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end

      begin
        child_id = fork do
          ready_reader.close
          gate_writer.close
          ClaudeEasy.run(
            directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
            selected_name: "active", validator: ->(_path) { true },
            auto_reload: true, requester: requester,
            connectivity_checker: -> { true }, usage_profile: 3
          )
          exit! 0
        end
        ready_writer.close
        gate_reader.close
        assert IO.select([ready_reader], nil, nil, 10), "child never loaded the active candidate"
        ready_reader.read(1)
        Process.kill("KILL", child_id)
        _waited_id, status = Process.wait2(child_id)
        child_id = nil
        assert_equal 9, status.termsig
        candidate_selections = JSON.parse(File.read(runtime_state))
        assert_operator candidate_selections.length, :>, 1
        transaction_path = ClaudeEasy.profile_transaction_path(backup_root)
        validator_called = false

        blocked_results = ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
          selected_name: "active", validator: ->(_path) { validator_called = true; false },
          auto_reload: false, requester: requester,
          connectivity_checker: -> { true }, usage_profile: 3
        )

        assert blocked_results.any? do |result|
          result.fetch(:status) == :reload_failed_restore_pending
        end
        refute validator_called
        assert_equal original.b, File.binread(profile)
        assert_equal candidate_selections, JSON.parse(File.read(runtime_state))
        assert File.exist?(transaction_path)

        controller_requester = lambda do |_socket, method, endpoint, body = nil|
          requester.call(method, endpoint, body)
        end
        results = ClaudeEasy.stub(:runtime_loaded_profile_state, :candidate) do
          ClaudeEasy.stub(:controller_socket, "fixture.sock") do
            ClaudeEasy.stub(:controller_request, controller_requester) do
              ClaudeEasy.run(
                directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
                selected_name: "active", validator: ->(_path) { false },
                auto_reload: true, connectivity_checker: -> { true }, usage_profile: 3
              )
            end
          end
        end

        assert results.any? { |result| result.fetch(:status) == :validation_failed }
        assert_equal original.b, File.binread(profile)
        assert_equal({ "Main" => "Taiwan" }, JSON.parse(File.read(runtime_state)))
      ensure
        gate_writer.write(".") rescue nil
        Process.kill("KILL", child_id) rescue nil
        Process.waitpid(child_id) rescue nil
        [ready_reader, ready_writer, gate_reader, gate_writer].each { |io| io.close rescue nil }
      end
    end
  end

  def test_profile_transaction_records_the_pre_reload_runtime_checkpoint
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "new"))
      File.binwrite(profile, original)
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "Taiwan" }
      }

      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.prepare_profile_transaction(
          [{ path: profile, original: original, candidate: candidate }],
          backup_root, roots: [directory], runtime_checkpoint: checkpoint.merge(extra: true)
        )
      end

      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: candidate }],
        backup_root, roots: [directory], runtime_checkpoint: checkpoint
      )
      state = JSON.parse(transaction.fetch(:bytes))
      recovered = ClaudeEasy.recover_profile_transaction(
        backup_root, roots: [directory], keep_transaction: true
      )

      assert_equal 4, state.fetch("Version")
      assert_equal checkpoint, recovered.fetch(:runtime_checkpoint)
    end
  end

  def test_profile_transaction_rejects_a_missing_version_four_runtime_checkpoint
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "new"))
      File.binwrite(profile, original)
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "Taiwan" }
      }
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: candidate }],
        backup_root, roots: [directory], runtime_checkpoint: checkpoint
      )
      transaction_path = ClaudeEasy.profile_transaction_path(backup_root)
      state = JSON.parse(File.binread(transaction_path))
      state.delete("Runtime")
      File.binwrite(transaction_path, JSON.generate(state))

      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.recover_profile_transaction(
          backup_root, roots: [directory], keep_transaction: true
        )
      end
      assert_equal original.b, File.binread(profile)
    end
  end

  def test_runtime_recovery_uses_the_durable_checkpoint_instead_of_damaged_live_state
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      File.binwrite(profile, YAML.dump(base_config))
      selected = "Japan"
      tun_enabled = false
      requester = lambda do |method, endpoint, body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => {
              "type" => "Selector", "now" => selected,
              "all" => ["Taiwan", "Japan"]
            }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => tun_enabled })]
        when ["PUT", "/configs?force=true"]
          selected = "Japan"
          tun_enabled = false
          [204, ""]
        when ["PUT", "/proxies/Main"]
          selected = JSON.parse(body).fetch("name")
          [204, ""]
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          raise "unexpected controller request: #{method} #{endpoint}"
        end
      end
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "Taiwan" }
      }

      restored = ClaudeEasy.reload_recovered_profile_runtime(
        [{ path: profile, active: true }], require_tun: :preserve,
        requester: requester, connectivity_checker: -> { true },
        runtime_checkpoint: checkpoint
      )

      refute restored
      assert_equal "Japan", selected
      refute tun_enabled
    end
  end

  def test_script_subscription_download_uses_the_clashx_native_request_without_exposing_the_url
    refute_respond_to ClaudeEasy, :curl_config_value
    assert_respond_to ClaudeEasy, :fetch_remote_subscription
    refute_respond_to ClaudeEasy, :fetch_remote_subscription_via_mihomo
    assert_operator ClaudeEasy::MAX_REMOTE_SUBSCRIPTION_BYTES, :>, 0
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT,
                    'request.setValueForHTTPHeaderField("zh-CN,zh;q=0.9", "Accept-Language");'
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT,
                    'connection:willSendRequest:redirectResponse:'
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "originalHost"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "originalPort"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "nextURL.host"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "nextURL.port"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT,
                    'protocols: ["NSURLConnectionDataDelegate", "NSURLConnectionDelegate"]'
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "didReceiveData:"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "connection.cancel;"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "data.appendData(receivedData);"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "request.HTTPShouldHandleCookies = false;"
    refute_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT,
                    "URLSession:dataTask:didReceiveResponse:completionHandler:"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "var finalURL = response.URL;"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT,
                    "Number(primaryApplications.count) + Number(alternateApplications.count) !== 1"
    refute_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "Alamofire/"

    status = Struct.new(:success?).new(true)
    capture = lambda do |*arguments, **options|
      assert_equal ["/usr/bin/osascript", "-l", "JavaScript", "-e", ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT], arguments
      refute_includes arguments.join(" "), "example.invalid"
      assert_equal "30\n#{ClaudeEasy::MAX_REMOTE_SUBSCRIPTION_BYTES}\nhttps://example.invalid/subscription\n", options.fetch(:stdin_data)
      [YAML.dump(base_config), "", status]
    end
    Open3.stub(:capture3, capture) do
      ClaudeEasy.fetch_remote_subscription(
        { name: "friend", url: "https://example.invalid/subscription" }
      )
    end
    assert_raises(ClaudeEasy::InvalidConfigError) do
      ClaudeEasy.fetch_remote_subscription({ name: "missing-url" })
    end


    exact = "x" * ClaudeEasy::MAX_REMOTE_SUBSCRIPTION_BYTES
    Open3.stub(:capture3, ->(*_arguments, **_options) { [exact, "", status] }) do
      assert_equal exact, ClaudeEasy.fetch_remote_subscription(
        { name: "friend", url: "https://example.invalid/subscription" }
      )
    end
    oversized = exact + "x"
    Open3.stub(:capture3, ->(*_arguments, **_options) { [oversized, "", status] }) do
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.fetch_remote_subscription(
          { name: "friend", url: "https://example.invalid/subscription" }
        )
      end
    end
  end

  def test_clashx_native_fetch_script_completes_a_real_foundation_request
    skip "JXA Foundation integration requires macOS" unless RbConfig::CONFIG["host_os"].include?("darwin")

    body = "real-foundation-response\n"
    stdout, stderr, status = run_clashx_native_fetch_integration do |listener|
      write_http_fixture_response(
        listener, status: "200 OK", headers: { "Content-Type" => "application/octet-stream" }, body: body
      )
    end

    assert status.success?, stderr
    assert_equal body, stdout
  end

  def test_clashx_native_fetch_script_rejects_an_oversized_real_foundation_response
    skip "JXA Foundation integration requires macOS" unless RbConfig::CONFIG["host_os"].include?("darwin")

    stdout, stderr, status = run_clashx_native_fetch_integration(max_bytes: 32) do |listener|
      write_http_fixture_response(
        listener, status: "200 OK", body: "x" * 64, include_content_length: false
      )
    end

    refute status.success?
    assert_empty stdout
    assert_includes stderr, "subscription request failed"
  end

  def test_clashx_native_fetch_script_follows_a_same_origin_redirect
    skip "JXA Foundation integration requires macOS" unless RbConfig::CONFIG["host_os"].include?("darwin")

    body = "redirected-foundation-response\n"
    stdout, stderr, status = run_clashx_native_fetch_integration do |listener|
      port = listener.addr[1]
      write_http_fixture_response(
        listener, status: "302 Found", headers: { "Location" => "http://127.0.0.1:#{port}/final" }
      )
      write_http_fixture_response(listener, status: "200 OK", body: body)
    end

    assert status.success?, stderr
    assert_equal body, stdout
  end

  def test_clashx_native_request_treats_bridged_application_counts_as_numbers
    lines = ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT.lines
    count_check = lines.select do |line|
      line.include?("primaryApplications =") ||
        line.include?("alternateApplications =") ||
        line.include?("ClashX Meta process is not unique")
    end.join
    count_check.sub!(/var primaryApplications = .*;/, 'var primaryApplications = {count: "1"};')
    count_check.sub!(/var alternateApplications = .*;/, 'var alternateApplications = {count: "0"};')
    script = <<~JAVASCRIPT
      function fail(message) { throw new Error(message); }
      #{count_check}
      "unique";
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3(
      "/usr/bin/osascript", "-l", "JavaScript", "-e", script
    )

    assert status.success?, stderr
    assert_equal "unique\n", stdout
  end

  def test_clashx_native_request_selects_the_nonempty_application_list_with_bridged_counts
    selection = ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT[/var application = .*?alternateApplications\.objectAtIndex\(0\);/m]
    script = <<~JAVASCRIPT
      var primaryApplications = {count: "1", objectAtIndex: function(index) { return "primary"; }};
      var alternateApplications = {count: "0", objectAtIndex: function(index) { return "alternate"; }};
      #{selection}
      application;
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3(
      "/usr/bin/osascript", "-l", "JavaScript", "-e", script
    )

    assert status.success?, stderr
    assert_equal "primary\n", stdout
  end

  def clashx_native_request_error_check
    error_check = ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT.lines.find do |line|
      line.include?("requestError && !requestError.isNil()")
    end
    refute_nil error_check, "native fetch script lost the requestError gate"
    error_check
  end

  def evaluate_clashx_native_request_error_check(request_error_is_nil:)
    script = <<~JAVASCRIPT
      function fail(message) { throw new Error(message); }
      var redirectRejected = false;
      var responseTooLarge = false;
      var finished = true;
      var requestError = {isNil: function() { return #{request_error_is_nil}; }};
      var data = {};
      var response = {};
      #{clashx_native_request_error_check}
      "accepted";
    JAVASCRIPT

    Open3.capture3("/usr/bin/osascript", "-l", "JavaScript", "-e", script)
  end

  def test_clashx_native_request_accepts_an_objective_c_nil_error
    stdout, stderr, status = evaluate_clashx_native_request_error_check(request_error_is_nil: true)

    assert status.success?, stderr
    assert_equal "accepted\n", stdout
  end

  def test_clashx_native_request_rejects_a_non_nil_error
    _stdout, stderr, status = evaluate_clashx_native_request_error_check(request_error_is_nil: false)

    refute status.success?, "non-nil requestError must fail the native fetch gate"
    assert_match(/subscription request failed/, stderr)
  end

  def test_profile_one_restore_rejects_enabled_tun
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      patched = ClaudeEasy.patch(base_config, @policy, usage_profile: 1)
      config = patched.fetch(:config).merge("tun" => { "enable" => true })
      again = ClaudeEasy.patch(config, @policy, usage_profile: 1)
      assert_equal :unchanged, again[:status]
      assert_equal({ "enable" => true }, again[:config]["tun"])

      File.write(path, YAML.dump(config))
      refute ClaudeEasy.restore_candidate_valid?(
        path, 1, policy: @policy, validator: ->(_candidate) { true }
      )
    end
  end

  def test_update_candidate_rejects_encoding_transform_and_validation_failures
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      File.write(path, YAML.dump(base_config))
      target = { name: "friend", path: path }
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.build_update_candidate(target, "\xFF".b, @policy, 3, ->(_path) { true })
      end
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.build_update_candidate(target, YAML.dump({}), @policy, 3, ->(_path) { true })
      end
      assert_raises(ClaudeEasy::SafeUpdateCandidateError) do
        ClaudeEasy.build_update_candidate(target, "[invalid", @policy, 3, ->(_path) { true })
      end

      ClaudeEasy.stub(:patch, { status: :error }) do
        assert_raises(ClaudeEasy::InvalidConfigError) do
          ClaudeEasy.build_update_candidate(
            target, YAML.dump(base_config), @policy, 3, ->(_path) { true }
          )
        end
      end

      [
        { status: :updated, changed: true, config: base_config },
        { status: :updated, changed: false, config: base_config.merge("unexpected" => true) }
      ].each do |second_result|
        results = [
          { status: :updated, changed: true, config: base_config },
          second_result
        ]
        ClaudeEasy.stub(:patch, ->(*_args, **_options) { results.shift }) do
          assert_raises(ClaudeEasy::InvalidConfigError) do
            ClaudeEasy.build_update_candidate(
              target, YAML.dump(base_config), @policy, 3, ->(_path) { true }
            )
          end
        end
        assert_empty results
      end

      patch_calls = 0
      exploding_second_patch = lambda do |*_args, **_options|
        patch_calls += 1
        raise "injected second patch failure" if patch_calls == 2

        { status: :updated, changed: true, config: base_config }
      end
      ClaudeEasy.stub(:patch, exploding_second_patch) do
        assert_raises(ClaudeEasy::SafeUpdateCandidateError) do
          ClaudeEasy.build_update_candidate(
            target, YAML.dump(base_config), @policy, 3, ->(_path) { true }
          )
        end
      end

      [:timeout, false].each do |validation|
        assert_raises(ClaudeEasy::InvalidConfigError) do
          ClaudeEasy.build_update_candidate(
            target, YAML.dump(base_config), @policy, 3, ->(_path) { validation }
          )
        end
      end
    end
  end

  def test_update_candidate_rejects_replacing_anytls_with_shadowsocks
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      current = base_config.merge(
        "proxies" => base_config.fetch("proxies").map { |proxy| proxy.merge("type" => "anytls") }
      )
      File.write(path, YAML.dump(current))

      error = assert_raises(ClaudeEasy::SafeUpdateCandidateError) do
        ClaudeEasy.build_update_candidate(
          { name: "friend", path: path }, YAML.dump(base_config), @policy, 3, ->(_path) { true }
        )
      end

      assert_equal :protocol_regression, error.reason

      shadowsocks = base_config.merge(
        "proxies" => base_config.fetch("proxies").map { |proxy| proxy.merge("type" => "shadowsocks") }
      )
      error = assert_raises(ClaudeEasy::SafeUpdateCandidateError) do
        ClaudeEasy.build_update_candidate(
          { name: "friend", path: path }, YAML.dump(shadowsocks), @policy, 3, ->(_path) { true }
        )
      end
      assert_equal :protocol_regression, error.reason
    end
  end

  def test_recovered_safe_update_runtime_uses_the_saved_checkpoint
    Dir.mktmpdir do |directory|
      path = File.join(directory, "active.yaml")
      File.binwrite(path, YAML.dump(base_config))
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      checkpoint = { path: File.realpath(path), expected_tun: :disabled, selections: {} }
      bytes = File.binread(path)
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: path, original: bytes, candidate: bytes }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      observed_tun = nil
      restored = ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ name: "active", path: path }], 1, "active",
        precommit_condition: -> { true }, runtime_checkpoint: checkpoint,
        transaction: transaction, client_identity: identity,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { true },
        runtime_waiter: lambda { |_current, **options|
          observed_tun = options.fetch(:expected_tun)
          true
        }, reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      )

      assert restored
      assert_equal :disabled, observed_tun
    end
  end

  def test_safe_update_all_leaves_every_profile_untouched_when_one_download_is_invalid
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      targets = %w[first second third].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.to_h { |target| [target.fetch(:path), File.binread(target.fetch(:path))] }
      fetcher = lambda do |target|
        target.fetch(:name) == "second" ? "<html>expired</html>" : YAML.dump(base_config)
      end

      result = ClaudeEasy.safe_update_all(
        targets: targets, policy: @policy, backup_root: backup_root, usage_profile: 3,
        fetcher: fetcher, validator: ->(_path) { true },
        activation: ->(_items) { flunk "must not activate" }, selected_name: "first"
      )

      assert_equal :aborted, result.fetch(:status)
      assert_equal "second", result.fetch(:failed_profile)
      targets.each { |target| assert_equal originals.fetch(target.fetch(:path)), File.binread(target.fetch(:path)) }
      assert_equal 3, Dir.children(backup_root).count { |name| name.include?("--pre-update--") }
      refute_includes JSON.generate(result), "subscriptions.invalid"
    end
  end

  def test_safe_update_all_stops_when_the_running_client_identity_disappears
    Dir.mktmpdir do |directory|
      path = File.join(directory, "active.yaml")
      File.write(path, YAML.dump(base_config))
      target = { name: "active", path: path, url: "https://subscriptions.invalid/active" }

      result = ClaudeEasy.safe_update_all(
        targets: [target], policy: @policy, backup_root: File.join(directory, "backups"),
        usage_profile: 1, fetcher: ->(_item) { YAML.dump(base_config) },
        validator: ->(_path) { true }, selected_name: "active",
        client_identity_reader: -> { nil }
      )

      assert_equal :aborted, result.fetch(:status)
      assert_equal :client_state_changed, result.fetch(:reason)

      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      result = ClaudeEasy.stub(:capture_runtime_checkpoint, nil) do
        ClaudeEasy.safe_update_all(
          targets: [target], policy: @policy, backup_root: File.join(directory, "backups"),
          usage_profile: 1, fetcher: ->(_item) { YAML.dump(base_config) },
          validator: ->(_path) { true }, selected_name: "active",
          client_identity_reader: -> { identity }
        )
      end
      assert_equal :client_state_changed, result.fetch(:reason)
    end
  end

  def test_unchanged_runtime_resolves_required_and_preserved_tun_state
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "台湾家宽 01" },
            "AI" => { "type" => "Selector", "now" => "Main" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        else
          [404, ""]
        end
      end
      expected_tun = []

      ClaudeEasy.stub(:runtime_selections, { "Main" => "台湾家宽 01" }) do
        ClaudeEasy.stub(:runtime_selections_for_profile, { "Main" => "台湾家宽 01" }) do
          ClaudeEasy.stub(:runtime_health_healthy?, true) do
            ClaudeEasy.stub(:runtime_matches_profile?, false) do
              checked = ClaudeEasy.verify_unchanged_profile_runtime(
                { path: profile, status: :unchanged }, requester: requester
              )
              assert_equal :runtime_check_failed, checked.fetch(:status)
            end
          end
        end
      end

      ClaudeEasy.stub(:runtime_matches_profile?, true) do
        ClaudeEasy.stub(:runtime_health_healthy?, lambda { |_requester, **options|
          expected_tun << options.fetch(:expected_tun)
          true
        }) do
          result = { path: profile, status: :unchanged }
          assert_equal result, ClaudeEasy.verify_unchanged_profile_runtime(
            result, requester: requester, require_tun: true
          )
          assert_equal result, ClaudeEasy.verify_unchanged_profile_runtime(
            result, requester: requester, require_tun: :preserve
          )
          assert_equal result, ClaudeEasy.verify_unchanged_profile_runtime(
            result, requester: requester, require_tun: false
          )
        end
      end

      assert_equal [:enabled, :disabled, :ignore], expected_tun
    end
  end

  def test_activation_does_not_reload_runtime_when_tun_is_unknown_before_candidate_load
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config)
      candidate = YAML.dump(base_config.merge("subscription-marker" => "candidate"))
      File.binwrite(profile, candidate)
      stat = File.stat(profile)
      result = {
        path: profile, rollback_bytes: original.b,
        patched_digest: Digest::SHA256.hexdigest(candidate.b),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
      }
      reloads = 0
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => {})]
        when ["PUT", "/configs?force=true"]
          reloads += 1
          [204, ""]
        else
          raise "unexpected controller request: #{method} #{endpoint}"
        end
      end

      activated = ClaudeEasy.activate_updated_profile(
        result, requester: requester, require_tun: :preserve
      )

      assert_equal :reload_failed_rolled_back, activated.fetch(:status)
      assert_equal original.b, File.binread(profile)
      assert_equal 0, reloads
    end
  end

  def test_restore_activation_preserves_the_existing_tun_state
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      candidate = YAML.dump(base_config.merge("changed" => true))
      File.binwrite(profile, candidate)
      proxy_body = JSON.generate(
        "proxies" => { "Main" => { "type" => "Selector", "now" => "Taiwan" } }
      )
      requester = lambda do |method, endpoint, _body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, proxy_body]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        when ["PUT", "/configs?force=true"], ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end

      committed = File.stat(profile)
      result = ClaudeEasy.activate_updated_profile(
        {
          path: profile, rollback_bytes: original.b,
          patched_digest: Digest::SHA256.hexdigest(candidate.b),
          patched_identity: [committed.dev, committed.ino],
          patched_path: File.realpath(profile)
        },
        requester: requester, connectivity_checker: -> { true }, require_tun: :preserve
      )

      assert_equal true, result[:reloaded]
      assert_equal candidate.b, File.binread(profile)
    end
  end

  def test_activation_restores_profile_when_tun_state_is_unknown
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      candidate = YAML.dump(base_config.merge("changed" => true))
      File.binwrite(profile, candidate)
      reloads = 0
      requester = lambda do |method, endpoint, _body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => nil })]
        when ["PUT", "/configs?force=true"]
          reloads += 1
          [204, ""]
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          [404, ""]
        end
      end

      committed = File.stat(profile)
      result = ClaudeEasy.activate_updated_profile(
        {
          path: profile, rollback_bytes: original.b,
          patched_digest: Digest::SHA256.hexdigest(candidate.b),
          patched_identity: [committed.dev, committed.ino],
          patched_path: File.realpath(profile)
        },
        requester: requester, connectivity_checker: -> { true }, require_tun: :preserve
      )

      assert_equal :reload_failed_rolled_back, result.fetch(:status)
      assert_equal original.b, File.binread(profile)
      assert_equal 0, reloads
    end
  end

  def test_tun_state_uses_authoritative_runtime_config
    assert_respond_to ClaudeEasy, :tun_state
    enabled = ->(*_args) { [200, JSON.generate("tun" => { "enable" => true })] }
    disabled = ->(*_args) { [200, JSON.generate("tun" => { "enable" => false })] }
    unavailable = ->(*_args) { [503, ""] }
    malformed = ->(*_args) { [200, "not json"] }
    wrong_shape = ->(*_args) { [200, "[]"] }

    assert_equal :enabled, ClaudeEasy.tun_state(socket: "/tmp/fake.sock", requester: enabled)
    assert_equal :disabled, ClaudeEasy.tun_state(socket: "/tmp/fake.sock", requester: disabled)
    assert_equal :unknown, ClaudeEasy.tun_state(socket: "/tmp/fake.sock", requester: unavailable)
    assert_equal :unknown, ClaudeEasy.tun_state(socket: "/tmp/fake.sock", requester: malformed)
    assert_equal :unknown, ClaudeEasy.tun_state(socket: "/tmp/fake.sock", requester: wrong_shape)
  end

  def test_tun_state_does_not_require_a_local_socket_when_a_requester_is_supplied
    enabled = ->(*_args) { [200, JSON.generate("tun" => { "enable" => true })] }

    ClaudeEasy.stub(:controller_socket, nil) do
      assert_equal :enabled, ClaudeEasy.tun_state(requester: enabled)
    end
    [1, 2, 3].each do |usage_profile|
      assert_equal :preserve, ClaudeEasy.runtime_tun_requirement(usage_profile)
    end
  end

  def test_default_connectivity_waits_between_cold_reload_failures
    failed = Object.new
    failed.define_singleton_method(:success?) { false }
    successful = Object.new
    successful.define_singleton_method(:success?) { true }
    attempts = 0
    delays = []

    Open3.stub(:capture2e, lambda { |*_args|
      attempts += 1
      ["", attempts == 3 ? successful : failed]
    }) do
      ClaudeEasy.stub(:sleep, ->(seconds) { delays << seconds }) do
        assert ClaudeEasy.default_connectivity_healthy?
      end
    end

    assert_equal [1, 1], delays
  end

  def test_tun_connectivity_disables_curl_config_and_every_proxy_source
    success = Object.new
    success.define_singleton_method(:success?) { true }
    invocation = nil

    Open3.stub(:capture2e, lambda { |*arguments|
      invocation = arguments
      ["", success]
    }) do
      assert ClaudeEasy.default_connectivity_healthy?(tun_mode: :enabled)
    end

    environment = invocation.fetch(0)
    arguments = invocation.drop(1)
    %w[http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY].each do |name|
      assert environment.key?(name), name
      assert_nil environment.fetch(name), name
    end
    assert_equal ["/usr/bin/curl", "-q"], arguments.first(2)
    proxy_index = arguments.index("--proxy")
    refute_nil proxy_index
    assert_equal "", arguments.fetch(proxy_index + 1)
    assert_includes arguments, "--noproxy"
    assert_includes arguments, "*"
  end

  def test_runtime_health_rejects_every_partial_health_failure
    requester_for = lambda do |failure|
      lambda do |method, endpoint, _body|
        case [method, endpoint]
        when ["POST", "/cache/fakeip/flush"]
          flunk "runtime health must preserve Fake-IP mappings"
        when ["POST", "/cache/dns/flush"]
          [failure == :dns_flush ? 503 : 204, ""]
        when ["GET", "/configs"]
          tun = failure == :tun ? nil : true
          [200, JSON.generate("tun" => { "enable" => tun })]
        when ["GET", "/proxies"]
          proxies = if failure == :proxy_shape
                      []
                    else
                      selected = failure == :selection ? "Japan" : "Taiwan"
                      { "Main" => { "type" => "Selector", "now" => selected } }
                    end
          [200, JSON.generate("proxies" => proxies)]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            failed_dns = failure == :baidu_dns && endpoint.include?("www.baidu.com")
            [failed_dns ? 503 : 200, JSON.generate("Status" => 0, "Answer" => ["203.0.113.1"])]
          else
            [404, ""]
          end
        end
      end
    end
    selections = { "Main" => "Taiwan" }
    checker = -> { true }

    assert ClaudeEasy.runtime_health_healthy?(
      requester_for.call(nil), selections: selections, expected_tun: :enabled,
      connectivity_checker: checker
    )
    %i[dns_flush tun proxy_shape selection baidu_dns].each do |failure|
      refute ClaudeEasy.runtime_health_healthy?(
        requester_for.call(failure), selections: selections, expected_tun: :enabled,
        connectivity_checker: checker
      ), "runtime health accepted #{failure}"
    end
    refute ClaudeEasy.runtime_health_healthy?(
      requester_for.call(nil), selections: selections, expected_tun: nil,
      connectivity_checker: checker
    )
    refute ClaudeEasy.runtime_health_healthy?(
      requester_for.call(nil), selections: [], expected_tun: :enabled,
      connectivity_checker: checker
    )
    refute ClaudeEasy.runtime_health_healthy?(
      requester_for.call(nil), selections: selections, expected_tun: :enabled,
      connectivity_checker: -> { false }
    )
  end

  def test_runtime_rollback_does_not_patch_tun_when_the_original_subscription_omits_it
    Dir.mktmpdir do |directory|
      path = File.join(directory, "active.yaml")
      original = YAML.dump(base_config.reject { |key, _value| key == "tun" })
      candidate = YAML.dump(base_config.merge("tun" => { "enable" => true }))
      File.binwrite(path, candidate)
      stat = File.stat(path)
      result = {
        path: path, rollback_bytes: original.b,
        patched_digest: Digest::SHA256.hexdigest(candidate.b),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(path)
      }
      tun_enabled = true
      reloads = 0
      config_reads = 0
      patches = []
      requester = lambda do |method, endpoint, body|
        case [method, endpoint]
        when ["GET", "/configs"]
          config_reads += 1
          [200, JSON.generate("tun" => { "enable" => tun_enabled })]
        when ["PUT", "/configs?force=true"]
          reloads += 1
          loaded = ClaudeEasy.load_yaml(File.read(JSON.parse(body).fetch("path")))
          tun_enabled = loaded.dig("tun", "enable") == true
          [204, ""]
        when ["PATCH", "/configs"]
          payload = JSON.parse(body)
          patches << payload
          tun_enabled = payload.dig("tun", "enable") == true
          [204, ""]
        else
          raise "unexpected controller request: #{method} #{endpoint}"
        end
      end
      health_checks = 0
      health = lambda do |_requester, **_options|
        health_checks += 1
        reloads > 1 && tun_enabled
      end

      activated = ClaudeEasy.stub(:runtime_selections, {}) do
        ClaudeEasy.stub(:runtime_health_healthy?, health) do
          ClaudeEasy.stub(:sleep, nil) do
            ClaudeEasy.activate_updated_profile(result, requester: requester, require_tun: true)
          end
        end
      end

      assert_equal :reload_failed_restore_pending, activated.fetch(:status)
      assert_equal original.b, File.binread(path)
      refute tun_enabled
      assert_equal 2, reloads
      assert_equal 3, config_reads
      assert_empty patches
    end
  end

  def test_clashx_native_reload_targets_only_the_existing_process
    identity = {
      pid: 12_345, started: "Thu Aug 20 00:14:18 2026",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    calls = []
    sender = lambda do |pid, url|
      calls << [pid, url]
      true
    end

    assert ClaudeEasy.request_clashx_native_reload(
      identity, sender: sender, process_reader: -> { identity }
    )
    assert_equal [[identity.fetch(:pid), "clash://update-config"]], calls

    refute ClaudeEasy.request_clashx_native_reload(
      identity, sender: ->(*_arguments) { flunk "stale PID must not receive an event" },
      process_reader: -> { identity.merge(pid: 54_321) }
    )
  end

  def test_clashx_runtime_waits_for_profile_match_and_full_health
    identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
    matches = [false, false, true]
    dns_checks = []
    sleeps = 0

    ClaudeEasy.stub(:runtime_health_healthy?, lambda { |_requester, **options|
      dns_checks << options.fetch(:check_dns, true)
      true
    }) do
      requester = ->(*_arguments) {
        [200, JSON.generate("proxies" => {
          "Main" => { "type" => "Selector", "now" => "Taiwan", "all" => ["Taiwan"] }
        })]
      }
      assert ClaudeEasy.wait_for_clashx_safe_runtime(
        identity, selections: { "Main" => "Taiwan" },
        expected_tun: :enabled, requester_factory: -> { requester },
        reload_receipt: {}, reload_receipt_reader: ->(_receipt) { true },
        profile_match_reader: ->(_requester) { matches.shift },
        process_reader: -> { identity }, connectivity_checker: -> { true },
        sleeper: ->(_seconds) { sleeps += 1 }, attempts: 4
      )
    end

    assert_equal 2, sleeps
    assert_equal [true], dns_checks
  end

  def test_clashx_runtime_waits_for_a_new_core_reload_completion_record
    assert_respond_to ClaudeEasy, :clashx_reload_snapshot
    assert_respond_to ClaudeEasy, :clashx_reload_completed_since?

    Dir.mktmpdir do |directory|
      session = File.join(directory, "2026-08-21_17-00-00")
      FileUtils.mkdir_p(session)
      log = File.join(session, "clashx_core_21_17-00-01.log")
      File.binwrite(log, "Initial configuration complete, total time: 10ms\n")
      snapshot = ClaudeEasy.clashx_reload_snapshot(log_root: directory)
      refute_nil snapshot

      File.open(log, "ab") { |handle| handle.write("unrelated runtime log\n") }
      refute ClaudeEasy.clashx_reload_completed_since?(snapshot, log_root: directory)
      File.open(log, "ab") do |handle|
        handle.write("Initial configuration complete, total time: 12ms\n")
      end
      assert ClaudeEasy.clashx_reload_completed_since?(snapshot, log_root: directory)

      rotated_snapshot = ClaudeEasy.clashx_reload_snapshot(log_root: directory)
      rotated_log = File.join(session, "clashx_core_21_17-01-00.log")
      File.binwrite(rotated_log, "Initial configuration complete, total time: 9ms\n")
      assert ClaudeEasy.clashx_reload_completed_since?(rotated_snapshot, log_root: directory)

      ClaudeEasy.stub(:clashx_reload_snapshot, ->(**_options) { raise IOError }) do
        refute ClaudeEasy.clashx_reload_completed_since?(rotated_snapshot, log_root: directory)
      end

      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      receipts = [false, true]
      sleeps = 0
      requester = ->(*_arguments) {
        [200, JSON.generate("proxies" => {
          "Main" => { "type" => "Selector", "now" => "Taiwan", "all" => ["Taiwan"] }
        })]
      }
      ClaudeEasy.stub(:runtime_health_healthy?, true) do
        assert ClaudeEasy.wait_for_clashx_safe_runtime(
          identity, selections: { "Main" => "Taiwan" },
          expected_tun: :enabled, requester_factory: -> { requester },
          reload_receipt: {}, reload_receipt_reader: ->(_receipt) { true },
          profile_match_reader: ->(_requester) { receipts.shift },
          process_reader: -> { identity }, sleeper: ->(_seconds) { sleeps += 1 }, attempts: 3
        )
      end
      assert_equal 1, sleeps
    end
  end

  def test_clashx_reload_receipt_stream_reads_a_live_controller_event
    Dir.mktmpdir do |directory|
      socket_path = File.join(directory, "controller.sock")
      server = UNIXServer.new(socket_path)
      release = Queue.new
      worker = Thread.new do
        client = server.accept
        request = +""
        request << client.readpartial(1024) until request.include?("\r\n\r\n")
        client.write(
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
          "Connection: Upgrade\r\nSec-WebSocket-Accept: fixture\r\n\r\n"
        )
        release.pop
        payload = "{\"type\":\"info\",\"payload\":\"Initial configuration complete, total time: 1ms\"}\n"
        client.write([0x81, payload.bytesize].pack("CC") + payload)
        request
      ensure
        client&.close
      end

      receipt = ClaudeEasy.stub(:controller_secret, "fixture-secret") do
        ClaudeEasy.open_clashx_reload_receipt(socket_path, timeout: 1)
      end
      assert receipt
      release << true
      assert IO.select([receipt.fetch(:socket)], nil, nil, 1)
      assert ClaudeEasy.clashx_reload_receipt_completed?(receipt)
      assert_includes worker.value, "GET /logs?level=info HTTP/1.1"
      assert_includes worker.value, "Upgrade: websocket"
      assert_includes worker.value, "Authorization: Bearer fixture-secret"
      ClaudeEasy.close_clashx_reload_receipt(receipt)
      server.close
    end
  end

  def test_clashx_reload_receipt_helpers_fail_closed_and_bound_the_buffer
    closed = false
    broken_socket = Object.new
    broken_socket.define_singleton_method(:close_on_exec=) { |_value| }
    broken_socket.define_singleton_method(:write) { |_request| raise IOError }
    broken_socket.define_singleton_method(:close) { closed = true }
    UNIXSocket.stub(:new, broken_socket) do
      assert_nil ClaudeEasy.open_clashx_reload_receipt("socket")
    end
    assert closed

    completed_socket = Object.new
    completed_socket.define_singleton_method(:read_nonblock) { |_size, exception:| :wait_readable }
    completed = { socket: completed_socket, buffer: "Initial configuration complete, total time:".b, completed: false }
    assert ClaudeEasy.clashx_reload_receipt_completed?(completed)
    assert completed[:completed]
    assert_empty completed[:buffer]

    reads = ["x", :wait_readable]
    reader = Object.new
    reader.define_singleton_method(:read_nonblock) { |_size, exception:| reads.shift }
    bounded = { socket: reader, buffer: "x" * 65_536, completed: false }
    refute ClaudeEasy.clashx_reload_receipt_completed?(bounded)
    assert_operator bounded.fetch(:buffer).bytesize, :<, 65_536

    raising_reader = Object.new
    raising_reader.define_singleton_method(:read_nonblock) { |_size, exception:| raise IOError }
    refute ClaudeEasy.clashx_reload_receipt_completed?(
      socket: raising_reader, buffer: "", completed: false
    )

    raising_close = Object.new
    raising_close.define_singleton_method(:closed?) { false }
    raising_close.define_singleton_method(:close) { raise IOError }
    refute ClaudeEasy.close_clashx_reload_receipt(socket: raising_close)
  end


  def test_runtime_match_rejects_an_old_in_memory_config
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      File.write(profile, YAML.dump(
        "proxies" => [{ "name" => "New Node", "type" => "ss" }],
        "proxy-groups" => [{ "name" => "Main", "type" => "select", "proxies" => ["New Node"] }]
      ))
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Old Node", "all" => ["Old Node"] },
            "Old Node" => { "type" => "Shadowsocks" }
          })]
        when ["GET", "/providers/proxies"]
          [200, JSON.generate("providers" => {})]
        else
          [0, ""]
        end
      end

      runtime_path_reader = -> { [profile] }
      refute ClaudeEasy.runtime_matches_profile?(
        requester, profile, runtime_path_reader: runtime_path_reader
      )

      loaded = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "New Node", "all" => ["New Node"] },
            "New Node" => { "type" => "Shadowsocks" }
          })]
        when ["GET", "/providers/proxies"]
          [200, JSON.generate("providers" => {})]
        when ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          [0, ""]
        end
      end
      assert ClaudeEasy.runtime_matches_profile?(
        loaded, profile, runtime_path_reader: runtime_path_reader
      )

      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      ClaudeEasy.stub(:runtime_health_healthy?, true) do
        assert ClaudeEasy.wait_for_clashx_safe_runtime(
          identity, selections: { "Main" => "New Node" }, expected_tun: :ignore,
          requester_factory: -> { loaded }, expected_profile_path: profile,
          reload_receipt: {}, reload_receipt_reader: ->(_receipt) { true },
          profile_match_reader: ->(requester) {
            ClaudeEasy.runtime_matches_profile?(
              requester, profile, runtime_path_reader: runtime_path_reader
            )
          },
          process_reader: -> { identity }, attempts: 1
        )
        refute ClaudeEasy.wait_for_clashx_safe_runtime(
          identity, selections: { "Main" => "New Node" }, expected_tun: :ignore,
          requester_factory: -> { loaded }, expected_profile_path: profile,
          reload_receipt_reader: ->(_receipt) { false }, reload_receipt: {},
          process_reader: -> { identity }, attempts: 1
        )
        refute ClaudeEasy.wait_for_clashx_safe_runtime(
          identity, selections: { "Main" => "Old Node" }, expected_tun: :ignore,
          requester_factory: -> { requester }, expected_profile_path: profile,
          process_reader: -> { identity }, attempts: 1
        )
        refute ClaudeEasy.wait_for_clashx_safe_runtime(
          identity, selections: { "Main" => "New Node" }, expected_tun: :ignore,
          requester_factory: -> { loaded }, process_reader: -> { identity },
          attempts: 1
        )
        refute ClaudeEasy.wait_for_clashx_safe_runtime(
          identity, selections: { "Main" => "New Node" }, expected_tun: :ignore,
          requester_factory: -> { loaded }, reload_receipt: {},
          reload_receipt_reader: ->(_before) { true },
          process_reader: -> { identity }, attempts: 1
        )
      end

      refute ClaudeEasy.runtime_matches_profile?(->(*) { raise IOError }, profile)
      refute ClaudeEasy.runtime_matches_profile?(
        loaded, File.join(directory, "missing.yaml")
      )
      File.write(profile, YAML.dump(
        "proxies" => [{ "name" => "New Node", "type" => "ss" }, { "type" => "ss" }],
        "proxy-groups" => [
          { "name" => "Main", "type" => "select", "proxies" => ["New Node"] },
          { "type" => "select" }
        ],
        "proxy-providers" => { "sub" => { "type" => "http" } }
      ))
      refute ClaudeEasy.runtime_matches_profile?(loaded, profile)
      with_provider = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "New Node", "all" => ["New Node"] },
            "New Node" => { "type" => "Shadowsocks" },
            "GLOBAL" => { "type" => "Selector" }
          })]
        when ["GET", "/providers/proxies"]
          [200, JSON.generate("providers" => { "sub" => {} })]
        else
          [0, ""]
        end
      end
      assert ClaudeEasy.runtime_matches_profile?(
        with_provider, profile, runtime_path_reader: runtime_path_reader
      )
      missing_provider = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "New Node", "all" => ["New Node"] },
            "New Node" => { "type" => "Shadowsocks" }
          })]
        when ["GET", "/providers/proxies"]
          [404, ""]
        else
          [0, ""]
        end
      end
      refute ClaudeEasy.runtime_matches_profile?(missing_provider, profile)
      File.write(profile, "[]")
      refute ClaudeEasy.runtime_matches_profile?(loaded, profile)
    end
  end

  def test_safe_reload_uses_the_fresh_receipt_instead_of_the_clashx_bootstrap_config
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      bootstrap = File.join(directory, "bootstrap.yaml")
      File.write(profile, YAML.dump(
        "proxies" => [{ "name" => "New Node", "type" => "ss" }],
        "proxy-groups" => [
          { "name" => "Main", "type" => "select", "proxies" => ["New Node"] }
        ]
      ))
      File.write(bootstrap, YAML.dump(
        "mixed-port" => 7890,
        "external-ui" => "ui",
        "rules" => ["MATCH,DIRECT"]
      ))
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "New Node", "all" => ["New Node"] },
            "New Node" => { "type" => "Shadowsocks" }
          })]
        when ["GET", "/providers/proxies"]
          [200, JSON.generate("providers" => {})]
        when ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          [0, ""]
        end
      end
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }

      ClaudeEasy.stub(:running_mihomo_config_paths, [bootstrap]) do
        ClaudeEasy.stub(:runtime_health_healthy?, true) do
          assert ClaudeEasy.wait_for_clashx_safe_runtime(
            identity, selections: { "Main" => "New Node" }, expected_tun: :ignore,
            requester_factory: -> { requester }, expected_profile_path: profile,
            reload_receipt: {}, reload_receipt_reader: ->(_receipt) { true },
            process_reader: -> { identity }, attempts: 1
          )
        end
      end
    end
  end

  def test_safe_reload_rejects_entries_only_present_in_the_previous_profile
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      File.write(profile, YAML.dump(
        "proxies" => [{ "name" => "New Node", "type" => "ss" }],
        "proxy-groups" => [
          { "name" => "Main", "type" => "select", "proxies" => ["New Node"] }
        ]
      ))
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => {
              "type" => "Selector", "now" => "New Node", "all" => ["New Node", "Old Node"]
            },
            "New Node" => { "type" => "Shadowsocks" },
            "Old Node" => { "type" => "Shadowsocks" }
          })]
        when ["GET", "/providers/proxies"]
          [200, JSON.generate("providers" => {})]
        else
          [0, ""]
        end
      end
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      previous_identity = {
        proxies: ["New Node", "Old Node"],
        groups: { "Main" => ["New Node", "Old Node"] }, providers: []
      }

      refute ClaudeEasy.wait_for_clashx_safe_runtime(
        identity, selections: { "Main" => "New Node" }, expected_tun: :ignore,
        requester_factory: -> { requester }, expected_profile_path: profile,
        previous_profile_identity: previous_identity,
        reload_receipt: {}, reload_receipt_reader: ->(_receipt) { true },
        process_reader: -> { identity }, attempts: 1
      )
    end
  end

  def test_clashx_reload_receipt_ignores_an_old_completion_moved_by_log_rotation
    Dir.mktmpdir do |directory|
      session = File.join(directory, "2026-08-21_17-00-00")
      FileUtils.mkdir_p(session)
      log = File.join(session, "clashx_core_21_17-00-01.log")
      File.binwrite(log, "Initial configuration complete, total time: 10ms\n")
      snapshot = ClaudeEasy.clashx_reload_snapshot(log_root: directory)

      File.rename(log, "#{log}.1")
      File.binwrite(log, "reload started\n")

      refute ClaudeEasy.clashx_reload_completed_since?(snapshot, log_root: directory)
      File.open(log, "ab") do |handle|
        handle.write("Initial configuration complete, total time: 12ms\n")
      end
      assert ClaudeEasy.clashx_reload_completed_since?(snapshot, log_root: directory)
    end
  end

  def test_profile_transaction_allows_each_native_reload_phase_once_per_client_process
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      File.binwrite(profile, "original")
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: "original", candidate: "candidate" }],
        backup_root, roots: [directory],
        runtime_checkpoint: { path: File.realpath(profile), expected_tun: :enabled, selections: {} },
        activation_identity: identity
      )
      candidate_bytes = transaction.fetch(:candidate_bytes).dup

      assert ClaudeEasy.mark_profile_transaction_activation(transaction, :update, identity)
      assert_equal candidate_bytes, transaction.fetch(:candidate_bytes)
      refute ClaudeEasy.mark_profile_transaction_activation(transaction, :update, identity)
      assert ClaudeEasy.mark_profile_transaction_activation(transaction, :rollback, identity)
      assert_equal candidate_bytes, transaction.fetch(:candidate_bytes)
      refute ClaudeEasy.mark_profile_transaction_activation(transaction, :rollback, identity)

      restarted = identity.merge(pid: 54_321, started: "later")
      assert ClaudeEasy.mark_profile_transaction_activation(transaction, :rollback, restarted)
      refute ClaudeEasy.mark_profile_transaction_activation(transaction, :rollback, restarted)
    end
  end

  def test_runtime_checkpoint_detects_user_selection_and_tun_changes
    checkpoint = {
      path: "/profiles/active.yaml", expected_tun: :disabled,
      selections: { "Main" => "Taiwan" }
    }
    requester = lambda do |_method, endpoint, _body = nil|
      case endpoint
      when "/proxies"
        [200, JSON.generate("proxies" => {
          "Main" => { "type" => "Selector", "now" => "Japan" }
        })]
      when "/configs"
        [200, JSON.generate("tun" => { "enable" => true })]
      else
        flunk("unexpected runtime request: #{endpoint}")
      end
    end

    refute ClaudeEasy.runtime_checkpoint_current?(checkpoint, requester: requester)
  end

  def test_safe_update_uses_one_client_native_reload_and_no_controller_reload
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "original"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "candidate"))
      File.binwrite(profile, candidate)
      stat = File.stat(profile)
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      checkpoint = { path: File.realpath(profile), expected_tun: :enabled, selections: {} }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: candidate, candidate: candidate }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      result = {
        path: profile, rollback_bytes: original,
        patched_digest: Digest::SHA256.hexdigest(candidate),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
      }
      reloads = []

      activated = ClaudeEasy.activate_safe_updated_profile(
        result, transaction: transaction, client_identity: identity,
        runtime_checkpoint: checkpoint,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(current) { reloads << current; true },
        runtime_waiter: ->(*_arguments, **_options) { true },
        reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      )

      assert_equal true, activated.fetch(:reloaded)
      assert_equal [identity], reloads
      assert_equal candidate.b, File.binread(profile)
    end
  end

  def test_default_safe_update_wires_the_client_native_reload_path
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      File.binwrite(profile, YAML.dump(base_config.merge("subscription-marker" => "old")))
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :ignore,
        selections: { "Main" => "台湾家宽 01", "AI" => "Main" }
      }
      reloads = 0
      checkpoint_requirement = nil
      checkpoint_reader = lambda do |_path, require_tun:, **_options|
        checkpoint_requirement = require_tun
        checkpoint
      end

      result = ClaudeEasy.stub(:capture_runtime_checkpoint, checkpoint_reader) do
        ClaudeEasy.stub(:runtime_checkpoint_current?, true) do
          ClaudeEasy.safe_update_all(
            targets: [{ name: "friend", path: profile, url: "https://subscriptions.invalid/friend" }],
            policy: @policy, backup_root: backup_root, usage_profile: 1,
            selected_name: "friend",
            fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
            validator: ->(_candidate) { true }, client_identity_reader: -> { identity },
            native_reloader: ->(_current) { reloads += 1; true },
            runtime_waiter: ->(*_arguments, **_options) { true },
            reload_snapshot_reader: -> { { "log" => [1, 2, reloads] } }
          )
        end
      end

      assert_equal :updated, result.fetch(:status), result.inspect
      assert_equal :preserve, checkpoint_requirement
      assert_equal 1, reloads
      assert_equal "new", ClaudeEasy.load_yaml(File.read(profile)).fetch("subscription-marker")
    end
  end

  def test_safe_update_failure_restores_file_and_attempts_native_rollback_only_once
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "original"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "candidate"))
      File.binwrite(profile, candidate)
      stat = File.stat(profile)
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      checkpoint = { path: File.realpath(profile), expected_tun: :enabled, selections: {} }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: candidate, candidate: candidate }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      result = {
        path: profile, rollback_bytes: original,
        patched_digest: Digest::SHA256.hexdigest(candidate),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
      }
      reloads = 0
      waits = [false, true]
      native = ->(_current) { reloads += 1; true }
      waiter = ->(*_arguments, **_options) { waits.shift }

      activated = ClaudeEasy.activate_safe_updated_profile(
        result, transaction: transaction, client_identity: identity,
        runtime_checkpoint: checkpoint, runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: native,
        runtime_waiter: waiter, reload_snapshot_reader: -> { { "log" => [1, 2, reloads] } }
      )

      assert_equal :reload_failed_rolled_back, activated.fetch(:status)
      assert_equal original.b, File.binread(profile)
      assert_equal 2, reloads

      repeated = ClaudeEasy.activate_safe_updated_profile(
        result, transaction: transaction, client_identity: identity,
        runtime_checkpoint: checkpoint,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { flunk "same process must not reload again" },
        runtime_waiter: waiter, reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      )
      assert_equal :reload_failed_restore_pending, repeated.fetch(:status)
    end
  end

  def test_pending_safe_update_recovery_rechecks_runtime_without_repeating_native_reload
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      File.binwrite(profile, YAML.dump(base_config))
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "台湾家宽 01", "AI" => "Main" }
      }
      bytes = File.binread(profile)
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: bytes, candidate: bytes }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      reloads = 0
      options = {
        transaction: transaction, client_identity: identity,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { reloads += 1; true },
        runtime_waiter: ->(*_arguments, **_keywords) { true },
        reload_snapshot_reader: -> { { "log" => [1, 2, reloads] } }
      }

      assert ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ path: profile }], 1, "active", **options
      )
      assert ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ path: profile }], 1, "active", **options
      )
      assert_equal 1, reloads
    end
  end

  def test_pending_safe_update_recovery_keeps_different_candidate_runtime_pending
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config)
      candidate = YAML.dump(base_config.merge("subscription-marker" => "candidate"))
      File.binwrite(profile, original)
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "台湾家宽 01", "AI" => "Main" }
      }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: candidate }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      reloads = 0
      options = {
        transaction: transaction, client_identity: identity,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { reloads += 1; true },
        runtime_waiter: ->(*_arguments, **_keywords) { true },
        reload_snapshot_reader: -> { { "log" => [1, 2, reloads] } }
      }

      assert ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ path: profile }], 1, "active", **options
      )
      refute ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ path: profile }], 1, "active", **options
      )
      assert_equal 1, reloads
    end
  end

  def test_pending_safe_update_recovery_rechecks_the_restored_file_after_runtime_validation
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "台湾家宽 01", "AI" => "Main" }
      }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: original }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      options = {
        transaction: transaction, client_identity: identity,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { true },
        runtime_waiter: ->(*_arguments, **_keywords) { true },
        reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      }
      assert ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ path: profile }], 1, "active", **options
      )

      options[:runtime_waiter] = lambda do |*_arguments, **_keywords|
        File.binwrite(profile, YAML.dump(base_config.merge("external-change" => true)))
        true
      end
      refute ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ path: profile }], 1, "active", **options
      )
    end
  end

  def test_safe_update_recovery_rechecks_the_restored_file_after_first_rollback_event
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "台湾家宽 01", "AI" => "Main" }
      }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: original }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      reloads = 0

      restored = ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ path: profile }], 1, "active",
        transaction: transaction, client_identity: identity,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { reloads += 1; true },
        runtime_waiter: lambda do |*_arguments, **_keywords|
          File.binwrite(profile, YAML.dump(base_config.merge("external-change" => true)))
          true
        end,
        reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      )

      refute restored
      assert_equal 1, reloads
    end
  end

  def test_runtime_activation_covers_required_tun_and_fail_closed_paths
    Dir.mktmpdir do |directory|
      path = File.join(directory, "active.yaml")
      File.binwrite(path, YAML.dump(base_config))
      requester = ->(*_arguments) { [200, "{}"] }
      work_items = [{ path: path, active: true }]

      ClaudeEasy.stub(:runtime_selections, {}) do
        ClaudeEasy.stub(:runtime_selections_for_profile, {}) do
          ClaudeEasy.stub(:reload_profile_runtime, true) do
            ClaudeEasy.stub(:runtime_health_healthy?, true) do
              assert ClaudeEasy.reload_recovered_profile_runtime(
                work_items, require_tun: true, requester: requester
              )
            end
          end
        end
      end

      result = {
        path: path, rollback_bytes: File.binread(path), patched_digest: "digest",
        patched_identity: [0, 0], patched_path: File.realpath(path)
      }
      checkpoint = { path: File.realpath(path), expected_tun: :disabled, selections: {} }
      transaction = { path: path }
      ClaudeEasy.stub(:profile_result_current?, true) do
        ClaudeEasy.stub(:runtime_selections_for_profile, {}) do
          ClaudeEasy.stub(:rollback_before_runtime_reload, :rolled_back) do
            rejected = ClaudeEasy.activate_safe_updated_profile(
              result, transaction: transaction, client_identity: {},
              runtime_checkpoint: checkpoint, precommit_condition: -> { false },
              runtime_checkpoint_checker: ->(_current) { true }
            )
            assert_equal :rolled_back, rejected.fetch(:status)

            pending = ClaudeEasy.activate_safe_updated_profile(
              result, transaction: transaction, client_identity: {},
              runtime_checkpoint: checkpoint,
              runtime_checkpoint_checker: ->(_current) { true },
              reload_snapshot_reader: -> { raise IOError }
            )
            assert_equal :reload_failed_restore_pending, pending.fetch(:status)

            no_socket = ClaudeEasy.stub(:controller_socket, nil) do
              ClaudeEasy.activate_updated_profile(result)
            end
            assert_equal :rolled_back, no_socket.fetch(:status)
          end
        end
      end
      controller_failed = ClaudeEasy.stub(:profile_result_current?, true) do
        ClaudeEasy.stub(:controller_request, ->(*_arguments) { raise IOError }) do
          ClaudeEasy.activate_updated_profile(result, socket: "socket")
        end
      end
      assert_equal :reload_failed_rollback_conflict, controller_failed.fetch(:status)
    end
  end

  def test_v5_transaction_recovery_uses_the_native_safe_update_path
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("marker" => "original"))
      candidate = YAML.dump(base_config.merge("marker" => "candidate"))
      File.binwrite(path, original)
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      current_identity = identity.merge(pid: 54_321, started: "restarted")
      checkpoint = { path: File.realpath(path), expected_tun: :disabled, selections: {} }
      ClaudeEasy.prepare_profile_transaction(
        [{ path: path, original: original, candidate: candidate }],
        backup_root, roots: [directory], runtime_checkpoint: checkpoint,
        activation_identity: identity
      )
      File.binwrite(path, candidate)
      reloads = []
      checkpoint_checks = [false, true]

      ClaudeEasy.stub(:saved_usage_profile, 1) do
        ClaudeEasy.stub(:clashx_running_identity, current_identity) do
          ClaudeEasy.stub(:reload_recovered_profile_runtime, ->(*) { flunk "v5 recovery used controller reload" }) do
            ClaudeEasy.stub(:runtime_selections_for_profile, {}) do
              ClaudeEasy.stub(:open_clashx_reload_receipt, {}) do
                ClaudeEasy.stub(:request_clashx_native_reload, ->(current) { reloads << current; true }) do
                  ClaudeEasy.stub(:wait_for_clashx_safe_runtime, true) do
                    ClaudeEasy.stub(:current_runtime_loaded_profile_state, :candidate) do
                      ClaudeEasy.stub(:capture_runtime_checkpoint, checkpoint) do
                        ClaudeEasy.stub(:runtime_checkpoint_current?, ->(*_arguments, **_options) { checkpoint_checks.shift }) do
                          assert_equal :recovered, ClaudeEasy.resume_profile_transaction(
                            backup_root, roots: [directory], work_items: [{ path: path, active: true }],
                            reload_runtime: true, require_tun: :preserve
                          )
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
      assert_equal [current_identity], reloads
      assert_equal original.b, File.binread(path)
    end
  end

  def test_generated_profile_passes_installed_mihomo_validation
    core = ENV["CLAUDE_EASY_TEST_MIHOMO"]
    if core.to_s.empty?
      flunk "CI required a real Mihomo core but CLAUDE_EASY_TEST_MIHOMO was empty" if ENV["CLAUDE_EASY_REQUIRE_REAL_MIHOMO"] == "1"
      skip "set CLAUDE_EASY_RUN_INSTALLED_CORE_TEST=1 to test the locally installed Mihomo core" unless ENV["CLAUDE_EASY_RUN_INSTALLED_CORE_TEST"] == "1"
      core = ClaudeEasy.mihomo_core_path
      skip "ClashX Meta Mihomo core is not installed" unless core
    end
    assert_equal :supported, ClaudeEasy.mihomo_core_status(core)

    text = <<~YAML
      mixed-port: 7890
      proxies:
        - name: node
          type: socks5
          server: 127.0.0.1
          port: 1080
          username: yes
          password: on
          udp: true
      proxy-groups:
        - name: Main
          type: select
          proxies: [node]
      rules:
        - MATCH,Main
    YAML
    validations = []
    profiles_completed = []
    Dir.mktmpdir do |directory|
      [1, 2, 3].each do |usage_profile|
        profile = File.join(directory, "profile-#{usage_profile}.yaml")
        File.write(profile, text)
        assert_equal true, ClaudeEasy.validate_with_mihomo(profile, core_path: core),
                     "profile #{usage_profile} baseline fixture must be valid"
        validations << { "profile" => usage_profile, "stage" => "baseline" }
        validator = ->(path) { ClaudeEasy.validate_with_mihomo(path, core_path: core) }
        result = ClaudeEasy.patch_path(
          profile, @policy, validator: validator, usage_profile: usage_profile
        )
        assert_equal :updated, result.fetch(:status), "profile #{usage_profile}"
        assert_equal true, ClaudeEasy.validate_with_mihomo(profile, core_path: core),
                     "profile #{usage_profile} patch must stay valid"
        validations << { "profile" => usage_profile, "stage" => "patched" }
        profiles_completed << usage_profile
      end
    end
    assert_equal [1, 2, 3], profiles_completed.sort
    expected_validations = [1, 2, 3].flat_map do |usage_profile|
      [
        { "profile" => usage_profile, "stage" => "baseline" },
        { "profile" => usage_profile, "stage" => "patched" }
      ]
    end
    assert_equal expected_validations, validations
  end

  def base_config
    {
      "proxies" => [
        { "name" => "台湾家宽 01", "type" => "ss", "server" => "tw.example", "password" => "fixture-secret" },
        { "name" => "日本家宽 01", "type" => "ss", "server" => "jp.example", "password" => "fixture-secret" },
        { "name" => "美国家宽 01", "type" => "ss", "server" => "us.example", "password" => "fixture-secret" }
      ],
      "proxy-groups" => [
        { "name" => "Main", "type" => "select", "proxies" => ["台湾家宽 01", "日本家宽 01", "美国家宽 01"] },
        { "name" => "AI", "type" => "select", "proxies" => ["Main"] }
      ],
      "dns" => {
        "enable" => true,
        "nameserver" => ["223.5.5.5"],
        "nameserver-policy" => { "+.example.com,+.example.org" => ["223.5.5.5"] }
      },
      "rules" => [
        "DOMAIN,raw.githubusercontent.com,AI",
        "DOMAIN,storage.googleapis.com,AI",
        "DOMAIN-SUFFIX,friend.example,DIRECT",
        "DOMAIN,static.example.net,DIRECT",
        "GEOSITE,CN,DIRECT",
        "MATCH,Main"
      ]
    }
  end
end
