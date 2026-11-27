import assert from 'node:assert/strict';
import { chromium, webkit } from '@playwright/test';
const failures = [];
const origins = process.env.AVAILABILITY_ORIGINS?.split(',') || ['https://mess.prav-buro.ru', 'https://mess.prav-buro.ru:18443', 'https://162.248.166.241:18443'];
for (const [name, type, options] of [['Chrome', chromium, { executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' }], ['WebKit', webkit, {}]]) {
  const browser = await type.launch({ headless: true, ...options });
  try {
    for (const origin of origins) {
      const page = await browser.newPage();
      const errors = [];
      page.on('pageerror', error => errors.push(error.name));
      try {
        const response = await page.goto(origin + '/app/login', { timeout: 25000, waitUntil: 'domcontentloaded' });
        await page.locator('input[type=password]').waitFor({ timeout: 20000 });
        assert.equal(response.status(), 200);
        assert.equal(errors.length, 0);
        console.log('PASS ' + name + ' renders login at ' + origin);
      } catch (error) {
        failures.push({browser: name, origin, error: error.name});
        console.log('FAIL ' + name + ' ' + origin + ' ' + error.name);
      } finally {
        await page.close();
      }
    }
  } finally {
    await browser.close();
  }
}

assert.equal(failures.length, 0, JSON.stringify(failures));
