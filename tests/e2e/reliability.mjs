import fs from 'node:fs';
import { chromium, expect } from '@playwright/test';
const fixture=JSON.parse(fs.readFileSync('secrets/baseline.json','utf8'));
const cases=JSON.parse(fs.readFileSync('.state/reliability-case.json','utf8'));
const password=fs.readFileSync('.env','utf8').match(/^LAB_USER_PASSWORD=(.+)$/m)[1];
const base='http://localhost:8080';
const report={mode:'synthetic-only',checks:[],errors:[]};
const browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
const check=(name,passed)=>{report.checks.push({name,passed:!!passed});console.log(`${passed?'PASS':'FAIL'} ${name}`);if(!passed)throw new Error(name);};
try {
 const context=await browser.newContext({locale:'ru-RU'});
 const page=await context.newPage();
 page.on('pageerror',e=>report.errors.push(e.name+': '+e.message.slice(0,100)));
 await page.goto(base+'/app/login');
 await page.locator('input[placeholder="example@companyname.com"]').fill(fixture.users.A.email);
 await page.locator('input[type=password]').fill(password);
 await page.locator('button[type=submit]').click();
 await page.waitForURL('**/app/accounts/**');
 await page.goto(`${base}/app/accounts/${fixture.account_id}/conversations/${cases.conversation}`);
 await page.getByText(cases.content,{exact:true}).first().waitFor();
 const editButtons=page.getByRole('button',{name:'Редактировать',exact:true});
 check('Manager sees edit control for sent Telegram text',await editButtons.count()>0);
 await editButtons.first().click();
 const input=page.getByRole('textbox',{name:'Новый текст сообщения',exact:true});
 await expect(input).toHaveValue(cases.content);
 await input.fill('Synthetic edited through browser');
 await page.getByRole('button',{name:'Сохранить',exact:true}).click();
 await page.getByText('Synthetic edited through browser',{exact:true}).first().waitFor({timeout:45000});
 check('Browser edit is acknowledged and shown in the same message',true);
 check('User sees the edited marker',await page.getByText('Изменено',{exact:true}).count()>0);
 await page.screenshot({path:'docs/evidence/audit-fixes-editing.png',fullPage:true});
 check('No unhandled browser errors',report.errors.length===0);
 report.passed=true;
} catch(error) {report.passed=false;report.error=error.message;process.exitCode=1;}
finally {report.executed_at=new Date().toISOString();fs.writeFileSync('docs/evidence/audit-fixes-browser.json',JSON.stringify(report,null,2)+'\n');await browser.close();}
