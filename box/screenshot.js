// Playwright screenshot helper. All browser work happens on Box, never on
// Cloady (the free tier only gets 4 CPU-hours / month).
// Usage: node screenshot.js <url> <out.jpg> [width] [height]
const fs = require('fs');
const { chromium } = require('playwright');

// Box ships Google Chrome but not Playwright's own Chromium download.
// Prefer a system browser: set CHROME_PATH to override.
function browserPath() {
  const candidates = [
    process.env.CHROME_PATH,
    '/usr/bin/google-chrome-stable',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  ].filter(Boolean);
  return candidates.find((p) => { try { return fs.existsSync(p); } catch { return false; } });
}

(async () => {
  const [url, out, w, h] = process.argv.slice(2);
  if (!url || !out) throw new Error('usage: node screenshot.js <url> <out.jpg>');
  const browser = await chromium.launch({
    headless: true,
    executablePath: browserPath(),
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  try {
    const page = await browser.newPage({
      viewport: { width: Number(w) || 900, height: Number(h) || 600 },
      deviceScaleFactor: 1,
    });
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(1200);
    await page.screenshot({ path: out, type: 'jpeg', quality: 45, fullPage: false });
    console.log('ok');
  } finally {
    await browser.close();
  }
})().catch((e) => { console.error(e.message); process.exit(1); });
