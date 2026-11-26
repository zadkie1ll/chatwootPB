// Touches only an explicitly approved test conversation; sends no messages.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { chromium } from '@playwright/test';
const id = process.env.SHARING_TEST_CONVERSATION_ID;
assert.match(id || '', /^\d+$/);
assert.equal(process.env.SHARING_LIVE_TEST, 'approved');
const base = process.env.SERVER_BASE_URL || 'https://mess.prav-buro.ru:18443';
const credentials = [...fs.readFileSync('secrets/managers-20261125-access.txt', 'utf8').matchAll(/Логин: (.+)\nПароль: (.+)/g)];
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true,
  ...(process.env.TEST_SOCKS_PROXY ? { proxy: { server: process.env.TEST_SOCKS_PROXY } } : {}) });
const sessions = [];
const errors = [];
const check = (name, value) => { assert.ok(value, name); console.log('PASS ' + name); };
const endpoint = `/api/v1/accounts/1/corporate/sharing/conversations/${id}`;
let original;
let owner;
async function login(index) {
  const context = await browser.newContext({ locale: 'ru-RU', viewport: { width: 1600, height: 1000 } });
  const page = await context.newPage();
  page.on('pageerror', e => errors.push(e.name));
  page.on('console', message => { if (message.type() === 'error' && /^(SyntaxError|TypeError|ReferenceError):/.test(message.text())) errors.push('render'); });
  await page.goto(base + '/app/login');
  await page.locator('input[placeholder="example@companyname.com"]').fill(credentials[index][1]);
  await page.locator('input[type=password]').fill(credentials[index][2]);
  const pending = page.waitForResponse(r => new URL(r.url()).pathname === '/auth/sign_in' && r.request().method() === 'POST');
  await page.locator('button[type=submit]').click();
  const response = await pending;
  check('Acceptance manager signs in', response.status() === 200);
  const h = await response.allHeaders();
  const auth = Object.fromEntries(['access-token', 'token-type', 'client', 'expiry', 'uid'].filter(k => h[k]).map(k => [k, h[k]]));
  const session = { context, page, auth };
  sessions.push(session);
  await page.waitForURL('**/app/accounts/**');
  return session;
}
try {
  owner = await login(0);
  const reader = await login(1);
  const prior = await owner.page.request.get(base + endpoint, { headers: owner.auth });
  check('Owner can manage acceptance chat', prior.status() === 200);
  original = await prior.json();
  assert.equal(original.manual, false, 'Acceptance requires an initially private test chat');
  assert.equal(original.absence, false, 'Do not change live absence settings');
  const privateView = await reader.page.request.get(base + `/api/v1/accounts/1/conversations/${id}`, { headers: reader.auth });
  check('Colleague cannot read private test chat', [401, 404].includes(privateView.status()));
  await owner.page.goto(base + `/app/accounts/1/conversations/${id}`);
  const share = owner.page.getByRole('button', { name: 'Открыть чат всем', exact: true });
  await share.waitFor();
  const opening = owner.page.waitForResponse(r => new URL(r.url()).pathname === endpoint && r.request().method() === 'PATCH');
  await share.click();
  check('Owner shares chat from interface', (await opening).status() === 200);
  const state = await (await owner.page.request.get(base + endpoint, { headers: owner.auth })).json();
  check('Sharing preserves original owner', state.shared && state.owner_id === original.owner_id);
  const sharedView = await reader.page.request.get(base + `/api/v1/accounts/1/conversations/${id}`, { headers: reader.auth });
  check('Colleague can read shared test chat', sharedView.status() === 200);
  await reader.page.goto(base + '/app/accounts/1/dashboard');
  const tab = reader.page.locator('a').filter({ hasText: /^Общие/ }).first();
  await tab.waitFor();
  await tab.click();
  const meta = await reader.page.request.get(base + '/api/v1/accounts/1/conversations/meta', { headers: reader.auth });
  check('Shared tab and counters available', (await meta.json()).meta.shared_count >= 1);
  const messages = await reader.page.request.get(base + `/api/v1/accounts/1/conversations/${id}/messages`, { headers: reader.auth });
  check('Shared messages API is available', messages.status() === 200);
  const payload = await messages.json();
  const file = payload.payload.flatMap(m => m.attachments || []).find(a => a.data_url?.includes('/api/v1/corporate_files/'));
  assert.ok(file, 'Approved test conversation must contain test media');
  check('Protected media retains reserve origin', new URL(file.data_url).origin === base);
  const media = await reader.page.request.head(file.data_url);
  check('Shared test media is accessible with browser session', media.status() === 200);
  await owner.page.getByRole('button', { name: 'Закрыть постоянный общий доступ', exact: true }).click();
  await owner.page.getByRole('button', { name: 'Открыть чат всем', exact: true }).waitFor();
  const denied = await reader.page.request.get(base + `/api/v1/accounts/1/conversations/${id}`, { headers: reader.auth });
  check('Closing sharing revokes chat access', [401, 404].includes(denied.status()));
  const deniedMedia = await reader.page.request.head(file.data_url);
  check('The same media URL is denied after closing sharing', deniedMedia.status() === 404);
  check('No JavaScript errors', errors.length === 0);
} finally {
  if (owner && original) {
    const restore = await owner.page.request.patch(base + endpoint, { headers: owner.auth, data: { shared: original.manual } });
    check('Original sharing state restored', restore.status() === 200);
  }
  for (const session of sessions) {
    const response = await session.page.request.delete(base + '/auth/sign_out', { headers: session.auth });
    check('Probe session revoked', response.status() === 200);
    await session.context.close();
  }
  await browser.close();
}
