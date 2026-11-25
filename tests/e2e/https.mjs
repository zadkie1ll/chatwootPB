// Read-only production smoke: no customer content, uploads or Telegram sign-in.
import fs from 'node:fs';
import { chromium } from '@playwright/test';
const base = process.env.SERVER_BASE_URL || 'https://mess.prav-buro.ru';
const accounts = [...fs.readFileSync('secrets/server-access.txt', 'utf8').matchAll(/Логин: (.+)\nПароль: (.+)/g)];
const report = { base, checks: [], page_errors: [], server_errors: [] };
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
function check(name, passed) {
  report.checks.push({ name, passed: Boolean(passed) });
  console.log(`${passed ? 'PASS' : 'FAIL'} ${name}`);
  if (!passed) throw new Error(name);
}
try {
  const redirect = await fetch(base.replace('https:', 'http:') + '/app/login', { redirect: 'manual' });
  check('HTTP redirects to the selected HTTPS domain', redirect.status === 301 && redirect.headers.get('location') === base + '/app/login');
  for (const [index, role] of ['technical_admin', 'supervisor'].entries()) {
    const context = await browser.newContext({ locale: 'ru-RU' });
    const page = await context.newPage();
    const socket = { secure: false, welcome: false };
    page.on('pageerror', error => report.page_errors.push({ role, name: error.name }));
    page.on('response', response => { if (response.status() >= 500) report.server_errors.push({ status: response.status(), path: new URL(response.url()).pathname }); });
    page.on('websocket', ws => {
      if (!ws.url().includes('/cable')) return;
      socket.secure = ws.url().startsWith('wss://');
      ws.on('framereceived', frame => {
        try { if (JSON.parse(String(frame.payload)).type === 'welcome') socket.welcome = true; } catch { /* non-JSON keepalive */ }
      });
    });
    await page.goto(base + '/app/login');
    await page.locator('input[placeholder="example@companyname.com"]').fill(accounts[index][1]);
    await page.locator('input[type=password]').fill(accounts[index][2]);
    const pending = page.waitForResponse(r => new URL(r.url()).pathname === '/auth/sign_in' && r.request().method() === 'POST');
    await page.locator('button[type=submit]').click();
    const login = await pending;
    check(role + ' signs in over trusted HTTPS', login.status() === 200);
    const headers = await login.allHeaders();
    const auth = Object.fromEntries(['access-token', 'token-type', 'client', 'expiry', 'uid'].filter(k => headers[k]).map(k => [k, headers[k]]));
    await page.waitForURL('**/app/accounts/**');
    await page.getByRole('button', { name: role === 'technical_admin' ? 'Каналы' : 'Клиенты и назначения', exact: true }).waitFor();
    const access = await fetch(base + '/api/v1/accounts/1/corporate/access', { headers: auth });
    const permissions = await access.json();
    check(role + ' has the expected role', access.status === 200 && permissions.role === role);
    if (process.env.EXPECT_BITRIX === 'true') {
      const directory = await fetch(base + '/api/v1/accounts/1/corporate/crm/employees', { headers: auth });
      if (role === 'supervisor') {
        check('CRM and shared intake enabled', permissions.crm_enabled && permissions.shared_intake_enabled);
        check('Supervisor reads live CRM employee directory', directory.status === 200 && Array.isArray((await directory.json()).employees));
        await page.getByRole('button', { name: 'Клиенты и назначения', exact: true }).click();
        await page.getByRole('heading', { name: 'Сотрудники Битрикс24', exact: true }).waitFor();
        check('CRM employee mapping UI opens on production', true);
      } else {
        check('Technical admin cannot read CRM employee mappings', directory.status === 404);
      }
    }
    if (role === 'technical_admin') {
      await page.getByRole('button', { name: 'Каналы', exact: true }).click();
      await page.getByRole('heading', { name: 'Подключение личного Telegram', exact: true }).waitFor();
      check('Telegram setup opens over HTTPS', true);
    }
    const cookie = (await context.cookies()).find(value => value.name === 'corporate_file_session');
    check(role + ' media cookie is Secure/HttpOnly/Strict', cookie?.secure && cookie.httpOnly && cookie.sameSite === 'Strict');
    for (let attempt = 0; attempt < 40 && !socket.welcome; attempt += 1) await page.waitForTimeout(250);
    check(role + ' ActionCable connects through WSS', socket.secure && socket.welcome);
    await context.close();
  }
  const internal = await fetch(base + '/internal/corporate/outbox');
  check('Internal service API stays closed publicly', internal.status === 404);
  check('No browser or server errors', report.page_errors.length === 0 && report.server_errors.length === 0);
  report.passed = true;
} catch (error) {
  report.passed = false;
  report.error = error.message.slice(0, 180);
  process.exitCode = 1;
} finally {
  report.executed_at = new Date().toISOString();
  fs.writeFileSync(process.env.EXPECT_BITRIX === 'true' ? 'docs/evidence/bitrix-production-browser.json' : 'docs/evidence/server-https-browser.json', JSON.stringify(report, null, 2) + '\n');
  await browser.close();
}
