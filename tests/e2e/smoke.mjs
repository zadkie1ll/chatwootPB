import { chromium } from '@playwright/test';
import fs from 'node:fs';
const fixture = JSON.parse(fs.readFileSync('secrets/baseline.json', 'utf8'));
const password = fs.readFileSync('.env', 'utf8').match(/^LAB_USER_PASSWORD=(.+)$/m)[1];
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
const report = { checks: [], errors: [], failed_requests: [] };
const contexts = [];
const base = 'http://localhost:8080';
const check = (name, passed) => { report.checks.push({ name, passed }); console.log(`${passed ? 'PASS' : 'FAIL'} ${name}`); };
async function login(label) {
  const context = await browser.newContext({ locale: 'ru-RU' });
  contexts.push(context);
  const page = await context.newPage();
  page.on('response', response => { if (response.status() >= 400) report.failed_requests.push({ label, status: response.status(), path: new URL(response.url()).pathname }); });
  page.on('pageerror', error => report.errors.push({ label, name: error.name, message: error.message.slice(0, 160) }));
  await page.goto(`${base}/app/login`);
  await page.locator('input[placeholder="example@companyname.com"]').fill(fixture.users[label].email);
  await page.locator('input[type=password]').fill(password);
  await page.locator('button[type=submit]').click();
  await page.waitForURL('**/app/accounts/**', { timeout: 30000 });
  return page;
}
let restored = false;
try {
  const manager = await login('A');
  await manager.getByRole('button', { name: 'Мои клиенты', exact: true }).click();
  await manager.getByRole('button', { name: 'Synthetic Client X', exact: true }).waitFor();
  check('Manager UI lists own client only', await manager.getByRole('button', { name: 'Synthetic Client Y', exact: true }).count() === 0);
  await manager.screenshot({ path: 'docs/evidence/ui-manager.png', fullPage: true });
  await manager.getByRole('button', { name: 'Synthetic Client X', exact: true }).click();
  await manager.waitForTimeout(1500);
  const supervisor = await login('R');
  await supervisor.getByRole('button', { name: 'Клиенты и назначения', exact: true }).click();
  await supervisor.getByRole('button', { name: 'Synthetic Client X', exact: true }).waitFor();
  check('Supervisor UI includes A and B clients', await supervisor.getByRole('button', { name: 'Synthetic Client Y', exact: true }).count() === 1);
  await supervisor.screenshot({ path: 'docs/evidence/ui-supervisor.png', fullPage: true });
  await supervisor.getByLabel('Ответственный', { exact: false }).selectOption('unassigned');
  await supervisor.getByRole('button', { name: 'Synthetic Client X', exact: true }).waitFor({ state: 'detached' });
  await supervisor.getByRole('button', { name: 'Synthetic Client Z', exact: true }).waitFor();
  check('Supervisor can filter neutral clients', await supervisor.getByRole('button', { name: 'Synthetic Client X', exact: true }).count() === 0);
  await supervisor.getByLabel('Ответственный', { exact: false }).selectOption('');
  await supervisor.getByRole('button', { name: 'Synthetic Client X', exact: true }).waitFor();
  const employee = `Browser manager ${Date.now()}`;
  await supervisor.getByLabel('Имя менеджера', { exact: true }).fill(employee);
  await supervisor.getByLabel('Email для входа', { exact: true }).fill(`browser-${Date.now()}@example.invalid`);
  await supervisor.getByLabel('Начальный пароль (не менее 12 символов)', { exact: true }).fill('SyntheticBrowserPassword12!');
  await supervisor.getByRole('button', { name: 'Создать менеджера', exact: true }).click();
  await supervisor.getByText('Менеджер создан. Передайте ему адрес приложения, email и заданный пароль.', { exact: true }).waitFor();
  check('Supervisor creates manager through UI', true);
  const employeeRow = supervisor.locator('li').filter({ hasText: employee });
  supervisor.once('dialog', dialog => dialog.accept());
  await employeeRow.getByRole('button', { name: 'Отключить доступ', exact: true }).click();
  await employeeRow.getByText('Доступ отключён', { exact: true }).waitFor();
  check('Supervisor disables manager through UI', true);
  const row = supervisor.locator('li').filter({ has: supervisor.getByRole('button', { name: 'Synthetic Client X', exact: true }) });
  await row.locator('select').selectOption(String(fixture.users.B.id));
  await supervisor.getByLabel('Причина назначения или передачи').fill('Synthetic browser transfer');
  await row.getByRole('button', { name: 'Назначить / передать', exact: true }).click();
  await supervisor.getByText('Назначение клиента обновлено.', { exact: true }).waitFor();
  await manager.waitForTimeout(2500);
  check('Previous manager browser clears client content', !(await manager.locator('body').innerText()).includes('Synthetic baseline message X'));
  const technical = await login('T');
  await technical.waitForURL('**/settings/inboxes**', { timeout: 30000 });
  check('Technical UI opens channel settings', technical.url().includes('/settings/inboxes'));
  await technical.screenshot({ path: 'docs/evidence/ui-technical.png', fullPage: true });
  await technical.getByRole('button', { name: 'Каналы', exact: true }).click();
  await technical.getByRole('heading', { name: 'Подключение личного Telegram', exact: true }).waitFor();
  await technical.getByText('Тестовый режим: настоящие сообщения не отправляются.', { exact: true }).waitFor();
  check('Technical UI opens Telegram connection status', true);
  check('No unhandled JavaScript errors', report.errors.length === 0);
} catch (error) {
  report.error = error.message.slice(0, 250);
  console.error(error.name, report.error);
  for (let i = 0; i < contexts.length; i += 1) {
    const page = contexts[i].pages()[0];
    if (page) await page.screenshot({ path: `docs/evidence/ui-failure-${i}.png`, fullPage: true }).catch(() => {});
  }
} finally {
  const response = await fetch(`${base}/api/v1/accounts/${fixture.account_id}/corporate/ownerships/${fixture.contacts.X}`, {
    method: 'PUT', headers: { Authorization: `Bearer ${fixture.users.R.token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ owner_id: fixture.users.A.id, reason: 'Restore browser fixture' }),
  });
  restored = response.ok;
  report.fixture_restored = restored;
  report.executed_at = new Date().toISOString();
  report.passed = !report.error && restored && report.checks.every(item => item.passed);
  fs.writeFileSync('docs/evidence/stage-2-browser.json', `${JSON.stringify(report, null, 2)}\n`);
  await browser.close();
  if (!report.passed) process.exitCode = 1;
}
