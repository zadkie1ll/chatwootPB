// Changes only the testing manager's display scale, restoring it in finally.
// No messages, edits, recipient lookups or sharing changes are sent.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { chromium } from '@playwright/test';
const base = process.env.SERVER_BASE_URL || 'https://162.248.166.241:18443';
const pair = [...fs.readFileSync('secrets/managers-20261125-access.txt', 'utf8').matchAll(/Логин: (.+)\nПароль: (.+)/g)][0];
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
const page = await browser.newPage({ locale: 'ru-RU', viewport: { width: 1600, height: 1000 } });
page.setDefaultTimeout(25000);
const errors = [];
page.on('pageerror', error => errors.push(error.name));
const check = (label, value) => { assert.ok(value, label); console.log('PASS ' + label); };
let auth, original;
try {
  await page.goto(base + '/app/login', { waitUntil: 'domcontentloaded' });
  await page.locator('input[placeholder="example@companyname.com"]').fill(pair[1]);
  await page.locator('input[type=password]').fill(pair[2]);
  const signed = page.waitForResponse(response => new URL(response.url()).pathname === '/auth/sign_in' && response.request().method() === 'POST');
  await page.locator('button[type=submit]').click();
  const response = await signed;
  check('Manager login succeeds', response.status() === 200);
  const h = await response.allHeaders();
  auth = Object.fromEntries(['access-token', 'token-type', 'client', 'expiry', 'uid'].map(key => [key, h[key]]));
  await page.getByRole('button', { name: 'Мои клиенты', exact: true }).waitFor();
  const select = page.getByRole('combobox', { name: 'Масштаб', exact: true });
  original = await select.inputValue();
  for (const scale of ['65', '85', '100', '120']) {
    const saved = page.waitForResponse(response => new URL(response.url()).pathname === '/api/v1/profile' && response.request().method() === 'PUT');
    await select.selectOption(scale);
    check('Scale saved: ' + scale, (await saved).status() === 200);
    await page.waitForFunction(value => document.documentElement.dataset.interfaceScale === String(Number(value) / 100), scale);
    const dimensions = await page.locator('#app.flex').evaluate(element => {
      const rect = element.getBoundingClientRect();
      return { height: rect.height, viewport: innerHeight, width: document.body.getBoundingClientRect().width, viewportWidth: innerWidth };
    });
    check('Dashboard fills viewport at ' + scale, Math.abs(dimensions.height - dimensions.viewport) < 2 && dimensions.width <= dimensions.viewportWidth + 2);
    const mine = await page.getByRole('button', { name: 'Мои клиенты', exact: true }).boundingBox();
    const absence = await page.getByRole('button', { name: /Открыть мои чаты всем|Закрыть доступ на время отсутствия/ }).boundingBox();
    check('Absence control stays to the right at ' + scale, absence.x > mine.x + mine.width);
    await page.getByRole('button', { name: 'Новый диалог', exact: true }).click();
    const dialog = page.getByRole('dialog');
    await dialog.waitFor();
    const rect = await dialog.boundingBox();
    check('New-chat dialog fits viewport at ' + scale, rect.x >= 0 && rect.y >= 0 && rect.x + rect.width <= 1601 && rect.y + rect.height <= 1001);
    await page.keyboard.press('Escape');
    await dialog.waitFor({ state: 'hidden' });
  }
  await page.reload({ waitUntil: 'domcontentloaded' });
  await select.waitFor();
  check('Scale survives reload', await select.inputValue() === '120');
  await page.goto(base + '/app/accounts/1/conversations/13', { waitUntil: 'domcontentloaded' });
  const edit = page.getByRole('button', { name: 'Редактировать', exact: true }).last();
  await edit.waitFor();
  const layout = await edit.evaluate(button => {
    const tools = button.parentElement;
    const bubble = tools.previousElementSibling;
    return { toolsTop: tools.getBoundingClientRect().top, bubbleBottom: bubble.getBoundingClientRect().bottom };
  });
  check('Edit control is below the bubble', layout.toolsTop >= layout.bubbleBottom - 1);
  check('No JavaScript errors', errors.length === 0);
} finally {
  try {
    if (auth) {
      try {
        if (original) {
          const saved = page.waitForResponse(response => new URL(response.url()).pathname === '/api/v1/profile' && response.request().method() === 'PUT');
          await page.getByRole('combobox', { name: 'Масштаб', exact: true }).selectOption(original);
          check('Original scale saved', (await saved).status() === 200);
          check('Original scale restored', await page.getByRole('combobox', { name: 'Масштаб', exact: true }).inputValue() === original);
        }
      } finally {
        check('Probe session revoked', (await page.request.delete(base + '/auth/sign_out', { headers: auth, timeout: 15000 })).status() === 200);
      }
    }
  } finally {
    await browser.close();
  }
}
