const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');
const { isDeepStrictEqual } = require('node:util');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const enginePath = path.join(root, 'claude-easy/scripts/windows/clash_verge_global.js');
const policyPath = path.join(root, 'claude-easy/references/policy.json');
const installerPath = path.join(root, 'claude-easy/scripts/install_windows.ps1');
const installerModuleDir = path.join(root, 'claude-easy/scripts/windows/install_windows');
const fixturePath = path.join(root, 'tests/fixtures/main_group_cases.json');
const available = fs.existsSync(enginePath) && fs.existsSync(policyPath);
const fixturesAvailable = available && fs.existsSync(fixturePath);
const engine = available ? require(enginePath) : null;

test('Windows engine files exist', () => {
  assert.equal(fs.existsSync(enginePath), true, 'Windows enhancement script is missing');
  assert.equal(fs.existsSync(policyPath), true, 'canonical policy is missing');
});
test('global transform applies common policy', { skip: !available }, () => {
  const patched = engine.claudeEasyTransform(baseConfig(), 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === 'AI');
  const safeGroup = engine.claudeEasyRouteGroupName(patched);
  assert.equal(patched.ipv6, false);
  assert.equal(patched.dns.ipv6, false);
  assert.deepEqual(patched.tun['dns-hijack'], ['any:53', 'tcp://any:53']);
  assert.deepEqual(patched.dns['direct-nameserver'], engine.CLAUDE_EASY_POLICY.directResolvers);
  assert.equal(patched.dns['direct-nameserver-follow-policy'], false);
  assert.deepEqual(patched.dns['nameserver-policy']['geosite:cn'], engine.CLAUDE_EASY_POLICY.directResolvers);
  assert.ok(patched.dns['nameserver-policy']['+.openai.com'].every((value) => value.endsWith(`#${ai.name}`)));
  assert.deepEqual(ai, { name: 'AI', type: 'select', proxies: ['Main'] });
  const udpIndex = patched.rules.indexOf(`NETWORK,UDP,${ai.name}`);
  assert.ok(udpIndex >= 0);
  assert.equal(patched.rules[udpIndex + 1], 'NETWORK,UDP,REJECT');
  assert.ok(patched.rules.indexOf(`RULE-SET,${engine.CLAUDE_EASY_POLICY.cnDomainProvider.name},DIRECT`) < udpIndex);
  assert.ok(patched.rules.includes('DOMAIN,raw.githubusercontent.com,AI'));
  assert.ok(patched.rules.includes('DOMAIN,storage.googleapis.com,AI'));
});
test('routes UDP by deterministic destination and fails closed for AI', { skip: !available }, () => {
  const patched = engine.claudeEasyTransform(baseConfig(), 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === 'AI');
  const cnProvider = engine.CLAUDE_EASY_POLICY.cnDomainProvider.name;
  const cnIpProvider = engine.CLAUDE_EASY_POLICY.cnIpProvider.name;
  const expectedOrder = [
    `DOMAIN-SUFFIX,openai.com,${ai.name}`,
    'DOMAIN-SUFFIX,openai.com,REJECT',
    `RULE-SET,${cnProvider},DIRECT`,
    `AND,((NETWORK,UDP),(RULE-SET,${cnIpProvider})),DIRECT`,
    `NETWORK,UDP,${ai.name}`,
    'NETWORK,UDP,REJECT'
  ];
  const indexes = expectedOrder.map((rule) => patched.rules.indexOf(rule));
  assert.equal(patched['rule-providers'][cnIpProvider].behavior, 'ipcidr');
  assert.equal(patched['rule-providers'][cnIpProvider].proxy, 'Main');
  assert.equal(indexes.includes(-1), false);
  for (let index = 1; index < indexes.length; index += 1) {
    assert.ok(indexes[index - 1] < indexes[index]);
  }
  assert.deepEqual(engine.claudeEasyTransform(structuredClone(patched), 'fixture'), patched);
});
test('routes local UDP direct before the global UDP guard', { skip: !available }, () => {
  const patched = engine.claudeEasyTransform(baseConfig(), 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === 'AI');
  const globalUdp = patched.rules.indexOf(`NETWORK,UDP,${ai.name}`);
  const localRules = [
    'AND,((NETWORK,UDP),(IP-CIDR,10.0.0.0/8,no-resolve)),DIRECT',
    'AND,((NETWORK,UDP),(IP-CIDR,100.64.0.0/10,no-resolve)),DIRECT',
    'AND,((NETWORK,UDP),(IP-CIDR,127.0.0.0/8,no-resolve)),DIRECT',
    'AND,((NETWORK,UDP),(IP-CIDR,169.254.0.0/16,no-resolve)),DIRECT',
    'AND,((NETWORK,UDP),(IP-CIDR,172.16.0.0/12,no-resolve)),DIRECT',
    'AND,((NETWORK,UDP),(IP-CIDR,192.168.0.0/16,no-resolve)),DIRECT',
    'AND,((NETWORK,UDP),(IP-CIDR,224.0.0.0/4,no-resolve)),DIRECT',
    'AND,((NETWORK,UDP),(IP-CIDR,255.255.255.255/32,no-resolve)),DIRECT',
    'AND,((NETWORK,UDP),(IP-CIDR6,::1/128,no-resolve)),DIRECT',
    'AND,((NETWORK,UDP),(IP-CIDR6,fc00::/7,no-resolve)),DIRECT',
    'AND,((NETWORK,UDP),(IP-CIDR6,fe80::/10,no-resolve)),DIRECT',
    'AND,((NETWORK,UDP),(IP-CIDR6,ff00::/8,no-resolve)),DIRECT'
  ];
  for (const rule of localRules) {
    assert.ok(patched.rules.includes(rule), rule);
    assert.ok(patched.rules.indexOf(rule) < globalUdp, rule);
  }
  assert.equal(patched.rules.some((rule) => rule.includes('198.18.0.0/15')), false);
});
test('lightweight profiles receive the common China-domain baseline only', { skip: !available }, () => {
  for (const usageProfile of [1, 2]) {
    const input = baseConfig();
    input.ipv6 = true;
    input.tun = { enable: false };
    input.dns['nameserver-policy'] = { 'geosite:cn': ['system'] };
    const patched = engine.claudeEasyTransform(input, 'fixture', usageProfile);
    const providerName = engine.CLAUDE_EASY_POLICY.cnDomainProvider.name;
    const provider = patched['rule-providers'][providerName];
    assert.equal(provider.type, 'http');
    assert.equal(provider.behavior, 'domain');
    assert.equal(provider.format, 'mrs');
    assert.equal(provider.url, engine.CLAUDE_EASY_POLICY.cnDomainProvider.url);
    assert.equal(provider.proxy, 'Main');
    assert.deepEqual(patched.dns['nameserver-policy'][`rule-set:${providerName}`], engine.CLAUDE_EASY_POLICY.directResolvers);
    assert.deepEqual(patched.dns['nameserver-policy']['geosite:cn'], engine.CLAUDE_EASY_POLICY.directResolvers);
    assert.ok(patched.rules.indexOf(`RULE-SET,${providerName},DIRECT`) < patched.rules.indexOf('GEOSITE,CN,DIRECT'));
    assert.equal(patched.ipv6, true);
    assert.deepEqual(patched.tun, { enable: false });
    assert.equal(patched.rules.some((rule) => rule.includes('NETWORK,UDP')), false);
    assert.equal(patched.rules.includes(engine.CLAUDE_EASY_POLICY.cnUdpDirectRule), false);
    assert.equal(Object.hasOwn(patched['rule-providers'], engine.CLAUDE_EASY_POLICY.cnIpProvider.name), false);
    assert.deepEqual(engine.claudeEasyTransform(patched, 'fixture', usageProfile), patched);
  }
});
test('invalid Windows usage profiles leave the subscription unchanged', { skip: !available }, () => {
  for (const usageProfile of [0, 4, null, '3']) {
    const input = baseConfig();
    assert.equal(engine.claudeEasyTransform(input, 'fixture', usageProfile), input);
    assert.deepEqual(engine.claudeEasyTransform(input, 'fixture', usageProfile), input);
  }
});
test('China IP UDP provider preserves a colliding user provider', { skip: !available }, () => {
  const config = baseConfig();
  const providerName = engine.CLAUDE_EASY_POLICY.cnIpProvider.name;
  const userProvider = { type: 'file', behavior: 'ipcidr', path: './user/cn-ip.yaml' };
  config['rule-providers'] = { [providerName]: userProvider };
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const managedName = `${providerName}-2`;
  const cnUdpDirect = engine.CLAUDE_EASY_POLICY.cnUdpDirectRule.replace('{CN_IP}', managedName);
  assert.deepEqual(patched['rule-providers'][providerName], userProvider);
  assert.equal(patched['rule-providers'][managedName].behavior, 'ipcidr');
  assert.ok(patched.rules.includes(cnUdpDirect));
  assert.deepEqual(engine.claudeEasyTransform(structuredClone(patched), 'fixture'), patched);
});
test('every Windows usage profile persists proxy selections across reloads', { skip: !available }, () => {
  for (const usageProfile of [1, 2, 3]) {
    const missing = baseConfig();
    const disabled = baseConfig();
    const invalid = baseConfig();
    disabled.profile = { 'store-selected': false, sibling: 'preserved' };
    invalid.profile = [];
    const patchedMissing = engine.claudeEasyTransform(missing, 'fixture', usageProfile);
    const patchedDisabled = engine.claudeEasyTransform(disabled, 'fixture', usageProfile);
    const patchedInvalid = engine.claudeEasyTransform(invalid, 'fixture', usageProfile);
    assert.equal(patchedMissing.profile['store-selected'], true);
    assert.equal(patchedDisabled.profile['store-selected'], true);
    assert.equal(patchedDisabled.profile.sibling, 'preserved');
    assert.deepEqual(patchedInvalid.profile, { 'store-selected': true });
  }
});
test('Windows preserves REALITY short-id text exactly like macOS', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies[0]['reality-opts'] = { 'short-id': '0906152e4' };
  config.proxies[1]['reality-opts'] = { 'short-id': 'not-hex!!' };
  const patched = engine.claudeEasyTransform(config, 'fixture');
  assert.equal(patched.proxies[0]['reality-opts']['short-id'], '0906152e4');
  assert.equal(typeof patched.proxies[0]['reality-opts']['short-id'], 'string');
  assert.equal(patched.proxies[1]['reality-opts']['short-id'], 'not-hex!!');
});
test('common China-domain baseline preserves a colliding user provider', { skip: !available }, () => {
  const input = baseConfig();
  const providerName = engine.CLAUDE_EASY_POLICY.cnDomainProvider.name;
  input['rule-providers'] = {
    [providerName]: { type: 'file', behavior: 'domain', path: './user-owned.yaml' }
  };
  const patched = engine.claudeEasyTransform(input, 'fixture', 1);
  assert.equal(patched['rule-providers'][providerName].path, './user-owned.yaml');
  assert.ok(patched['rule-providers'][`${providerName}-2`]);
  assert.ok(patched.rules.includes(`RULE-SET,${providerName}-2,DIRECT`));
});
test('common China-domain baseline preserves a colliding user provider path', { skip: !available }, () => {
  const input = baseConfig();
  const provider = engine.CLAUDE_EASY_POLICY.cnDomainProvider;
  input['rule-providers'] = {
    'user-cn': { type: 'file', behavior: 'domain', path: provider.path }
  };
  const patched = engine.claudeEasyTransform(input, 'fixture', 1);
  assert.equal(patched['rule-providers']['user-cn'].path, provider.path);
  assert.equal(patched['rule-providers'][`${provider.name}-2`].path, `./ruleset/${provider.name}-2.mrs`);
  assert.ok(patched.rules.includes(`RULE-SET,${provider.name}-2,DIRECT`));
});
test('common China-domain baseline normalizes Unicode provider cache paths', { skip: !available }, () => {
  const input = baseConfig();
  const provider = engine.CLAUDE_EASY_POLICY.cnDomainProvider;
  const originalPath = provider.path;
  provider.path = './ruleset/caf\u00e9.mrs';
  input['rule-providers'] = {
    'user-cn': { type: 'file', behavior: 'domain', path: './ruleset/cafe\u0301.mrs' }
  };
  try {
    const patched = engine.claudeEasyTransform(input, 'fixture', 1);
    assert.equal(patched['rule-providers'][provider.name], undefined);
    assert.equal(patched['rule-providers'][`${provider.name}-2`].path, './ruleset/caf\u00e9-2.mrs');
  } finally {
    provider.path = originalPath;
  }
});
for (const collision of [
  ['backslash separators', '.\\ruleset\\claude-easy-cn-domain.mrs'],
  ['an omitted dot segment', 'ruleset/claude-easy-cn-domain.mrs'],
  ['different path casing', './RULESET/CLAUDE-EASY-CN-DOMAIN.MRS'],
  ['collapsed parent segments', './ruleset/sub/../claude-easy-cn-domain.mrs'],
  ['an absolute Mihomo HomeDir path', 'C:\\Users\\alice\\AppData\\Roaming\\mihomo\\ruleset\\claude-easy-cn-domain.mrs'],
  ['an absolute UNC Mihomo HomeDir path', '\\\\server\\share\\mihomo\\ruleset\\claude-easy-cn-domain.mrs']
]) {
  test(`common China-domain baseline preserves a Windows-equivalent user provider path: ${collision[0]}`, { skip: !available }, () => {
    const input = baseConfig();
    const provider = engine.CLAUDE_EASY_POLICY.cnDomainProvider;
    input['rule-providers'] = {
      'user-cn': { type: 'file', behavior: 'domain', path: collision[1] }
    };
    const patched = engine.claudeEasyTransform(input, 'fixture', 1);
    assert.equal(patched['rule-providers']['user-cn'].path, collision[1]);
    assert.equal(patched['rule-providers'][provider.name], undefined);
    assert.equal(patched['rule-providers'][`${provider.name}-2`].path, `./ruleset/${provider.name}-2.mrs`);
  });
}
for (const distinctPath of [
  'C:\\cache\\claude-easy-cn-domain.mrs',
  '\\\\server\\share\\cache\\claude-easy-cn-domain.mrs',
  '../ruleset/claude-easy-cn-domain.mrs'
]) {
  test(`common China-domain baseline keeps a distinct Windows path: ${distinctPath}`, { skip: !available }, () => {
    const input = baseConfig();
    const provider = engine.CLAUDE_EASY_POLICY.cnDomainProvider;
    input['rule-providers'] = {
      'user-cn': { type: 'file', behavior: 'domain', path: distinctPath }
    };
    const patched = engine.claudeEasyTransform(input, 'fixture', 1);
    assert.equal(patched['rule-providers']['user-cn'].path, distinctPath);
    assert.equal(patched['rule-providers'][provider.name].path, provider.path);
    assert.equal(patched['rule-providers'][`${provider.name}-2`], undefined);
  });
}
test('preserves an existing user AI group before using it for managed policy', { skip: !available }, () => {
  const config = baseConfig();
  const originalAi = structuredClone(config['proxy-groups'].find((group) => group.name === 'AI'));
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === 'AI');
  assert.deepEqual(ai, originalAi);
  assert.equal(patched['proxy-groups'].some((group) => /^🤖 AI · ClaudeEasy(?: \d+)?$/.test(group.name)), false);
  assert.equal(patched['proxy-groups'].some((group) => /^🛡 安全代理 · ClaudeEasy(?: \d+)?$/.test(group.name)), false);
  assert.ok(patched.rules.includes('DOMAIN-SUFFIX,openai.com,AI'));
  assert.deepEqual(patched.rules.slice(0, 2), engine.claudeEasyRenderAiRules('AI').slice(0, 2));
  assert.ok(patched.dns.nameserver.every((value) => value.endsWith('#Main')));
  assert.ok(patched.dns['nameserver-policy']['+.openai.com'].every((value) => value.endsWith('#AI')));
});
for (const [name, declaredMembership] of [
  ['AI', ['DIRECT']],
  ['OpenAI', ['美国家宽 01']],
  ['AI Tools', ['REJECT']]
]) {
  test(`preserves user AI group membership: ${name}`, { skip: !available }, () => {
    const config = baseConfig();
    config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
    config['proxy-groups'].push({ name, type: 'select', proxies: declaredMembership });
    const patched = engine.main(config, 'subscription');
    const ai = patched['proxy-groups'].find((group) => group.name === name);
    assert.deepEqual(ai, { name, type: 'select', proxies: declaredMembership });
    assert.equal(patched.rules[0], `DOMAIN-SUFFIX,anthropic.com,${name}`);
    assert.ok(patched.rules.includes(`DOMAIN-SUFFIX,openai.com,${name}`));
    assert.deepEqual(engine.main(structuredClone(patched), 'subscription'), patched);
  });
}
test('creates an AI group with all inline nodes when the subscription has none', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === '🤖 AI · ClaudeEasy');
  assert.deepEqual(ai.proxies, ['台湾家宽 01', '日本家宽 01', '美国家宽 01']);
  assert.equal(Object.hasOwn(ai, 'use'), false);
  assert.equal(patched['proxy-groups'].some((group) => /^🛡 安全代理 · ClaudeEasy(?: \d+)?$/.test(group.name)), false);
  assert.ok(patched.rules.includes('DOMAIN-SUFFIX,openai.com,🤖 AI · ClaudeEasy'));
  assert.deepEqual(patched.rules.slice(0, 2), engine.claudeEasyRenderAiRules('🤖 AI · ClaudeEasy').slice(0, 2));
  assert.ok(patched.dns['nameserver-policy']['+.openai.com'].every((value) => value.endsWith('#🤖 AI · ClaudeEasy')));
});
test('new AI group includes every proxy provider', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  config['proxy-providers'] = {
    'airport-a': { type: 'http', url: 'https://example.invalid/a' },
    'airport-b': { type: 'file', path: './providers/b.yaml' }
  };
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === '🤖 AI · ClaudeEasy');
  assert.deepEqual(ai.proxies, ['台湾家宽 01', '日本家宽 01', '美国家宽 01']);
  assert.deepEqual(ai.use, ['airport-a', 'airport-b']);
});
test('new AI group supports provider-only subscriptions', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies = [];
  config['proxy-groups'] = [{ name: 'Main', type: 'select', use: ['airport-a'] }];
  config['proxy-providers'] = {
    'airport-a': { type: 'http', url: 'https://example.invalid/a' }
  };
  config.rules = ['MATCH,Main'];
  const first = engine.claudeEasyTransform(config, 'fixture');
  const ai = first['proxy-groups'].find((group) => group.name === '🤖 AI · ClaudeEasy');
  assert.deepEqual(ai.proxies, []);
  assert.deepEqual(ai.use, ['airport-a']);
  assert.deepEqual(engine.claudeEasyTransform(first, 'fixture'), first);
});
test('does not create an AI group without nodes or providers', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies = [];
  delete config['proxy-providers'];
  config['proxy-groups'] = [{ name: 'Main', type: 'select', proxies: ['Ghost'] }];
  config.rules = ['MATCH,Main'];
  assert.deepEqual(engine.claudeEasyTransform(config, 'fixture'), config);
});
test('preserves ambiguous single-main AI group ownership', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  const aiName = '🤖 AI · ClaudeEasy';
  config['proxy-groups'].push({ name: aiName, type: 'select', proxies: ['Main'] });
  config.rules = engine.claudeEasyRenderAiRules(aiName).concat(config.rules);
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === aiName);
  assert.deepEqual(ai.proxies, ['Main']);
  assert.deepEqual(engine.claudeEasyTransform(structuredClone(patched), 'fixture'), patched);
});
test('removes groups created by an older patch', { skip: !available }, () => {
  const config = baseConfig();
  const aiName = '🤖 AI · ClaudeEasy';
  const safeName = '🛡 安全代理 · ClaudeEasy';
  config['proxy-groups'].push({
    name: aiName, type: 'select', proxies: ['台湾家宽 01', '日本家宽 01', '美国家宽 01']
  });
  config['proxy-groups'].push({
    name: safeName, type: 'select', proxies: ['台湾家宽 01', '日本家宽 01'],
    'include-all': true, 'exclude-type': 'Direct|Dns|Reject|RejectDrop|Pass|PassRule|Compatible|Rematch', 'empty-fallback': 'REJECT'
  });
  config.dns.nameserver = [`https://dns.alidns.com/dns-query#${safeName}`];
  config.dns['nameserver-policy'] = { '+.openai.com': [`https://dns.alidns.com/dns-query#${safeName}`] };
  config.rules = [`NETWORK,UDP,${safeName}`, 'NETWORK,UDP,REJECT']
    .concat(engine.claudeEasyRenderAiRules(aiName), config.rules);
  const patched = engine.claudeEasyTransform(config, 'fixture');
  assert.equal(patched['proxy-groups'].some((group) => group.name === aiName || group.name === safeName), false);
  assert.equal(patched.rules.some((rule) => rule.includes(aiName) || rule.includes(safeName)), false);
  assert.equal(JSON.stringify(patched.dns).includes(safeName), false);
  assert.deepEqual(patched.rules.slice(0, 2), engine.claudeEasyRenderAiRules('AI').slice(0, 2));
});
test('preserves encrypted IP bootstrap and replaces direct resolvers with managed mainland DoH', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies.push({ name: 'ecs', type: 'ss', server: 'proxy.invalid' });
  config.dns['default-nameserver'] = ['tls://223.5.5.5', 'tls://1.12.12.12'];
  config.dns['proxy-server-nameserver'] = ['https://223.5.5.5/dns-query', 'https://1.1.1.1/dns-query#ecs'];
  config.dns['direct-nameserver'] = ['system'];
  const dns = engine.claudeEasyTransform(config, 'fixture').dns;
  assert.deepEqual(dns['default-nameserver'], ['tls://223.5.5.5', 'tls://1.12.12.12']);
  assert.deepEqual(dns['proxy-server-nameserver'], ['https://223.5.5.5/dns-query', 'https://1.1.1.1/dns-query#ecs']);
  assert.deepEqual(dns['direct-nameserver'], engine.CLAUDE_EASY_POLICY.directResolvers);
  assert.equal(dns['direct-nameserver-follow-policy'], false);
});
test('managed DNS uses bootstrap-free IP DoH and rewrites other endpoints', { skip: !available }, () => {
  const expectedResolvers = [
    'https://94.140.14.140/dns-query',
    'https://94.140.14.141/dns-query',
    'https://101.101.101.101/dns-query'
  ];
  assert.deepEqual(engine.CLAUDE_EASY_POLICY.resolvers, expectedResolvers);
  assert.deepEqual(engine.CLAUDE_EASY_POLICY.directResolvers, [
    'https://223.5.5.5/dns-query#DIRECT',
    'https://1.12.12.12/dns-query#DIRECT'
  ]);
  const config = baseConfig();
  config.dns['proxy-server-nameserver'] = ['223.5.5.5', '120.53.53.53'];
  config.dns['nameserver-policy'] = {
    '+.hostname-resolver.example': ['https://dns.alidns.com/dns-query#台湾家宽 01'],
    '+.blocked-prone.example': ['https://8.8.8.8/dns-query#台湾家宽 01'],
    '+.managed.example': ['https://94.140.14.140/dns-query#台湾家宽 01']
  };
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const policies = patched.dns['nameserver-policy'];
  const managed = expectedResolvers.map((resolver) => `${resolver}#台湾家宽 01`);
  assert.deepEqual(policies['+.hostname-resolver.example'], managed);
  assert.deepEqual(policies['+.blocked-prone.example'], managed);
  assert.deepEqual(policies['+.managed.example'], managed);
  assert.deepEqual(patched.dns['proxy-server-nameserver'], engine.CLAUDE_EASY_POLICY.bootstrapFallbackResolvers);
});
test('uses bootstrap-free mainland DoH when proxy bootstrap is missing', { skip: !available }, () => {
  for (const usageProfile of [1, 2, 3]) {
    const dns = engine.claudeEasyTransform(baseConfig(), 'fixture', usageProfile).dns;
    assert.equal(Object.hasOwn(dns, 'default-nameserver'), false);
    assert.deepEqual(dns['proxy-server-nameserver'], [
      'https://223.5.5.5/dns-query#DIRECT',
      'https://1.12.12.12/dns-query#DIRECT'
    ]);
    assert.deepEqual(dns['direct-nameserver'], engine.CLAUDE_EASY_POLICY.directResolvers);
    assert.equal(dns['direct-nameserver-follow-policy'], false);
  }
});
test('migrates system proxy bootstrap to bootstrap-free mainland DoH', { skip: !available }, () => {
  const config = baseConfig();
  config.dns['proxy-server-nameserver'] = ['system'];
  for (const usageProfile of [1, 2, 3]) {
    const dns = engine.claudeEasyTransform(config, 'fixture', usageProfile).dns;
    assert.deepEqual(dns['proxy-server-nameserver'], [
      'https://223.5.5.5/dns-query#DIRECT',
      'https://1.12.12.12/dns-query#DIRECT'
    ]);
  }
});
test('migrates non-list bootstrap fields in every usage profile', { skip: !available }, () => {
  for (const value of ['system', 'https://223.5.5.5/dns-query']) {
    const config = baseConfig();
    config.dns['default-nameserver'] = value;
    config.dns['proxy-server-nameserver'] = value;
    for (const usageProfile of [1, 2, 3]) {
      const dns = engine.claudeEasyTransform(config, 'fixture', usageProfile).dns;
      assert.deepEqual(dns['default-nameserver'], engine.CLAUDE_EASY_POLICY.bootstrapFallbackResolvers);
      assert.deepEqual(dns['proxy-server-nameserver'], engine.CLAUDE_EASY_POLICY.bootstrapFallbackResolvers);
    }
  }
});
test('migrates mixed system and plaintext bootstrap to bootstrap-free mainland DoH', { skip: !available }, () => {
  const config = baseConfig();
  config.dns['default-nameserver'] = ['udp://223.5.5.5', 'system', 'tls://1.12.12.12'];
  config.dns['proxy-server-nameserver'] = ['https://1.1.1.1/dns-query#h3=true#&skip-cert-verify=true&DIRECT'];
  for (const usageProfile of [1, 2, 3]) {
    const dns = engine.claudeEasyTransform(config, 'fixture', usageProfile).dns;
    assert.deepEqual(dns['default-nameserver'], engine.CLAUDE_EASY_POLICY.bootstrapFallbackResolvers);
    assert.deepEqual(dns['proxy-server-nameserver'], engine.CLAUDE_EASY_POLICY.bootstrapFallbackResolvers);
  }
});
test('migrates the old unsafe bootstrap signature to bootstrap-free mainland DoH', { skip: !available }, () => {
  const config = baseConfig();
  config.dns['default-nameserver'] = ['1.1.1.1', '8.8.8.8'];
  config.dns['proxy-server-nameserver'] = ['https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query'];
  const dns = engine.claudeEasyTransform(config, 'fixture').dns;
  const expected = [
    'https://223.5.5.5/dns-query#DIRECT',
    'https://1.12.12.12/dns-query#DIRECT'
  ];
  assert.deepEqual(dns['default-nameserver'], expected);
  assert.deepEqual(dns['proxy-server-nameserver'], expected);
});
test('migrates the reversed old unsafe proxy bootstrap signature', { skip: !available }, () => {
  const config = baseConfig();
  config.dns['proxy-server-nameserver'] = [
    'https://8.8.8.8/dns-query',
    'https://1.1.1.1/dns-query'
  ];
  const dns = engine.claudeEasyTransform(config, 'fixture', 1).dns;
  assert.deepEqual(dns['proxy-server-nameserver'], [
    'https://223.5.5.5/dns-query#DIRECT',
    'https://1.12.12.12/dns-query#DIRECT'
  ]);
});
test('main delegates to the same transform', { skip: !available }, () => {
  assert.deepEqual(engine.main(baseConfig(), 'fixture'), engine.claudeEasyTransform(baseConfig(), 'fixture'));
});
test('transform is idempotent', { skip: !available }, () => {
  const once = engine.claudeEasyTransform(baseConfig(), 'fixture');
  const twice = engine.claudeEasyTransform(once, 'fixture');
  assert.deepEqual(twice, once);
});
test('global transform verifies a second pass before returning a candidate', () => {
  const source = fs.readFileSync(enginePath, 'utf8');
  const sandbox = {};
  vm.runInNewContext(
    `${source}\n` +
      'globalThis.claudeEasyTestTransform = claudeEasyTransform;\n' +
      'globalThis.claudeEasyTestSetApply = function (replacement) { claudeEasyApply = replacement; };\n',
    sandbox
  );
  let passes = 0;
  sandbox.claudeEasyTestSetApply((config) => {
    passes += 1;
    return { ...config, mutation: passes };
  });
  const original = { fixture: true };
  const result = sandbox.claudeEasyTestTransform(original, 'fixture', 3);
  assert.equal(passes, 2);
  assert.strictEqual(result, original);
});
test('new AI group lists US home broadband without auto selecting it', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies = config.proxies.filter((proxy) => proxy.name === '美国家宽 01');
  config['proxy-groups'] = [{ name: 'Main', type: 'select', proxies: ['美国家宽 01'] }];
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === '🤖 AI · ClaudeEasy');
  assert.deepEqual(ai.proxies, ['美国家宽 01']);
  assert.equal(Object.hasOwn(ai, 'now'), false);
});
test('does not alter the user AI group while Japan nodes remain available', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies = config.proxies.filter((proxy) => !proxy.name.includes('台湾'));
  config['proxy-groups'][0].proxies = config['proxy-groups'][0].proxies.filter((name) => !name.includes('台湾'));
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === 'AI');
  assert.deepEqual(ai.proxies, ['Main']);
  assert.equal(Object.hasOwn(ai, 'now'), false);
});
test('puts the UDP guard ahead of a narrow rule set', { skip: !available }, () => {
  const config = baseConfig();
  config.rules.splice(2, 0, 'RULE-SET,private-special,DIRECT');
  const rules = engine.claudeEasyTransform(config, 'fixture').rules;
  const udpIndex = rules.findIndex((rule) => rule.startsWith('NETWORK,UDP,') && rule !== 'NETWORK,UDP,REJECT');
  const cnUdpDirect = engine.CLAUDE_EASY_POLICY.cnUdpDirectRule.replace(
    '{CN_IP}', engine.CLAUDE_EASY_POLICY.cnIpProvider.name
  );
  assert.equal(rules[udpIndex - 1], cnUdpDirect);
  assert.equal(rules[udpIndex + 1], 'NETWORK,UDP,REJECT');
  assert.ok(udpIndex < rules.indexOf('GEOSITE,CN,DIRECT'));
  assert.ok(udpIndex < rules.indexOf('RULE-SET,private-special,DIRECT'));
});
test('strips foreign-target rules that collide with managed AI keys', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'].push({ name: 'MyGroup', type: 'select', proxies: ['台湾家宽 01'] });
  const conflicts = [
    'DOMAIN-SUFFIX,openai.com,MyGroup',
    'DOMAIN-SUFFIX,claude.ai,DIRECT',
    'DOMAIN-SUFFIX,anthropic.com,REJECT'
  ];
  config.rules = conflicts.concat(config.rules);
  const patched = engine.main(config, 'subscription');
  for (const conflict of conflicts.slice(0, 2)) assert.equal(patched.rules.includes(conflict), false, conflict);
  assert.ok(patched.rules.includes('DOMAIN-SUFFIX,anthropic.com,REJECT'));
  assert.ok(patched.rules.includes('DOMAIN-SUFFIX,openai.com,AI'));
  assert.ok(patched.rules.includes('DOMAIN-SUFFIX,claude.ai,AI'));
  assert.ok(patched.rules.includes('DOMAIN-SUFFIX,anthropic.com,AI'));
  assert.deepEqual(engine.main(structuredClone(patched), 'subscription'), patched);
});
test('main-group AI rules do not bypass the independent AI selector', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  const providerRules = [
    'DOMAIN-SUFFIX,openai.com,Main',
    'DOMAIN-SUFFIX,claude.ai,Main',
    'DOMAIN-KEYWORD,openai,Main'
  ];
  config.rules = providerRules.concat(config.rules);
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === '🤖 AI · ClaudeEasy');
  for (const rule of providerRules) assert.equal(patched.rules.includes(rule), false, rule);
  assert.ok(patched.rules.includes(`DOMAIN-SUFFIX,openai.com,${ai.name}`));
  assert.ok(patched.rules.includes(`DOMAIN-SUFFIX,claude.ai,${ai.name}`));
  assert.ok(patched.rules.includes(`DOMAIN-KEYWORD,openai,${ai.name}`));
});
test('UDP guard precedes leaking rules without deleting them', { skip: !available }, () => {
  const config = baseConfig();
  const userRules = [
    'NETWORK,udp,DIRECT',
    'NETWORK, UDP, DIRECT',
    'DST-PORT,3478,DIRECT',
    'PROCESS-NAME,chrome.exe,DIRECT'
  ];
  config.rules = userRules.concat(config.rules);
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const guard = 'NETWORK,UDP,AI';
  const cnUdpDirect = engine.CLAUDE_EASY_POLICY.cnUdpDirectRule.replace(
    '{CN_IP}', engine.CLAUDE_EASY_POLICY.cnIpProvider.name
  );
  assert.equal(patched.rules[patched.rules.indexOf(guard) - 1], cnUdpDirect);
  assert.equal(patched.rules[patched.rules.indexOf(guard) + 1], 'NETWORK,UDP,REJECT');
  for (const rule of userRules) {
    assert.ok(patched.rules.includes(rule), rule);
    assert.ok(patched.rules.indexOf(guard) < patched.rules.indexOf(rule), rule);
  }
});
test('preserves user UDP rules to selected groups', { skip: !available }, () => {
  for (const [target, expectedCount] of [['Main', 1], ['AI', 2]]) {
    const config = baseConfig();
    const userRule = `NETWORK,UDP,${target}`;
    config.rules.splice(2, 0, userRule, 'NETWORK,UDP,REJECT');
    const rules = engine.claudeEasyTransform(config, 'fixture').rules;
    assert.equal(rules.filter((rule) => rule === userRule).length, expectedCount, target);
    assert.equal(rules.filter((rule) => rule === 'NETWORK,UDP,REJECT').length, 2, target);
  }
});
test('preserves a leading user UDP rule to the main group', { skip: !available }, () => {
  const config = baseConfig();
  config.rules.unshift('NETWORK,UDP,Main', 'NETWORK,UDP,REJECT');
  const rules = engine.claudeEasyTransform(config, 'fixture').rules;
  assert.equal(rules.filter((rule) => rule === 'NETWORK,UDP,Main').length, 1);
  assert.equal(rules.filter((rule) => rule === 'NETWORK,UDP,REJECT').length, 2);
});
test('managed AI rules precede every rule set', { skip: !available }, () => {
  const config = baseConfig();
  config.rules = ['RULE-SET,gfw,DIRECT', 'RULE-SET,geolocation-!cn,Main', 'MATCH,Main'];
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const managed = patched.rules.find((rule) => rule.startsWith('DOMAIN-SUFFIX,openai.com,🤖 AI · ClaudeEasy'));
  assert.ok(patched.rules.indexOf(managed) < patched.rules.indexOf('RULE-SET,gfw,DIRECT'));
  assert.ok(patched.rules.indexOf(managed) < patched.rules.indexOf('RULE-SET,geolocation-!cn,Main'));
});
test('exports the canonical policy without divergence', { skip: !available }, () => {
  const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
  const mapping = {
    version: 'version',
    resolvers: 'resolvers',
    direct_resolvers: 'directResolvers',
    bootstrap_fallback_resolvers: 'bootstrapFallbackResolvers',
    main_group_names: 'mainGroupNames',
    ai_group_names: 'aiGroupNames',
    taiwan_tokens: 'taiwanTokens',
    japan_tokens: 'japanTokens',
    forbidden_ai_domains: 'forbiddenAiDomains',
    legacy_ai_rules: 'legacyAiRules',
    ai_rules: 'aiRules'
  };
  for (const [jsonKey, jsKey] of Object.entries(mapping)) {
    assert.deepEqual(engine.CLAUDE_EASY_POLICY[jsKey], policy[jsonKey], `policy divergence at ${jsonKey}`);
  }
});
test('shared main-group fixtures match the Ruby engine', { skip: !fixturesAvailable }, () => {
  const shared = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
  assert.equal(shared.schema_version, 1);
  const cases = shared.cases;
  for (const fixture of cases) {
    const snapshot = JSON.parse(JSON.stringify(fixture.config));
    assert.equal(engine.claudeEasyDetectMain(fixture.config), fixture.expected_main_group, fixture.name);
    if (fixture.expected_main_group === null) {
      engine.claudeEasyTransform(fixture.config, 'fixture');
      assert.deepEqual(fixture.config, snapshot, fixture.name);
    }
  }
});
test('complex dynamic filters are patched in every usage profile', { skip: !available }, () => {
  const config = {
    proxies: [{ name: 'HK 01', type: 'ss', server: 'hk.example' }],
    'proxy-groups': [{
      name: 'Dynamic', type: 'select', 'include-all-proxies': true,
      filter: '(?i)HK|香港'
    }],
    rules: ['MATCH,Dynamic']
  };
  for (const usageProfile of [1, 2, 3]) {
    const patched = engine.claudeEasyTransform(config, 'fixture', usageProfile);
    assert.notDeepEqual(patched, config, `usage profile ${usageProfile}`);
    assert.equal(engine.claudeEasyDetectMain(patched), 'Dynamic', `usage profile ${usageProfile}`);
  }
});
test('shared unsafe group references use managed wrappers', { skip: !fixturesAvailable }, () => {
  const fixtures = JSON.parse(fs.readFileSync(fixturePath, 'utf8')).unsafe_reference_cases;
  const routeWrapper = '🔗 路由引用 · ClaudeEasy';
  const aiWrapper = '🔗 路由引用 · ClaudeEasy 2';
  for (const fixture of fixtures) {
    const input = structuredClone(fixture.config);
    const snapshot = structuredClone(input);
    const patched = engine.claudeEasyTransform(input, 'fixture');
    const groups = patched['proxy-groups'];
    assert.deepEqual(groups.find((group) => group.name === routeWrapper).proxies, [fixture.main_group], fixture.name);
    assert.deepEqual(groups.find((group) => group.name === aiWrapper).proxies, [fixture.ai_group], fixture.name);
    const provider = Object.values(patched['rule-providers']).find((item) => item.url === engine.CLAUDE_EASY_POLICY.cnDomainProvider.url);
    assert.equal(provider.proxy, routeWrapper, fixture.name);
    assert.deepEqual(
      patched.dns.nameserver,
      engine.CLAUDE_EASY_POLICY.resolvers.map((resolver) => `${resolver}#${routeWrapper}`),
      fixture.name
    );
    assert.deepEqual(
      patched.dns['nameserver-policy']['+.openai.com'],
      engine.CLAUDE_EASY_POLICY.resolvers.map((resolver) => `${resolver}#${aiWrapper}`),
      fixture.name
    );
    assert.ok(patched.rules.includes(`NETWORK,UDP,${aiWrapper}`), fixture.name);
    assert.ok(patched.rules.includes(`DOMAIN-SUFFIX,openai.com,${aiWrapper}`), fixture.name);
    assert.equal(JSON.stringify(patched.dns).includes('skip-cert-verify=true'), false, fixture.name);
    assert.deepEqual(input, snapshot, `${fixture.name}: input mutated`);
    assert.deepEqual(engine.claudeEasyTransform(patched, 'fixture'), patched, `${fixture.name}: second pass`);
  }
});
test('shared full-transform fixtures match the Ruby engine', { skip: !fixturesAvailable }, () => {
  const fixtures = JSON.parse(fs.readFileSync(fixturePath, 'utf8')).transform_cases;
  for (const fixture of fixtures) {
    const input = structuredClone(fixture.input);
    const snapshot = structuredClone(input);
    const patched = engine.claudeEasyTransform(input, 'fixture');
    const changed = !isDeepStrictEqual(patched, input);
    const valid = input && typeof input === 'object' && !Array.isArray(input) &&
      Array.isArray(input['proxy-groups']) && (input.rules == null || Array.isArray(input.rules)) &&
      (Array.isArray(input.proxies) ||
        (input['proxy-providers'] && typeof input['proxy-providers'] === 'object' && !Array.isArray(input['proxy-providers'])));
    const mainGroup = valid ? engine.claudeEasyDetectMain(input) : null;
    const udp = patched && Array.isArray(patched.rules) ? patched.rules.find((rule) => /^NETWORK\s*,\s*UDP\s*,/i.test(rule)) : null;
    const aiGroup = udp ? udp.split(',').map((field) => field.trim()).at(-1) : null;
    assert.equal(changed, fixture.expected_changed, fixture.name);
    const expectedDetectedMain = Object.hasOwn(fixture, 'expected_detected_main_group') ?
      fixture.expected_detected_main_group : fixture.expected_main_group;
    assert.equal(mainGroup, expectedDetectedMain, fixture.name);
    if (fixture.expected_main_group !== null) {
      assert.ok(
        patched['proxy-groups'].some((group) => group && group.name === fixture.expected_main_group),
        `${fixture.name}: main group was removed`
      );
    }
    assert.equal(aiGroup, fixture.expected_ai_group, fixture.name);
    assert.deepEqual(input, snapshot, `${fixture.name}: input mutated`);
    const expectedPath = path.join(root, 'tests/fixtures/transform_expected', `${fixture.name}.json`);
    const expected = JSON.parse(fs.readFileSync(expectedPath, 'utf8'));
    assert.deepStrictEqual(JSON.parse(JSON.stringify(patched)), expected, `${fixture.name}: output drift`);
    const serialized = JSON.stringify(patched);
    for (const value of fixture.expected_absent_strings || []) {
      assert.equal(serialized.includes(value), false, `${fixture.name}: retained ${value}`);
    }
    for (const value of fixture.expected_present_strings || []) {
      assert.equal(serialized.includes(value), true, `${fixture.name}: missing ${value}`);
    }
    if (fixture.expected_changed) {
      assert.deepEqual(engine.claudeEasyTransform(patched, 'fixture'), patched, `${fixture.name}: second pass`);
    }
  }
});
test('keeps a non-select AI group and creates a non-conflicting selector', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  config['proxy-groups'].push({ name: 'AI', type: 'url-test', proxies: ['台湾家宽 01'], url: 'https://example.invalid', interval: 300 });
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const original = patched['proxy-groups'].find((group) => group.name === 'AI');
  assert.equal(original.type, 'url-test');
  const created = patched['proxy-groups'].find((group) => group.name === '🤖 AI · ClaudeEasy');
  assert.ok(created, 'a new AI selector must be created');
  assert.equal(created.type, 'select');
  assert.ok(patched.rules.includes('DOMAIN-SUFFIX,openai.com,🤖 AI · ClaudeEasy'));
  assert.ok(patched.rules.includes('NETWORK,UDP,🤖 AI · ClaudeEasy'));
  for (const group of patched['proxy-groups']) {
    assert.ok(!(Array.isArray(group.proxies) && group.proxies.includes(group.name)), `group ${group.name} references itself`);
  }
});
test('an AI-only selectable group receives the full patch as a last resort', { skip: !available }, () => {
  const config = {
    proxies: [{ name: '台湾家宽 01', type: 'ss', server: 'tw.example' }],
    'proxy-groups': [{ name: 'AI', type: 'select', proxies: ['台湾家宽 01'] }],
    rules: ['MATCH,AI']
  };
  assert.equal(engine.claudeEasyDetectMain(config), 'AI');
  const patched = engine.claudeEasyTransform(config, 'fixture');
  assert.notStrictEqual(patched, config);
  assert.equal(patched['rule-providers']['claude-easy-cn-domain'].proxy, 'AI');
  assert.ok(patched.rules.includes('NETWORK,UDP,AI'));
});
test('patches and preserves a provider-only profile', { skip: !available }, () => {
  const providers = { provider1: { type: 'http', url: 'https://example.invalid/sub', interval: 3600 } };
  const config = {
    'proxy-providers': providers,
    'proxy-groups': [
      { name: 'Main', type: 'select', use: ['provider1'] },
      { name: 'AI', type: 'select', use: ['provider1'] }
    ],
    rules: ['MATCH,Main']
  };
  const patched = engine.claudeEasyTransform(config, 'fixture');
  assert.equal(engine.claudeEasyDetectMain(config), 'Main');
  assert.deepEqual(patched['proxy-providers'], providers);
  assert.deepEqual(patched['proxy-groups'].find((group) => group.name === 'Main').use, ['provider1']);
  assert.ok(patched.rules.includes('NETWORK,UDP,AI'));
  for (const group of patched['proxy-groups']) {
    assert.ok(!(Array.isArray(group.proxies) && group.proxies.includes(group.name)), `group ${group.name} references itself`);
  }
});
test('composes an existing main before ClaudeEasy', { skip: !available }, () => {
  const previous = (config) => {
    config.marker = 'previous-ran';
    return config;
  };
  const patched = engine.claudeEasyCompose(previous, baseConfig(), 'fixture');
  assert.equal(patched.marker, 'previous-ran');
  assert.equal(patched.ipv6, false);
});
test('returns invalid configurations unchanged', { skip: !available }, () => {
  const invalid = { message: '401 unauthorized' };
  assert.deepEqual(engine.claudeEasyTransform(invalid, 'fixture'), invalid);
});

