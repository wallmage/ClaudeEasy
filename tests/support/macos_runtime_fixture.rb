require "fileutils"
require "json"
require "openssl"
require "socket"
require "yaml"

module MacosRuntimeFixture
  def write_release_preferences_fixture(directory, selected: "friend")
    path = File.join(directory, "claude_easy_preferences_fixture.rb")
    File.write(path, <<~RUBY)
      require "json"
      require "open3"

      ClaudeEasyFixtureStatus = Struct.new(:success?)
      module Open3
        class << self
          alias claude_easy_fixture_capture3 capture3

          def capture3(*arguments, **options)
            if arguments[0] == "/usr/bin/defaults" &&
               arguments[1] == "export" &&
               arguments[2] == "com.metacubex.ClashX.meta"
              plist = "<plist><dict><key>selectConfigName</key><string>#{selected}</string></dict></plist>"
              return [plist, "", ClaudeEasyFixtureStatus.new(true)]
            end
            if arguments[0] == "/usr/bin/plutil" &&
               arguments[1] == "-convert" &&
               options[:stdin_data].to_s.include?("selectConfigName")
              return [
                JSON.generate("selectConfigName" => "#{selected}"), "",
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

  def start_release_controller(home)
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
                 JSON.generate("proxies" => {
                   "Main" => { "type" => "Selector", "now" => "node" }
                 })
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
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 1
    certificate.subject = OpenSSL::X509::Name.parse("/CN=www.google.com")
    certificate.issuer = certificate.subject
    certificate.public_key = key.public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + 3600
    extensions = OpenSSL::X509::ExtensionFactory.new
    extensions.subject_certificate = certificate
    extensions.issuer_certificate = certificate
    certificate.add_extension(
      extensions.create_extension("subjectAltName", "DNS:www.google.com")
    )
    certificate.sign(key, OpenSSL::Digest::SHA256.new)

    tcp_server = TCPServer.new("127.0.0.1", 0)
    context = OpenSSL::SSL::SSLContext.new
    context.cert = certificate
    context.key = key
    ssl_server = OpenSSL::SSL::SSLServer.new(tcp_server, context)
    thread = Thread.new do
      client = ssl_server.accept
      client.gets
      while (line = client.gets)
        break if line == "\r\n"
      end
      client.write(
        "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n" \
        "Connection: close\r\n\r\n"
      )
    rescue IOError, Errno::EBADF, OpenSSL::SSL::SSLError
      nil
    ensure
      client&.close rescue nil
    end
    File.write(
      File.join(home, ".curlrc"),
      "insecure\n" \
      "connect-to = \"www.google.com:443:127.0.0.1:#{tcp_server.addr.fetch(1)}\"\n"
    )
    [tcp_server, thread]
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
