const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');
const { isDeepStrictEqual } = require('node:util');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const enginePath = path.join(root, 'claude-easy/scripts/windows/clash_verge_global.js');
const policyPath = path.join(root, 'claude-easy/references/policy.json');
const installerPath = path.join(root, 'claude-easy/scripts/install_windows.ps1');
const uninstallerPath = path.join(root, 'claude-easy/scripts/uninstall_windows.ps1');
const routeVerifierPath = path.join(root, 'claude-easy/scripts/windows/verify_routes.ps1');
const resultContractPath = path.join(root, 'claude-easy/scripts/windows/result_contract.ps1');
const installerModuleDir = path.join(root, 'claude-easy/scripts/windows/install_windows');
const installerModuleNames = [
  'common.ps1', 'yaml.ps1', 'profiles.ps1', 'mihomo.ps1',
  'transaction.ps1', 'script_js.ps1', 'safe_update.ps1'
];
const installerModulePaths = installerModuleNames.map((name) => path.join(installerModuleDir, name));
function readInstallerBundle() {
  return [installerPath, ...installerModulePaths].map((file) => fs.readFileSync(file, 'utf8')).join('\n');
}
const installWrapperPath = path.join(root, 'claude-easy/scripts/install_windows.cmd');
const uninstallWrapperPath = path.join(root, 'claude-easy/scripts/uninstall_windows.cmd');
const windowsInstallerTestPath = path.join(root, 'tests/test_windows_installer.ps1');
const fixturePath = path.join(root, 'tests/fixtures/main_group_cases.json');
const available = fs.existsSync(enginePath) && fs.existsSync(policyPath);
const fixturesAvailable = available && fs.existsSync(fixturePath);
const engine = available ? require(enginePath) : null;

function assertBalancedPowerShellDelimiters(source, displayName) {
  const opening = new Map([['(', ')'], ['[', ']'], ['{', '}']]);
  const closing = new Set(opening.values());
  const stack = [];
  let state = 'code';
  let line = 1;
  let lineStart = 0;

  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1] || '';
    if (character === '\n') {
      line += 1;
      lineStart = index + 1;
      if (state === 'line-comment') state = 'code';
      continue;
    }
    if (state === 'line-comment') continue;
    if (state === 'block-comment') {
      if (character === '#' && next === '>') {
        state = 'code';
        index += 1;
      }
      continue;
    }
    if (state === 'single-quoted') {
      if (character === "'" && next === "'") {
        index += 1;
      } else if (character === "'") {
        state = 'code';
      }
      continue;
    }
    if (state === 'double-quoted') {
      if (character === '`') {
        index += 1;
      } else if (character === '"') {
        state = 'code';
      }
      continue;
    }
    if (state === 'single-here' || state === 'double-here') {
      if (index === lineStart) {
        const lineEnd = source.indexOf('\n', index);
        const currentLine = source.slice(index, lineEnd === -1 ? source.length : lineEnd);
        const terminator = state === 'single-here' ? "'@" : '"@';
        if (currentLine.trimStart().startsWith(terminator)) {
          state = 'code';
          index += currentLine.indexOf(terminator) + 1;
        }
      }
      continue;
    }

    if (character === '#') {
      state = 'line-comment';
      continue;
    }
    if (character === '<' && next === '#') {
      state = 'block-comment';
      index += 1;
      continue;
    }
    if (character === '@' && (next === "'" || next === '"')) {
      const lineEnd = source.indexOf('\n', index);
      const remainder = source.slice(index + 2, lineEnd === -1 ? source.length : lineEnd);
      if (remainder.trim() === '') {
        state = next === "'" ? 'single-here' : 'double-here';
        index += 1;
        continue;
      }
    }
    if (character === "'") {
      state = 'single-quoted';
      continue;
    }
    if (character === '"') {
      state = 'double-quoted';
      continue;
    }
    if (character === '`') {
      index += 1;
      continue;
    }
    if (opening.has(character)) {
      stack.push({ character, line });
      continue;
    }
    if (closing.has(character)) {
      const expected = stack.length > 0 ? opening.get(stack[stack.length - 1].character) : null;
      assert.equal(character, expected, `${displayName}:${line}: unexpected ${character}`);
      stack.pop();
    }
  }
  assert.equal(state, 'code', `${displayName}:${line}: unterminated ${state}`);
  assert.equal(stack.length, 0, `${displayName}:${stack.at(-1)?.line || line}: unclosed ${stack.at(-1)?.character || 'delimiter'}`);
}

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
  assert.deepEqual(ai.proxies, ['Main']);
  const udpIndex = patched.rules.indexOf(`NETWORK,UDP,${ai.name}`);
  assert.ok(udpIndex >= 0);
  assert.equal(patched.rules[udpIndex + 1], 'NETWORK,UDP,REJECT');
  assert.equal(udpIndex, 0);
  assert.ok(patched.rules.includes('DOMAIN,raw.githubusercontent.com,AI'));
  assert.ok(patched.rules.includes('DOMAIN,storage.googleapis.com,AI'));
});

