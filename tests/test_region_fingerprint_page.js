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

function detectorApi(globals = {}) {
  const context = vm.createContext({ window: {}, ...globals });
  vm.runInContext(scriptSource("claude-easy-region-core"), context, {
    filename: "claude-region-check-core.js",
  });
  return context.window.ClaudeEasyRegionCheck;
}

function baseEnvironment(overrides = {}) {
  return {
    timeZone: "Asia/Taipei",
    timezoneOffset: -480,
    language: "zh-TW",
    intlLocale: "zh-TW",
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15",
    platform: "MacIntel",
    userAgentData: undefined,
    hasFont: (font) => font === "PingFang TC",
    detectWebrtcLeak: async () => ({
      raw: "未发现 WebRTC IP 候选",
      score: 0,
    }),
    ...overrides,
  };
}

test("the detector is one self-contained HTML file with only disclosed network probes", () => {
  const source = pageSource();
  const executableSource = source.replace(/<!--[\s\S]*?-->/g, "");

  assert.match(source, /data-contract-version="1"/);
  assert.match(source, /data-action="start"/);
  assert.match(source, /data-action="rescan"/);
  const csp = source.match(
    /<meta\s+http-equiv="Content-Security-Policy"\s+content="([^"]+)"\s*>/i,
  );
  assert.ok(csp, "the local page must enforce a Content Security Policy");
  const cspEntries = csp[1].split(";").map((entry) => entry.trim()).filter(Boolean);
  const cspDirectives = Object.fromEntries(cspEntries.map((entry) => {
    const [name, ...values] = entry.split(/\s+/);
    return [name, values.join(" ")];
  }));
  assert.equal(new Set(cspEntries.map((entry) => entry.split(/\s+/, 1)[0])).size, cspEntries.length);
  assert.deepEqual(cspDirectives, {
    "default-src": "'none'",
    "script-src": "'unsafe-inline'",
    "style-src": "'unsafe-inline'",
    "connect-src": "https://cloudflare.com",
    "img-src": "'none'",
    "font-src": "'none'",
    "object-src": "'none'",
    "base-uri": "'none'",
    "form-action": "'none'",
  });
  assert.doesNotMatch(csp[1], /\bnavigate-to\b/);
  assert.doesNotMatch(source, /FuckClaude/);
  assert.doesNotMatch(source, /\b(?:src|href)\s*=/i);
  assert.deepEqual(
    Array.from(executableSource.matchAll(/https?:\/\/[^'"\s<]+/g), (match) => match[0]),
    [
      "https://cloudflare.com;",
      "https://cloudflare.com/cdn-cgi/trace",
    ],
  );
  assert.match(source, /\bfetch\b/);
  assert.doesNotMatch(
    source,
    /\b(?:XMLHttpRequest|WebSocket|EventSource|sendBeacon|serviceWorker)\b/,
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
    /\b(?:window\.open|document\.write|location\s*(?:=|\.|\[)|history\s*\.)/i,
  );
  assert.doesNotMatch(source, /\bwindow\s*\[\s*["']location["']\s*\]/i);
  assert.deepEqual(
    Array.from(source.matchAll(/stun:[a-z0-9.-]+:\d+/g), (match) => match[0]),
    [
      "stun:stun.l.google.com:19302",
      "stun:stun.cloudflare.com:3478",
      "stun:stun1.l.google.com:19302",
    ],
  );
  assert.match(source, /stun\.l\.google\.com/);
  assert.match(source, /stun1\.l\.google\.com/);
  assert.match(source, /stun\.cloudflare\.com/);
});

test("the public contract exposes the upstream ten signals and weights", () => {
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
      "webrtcLeak",
      "cnBrowser",
      "deviceVendor",
      "intlLocale",
      "timezoneOffset",
      "emoji",
    ],
  );
  assert.equal(new Set(ids).size, 10);
  assert.deepEqual(weights, {
    timezone: 24,
    language: 18,
    fonts: 14,
    vendorFonts: 10,
    webrtcLeak: 10,
    cnBrowser: 8,
    deviceVendor: 6,
    intlLocale: 4,
    timezoneOffset: 3,
    emoji: 3,
  });
  assert.equal(totalWeight, 100);
  assert.ok(api.signals.every((signal) => signal.weight > 0));
  assert.equal(Object.isFrozen(api.signals), true);
  assert.ok(api.signals.every((signal) => Object.isFrozen(signal)));
  assert.ok(!ids.includes("anthropicBaseUrl"));
  assert.equal(
    api.signals.find((signal) => signal.id === "fonts").name,
    "浏览器可见中文字体",
  );
  assert.equal(
    api.signals.find((signal) => signal.id === "language").name,
    "浏览器语言",
  );
  assert.equal(
    api.signals.find((signal) => signal.id === "emoji").name,
    "Emoji 平台推断",
  );
  assert.equal(
    api.signals.find((signal) => signal.id === "webrtcLeak").name,
    "WebRTC IP 泄露",
  );
  assert.equal(api.riskBand(0), "low");
  assert.equal(api.riskBand(30), "low");
  assert.equal(api.riskBand(31), "medium");
  assert.equal(api.riskBand(60), "medium");
  assert.equal(api.riskBand(61), "high");
  assert.equal(api.riskBand(100), "high");
});

test("a public WebRTC exit mismatch contributes zero without proof of a leak", async () => {
  const api = detectorApi();
  const candidate = await api.detect(baseEnvironment({
    detectWebrtcLeak: async () => api.classifyWebrtc("198.51.100.7", [
      { ip: "203.0.113.9", type: "srflx" },
    ]),
  }));
  const signal = candidate.signals.find((entry) => entry.id === "webrtcLeak");

  assert.equal(signal.score, 0);
  assert.equal(signal.contribution, 0);
  assert.equal(signal.match, "none");
  assert.equal(signal.raw, "WebRTC 公网出口不同，未确认泄露");
});

test("WebRTC classification compares candidates with the browser proxy exit", () => {
  const api = detectorApi();
  assert.deepEqual(
    { ...api.classifyWebrtc("198.51.100.7", [
      { ip: "203.0.113.9", type: "relay" },
    ]) },
    { raw: "未检测到 WebRTC 公网出口", score: 0 },
  );
  assert.deepEqual(
    { ...api.classifyWebrtc("198.51.100.7", [
      { ip: "198.51.100.7", type: "srflx" },
      { ip: "198.51.100.7", type: "srflx" },
    ]) },
    { raw: "WebRTC 与网页代理出口一致", score: 0 },
  );
  assert.deepEqual(
    { ...api.classifyWebrtc("198.51.100.7", [
      { ip: "203.0.113.9", type: "srflx" },
    ]) },
    { raw: "WebRTC 公网出口不同，未确认泄露", score: 0 },
  );
  assert.deepEqual(
    { ...api.classifyWebrtc("198.51.100.7", [
      { ip: "192.168.1.7", type: "host" },
    ]) },
    { raw: "WebRTC 暴露本地网络地址", score: 1 },
  );
  assert.deepEqual(
    { ...api.classifyWebrtc("2001:db8::7", [
      { ip: "198.51.100.7", type: "srflx" },
    ]) },
    { raw: "WebRTC 公网出口不同，未确认泄露", score: 0 },
  );
  assert.deepEqual(
    { ...api.classifyWebrtc("198.51.100.7", [
      { ip: "203.0.113.9", type: "srflx" },
      { ip: "2001:db8::7", type: "srflx" },
    ]) },
    { raw: "WebRTC 公网出口不同，未确认泄露", score: 0 },
  );
});

test("the WebRTC probe compares against an egress lookup without sending candidates", async () => {
  let configuration;
  const fetchCalls = [];
  const api = detectorApi({
    window: {
      fetch: async (...args) => {
        fetchCalls.push(args);
        return {
          ok: true,
          text: async () => "ip=198.51.100.7\n",
        };
      },
    },
  });
  class FakePeerConnection {
    constructor(value) {
      configuration = value;
    }
    createDataChannel() {}
    createOffer() {
      this.onicecandidate({
        candidate: {
          candidate: "candidate:1 1 udp 1 198.51.100.7 54321 typ srflx",
        },
      });
      this.onicecandidate({ candidate: null });
      return Promise.resolve({ type: "offer", sdp: "" });
    }
    setLocalDescription() {
      return Promise.resolve();
    }
    close() {}
  }

  const result = await api.detectWebrtcLeak({
    PeerConnection: FakePeerConnection,
    schedule: () => {},
  });
  assert.equal(
    JSON.stringify(configuration),
    JSON.stringify({
      iceServers: [
        { urls: "stun:stun.l.google.com:19302" },
        { urls: "stun:stun.cloudflare.com:3478" },
        { urls: "stun:stun1.l.google.com:19302" },
      ],
    }),
  );
  assert.equal(fetchCalls.length, 1);
  assert.equal(fetchCalls[0][0], "https://cloudflare.com/cdn-cgi/trace");
  assert.equal(fetchCalls[0][1].cache, "no-store");
  assert.equal(Object.hasOwn(fetchCalls[0][1], "body"), false);
  assert.doesNotMatch(JSON.stringify(fetchCalls), /198\.51\.100\.7/);
  assert.deepEqual(
    { ...result },
    { raw: "WebRTC 与网页代理出口一致", score: 0 },
  );
});

test("a WebRTC probe timeout stays unavailable instead of looking safe", async () => {
  const api = detectorApi();
  class SilentPeerConnection {
    createDataChannel() {}
    createOffer() { return Promise.resolve({ type: "offer", sdp: "" }); }
    setLocalDescription() { return Promise.resolve(); }
    close() {}
  }

  await assert.rejects(
    api.detectWebrtcLeak({
      PeerConnection: SilentPeerConnection,
      schedule: (callback) => callback(),
    }),
    /超时/,
  );
});

test("the public API exposes no country lookup that could disclose a WebRTC IP", () => {
  const api = detectorApi({
    window: {
      fetch: async () => { throw new Error("must not be called"); },
    },
  });

  assert.equal(Object.hasOwn(api, "lookupCountry"), false);
});

test("a failed WebRTC probe contributes zero and keeps the total", async () => {
  const api = detectorApi();
  const result = await api.detect(baseEnvironment({
    detectWebrtcLeak: async () => {
      throw new Error("STUN unavailable");
    },
  }));
  const signal = result.signals.find((entry) => entry.id === "webrtcLeak");

  assert.equal(result.status, "complete");
  assert.equal(result.total, 6);
  assert.equal(signal.raw, "未确认 WebRTC 泄露");
  assert.equal(signal.coverage, "full");
  assert.equal(signal.contribution, 0);
});

test("an unavailable WebRTC API contributes zero and keeps the total", async () => {
  const context = {
    measureText: () => ({ width: 100 }),
  };
  const api = detectorApi({
    document: {
      createElement: () => ({ getContext: () => context }),
    },
    navigator: {
      language: "en-US",
      platform: "MacIntel",
      userAgent:
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 Safari/605.1.15",
      userAgentData: undefined,
    },
  });

  const result = await api.detect(api.browserEnvironment());
  const signal = result.signals.find((entry) => entry.id === "webrtcLeak");

  assert.equal(signal.raw, "未确认 WebRTC 泄露");
  assert.equal(signal.coverage, "full");
  assert.equal(signal.score, 0);
  assert.equal(signal.contribution, 0);
  assert.equal(typeof result.total, "number");
  assert.equal(result.total, result.knownTotal);
  assert.equal(result.unknownWeight, 0);
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

test("browser environment survives unavailable canvas font detection", async () => {
  const api = detectorApi({
    document: {
      createElement: () => {
        throw new Error("canvas disabled");
      },
    },
    navigator: {
      language: "en-US",
      languages: ["en-US"],
      platform: "MacIntel",
      userAgent:
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 Safari/605.1.15",
      userAgentData: undefined,
    },
  });
  const environment = api.browserEnvironment();
  const result = await api.detect(environment);
  const fonts = result.signals.find((signal) => signal.id === "fonts");
  const vendorFonts = result.signals.find(
    (signal) => signal.id === "vendorFonts",
  );

  assert.equal(environment.hasFont("PingFang SC"), false);
  assert.equal(result.status, "complete");
  assert.equal(result.signals.length, 10);
  assert.equal(fonts.coverage, "unavailable");
  assert.equal(vendorFonts.coverage, "unavailable");
  assert.equal(result.unavailableCount, 2);
  assert.equal(result.total, null);
  assert.equal(result.unknownWeight, 24);
});

test("browser environment ignores fallback languages and reads only the interface language", () => {
  let languagesReads = 0;
  const navigator = {
    language: "en-US",
    platform: "MacIntel",
    userAgent: "Mozilla/5.0",
    userAgentData: undefined,
  };
  Object.defineProperty(navigator, "languages", {
    get() {
      languagesReads += 1;
      return ["en-US", "zh-CN"];
    },
  });
  const api = detectorApi({
    document: {
      createElement: () => ({ getContext: () => null }),
    },
    navigator,
  });

  const environment = api.browserEnvironment();

  assert.equal(environment.language, "en-US");
  assert.equal(languagesReads, 0);
  assert.equal(Object.hasOwn(environment, "languages"), false);
});

test("browser environment tolerates restricted navigator getters", async () => {
  const restrictedNavigator = {};
  for (const property of [
    "language",
    "languages",
    "platform",
    "userAgent",
    "userAgentData",
  ]) {
    Object.defineProperty(restrictedNavigator, property, {
      get() {
        throw new Error(`${property} is restricted`);
      },
    });
  }
  const api = detectorApi({
    document: {
      createElement: () => ({ getContext: () => null }),
    },
    navigator: restrictedNavigator,
  });

  const environment = api.browserEnvironment();
  const result = await api.detect(environment);

  assert.equal(environment.language, "");
  assert.equal(environment.userAgent, "");
  assert.equal(environment.platform, "");
  assert.equal(result.status, "complete");
  assert.ok(result.unavailableCount >= 6);
});

test("font measurement failures stay unavailable instead of becoming no match", async () => {
  const api = detectorApi();
  const result = await api.detect(baseEnvironment({
    fontDetectionAvailable: true,
    hasFont: () => {
      throw new Error("font measurement blocked");
    },
  }));
  const fonts = result.signals.find((signal) => signal.id === "fonts");
  const vendorFonts = result.signals.find(
    (signal) => signal.id === "vendorFonts",
  );

  assert.equal(fonts.raw, "无法读取");
  assert.equal(fonts.coverage, "unavailable");
  assert.equal(vendorFonts.raw, "无法读取");
  assert.equal(vendorFonts.coverage, "unavailable");
  assert.ok(result.unavailableCount >= 2);
});

test("unreadable browser values remain unknown instead of looking safe", async () => {
  const api = detectorApi();
  const result = await api.detect({
    timeZone: "",
    timezoneOffset: Number.NaN,
    language: "",
    intlLocale: "",
    userAgent: "",
    platform: "",
    userAgentData: undefined,
    fontDetectionAvailable: false,
    hasFont: () => false,
  });

  assert.equal(result.status, "complete");
  assert.equal(result.total, null);
  assert.equal(result.knownTotal, 0);
  assert.equal(result.unknownWeight, 90);
  assert.equal(result.matchedCount, 0);
  assert.equal(result.unavailableCount, 9);
  assert.ok(
    result.signals
      .filter((signal) => signal.raw === "无法读取")
      .every((signal) =>
        signal.coverage === "unavailable" &&
        signal.score === null &&
        signal.contribution === null &&
        signal.match === "unknown"),
  );
});

const SCORE_TRUTH_CASES = [
  { method: "scoreTimezone", input: "Asia/Taipei", expected: 0 },
  { method: "scoreTimezone", input: "Asia/Shanghai", expected: 1 },
  { method: "scoreLanguage", input: "zh-TW", expected: 0 },
  { method: "scoreLanguage", input: "zh-CN", expected: 1 },
  { method: "scoreIntlLocale", input: "zh-TW", expected: 0 },
  { method: "scoreIntlLocale", input: "zh-Hant-TW", expected: 0.5 },
  { method: "scoreIntlLocale", input: "zh-CN", expected: 1 },
  { method: "scoreIntlLocale", input: "zh-Hans-CN", expected: 1 },
  { method: "scoreIntlLocale", input: "zh-Hant-HK", expected: 0.5 },
  { method: "scoreLanguage", input: "zh-CN", expected: 1 },
  { method: "scoreLanguage", input: "zh-Hans", expected: 1 },
  { method: "scoreLanguage", input: "zh-Hans-CN", expected: 1 },
  { method: "scoreLanguage", input: "en-US", expected: 0 },
  { method: "scoreLanguage", input: "zh-SG", expected: 0 },
  { method: "scoreLanguage", input: "zh-Hans-SG", expected: 0 },
  { method: "scoreLanguage", input: "zh-MY", expected: 0 },
  { method: "scoreLanguage", input: "zh-Hans-TW", expected: 0 },
  { method: "scoreLanguage", input: "zh-Hant", expected: 0 },
  { method: "scoreLanguage", input: "zh-Hant-CN", expected: 0 },
  { method: "scoreLanguage", input: "zh-HK", expected: 0 },
  { method: "scoreLanguage", input: "zh-MO", expected: 0 },
  { method: "scoreLanguage", input: "zh", expected: 0 },
  { method: "scoreLanguage", input: "", expected: 0 },
];

test("timezone, language, and intl locale scoring follow the upstream truth table", () => {
  const api = detectorApi();
  for (const { method, input, expected } of SCORE_TRUTH_CASES) {
    assert.equal(api[method](input), expected, `${method}(${input})`);
  }
});

test("English interface stays zero even when fallback languages include Simplified Chinese", async () => {
  const api = detectorApi();
  const result = await api.detect(baseEnvironment({
    language: "en-US",
    languages: ["en-US", "en", "zh", "zh-CN", "zh-TW"],
  }));
  const language = result.signals.find((signal) => signal.id === "language");

  assert.equal(language.raw, "en-US");
  assert.equal(language.score, 0);
  assert.equal(language.contribution, 0);
});

test("match count uses the upstream 0.25 threshold", async () => {
  const api = detectorApi();
  const result = await api.detect(baseEnvironment());
  const fonts = result.signals.find((signal) => signal.id === "fonts");
  const emoji = result.signals.find((signal) => signal.id === "emoji");

  assert.equal(fonts.score, 0.2);
  assert.equal(fonts.contribution, 3);
  assert.equal(fonts.match, "none");
  assert.equal(emoji.score, 0.25);
  assert.equal(emoji.match, "weak");
  assert.equal(
    result.matchedCount,
    result.signals.filter((signal) => signal.score >= 0.25).length,
  );
});

test("Safari completes through the UA fallback and labels device evidence as limited", async () => {
  const api = detectorApi();
  const result = await api.detect(baseEnvironment());
  const device = result.signals.find(
    (signal) => signal.id === "deviceVendor",
  );

  assert.equal(result.status, "complete");
  assert.equal(result.signals.length, 10);
  assert.equal(result.total, 6);
  assert.equal(result.band, undefined);
  assert.equal(result.matchedCount, 2);
  assert.equal(device.coverage, "limited");
  assert.equal(device.contribution, 0);
  assert.match(device.raw, /仅 User-Agent/);
});

test("Chrome and Edge keep desktop device evidence limited when no model is exposed", async () => {
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
    assert.equal(result.signals.length, 10, browser.name);
    assert.equal(device.coverage, "limited", browser.name);
    assert.match(device.raw, /未提供设备型号/, browser.name);
  }
});

test("high-entropy device models affect the device signal", async () => {
  const api = detectorApi();
  let requestedHints;
  const result = await api.detect(baseEnvironment({
    userAgent:
      "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 " +
      "Chrome/140.0.0.0 Mobile Safari/537.36",
    platform: "Linux armv8l",
    userAgentData: {
      brands: [{ brand: "Chromium", version: "140" }],
      getHighEntropyValues: async (hints) => {
        requestedHints = Array.from(hints);
        return {
          model: "HUAWEI NOH-AN00",
          platform: "Android",
          platformVersion: "14.0.0",
        };
      },
    },
    hasFont: () => false,
  }));
  const device = result.signals.find(
    (signal) => signal.id === "deviceVendor",
  );

  assert.equal(device.coverage, "full");
  assert.equal(device.raw, "Huawei / Honor");
  assert.equal(device.contribution, 5);
  assert.deepEqual(requestedHints, ["model", "platform", "platformVersion"]);
});

test("high-entropy platform evidence affects device scoring like upstream", async () => {
  const api = detectorApi();
  const result = await api.detect(baseEnvironment({
    userAgent: "Mozilla/5.0",
    platform: "",
    userAgentData: {
      brands: [{ brand: "Chromium", version: "140" }],
      getHighEntropyValues: async () => ({
        model: "",
        platform: "HarmonyOS",
        platformVersion: "6.0",
      }),
    },
    hasFont: () => false,
  }));
  const device = result.signals.find((signal) => signal.id === "deviceVendor");

  assert.equal(device.raw, "HarmonyOS（有限信息：浏览器未提供设备型号）");
  assert.equal(device.contribution, 6);
});

test("TheWorld browser remains covered by the upstream browser rules", async () => {
  const api = detectorApi();
  const result = await api.detect(baseEnvironment({
    userAgent:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
      "AppleWebKit/537.36 Chrome/140.0.0.0 Safari/537.36 TheWorld",
    platform: "Win32",
    userAgentData: undefined,
    hasFont: () => false,
  }));
  const browser = result.signals.find((signal) => signal.id === "cnBrowser");

  assert.equal(browser.raw, "TheWorld");
  assert.equal(browser.contribution, 8);
});

test("a full mainland timezone hit is always reported as a match", async () => {
  const api = detectorApi();
  const result = await api.detect(baseEnvironment({
    timeZone: "Asia/Shanghai",
  }));
  const timezone = result.signals.find(
    (signal) => signal.id === "timezone",
  );

  assert.equal(timezone.score, 1);
  assert.equal(timezone.contribution, 24);
  assert.equal(timezone.match, "strong");
  assert.ok(result.matchedCount >= 1);
  assert.equal(result.band, undefined);
});

test("partial-match branches keep their documented contributions", async () => {
  const api = detectorApi();
  const result = await api.detect(baseEnvironment({
    timeZone: "Asia/Hong_Kong",
    language: "zh-HK",
    intlLocale: "zh-Hant-HK",
    hasFont: (font) => ["PingFang TC", "MiSans"].includes(font),
  }));
  const signals = Object.fromEntries(
    result.signals.map((signal) => [signal.id, signal]),
  );

  assert.equal(signals.timezone.contribution, 14);
  assert.equal(signals.language.contribution, 0);
  assert.equal(signals.fonts.contribution, 3);
  assert.equal(signals.vendorFonts.contribution, 8);
  assert.equal(signals.intlLocale.contribution, 2);
  assert.equal(signals.timezoneOffset.contribution, 2);
  assert.equal(signals.emoji.contribution, 1);
  assert.equal(new Set(result.signals.map((signal) => signal.id)).size, 10);
});

test("every contribution is bounded and the displayed total is their exact sum", async () => {
  const api = detectorApi();
  const result = await api.detect(
    baseEnvironment({
      timeZone: "Asia/Shanghai",
      language: "zh-CN",
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

  assert.equal(result.total, 86);
  assert.equal(sum, 86);
  for (const signal of result.signals) {
    assert.ok(signal.contribution >= 0);
    assert.ok(signal.contribution <= signal.weight);
  }
});
