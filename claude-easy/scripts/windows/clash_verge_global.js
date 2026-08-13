// ClaudeEasy — Clash Verge Rev global enhancement script.
// This file intentionally has no Node.js runtime dependency.

// CLAUDEEASY POLICY BEGIN
const CLAUDE_EASY_POLICY = {
  "version": 1,
  "resolvers": [
    "https://94.140.14.140/dns-query",
    "https://94.140.14.141/dns-query",
    "https://101.101.101.101/dns-query"
  ],
  "directResolvers": [
    "https://223.5.5.5/dns-query#DIRECT",
    "https://1.12.12.12/dns-query#DIRECT"
  ],
  "bootstrapFallbackResolvers": [
    "https://223.5.5.5/dns-query#DIRECT",
    "https://1.12.12.12/dns-query#DIRECT"
  ],
  "cnDomainProvider": {
    "name": "claude-easy-cn-domain",
    "type": "http",
    "behavior": "domain",
    "format": "mrs",
    "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs",
    "path": "./ruleset/claude-easy-cn-domain.mrs",
    "interval": 86400,
    "size_limit": 2097152
  },
  "mainGroupNames": [
    "Proxy",
    "PROXY",
    "Final",
    "Fallback",
    "节点选择",
    "节点列表",
    "兜底分流"
  ],
  "aiGroupNames": [
    "AI",
    "OpenAI",
    "人工智能",
    "🤖 AI"
  ],
  "taiwanTokens": [
    "台湾",
    "台灣",
    "Taiwan",
    "TW",
    "🇹🇼"
  ],
  "japanTokens": [
    "日本",
    "Japan",
    "JP",
    "🇯🇵"
  ],
  "forbiddenAiDomains": [
    "raw.githubusercontent.com",
    "storage.googleapis.com"
  ],
  "legacyAiRules": [
    "DOMAIN-SUFFIX,ai.com,{AI}",
    "IP-CIDR,160.79.104.0/21,{AI},no-resolve"
  ],
  "aiRules": [
    "DOMAIN-SUFFIX,anthropic.com,{AI}",
    "DOMAIN-SUFFIX,claude.ai,{AI}",
    "DOMAIN-SUFFIX,claude.com,{AI}",
    "DOMAIN-SUFFIX,claude.site,{AI}",
    "DOMAIN-SUFFIX,claudeusercontent.com,{AI}",
    "DOMAIN-SUFFIX,claudemcpclient.com,{AI}",
    "DOMAIN-SUFFIX,claudemcpcontent.com,{AI}",
    "DOMAIN,servd-anthropic-website.b-cdn.net,{AI}",
    "DOMAIN-SUFFIX,openai.com,{AI}",
    "DOMAIN-SUFFIX,chatgpt.com,{AI}",
    "DOMAIN-SUFFIX,chatgpt.livekit.cloud,{AI}",
    "DOMAIN-SUFFIX,oaistatic.com,{AI}",
    "DOMAIN-SUFFIX,oaiusercontent.com,{AI}",
    "DOMAIN-SUFFIX,oaistatsig.com,{AI}",
    "DOMAIN-SUFFIX,cdn.openaimerge.com,{AI}",
    "DOMAIN,openai-api.arkoselabs.com,{AI}",
    "DOMAIN,chat.openai.com.cdn.cloudflare.net,{AI}",
    "DOMAIN,openaiapi-site.azureedge.net,{AI}",
    "DOMAIN,openaicom.imgix.net,{AI}",
    "DOMAIN,openaicom-api-bdcpf8c6d2e9atf6.z01.azurefd.net,{AI}",
    "DOMAIN,openaicomproductionae4b.blob.core.windows.net,{AI}",
    "DOMAIN,production-openaicom-storage.azureedge.net,{AI}",
    "DOMAIN,ai.google.dev,{AI}",
    "DOMAIN-SUFFIX,aistudio.google.com,{AI}",
    "DOMAIN-SUFFIX,gemini.google.com,{AI}",
    "DOMAIN-SUFFIX,gemini.google,{AI}",
    "DOMAIN-SUFFIX,gemini.gstatic.com,{AI}",
    "DOMAIN-SUFFIX,bard.google.com,{AI}",
    "DOMAIN-SUFFIX,makersuite.google.com,{AI}",
    "DOMAIN,alkalimakersuite-pa.clients6.google.com,{AI}",
    "DOMAIN,webchannel-alkalimakersuite-pa.clients6.google.com,{AI}",
    "DOMAIN-SUFFIX,generativelanguage.googleapis.com,{AI}",
    "DOMAIN,aiplatform.googleapis.com,{AI}",
    "DOMAIN-SUFFIX,generativeai.google,{AI}",
    "DOMAIN-KEYWORD,openai,{AI}",
    "IP-CIDR,160.79.104.0/23,{AI},no-resolve",
    "IP-CIDR6,2607:6bc0::/48,{AI},no-resolve"
  ]
};
// CLAUDEEASY POLICY END

const CLAUDE_EASY_AI_GROUP = "🤖 AI · ClaudeEasy";
const CLAUDE_EASY_SAFE_GROUP = "🛡 安全代理 · ClaudeEasy";
const CLAUDE_EASY_REFERENCE_GROUP = "🔗 路由引用 · ClaudeEasy";
const CLAUDE_EASY_DIRECT_NAMES = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE", "REMATCH"];
const CLAUDE_EASY_DIRECT_TYPES = ["direct", "dns", "reject", "reject-drop", "pass", "pass-rule", "compatible", "rematch"];
const CLAUDE_EASY_ROUTE_GROUP_TYPES = ["select", "url-test", "fallback", "load-balance"];
const CLAUDE_EASY_LEGACY_QUIC_REJECT_RULE = "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT";
const CLAUDE_EASY_USAGE_PROFILE = 3;