test('lightweight profiles receive the common China-domain baseline only', { skip: !available }, () => {
  for (const usageProfile of [1, 2]) {
    const input = baseConfig();
    input.ipv6 = true;
    input.tun = { enable: false };
    const patched = engine.claudeEasyTransform(input, 'fixture', usageProfile);
    const providerName = engine.CLAUDE_EASY_POLICY.cnDomainProvider.name;
    const provider = patched['rule-providers'][providerName];

    assert.equal(provider.type, 'http');
    assert.equal(provider.behavior, 'domain');
    assert.equal(provider.format, 'mrs');
    assert.equal(provider.url, engine.CLAUDE_EASY_POLICY.cnDomainProvider.url);
    assert.equal(provider.proxy, 'Main');
    assert.deepEqual(patched.dns['nameserver-policy'][`rule-set:${providerName}`], engine.CLAUDE_EASY_POLICY.directResolvers);
    assert.ok(patched.rules.indexOf(`RULE-SET,${providerName},DIRECT`) < patched.rules.indexOf('GEOSITE,CN,DIRECT'));
    assert.equal(patched.ipv6, true);
    assert.deepEqual(patched.tun, { enable: false });
    assert.equal(patched.rules.some((rule) => rule.startsWith('NETWORK,UDP,')), false);
    assert.deepEqual(engine.claudeEasyTransform(patched, 'fixture', usageProfile), patched);
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

test('reuses the existing AI group without creating visible groups', { skip: !available }, () => {
  const config = baseConfig();
  const originalAi = structuredClone(config['proxy-groups'].find((group) => group.name === 'AI'));

  const patched = engine.claudeEasyTransform(config, 'fixture');

  assert.deepEqual(patched['proxy-groups'].find((group) => group.name === 'AI'), originalAi);
  assert.equal(patched['proxy-groups'].some((group) => /^🤖 AI · ClaudeEasy(?: \d+)?$/.test(group.name)), false);
  assert.equal(patched['proxy-groups'].some((group) => /^🛡 安全代理 · ClaudeEasy(?: \d+)?$/.test(group.name)), false);
  assert.ok(patched.rules.includes('DOMAIN-SUFFIX,openai.com,AI'));
  assert.deepEqual(patched.rules.slice(0, 2), ['NETWORK,UDP,AI', 'NETWORK,UDP,REJECT']);
  assert.ok(patched.dns.nameserver.every((value) => value.endsWith('#Main')));
  assert.ok(patched.dns['nameserver-policy']['+.openai.com'].every((value) => value.endsWith('#AI')));
});

test('creates an AI group with all inline nodes when the subscription has none', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');

  const patched = engine.claudeEasyTransform(config, 'fixture');

  const ai = patched['proxy-groups'].find((group) => group.name === '🤖 AI · ClaudeEasy');
  assert.deepEqual(ai.proxies, ['台湾家宽 01', '日本家宽 01', '美国家宽 01']);
  assert.equal(Object.hasOwn(ai, 'use'), false);
  assert.equal(patched['proxy-groups'].some((group) => /^🛡 安全代理 · ClaudeEasy(?: \d+)?$/.test(group.name)), false);
  assert.ok(patched.rules.includes('DOMAIN-SUFFIX,openai.com,🤖 AI · ClaudeEasy'));
  assert.deepEqual(patched.rules.slice(0, 2), ['NETWORK,UDP,🤖 AI · ClaudeEasy', 'NETWORK,UDP,REJECT']);
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

test('migrates owned single-main AI group to an independent node selector', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'] = config['proxy-groups'].filter((group) => group.name !== 'AI');
  const aiName = '🤖 AI · ClaudeEasy';
  config['proxy-groups'].push({ name: aiName, type: 'select', proxies: ['Main'] });
  config.rules = engine.claudeEasyRenderAiRules(aiName).concat(config.rules);

  const patched = engine.claudeEasyTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === aiName);

  assert.deepEqual(ai.proxies, ['台湾家宽 01', '日本家宽 01', '美国家宽 01']);
  assert.equal(ai.proxies.includes('Main'), false);
});

test('removes groups created by an older patch', { skip: !available }, () => {
  const config = baseConfig();
  const aiName = '🤖 AI · ClaudeEasy';
  const safeName = '🛡 安全代理 · ClaudeEasy';
  config['proxy-groups'].push({ name: aiName, type: 'select', proxies: ['台湾家宽 01'] });
  config['proxy-groups'].push({
    name: safeName, type: 'select', proxies: ['台湾家宽 01', '日本家宽 01'],
    'include-all': true, 'exclude-type': 'Direct|Dns|Reject|Pass|Compatible|Rematch', 'empty-fallback': 'REJECT'
  });
  config.dns.nameserver = [`https://dns.alidns.com/dns-query#${safeName}`];
  config.dns['nameserver-policy'] = { '+.openai.com': [`https://dns.alidns.com/dns-query#${safeName}`] };
  config.rules = [`NETWORK,UDP,${safeName}`, 'NETWORK,UDP,REJECT']
    .concat(engine.claudeEasyRenderAiRules(aiName), config.rules);

  const patched = engine.claudeEasyTransform(config, 'fixture');

  assert.equal(patched['proxy-groups'].some((group) => group.name === aiName || group.name === safeName), false);
  assert.equal(patched.rules.some((rule) => rule.includes(aiName) || rule.includes(safeName)), false);
  assert.equal(JSON.stringify(patched.dns).includes(safeName), false);
  assert.deepEqual(patched.rules.slice(0, 2), ['NETWORK,UDP,AI', 'NETWORK,UDP,REJECT']);
});

test('preserves bootstrap and replaces direct resolvers with managed mainland DoH', { skip: !available }, () => {
  const config = baseConfig();
  config.dns['default-nameserver'] = ['223.5.5.5', '119.29.29.29'];
  config.dns['proxy-server-nameserver'] = ['223.5.5.5', '120.53.53.53'];
  config.dns['direct-nameserver'] = ['system'];

  const dns = engine.claudeEasyTransform(config, 'fixture').dns;

  assert.deepEqual(dns['default-nameserver'], ['223.5.5.5', '119.29.29.29']);
  assert.deepEqual(dns['proxy-server-nameserver'], ['223.5.5.5', '120.53.53.53']);
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
  assert.deepEqual(patched.dns['proxy-server-nameserver'], ['223.5.5.5', '120.53.53.53']);
});

test('uses system only when proxy bootstrap is missing', { skip: !available }, () => {
  const dns = engine.claudeEasyTransform(baseConfig(), 'fixture').dns;

  assert.equal(Object.hasOwn(dns, 'default-nameserver'), false);
  assert.deepEqual(dns['proxy-server-nameserver'], ['system']);
  assert.deepEqual(dns['direct-nameserver'], engine.CLAUDE_EASY_POLICY.directResolvers);
  assert.equal(dns['direct-nameserver-follow-policy'], false);
});

test('migrates the old unsafe bootstrap signature to system', { skip: !available }, () => {
  const config = baseConfig();
  config.dns['default-nameserver'] = ['1.1.1.1', '8.8.8.8'];
  config.dns['proxy-server-nameserver'] = ['https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query'];

  const dns = engine.claudeEasyTransform(config, 'fixture').dns;

  assert.deepEqual(dns['default-nameserver'], ['system']);
  assert.deepEqual(dns['proxy-server-nameserver'], ['system']);
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

  assert.match(source, /function claudeEasyApply/);
  assert.match(source, /const secondPass = claudeEasyApply\(claudeEasyClone\(candidate\)/);
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

test('does not select Japan home broadband automatically', { skip: !available }, () => {
  const config = baseConfig();
  config.proxies = config.proxies.filter((proxy) => !proxy.name.includes('台湾'));
  config['proxy-groups'][0].proxies = config['proxy-groups'][0].proxies.filter((name) => !name.includes('台湾'));
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const ai = patched['proxy-groups'].find((group) => group.name === 'AI');
  assert.deepEqual(ai.proxies, ['Main']);
});

test('puts the UDP guard ahead of a narrow rule set', { skip: !available }, () => {
  const config = baseConfig();
  config.rules.splice(2, 0, 'RULE-SET,private-special,DIRECT');
  const rules = engine.claudeEasyTransform(config, 'fixture').rules;
  const udpIndex = rules.findIndex((rule) => rule.startsWith('NETWORK,UDP,') && rule !== 'NETWORK,UDP,REJECT');
  assert.equal(udpIndex, 0);
  assert.equal(rules[udpIndex + 1], 'NETWORK,UDP,REJECT');
  assert.ok(udpIndex < rules.indexOf('GEOSITE,CN,DIRECT'));
  assert.ok(udpIndex < rules.indexOf('RULE-SET,private-special,DIRECT'));
});

test('preserves a user AI target ahead of the managed rule', { skip: !available }, () => {
  const config = baseConfig();
  config['proxy-groups'].push({ name: 'MyGroup', type: 'select', proxies: ['台湾家宽 01'] });
  const userRule = 'DOMAIN-SUFFIX,openai.com,MyGroup';
  config.rules.unshift(userRule);
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const managed = 'DOMAIN-SUFFIX,openai.com,AI';
  assert.equal(patched.rules.filter((rule) => rule === userRule).length, 1);
  assert.ok(patched.rules.indexOf(userRule) < patched.rules.indexOf(managed));
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
  assert.equal(patched.rules.indexOf(guard), 0);
  assert.equal(patched.rules[1], 'NETWORK,UDP,REJECT');
  for (const rule of userRules) {
    assert.ok(patched.rules.includes(rule), rule);
    assert.ok(patched.rules.indexOf(guard) < patched.rules.indexOf(rule), rule);
  }
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

test('unknown policy version is rejected without mutation', { skip: !available }, () => {
  const config = baseConfig();
  const snapshot = JSON.parse(JSON.stringify(config));
  const originalVersion = engine.CLAUDE_EASY_POLICY.version;
  try {
    engine.CLAUDE_EASY_POLICY.version = 2;
    assert.deepEqual(engine.claudeEasyTransform(config, 'fixture'), config);
    assert.deepEqual(config, snapshot);
  } finally {
    engine.CLAUDE_EASY_POLICY.version = originalVersion;
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
    const serialized = JSON.stringify(patched);
    assert.equal(crypto.createHash('sha256').update(serialized).digest('hex'), fixture.expected_config_sha256, `${fixture.name}: output drift`);
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

test('PowerShell installer uses the documented global script and app settings', () => {
  assert.equal(fs.existsSync(installerPath), true, 'Windows installer is missing');
  const source = readInstallerBundle();
  assert.match(source, /io\.github\.clash-verge-rev\.clash-verge-rev/);
  assert.match(source, /profiles[\\/]Script\.js/);
  assert.match(source, /enable_tun_mode/);
  assert.match(source, /enable_dns_settings/);
  assert.match(source, /config\.yaml/);
  assert.match(source, /\.backup/);
  assert.match(source, /[\p{Script=Han}]/u);
  assert.match(source, /function Build-GlobalScript/);
  assert.match(source, /function Write-Utf8Atomic/);
  const preflight = source.indexOf('$scriptOutput = Build-GlobalScript');
  const firstBackup = source.indexOf('Backup-Versioned $target.Path $backupRoot "prewrite"');
  assert.ok(preflight !== -1 && firstBackup !== -1 && preflight < firstBackup, 'all transformations must be prepared before files change');
});

test('PowerShell safe update checks installed script and proxy-group prerequisites before acceptance', () => {
  const installer = fs.readFileSync(installerPath, 'utf8');
  const safeUpdateModule = fs.readFileSync(path.join(installerModuleDir, 'safe_update.ps1'), 'utf8');
  const scriptCheck = installer.indexOf(
    'Assert-ClaudeEasyManagedScriptCurrent $scriptText $savedProfile $enginePath $targetScript'
  );
  const profileCheck = installer.indexOf(
    'Assert-ClaudeEasyProxyGroupCollection $text ([string]$item.File)'
  );
  const mihomoCheck = installer.indexOf('Test-MihomoCandidate $core $text $profilesDirectory');
  const manifestRemoval = installer.indexOf(
    'Remove-VerifiedOwnedFile $safeUpdateStatePath $manifestSnapshot.Bytes $manifestSnapshot.Identity'
  );
  assert.ok(scriptCheck >= 0, 'safe update does not validate the installed global script');
  assert.ok(profileCheck > scriptCheck, 'proxy-group prerequisites are not checked after the installed script');
  assert.ok(mihomoCheck > profileCheck, 'Mihomo validation does not run after proxy-group checks');
  assert.ok(manifestRemoval > mihomoCheck, 'safe-update manifest is removed before validation finishes');
  assert.match(
    safeUpdateModule,
    /\$flowLines \+= @\(\$lines\[\(\$groupsNode\.Start \+ 1\)\.\.\(\$lines\.Count - 1\)\]\)/,
    'multi-line flow sequences stop before their top-level closing bracket'
  );
});

test('PowerShell 5.1 keeps a single remote subscription path as an array', () => {
  const profilesModule = fs.readFileSync(path.join(installerModuleDir, 'profiles.ps1'), 'utf8');

  assert.match(profilesModule, /\$matches\s*=\s*@\(\$candidates\s*\|\s*Where-Object/);
  assert.match(profilesModule, /Resolve-Path\s+-LiteralPath\s+\$matches\[0\]/);
});

// Static contract only: pwsh is unavailable on macOS, so exit codes cannot be
// executed natively here. Verify on Windows before relying on them.
test('PowerShell installer keeps exit codes by avoiding Write-Error', () => {
  const source = fs.readFileSync(installerPath, 'utf8');
  assert.doesNotMatch(source, /\bWrite-Error\b/, 'Write-Error becomes terminating under $ErrorActionPreference = "Stop"');
  assert.match(source, /\[Console\]::Error\.WriteLine/);
  for (const code of ['exit 0', 'exit 1', 'exit 2', 'exit 3']) {
    assert.ok(source.includes(code), `missing ${code}`);
  }
  const notFound = source.indexOf('没有找到受支持的 Clash Verge Rev');
  assert.ok(notFound !== -1 && source.indexOf('exit 2') > notFound, 'missing client must exit 2');
  const missingEngine = source.indexOf('安装包不完整');
  assert.ok(missingEngine !== -1 && source.indexOf('exit 3') > missingEngine, 'missing engine must exit 3');
  const failure = source.indexOf('安装失败');
  assert.ok(failure !== -1 && source.lastIndexOf('exit 1') > failure, 'install failure must exit 1');
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
    '+.interface.example': ['https://1.1.1.1/dns-query#en0']
  };
  const patched = engine.claudeEasyTransform(config, 'fixture');
  const policy = patched.dns['nameserver-policy'];
  assert.deepEqual(policy['+.proxy.example'], engine.CLAUDE_EASY_POLICY.resolvers.map((resolver) => `${resolver}#台湾家宽 01`));
  assert.deepEqual(policy['+.group.example'], engine.CLAUDE_EASY_POLICY.resolvers.map((resolver) => `${resolver}#SafeExisting`));
  for (const pattern of ['+.direct.example', '+.option.example', '+.interface.example']) {
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

test('DNS policy accounts for exclusion, empty fallback, and DNS outbounds', { skip: !available }, () => {
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
  assert.deepEqual(policies['+.fallback.example'], engine.CLAUDE_EASY_POLICY.resolvers.map((resolver) => `${resolver}#FilteredToSafeProxy`));
  assert.ok(policies['+.dns-out.example'].every((endpoint) => endpoint.endsWith(safeSuffix)));
  assert.deepEqual(mainGroup, originalMain);
});

test('DNS policy rejects unsafe group filters and honors case-insensitive exclusions', { skip: !available }, () => {
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
  assert.deepEqual(
    patched.dns['nameserver-policy']['+.case-filtered.example'],
    engine.CLAUDE_EASY_POLICY.resolvers.map((resolver) => `${resolver}#CaseFiltered`)
  );
  assert.ok(patched.dns['nameserver-policy']['+.invalid-filter.example'].every((endpoint) => {
    return endpoint.endsWith(`#${routeGroup}`);
  }));
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
    '+.ecs.example': [`https://1.1.1.1/dns-query#${target}&ecs=203.0.113.0/24&ecs-override=true`]
  };

  const patched = engine.claudeEasyTransform(config, 'fixture');
  const policies = patched.dns['nameserver-policy'];
  const safeSuffix = `#${engine.claudeEasyRouteGroupName(patched)}`;
  assert.deepEqual(policies['+.h3.example'], engine.CLAUDE_EASY_POLICY.resolvers.map((resolver) => `${resolver}#${target}&h3=true`));
  for (const pattern of ['+.skip-cert.example', '+.ecs.example']) {
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

test('user-owned branded select group is preserved', { skip: !available }, () => {
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

test('branded user group with AI rules is not mistaken for patch ownership', { skip: !available }, () => {
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
  old['proxy-groups'].push({ name: aiGroup, type: 'select', proxies: ['台湾家宽 01'] });
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

test('PowerShell installer structurally edits YAML and rolls back failed transactions', () => {
  const source = readInstallerBundle();
  assert.match(source, /function Find-YamlMappingNode/);
  assert.match(source, /function Set-YamlTopLevelScalar/);
  assert.match(source, /function Set-YamlTunMapping/);
  assert.match(source, /function Test-GeneratedYaml/);
  assert.match(source, /function Invoke-VerifiedPathTransaction/);
  assert.match(source, /function Get-RedactedYamlChangedPaths/);
  assert.match(source, /ChangedFields/);
  assert.match(source, /Assert-RemoteSubscriptionAutoUpdateDisabled \$output \| Out-Null/);
  assert.match(source, /ComputeHash\(\$[Bb]ytes,\s*0,\s*\$[Bb]ytes\.Length\)/);
  assert.doesNotMatch(source, /ComputeHash\(\$[Bb]ytes\)/);
  assert.doesNotMatch(source, /function Set-TunBlock/);
});

test('Windows recovery fault injection matches the current write boundary', () => {
  const fixture = fs.readFileSync(windowsInstallerTestPath, 'utf8').replace(/\r\n/g, '\n');
  const transaction = fs.readFileSync(
    path.join(installerModuleDir, 'transaction.ps1'),
    'utf8'
  ).replace(/\r\n/g, '\n');
  const match = fixture.match(
    /\$publicUninstallRecoveryNeedle = @'\n([\s\S]*?)\n'@/
  );
  assert.ok(match, 'public uninstall recovery fixture omitted its literal boundary');
  const boundary = match[1];
  assert.equal(
    transaction.split(boundary).length - 1,
    1,
    'public uninstall recovery fixture boundary must match transaction.ps1 exactly once'
  );
});

test('Windows installation fails closed and preserves exact restore state', () => {
  const installer = readInstallerBundle();
  const uninstaller = fs.readFileSync(uninstallerPath, 'utf8');
  assert.match(installer, /\[string\]\$MihomoPath/);
  assert.match(installer, /function Test-MihomoVersion/);
  assert.match(installer, /Mihomo 1\.19\.27/);
  assert.match(installer, /Join-Path \(Join-Path \$env:LOCALAPPDATA "Clash Verge"\) "verge-mihomo\.exe"/);
  assert.match(installer, /function Test-ClashVergeRunning/);
  assert.match(installer, /if \(\$clientRunning\)[\s\S]*client_running_profile_three_deferred[\s\S]*client_running_auto_update_deferred/);
  assert.doesNotMatch(installer, /installed_running_client/);
  assert.match(installer, /WaitForExit\(\$TimeoutSeconds \* 1000\)/);
  assert.match(installer, /\$process\.Kill\(\)/);
  assert.doesNotMatch(installer, /Get-Process -Name "verge-mihomo"/);
  assert.match(installer, /function Write-BytesAtomic/);
  assert.match(installer, /function Set-RemoteSubscriptionAutoUpdateDisabled/);
  assert.match(installer, /function Assert-RemoteSubscriptionAutoUpdateDisabled/);
  assert.match(installer, /Assert-RemoteSubscriptionAutoUpdateDisabled \$indexText \| Out-Null/);
  assert.doesNotMatch(installer, /if \(\$savedProfile -eq 3\) \{ Assert-RemoteSubscriptionAutoUpdateDisabled/);
  assert.match(installer, /allow_auto_update/);
  assert.match(installer, /profiles\.yaml/);
  assert.match(installer, /OriginalBytes/);
  assert.match(installer, /install-state\.json/);
  assert.match(installer, /SetAccessRuleProtection/);
  assert.match(installer, /async\\s\+function\\s\+main/);
  assert.match(installer, /不会等待异步 main/);
  assert.match(uninstaller, /InstalledSha256/);
  assert.match(uninstaller, /function New-UninstallBackup/);
  assert.match(uninstaller, /Backup-Versioned \$Path \$backupRoot "pre-uninstall"/);
  assert.equal(fs.existsSync(installWrapperPath), true);
  assert.equal(fs.existsSync(uninstallWrapperPath), true);
  assert.match(fs.readFileSync(installWrapperPath, 'utf8'), /-ExecutionPolicy Bypass/);
  assert.match(fs.readFileSync(uninstallWrapperPath, 'utf8'), /-ExecutionPolicy Bypass/);
});

test('Windows installer is split into side-effect-free modules with stable function ownership', () => {
  const entry = fs.readFileSync(installerPath, 'utf8');
  const expected = {
    'common.ps1': ['Write-Info', 'Complete-InstallResult', 'Get-SavedUsageProfile', 'Save-UsageProfile'],
    'transaction.ps1': [
      'Protect-BackupAcl', 'ConvertTo-NormalizedWindowsPath', 'Resolve-ClashVergeAppHome',
      'Get-AppHomeRelativePath',
      'Enter-AppHomeMutationLock', 'Exit-AppHomeMutationLock',
      'Get-PathKey', 'Assert-NoReparsePointPath', 'Backup-Versioned', 'Backup-InitialOnce', 'Write-BytesAtomic',
      'ConvertTo-Utf8Bytes', 'Write-Utf8Atomic', 'Get-BytesSha256', 'Get-FileSha256',
      'Get-StreamBytes', 'Get-OptionalFileSnapshot', 'Remove-VerifiedOwnedFile', 'Write-LockedStreamBytes',
      'Initialize-VerifiedFileNative', 'Open-VerifiedDirectoryChain', 'Set-VerifiedDeleteDisposition',
      'Write-FileTransactionPreparation', 'Get-ValidatedFileTransactionPaths',
      'Get-InterruptedRecoveryPolicy', 'Get-ValidatedFileTransactionPreparation',
      'Get-ValidatedFileTransactionPreparationTargets', 'Remove-FileTransactionPreparation',
      'Test-SafeUpdateRunningRecoveryTargets', 'Test-InterruptedRecoveryRequiresStoppedClient',
      'Test-InterruptedRecoveryCommitCondition', 'Repair-InterruptedFilePreparation',
      'Write-FileTransactionJournal', 'Remove-FileTransactionJournal',
      'Get-ValidatedFileTransactionJournal', 'Get-InterruptedTransactionRecoveryPlan',
      'New-InterruptedRecoveryTemporaryFile', 'Remove-InterruptedRecoveryTemporaryFile',
      'Invoke-InterruptedTransactionRecovery', 'Assert-InterruptedTransactionRecovered',
      'Repair-InterruptedFileTransaction', 'Invoke-VerifiedPathTransaction',
      'Invoke-VerifiedFileTransaction', 'Invoke-VerifiedWriteDeleteTransaction',
      'Get-InstallStateEntry', 'Assert-InstallStateEntry', 'Assert-InstallState', 'Assert-StateSnapshotUnchanged',
      'New-InstallStateEntry'
    ],
    'yaml.ps1': [
      'Split-YamlLines', 'Join-YamlLines', 'Get-YamlIndent', 'Get-YamlMappingEntry', 'Get-YamlPathFingerprints',
      'Get-RedactedYamlChangedPaths', 'Find-YamlMappingNode', 'Replace-YamlRange', 'Set-YamlTopLevelScalar',
      'Get-ManagedTunLines', 'New-ManagedTunBlock', 'Set-YamlTunMapping', 'Test-GeneratedYaml'
    ],
    'profiles.ps1': [
      'Get-RemoteSubscriptionProfileItems', 'Get-RemoteSubscriptionAutoUpdateStateRecords',
      'Get-RemoteSubscriptionAutoUpdateOwnership', 'Restore-RemoteSubscriptionAutoUpdate',
      'Assert-RemoteSubscriptionAutoUpdateOwnershipState', 'Merge-RemoteSubscriptionAutoUpdateOwnership',
      'Get-RemoteSubscriptionTargets',
      'Set-RemoteSubscriptionAutoUpdateDisabled', 'Assert-RemoteSubscriptionAutoUpdateDisabled'
    ],
    'mihomo.ps1': [
      'ConvertTo-NativeArgument', 'Invoke-Mihomo', 'Test-ClashVergeRunning', 'Test-MihomoVersionText',
      'Test-MihomoVersion', 'Find-MihomoCore', 'Start-MihomoCandidateCleanupWatcher',
      'Test-MihomoCandidate'
    ],
    'script_js.ps1': [
      'Get-JavaScriptAnalysis', 'Rename-JavaScriptMain', 'Assert-JavaScriptReservedIdentifiers',
      'Assert-JavaScriptDoesNotUseDynamicCode',
      'Assert-JavaScriptDoesNotBindMain', 'Assert-JavaScriptDoesNotReferenceMain',
      'Assert-JavaScriptCanCompose', 'Build-GlobalScript'
    ],
    'safe_update.ps1': [
      'Get-BackupTarget', 'Get-ClaudeEasyManagedScriptBlock', 'Get-ClaudeEasyManagedScriptEnvelope',
      'Assert-ClaudeEasyScriptOutsideManagedBlockIsPassive',
      'Assert-ClaudeEasyManagedScriptCurrent',
      'Test-ClaudeEasyFlowSequenceHasItem', 'Assert-ClaudeEasyProxyGroupCollection', 'Test-RestoreCandidate',
      'Test-SafeUpdateRefreshEvidence',
      'Open-SafeUpdateVersionGuard', 'New-SafeUpdateSnapshotContext',
      'Get-SafeUpdateRecoveryItems', 'Get-SafeUpdateVerificationTargets', 'Restore-SafeUpdateFiles'
    ]
  };

  assert.doesNotMatch(entry, /^function\s+/m, 'entry point still contains library functions');
  let previousLoad = -1;
  const seen = new Set();
  for (const [index, moduleName] of installerModuleNames.entries()) {
    const modulePath = installerModulePaths[index];
    assert.equal(fs.existsSync(modulePath), true, moduleName);
    const source = fs.readFileSync(modulePath, 'utf8');
    const names = [...source.matchAll(/^\uFEFF?function\s+([A-Za-z0-9-]+)/gm)].map((match) => match[1]);
    assert.deepEqual(names, expected[moduleName], moduleName);
    for (const name of names) {
      assert.equal(seen.has(name), false, `duplicate function ${name}`);
      seen.add(name);
    }
    const load = entry.indexOf(`"${moduleName}"`);
    assert.ok(load > previousLoad, `module load order: ${moduleName}`);
    previousLoad = load;
  }
  assert.ok(previousLoad < entry.indexOf('if ([string]::IsNullOrWhiteSpace($AppHome))'), 'modules load after execution began');
});

test('Windows engine contains no unused rule-identity helper', () => {
  const source = fs.readFileSync(enginePath, 'utf8');
  assert.doesNotMatch(source, /function claudeEasyRuleIdentity/);
});

test('all shipped and test PowerShell scripts are strict UTF-8 with a BOM', () => {
  const pending = [path.join(root, 'claude-easy/scripts')];
  const powershellFiles = [path.join(root, 'tests/test_windows_installer.ps1')];
  while (pending.length > 0) {
    const directory = pending.pop();
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) pending.push(entryPath);
      if (entry.isFile() && entry.name.endsWith('.ps1')) powershellFiles.push(entryPath);
    }
  }

  const decoder = new TextDecoder('utf-8', { fatal: true });
  for (const entry of powershellFiles) {
    const bytes = fs.readFileSync(entry);
    assert.deepEqual([...bytes.subarray(0, 3)], [0xef, 0xbb, 0xbf], entry);
    assert.doesNotThrow(() => decoder.decode(bytes), entry);
  }
});

test('PowerShell files have balanced syntax delimiters before Windows CI', () => {
  assert.doesNotThrow(() => assertBalancedPowerShellDelimiters(
    "function Test-Example {`n  @(')', ']') | ForEach-Object { $_ }`n}`n",
    'balanced-fixture'
  ));
  assert.throws(() => assertBalancedPowerShellDelimiters(
    'function Test-Broken { return (@(1, 2)) -join "`n") }',
    'broken-fixture'
  ));

  const pending = [path.join(root, 'claude-easy/scripts')];
  const powershellFiles = [path.join(root, 'tests/test_windows_installer.ps1')];
  while (pending.length > 0) {
    const directory = pending.pop();
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) pending.push(entryPath);
      if (entry.isFile() && entry.name.endsWith('.ps1')) powershellFiles.push(entryPath);
    }
  }
  for (const entry of powershellFiles) {
    assertBalancedPowerShellDelimiters(fs.readFileSync(entry, 'utf8'), path.relative(root, entry));
  }
});

test('Windows public commands share the JSON v1 result contract', () => {
  const contract = fs.readFileSync(resultContractPath, 'utf8');
  assert.match(contract, /\$script:ClaudeEasyResultSchema = "claude-easy\.result"/);
  assert.match(contract, /\$script:ClaudeEasyResultVersion = 1/);
  assert.match(contract, /function New-ClaudeEasyResult/);
  assert.match(contract, /function Write-ClaudeEasyResult/);
  assert.match(contract, /function Protect-ClaudeEasyResultValue/);
  assert.match(contract, /ConvertTo-Json -Depth/);

  for (const entry of [installerPath, uninstallerPath, routeVerifierPath]) {
    const source = entry === installerPath ? readInstallerBundle() : fs.readFileSync(entry, 'utf8');
    assert.match(source, /\[switch\]\$Json/, entry);
    assert.match(source, /result_contract\.ps1/, entry);
    assert.match(source, /Write-ClaudeEasyResult/, entry);
  }

  assert.match(fs.readFileSync(path.join(installerModuleDir, 'common.ps1'), 'utf8'), /-Command "install"/);
  assert.match(fs.readFileSync(uninstallerPath, 'utf8'), /-Command "uninstall"/);
  assert.match(fs.readFileSync(routeVerifierPath, 'utf8'), /-Command "verify_routes"/);
});

test('Windows route verifier accepts an explicit non-AI Google proxy group', () => {
  const source = fs.readFileSync(routeVerifierPath, 'utf8');

  assert.match(source, /function Test-RouteChains/);
  assert.match(source, /Observe-Route "Google"[^\r\n]+\$true/);
  assert.match(source, /Observe-Route "OpenAI"[^\r\n]+\$false/);
  assert.match(source, /\(\?\i\)\(\^\|\\\.\)google\\\.com\$/);
  assert.doesNotMatch(source, /Observe-Route "Google"[^\r\n]+"google"/);
});

test('Windows route verifier keeps PowerShell 5 route arrays and empty selections safe', () => {
  const source = fs.readFileSync(routeVerifierPath, 'utf8');

  assert.match(source, /\[Uri\]\$parsed = \$null/);
  assert.match(source, /\$chainItems = @\(\$Chains\)/);
  assert.match(source, /\$providerChainItems = @\(\$ProviderChains\)/);
  assert.match(source, /\$connection\.PSObject\.Properties\["providerChains"\]/);
  assert.match(
    source,
    /\[string\]::IsNullOrWhiteSpace\(\$ExpectedSelection\)[\s\S]*?\$expectedType -ne "LoadBalance"/
  );
});

test('Windows route verifier removes a PowerShell 5 stdin BOM before using the secret', () => {
  const source = fs.readFileSync(routeVerifierPath, 'utf8');

  assert.match(source, /\$value\[0\] -eq \[char\]0xFEFF/);
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