test('PowerShell safe update checks installed script and proxy-group prerequisites before acceptance', () => {
  const installer = fs.readFileSync(installerPath, 'utf8');
  const safeUpdateModule = fs.readFileSync(path.join(installerModuleDir, 'safe_update.ps1'), 'utf8');
  const scriptCheck = installer.indexOf(
    'Assert-ClaudeEasyManagedScriptCurrent $scriptText $savedProfile $enginePath $targetScript'
  );
  const profileCheck = installer.indexOf(
    'Assert-ClaudeEasyProxyGroupCollection $text $publicSubscriptionLabel'
  );
  const mihomoCheck = installer.indexOf('Test-MihomoCandidate $core $text $profilesDirectory');
  const manifestRemoval = installer.indexOf(
    'Remove-VerifiedOwnedFile $safeUpdateStatePath $manifestSnapshot.Bytes $manifestSnapshot.Identity'
  );
  assert.ok(scriptCheck >= 0, 'safe update does not validate the installed global script');
  assert.ok(profileCheck > scriptCheck, 'proxy-group prerequisites are not checked after the installed script');
  assert.ok(mihomoCheck > profileCheck, 'Mihomo validation does not run after proxy-group checks');
  assert.ok(manifestRemoval > mihomoCheck, 'safe-update manifest is removed before validation finishes');
  const postVerification = installer.slice(installer.indexOf('foreach ($entry in $validated)'));
  assert.doesNotMatch(postVerification, /Get-FileSha256\s+\$[^\r\n]*Target\.Path/);
  assert.match(postVerification, /ValidatedSha256/);
  assert.match(
    safeUpdateModule,
    /\$flowLines \+= @\(\$lines\[\(\$groupsNode\.Start \+ 1\)\.\.\(\$lines\.Count - 1\)\]\)/,
    'multi-line flow sequences stop before their top-level closing bracket'
  );
});