function claudeEasyClone(value) {
  return JSON.parse(JSON.stringify(value));
}

function claudeEasyUsable(config) {
  return config && typeof config === "object" && !Array.isArray(config) &&
    Array.isArray(config["proxy-groups"]) && (config.rules == null || Array.isArray(config.rules)) &&
    (Array.isArray(config.proxies) || (config["proxy-providers"] && typeof config["proxy-providers"] === "object" &&
      !Array.isArray(config["proxy-providers"])));
}

function claudeEasySelectableGroups(config) {
  return (config["proxy-groups"] || []).filter(function (group) {
    return group && typeof group.name === "string" && String(group.type).toLowerCase() === "select";
  });
}

function claudeEasyRouteGroups(config) {
  return (config["proxy-groups"] || []).filter(function (group) {
    return group && typeof group.name === "string" &&
      CLAUDE_EASY_ROUTE_GROUP_TYPES.indexOf(String(group.type).toLowerCase()) !== -1;
  });
}

function claudeEasyManagedName(name, base) {
  if (typeof name !== "string") return false;
  if (name === base) return true;
  if (name.indexOf(base + " ") !== 0) return false;
  return /^(?:[2-9]|[1-9][0-9]+)$/.test(name.slice(base.length + 1));
}

function claudeEasyManagedGroupName(name) {
  return claudeEasyManagedName(name, CLAUDE_EASY_AI_GROUP) || claudeEasyManagedName(name, CLAUDE_EASY_SAFE_GROUP) ||
    claudeEasyManagedName(name, CLAUDE_EASY_REFERENCE_GROUP);
}

function claudeEasyNormalizedAdapterType(type) {
  const normalized = String(type || "").toLowerCase().replace(/[^a-z0-9]/g, "");
  if (normalized === "ss") return "shadowsocks";
  if (normalized === "ssr") return "shadowsocksr";
  if (normalized === "select") return "selector";
  return normalized;
}

function claudeEasyGroupExcludesType(group, type) {
  const sourceType = claudeEasyNormalizedAdapterType(type);
  return String(group["exclude-type"] || "").split("|").some(function (item) {
    return claudeEasyNormalizedAdapterType(item) === sourceType;
  });
}

function claudeEasyProxySource(config, name) {
  const proxy = (config.proxies || []).find(function (item) {
    return item && typeof item.name === "string" && item.name === name;
  });
  return Boolean(proxy) && !claudeEasyDirectName(name) &&
    CLAUDE_EASY_DIRECT_TYPES.indexOf(String(proxy.type || "").toLowerCase()) === -1;
}

function claudeEasySimpleGroupFilterMatch(pattern, name) {
  if (typeof pattern !== "string" || typeof name !== "string") return null;
  let source = pattern;
  const insensitive = source.indexOf("(?i)") === 0;
  if (insensitive) source = source.slice(4);
  if (source === ".*") return true;
  const exact = source.length >= 2 && source[0] === "^" && source[source.length - 1] === "$";
  if (exact) source = source.slice(1, -1);
  if (/[\\.\^$*+?()\[\]{}|]/.test(source)) return null;
  const candidate = insensitive ? name.toLowerCase() : name;
  const expected = insensitive ? source.toLowerCase() : source;
  return exact ? candidate === expected : candidate.indexOf(expected) !== -1;
}

function claudeEasyImportedProxySource(config, group, name) {
  if (!claudeEasyProxySource(config, name)) return false;
  const proxy = (config.proxies || []).find(function (item) { return item && item.name === name; });
  if (claudeEasyGroupExcludesType(group, proxy.type)) return false;
  const included = String(group.filter || "");
  if (included && claudeEasySimpleGroupFilterMatch(included, name) === false) return false;
  const excluded = String(group["exclude-filter"] || "");
  return !excluded || claudeEasySimpleGroupFilterMatch(excluded, name) !== true;
}

function claudeEasyProviderImportCanHaveSource(group) {
  const exclusion = group["exclude-filter"];
  return typeof exclusion !== "string" || exclusion.replace(/^\(\?i\)/, "") !== ".*";
}

function claudeEasyProviderSource(config, name) {
  const providers = config["proxy-providers"];
  const provider = providers && typeof providers === "object" && !Array.isArray(providers) ? providers[name] : null;
  return typeof name === "string" && name.length > 0 && provider && typeof provider === "object" && !Array.isArray(provider);
}

function claudeEasyGroupHasProxySource(config, group, visiting) {
  visiting = visiting || [];
  if (visiting.indexOf(group.name) !== -1) return false;

  if (claudeEasyProviderImportCanHaveSource(group) && (Array.isArray(group.use) ? group.use : []).some(function (name) {
    return claudeEasyProviderSource(config, name);
  })) return true;
  if (group["include-all"] === true || group["include-all-providers"] === true) {
    const providers = config["proxy-providers"];
    if (claudeEasyProviderImportCanHaveSource(group) && providers && typeof providers === "object" && !Array.isArray(providers) && Object.keys(providers).some(function (name) {
      return claudeEasyProviderSource(config, name);
    })) return true;
  }
  if (group["include-all"] === true || group["include-all-proxies"] === true) {
    if ((config.proxies || []).some(function (proxy) {
      return proxy && claudeEasyImportedProxySource(config, group, proxy.name);
    })) return true;
  }

  const nestedGroups = claudeEasyRouteGroups(config);
  return (Array.isArray(group.proxies) ? group.proxies : []).some(function (member) {
    if (claudeEasyProxySource(config, member)) return true;
    const nested = nestedGroups.find(function (candidate) { return candidate.name === member; });
    return Boolean(nested) && claudeEasyGroupHasProxySource(config, nested, visiting.concat([group.name]));
  });
}

