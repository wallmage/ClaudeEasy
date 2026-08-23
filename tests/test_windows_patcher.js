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
