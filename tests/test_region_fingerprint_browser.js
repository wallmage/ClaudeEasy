const assert = require("node:assert/strict");
const path = require("node:path");
const test = require("node:test");
const { pathToFileURL } = require("node:url");
const { chromium, webkit } = require("playwright");

const PAGE_URL = pathToFileURL(path.join(
  __dirname,
  "..",
  "claude-easy",
  "assets",
  "claude-region-check.html",
)).href;
const PUBLIC_IP_URL = "https://cloudflare.com/cdn-cgi/trace";

const TARGETS = {
  chrome: { browserType: chromium, launch: { channel: "chrome" } },
  edge: { browserType: chromium, launch: { channel: "msedge" } },
  webkit: { browserType: webkit, launch: {} },
};

function requestedTargets() {
  const configured = process.env.CLAUDE_EASY_BROWSER_TARGETS;
  if (configured) {
    return configured.split(",").map((target) => target.trim()).filter(Boolean);
  }
  return process.platform === "win32"
    ? ["chrome", "edge"]
    : ["chrome", "webkit"];
}

async function waitForCompletedScan(page) {
  await page.waitForFunction(() => {
    const status = document.querySelector("[data-result-status]");
    const rescan = document.querySelector('[data-action="rescan"]');
    return status &&
      status.getAttribute("data-result-status") === "complete" &&
      rescan &&
      !rescan.disabled;
  }, null, { timeout: 15_000 });
}

