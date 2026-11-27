// Creates a push subscription only in this isolated browser profile, then removes it.
// No customer messages or third-party notifications are sent.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { chromium } from '@playwright/test';
const base = process.env.SERVER_BASE_URL || 'https://162.248.166.241:18443';
const pair = [...fs.readFileSync('secrets/managers-20261125-access.txt','utf8').matchAll(/Логин: (.+)\nПароль: (.+)/g)][0];
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
const context = await browser.newContext({ locale: 'ru-RU' });
const page = await context.newPage();
page.setDefaultTimeout(30000);
const errors = [];
page.on('pageerror', error => errors.push(error.name));
let auth;
const api = base + '/api/v1/accounts/1/corporate/browser_push';
const check = (name, value) => { assert.ok(value, name); console.log('PASS ' + name); };
try {
 await page.goto(base + '/app/login', { waitUntil: 'domcontentloaded' });
 await page.locator('input[placeholder="example@companyname.com"]').fill(pair[1]);
 await page.locator('input[type=password]').fill(pair[2]);
 const signed = page.waitForResponse(r => new URL(r.url()).pathname === '/auth/sign_in' && r.request().method() === 'POST');
 await page.locator('button[type=submit]').click();
 const response = await signed;
 check('Manager login', response.status() === 200);
 const h = await response.allHeaders();
 auth = Object.fromEntries(['access-token','token-type','client','expiry','uid'].map(k => [k,h[k]]));
 await page.getByRole('button', { name: 'Уведомления', exact: true }).click();
 const panel = page.getByRole('dialog', { name: 'Уведомления', exact: true });
 await panel.waitFor();
 check('Notification health panel is available', await panel.getByRole('status').textContent() !== '');
 const status = await page.request.post(api + '/status', { headers: auth, data: {}, timeout: 15000 });
 check('Server is configured and disconnected profile is not marked verified', status.status() === 200 && (await status.json()).configured && !(await status.json()).connected);
 const sw = await page.request.get(base + '/sw.js');
 check('Updated service worker is public', sw.status() === 200 && (await sw.text()).includes('corporate_push_receipts'));
 const forged = await page.request.post(base + '/api/v1/corporate_push_receipts', { data: { token: 'synthetic-forgery' } });
 check('Forged receipt is rejected', forged.status() === 404);
 await context.grantPermissions(['notifications'], { origin: base });
 await panel.getByRole('button', { name: 'Проверить снова', exact: true }).click();
 await panel.getByRole('button', { name: 'Включить уведомления', exact: true }).click();
 await page.waitForFunction(() => {
  const panel = document.querySelector('section[role=dialog]');
  return panel && [...panel.querySelectorAll('button')].every(button => !button.disabled);
 }, { timeout: 25000 });
 const test = panel.getByRole('button', { name: 'Отправить тест', exact: true });
 if (await test.count()) {
   check('Real browser subscription was saved', true);
   await test.click();
   try {
     await panel.getByRole('button', { name: 'Уведомление вижу', exact: true }).waitFor({ timeout: 35000 });
     check('Real push was acknowledged by service worker', true);
     check('Visible display still requires human confirmation', !(await panel.getByRole('status').textContent()).includes('Уведомления подключены'));
   } catch {
     console.log('UNVERIFIED Browser receipt did not arrive on automated external route');
   }
 } else {
   console.log('UNVERIFIED Real PushManager subscription unavailable on automated external route');
   check('Failed subscription is visible without false success', await panel.getByRole('alert').count() === 1);
 }
 check('No JavaScript exceptions', errors.length === 0);
} finally {
 try {
  if (auth) {
   try {
    const endpoint = await page.evaluate(async () => {
      const registration = await navigator.serviceWorker.getRegistration('/');
      const subscription = await registration?.pushManager.getSubscription();
      return subscription?.endpoint;
    });
    if (endpoint) {
      check('Isolated browser subscription removed', (await page.request.delete(api, { headers: auth, data: { endpoint }, timeout: 15000 })).status() === 204);
      await page.evaluate(async () => { const registration = await navigator.serviceWorker.getRegistration('/'); await (await registration?.pushManager.getSubscription())?.unsubscribe(); });
    }
   } finally { check('Probe session revoked', (await page.request.delete(base + '/auth/sign_out', { headers: auth, timeout: 15000 })).status() === 200); }
  }
 } finally { await browser.close(); }
}
