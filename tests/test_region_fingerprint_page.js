const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const ROOT = path.resolve(__dirname, "..");
const PAGE = path.join(
  ROOT,
  "claude-easy",
  "assets",
  "claude-region-check.html",
);

function pageSource() {
  return fs.readFileSync(PAGE, "utf8");
}

function scriptSource(id) {
  const source = pageSource();
  const match = source.match(new RegExp(
    `<script id="${id}">([\\s\\S]*?)<\\/script>`,
  ));
  assert.ok(match, `the page must expose the ${id} inline script`);
  return match[1];
}

function detectorApi() {
  const context = vm.createContext({ window: {} });
  vm.runInContext(scriptSource("claude-easy-region-core"), context, {
    filename: "claude-region-check-core.js",
  });
  return context.window.ClaudeEasyRegionCheck;
}

class FakeElement {
  constructor() {
    this.attributes = new Map();
    this.children = [];
    this.listeners = new Map();
    this.disabled = false;
    this.hidden = false;
    this._textContent = "";
  }

  set textContent(value) {
    this._textContent = String(value);
    this.children = [];
  }

  get textContent() {
    return this._textContent;
  }

  appendChild(child) {
    this.children.push(child);
    return child;
  }

  setAttribute(name, value) {
    this.attributes.set(name, String(value));
  }

  removeAttribute(name) {
    this.attributes.delete(name);
  }

  addEventListener(name, listener) {
    this.listeners.set(name, listener);
  }

  click() {
    return this.listeners.get("click")();
  }

  querySelector(selector) {
    const attribute = selector.match(/^\[([^=\]]+)(?:="([^"]*)")?\]$/);
    assert.ok(attribute, `unsupported fake selector: ${selector}`);
    const [, name, value] = attribute;
    const stack = [...this.children];
    while (stack.length > 0) {
      const candidate = stack.shift();
      if (candidate.attributes.has(name) &&
          (value === undefined || candidate.attributes.get(name) === value)) {
        return candidate;
      }
      stack.push(...candidate.children);
    }
    return null;
  }
}

function uiHarness(detector) {
  const elements = {
    list: new FakeElement(),
    start: new FakeElement(),
    rescan: new FakeElement(),
    score: new FakeElement(),
    band: new FakeElement(),
    status: new FakeElement(),
  };
  elements.rescan.hidden = true;
  const selectors = new Map([
    ["[data-signal-list]", elements.list],
    ['[data-action="start"]', elements.start],
    ['[data-action="rescan"]', elements.rescan],
    ["[data-result-score]", elements.score],
    ["[data-result-band]", elements.band],
    ["[data-result-status]", elements.status],
  ]);
  const context = vm.createContext({
    window: { ClaudeEasyRegionCheck: detector },
    document: {
      createElement: () => new FakeElement(),
      querySelector: (selector) => selectors.get(selector),
    },
  });
  vm.runInContext(scriptSource("claude-easy-region-ui"), context, {
    filename: "claude-region-check-ui.js",
  });
  return elements;
}

function baseEnvironment(overrides = {}) {
  return {
    timeZone: "Asia/Taipei",
    timezoneOffset: -480,
    languages: ["zh-TW", "zh", "en-US"],
    intlLocale: "zh-TW",
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15",
    platform: "MacIntel",
    userAgentData: undefined,
    hasFont: (font) => font === "PingFang TC",
    ...overrides,
  };
}

