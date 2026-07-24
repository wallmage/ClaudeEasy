module ClaudeEasy
  module_function

  AI_GROUP_BASE = "🤖 AI · ClaudeEasy".freeze
  SAFE_GROUP_BASE = "🛡 安全代理 · ClaudeEasy".freeze
  MIN_MIHOMO_VERSION = [1, 19, 27].freeze
  MAX_PATCH_ATTEMPTS = 3
  POLICY_VERSION = 1
  AUTO_CORE = Object.new.freeze
  DIRECT_TYPES = %w[direct dns reject pass compatible rematch].freeze
  DIRECT_NAMES = %w[DIRECT REJECT REJECT-DROP PASS PASS-RULE COMPATIBLE REMATCH].freeze
  ROUTE_GROUP_TYPES = %w[select url-test fallback load-balance relay].freeze
  EXCLUDED_SAFE_TYPES = "Direct|Dns|Reject|Pass|Compatible|Rematch".freeze
  LEGACY_QUIC_REJECT_RULE = "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT".freeze
  CN_PROVIDER_SUFFIX = /(?:-[2-9]|-[1-9][0-9]+)?/.freeze

  class InvalidConfigError < StandardError; end

  TUN_POLICY = {
    "enable" => true,
    "stack" => "system",
    "dns-hijack" => ["any:53", "tcp://any:53"],
    "auto-route" => true,
    "auto-detect-interface" => true,
    "strict-route" => true
  }.freeze

  class YAML12ScalarScanner < Psych::ScalarScanner
    INTEGER = /\A[-+]?(?:0|[1-9][0-9_]*|0o[0-7_]+|0x[0-9a-fA-F_]+|0b[01_]+)\z/.freeze
    FLOAT = /\A[-+]?(?:(?:[0-9][0-9_]*)?\.[0-9_]+|[0-9][0-9_]*\.[0-9_]*|[0-9][0-9_]*(?:\.[0-9_]*)?[eE][-+]?[0-9]+)\z/.freeze

    def tokenize(string)
      return nil if string.empty? || string.match?(/\A(?:~|null)\z/i)
      return true if string.match?(/\Atrue\z/i)
      return false if string.match?(/\Afalse\z/i)
      return Float::INFINITY if string.match?(/\A\+?\.inf\z/i)
      return -Float::INFINITY if string.match?(/\A-\.inf\z/i)
      return Float::NAN if string.match?(/\A\.nan\z/i)

      clean = string.delete("_")
      return Integer(clean) if string.match?(INTEGER)
      return Float(clean) if string.match?(FLOAT)

      string
    rescue ArgumentError
      string
    end
  end

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def base_result(config, status, changed: false)
    {
      config: config,
      changed: changed,
      status: status,
      ai_group: nil,
      route_group: nil,
      main_group: nil,
      cn_provider: nil,
      ai_group_created: false,
      ai_group_reset: false
    }
  end

  def managed_cn_provider_name?(name, policy)
    base = policy.dig("cn_domain_provider", "name")
    base.is_a?(String) && name.is_a?(String) && name.match?(/\A#{Regexp.escape(base)}#{CN_PROVIDER_SUFFIX}\z/)
  end

  def cn_provider_path(provider_policy, name)
    base_name = provider_policy.fetch("name")
    base_path = provider_policy.fetch("path")
    suffix = name.delete_prefix(base_name)
    return base_path if suffix.empty?

    extension = File.extname(base_path)
    base_path.delete_suffix(extension) + suffix + extension
  end

  def owned_cn_provider?(name, provider, policy)
    provider_policy = policy["cn_domain_provider"]
    return false unless provider_policy.is_a?(Hash) && provider.is_a?(Hash)
    return false unless managed_cn_provider_name?(name, policy)

    provider["url"] == provider_policy["url"] && provider["path"] == cn_provider_path(provider_policy, name)
  end

  def ensure_cn_provider(config, policy, route_group)
    provider_policy = policy["cn_domain_provider"]
    raise InvalidConfigError, "国内域名规则配置无效" unless provider_policy.is_a?(Hash)

    providers = config["rule-providers"].is_a?(Hash) ? config["rule-providers"] : {}
    config["rule-providers"] = providers
    name = providers.find { |candidate, provider| owned_cn_provider?(candidate, provider, policy) }&.first
    unless name
      base = provider_policy.fetch("name")
      name = base
      sequence = 2
      while providers.key?(name) || providers.any? { |_candidate, provider|
              provider.is_a?(Hash) && provider["path"] == cn_provider_path(provider_policy, name)
            }
        name = "#{base}-#{sequence}"
        sequence += 1
      end
    end
    providers[name] = {
      "type" => provider_policy.fetch("type"),
      "behavior" => provider_policy.fetch("behavior"),
      "format" => provider_policy.fetch("format"),
      "url" => provider_policy.fetch("url"),
      "path" => cn_provider_path(provider_policy, name),
      "interval" => provider_policy.fetch("interval"),
      "proxy" => route_group,
      "size-limit" => provider_policy.fetch("size_limit")
    }
    name
  end

  def patch_common_cn(config, policy, route_group)
    owned_names = if config["rule-providers"].is_a?(Hash)
                    config["rule-providers"].select { |name, provider| owned_cn_provider?(name, provider, policy) }.keys
                  else
                    []
                  end
    provider_name = ensure_cn_provider(config, policy, route_group)
    owned_names << provider_name

    dns = config["dns"].is_a?(Hash) ? config["dns"] : {}
    config["dns"] = dns
    dns["enable"] = true
    dns["respect-rules"] = true
    dns["proxy-server-nameserver"] = deep_copy(policy["bootstrap_fallback_resolvers"]) if Array(dns["proxy-server-nameserver"]).empty?
    dns["nameserver"] = tagged_resolvers(policy, route_group) if Array(dns["nameserver"]).empty?
    dns["direct-nameserver"] = deep_copy(policy["direct_resolvers"])
    dns["direct-nameserver-follow-policy"] = false
    policies = dns["nameserver-policy"].is_a?(Hash) ? deep_copy(dns["nameserver-policy"]) : {}
    policies["rule-set:#{provider_name}"] = deep_copy(policy["direct_resolvers"])
    dns["nameserver-policy"] = policies

    rules = Array(config["rules"]).reject do |rule|
      info = rule_info(rule)
      info[:type] == "RULE-SET" && owned_names.include?(info[:payload])
    end
    insertion = rules.index { |rule| broad_rule?(rule) } || rules.length
    rules.insert(insertion, "RULE-SET,#{provider_name},DIRECT")
    config["rules"] = rules
    provider_name
  end

  def usable_config?(config)
    return false unless config.is_a?(Hash)
    return false unless config["proxy-groups"].is_a?(Array)
    return false if config.key?("rules") && !config["rules"].is_a?(Array)

    config["proxies"].is_a?(Array) || config["proxy-providers"].is_a?(Hash)
  end

  def selectable_groups(config)
    Array(config["proxy-groups"]).select do |group|
      group.is_a?(Hash) && group["name"].is_a?(String) && group["type"].to_s.downcase == "select"
    end
  end

  def route_groups(config)
    Array(config["proxy-groups"]).select do |group|
      group.is_a?(Hash) && group["name"].is_a?(String) &&
        ROUTE_GROUP_TYPES.include?(group["type"].to_s.downcase)
    end
  end

  def managed_name?(name, base)
    name.is_a?(String) && name.match?(/\A#{Regexp.escape(base)}(?: (?:[2-9]|[1-9][0-9]+))?\z/)
  end

  def managed_group_name?(name)
    managed_name?(name, AI_GROUP_BASE) || managed_name?(name, SAFE_GROUP_BASE)
  end

  def detect_main_group(config, policy)
    groups = route_groups(config)
    candidates = groups.reject do |group|
      ai_name?(group["name"], policy) || managed_group_name?(group["name"])
    end
    names = candidates.map { |group| group["name"] }

    match = Array(config["rules"]).reverse.map { |rule| rule_info(rule) }.find { |info| info[:type] == "MATCH" }
    match_target = match && match[:target]
    return match_target if !direct_name?(match_target) && names.include?(match_target)

    references = Hash.new(0)
    Array(config["rules"]).each do |rule|
      next unless broad_rule?(rule)

      target = rule_info(rule)[:target]
      references[target] += 1 if names.include?(target)
    end
    frequent = references.max_by { |name, count| [count, -names.index(name)] }
    return frequent[0] if frequent && frequent[1] > 1

    Array(policy["main_group_names"]).each do |preferred|
      found = names.find { |name| name.casecmp(preferred).zero? }
      return found if found
    end

    candidates.each do |group|
      return group["name"] unless Array(group["use"]).empty?

      members = Array(group["proxies"])
      return group["name"] unless members.empty? || members.all? { |member| direct_name?(member) }
    end
    groups.each do |group|
      return group["name"] unless Array(group["use"]).empty?

      members = Array(group["proxies"])
      return group["name"] unless members.empty? || members.all? { |member| direct_name?(member) }
    end
    groups.first&.fetch("name")
  end

  def ai_name?(name, policy)
    return false unless name.is_a?(String)
    return true if Array(policy["ai_group_names"]).any? { |candidate| name.casecmp(candidate).zero? }

    normalized = name.downcase
    normalized.include?("openai") || normalized.include?("人工智能") || normalized.match?(/(^|[^a-z])ai([^a-z]|$)/)
  end

  def existing_ai_group(config, policy)
    candidates = selectable_groups(config).select { |group| ai_name?(group["name"], policy) }
    candidates.find { |group| !managed_group_name?(group["name"]) } || candidates.first
  end

  def unique_group_name(config, base)
    names = Array(config["proxy-groups"]).map { |group| group["name"] if group.is_a?(Hash) }.compact
    names.concat(Array(config["proxies"]).map { |proxy| proxy["name"] if proxy.is_a?(Hash) }.compact)
    return base unless names.include?(base)

    suffix = 2
    suffix += 1 while names.include?("#{base} #{suffix}")
    "#{base} #{suffix}"
  end

  def managed_ai_group_fingerprint?(group)
    return false unless group.is_a?(Hash)
    return false unless (group.keys - %w[name proxies type use]).empty?
    return false unless %w[name proxies type].all? { |key| group.key?(key) }
    return false unless group["type"].to_s.downcase == "select"

    proxies = group["proxies"]
    providers = group.key?("use") ? group["use"] : []
    return false unless proxies.is_a?(Array) && providers.is_a?(Array)
    return false if proxies.empty? && providers.empty?

    proxies.all? { |name| name.is_a?(String) && name != group["name"] } &&
      providers.all? { |name| name.is_a?(String) && !name.empty? }
  end

  def managed_safe_group_fingerprint?(group)
    expected_keys = %w[empty-fallback exclude-type include-all name proxies type]
    legacy_exclusions = [EXCLUDED_SAFE_TYPES, "Direct|Reject|Pass|Compatible|Rematch", "Direct|Reject|Pass|Compatible"]
    return false unless group.is_a?(Hash) && group.keys.sort == expected_keys.sort
    return false unless group["type"].to_s.downcase == "select" && group["include-all"] == true
    return false unless group["empty-fallback"].to_s.casecmp("REJECT").zero?
    return false unless legacy_exclusions.include?(group["exclude-type"])

    proxies = group["proxies"]
    proxies.is_a?(Array) && proxies.all? { |name| name.is_a?(String) && name != group["name"] }
  end

  def owned_ai_group?(config, name, policy)
    group = selectable_groups(config).find { |item| item["name"] == name }
    return false unless managed_ai_group_fingerprint?(group)

    templates = Array(policy["ai_rules"]) + Array(policy["legacy_ai_rules"])
    keys = templates.map { |template| managed_rule_key(template) }.compact.uniq
    matches = Array(config["rules"]).count do |rule|
      info = rule_info(rule)
      info[:target] == name && keys.include?(managed_rule_key(rule))
    end
    matches >= 2
  end

  def resolver_targets(config)
    dns = config["dns"]
    return [] unless dns.is_a?(Hash)

    fields = %w[nameserver fallback direct-nameserver]
    endpoints = fields.flat_map { |field| Array(dns[field]) }
    if dns["nameserver-policy"].is_a?(Hash)
      endpoints.concat(dns["nameserver-policy"].values.flat_map { |value| Array(value) })
    end
    endpoints.map { |endpoint| resolver_target(endpoint) }.compact
  end

  def owned_safe_group?(config, name)
    group = selectable_groups(config).find { |item| item["name"] == name }
    return false unless managed_safe_group_fingerprint?(group)

    guarded = Array(config["rules"]).each_cons(2).any? do |first, second|
      first_info = rule_info(first)
      second_info = rule_info(second)
      first_info[:type] == "NETWORK" && first_info[:payload].casecmp("UDP").zero? && first_info[:target] == name &&
        second_info[:type] == "NETWORK" && second_info[:payload].casecmp("UDP").zero? &&
        second_info[:target].to_s.casecmp("REJECT").zero?
    end
    guarded && resolver_targets(config).include?(name)
  end

  def find_managed_select_group(config, base, kind, policy = nil)
    selectable_groups(config).find do |group|
      next false unless managed_name?(group["name"], base)

      kind == :ai ? owned_ai_group?(config, group["name"], policy) : owned_safe_group?(config, group["name"])
    end
  end

  def ai_group_sources(config)
    proxies = Array(config["proxies"]).each_with_object([]) do |proxy, names|
      next unless proxy.is_a?(Hash) && proxy["name"].is_a?(String)
      next if proxy["name"].empty? || direct_name?(proxy["name"])
      next if DIRECT_TYPES.include?(proxy["type"].to_s.downcase)

      names << proxy["name"] unless names.include?(proxy["name"])
    end.uniq
    providers = if config["proxy-providers"].is_a?(Hash)
                  config["proxy-providers"].each_with_object([]) do |(name, provider), names|
                    names << name if name.is_a?(String) && !name.empty? && provider.is_a?(Hash)
                  end
                else
                  []
                end
    [proxies, providers]
  end

  def configure_managed_ai_group(group, config)
    proxies, providers = ai_group_sources(config)
    return false if proxies.empty? && providers.empty?

    group.keys.each { |key| group.delete(key) unless %w[name type].include?(key) }
    group["type"] = "select"
    group["proxies"] = proxies
    group["use"] = providers unless providers.empty?
    true
  end

  def ensure_ai_group(config, policy)
    group = find_managed_select_group(config, AI_GROUP_BASE, :ai, policy)
    unless group
      group = { "name" => unique_group_name(config, AI_GROUP_BASE), "type" => "select" }
      config["proxy-groups"] << group
    end

    configure_managed_ai_group(group, config) ? group["name"] : nil
  end

  def direct_name?(name)
    DIRECT_NAMES.any? { |candidate| candidate.casecmp(name.to_s).zero? }
  end

  def owned_managed_group_names(config, policy)
    ai_names = selectable_groups(config).map { |group| group["name"] }.select do |name|
      managed_name?(name, AI_GROUP_BASE) && owned_ai_group?(config, name, policy)
    end
    safe_names = selectable_groups(config).map { |group| group["name"] }.select do |name|
      managed_name?(name, SAFE_GROUP_BASE) && owned_safe_group?(config, name)
    end
    [ai_names, safe_names]
  end

  def remove_owned_managed_groups(config, names)
    owned = names.each_with_object({}) { |name, memo| memo[name] = true }
    config["proxy-groups"] = Array(config["proxy-groups"]).reject do |group|
      group.is_a?(Hash) && owned[group["name"]]
    end
  end

  def tagged_resolvers(policy, group)
    Array(policy["resolvers"]).map { |resolver| "#{resolver}##{group}" }
  end

  def ai_dns_patterns(policy)
    Array(policy["ai_rules"]).each_with_object([]) do |template, patterns|
      type, value, = template.split(",")
      case type
      when "DOMAIN-SUFFIX" then patterns << "+.#{value}"
      when "DOMAIN" then patterns << value
      end
    end.uniq
  end

  def legacy_ai_dns_patterns(policy)
    Array(policy["legacy_ai_rules"]).each_with_object([]) do |template, patterns|
      type, value, = template.split(",")
      case type
      when "DOMAIN-SUFFIX" then patterns << "+.#{value}"
      when "DOMAIN" then patterns << value
      end
    end.uniq
  end

  def safe_proxy_target?(config, target)
    Array(config["proxies"]).any? do |proxy|
      proxy.is_a?(Hash) && proxy["name"] == target && !DIRECT_TYPES.include?(proxy["type"].to_s.downcase)
    end
  end

  def group_cannot_reach_direct?(config, target, visiting = [])
    return false if direct_name?(target) || visiting.include?(target)

    group = Array(config["proxy-groups"]).find { |item| item.is_a?(Hash) && item["name"] == target }
    return false unless group

    return false unless Array(group["use"]).empty?
    return false if group["include-all"] == true || group["include-all-proxies"] == true || group["include-all-providers"] == true

    members = Array(group["proxies"])
    exclusion = group["exclude-filter"].to_s
    unless exclusion.empty?
      # Mihomo applies exclude-filter to explicit members too. Accept only the
      # common RE2-compatible subset so a runtime regex cannot remove every
      # safe member while our check still sees one.
      return false if exclusion.match?(/\(\?(?!i\))/) || exclusion.match?(/\\[1-9]/)

      begin
        matcher = Regexp.new(exclusion)
      rescue RegexpError
        return false
      end
      members = members.reject { |member| matcher.match?(member.to_s) }
    end

    if members.empty?
      # Mihomo defaults an empty group to COMPATIBLE. Only an explicitly named
      # safe inline proxy is acceptable here; proxy groups are not allowed by
      # Mihomo's empty-fallback field.
      return safe_proxy_target?(config, group["empty-fallback"])
    end

    members.all? do |member|
      safe_proxy_target?(config, member) || group_cannot_reach_direct?(config, member, visiting + [target])
    end
  end

  def resolver_target(endpoint)
    fragment = endpoint.to_s.split("#", 2)[1]
    return nil if fragment.nil? || fragment.empty?

    target = fragment.split("&", 2).first.to_s
    return nil if target.empty? || target.include?("=")

    target
  end

  def safe_resolver_endpoint?(config, endpoint)
    return false unless endpoint.to_s.match?(/\A(?:https|tls|quic):\/\//i)

    options = endpoint.to_s.split("#", 2)[1].to_s.split("&").drop(1)
    options.each do |option|
      key, value = option.split("=", 2)
      normalized = key.to_s.downcase
      return false if %w[ecs ecs-override].include?(normalized)
      return false if normalized == "skip-cert-verify" && value.to_s.casecmp("true").zero?
    end

    target = resolver_target(endpoint)
    return false if target.nil? || direct_name?(target)

    safe_proxy_target?(config, target) || group_cannot_reach_direct?(config, target)
  end

  def normalized_resolver_endpoints(config, policy, values)
    return nil unless values.all? { |value| safe_resolver_endpoint?(config, value) }

    values.flat_map do |value|
      fragment = value.to_s.split("#", 2)[1]
      Array(policy["resolvers"]).map { |resolver| "#{resolver}##{fragment}" }
    end.uniq
  end

  def patch_dns(config, policy, route_group, ai_group, owned_safe_names = [], cn_provider_name = nil)
    dns = config["dns"].is_a?(Hash) ? config["dns"] : {}
    config["dns"] = dns
    dns["enable"] = true
    dns["ipv6"] = false
    dns["respect-rules"] = true
    dns["use-hosts"] = true
    dns["use-system-hosts"] = true

    safe_resolvers = tagged_resolvers(policy, route_group)
    ai_resolvers = tagged_resolvers(policy, ai_group)
    fallback_bootstrap = deep_copy(policy["bootstrap_fallback_resolvers"])
    legacy_default = ["1.1.1.1", "8.8.8.8"]
    legacy_proxy = [
      ["1.1.1.1", "8.8.8.8"],
      ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]
    ]
    current_proxy = Array(dns["proxy-server-nameserver"])
    if current_proxy.empty? || legacy_proxy.include?(current_proxy)
      dns["proxy-server-nameserver"] = fallback_bootstrap
    end
    if Array(dns["default-nameserver"]) == legacy_default
      dns["default-nameserver"] = deep_copy(fallback_bootstrap)
    end
    dns["nameserver"] = deep_copy(safe_resolvers)
    dns["fallback"] = deep_copy(safe_resolvers) if dns.key?("fallback")
    dns["direct-nameserver"] = deep_copy(policy["direct_resolvers"])
    dns["direct-nameserver-follow-policy"] = false

    existing = dns["nameserver-policy"].is_a?(Hash) ? dns["nameserver-policy"] : {}
    policies = {}
    legacy_patterns = legacy_ai_dns_patterns(policy)
    existing.each do |combined, endpoints|
      combined.to_s.split(",").map(&:strip).reject(&:empty?).each do |pattern|
        values = Array(endpoints).map(&:to_s)
        legacy_owned = legacy_patterns.include?(pattern) && !values.empty? &&
                       values.all? { |value| owned_safe_names.include?(resolver_target(value)) }
        next if legacy_owned

        references_old_group = values.any? { |value| owned_safe_names.include?(resolver_target(value)) }
        normalized = !references_old_group && !values.empty? ? normalized_resolver_endpoints(config, policy, values) : nil
        policies[pattern] = normalized || deep_copy(safe_resolvers)
      end
    end
    policies["geosite:cn"] = deep_copy(policy["direct_resolvers"])
    policies["rule-set:#{cn_provider_name}"] = deep_copy(policy["direct_resolvers"]) if cn_provider_name
    ai_dns_patterns(policy).each { |pattern| policies[pattern] = deep_copy(ai_resolvers) }
    dns["nameserver-policy"] = policies
  end

  def split_rule_fields(rule)
    fields = []
    buffer = +""
    depth = 0
    rule.to_s.each_char do |character|
      case character
      when "("
        depth += 1
        buffer << character
      when ")"
        depth -= 1 if depth.positive?
        buffer << character
      when ","
        if depth.zero?
          fields << buffer.strip
          buffer = +""
        else
          buffer << character
        end
      else
        buffer << character
      end
    end
    fields << buffer.strip
    fields
  end

  def rule_info(rule)
    parts = split_rule_fields(rule)
    type = parts[0].to_s.upcase
    no_resolve = parts.last.to_s.casecmp("no-resolve").zero?
    target_index = no_resolve ? parts.length - 2 : parts.length - 1
    target = target_index.positive? ? parts[target_index] : nil
    { parts: parts, type: type, payload: parts[1].to_s, target: target }
  end

  def managed_rule_key(rule)
    info = rule_info(rule)
    return nil if info[:type].empty? || info[:payload].empty?

    [info[:type], info[:payload].downcase]
  end

  def managed_rule_identity(rule)
    info = rule_info(rule)
    key = managed_rule_key(rule)
    key && info[:target] ? key + [info[:target]] : nil
  end

  def render_ai_rules(policy, ai_group)
    Array(policy["ai_rules"]).map { |template| template.sub("{AI}") { ai_group } }
  end

  def broad_rule?(rule)
    %w[MATCH GEOSITE GEOIP RULE-SET].include?(rule_info(rule)[:type])
  end

  def patch_rules(config, policy, ai_group, route_group, owned_ai_names = [], owned_safe_names = [])
    managed = render_ai_rules(policy, ai_group)
    managed_keys = managed.map { |rule| managed_rule_key(rule) }.compact
    managed_identities = managed.map { |rule| managed_rule_identity(rule) }.compact
    legacy_keys = Array(policy["legacy_ai_rules"]).map { |rule| managed_rule_key(rule) }.compact
    forbidden = Array(policy["forbidden_ai_domains"])

    original_rules = Array(config["rules"])
    owned_udp_indexes = []
    original_rules.each_with_index do |rule, index|
      if rule.to_s.gsub(/\s+/, "").casecmp(LEGACY_QUIC_REJECT_RULE).zero?
        owned_udp_indexes << index
        next
      end

      info = rule_info(rule)
      next unless info[:type] == "NETWORK" && info[:payload].casecmp("UDP").zero? &&
                  (owned_safe_names.include?(info[:target]) || [route_group, ai_group].include?(info[:target]))

      owned_udp_indexes << index
      next_info = rule_info(original_rules[index + 1]) if index + 1 < original_rules.length
      if next_info && next_info[:type] == "NETWORK" && next_info[:payload].casecmp("UDP").zero? &&
         next_info[:target].to_s.casecmp("REJECT").zero?
        owned_udp_indexes << index + 1
      end
    end

    user_overrides = []
    remaining = []
    original_rules.each_with_index do |rule, index|
      next if owned_udp_indexes.include?(index)

      info = rule_info(rule)
      key = managed_rule_key(rule)
      patch_owned_ai = owned_ai_names.include?(info[:target]) && managed_keys.include?(key)
      exact_current_ai = managed_identities.include?(managed_rule_identity(rule))
      legacy_owned_ai = legacy_keys.include?(key) && owned_ai_names.include?(info[:target])
      forbidden_ai = %w[DOMAIN DOMAIN-SUFFIX].include?(info[:type]) &&
                     forbidden.any? { |domain| domain.casecmp(info[:payload]).zero? } &&
                     owned_ai_names.include?(info[:target])
      main_group_ai = managed_keys.include?(key) && info[:target] == route_group
      next if patch_owned_ai || exact_current_ai || legacy_owned_ai || forbidden_ai || main_group_ai

      if managed_keys.include?(key)
        user_overrides << rule
      else
        remaining << rule
      end
    end

    config["rules"] = ["NETWORK,UDP,#{ai_group}", "NETWORK,UDP,REJECT"] + user_overrides + managed + remaining
  end

  def normalize_reality_short_ids(value)
    stack = [value]
    until stack.empty?
      current = stack.pop
      case current
      when Hash
        current.each do |key, child|
          if key.to_s == "short-id" && child.is_a?(String) && child.match?(/\A[0-9a-fA-F]{1,16}\z/)
            current[key] = child.dup
          else
            stack << child
          end
        end
      when Array
        stack.concat(current)
      end
    end
    value
  end

  def patch(config, policy, usage_profile: 3)
    return base_result(config, :invalid_policy) unless policy.is_a?(Hash) && policy["version"] == POLICY_VERSION
    return base_result(config, :invalid_profile) unless [1, 2, 3].include?(usage_profile)
    return base_result(config, :invalid) unless usable_config?(config)

    original = deep_copy(config)
    patched = deep_copy(config)
    patched["rules"] ||= []
    main_group = detect_main_group(patched, policy)
    return base_result(config, :no_main_group) unless main_group

    cn_provider = patch_common_cn(patched, policy, main_group)
    if usage_profile < 3
      normalize_reality_short_ids(patched)
      return {
        config: patched,
        changed: patched != original,
        status: patched == original ? :unchanged : :updated,
        ai_group: nil,
        route_group: main_group,
        main_group: main_group,
        cn_provider: cn_provider,
        ai_group_created: false,
        ai_group_reset: false
      }
    end

    owned_ai_names, owned_safe_names = owned_managed_group_names(patched, policy)
    existing_ai = existing_ai_group(patched, policy)
    ai_group_created = existing_ai.nil?
    ai_group_reset = existing_ai && owned_ai_names.include?(existing_ai["name"])
    ai_group = if existing_ai
                 if ai_group_reset
                   return base_result(config, :no_ai_nodes) unless configure_managed_ai_group(existing_ai, patched)
                 end
                 existing_ai["name"]
               else
                 ensure_ai_group(patched, policy)
               end
    return base_result(config, :no_ai_nodes) unless ai_group
    route_group = main_group
    patched["ipv6"] = false
    patched["tun"] = {} unless patched["tun"].is_a?(Hash)
    TUN_POLICY.each { |key, value| patched["tun"][key] = deep_copy(value) }
    patch_dns(patched, policy, route_group, ai_group, owned_safe_names, cn_provider)
    patch_rules(patched, policy, ai_group, route_group, owned_ai_names, owned_safe_names)
    remove_owned_managed_groups(
      patched,
      (owned_ai_names - [ai_group, route_group]) + (owned_safe_names - [route_group])
    )
    normalize_reality_short_ids(patched)

    {
      config: patched,
      changed: patched != original,
      status: patched == original ? :unchanged : :updated,
      ai_group: ai_group,
      route_group: route_group,
      main_group: main_group,
      cn_provider: cn_provider,
      ai_group_created: ai_group_created,
      ai_group_reset: !!ai_group_reset
    }
  end

  def dump_config(config)
    visitor = Psych::Visitors::YAMLTree.create({})
    visitor << config
    tag_reality_short_ids(visitor.tree).yaml
  end

  def tag_reality_short_ids(node)
    stack = [node]
    until stack.empty?
      current = stack.pop
      case current
      when Psych::Nodes::Mapping
        current.children.each_slice(2) do |key, value|
          if key.is_a?(Psych::Nodes::Scalar) && key.value == "short-id" &&
             value.is_a?(Psych::Nodes::Scalar) && value.value.match?(/\A[0-9a-fA-F]{1,16}\z/)
            value.tag = "tag:yaml.org,2002:str"
            value.plain = false
            value.quoted = true
            value.style = Psych::Nodes::Scalar::DOUBLE_QUOTED
          end
          stack << value
        end
      when Psych::Nodes::Document, Psych::Nodes::Sequence, Psych::Nodes::Stream
        stack.concat(current.children)
      end
    end
    node
  end

  def yaml_alias?(node)
    stack = [node]
    until stack.empty?
      current = stack.pop
      return true if current.is_a?(Psych::Nodes::Alias)

      stack.concat(Array(current.children)) if current.respond_to?(:children)
    end
    false
  end

  def load_yaml(text, filename = nil)
    # REALITY short-id is schema-defined text, but a valid hexadecimal value
    # can also resemble a YAML number (for example 0906152e4 or 12345678).
    # Tag only that field as text before scalar resolution so unrelated YAML
    # 1.2 exponent values keep their numeric meaning.
    stream = Psych.parse_stream(text, filename: filename)
    documents = stream.children
    return nil if documents.empty?
    raise InvalidConfigError, "YAML 必须只包含一个文档" unless documents.length == 1

    document = documents.first
    raise InvalidConfigError, "YAML 别名不受支持" if yaml_alias?(document)

    tag_reality_short_ids(document)

    class_loader = Psych::ClassLoader::Restricted.new([], [])
    scanner = YAML12ScalarScanner.new(class_loader)
    Psych::Visitors::ToRuby.new(scanner, class_loader).accept(document)
  end

end
