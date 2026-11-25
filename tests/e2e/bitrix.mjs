import fs from 'node:fs';
import { chromium, expect } from '@playwright/test';
const fixture = JSON.parse(fs.readFileSync('secrets/baseline.json', 'utf8'));
const cases = JSON.parse(fs.readFileSync('.state/bitrix-case.json', 'utf8'));
const password = fs.readFileSync('.env', 'utf8').match(/^LAB_USER_PASSWORD=(.+)$/m)[1];
const base = 'http://localhost:8080';
const report = { mode: 'synthetic-crm', checks: [], errors: [] };
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
const check = (name, passed) => { report.checks.push({ name, passed: Boolean(passed) }); console.log(`${passed ? 'PASS' : 'FAIL'} ${name}`); if (!passed) throw new Error(name); };
async function login(label) {
  const context = await browser.newContext({ locale: 'ru-RU' });
  const page = await context.newPage();
  page.on('pageerror', error => report.errors.push({ label, name: error.name, message: error.message.slice(0, 120) }));
  await page.goto(base + '/app/login');
  await page.locator('input[placeholder="example@companyname.com"]').fill(fixture.users[label].email);
  await page.locator('input[type=password]').fill(password);
  await page.locator('button[type=submit]').click();
  await page.waitForURL('**/app/accounts/**');
  return page;
}
try {
  const supervisor = await login('R');
  await supervisor.getByRole('button', { name: 'Клиенты и назначения', exact: true }).click();
  const mapping = supervisor.locator('section').filter({ has: supervisor.getByRole('heading', { name: 'Сотрудники Битрикс24', exact: true }) }).last();
  const select = mapping.getByLabel('Сотрудник Битрикс24 для Lab A', { exact: true });
  await select.waitFor();
  await expect(select).toHaveValue('11');
  const row = mapping.locator('li').filter({ hasText: 'Lab A' });
  const [saved] = await Promise.all([
    supervisor.waitForResponse(response => response.request().method() === 'PUT' && new URL(response.url()).pathname.endsWith('/corporate/crm/employees/' + fixture.users.A.id)),
    row.getByRole('button', { name: 'Связать сотрудника', exact: true }).click(),
  ]);
  check('Supervisor maps employee through the product UI', saved.status() === 204);
  const manager = await login('A');
  await manager.goto(`${base}/app/accounts/${fixture.account_id}/conversations/${cases.browser}`);
  await manager.getByText('Общий входящий: номер пока неизвестен. Все менеджеры видят этот чат и могут отвечать. После привязки останутся ответственный и руководитель.', { exact: true }).waitFor();
  check('Shared conversation has the identification banner', true);
  const phone = manager.getByLabel('Телефон клиента', { exact: true });
  await phone.fill('89991234567');
  await expect(phone).toHaveValue('+7 (999) 123-45-67');
  check('Phone input formats a pasted Russian phone automatically', true);
  await manager.getByLabel('Ссылка на сделку или лид', { exact: true }).fill('https://synthetic.bitrix24.test:8443/crm/deal/details/701/');
  await manager.getByRole('button', { name: 'Связать со сделкой', exact: true }).click();
  await manager.getByText('Сделка и ссылки синхронизированы', { exact: true }).waitFor({ timeout: 45000 });
  check('Manager links a deal from the conversation banner', true);
  check('Bound chat no longer displays shared access banner', await manager.getByText('Общий входящий: номер пока неизвестен. Все менеджеры видят этот чат и могут отвечать. После привязки останутся ответственный и руководитель.', { exact: true }).count() === 0);
  const response = await fetch(`${base}/api/v1/accounts/${fixture.account_id}/conversations/${cases.browser}/messages`, { headers: { Authorization: `Bearer ${fixture.users.B.token}` } });
  check('Another manager cannot use the bound direct conversation URL', [401, 403, 404].includes(response.status));
  await manager.screenshot({ path: 'docs/evidence/bitrix-conversation.png', fullPage: true });
  check('No unhandled browser errors in CRM UI', report.errors.length === 0);
  report.passed = true;
} catch (error) {
  report.passed = false; report.error = error.message.slice(0, 250); process.exitCode = 1;
} finally {
  report.executed_at = new Date().toISOString();
  fs.writeFileSync('docs/evidence/bitrix-browser.json', JSON.stringify(report, null, 2) + '\n');
  await browser.close();
}
