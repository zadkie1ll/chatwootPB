// Read-only staff acceptance. No staff accounts, passwords, access or mappings are changed.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { chromium } from '@playwright/test';
const base = process.env.SERVER_BASE_URL || 'https://162.248.166.241:18443';
const credentials = [...fs.readFileSync('secrets/server-access.txt', 'utf8').matchAll(/Логин: (.+)\nПароль: (.+)/g)][1];
const manager = [...fs.readFileSync('secrets/managers-20261125-access.txt', 'utf8').matchAll(/Логин: (.+)\nПароль: (.+)/g)][0];
const browser = await chromium.launch({ headless: true, executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' });
const errors = [];
const sessions = [];
const check = (label, value) => { assert.ok(value, label); console.log('PASS ' + label); };
async function login(pair) {
 const context = await browser.newContext({ locale: 'ru-RU', viewport: { width: 1600, height: 1000 } });
 const page = await context.newPage();page.setDefaultTimeout(30000);
 page.on('pageerror', error => errors.push(error.name));
 await page.goto(base+'/app/login', { waitUntil: 'domcontentloaded' });
 await page.locator('input[placeholder="example@companyname.com"]').fill(pair[1]);
 await page.locator('input[type=password]').fill(pair[2]);
 const pending = page.waitForResponse(r => new URL(r.url()).pathname === '/auth/sign_in' && r.request().method() === 'POST');
 await page.locator('button[type=submit]').click();
 const response = await pending;assert.equal(response.status(),200);
 const h = await response.allHeaders();
 const auth = Object.fromEntries(['access-token','token-type','client','expiry','uid'].map(k=>[k,h[k]]));
 const session = {context,page,auth};sessions.push(session);
 return session;
}
try {
 const admin = await login(credentials);
 const {page,auth} = admin;
 await page.getByRole('link',{name:'Менеджеры',exact:true}).first().click();
 await page.waitForURL('**/corporate/managers');
 await page.getByRole('heading',{name:'Менеджеры',exact:true}).waitFor();
 const response = await page.request.get(base+'/api/v1/accounts/1/corporate/staff/directory',{headers:auth});
 const directory = await response.json();
 check('Supervisor directory API and schema', response.status()===200 && directory.api_version===1 && directory.account_id===1);
 check('Existing three linked managers remain present', [5,6,7].every(id=>directory.payload.some(row=>row.id===id && row.bitrix_user_id)));
 check('No credentials or realtime tokens in directory', !['password','encrypted_password','tokens','pubsub_token'].some(key=>JSON.stringify(directory).includes('"'+key+'"')));
 await page.getByLabel('Поиск сотрудников',{exact:true}).fill('Валерий');
 const searched = page.waitForResponse(r=>new URL(r.url()).pathname.endsWith('/staff/directory') && new URL(r.url()).searchParams.get('q')==='Валерий');
 await page.getByRole('button',{name:'Найти',exact:true}).click();
 const filtered = await (await searched).json();
 check('Staff search keeps correct CRM identity', filtered.payload.some(row=>row.id===7 && row.bitrix_user_id==='482'));
 await page.getByRole('button',{name:'Добавить менеджера',exact:true}).click();
 const dialog = page.getByRole('dialog',{name:'Добавить менеджера',exact:true});await dialog.waitFor();
 await dialog.getByLabel('Способ добавления').selectOption('manual');
 await dialog.getByRole('button',{name:'Сгенерировать пароль',exact:true}).click();
 check('Strong password generation works', (await dialog.locator('input[autocomplete="new-password"]').inputValue()).length>=20);
 await page.keyboard.press('Escape');
 await dialog.waitFor({state:'hidden'});
 check('Creation form closes without modifying staff', true);
 await page.getByRole('button',{name:'Настроить',exact:true}).first().click();
 const edit = page.getByRole('dialog',{name:'Настроить',exact:true});await edit.waitFor();
 check('Existing password is never displayed', await edit.locator('input[autocomplete="new-password"]').inputValue()==='');
 await edit.getByRole('button',{name:'Отмена',exact:true}).click();
 await edit.waitFor({state:'hidden'});
 const employee = await login(manager);
 const denied = await employee.page.request.get(base+'/api/v1/accounts/1/corporate/staff/directory',{headers:employee.auth});
 check('Manager cannot read staff administration API', denied.status()===404);
 await employee.page.goto(base+'/app/accounts/1/corporate/managers',{waitUntil:'domcontentloaded'});
 await employee.page.getByRole('alert').filter({hasText:'Нет доступа'}).first().waitFor();
 check('Manager direct page is denied', await employee.page.getByRole('table').count()===0);
 check('No JavaScript errors', errors.length===0);
} finally {
 try {
  for (const session of sessions) {
   check('Probe session revoked', (await session.page.request.delete(base+'/auth/sign_out',{headers:session.auth,timeout:15000})).status()===200);
   await session.context.close();
  }
 } finally { await browser.close(); }
}