test("the detector is one self-contained offline HTML file", () => {
  const source = pageSource();
  const executableSource = source.replace(/<!--[\s\S]*?-->/g, "");

  assert.match(source, /data-contract-version="1"/);
  assert.match(source, /data-action="start"/);
  assert.match(source, /data-action="rescan"/);
  assert.match(
    source,
    /Copyright \(c\) 2026 LinXiaoTao \(https:\/\/github\.com\/LinXiaoTao\/FuckClaude\)/,
  );
  assert.match(source, /MIT License/);
  assert.doesNotMatch(source, /\b(?:src|href)\s*=/i);
  assert.doesNotMatch(executableSource, /https?:\/\//i);
  assert.doesNotMatch(
    source,
    /\b(?:fetch|XMLHttpRequest|WebSocket|EventSource|sendBeacon|serviceWorker)\b/,
  );
  assert.doesNotMatch(source, /\bimport\s*\(/);
  assert.doesNotMatch(source, /\b(?:analytics|adsense|googletagmanager)\b/i);
  assert.doesNotMatch(source, /(?:@import|\burl\s*\()/i);
  assert.doesNotMatch(
    source,
    /<(?:iframe|object|embed|form|link|img|video|audio|source)\b/i,
  );
  assert.doesNotMatch(
    source,
    /\b(?:window\.open|document\.write|location\s*=)/i,
  );
});

test("the public contract exposes exactly nine weighted signals totaling 100", () => {
  const api = detectorApi();
  const ids = Array.from(api.signals, (signal) => signal.id);
  const weights = Object.fromEntries(
    Array.from(api.signals, (signal) => [signal.id, signal.weight]),
  );
  const totalWeight = Array.from(api.signals).reduce(
    (total, signal) => total + signal.weight,
    0,
  );

  assert.deepEqual(
    ids,
    [
      "timezone",
      "language",
      "fonts",
      "vendorFonts",
      "cnBrowser",
      "deviceVendor",
      "intlLocale",
      "timezoneOffset",
      "emoji",
    ],
  );
  assert.equal(new Set(ids).size, 9);
  assert.deepEqual(weights, {
    timezone: 26,
    language: 20,
    fonts: 16,
    vendorFonts: 10,
    cnBrowser: 8,
    deviceVendor: 6,
    intlLocale: 6,
    timezoneOffset: 4,
    emoji: 4,
  });
  assert.equal(totalWeight, 100);
  assert.ok(api.signals.every((signal) => signal.weight > 0));
  assert.ok(!ids.includes("anthropicBaseUrl"));
});

test("rejected high-entropy client hints fall back without aborting the scan", async () => {
  const api = detectorApi();
  const result = await api.detect(baseEnvironment({
    userAgentData: {
      brands: [{ brand: "Chromium", version: "140" }],
      getHighEntropyValues: async () => {
        throw new Error("client hints unavailable");
      },
    },
  }));
  const device = result.signals.find(
    (signal) => signal.id === "deviceVendor",
  );

  assert.equal(result.status, "complete");
  assert.equal(device.coverage, "limited");
  assert.match(device.raw, /仅 User-Agent/);
});

test("the full UI renders success, rescan, and failure states", async () => {
  const api = detectorApi();
  const result = await api.detect(baseEnvironment());
  let calls = 0;
  const success = uiHarness({
    signals: api.signals,
    browserEnvironment: () => ({}),
    detect: async () => {
      calls += 1;
      return result;
    },
  });

  assert.equal(success.list.children.length, 9);
  await success.start.click();
  assert.equal(success.status.attributes.get("data-result-status"), "complete");
  assert.match(success.status.textContent, /检测完成/);
  assert.equal(success.score.textContent, String(result.total));
  assert.equal(success.band.textContent, "低风险");
  assert.equal(success.start.hidden, true);
  assert.equal(success.rescan.hidden, false);
  await success.rescan.click();
  assert.equal(calls, 2);

  const failure = uiHarness({
    signals: api.signals,
    browserEnvironment: () => ({}),
    detect: async () => {
      throw new Error("scan failed");
    },
  });
  await failure.start.click();
  assert.equal(failure.status.attributes.get("data-result-status"), "failed");
  assert.match(failure.status.textContent, /未验证/);
  assert.equal(failure.score.textContent, "—");
  assert.equal(failure.band.textContent, "未验证");
  assert.equal(failure.start.hidden, true);
  assert.equal(failure.rescan.hidden, false);
});

test("Taiwan preferences score zero while mainland preferences score fully", () => {
  const api = detectorApi();

  assert.equal(api.scoreTimezone("Asia/Taipei"), 0);
  assert.equal(api.scoreTimezone("Asia/Shanghai"), 1);
  assert.equal(api.scoreLanguages(["zh-TW", "zh", "en-US"]), 0);
  assert.equal(api.scoreLanguages(["zh-CN", "zh", "en-US"]), 1);
  assert.equal(api.scoreIntlLocale("zh-TW"), 0);
  assert.equal(api.scoreIntlLocale("zh-CN"), 1);
});

test("Safari completes through the UA fallback and labels device evidence as limited", async () => {
  const api = detectorApi();
  const result = await api.detect(baseEnvironment());
  const device = result.signals.find(
    (signal) => signal.id === "deviceVendor",
  );

  assert.equal(result.status, "complete");
  assert.equal(result.signals.length, 9);
  assert.equal(result.total, 7);
  assert.equal(result.band, "low");
  assert.equal(device.coverage, "limited");
  assert.equal(device.contribution, 0);
  assert.match(device.raw, /仅 User-Agent/);
});

test("Chrome and Edge use full client hints without changing the nine-signal contract", async () => {
  const api = detectorApi();
  const cases = [
    {
      name: "Chrome",
      brands: [
        { brand: "Chromium", version: "140" },
        { brand: "Google Chrome", version: "140" },
      ],
    },
    {
      name: "Edge",
      brands: [
        { brand: "Chromium", version: "140" },
        { brand: "Microsoft Edge", version: "140" },
      ],
    },
  ];

  for (const browser of cases) {
    const result = await api.detect(
      baseEnvironment({
        userAgent:
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
          "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
        platform: "Win32",
        userAgentData: {
          brands: browser.brands,
          getHighEntropyValues: async () => ({
            model: "",
            platform: "Windows",
            platformVersion: "19.0.0",
          }),
        },
        hasFont: () => false,
      }),
    );
    const device = result.signals.find(
      (signal) => signal.id === "deviceVendor",
    );

    assert.equal(result.status, "complete", browser.name);
    assert.equal(result.signals.length, 9, browser.name);
    assert.equal(device.coverage, "full", browser.name);
  }
});

test("risk bands keep the documented 0-30, 31-60, and 61-100 boundaries", () => {
  const api = detectorApi();

  assert.equal(api.riskBand(0), "low");
  assert.equal(api.riskBand(30), "low");
  assert.equal(api.riskBand(31), "medium");
  assert.equal(api.riskBand(60), "medium");
  assert.equal(api.riskBand(61), "high");
  assert.equal(api.riskBand(100), "high");
});

test("every contribution is bounded and the displayed total is their exact sum", async () => {
  const api = detectorApi();
  const result = await api.detect(
    baseEnvironment({
      timeZone: "Asia/Shanghai",
      languages: ["zh-CN", "zh"],
      intlLocale: "zh-CN",
      userAgent:
        "Mozilla/5.0 (Linux; Android 14; HUAWEI) " +
        "AppleWebKit/537.36 Mobile MicroMessenger/8.0",
      platform: "Linux armv8l",
      userAgentData: {
        brands: [{ brand: "WeChat", version: "8" }],
        getHighEntropyValues: async () => ({
          model: "HUAWEI NOH-AN00",
          platform: "Android",
        }),
      },
      hasFont: () => true,
    }),
  );
  const sum = result.signals.reduce(
    (total, signal) => total + signal.contribution,
    0,
  );

  assert.equal(result.total, 95);
  assert.equal(sum, 95);
  for (const signal of result.signals) {
    assert.ok(signal.contribution >= 0);
    assert.ok(signal.contribution <= signal.weight);
  }
});