test('DNS fragments must resolve to a non-direct proxy or group', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'].push({ name: 'SafeExisting', type: 'select', proxies: ['台湾家宽 01'] });
  config['proxy-groups'].push({ name: 'CanDirect', type: 'select', proxies: ['台湾家宽 01', 'DIRECT'] });
  config.dns['nameserver-policy'] = {
    '+.proxy.example': ['https://1.1.1.1/dns-query#台湾家宽 01'],
    '+.group.example': ['https://1.1.1.1/dns-query#SafeExisting'],
    '+.direct.example': ['https://1.1.1.1/dns-query#CanDirect'],
    '+.option.example': ['https://1.1.1.1/dns-query#h3=true'],
    '+.interface.example': ['https://1.1.1.1/dns-query#en0'],
    '+.overridden.example': ['https://1.1.1.1/dns-query#SafeExisting&DIRECT'],
    '+.encoded-overridden.example': ['https://1.1.1.1/dns-query#SafeExisting&%44IRECT'],
    '+.invalid-percent.example': ['https://1.1.1.1/dns-query#SafeExisting&ecs%ZZvalue'],
    '+.multi-fragment.example': ['https://1.1.1.1/dns-query#h3=true#&skip-cert-verify=true&SafeExisting']
  };
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const policy = patched.dns['nameserver-policy'];
  assert.deepEqual(policy['+.proxy.example'], engine.CLAUDE_EASY_POLICY.resolvers.map((resolver) => `${resolver}#台湾家宽 01`));
  assert.deepEqual(policy['+.group.example'], engine.CLAUDE_EASY_POLICY.resolvers.map((resolver) => `${resolver}#SafeExisting`));
  for (const pattern of [
    '+.direct.example', '+.option.example', '+.interface.example',
    '+.overridden.example', '+.encoded-overridden.example', '+.invalid-percent.example', '+.multi-fragment.example'
  ]) {
    assert.ok(policy[pattern].every((value) => value.endsWith(`#${engine.claudeEasyRouteGroupName(patched)}`)), pattern);
  }
});
test('DNS policy rejects plaintext and dynamic group targets', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-providers'] = { provider1: { type: 'http', url: 'https://example.invalid/sub' } };
  config['proxy-groups'].push({ name: 'ProviderGroup', type: 'select', use: ['provider1'] });
  config['proxy-groups'].push({ name: 'IncludeAllGroup', type: 'select', 'include-all': true, 'exclude-type': 'Indirect' });
  config.dns['nameserver-policy'] = {
    '+.encrypted.example': ['https://1.1.1.1/dns-query#台湾家宽 01'],
    '+.plaintext.example': ['1.1.1.1#台湾家宽 01'],
    '+.provider.example': ['https://1.1.1.1/dns-query#ProviderGroup'],
    '+.include-all.example': ['https://1.1.1.1/dns-query#IncludeAllGroup']
  };
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const policies = patched.dns['nameserver-policy'];
  const safeSuffix = `#${engine.claudeEasyRouteGroupName(patched)}`;
  assert.deepEqual(policies['+.encrypted.example'], engine.CLAUDE_EASY_POLICY.resolvers.map((resolver) => `${resolver}#台湾家宽 01`));
  for (const pattern of ['+.plaintext.example', '+.provider.example', '+.include-all.example']) {
    assert.ok(policies[pattern].every((endpoint) => endpoint.endsWith(safeSuffix)), pattern);
  }
});
test('DNS policy refuses subscription-filtered groups and DNS outbounds', { skip: !available }, () => {
  const config = baseConfig();
  const originalMain = structuredClone(config['proxy-groups'].find((group) => group.name === 'Main'));
  config.proxies.push({ name: 'InternalDNS', type: 'dns' });
  config['proxy-groups'].push(
    { name: 'FilteredToCompatible', type: 'select', proxies: ['台湾家宽 01'], 'exclude-filter': '台湾' },
    {
      name: 'FilteredToSafeProxy', type: 'select', proxies: ['台湾家宽 01'],
      'exclude-filter': '台湾', 'empty-fallback': '日本家宽 01'
    },
    { name: 'DnsOutboundGroup', type: 'select', proxies: ['InternalDNS'] }
  );
  config.dns['nameserver-policy'] = {
    '+.compatible.example': ['https://1.1.1.1/dns-query#FilteredToCompatible'],
    '+.fallback.example': ['https://1.1.1.1/dns-query#FilteredToSafeProxy'],
    '+.dns-out.example': ['https://1.1.1.1/dns-query#DnsOutboundGroup']
  };
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const policies = patched.dns['nameserver-policy'];
  const safeName = engine.claudeEasyRouteGroupName(patched);
  const safeSuffix = `#${safeName}`;
  const mainGroup = patched['proxy-groups'].find((group) => group.name === safeName);
  assert.ok(policies['+.compatible.example'].every((endpoint) => endpoint.endsWith(safeSuffix)));
  assert.ok(policies['+.fallback.example'].every((endpoint) => endpoint.endsWith(safeSuffix)));
  assert.ok(policies['+.dns-out.example'].every((endpoint) => endpoint.endsWith(safeSuffix)));
  assert.deepEqual(mainGroup, originalMain);
});
test('DNS policy rejects every subscription-controlled group filter', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies.push(
    { name: 'Taiwan Backup', type: 'ss', server: 'tw-backup.example', password: 'fixture-secret' },
    { name: 'Japan Backup', type: 'ss', server: 'jp-backup.example', password: 'fixture-secret' }
  );
  config['proxy-groups'].push(
    { name: 'CaseFiltered', type: 'select', proxies: ['Taiwan Backup', 'Japan Backup'], 'exclude-filter': '(?i)taiwan' },
    { name: 'InvalidFilter', type: 'select', proxies: ['Japan Backup'], 'exclude-filter': '[' }
  );
  config.dns['nameserver-policy'] = {
    '+.case-filtered.example': ['https://1.1.1.1/dns-query#CaseFiltered'],
    '+.invalid-filter.example': ['https://1.1.1.1/dns-query#InvalidFilter']
  };
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const routeGroup = engine.claudeEasyRouteGroupName(patched);
  for (const pattern of ['+.case-filtered.example', '+.invalid-filter.example']) {
    assert.ok(patched.dns['nameserver-policy'][pattern].every((endpoint) => endpoint.endsWith(`#${routeGroup}`)), pattern);
  }
});
test('DNS policy never executes subscription-controlled catastrophic group filters', { skip: !available }, () => {
  const config = baseConfig();
  const nearMiss = `${'a'.repeat(18)}!`;
  config.proxies.push({ name: nearMiss, type: 'ss', server: 'safe.example', password: 'fixture-secret' });
  config['proxy-groups'].push(
    { name: 'NestedQuantifier', type: 'select', proxies: [nearMiss], 'exclude-filter': '(a+)+$' },
    { name: 'OverlappingAlternation', type: 'select', proxies: [nearMiss], 'exclude-filter': '(a|aa)+$' }
  );
  config.dns['nameserver-policy'] = {
    '+.nested.example': ['https://1.1.1.1/dns-query#NestedQuantifier'],
    '+.overlap.example': ['https://1.1.1.1/dns-query#OverlappingAlternation']
  };
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const safeSuffix = `#${engine.claudeEasyRouteGroupName(patched)}`;
  for (const pattern of ['+.nested.example', '+.overlap.example']) {
    assert.ok(patched.dns['nameserver-policy'][pattern].every((endpoint) => endpoint.endsWith(safeSuffix)), pattern);
  }
});
test('nested rules and the legacy QUIC guard are handled without weakening user rules', { skip: !available }, () => {
  const config = baseConfig();
  const nestedUserRule = 'AND,((NETWORK,UDP),(DST-PORT,3478)),REJECT';
  const legacyQuicGuard = 'AND,((NETWORK,UDP),(DST-PORT,443)),REJECT';
  config.rules.unshift(nestedUserRule, legacyQuicGuard);
  const patched = engine.claudeEasyTransform(config, 'fixture');
  assert.ok(patched.rules.includes(nestedUserRule), 'a user nested rule was removed');
  assert.equal(patched.rules.includes(legacyQuicGuard), false, 'the managed legacy guard was retained');
});
test('DNS policy rejects privacy-weakening resolver options', { skip: !available }, () => {
  const config = baseConfig();
  const target = '台湾家宽 01';
  config.dns['nameserver-policy'] = {
    '+.h3.example': [`https://1.1.1.1/dns-query#${target}&h3=true`],
    '+.skip-cert.example': [`https://1.1.1.1/dns-query#${target}&skip-cert-verify=true`],
    '+.ecs.example': [`https://1.1.1.1/dns-query#${target}&ecs=203.0.113.0/24&ecs-override=true`],
    '+.encoded-skip-cert.example': [`https://1.1.1.1/dns-query#${target}&skip-cert-verify%3Dtrue`],
    '+.encoded-ecs.example': [`https://1.1.1.1/dns-query#${target}&%65cs=203.0.113.0/24`]
  };
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const policies = patched.dns['nameserver-policy'];
  const safeSuffix = `#${engine.claudeEasyRouteGroupName(patched)}`;
  assert.deepEqual(policies['+.h3.example'], engine.CLAUDE_EASY_POLICY.resolvers.map((resolver) => `${resolver}#${target}&h3=true`));
  for (const pattern of ['+.skip-cert.example', '+.ecs.example', '+.encoded-skip-cert.example', '+.encoded-ecs.example']) {
    assert.ok(policies[pattern].every((endpoint) => endpoint.endsWith(safeSuffix)), pattern);
  }
});
test('null proxy providers do not crash DNS validation', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-providers'] = null;
  config['proxy-groups'].push({ name: 'NullProviderGroup', type: 'select', use: ['missing'] });
  config.dns['nameserver-policy'] = {
    '+.null-provider.example': ['https://1.1.1.1/dns-query#NullProviderGroup']
  };
  const patched = engine.claudeEasyTransform(config, 'fixture');
  assert.ok(patched.dns['nameserver-policy']['+.null-provider.example'].every((endpoint) => {
    return endpoint.endsWith(`#${engine.claudeEasyRouteGroupName(patched)}`);
  }));
});
test('direct and rematch home names are not selected automatically', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies.unshift(
    { name: '台湾家宽 DIRECT', type: 'direct' },
    { name: '台湾家宽 REMATCH', type: 'rematch', 'target-rematch-name': 'again' }
  );
  config['proxy-groups'][0].proxies.unshift('台湾家宽 DIRECT', '台湾家宽 REMATCH');
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === 'AI');
  const mainGroup = patched['proxy-groups'].find((group) => group.name === 'Main');
  assert.deepEqual(ai.proxies, ['Main']);
  assert.equal(ai.proxies.includes('台湾家宽 DIRECT'), false);
  assert.equal(ai.proxies.includes('台湾家宽 REMATCH'), false);
  assert.ok(mainGroup.proxies.includes('台湾家宽 DIRECT'));
  assert.ok(mainGroup.proxies.includes('台湾家宽 REMATCH'));
  assert.equal(patched['proxy-groups'].some((group) => /^🛡 安全代理 · ClaudeEasy/.test(group.name)), false);
});
test('tun arrays are replaced by a mapping', { skip: !available }, () => {
  const config = baseConfig();
  config.tun = [];
  const patched = engine.claudeEasyTransform(config, 'fixture');
  assert.equal(Array.isArray(patched.tun), false);
  assert.equal(patched.tun.enable, true);
});
test('owned AI group is independent and collision safe', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  config['proxy-groups'].push({ name: '🤖 AI · ClaudeEasy', type: 'url-test', proxies: ['台湾家宽 01'] });
  config['proxy-groups'].push({ name: '🤖 AI · ClaudeEasy 2', type: 'url-test', proxies: ['台湾家宽 01'] });
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const names = patched['proxy-groups'].map((group) => group.name);
  assert.deepEqual(names, [...new Set(names)]);
  const managed = patched['proxy-groups'].find((group) => group.name === '🤖 AI · ClaudeEasy 3');
  assert.deepEqual(managed.proxies, ['台湾家宽 01', '日本家宽 01', '美国家宽 01']);
});
test('user-owned branded select group is preserved while carrying managed policy', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  const userGroup = {
    name: '🤖 AI · ClaudeEasy',
    type: 'select',
    proxies: ['Main', '日本家宽 01'],
    icon: 'https://example.invalid/user-icon.png'
  };
  config['proxy-groups'].push(userGroup);
  const first = engine.claudeEasyTransform(config, 'fixture');
  const second = engine.claudeEasyTransform(first, 'fixture');
  assert.deepEqual(first['proxy-groups'].find((group) => group.name === userGroup.name), userGroup);
  assert.equal(first['proxy-groups'].some((group) => group.name === '🤖 AI · ClaudeEasy 2'), false);
  assert.ok(first.rules.includes('DOMAIN-SUFFIX,openai.com,🤖 AI · ClaudeEasy'));
  assert.deepEqual(second, first);
});
test('managed-looking user AI group without prior ownership evidence is preserved idempotently', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  const userGroup = {
    name: '🤖 AI · ClaudeEasy',
    type: 'select',
    proxies: ['Main']
  };
  config['proxy-groups'].push(userGroup);
  const patched = engine.claudeEasyTransform(config, 'fixture');
  assert.notDeepEqual(patched, config);
  assert.deepEqual(patched['proxy-groups'].find((group) => group.name === userGroup.name), userGroup);
  assert.ok(patched.rules.includes(`DOMAIN-SUFFIX,openai.com,${userGroup.name}`));
  assert.deepEqual(engine.claudeEasyTransform(structuredClone(patched), 'fixture'), patched);
});
test('branded user group with AI rules is preserved without ownership evidence', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  const userGroup = {
    name: '🤖 AI · ClaudeEasy',
    type: 'select',
    proxies: ['Main', '日本家宽 01'],
    icon: 'https://example.invalid/user-icon.png'
  };
  config['proxy-groups'].push(userGroup);
  config.rules.unshift(
    'DOMAIN-SUFFIX,anthropic.com,🤖 AI · ClaudeEasy',
    'DOMAIN-SUFFIX,openai.com,🤖 AI · ClaudeEasy'
  );
  const first = engine.claudeEasyTransform(config, 'fixture');
  const second = engine.claudeEasyTransform(first, 'fixture');
  assert.deepEqual(first['proxy-groups'].find((group) => group.name === userGroup.name), userGroup);
  assert.deepEqual(second['proxy-groups'].find((group) => group.name === userGroup.name), userGroup);
  assert.equal(first['proxy-groups'].some((group) => group.name === '🤖 AI · ClaudeEasy 2'), false);
  assert.deepEqual(second, first);
});
test('inline proxy names reserve managed group names', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  config.proxies.unshift(
    { name: '🤖 AI · ClaudeEasy', type: 'ss', server: 'ai.example', port: 443 },
    { name: '🛡 安全代理 · ClaudeEasy', type: 'ss', server: 'safe.example', port: 443 }
  );
  const patched = engine.claudeEasyTransform(config, 'fixture');
  assert.ok(patched['proxy-groups'].some((group) => group.name === '🤖 AI · ClaudeEasy 2'));
  assert.equal(patched['proxy-groups'].some((group) => /^🛡 安全代理 · ClaudeEasy(?: \d+)?$/.test(group.name)), false);
});
test('migrates legacy owned AI rules and DNS pattern', { skip: !available }, () => {
  const old = baseConfig();
  old['proxy-groups'] = old['proxy-groups'].filter((group) => group.name !== 'AI');
  const aiGroup = '🤖 AI · ClaudeEasy';
  const safeGroup = '🛡 安全代理 · ClaudeEasy';
  old['proxy-groups'].push({
    name: aiGroup, type: 'select', proxies: ['台湾家宽 01', '日本家宽 01', '美国家宽 01']
  });
  old['proxy-groups'].push({
    name: safeGroup, type: 'select', proxies: ['台湾家宽 01'], 'include-all': true,
    'exclude-type': 'Direct|Dns|Reject|Pass|Compatible|Rematch', 'empty-fallback': 'REJECT'
  });
  old.rules = [`NETWORK,UDP,${safeGroup}`, 'NETWORK,UDP,REJECT']
    .concat(engine.claudeEasyRenderAiRules(aiGroup).map((rule) => rule.replace('160.79.104.0/23', '160.79.104.0/21')),
      [`DOMAIN-SUFFIX,ai.com,${aiGroup}`], old.rules);
  old.dns.nameserver = [`https://dns.alidns.com/dns-query#${safeGroup}`];
  old.dns['nameserver-policy'] = { '+.ai.com': old.dns.nameserver.slice() };
  const patched = engine.claudeEasyTransform(old, 'fixture');
  assert.ok(!patched.rules.includes(`DOMAIN-SUFFIX,ai.com,${aiGroup}`));
  assert.ok(!patched.rules.includes(`IP-CIDR,160.79.104.0/21,${aiGroup},no-resolve`));
  assert.ok(patched.rules.includes(`IP-CIDR,160.79.104.0/23,${aiGroup},no-resolve`));
  assert.equal(Object.prototype.hasOwnProperty.call(patched.dns['nameserver-policy'], '+.ai.com'), false);
});
test('preserves user legacy AI rules and DNS pattern', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'].push({ name: 'Friend', type: 'select', proxies: ['台湾家宽 01'] });
  config.rules.unshift('DOMAIN-SUFFIX,ai.com,Friend', 'IP-CIDR,160.79.104.0/21,Friend,no-resolve');
  config.dns['nameserver-policy']['+.ai.com'] = ['https://1.1.1.1/dns-query#Friend'];
  const patched = engine.claudeEasyTransform(config, 'fixture');
  assert.ok(patched.rules.includes('DOMAIN-SUFFIX,ai.com,Friend'));
  assert.ok(patched.rules.includes('IP-CIDR,160.79.104.0/21,Friend,no-resolve'));
  assert.deepEqual(patched.dns['nameserver-policy']['+.ai.com'], engine.CLAUDE_EASY_POLICY.resolvers.map((resolver) => `${resolver}#Friend`));
});
test('patches config without a rules array', { skip: !available }, () => {
  const config = baseConfig();
  delete config.rules;
  const patched = engine.claudeEasyTransform(config, 'fixture');
  assert.ok(Array.isArray(patched.rules));
  assert.ok(patched.rules.some((rule) => rule.startsWith('DOMAIN-SUFFIX,openai.com,')));
});
test('existing AI group is reused even when many similar names exist', { skip: !available }, () => {
  const config = baseConfig();
  const base = '🤖 AI · ClaudeEasy';
  config['proxy-groups'].push({ name: base, type: 'select', proxies: ['Main'] });
  for (let suffix = 2; suffix <= 9; suffix += 1) {
    config['proxy-groups'].push({ name: `${base} ${suffix}`, type: 'select', proxies: ['Main'] });
  }
  const first = engine.claudeEasyTransform(config, 'fixture');
  const second = engine.claudeEasyTransform(first, 'fixture');
  assert.ok(first.rules.includes('DOMAIN-SUFFIX,openai.com,AI'));
  assert.equal(first['proxy-groups'].some((group) => group.name === `${base} 10`), false);
  assert.deepEqual(second, first);
});
test('rule templates insert selector names literally', { skip: !available }, () => {
  const rules = engine.claudeEasyRenderAiRules('AI $&');
  assert.ok(rules.includes('DOMAIN-SUFFIX,openai.com,AI $&'));
});
test('shared SaaS domains are not routed wholesale through AI', () => {
  const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
  const rules = policy.ai_rules.join('\n');
  for (const domain of ['sentry.io', 'auth0.com', 'segment.io', 'intercom.io', 'js.stripe.com', 'challenges.cloudflare.com', 'ct.sendgrid.net']) {
    assert.ok(!rules.includes(`,${domain},`), domain);
  }
});
test('canonical AI policy excludes unrelated ai.com and uses Anthropic inbound ranges', () => {
  const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
  const rules = policy.ai_rules;
  assert.ok(!rules.includes('DOMAIN-SUFFIX,ai.com,{AI}'));
  assert.ok(rules.includes('IP-CIDR,160.79.104.0/23,{AI},no-resolve'));
  assert.ok(!rules.includes('IP-CIDR,160.79.104.0/21,{AI},no-resolve'));
  assert.ok(rules.includes('IP-CIDR6,2607:6bc0::/48,{AI},no-resolve'));
});
test('all Windows profiles sanitize scalar nameservers and split combined DNS policy keys', () => {
  for (const usageProfile of [1, 2, 3]) {
    const config = baseConfig();
    config.dns.nameserver = 'system';
    config.dns['nameserver-policy'] = {
      'geosite:cn,+.example.com': ['system']
    };
    const patched = engine.claudeEasyTransform(config, 'fixture', usageProfile);
    assert.ok(Array.isArray(patched.dns.nameserver), String(usageProfile));
    assert.equal(Object.hasOwn(patched.dns['nameserver-policy'], 'geosite:cn,+.example.com'), false);
    assert.equal(Object.hasOwn(patched.dns['nameserver-policy'], '+.example.com'), true);
  }
});
test('profile three ignores an array-shaped DNS policy instead of turning indexes into keys', () => {
  const config = baseConfig();
  config.dns['nameserver-policy'] = ['geosite:cn'];
  const patched = engine.claudeEasyTransform(config, 'fixture', 3);
  assert.equal(Object.hasOwn(patched.dns['nameserver-policy'], '0'), false);
});

