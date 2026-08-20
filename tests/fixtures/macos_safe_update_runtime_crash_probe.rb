#!/usr/bin/env ruby

require "json"
require "minitest/mock"
require "yaml"

def persist_child_coverage
  output_path = ENV["CLAUDE_EASY_CHILD_COVERAGE_OUTPUT"]
  return unless output_path

  require "coverage"
  require "digest"
  coverage = Coverage.peek_result
  digests = coverage.each_key.to_h do |path|
    [path, File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil]
  end
  File.binwrite(output_path, Marshal.dump({ coverage: coverage, digests: digests }))
end

root = File.expand_path("../..", __dir__)
require File.join(root, "claude-easy/scripts/macos/patch_profiles.rb")

directory = File.realpath(ARGV.fetch(0))
profile = File.join(directory, "active.yaml")
backup_root = File.join(directory, "backups")
runtime_marker = File.join(directory, "runtime-marker")
gate_seen = File.join(directory, "reload-gated")
policy = JSON.parse(File.read(File.join(root, "claude-easy/references/policy.json")))
target = { name: "active", path: profile, url: "https://fixture.invalid/active" }
identity = {
  pid: 12_345, started: "same",
  executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
}

requester = lambda do |_socket, method, endpoint, body = nil|
  case [method, endpoint]
  when ["GET", "/proxies"]
    [200, JSON.generate("proxies" => {
      "Main" => { "type" => "Selector", "now" => "Taiwan" }
    })]
  when ["GET", "/configs"]
    [200, JSON.generate("tun" => { "enable" => true })]
  when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
    [204, ""]
  else
    if method == "GET" && endpoint.start_with?("/dns/query?")
      [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
    else
      [404, ""]
    end
  end
end

native_reloader = lambda do |_identity|
  ClaudeEasyAppleEvents.send_get_url(12_345, "clash://update-config")
  marker = ClaudeEasy.load_yaml(File.read(profile)).fetch("subscription-marker")
  File.write(runtime_marker, marker)
  if marker == "new-active" && !File.exist?(gate_seen)
    File.write(gate_seen, "1")
    persist_child_coverage
    STDOUT.write(".")
    STDOUT.flush
    STDIN.read(1)
  end
  true
end

ClaudeEasy.stub(:controller_socket, "socket") do
  ClaudeEasy.stub(:controller_request, requester) do
    ClaudeEasy.stub(:default_connectivity_healthy?, true) do
      ClaudeEasy.safe_update_all(
        targets: [target], policy: policy, backup_root: backup_root,
        usage_profile: 1, selected_name: "active",
        fetcher: ->(_item) {
          current = ClaudeEasy.load_yaml(File.read(profile))
          YAML.dump(current.merge("subscription-marker" => "new-active"))
        },
        validator: ->(_path) { true },
        client_identity_reader: -> { identity },
        native_reloader: native_reloader,
        runtime_waiter: ->(*_arguments, **_options) { true },
        generation_reader: -> { "generation" }
      )
    end
  end
end
