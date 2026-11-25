// Production control-plane smoke only: never starts MAX auth or reads chats.
import fs from 'node:fs';
import { chromium } from '@playwright/test';
const base = 'https://mess.prav-buro.ru';
const accounts = [...fs.readFileSync('secrets/server-access.txt', 'utf8').matchAll(/Логин: (.+)\nПароль: (.+)/g)];
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
const report = { mode: 'production-readonly-no-max-login', checks: [], errors: [] };
const check = (name, passed) => {
  report.checks.push({ name, passed: !!passed });
  console.log(`${passed ? 'PASS' : 'FAIL'} ${name}`);
  if (!passed) throw new Error(name);
};
try {
  for (const [index, role] of ['technical_admin', 'supervisor'].entries()) {
    const context = await browser.newContext({ locale: 'ru-RU' });
    const page = await context.newPage();
    page.on('pageerror', error => report.errors.push({ role, name: error.name }));
    await page.goto(base + '/app/login');
    await page.locator('input[placeholder="example@companyname.com"]').fill(accounts[index][1]);
    await page.locator('input[type=password]').fill(accounts[index][2]);
    const pending = page.waitForResponse(r => new URL(r.url()).pathname === '/auth/sign_in' && r.request().method() === 'POST');
    await page.locator('button[type=submit]').click();
    const response = await pending;
    check(role + ' signs in through trusted HTTPS', response.status() === 200);
    const headers = await response.allHeaders();
    const auth = Object.fromEntries(['access-token', 'token-type', 'client', 'expiry', 'uid'].filter(k => headers[k]).map(k => [k, headers[k]]));
    await page.waitForURL('**/app/accounts/**');
    const max = await fetch(base + '/api/v1/accounts/1/corporate/max_channel', { headers: auth });
    if (role === 'technical_admin') {
      const state = await max.json();
      check('Technical admin can read private MAX pilot readiness', max.status === 200 && state.poc_only && state.messages_forwarded === false);
      check('MAX authentication responses cannot be cached', max.headers.get('cache-control')?.includes('no-store'));
      await page.getByRole('button', { name: 'Каналы', exact: true }).click();
      await page.getByRole('heading', { name: 'Подключение личного MAX — тест', exact: true }).waitFor();
      check('MAX connection screen is available on the real site', true);
      const tg = await fetch(base + '/api/v1/accounts/1/corporate/channel', { headers: auth });
      check('Existing Telegram session remains connected', tg.status === 200 && (await tg.json()).status === 'connected');
    } else {
      check('Supervisor cannot access MAX session or QR controls', max.status === 404);
      const health = await fetch(base + '/api/v1/accounts/1/corporate/health', { headers: auth });
      const state = await health.json();
      check('Telegram and existing delivery workers remain healthy', health.status === 200 && state.telegram?.connected && state.chatwoot_worker?.healthy && Object.values(state.workers || {}).every(v => v.healthy));
    }
    const signout = await fetch(base + '/auth/sign_out', { method: 'DELETE', headers: auth });
    check(role + ' probe session is revoked', signout.status === 200);
    await context.close();
  }
  check('No browser JavaScript errors', report.errors.length === 0);
  report.passed = true;
} catch (error) {
  report.passed = false;
  report.error = error.message.slice(0, 220);
  process.exitCode = 1;
} finally {
  report.executed_at = new Date().toISOString();
  fs.writeFileSync('docs/evidence/max-auth-production-browser-2026-11-25.json', JSON.stringify(report, null, 2) + '\n');
  await browser.close();
}
