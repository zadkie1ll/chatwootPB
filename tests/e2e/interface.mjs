// Synthetic Telegram only. Production verification never sends customer messages.
import fs from 'node:fs';
import { chromium, expect } from '@playwright/test';
const fixture = JSON.parse(fs.readFileSync('secrets/baseline.json', 'utf8'));
const password = fs.readFileSync('.env', 'utf8').match(/^LAB_USER_PASSWORD=(.+)$/m)[1];
const report = { mode: 'synthetic-only', checks: [], errors: [] };
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
const check = (name, passed) => {
  report.checks.push({ name, passed: !!passed });
  console.log(`${passed ? 'PASS' : 'FAIL'} ${name}`);
  if (!passed) throw new Error(name);
};
try {
  const context = await browser.newContext({ locale: 'ru-RU' });
  const page = await context.newPage();
  page.on('pageerror', error => report.errors.push(error.message.slice(0, 160)));
  await page.goto('http://localhost:8080/app/login');
  await page.locator('input[placeholder="example@companyname.com"]').fill(fixture.users.A.email);
  await page.locator('input[type=password]').fill(password);
  await page.locator('button[type=submit]').click();
  await page.waitForURL('**/app/accounts/**');
  await page.getByRole('button', { name: 'Новый диалог Telegram', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Новый диалог Telegram', exact: true });
  await expect(dialog).toBeVisible();
  check('Plus button opens the quick new-chat dialog', true);
  await dialog.getByRole('textbox').fill('+7999' + Date.now().toString().slice(-7));
  await dialog.getByRole('textbox').press('Enter');
  await page.waitForURL('**/conversations/*');
  check('Enter in the new-chat form opens a Telegram conversation', true);
  await expect(page.locator('[data-channel="telegram"]').first()).toBeVisible();
  check('Telegram channel icon is visible', true);
  const editor = page.locator('.reply-box .ProseMirror[contenteditable=true]').first();
  await editor.waitFor();
  const marker = `Synthetic Enter ${Date.now()}`;
  await editor.fill(marker);
  const sent = page.waitForResponse(r => r.request().method() === 'POST' && /\/messages$/.test(new URL(r.url()).pathname));
  await editor.press('Enter');
  const response = await sent;
  check('Enter sends the message without another key', response.status() === 200);
  await expect(editor).toHaveText('');
  await expect(page.getByText(marker, { exact: true }).first()).toBeVisible();
  check('Sent message is visible and the composer is cleared', true);
  let sends = 0;
  page.on('request', request => { if (request.method() === 'POST' && /\/messages$/.test(new URL(request.url()).pathname)) sends++; });
  await editor.fill('Synthetic first line');
  await editor.press('Shift+Enter');
  await editor.pressSequentially('Synthetic second line');
  await page.waitForTimeout(500);
  check('Shift+Enter creates a new line without sending', sends === 0 && (await editor.innerText()).includes('second line'));
  const sentMultiline = page.waitForResponse(r => r.request().method() === 'POST' && /\/messages$/.test(new URL(r.url()).pathname));
  await editor.press('Enter');
  const multiline = await (await sentMultiline).json();
  check('Multiline draft is sent as one message on Enter', multiline.content.includes('first line') && multiline.content.includes('second line'));
  check('Extra send button is hidden in the corporate composer', await page.getByRole('button', { name: /^Отправить/ }).count() === 0);
  await page.getByRole('button', { name: 'AI-инструменты', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Сводка переписки', exact: true })).toBeVisible();
  check('AI menu exposes only conversation summary', await page.getByRole('button', { name: /Improve|Change tone|Ask Copilot|Улучшить|Изменить тон/ }).count() === 0);
  // UI behavior is isolated from a real provider; backend/provider behavior is
  // covered by Rails specs and a separate synthetic production provider probe.
  await page.route('**/corporate/conversations/*/summary', route => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ summary: 'Synthetic appointment summary', truncated: false }) }));
  await page.getByRole('button', { name: 'Сводка переписки', exact: true }).click();
  const summary = page.getByRole('dialog', { name: 'Сводка переписки', exact: true });
  await expect(summary.getByText('Synthetic appointment summary', { exact: true })).toBeVisible();
  check('Summary is displayed in a separate read-only dialog', true);
  check('AI summary is never inserted into the send composer', (await editor.innerText()).trim() === '');
  await summary.getByRole('button', { name: 'Закрыть', exact: true }).click();
  await page.screenshot({ path: 'docs/evidence/interface-2026-11-25.png', fullPage: true });
  check('No unhandled browser errors', report.errors.length === 0);
  report.passed = true;
} catch (error) {
  report.passed = false;
  report.error = error.message.slice(0, 350);
  process.exitCode = 1;
} finally {
  report.executed_at = new Date().toISOString();
  fs.writeFileSync('docs/evidence/interface-2026-11-25.json', JSON.stringify(report, null, 2) + '\n');
  await browser.close();
}
