// Sends only synthetic fixtures to the owner-authorized test conversation.
import fs from 'node:fs';
import { chromium, expect } from '@playwright/test';
if (process.env.MAX_LIVE_TEST_SEND !== 'approved' || !/^\d+$/.test(process.env.MAX_TEST_CONVERSATION_ID || '')) throw new Error('Explicit test-send opt-in and conversation ID required');
const id = process.env.MAX_TEST_CONVERSATION_ID;
const base = 'https://mess.prav-buro.ru';
const credentials = [...fs.readFileSync('secrets/managers-20261125-access.txt', 'utf8').matchAll(/Логин: (.+)\nПароль: (.+)/g)][0];
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
const context = await browser.newContext({ locale: 'ru-RU' });
const page = await context.newPage();
const report = { checks: [], errors: [], synthetic_files_only: true };
let auth;
const check = (name, passed) => { report.checks.push({ name, passed: !!passed }); console.log(`${passed ? 'PASS' : 'FAIL'} ${name}`); if (!passed) throw new Error(name); };
try {
  page.on('pageerror', error => report.errors.push(error.name));
  await page.goto(base + '/app/login', { waitUntil: 'domcontentloaded' });
  await page.locator('input[placeholder="example@companyname.com"]').fill(credentials[1]);
  await page.locator('input[type=password]').fill(credentials[2]);
  const signed = page.waitForResponse(r => new URL(r.url()).pathname === '/auth/sign_in' && r.request().method() === 'POST');
  await page.locator('button[type=submit]').click();
  const login = await signed;
  check('Manager signs in', login.status() === 200);
  const headers = await login.allHeaders();
  auth = Object.fromEntries(['access-token', 'token-type', 'client', 'expiry', 'uid'].filter(k => headers[k]).map(k => [k, headers[k]]));
  await page.waitForURL('**/app/accounts/**');
  await page.goto(base + `/app/accounts/1/conversations/${id}`, { waitUntil: 'domcontentloaded' });
  const editor = page.locator('.reply-box .ProseMirror[contenteditable=true]').first();
  await editor.waitFor();
  await editor.fill('Проверка двух файлов MAX через интерфейс менеджера.');
  const upload = page.locator('.reply-box input[type=file][multiple]').first();
  await upload.setInputFiles([
    { name: 'max-ui-test.txt', mimeType: 'text/plain', buffer: Buffer.from('Synthetic MAX UI attachment, no customer data.') },
    { name: 'max-ui-test.png', mimeType: 'image/png', buffer: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAeElEQVR4nO3PUQkAIBTAwBfNaDbXEH4cwmABbrP2+brhgga0oAEtaEALGtCCBrSgAS1oQAsa0IIGtKABLWhACxrQgga0oAEtaEALGtCCBrSgAS1oQAsa0IIGtKABLWhACxrQgga0oAEtaEALGtCCBrSgAS1oQAseu7+38Zbvl35qAAAAAElFTkSuQmCC', 'base64') },
  ]);
  await page.getByText('max-ui-test.txt', { exact: true }).last().waitFor();
  const responses = [];
  page.on('response', async response => {
    if (response.request().method() === 'POST' && new URL(response.url()).pathname === `/api/v1/accounts/1/conversations/${id}/messages`) {
      responses.push({ status: response.status(), body: await response.json() });
    }
  });
  await editor.press('Enter');
  await expect.poll(() => responses.length, { timeout: 30000 }).toBe(2);
  check('Enter creates one independent message per selected file', responses.every(r => r.status === 200 && r.body.attachments?.length === 1));
  report.test_message_ids = responses.map(r => r.body.id);
  check('Each message has a separate ID', new Set(report.test_message_ids).size === 2 && report.test_message_ids.every(Boolean));
  check('No browser JavaScript errors', report.errors.length === 0);
  report.passed = true;
} catch (error) {
  report.passed = false; report.error = error.message.slice(0, 250); process.exitCode = 1;
} finally {
  if (auth) await fetch(base + '/auth/sign_out', { method: 'DELETE', headers: auth });
  fs.writeFileSync('docs/evidence/max-file-send-2026-11-25.json', JSON.stringify(report, null, 2) + '\n');
  await browser.close();
}
