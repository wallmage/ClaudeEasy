#!/usr/bin/env ruby

require "coverage"
require "digest"
require "fileutils"
require "tmpdir"

COVERAGE_ROOT = File.expand_path("..", __dir__)
MACOS_RUBY_ROOT = File.join(COVERAGE_ROOT, "claude-easy/scripts/macos")
TARGETS = Dir.glob(File.join(MACOS_RUBY_ROOT, "**", "*.rb")).sort.freeze
VERIFY_ROUTES_PATH = File.join(MACOS_RUBY_ROOT, "verify_routes.rb")
TRANSFORM_PATH = File.join(MACOS_RUBY_ROOT, "patch_profiles", "transform.rb")
PRODUCTION_AGGREGATE_TARGETS = TARGETS.select do |path|
  path != VERIFY_ROUTES_PATH
end.freeze
MINIMUM_PATCHER_LINE_COVERAGE = 100.0
MINIMUM_MODULE_LINE_COVERAGE = 100.0
MINIMUM_VERIFY_LINE_COVERAGE = 100.0
MINIMUM_TRANSFORM_LINE_COVERAGE = 100.0
MINIMUM_PRODUCTION_BRANCH_COVERAGE = 75.0
CHILD_COVERAGE_DIRECTORY = Dir.mktmpdir("claude-easy-ruby-coverage-")
ENV["CLAUDE_EASY_CHILD_COVERAGE_DIRECTORY"] = CHILD_COVERAGE_DIRECTORY
ENV["CLAUDE_EASY_RUN_PRODUCTION_PROBES"] = "1"

def uncovered_line_ranges(lines)
  missing = lines.each_index.select { |index| lines[index] == 0 }.map { |index| index + 1 }
  missing.slice_when { |left, right| right != left + 1 }.map do |range|
    range.length == 1 ? range.first.to_s : "#{range.first}-#{range.last}"
  end
end

def branch_counts(coverage)
  coverage.fetch(:branches).values.flat_map(&:values)
end

def uncovered_branch_lines(coverage)
  coverage.fetch(:branches).values.flat_map do |branches|
    branches.select { |_branch, count| count.zero? }.keys.map { |branch| branch.fetch(2) }
  end.uniq.sort
end

def merge_coverage!(destination, source)
  destination.fetch(:lines).each_index do |index|
    source_count = source.fetch(:lines)[index]
    next unless source_count

    destination.fetch(:lines)[index] += source_count
  end
  source.fetch(:branches).each do |base_branch, branches|
    branches.each do |branch, count|
      destination.fetch(:branches).fetch(base_branch).fetch(branch)
      destination.fetch(:branches).fetch(base_branch)[branch] += count
    end
  end
end

def merge_child_coverage!(result)
  targets_by_digest = TARGETS.group_by { |path| Digest::SHA256.file(path).hexdigest }
  Dir.glob(File.join(CHILD_COVERAGE_DIRECTORY, "*.marshal")).sort.each do |path|
    payload = Marshal.load(File.binread(path))
    payload.fetch(:coverage).each do |source_path, coverage|
      target = if result.key?(source_path)
                 source_path
               else
                 matches = targets_by_digest.fetch(payload.fetch(:digests)[source_path], [])
                 matches.one? ? matches.first : nil
               end
      merge_coverage!(result.fetch(target), coverage) if target
    end
  end
end

def mutable_coverage_result(result)
  result.to_h do |path, coverage|
    branches = coverage.fetch(:branches).to_h do |base_branch, branch_counts|
      [base_branch, branch_counts.dup]
    end
    [path, { lines: coverage.fetch(:lines).dup, branches: branches }]
  end
end

Coverage.start(lines: true, branches: true)
load File.join(__dir__, "test_macos_patcher.rb")

Minitest.after_run do
  begin
    result = mutable_coverage_result(Coverage.result)
    merge_child_coverage!(result)
    failures = []
    TARGETS.each do |path|
      lines = result.fetch(path).fetch(:lines)
      relevant = lines.compact
      covered = relevant.count(&:positive?)
      percentage = covered * 100.0 / relevant.length
      required = if path == VERIFY_ROUTES_PATH
                   MINIMUM_VERIFY_LINE_COVERAGE
                 elsif path == TRANSFORM_PATH
                   MINIMUM_TRANSFORM_LINE_COVERAGE
                 else
                   MINIMUM_MODULE_LINE_COVERAGE
                 end
      puts format(
        "%s: %.2f%% (%d/%d), required %.2f%%",
        path.sub("#{COVERAGE_ROOT}/", ""), percentage, covered, relevant.length, required
      )
      missing = uncovered_line_ranges(lines)
      puts "  uncovered: #{missing.join(', ')}" unless missing.empty?
      branches = branch_counts(result.fetch(path))
      branch_covered = branches.count(&:positive?)
      branch_percentage = branch_covered * 100.0 / branches.length
      puts format("  branches: %.2f%% (%d/%d)", branch_percentage, branch_covered, branches.length)
      missing_branches = uncovered_branch_lines(result.fetch(path))
      puts "  uncovered branch lines: #{missing_branches.join(', ')}" unless missing_branches.empty?
      failures << path if percentage < required
    end

    production_relevant = PRODUCTION_AGGREGATE_TARGETS.sum { |path| result.fetch(path).fetch(:lines).compact.length }
    production_covered = PRODUCTION_AGGREGATE_TARGETS.sum { |path| result.fetch(path).fetch(:lines).compact.count(&:positive?) }
    production_percentage = production_covered * 100.0 / production_relevant
    puts format(
      "macOS Ruby production aggregate: %.2f%% (%d/%d), required %.2f%%",
      production_percentage, production_covered, production_relevant, MINIMUM_PATCHER_LINE_COVERAGE
    )
    failures << "macOS Ruby production aggregate" if production_percentage < MINIMUM_PATCHER_LINE_COVERAGE

    production_branches = TARGETS.flat_map { |path| branch_counts(result.fetch(path)) }
    production_branch_covered = production_branches.count(&:positive?)
    production_branch_percentage = production_branch_covered * 100.0 / production_branches.length
    puts format(
      "macOS Ruby production branch aggregate: %.2f%% (%d/%d), required %.2f%%",
      production_branch_percentage, production_branch_covered, production_branches.length,
      MINIMUM_PRODUCTION_BRANCH_COVERAGE
    )
    if production_branch_percentage < MINIMUM_PRODUCTION_BRANCH_COVERAGE
      failures << "macOS Ruby production branch aggregate"
    end

    abort "Ruby production coverage is below its required threshold" unless failures.empty?
  ensure
    ENV.delete("CLAUDE_EASY_CHILD_COVERAGE_DIRECTORY")
    ENV.delete("CLAUDE_EASY_RUN_PRODUCTION_PROBES")
    FileUtils.remove_entry(CHILD_COVERAGE_DIRECTORY)
  end
end
