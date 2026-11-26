// UI-only authentication simulation. No MAX requests or real QR credentials.
import fs from 'node:fs';
import { chromium, expect } from '@playwright/test';
const fixture = JSON.parse(fs.readFileSync('secrets/baseline.json', 'utf8'));
const password = fs.readFileSync('.env', 'utf8').match(/^LAB_USER_PASSWORD=(.+)$/m)[1];
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
const report = { mode: 'synthetic-max-auth-only', checks: [], errors: [] };
const check = (name, passed) => {
  report.checks.push({ name, passed: !!passed });
  console.log(`${passed ? 'PASS' : 'FAIL'} ${name}`);
  if (!passed) throw new Error(name);
};
try {
  const context = await browser.newContext({ locale: 'ru-RU' });
  const page = await context.newPage();
  page.on('pageerror', error => report.errors.push(error.message.slice(0, 120)));
  let current = 'disconnected';
  let passwordReceived = false;
  const attempt = 'synthetic-attempt';
  const image = 'data:image/svg+xml;base64,' + Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="white"/><text x="2" y="30">TEST</text></svg>').toString('base64');
  const snapshot = () => ({ status: current, attempt_id: attempt, qr_image: current === 'qr_required' ? image : null, connected: current === 'connected', poc_only: true });
  await page.route('**/corporate/max_channel', route => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(snapshot()) }));
  await page.route('**/corporate/max_channel/connect', async route => {
    const data = route.request().postDataJSON();
    if (data.step === 'start') current = 'qr_required';
    if (data.step === 'password') {
      passwordReceived = data.password === 'SyntheticPassword' && data.attempt_id === attempt && !route.request().url().includes('SyntheticPassword');
      current = 'connected';
    }
    if (data.step === 'cancel') current = 'disconnected';
    await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(snapshot()) });
  });
  await page.goto('http://localhost:8080/app/login');
  await page.locator('input[placeholder="example@companyname.com"]').fill(fixture.users.T.email);
  await page.locator('input[type=password]').fill(password);
  await page.locator('button[type=submit]').click();
  await page.waitForURL('**/app/accounts/**');
  await page.getByRole('button', { name: 'Каналы', exact: true }).click();
  const panel = page.getByRole('region', { name: 'Подключение личного MAX', exact: true });
  await expect(panel).toBeVisible();
  check('Technical admin sees a separate MAX pilot section', true);
  await panel.getByRole('button', { name: 'Показать QR для MAX', exact: true }).click();
  await expect(panel.getByRole('img', { name: 'Приватный QR-код входа в MAX', exact: true })).toBeVisible();
  check('Start action displays a locally rendered private QR image', true);
  current = 'password_required';
  const input = panel.getByLabel('Пароль дополнительной защиты MAX');
  await input.waitFor({ timeout: 10000 });
  await input.fill('SyntheticPassword');
  await page.waitForTimeout(5400);
  await expect(input).toHaveValue('SyntheticPassword');
  check('Status polling does not erase the password being typed', true);
  await input.press('Enter');
  await expect(panel.getByText('MAX подключён', { exact: true })).toBeVisible();
  check('2FA submits in POST body with its current login attempt', passwordReceived);
  check('QR and password input disappear after authentication', await panel.locator('input[type=password]').count() === 0 && await panel.getByRole('img').count() === 0);
  await panel.getByRole('button', { name: 'Отключить MAX', exact: true }).click();
  await expect(panel.getByRole('button', { name: 'Показать QR для MAX', exact: true })).toBeVisible();
  check('Operator can stop the pilot connection', true);
  const denied = await fetch(`http://localhost:8080/api/v1/accounts/${fixture.account_id}/corporate/max_channel`, { headers: { Authorization: `Bearer ${fixture.users.A.token}` } });
  check('Manager cannot access real MAX connection API', [401, 403, 404].includes(denied.status));
  check('Browser produced no JavaScript errors', report.errors.length === 0);
  report.passed = true;
} catch (error) {
  report.passed = false;
  report.error = error.message.slice(0, 350);
  process.exitCode = 1;
} finally {
  report.executed_at = new Date().toISOString();
  fs.writeFileSync('docs/evidence/max-auth-browser-2026-11-25.json', JSON.stringify(report, null, 2) + '\n');
  await browser.close();
}