// Prefer an independent non-AI group. AI-named and managed groups remain
// available only as last resorts so a valid subscription is never skipped.
function claudeEasyDetectMain(config) {
  const groups = claudeEasyRouteGroups(config);
  for (let index = groups.length - 1; index >= 0; index -= 1) {
    if (!claudeEasyGroupHasProxySource(config, groups[index], [])) groups.splice(index, 1);
  }
  const candidates = groups.filter(function (group) {
    return !claudeEasyAiName(group.name) && !claudeEasyManagedGroupName(group.name);
  });
  const names = candidates.map(function (group) { return group.name; });

  const matchRule = config.rules.slice().reverse().map(claudeEasyRuleInfo).find(function (info) { return info.type === "MATCH"; });
  const matchTarget = matchRule ? matchRule.target : null;
  if (matchTarget && !claudeEasyDirectName(matchTarget) && names.indexOf(matchTarget) !== -1) return matchTarget;

  const references = {};
  config.rules.forEach(function (rule) {
    if (!claudeEasyBroadRule(rule)) return;
    const target = claudeEasyRuleInfo(rule).target;
    if (names.indexOf(target) !== -1) references[target] = (references[target] || 0) + 1;
  });
  let frequentName = null;
  let frequentCount = 0;
  names.forEach(function (name) {
    const count = references[name] || 0;
    if (count > frequentCount) {
      frequentCount = count;
      frequentName = name;
    }
  });
  if (frequentName && frequentCount > 1) return frequentName;

  for (let i = 0; i < CLAUDE_EASY_POLICY.mainGroupNames.length; i += 1) {
    const preferred = CLAUDE_EASY_POLICY.mainGroupNames[i].toLowerCase();
    const found = names.find(function (name) { return name.toLowerCase() === preferred; });
    if (found) return found;
  }
  if (candidates.length) return candidates[0].name;
  return groups.length ? groups[0].name : null;
}

function claudeEasyAiName(name) {
  if (typeof name !== "string") return false;
  if (CLAUDE_EASY_POLICY.aiGroupNames.some(function (candidate) { return candidate.toLowerCase() === name.toLowerCase(); })) return true;
  const normalized = name.toLowerCase();
  return normalized.indexOf("openai") !== -1 || normalized.indexOf("人工智能") !== -1 || /(^|[^a-z])ai([^a-z]|$)/.test(normalized);
}

function claudeEasyExistingAiGroup(config) {
  const candidates = claudeEasySelectableGroups(config).filter(function (group) { return claudeEasyAiName(group.name); });
  return candidates.find(function (group) { return !claudeEasyManagedGroupName(group.name); }) || candidates[0] || null;
}

function claudeEasyUniqueGroupName(config, base) {
  const names = (config["proxy-groups"] || []).map(function (group) { return group && group.name; });
  (config.proxies || []).forEach(function (proxy) {
    if (proxy && typeof proxy.name === "string") names.push(proxy.name);
  });
  if (names.indexOf(base) === -1) return base;
  let suffix = 2;
  while (names.indexOf(base + " " + suffix) !== -1) suffix += 1;
  return base + " " + suffix;
}