function contrastRatio(first, second) {
  function colorChannels(value) {
    const hex = value.match(/^#([0-9a-f]{6})$/i);
    if (hex) {
      return hex[1].match(/[0-9a-f]{2}/gi)
        .map((channel) => parseInt(channel, 16));
    }
    const rgb = value.match(
      /^rgba?\(\s*(\d+)\D+(\d+)\D+(\d+)(?:\D+([\d.]+))?\s*\)$/i,
    );
    assert.ok(rgb, `unsupported CSS color: ${value}`);
    const alpha = rgb[4] === undefined ? 1 : Number(rgb[4]);
    return rgb.slice(1, 4)
      .map((channel) => Number(channel) * alpha + 255 * (1 - alpha));
  }

  function luminance(color) {
    const channels = colorChannels(color).map((value) => {
      const channel = value / 255;
      return channel <= 0.04045
        ? channel / 12.92
        : ((channel + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * channels[0] +
      0.7152 * channels[1] +
      0.0722 * channels[2];
  }
  const light = Math.max(luminance(first), luminance(second));
  const dark = Math.min(luminance(first), luminance(second));
  return (light + 0.05) / (dark + 0.05);
}

for (const targetName of requestedTargets()) {
  const target = TARGETS[targetName];
  if (!target) throw new Error(`unsupported browser target: ${targetName}`);

  test(`the real local page completes in ${targetName}`, {
    timeout: 60_000,
  }, async (t) => {
    const browser = await target.browserType.launch({
      headless: true,
      ...target.launch,
    });
    t.after(() => browser.close());
    const context = await browser.newContext({
      viewport: { width: 1280, height: 900 },
    });
    const page = await context.newPage();
    const consoleProblems = [];
    const pageErrors = [];
    const externalRequests = [];
    const websockets = [];
    page.on("console", (message) => {
      if (["error", "warning"].includes(message.type())) {
        consoleProblems.push(`${message.type()}: ${message.text()}`);
      }
    });
    page.on("pageerror", (error) => pageErrors.push(error.message));
    page.on("request", (request) => {
      if (!request.url().startsWith("file:")) {
        externalRequests.push(request.url());
      }
    });
    page.on("websocket", (socket) => websockets.push(socket.url()));
    await page.route("**/*", async (route) => {
      if (route.request().url().startsWith("file:")) {
        await route.continue();
      } else if (route.request().url() === PUBLIC_IP_URL) {
        await route.fulfill({
          status: 200,
          contentType: "text/plain",
          body: "ip=198.51.100.7\n",
        });
      } else {
        await route.abort();
      }
    });

    await page.goto(PAGE_URL);
    assert.equal(
      await page.locator("[data-signal-list] .signal").count(),
      10,
    );
    assert.equal(
      await page.locator("[data-result-status]").getAttribute("role"),
      "status",
    );
    assert.equal(
      await page.locator("[data-result-status]").getAttribute("aria-live"),
      "polite",
    );
    assert.equal(
      await page.locator("[data-signal-list]").getAttribute("role"),
      "list",
    );
    assert.match(await page.locator("body").innerText(), /越高/);

    await page.locator('[data-action="start"]').focus();
    assert.equal(
      await page.evaluate(() => document.activeElement.textContent.trim()),
      "开始检测",
    );
    const focusIndicator = await page.evaluate(() => {
      const button = document.activeElement;
      const buttonStyle = getComputedStyle(button);
      const rootStyle = getComputedStyle(document.documentElement);
      return {
        expectedColor: rootStyle.getPropertyValue("--accent").trim(),
        outlineColor: buttonStyle.outlineColor,
        outlineStyle: buttonStyle.outlineStyle,
        outlineWidth: buttonStyle.outlineWidth,
      };
    });
    assert.equal(focusIndicator.outlineStyle, "solid");
    assert.equal(focusIndicator.outlineWidth, "3px");
    const expectedFocusContrast = contrastRatio(
      focusIndicator.expectedColor,
      "#ffffff",
    );
    const actualFocusContrast = contrastRatio(
      focusIndicator.outlineColor,
      "#ffffff",
    );
    assert.ok(
      Math.abs(actualFocusContrast - expectedFocusContrast) < 0.001,
      `computed focus color differs from the design token: ${
        JSON.stringify(focusIndicator)
      }`,
    );
    assert.ok(
      actualFocusContrast >= 3,
      `focus indicator contrast is below 3:1: ${
        JSON.stringify(focusIndicator)
      }`,
    );
    assert.notEqual(focusIndicator.outlineColor, "rgba(0, 0, 0, 0)");
    await page.keyboard.press("Enter");
    await waitForCompletedScan(page);
    assert.equal(
      await page.evaluate(() => document.activeElement.textContent.trim()),
      "重新扫描",
    );

    const result = await page.evaluate(() => ({
      score: document.querySelector("[data-result-score]").textContent,
      summary: document.querySelector("[data-result-summary]").textContent,
      rows: Array.from(document.querySelectorAll(".signal")).map((row) => ({
        coverage: row.getAttribute("data-coverage"),
        value: row.querySelector("[data-signal-value]").textContent,
        contribution:
          row.querySelector("[data-signal-contribution]").textContent,
      })),
    }));
    assert.equal(result.rows.length, 10);
    for (const row of result.rows) {
      assert.notEqual(row.value, "等待检测");
      assert.notEqual(row.value, "正在读取");
      if (row.coverage === "unavailable") {
        assert.equal(row.contribution, "未知");
      } else {
        assert.match(row.contribution, /^\+\d+$/);
      }
    }
    if (result.rows.some((row) => row.coverage === "unavailable")) {
      assert.equal(result.score, "—");
      assert.equal(result.summary, "结果不完整");
    } else {
      assert.match(result.score, /^\d+$/);
      assert.match(result.summary, /^(?:低风险|中等风险|高风险)$/);
    }

    await page.keyboard.press("Enter");
    await waitForCompletedScan(page);
    assert.equal(
      await page.evaluate(() => document.activeElement.textContent.trim()),
      "重新扫描",
    );

    await page.setViewportSize({ width: 280, height: 720 });
    const reflow = await page.evaluate(() => ({
      clientWidth: document.documentElement.clientWidth,
      scrollWidth: document.documentElement.scrollWidth,
    }));
    assert.ok(
      reflow.scrollWidth <= reflow.clientWidth,
      `page overflowed horizontally: ${JSON.stringify(reflow)}`,
    );

    const colors = await page.evaluate(() => {
      const style = getComputedStyle(document.documentElement);
      return {
        foreground: style.getPropertyValue("--notice-text").trim(),
        background: style.getPropertyValue("--notice-soft").trim(),
      };
    });
    assert.ok(
      contrastRatio(colors.foreground, colors.background) >= 4.5,
      `partial-result contrast is below 4.5:1: ${JSON.stringify(colors)}`,
    );
    assert.deepEqual(consoleProblems, []);
    assert.deepEqual(pageErrors, []);
    assert.ok(
      externalRequests.every((url) => url === PUBLIC_IP_URL),
      `unexpected external requests: ${JSON.stringify(externalRequests)}`,
    );
    assert.deepEqual(websockets, []);
  });

  test(`the page explains disabled JavaScript in ${targetName}`, {
    timeout: 30_000,
  }, async (t) => {
    const browser = await target.browserType.launch({
      headless: true,
      ...target.launch,
    });
    t.after(() => browser.close());
    const context = await browser.newContext({
      javaScriptEnabled: false,
    });
    const page = await context.newPage();

    await page.goto(PAGE_URL);
    assert.match(await page.locator("body").innerText(), /无法运行检测/);
    assert.equal(
      await page.locator('[data-action="start"]').isDisabled(),
      true,
    );
  });
}
