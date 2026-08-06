require "fileutils"
require "json"
require "openssl"
require "socket"
require "yaml"

module MacosRuntimeFixture
  def write_release_preferences_fixture(directory, selected: "friend")
    path = File.join(directory, "claude_easy_preferences_fixture.rb")
    File.write(path, <<~RUBY)
      require "open3"

      ClaudeEasyFixtureStatus = Struct.new(:success?)
      module Open3
        class << self
          alias claude_easy_fixture_capture3 capture3
          alias claude_easy_fixture_capture2 capture2
          @claude_easy_auto_update_enabled = true

          def capture2(*arguments, **options)
            if arguments[0] == "/bin/ps" && arguments[1] == "ax"
              home = ENV.fetch("HOME")
              core = File.join(home, "Applications/ClashX Meta.app/Contents/Resources/com.metacubex.ClashX.ProxyConfigHelper.meta")
              config = File.join(home, "Library/Caches/com.MetaCubeX.ClashX.meta/cacheConfigs/active.yaml")
              return [[core, "-f", config].join(" ") + 10.chr, ClaudeEasyFixtureStatus.new(true)]
            end
            claude_easy_fixture_capture2(*arguments, **options)
          end

          def capture3(*arguments, **options)
            if arguments[0] == "/usr/bin/defaults" &&
               arguments[1] == "export" &&
               arguments[2] == "com.metacubex.ClashX.meta"
              auto_update = @claude_easy_auto_update_enabled ? "<true/>" : "<false/>"
              plist = "<plist><dict><key>selectConfigName</key><string>#{selected}</string><key>kAutoUpdateEnable</key>\#{auto_update}</dict></plist>"
              return [plist, "", ClaudeEasyFixtureStatus.new(true)]
            end
            if arguments[0] == "/usr/bin/defaults" &&
               arguments[1] == "write" &&
               arguments[2] == "com.metacubex.ClashX.meta" &&
               arguments[3] == "kAutoUpdateEnable" &&
               arguments[4] == "-bool" &&
               arguments[5] == "false"
              @claude_easy_auto_update_enabled = false
              return ["", "", ClaudeEasyFixtureStatus.new(true)]
            end
            if arguments[0] == "/usr/bin/plutil" &&
               arguments[1] == "-convert" &&
               options[:stdin_data].to_s.include?("selectConfigName")
              return [
                options[:stdin_data], "",
                ClaudeEasyFixtureStatus.new(true)
              ]
            end

            claude_easy_fixture_capture3(*arguments, **options)
          end
        end
      end
    RUBY
    path
  end

  def start_release_controller(home, mixed_port:, selector_names: ["Main"])
    socket_path = File.join(
      "/tmp", "claude-easy-#{Process.pid}-#{rand(1_000_000)}.sock"
    )
    server = UNIXServer.new(socket_path)
    cache = File.join(
      home, "Library", "Caches", "com.MetaCubeX.ClashX.meta", "cacheConfigs"
    )
    FileUtils.mkdir_p(cache)
    File.write(
      File.join(cache, "active.yaml"),
      YAML.dump("external-controller-unix" => socket_path)
    )
    requests = []
    thread = Thread.new do
      loop do
        client = server.accept
        request_line = client.gets.to_s
        headers = {}
        while (line = client.gets)
          break if line == "\r\n"

          key, value = line.split(":", 2)
          headers[key.to_s.downcase] = value.to_s.strip
        end
        client.read(headers.fetch("content-length", "0").to_i)
        _method, target, = request_line.split(" ", 3)
        requests << target
        body = if target == "/proxies"
                 JSON.generate("proxies" => selector_names.to_h do |name|
                   [name, { "type" => "Selector", "now" => "node" }]
                 end)
               elsif target == "/configs"
                 JSON.generate(
                   "mixed-port" => mixed_port,
                   "tun" => { "enable" => false }
                 )
               elsif target&.start_with?("/dns/query?")
                 JSON.generate("Status" => 0, "Answer" => [{ "data" => "127.0.0.1" }])
               else
                 ""
               end
        status = [
          "/configs?force=true", "/cache/fakeip/flush", "/cache/dns/flush"
        ].include?(target) ? 204 : 200
        client.write(
          "HTTP/1.1 #{status} #{status == 204 ? "No Content" : "OK"}\r\n" \
          "Content-Type: application/json\r\n" \
          "Content-Length: #{body.bytesize}\r\n" \
          "Connection: close\r\n\r\n#{body}"
        )
        client.close
      rescue IOError, Errno::EBADF
        break
      ensure
        client&.close rescue nil
      end
    end
    [server, thread, socket_path, requests]
  end

  def start_release_connectivity_server(home)
    ca_key = OpenSSL::PKey::RSA.new(2048)
    ca = OpenSSL::X509::Certificate.new
    ca.version = 2
    ca.serial = 1
    ca.subject = OpenSSL::X509::Name.parse("/CN=ClaudeEasy test CA")
    ca.issuer = ca.subject
    ca.public_key = ca_key.public_key
    ca.not_before = Time.now - 60
    ca.not_after = Time.now + 3600
    ca_extensions = OpenSSL::X509::ExtensionFactory.new
    ca_extensions.subject_certificate = ca
    ca_extensions.issuer_certificate = ca
    ca.add_extension(ca_extensions.create_extension("basicConstraints", "CA:TRUE", true))
    ca.add_extension(ca_extensions.create_extension("keyUsage", "keyCertSign,cRLSign", true))
    ca.sign(ca_key, OpenSSL::Digest::SHA256.new)

    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 2
    certificate.subject = OpenSSL::X509::Name.parse("/CN=www.google.com")
    certificate.issuer = ca.subject
    certificate.public_key = key.public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + 3600
    extensions = OpenSSL::X509::ExtensionFactory.new
    extensions.subject_certificate = certificate
    extensions.issuer_certificate = ca
    certificate.add_extension(
      extensions.create_extension("basicConstraints", "CA:FALSE", true)
    )
    certificate.add_extension(
      extensions.create_extension("keyUsage", "digitalSignature,keyEncipherment", true)
    )
    certificate.add_extension(
      extensions.create_extension("extendedKeyUsage", "serverAuth", false)
    )
    certificate.add_extension(
      extensions.create_extension("subjectAltName", "DNS:www.google.com")
    )
    certificate.sign(ca_key, OpenSSL::Digest::SHA256.new)

    tcp_server = TCPServer.new("127.0.0.1", 0)
    context = OpenSSL::SSL::SSLContext.new
    context.cert = certificate
    context.key = key
    thread = Thread.new do
      loop do
        client = tcp_server.accept
        request_line = client.gets.to_s
        while (line = client.gets)
          break if line == "\r\n"
        end
        unless request_line.start_with?("CONNECT www.google.com:443 ")
          client.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
          client.close
          next
        end
        client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
        ssl = OpenSSL::SSL::SSLSocket.new(client, context)
        ssl.sync_close = true
        ssl.accept
        ssl.gets
        while (line = ssl.gets)
          break if line == "\r\n"
        end
        ssl.write(
          "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n" \
          "Connection: close\r\n\r\n"
        )
        ssl.close
      rescue IOError, Errno::EBADF
        break
      rescue OpenSSL::SSL::SSLError
        client&.close rescue nil
      end
    end
    ca_path = File.join(home, "claude-easy-test-ca.pem")
    File.write(ca_path, ca.to_pem)
    [tcp_server, thread, ca_path, tcp_server.addr.fetch(1)]
  end

  def stop_release_runtime_fixture(controller_server:, controller_thread:,
                                   controller_socket_path:, connectivity_server:,
                                   connectivity_thread:)
    controller_server.close
    connectivity_server.close
    controller_thread.kill
    connectivity_thread.kill
    controller_thread.join
    connectivity_thread.join
    FileUtils.rm_f(controller_socket_path)
  end
end