function claudeEasySafeReferenceName(name) {
  return typeof name === "string" && name.length > 0 && !/[#,=&%\x00-\x1f\x7f-\x9f]/.test(name);
}

function claudeEasyReferenceWrapper(group, target) {
  return group && claudeEasyManagedName(group.name, CLAUDE_EASY_REFERENCE_GROUP) &&
    Object.keys(group).sort().join("\u0000") === ["name", "proxies", "type"].sort().join("\u0000") &&
    String(group.type).toLowerCase() === "select" && Array.isArray(group.proxies) &&
    group.proxies.length === 1 && group.proxies[0] === target;
}

function claudeEasySafeGroupReference(config, target) {
  if (claudeEasySafeReferenceName(target)) return target;
  if (!claudeEasyRouteGroups(config).some(function (group) { return group.name === target; })) return null;
  const existing = (config["proxy-groups"] || []).find(function (group) {
    return claudeEasyReferenceWrapper(group, target);
  });
  if (existing) return existing.name;
  const name = claudeEasyUniqueGroupName(config, CLAUDE_EASY_REFERENCE_GROUP);
  config["proxy-groups"].push({ name: name, type: "select", proxies: [target] });
  return name;
}

function claudeEasyManagedAiFingerprint(group) {
  if (!group) return false;
  if (Object.keys(group).some(function (key) { return ["name", "proxies", "type", "use"].indexOf(key) === -1; })) return false;
  if (!["name", "proxies", "type"].every(function (key) { return Object.prototype.hasOwnProperty.call(group, key); })) return false;
  const providers = Object.prototype.hasOwnProperty.call(group, "use") ? group.use : [];
  if (String(group.type).toLowerCase() !== "select" || !Array.isArray(group.proxies) || !Array.isArray(providers)) return false;
  if (!group.proxies.length && !providers.length) return false;
  return group.proxies.every(function (name) { return typeof name === "string" && name !== group.name; }) &&
    providers.every(function (name) { return typeof name === "string" && name.length > 0; });
}

function claudeEasyManagedSafeFingerprint(group) {
  const expected = ["empty-fallback", "exclude-type", "include-all", "name", "proxies", "type"].sort().join("\u0000");
  if (!group || Object.keys(group).sort().join("\u0000") !== expected) return false;
  if (String(group.type).toLowerCase() !== "select" || group["include-all"] !== true) return false;
  if (String(group["empty-fallback"]).toUpperCase() !== "REJECT") return false;
  if (["Direct|Dns|Reject|RejectDrop|Pass|PassRule|Compatible|Rematch", "Direct|Dns|Reject|Pass|Compatible|Rematch", "Direct|Reject|Pass|Compatible|Rematch", "Direct|Reject|Pass|Compatible"].indexOf(group["exclude-type"]) === -1) return false;
  return Array.isArray(group.proxies) && group.proxies.every(function (name) {
    return typeof name === "string" && name !== group.name;
  });
}

function claudeEasyOwnedAiGroup(config, name) {
  const group = claudeEasySelectableGroups(config).find(function (item) { return item.name === name; });
  if (!claudeEasyManagedAiFingerprint(group)) return false;
  const keys = CLAUDE_EASY_POLICY.aiRules.concat(CLAUDE_EASY_POLICY.legacyAiRules || []).map(claudeEasyManagedRuleKey);
  const matches = (config.rules || []).filter(function (rule) {
    const info = claudeEasyRuleInfo(rule);
    return info.target === name && keys.indexOf(claudeEasyManagedRuleKey(rule)) !== -1;
  });
  return matches.length >= 2;
}

function claudeEasyDecodedResolverFragment(endpoint) {
  const value = String(endpoint);
  const separator = value.indexOf("#");
  if (separator === -1) return "";
  try {
    return decodeURIComponent(value.slice(separator + 1));
  } catch (_error) {
    return null;
  }
}

function claudeEasyResolverTarget(endpoint) {
  const fragment = claudeEasyDecodedResolverFragment(endpoint);
  if (!fragment) return null;
  const targets = fragment.split("&").filter(function (part) { return part.indexOf("=") === -1; });
  if (targets.length !== 1 || !targets[0]) return null;
  return targets[0];
}

function claudeEasyResolverTargets(config) {
  const dns = config.dns;
  if (!dns || typeof dns !== "object" || Array.isArray(dns)) return [];
  let endpoints = [];
  ["nameserver", "fallback", "direct-nameserver"].forEach(function (field) {
    const value = dns[field];
    endpoints = endpoints.concat(Array.isArray(value) ? value : (value == null ? [] : [value]));
  });
  const policy = dns["nameserver-policy"];
  if (policy && typeof policy === "object" && !Array.isArray(policy)) {
    Object.keys(policy).forEach(function (key) {
      const value = policy[key];
      endpoints = endpoints.concat(Array.isArray(value) ? value : [value]);
    });
  }
  return endpoints.map(claudeEasyResolverTarget).filter(Boolean);
}

function claudeEasyOwnedSafeGroup(config, name) {
  const group = claudeEasySelectableGroups(config).find(function (item) { return item.name === name; });
  if (!claudeEasyManagedSafeFingerprint(group)) return false;
  const rules = config.rules || [];
  const guarded = rules.some(function (rule, index) {
    if (index + 1 >= rules.length) return false;
    const first = claudeEasyRuleInfo(rule);
    const second = claudeEasyRuleInfo(rules[index + 1]);
    return first.type === "NETWORK" && first.payload.toUpperCase() === "UDP" && first.target === name &&
      second.type === "NETWORK" && second.payload.toUpperCase() === "UDP" && String(second.target).toUpperCase() === "REJECT";
  });
  return guarded && claudeEasyResolverTargets(config).indexOf(name) !== -1;
}

function claudeEasyFindManagedSelect(config, base, kind) {
  return claudeEasySelectableGroups(config).find(function (group) {
    if (!claudeEasyManagedName(group.name, base)) return false;
    return kind === "ai" ? claudeEasyOwnedAiGroup(config, group.name) : claudeEasyOwnedSafeGroup(config, group.name);
  });
}

function claudeEasyResetGroup(group) {
  Object.keys(group).forEach(function (key) {
    if (key !== "name" && key !== "type") delete group[key];
  });
  group.type = "select";
}

function claudeEasyAiGroupSources(config) {
  const proxies = [];
  (config.proxies || []).forEach(function (proxy) {
    if (!proxy || typeof proxy.name !== "string" || !proxy.name || claudeEasyDirectName(proxy.name)) return;
    if (CLAUDE_EASY_DIRECT_TYPES.indexOf(String(proxy.type || "").toLowerCase()) !== -1) return;
    if (proxies.indexOf(proxy.name) === -1) proxies.push(proxy.name);
  });
  const providers = [];
  if (config["proxy-providers"] && typeof config["proxy-providers"] === "object" && !Array.isArray(config["proxy-providers"])) {
    Object.keys(config["proxy-providers"]).forEach(function (name) {
      const provider = config["proxy-providers"][name];
      if (name && provider && typeof provider === "object" && !Array.isArray(provider)) providers.push(name);
    });
  }
  return { proxies: proxies, providers: providers };
}

function claudeEasyConfigureManagedAiGroup(group, config) {
  const sources = claudeEasyAiGroupSources(config);
  if (!sources.proxies.length && !sources.providers.length) return false;
  claudeEasyResetGroup(group);
  group.proxies = sources.proxies;
  if (sources.providers.length) group.use = sources.providers;
  return true;
}

function claudeEasyEnsureAiGroup(config) {
  let group = claudeEasyFindManagedSelect(config, CLAUDE_EASY_AI_GROUP, "ai");
  if (!group) {
    group = { name: claudeEasyUniqueGroupName(config, CLAUDE_EASY_AI_GROUP), type: "select" };
    config["proxy-groups"].push(group);
  }
  return claudeEasyConfigureManagedAiGroup(group, config) ? group.name : null;
}

function claudeEasyOwnedManagedNames(config) {
  const names = claudeEasySelectableGroups(config).map(function (group) { return group.name; });
  return {
    ai: names.filter(function (name) {
      return claudeEasyManagedName(name, CLAUDE_EASY_AI_GROUP) && claudeEasyOwnedAiGroup(config, name);
    }),
    safe: names.filter(function (name) {
      return claudeEasyManagedName(name, CLAUDE_EASY_SAFE_GROUP) && claudeEasyOwnedSafeGroup(config, name);
    })
  };
}

function claudeEasyRemoveOwnedManagedGroups(config, names) {
  config["proxy-groups"] = (config["proxy-groups"] || []).filter(function (group) {
    return !group || names.indexOf(group.name) === -1;
  });
}

function claudeEasyTaggedResolvers(group) {
  return CLAUDE_EASY_POLICY.resolvers.map(function (resolver) { return resolver + "#" + group; });
}

function claudeEasyDnsPatterns() {
  const patterns = [];
  CLAUDE_EASY_POLICY.aiRules.forEach(function (template) {
    const parts = template.split(",");
    const pattern = parts[0] === "DOMAIN-SUFFIX" ? "+." + parts[1] : (parts[0] === "DOMAIN" ? parts[1] : null);
    if (pattern && patterns.indexOf(pattern) === -1) patterns.push(pattern);
  });
  return patterns;
}

function claudeEasyLegacyDnsPatterns() {
  const patterns = [];
  (CLAUDE_EASY_POLICY.legacyAiRules || []).forEach(function (template) {
    const parts = template.split(",");
    const pattern = parts[0] === "DOMAIN-SUFFIX" ? "+." + parts[1] : (parts[0] === "DOMAIN" ? parts[1] : null);
    if (pattern && patterns.indexOf(pattern) === -1) patterns.push(pattern);
  });
  return patterns;
}

function claudeEasyDirectName(name) {
  return CLAUDE_EASY_DIRECT_NAMES.some(function (candidate) {
    return candidate.toLowerCase() === String(name || "").toLowerCase();
  });
}

function claudeEasySafeProxyTarget(config, target) {
  return (config.proxies || []).some(function (proxy) {
    return proxy && proxy.name === target && CLAUDE_EASY_DIRECT_TYPES.indexOf(String(proxy.type || "").toLowerCase()) === -1;
  });
}

function claudeEasyGroupCannotReachDirect(config, target, visiting) {
  visiting = visiting || [];
  if (claudeEasyDirectName(target) || visiting.indexOf(target) !== -1) return false;
  const group = (config["proxy-groups"] || []).find(function (item) { return item && item.name === target; });
  if (!group) return false;

  if (Array.isArray(group.use) && group.use.length) return false;
  if (group["include-all"] === true || group["include-all-proxies"] === true || group["include-all-providers"] === true) return false;
  const exclusion = group["exclude-filter"];
  if (exclusion !== undefined && exclusion !== null && exclusion !== "") return false;

  const members = Array.isArray(group.proxies) ? group.proxies.slice() : [];
  if (!members.length) return claudeEasySafeProxyTarget(config, group["empty-fallback"]);
  return members.every(function (member) {
    return claudeEasySafeProxyTarget(config, member) || claudeEasyGroupCannotReachDirect(config, member, visiting.concat([target]));
  });
}

function claudeEasySafeResolverEndpoint(config, endpoint) {
  if (!/^(?:https|tls|quic):\/\//i.test(String(endpoint))) return false;
  const fragment = claudeEasyDecodedResolverFragment(endpoint);
  if (fragment === null) return false;
  const options = fragment.split("&").filter(function (part) { return part.indexOf("=") !== -1; });
  for (let index = 0; index < options.length; index += 1) {
    const pieces = options[index].split("=", 2);
    const key = String(pieces[0] || "").toLowerCase();
    const value = String(pieces[1] || "").toLowerCase();
    if (key === "ecs" || key === "ecs-override") return false;
    if (key === "skip-cert-verify" && value === "true") return false;
  }
  const target = claudeEasyResolverTarget(endpoint);
  if (!target || claudeEasyDirectName(target)) return false;
  return claudeEasySafeProxyTarget(config, target) || claudeEasyGroupCannotReachDirect(config, target, []);
}

function claudeEasyNormalizedResolverEndpoints(config, values) {
  if (!values.every(function (value) { return claudeEasySafeResolverEndpoint(config, value); })) return null;
  const normalized = [];
  values.forEach(function (value) {
    const endpoint = String(value);
    const fragment = endpoint.slice(endpoint.indexOf("#") + 1);
    CLAUDE_EASY_POLICY.resolvers.forEach(function (resolver) {
      const endpoint = resolver + "#" + fragment;
      if (normalized.indexOf(endpoint) === -1) normalized.push(endpoint);
    });
  });
  return normalized;
}

function claudeEasyUnsafeProxyBootstrap(values) {
  const normalized = Array.isArray(values) ? values : [];
  if (normalized.length === 0 || normalized.some(claudeEasyUnsafeBootstrapValue)) return true;
  const serialized = JSON.stringify(normalized);
  return [
    JSON.stringify(["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"])
  ].indexOf(serialized) !== -1;
}

function claudeEasyUnsafeDefaultBootstrap(values) {
  return !Array.isArray(values) || values.some(claudeEasyUnsafeBootstrapValue);
}

function claudeEasyUnsafeBootstrapValue(value) {
  const text = String(value);
  const scheme = text.match(/^([a-z][a-z0-9+.-]*):\/\//i);
  if (!scheme || ["https", "tls", "quic", "ts", "tailscale"].indexOf(scheme[1].toLowerCase()) === -1) return true;
  const fragment = claudeEasyDecodedResolverFragment(text);
  if (fragment === null) return true;
  return fragment.split("&").some(function (option) {
    const pieces = option.split("=", 2);
    const key = String(pieces[0] || "").toLowerCase();
    const optionValue = String(pieces[1] || "").toLowerCase();
    return (pieces.length > 1 && (key === "ecs" || key === "ecs-override")) ||
      (key === "skip-cert-verify" && optionValue === "true");
  });
}

function claudeEasyDns(config, routeGroup, aiGroup, ownedSafeNames, cnProviderName) {
  const dns = config.dns && typeof config.dns === "object" && !Array.isArray(config.dns) ? config.dns : {};
  config.dns = dns;
  dns.enable = true;
  dns.ipv6 = false;
  dns["respect-rules"] = true;
  dns["use-hosts"] = true;
  dns["use-system-hosts"] = true;
  const safeResolvers = claudeEasyTaggedResolvers(routeGroup);
  const aiResolvers = claudeEasyTaggedResolvers(aiGroup);
  dns.nameserver = safeResolvers.slice();
  if (Object.prototype.hasOwnProperty.call(dns, "fallback")) dns.fallback = safeResolvers.slice();
  dns["direct-nameserver"] = CLAUDE_EASY_POLICY.directResolvers.slice();
  dns["direct-nameserver-follow-policy"] = false;

  const existing = dns["nameserver-policy"] && typeof dns["nameserver-policy"] === "object" ? dns["nameserver-policy"] : {};
  const policies = {};
  const legacyPatterns = claudeEasyLegacyDnsPatterns();
  ownedSafeNames = ownedSafeNames || [];
  Object.keys(existing).forEach(function (combined) {
    String(combined).split(",").map(function (item) { return item.trim(); }).filter(Boolean).forEach(function (pattern) {
      const values = (Array.isArray(existing[combined]) ? existing[combined] : [existing[combined]]).map(String);
      const legacyOwned = legacyPatterns.indexOf(pattern) !== -1 && values.length > 0 && values.every(function (value) {
        return ownedSafeNames.indexOf(claudeEasyResolverTarget(value)) !== -1;
      });
      if (legacyOwned) return;
      const referencesOldGroup = values.some(function (value) {
        return ownedSafeNames.indexOf(claudeEasyResolverTarget(value)) !== -1;
      });
      const normalized = !referencesOldGroup && values.length > 0 ? claudeEasyNormalizedResolverEndpoints(config, values) : null;
      policies[pattern] = normalized || safeResolvers.slice();
    });
  });
  policies["geosite:cn"] = CLAUDE_EASY_POLICY.directResolvers.slice();
  if (cnProviderName) policies["rule-set:" + cnProviderName] = CLAUDE_EASY_POLICY.directResolvers.slice();
  claudeEasyDnsPatterns().forEach(function (pattern) { policies[pattern] = aiResolvers.slice(); });
  dns["nameserver-policy"] = policies;
}

function claudeEasySplitRule(rule) {
  const fields = [];
  let buffer = "";
  let depth = 0;
  String(rule).split("").forEach(function (character) {
    if (character === "(") {
      depth += 1;
      buffer += character;
    } else if (character === ")") {
      if (depth > 0) depth -= 1;
      buffer += character;
    } else if (character === "," && depth === 0) {
      fields.push(buffer.trim());
      buffer = "";
    } else {
      buffer += character;
    }
  });
  fields.push(buffer.trim());
  return fields;
}

function claudeEasyRuleInfo(rule) {
  const parts = claudeEasySplitRule(rule);
  const noResolve = String(parts[parts.length - 1] || "").toLowerCase() === "no-resolve";
  const targetIndex = noResolve ? parts.length - 2 : parts.length - 1;
  return {
    parts: parts,
    type: String(parts[0] || "").toUpperCase(),
    payload: String(parts[1] || ""),
    target: targetIndex > 0 ? parts[targetIndex] : null
  };
}

function claudeEasyManagedRuleKey(rule) {
  const info = claudeEasyRuleInfo(rule);
  if (!info.type || !info.payload) return null;
  return info.type + "\u0000" + info.payload.toLowerCase();
}

function claudeEasyManagedRuleIdentity(rule) {
  const info = claudeEasyRuleInfo(rule);
  const key = claudeEasyManagedRuleKey(rule);
  return key && info.target ? key + "\u0000" + info.target : null;
}

function claudeEasyBroadRule(rule) {
  return ["MATCH", "GEOSITE", "GEOIP", "RULE-SET"].indexOf(claudeEasyRuleInfo(rule).type) !== -1;
}

function claudeEasyManagedCnProviderName(name) {
  const base = CLAUDE_EASY_POLICY.cnDomainProvider.name;
  const escaped = base.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp("^" + escaped + "(?:-[2-9]|-[1-9][0-9]+)?$").test(String(name));
}

function claudeEasyCnProviderPath(name) {
  const provider = CLAUDE_EASY_POLICY.cnDomainProvider;
  const suffix = String(name).slice(provider.name.length);
  if (!suffix) return provider.path;
  const dot = provider.path.lastIndexOf(".");
  if (dot === -1) return provider.path + suffix;
  return provider.path.slice(0, dot) + suffix + provider.path.slice(dot);
}

function claudeEasyWindowsPathKey(value) {
  if (typeof value !== "string") return null;
  let path = value.replace(/\//g, "\\");
  let root = "";
  const drive = path.match(/^[A-Za-z]:/);
  if (drive) {
    root = drive[0].toLowerCase();
    path = path.slice(2);
  }
  if (path.indexOf("\\\\") === 0) {
    root += "\\\\";
    path = path.replace(/^\\+/, "");
  } else if (path.indexOf("\\") === 0) {
    root += "\\";
    path = path.replace(/^\\+/, "");
  }

  const parts = [];
  path.split("\\").forEach(function (part) {
    if (!part || part === ".") return;
    if (part === "..") {
      if (parts.length && parts[parts.length - 1] !== "..") parts.pop();
      else if (root.indexOf("\\") === -1) parts.push(part);
      return;
    }
    parts.push(part.normalize("NFC").toUpperCase().toLowerCase());
  });
  return root + "|" + parts.join("\\");
}

function claudeEasyWindowsProviderPathCollision(existingValue, managedValue) {
  const existingKey = claudeEasyWindowsPathKey(existingValue);
  const managedKey = claudeEasyWindowsPathKey(managedValue);
  if (existingKey === null || managedKey === null) return false;
  if (existingKey === managedKey) return true;
  const existingPath = existingValue.replace(/\//g, "\\");
  if (!/^(?:[A-Za-z]:\\|\\)/.test(existingPath)) return false;
  const existingParts = existingKey.slice(existingKey.indexOf("|") + 1);
  const managedParts = managedKey.slice(managedKey.indexOf("|") + 1);
  return existingParts === managedParts || existingParts.slice(-(managedParts.length + 1)) === "\\" + managedParts;
}

function claudeEasyOwnedCnProvider(name, provider) {
  const expected = CLAUDE_EASY_POLICY.cnDomainProvider;
  return provider && typeof provider === "object" && claudeEasyManagedCnProviderName(name) &&
    provider.url === expected.url && provider.path === claudeEasyCnProviderPath(name);
}

function claudeEasyEnsureCnProvider(config, routeGroup) {
  const expected = CLAUDE_EASY_POLICY.cnDomainProvider;
  const providers = config["rule-providers"] && typeof config["rule-providers"] === "object" &&
    !Array.isArray(config["rule-providers"]) ? config["rule-providers"] : {};
  config["rule-providers"] = providers;
  let name = Object.keys(providers).find(function (candidate) {
    return claudeEasyOwnedCnProvider(candidate, providers[candidate]);
  });
  if (!name) {
    name = expected.name;
    let sequence = 2;
    while (Object.prototype.hasOwnProperty.call(providers, name) || Object.keys(providers).some(function (candidate) {
      const provider = providers[candidate];
      return provider && typeof provider === "object" &&
        claudeEasyWindowsProviderPathCollision(provider.path, claudeEasyCnProviderPath(name));
    })) {
      name = expected.name + "-" + sequence;
      sequence += 1;
    }
  }
  providers[name] = {
    type: expected.type,
    behavior: expected.behavior,
    format: expected.format,
    url: expected.url,
    path: claudeEasyCnProviderPath(name),
    interval: expected.interval,
    proxy: routeGroup,
    "size-limit": expected.size_limit
  };
  return name;
}

function claudeEasyCommonCn(config, routeGroup) {
  const oldOwnedNames = [];
  const existingProviders = config["rule-providers"];
  if (existingProviders && typeof existingProviders === "object" && !Array.isArray(existingProviders)) {
    Object.keys(existingProviders).forEach(function (name) {
      if (claudeEasyOwnedCnProvider(name, existingProviders[name])) oldOwnedNames.push(name);
    });
  }
  const providerName = claudeEasyEnsureCnProvider(config, routeGroup);
  oldOwnedNames.push(providerName);

  const dns = config.dns && typeof config.dns === "object" && !Array.isArray(config.dns) ? config.dns : {};
  config.dns = dns;
  dns.enable = true;
  dns["respect-rules"] = true;
  if (claudeEasyUnsafeProxyBootstrap(dns["proxy-server-nameserver"])) {
    dns["proxy-server-nameserver"] = CLAUDE_EASY_POLICY.bootstrapFallbackResolvers.slice();
  }
  if (Object.prototype.hasOwnProperty.call(dns, "default-nameserver") &&
      claudeEasyUnsafeDefaultBootstrap(dns["default-nameserver"])) {
    dns["default-nameserver"] = CLAUDE_EASY_POLICY.bootstrapFallbackResolvers.slice();
  }
  if (!Array.isArray(dns.nameserver) || dns.nameserver.length === 0) {
    dns.nameserver = claudeEasyTaggedResolvers(routeGroup);
  }
  dns["direct-nameserver"] = CLAUDE_EASY_POLICY.directResolvers.slice();
  dns["direct-nameserver-follow-policy"] = false;
  const policies = dns["nameserver-policy"] && typeof dns["nameserver-policy"] === "object" &&
    !Array.isArray(dns["nameserver-policy"]) ? claudeEasyClone(dns["nameserver-policy"]) : {};
  policies["rule-set:" + providerName] = CLAUDE_EASY_POLICY.directResolvers.slice();
  dns["nameserver-policy"] = policies;

  const rules = (Array.isArray(config.rules) ? config.rules : []).filter(function (rule) {
    const info = claudeEasyRuleInfo(rule);
    return !(info.type === "RULE-SET" && oldOwnedNames.indexOf(info.payload) !== -1);
  });
  let insertion = rules.findIndex(claudeEasyBroadRule);
  if (insertion === -1) insertion = rules.length;
  rules.splice(insertion, 0, "RULE-SET," + providerName + ",DIRECT");
  config.rules = rules;
  return providerName;
}

function claudeEasyRenderAiRules(aiGroup) {
  return CLAUDE_EASY_POLICY.aiRules.map(function (template) {
    return template.replace(/\{AI\}/g, function () { return aiGroup; });
  });
}

function claudeEasyRules(config, aiGroup, routeGroup, ownedAiNames, ownedSafeNames) {
  const managed = claudeEasyRenderAiRules(aiGroup);
  const managedKeys = managed.map(claudeEasyManagedRuleKey);
  const managedIdentities = managed.map(claudeEasyManagedRuleIdentity);
  const legacyKeys = (CLAUDE_EASY_POLICY.legacyAiRules || []).map(claudeEasyManagedRuleKey);
  ownedAiNames = ownedAiNames || [];
  ownedSafeNames = ownedSafeNames || [];

  const original = config.rules || [];
  const ownedUdpIndexes = [];
  original.forEach(function (rule, index) {
    if (String(rule).replace(/\s+/g, "").toUpperCase() === CLAUDE_EASY_LEGACY_QUIC_REJECT_RULE) {
      ownedUdpIndexes.push(index);
      return;
    }

    const info = claudeEasyRuleInfo(rule);
    const next = index === 0 && original.length > 1 ? claudeEasyRuleInfo(original[1]) : null;
    if (index !== 0 || info.type !== "NETWORK" || info.payload.toUpperCase() !== "UDP" ||
        (ownedSafeNames.indexOf(info.target) === -1 && info.target !== aiGroup)) return;
    if (!next || next.type !== "NETWORK" || next.payload.toUpperCase() !== "UDP" ||
        String(next.target).toUpperCase() !== "REJECT") return;
    ownedUdpIndexes.push(index);
    ownedUdpIndexes.push(1);
  });

  const remaining = [];
  original.forEach(function (rule, index) {
    if (ownedUdpIndexes.indexOf(index) !== -1) return;
    const info = claudeEasyRuleInfo(rule);
    const key = claudeEasyManagedRuleKey(rule);
    const patchOwnedAi = managedKeys.indexOf(key) !== -1 && ownedAiNames.indexOf(info.target) !== -1;
    const exactCurrentAi = managedIdentities.indexOf(claudeEasyManagedRuleIdentity(rule)) !== -1;
    const legacyOwnedAi = legacyKeys.indexOf(key) !== -1 && ownedAiNames.indexOf(info.target) !== -1;
    const forbiddenAi = (info.type === "DOMAIN" || info.type === "DOMAIN-SUFFIX") &&
      CLAUDE_EASY_POLICY.forbiddenAiDomains.some(function (domain) { return domain.toLowerCase() === info.payload.toLowerCase(); }) &&
      ownedAiNames.indexOf(info.target) !== -1;
    const mainGroupAi = managedKeys.indexOf(key) !== -1 && info.target === routeGroup;
    if (patchOwnedAi || exactCurrentAi || legacyOwnedAi || forbiddenAi || mainGroupAi) return;
    if (managedKeys.indexOf(key) !== -1) return;
    remaining.push(rule);
  });

  config.rules = ["NETWORK,UDP," + aiGroup, "NETWORK,UDP,REJECT"].concat(managed, remaining);
}

function claudeEasyApply(config, profileName, usageProfile) {
  if (CLAUDE_EASY_POLICY.version !== 1) return config;
  if (!claudeEasyUsable(config)) return config;
  const patched = claudeEasyClone(config);
  if (!Array.isArray(patched.rules)) patched.rules = [];
  const detectedMainGroup = claudeEasyDetectMain(patched);
  if (!detectedMainGroup) return config;
  const mainGroup = claudeEasySafeGroupReference(patched, detectedMainGroup);
  if (!mainGroup) return config;
  const profile = [1, 2, 3].indexOf(usageProfile) !== -1 ? usageProfile : 3;
  const cnProviderName = claudeEasyCommonCn(patched, mainGroup);
  if (profile < 3) return patched;
  const ownedNames = claudeEasyOwnedManagedNames(patched);
  const existingAi = claudeEasyExistingAiGroup(patched);
  let aiGroup;
  if (existingAi) {
    if (!claudeEasyConfigureManagedAiGroup(existingAi, patched)) return config;
    aiGroup = existingAi.name;
  } else {
    aiGroup = claudeEasyEnsureAiGroup(patched);
  }
  if (!aiGroup) return config;
  aiGroup = claudeEasySafeGroupReference(patched, aiGroup);
  if (!aiGroup) return config;
  const routeGroup = mainGroup;
  patched.ipv6 = false;
  patched.tun = patched.tun && typeof patched.tun === "object" && !Array.isArray(patched.tun) ? patched.tun : {};
  patched.tun.enable = true;
  patched.tun.stack = "system";
  patched.tun["dns-hijack"] = ["any:53", "tcp://any:53"];
  patched.tun["auto-route"] = true;
  patched.tun["auto-detect-interface"] = true;
  patched.tun["strict-route"] = true;
  claudeEasyDns(patched, routeGroup, aiGroup, ownedNames.safe, cnProviderName);
  claudeEasyRules(patched, aiGroup, routeGroup, ownedNames.ai, ownedNames.safe);
  claudeEasyRemoveOwnedManagedGroups(
    patched,
    ownedNames.ai.filter(function (name) { return name !== aiGroup && name !== routeGroup; })
      .concat(ownedNames.safe.filter(function (name) { return name !== routeGroup; }))
  );
  return patched;
}

function claudeEasyTransform(config, profileName, usageProfile) {
  const candidate = claudeEasyApply(config, profileName, usageProfile);
  if (candidate === config) return config;
  const secondPass = claudeEasyApply(claudeEasyClone(candidate), profileName, usageProfile);
  if (JSON.stringify(candidate) !== JSON.stringify(secondPass)) return config;
  return candidate;
}

function claudeEasyCompose(previousMain, config, profileName) {
  let previousResult = config;
  if (typeof previousMain === "function") previousResult = previousMain(config, profileName) || config;
  return claudeEasyTransform(previousResult, profileName);
}

function main(config, profileName) {
  const previous = typeof claudeEasyPreviousMain === "function" ? claudeEasyPreviousMain : null;
  const previousResult = previous ? previous(config, profileName) || config : config;
  return claudeEasyTransform(previousResult, profileName, CLAUDE_EASY_USAGE_PROFILE);
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    CLAUDE_EASY_POLICY: CLAUDE_EASY_POLICY,
    claudeEasyCompose: claudeEasyCompose,
    claudeEasyDetectMain: claudeEasyDetectMain,
    claudeEasyRenderAiRules: claudeEasyRenderAiRules,
    claudeEasyRouteGroupName: claudeEasyDetectMain,
    claudeEasyTransform: claudeEasyTransform,
    main: main
  };
}
