// No recipient lookup or message is sent; create-chat requests are intercepted.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { chromium } from '@playwright/test';
const base = process.env.SERVER_BASE_URL || 'https://mess.prav-buro.ru:18443';
const pair = [...fs.readFileSync('secrets/managers-20261125-access.txt','utf8').matchAll(/Логин: (.+)\nПароль: (.+)/g)][0];
const browser = await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,...(process.env.TEST_SOCKS_PROXY ? {proxy:{server:process.env.TEST_SOCKS_PROXY}} : {})});
const page = await browser.newPage({locale:'ru-RU'});
const errors=[];page.on('pageerror',e=>errors.push(e.name));
let auth;
const check=(name,value)=>{assert.ok(value,name);console.log('PASS '+name);};
try {
 const welcome=page.waitForEvent('websocket',ws=>new URL(ws.url()).port==='18443');
 await page.goto(base+'/app/login');
 await page.locator('input[placeholder="example@companyname.com"]').fill(pair[1]);
 await page.locator('input[type=password]').fill(pair[2]);
 const signed=page.waitForResponse(r=>new URL(r.url()).pathname==='/auth/sign_in'&&r.request().method()==='POST');
 await page.locator('button[type=submit]').click();
 const response=await signed;check('Reserve login succeeds',response.status()===200);
 const headers=await response.allHeaders();auth=Object.fromEntries(['access-token','token-type','client','expiry','uid'].filter(k=>headers[k]).map(k=>[k,headers[k]]));
 await page.waitForURL('**/app/accounts/**');
 await page.goto(base+'/app/accounts/1/dashboard');
 await page.getByRole('button',{name:'Мои клиенты',exact:true}).waitFor();
 const socket=await welcome;check('Websocket uses reserve port',new URL(socket.url()).port==='18443');
 let requests=[];
 await page.route('**/api/v1/accounts/1/corporate/conversations',route=>{requests.push(route.request().postDataJSON());return route.fulfill({status:422,json:{error:'Synthetic validation probe'}});});
 await page.getByRole('button',{name:'Новый диалог',exact:true}).click();
 const dialog=page.getByRole('dialog');const input=dialog.locator('input');
 await dialog.locator('select').selectOption('max');
 await input.fill('8 (999) 123-45-67');check('Pasted 8 becomes formatted +7',await input.inputValue()==='+7 (999) 123-45-67');
 await dialog.locator('button[type=submit]').click();await page.waitForFunction(()=>document.body.textContent.includes('Synthetic validation probe'));
 check('MAX request contains normalized phone',requests[0]?.phone==='+79991234567'&&requests[0]?.channel==='max');
 await input.fill('+7 (999) 123-45-6');await dialog.locator('button[type=submit]').click();check('Incomplete phone blocked before lookup',requests.length===1);
 await dialog.locator('select').selectOption('telegram');await input.fill('https://t.me/sample_user');await dialog.locator('button[type=submit]').click();
 await page.waitForTimeout(200);check('Telegram link becomes username',requests[1]?.phone==='@sample_user');
 check('No JavaScript errors',errors.length===0);
} finally {
 if(auth){const result=await page.request.delete(base+'/auth/sign_out',{headers:auth});check('Probe session revoked',result.status()===200);}
 await browser.close();
}
