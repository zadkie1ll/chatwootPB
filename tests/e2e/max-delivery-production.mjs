// Read only acceptance against the explicitly selected owner-authorized test chat.
import fs from 'node:fs';
import { chromium } from '@playwright/test';
const id = process.env.MAX_TEST_CONVERSATION_ID;
if (!/^\d+$/.test(id || '')) throw new Error('MAX_TEST_CONVERSATION_ID is required');
const base = 'https://mess.prav-buro.ru';
const pairs = path => [...fs.readFileSync(path, 'utf8').matchAll(/Логин: (.+)\nПароль: (.+)/g)].map(match => ({ email: match[1], password: match[2] }));
const initial = pairs('secrets/server-access.txt');
const managers = pairs('secrets/managers-20261125-access.txt');
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
const report = { mode: 'selected-max-test-chat-readonly', checks: [], errors: [] };
function check(name, passed) {
  report.checks.push({ name, passed: !!passed });
  console.log(`${passed ? 'PASS' : 'FAIL'} ${name}`);
  if (!passed) throw new Error(name);
}
try {
  for (const [role, credentials] of [['technical_admin', initial[0]], ['supervisor', initial[1]], ['owner', managers[0]], ['other_manager', managers[1]]]) {
    if (process.env.MAX_ACCEPTANCE_ROLES && !process.env.MAX_ACCEPTANCE_ROLES.split(',').includes(role)) continue;
    const context = await browser.newContext({ locale: 'ru-RU' });
    const page = await context.newPage();
    page.on('pageerror', error => report.errors.push({ role, name: error.name }));
    let auth;
    try {
      await page.goto(base + '/app/login', { timeout: 25000, waitUntil: 'domcontentloaded' });
      await page.locator('input[placeholder="example@companyname.com"]').fill(credentials.email);
      await page.locator('input[type=password]').fill(credentials.password);
      const pending = page.waitForResponse(r => new URL(r.url()).pathname === '/auth/sign_in' && r.request().method() === 'POST');
      await page.locator('button[type=submit]').click();
      const response = await pending;
      check(role + ' signs in HTTP ' + response.status(), response.status() === 200);
      const headers = await response.allHeaders();
      auth = Object.fromEntries(['access-token', 'token-type', 'client', 'expiry', 'uid'].filter(k => headers[k]).map(k => [k, headers[k]]));
      await page.waitForURL('**/app/accounts/**');
      const access = await fetch(base + '/api/v1/accounts/1/corporate/access', { headers: auth });
      const identity = await access.json();
      check(role + ' authenticated role is confirmed', access.status === 200 && identity.role === ({ owner: 'manager', other_manager: 'manager' }[role] || role));
      const conversation = await fetch(base + `/api/v1/accounts/1/conversations/${id}`, { headers: auth });
      report.checks.push({ name: role + ' conversation HTTP status', status: conversation.status, content_type: conversation.headers.get('content-type') });
      const readable = ['supervisor', 'owner'].includes(role);
      check(role + ' MAX conversation access HTTP ' + conversation.status, readable ? conversation.status === 200 : (role === 'other_manager' ? [401, 403, 404].includes(conversation.status) : conversation.status === 404));
      const status = await fetch(base + '/api/v1/accounts/1/corporate/max_channel', { headers: auth });
      if (role === 'technical_admin') {
        const state = await status.json();
        check('Real MAX account remains connected', status.status === 200 && state.connected);
        check('MAX session responses are not cacheable', status.headers.get('cache-control')?.includes('no-store'));
      } else {
        check(role + ' cannot read MAX credentials or QR', status.status === 404);
      }
      if (role === 'owner') {
        await page.goto(base + `/app/accounts/1/conversations/${id}`, { waitUntil: 'domcontentloaded' });
        await page.locator('[data-channel=max]').first().waitFor();
        check('MAX badge is displayed in the real manager interface', true);
        await page.getByRole('button', { name: 'Новый диалог', exact: true }).click();
        await page.getByRole('dialog').getByRole('combobox').selectOption('max');
        check('Quick chat supports selecting MAX', await page.getByRole('dialog').getByRole('combobox').inputValue() === 'max');
        await page.getByRole('dialog').getByRole('button', { name: 'Отмена', exact: true }).click();
      }
    } finally {
      if (auth) {
        const response = await fetch(base + '/auth/sign_out', { method: 'DELETE', headers: auth });
        check(role + ' probe session revoked', response.status === 200);
      }
      await context.close();
    }
  }
  check('No browser JavaScript errors', report.errors.length === 0);
  report.passed = true;
} catch (error) {
  report.passed = false;
  report.error = error.message.slice(0, 180);
  process.exitCode = 1;
} finally {
  fs.writeFileSync('docs/evidence/max-delivery-browser-2026-11-25.json', JSON.stringify(report, null, 2) + '\n');
  await browser.close();
}
