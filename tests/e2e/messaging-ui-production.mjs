// Uses only an explicitly selected, owner-authorized acceptance conversation.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { chromium } from '@playwright/test';
const id = process.env.MESSAGING_TEST_CONVERSATION_ID;
assert.match(id || '', /^\d+$/);
const sendApproved = process.env.MESSAGING_LIVE_TEST_SEND === 'approved';
const base = 'https://mess.prav-buro.ru';
const pair = [...fs.readFileSync('secrets/managers-20261125-access.txt', 'utf8').matchAll(/Логин: (.+)\nПароль: (.+)/g)][0];
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true,
  ...(process.env.TEST_SOCKS_PROXY ? { proxy: { server: process.env.TEST_SOCKS_PROXY } } : {}) });
const context = await browser.newContext({ locale: 'ru-RU', viewport: { width: 1600, height: 1000 } });
const page = await context.newPage();
const errors = [];
page.on('pageerror', e => errors.push(e.name));
let auth;
const check = (name, value) => { assert.ok(value, name); console.log('PASS ' + name); };
try {
  await page.goto(base + '/app/login');
  await page.locator('input[placeholder="example@companyname.com"]').fill(pair[1]);
  await page.locator('input[type=password]').fill(pair[2]);
  const pending = page.waitForResponse(r => new URL(r.url()).pathname === '/auth/sign_in' && r.request().method() === 'POST');
  await page.locator('button[type=submit]').click();
  const signed = await pending;
  check('Manager signs in', signed.status() === 200);
  const h = await signed.allHeaders();
  auth = Object.fromEntries(['access-token', 'token-type', 'client', 'expiry', 'uid'].filter(k => h[k]).map(k => [k, h[k]]));
  await page.waitForURL('**/app/accounts/**');
  const chat = base + `/app/accounts/1/conversations/${id}`;
  await page.goto(chat);
  const separator = page.getByRole('separator', { name: 'Изменить ширину диалогов' });
  await separator.waitFor();
  const previous = Number(await separator.getAttribute('aria-valuenow'));
  const box = await separator.boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + 100);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width / 2 + 70, box.y + 100, { steps: 8 });
  await page.mouse.up();
  check('Conversation list resizes with pointer', Number(await separator.getAttribute('aria-valuenow')) > previous);
  const saved = await separator.getAttribute('aria-valuenow');
  await page.reload();
  await separator.waitFor();
  check('Conversation width survives reload', await separator.getAttribute('aria-valuenow') === saved);
  await page.getByRole('button', { name: 'Мои клиенты', exact: true }).click();
  await page.locator('#corporate-phone').waitFor();
  await page.locator('.conversation-panel').click({ position: { x: 100, y: 100 } });
  await page.locator('#corporate-phone').waitFor({ state: 'detached' });
  check('Client panel closes on outside click', await page.locator('#corporate-phone').count() === 0);
  await page.getByRole('button', { name: 'Мои клиенты', exact: true }).click();
  await page.locator('#corporate-phone').waitFor();
  await page.keyboard.press('Escape');
  await page.locator('#corporate-phone').waitFor({ state: 'detached' });
  check('Client panel closes on Escape', await page.locator('#corporate-phone').count() === 0);
  if (sendApproved) {
    const panel = page.locator('.conversation-panel');
    await panel.evaluate(el => { el.scrollTop = 0; });
    const editor = page.locator('.reply-box .ProseMirror[contenteditable=true]').first();
    await editor.fill('Проверка статуса прочтения MAX. Откройте этот тестовый диалог на телефоне.');
    const response = page.waitForResponse(r => r.request().method() === 'POST' && new URL(r.url()).pathname === `/api/v1/accounts/1/conversations/${id}/messages`);
    await editor.press('Enter');
    const created = await response;
    check('Acceptance message created', created.status() === 200);
    const message = await created.json();
    console.log('ACCEPTANCE_MESSAGE_ID ' + message.id);
    fs.writeFileSync('docs/evidence/messaging-live-message.json', JSON.stringify({ conversation_id: Number(id), message_id: message.id }) + '\n');
    await page.waitForFunction(() => { const el = document.querySelector('.conversation-panel'); return el.scrollHeight - el.clientHeight - el.scrollTop < 12; });
    check('Sending scrolls to the newest message', await panel.evaluate(el => el.scrollHeight - el.clientHeight - el.scrollTop < 12));
  }
  const readId = process.env.MESSAGING_READ_MESSAGE_ID;
  if (readId) {
    assert.match(readId, /^\d+$/);
    await page.goto(chat + '?messageId=' + readId);
    const indicator = page.locator(`#message${readId} .i-lucide-check-check`);
    await indicator.waitFor();
    check('Confirmed MAX read shows blue double checks', await indicator.evaluate(el => getComputedStyle(el).color) === 'rgb(126, 182, 255)');
  }
  check('No JavaScript errors', errors.length === 0);
} finally {
  if (auth) { const result = await page.request.delete(base + '/auth/sign_out', { headers: auth }); check('Probe session revoked', result.status() === 200); }
  await context.close();
  await browser.close();
}