test('PowerShell scripts never assign to read-only automatic variables', () => {
  const scriptsRoot = path.join(root, 'claude-easy/scripts');
  const pending = [scriptsRoot];
  const powershellFiles = [];
  while (pending.length > 0) {
    const directory = pending.pop();
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) pending.push(entryPath);
      if (entry.isFile() && entry.name.endsWith('.ps1')) powershellFiles.push(entryPath);
    }
  }

  const readonlyName = '(?:(?:global|script|local|private):)?(?:Host|PID|HOME|PSHOME|PSEdition|PSVersionTable|ShellId)';
  const assignment = new RegExp(
    `(?:\\$${readonlyName}\\b|\\$\\{${readonlyName}\\})\\s*(?:=|\\+=|-=|\\*=|\\/=|%=|\\+\\+|--)`,
    'i'
  );
  for (const file of powershellFiles) {
    fs.readFileSync(file, 'utf8').split(/\r?\n/).forEach((line, index) => {
      assert.doesNotMatch(line, assignment, `${path.relative(root, file)}:${index + 1}`);
    });
  }
});

function baseConfig() {
  return {
    proxies: [
      { name: '台湾家宽 01', type: 'ss', server: 'tw.example', password: 'fixture-secret' },
      { name: '日本家宽 01', type: 'ss', server: 'jp.example', password: 'fixture-secret' },
      { name: '美国家宽 01', type: 'ss', server: 'us.example', password: 'fixture-secret' }
    ],
    'proxy-groups': [
      { name: 'Main', type: 'select', proxies: ['台湾家宽 01', '日本家宽 01', '美国家宽 01'] },
      { name: 'AI', type: 'select', proxies: ['Main'] }
    ],
    dns: { enable: true, nameserver: ['223.5.5.5'], 'nameserver-policy': {} },
    rules: [
      'DOMAIN,raw.githubusercontent.com,AI',
      'DOMAIN,storage.googleapis.com,AI',
      'GEOSITE,CN,DIRECT',
      'MATCH,Main'
    ]
  };
}
