// First-install verification: no customer data, no Telegram authorization calls.
import fs from 'node:fs';
import { chromium } from '@playwright/test';
const matches = [...fs.readFileSync('secrets/server-access.txt', 'utf8').matchAll(/Логин: (.+)\nПароль: (.+)/g)];
if (matches.length !== 2) throw new Error('Private initial access file is missing');
const base = process.env.SERVER_BASE_URL || 'http://localhost:8088';
const report = { checks: [], errors: [], failed_requests: [] };
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
function check(name, passed) {
  report.checks.push({ name, passed: Boolean(passed) });
  console.log(`${passed ? 'PASS' : 'FAIL'} ${name}`);
  if (!passed) throw new Error(name);
}
async function login(index, label) {
  const context = await browser.newContext({ locale: 'ru-RU' });
  const page = await context.newPage();
  page.on('pageerror', error => report.errors.push({ label, name: error.name, message: error.message.slice(0, 160) }));
  page.on('response', response => { if (response.status() >= 400) report.failed_requests.push({ label, status: response.status(), path: new URL(response.url()).pathname }); });
  await page.goto(base + '/app/login');
  await page.locator('input[placeholder="example@companyname.com"]').fill(matches[index][1]);
  await page.locator('input[type=password]').fill(matches[index][2]);
  const pending = page.waitForResponse(response => new URL(response.url()).pathname === '/auth/sign_in' && response.request().method() === 'POST');
  await page.locator('button[type=submit]').click();
  const response = await pending;
  check(label + ' can sign in', response.status() === 200);
  const responseHeaders = await response.allHeaders();
  const headers = Object.fromEntries(['access-token', 'token-type', 'client', 'expiry', 'uid'].filter(k => responseHeaders[k]).map(k => [k, responseHeaders[k]]));
  await page.waitForURL('**/app/accounts/**', { timeout: 45000 });
  return { page, headers };
}
try {
  const technical = await login(0, 'Technical');
  await technical.page.getByRole('button', { name: 'Каналы', exact: true }).click();
  await technical.page.getByText('Telegram ещё не подключён.', { exact: true }).waitFor();
  check('Personal Telegram setup is available and disconnected', true);
  check('API credentials can be entered in the product', await technical.page.getByLabel('API ID', { exact: true }).count() === 1 && await technical.page.getByLabel('API Hash', { exact: true }).count() === 1);
  await technical.page.screenshot({ path: 'docs/evidence/server-telegram-setup.png', fullPage: true });
  const denied = await fetch(base + '/api/v1/accounts/1/contacts', { headers: technical.headers });
  check('Technical role cannot read clients on server', [401, 403, 404].includes(denied.status));
  const supervisor = await login(1, 'Supervisor');
  await supervisor.page.getByRole('button', { name: 'Клиенты и назначения', exact: true }).click();
  await supervisor.page.getByRole('heading', { name: 'Менеджеры', exact: true }).waitFor();
  check('Supervisor can create managers from the product', await supervisor.page.getByRole('button', { name: 'Создать менеджера', exact: true }).count() === 1);
  const contacts = await fetch(base + '/api/v1/accounts/1/contacts', { headers: supervisor.headers });
  const body = await contacts.json();
  check('Clean server has no synthetic customer fixtures', contacts.status === 200 && body.payload?.length === 0);
  const noSecrets = await fetch(base + '/api/v1/accounts/1/corporate/channel', { headers: supervisor.headers });
  check('Supervisor cannot access Telegram authorization', [401, 403, 404].includes(noSecrets.status));
  await supervisor.page.screenshot({ path: 'docs/evidence/server-supervisor.png', fullPage: true });
  check('No unhandled browser errors', report.errors.length === 0);
  report.passed = true;
} catch (error) {
  report.error = error.message.slice(0, 200);
  report.passed = false;
  process.exitCode = 1;
} finally {
  report.executed_at = new Date().toISOString();
  fs.writeFileSync('docs/evidence/server-browser.json', JSON.stringify(report, null, 2) + '\n');
  await browser.close();
}
