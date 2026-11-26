// Read-only acceptance: layout changes only, no messages sent or customer content exported.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { chromium } from '@playwright/test';
const id = process.env.LAYOUT_TEST_CONVERSATION_ID;
assert.match(id || '', /^\d+$/, 'Select an owner-authorized test conversation');
const base = 'https://mess.prav-buro.ru';
const credentials = [...fs.readFileSync('secrets/managers-20261125-access.txt', 'utf8').matchAll(/Логин: (.+)\nПароль: (.+)/g)][0];
const browser = await chromium.launch({
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: true,
  ...(process.env.TEST_SOCKS_PROXY ? { proxy: { server: process.env.TEST_SOCKS_PROXY } } : {}),
});
const context = await browser.newContext({ locale: 'ru-RU', viewport: { width: 1600, height: 1000 } });
const page = await context.newPage();
const errors = [];
page.on('pageerror', error => errors.push(error.name));
let auth;
const check = (name, passed) => { assert.ok(passed, name); console.log('PASS ' + name); };
try {
  await page.goto(base + '/app/login', { waitUntil: 'domcontentloaded' });
  await page.locator('input[placeholder="example@companyname.com"]').fill(credentials[1]);
  await page.locator('input[type=password]').fill(credentials[2]);
  const pending = page.waitForResponse(r => new URL(r.url()).pathname === '/auth/sign_in' && r.request().method() === 'POST');
  await page.locator('button[type=submit]').click();
  const response = await pending;
  check('Manager signs in', response.status() === 200);
  const headers = await response.allHeaders();
  auth = Object.fromEntries(['access-token', 'token-type', 'client', 'expiry', 'uid'].filter(k => headers[k]).map(k => [k, headers[k]]));
  await page.waitForURL('**/app/accounts/**');
  await page.evaluate(() => ['corporate-crm-collapsed', 'conversation-editor-height', 'inbox-list-collapsed', 'inbox-list-width'].forEach(key => localStorage.removeItem(key)));
  const chat = base + `/app/accounts/1/conversations/${id}`;
  await page.goto(chat);
  const details = page.locator(`[id="crm-details-1-${id}"]`);
  await details.waitFor();
  const toggle = page.locator(`[aria-controls="crm-details-1-${id}"]`);
  await toggle.click();
  check('CRM details collapse', !(await details.isVisible()));
  await page.reload();
  await toggle.waitFor();
  check('CRM collapse survives reload', await toggle.getAttribute('aria-expanded') === 'false');
  await toggle.click();
  await details.waitFor();
  check('CRM details reopen', await details.isVisible());
  const wrapper = page.locator('.resizable-editor-wrapper').first();
  await wrapper.waitFor();
  const handle = wrapper.locator('.cursor-row-resize');
  const box = await handle.boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2 + 40, { steps: 8 });
  await page.mouse.up();
  await page.waitForFunction(() => localStorage.getItem('conversation-editor-height') === '80');
  await page.reload();
  await wrapper.waitFor();
  check('Editor height survives reload', await wrapper.evaluate(el => el.style.getPropertyValue('--editor-height')) === '80px');
  await page.goto(base + '/app/accounts/1/inbox-view');
  const separator = page.getByRole('separator', { name: 'Изменить ширину входящих' });
  await separator.waitFor();
  const border = await separator.boundingBox();
  await page.mouse.move(border.x + border.width / 2, border.y + 100);
  await page.mouse.down();
  await page.mouse.move(border.x + border.width / 2 + 100, border.y + 100, { steps: 10 });
  await page.mouse.up();
  await page.waitForFunction(() => Number(localStorage.getItem('inbox-list-width')) > 400);
  check('Inbox pointer drag changes rendered width', await separator.locator('..').evaluate(el => el.getBoundingClientRect().width) > 400);
  await page.reload();
  await separator.waitFor();
  check('Inbox width survives reload', await separator.locator('..').evaluate(el => el.getBoundingClientRect().width) > 400);
  await page.getByRole('button', { name: 'Скрыть входящие', exact: true }).click();
  await page.getByRole('button', { name: 'Показать входящие', exact: true }).waitFor();
  await page.reload();
  await page.getByRole('button', { name: 'Показать входящие', exact: true }).waitFor();
  check('Inbox collapse survives reload', await separator.count() === 0);
  await page.getByRole('button', { name: 'Показать входящие', exact: true }).click();
  await separator.waitFor();
  check('Inbox reopens at saved width', await separator.locator('..').evaluate(el => el.getBoundingClientRect().width) > 400);
  check('No browser JavaScript errors', errors.length === 0);
} finally {
  if (auth) {
    const result = await page.request.delete(base + '/auth/sign_out', { headers: auth });
    check('Probe session revoked', result.status() === 200);
  }
  await context.close();
  await browser.close();
}
