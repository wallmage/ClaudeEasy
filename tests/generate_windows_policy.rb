require "json"

root = File.expand_path("..", __dir__)
policy_path = File.join(root, "claude-easy/references/policy.json")
engine_path = File.join(root, "claude-easy/scripts/windows/clash_verge_global.js")
policy = JSON.parse(File.binread(policy_path).force_encoding(Encoding::UTF_8))
mapping = {
  "version" => "version",
  "resolvers" => "resolvers",
  "direct_resolvers" => "directResolvers",
  "bootstrap_fallback_resolvers" => "bootstrapFallbackResolvers",
  "cn_domain_provider" => "cnDomainProvider",
  "main_group_names" => "mainGroupNames",
  "ai_group_names" => "aiGroupNames",
  "taiwan_tokens" => "taiwanTokens",
  "japan_tokens" => "japanTokens",
  "forbidden_ai_domains" => "forbiddenAiDomains",
  "legacy_ai_rules" => "legacyAiRules",
  "ai_rules" => "aiRules"
}
embedded = mapping.each_with_object({}) { |(source, target), result| result[target] = policy.fetch(source) }
block = "// CLAUDEEASY POLICY BEGIN\nconst CLAUDE_EASY_POLICY = #{JSON.pretty_generate(embedded)};\n// CLAUDEEASY POLICY END"
source = File.binread(engine_path).force_encoding(Encoding::UTF_8)
generated = source.sub(%r{// CLAUDEEASY POLICY BEGIN.*?// CLAUDEEASY POLICY END}m, block)
abort "找不到 Windows 策略标记" if generated == source && !source.include?(block)

if ARGV.include?("--check")
  abort "Windows 内嵌策略与 policy.json 不一致" unless generated == source
else
  File.binwrite(engine_path, generated)
end
