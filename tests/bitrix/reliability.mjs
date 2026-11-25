import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
const fixture = JSON.parse(fs.readFileSync('secrets/baseline.json', 'utf8'));
const base = `http://localhost:8080/api/v1/accounts/${fixture.account_id}`;
const checks = [];
const report = { mode: 'synthetic-only-verified-tls', checks };
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
function check(name, passed) {
  checks.push({ name, passed: !!passed });
  console.log(`${passed ? 'PASS' : 'FAIL'} ${name}`);
  if (!passed) throw new Error(name);
}
async function api(method, path, label='A', body) {
  const form = body instanceof FormData;
  const r = await fetch(base + path, { method, headers: { Authorization: `Bearer ${fixture.users[label].token}`, ...(form ? {} : {'Content-Type':'application/json'}) },
    body: body === undefined ? undefined : form ? body : JSON.stringify(body), signal: AbortSignal.timeout(65000) });
  return { status: r.status, data: await r.json().catch(() => null) };
}
function internal(service, code, data) {
  const r = spawnSync('bash', ['scripts/compose.sh','-f','compose.yaml','-f','infra/compose.bitrix-test.yaml','exec','-T',service,'python','-c',code],
    { input: data === undefined ? undefined : JSON.stringify(data), encoding: 'utf8' });
  if (r.status) throw new Error('Synthetic internal operation failed: ' + r.stderr.slice(-300));
  return JSON.parse(r.stdout);
}
function inject(event) {
  return internal('telegram-gateway','import os,sys,urllib.request; assert os.environ["TELEGRAM_MODE"]=="mock"; r=urllib.request.Request("http://127.0.0.1:8091/test/incoming",data=sys.stdin.buffer.read(),headers={"Authorization":"Bearer "+os.environ["GATEWAY_TOKEN"],"Content-Type":"application/json"}); print(urllib.request.urlopen(r).read().decode())',event);
}
const state = () => internal('integration-worker','import json,urllib.request; print(urllib.request.urlopen("https://synthetic.bitrix24.test:8443/test/state").read().decode())');
async function until(fn) {
  for (let n=0;n<120;n++) { const value=await fn(); if(value)return value; await pause(500); }
  throw new Error('Synthetic pipeline timed out');
}
const messages = async (id,label='A') => (await api('GET',`/conversations/${id}/messages`,label)).data?.payload || [];
const fileGet = (id,label='A') => fetch(`http://localhost:8080/api/v1/corporate_files/${id}`,{headers:{Authorization:`Bearer ${fixture.users[label].token}`}});
try {
  check('Mock mode explicitly selected', (await api('GET','/corporate/access')).data.gateway_mode==='mock');
  const suffix=String(Date.now()).slice(-8);
  const phone='+799'+suffix;
  const peer=phone.slice(1);
  const opened=await api('POST','/corporate/conversations','A',{channel:'telegram',phone});
  check('New outbound chat created',opened.status===200);
  const id=opened.data.conversation_id;
  const posted=await api('POST',`/conversations/${id}/messages`,'A',{content:'Synthetic reliable outgoing'});
  const sent=await until(async()=>(await messages(id)).find(m=>m.id===posted.data.id&&m.content_attributes.corporate_delivery==='sent'));
  const edited=await api('PUT',`/corporate/conversations/${id}/messages/${sent.id}/edit`,'A',{content:'Synthetic edited in application'});
  check('Editing is accepted as a separate operation',edited.status===202);
  const changed=await until(async()=>(await messages(id)).find(m=>m.id===sent.id&&m.content==='Synthetic edited in application'&&m.content_attributes.corporate_edit_status==='sent'));
  check('Edit preserves the Telegram message id and creates no new message',changed.source_id===sent.source_id&&(await messages(id)).filter(m=>m.source_id===sent.source_id).length===1);
  inject({external_user_id:peer,external_message_id:sent.source_id,direction:'outgoing',event_type:'edited',revision:new Date().toISOString(),text:'Synthetic edit from official client'});
  await until(async()=>(await messages(id)).some(m=>m.id===sent.id&&m.content==='Synthetic edit from official client'));
  check('Official Telegram edit is not discarded as echo',true);
  const first={external_user_id:peer,external_message_id:String(Date.now()),text:'Synthetic duplicated incoming'};
  inject(first); inject(first);
  await until(async()=>(await messages(id)).some(m=>m.source_id===first.external_message_id));
  check('Ordinary incoming text is stored exactly once',(await messages(id)).filter(m=>m.source_id===first.external_message_id).length===1);
  const files=[
    {name:'synthetic.pdf',type:'application/pdf',data:fs.readFileSync('chatwoot/spec/fixtures/files/sample.pdf')},
    {name:'synthetic.png',type:'image/png',data:Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=','base64')},
    {name:'synthetic.ogg',type:'audio/ogg',data:fs.readFileSync('chatwoot/spec/assets/sample.ogg'),voice:true},
  ];
  for (const [index,file] of files.entries()) {
    const external=String(Date.now()+index+1);
    const event={external_user_id:peer,external_message_id:external,text:'Synthetic media '+file.name,attachment_state:'pending',media_id:external};
    inject(event);
    const envelope=await until(async()=>(await messages(id)).find(m=>m.source_id===external));
    check(file.name+' envelope is visible before media',envelope.content===event.text&&envelope.content_attributes.corporate_media_state==='pending');
    inject({...event,event_type:'media',source_revision:'',revision:'/media',attachment_state:'ready',voice:!!file.voice,
      fixture_files:[{filename:file.name,content_type:file.type,data:file.data.toString('base64')}]});
    const ready=await until(async()=>(await messages(id)).find(m=>m.source_id===external&&m.attachments?.length===1));
    const downloaded=await fileGet(ready.attachments[0].id);
    check(file.name+' is delivered and protected download matches original bytes',downloaded.status===200&&Buffer.from(await downloaded.arrayBuffer()).equals(file.data));
    check(file.name+' stays inaccessible to another manager',(await fileGet(ready.attachments[0].id,'B')).status===404);
    if(file.voice)check('Voice metadata survives the pipeline',ready.attachments[0].file_type==='audio'&&ready.attachments[0].meta?.is_voice_message===true);
  }
  const note=new FormData();note.set('content','Preserved synthetic unsafe note');note.set('private','true');
  note.append('attachments[]',new Blob(['EICAR-STANDARD-ANTIVIRUS-TEST-FILE'],{type:'text/plain'}),'synthetic-av.txt');
  const unsafe=await api('POST',`/conversations/${id}/messages`,'A',note);
  check('Private note accepted into quarantine',unsafe.status===200);
  const rejected=await until(async()=>(await messages(id)).find(m=>m.id===unsafe.data.id&&m.content_attributes.corporate_attachments_state==='rejected'));
  check('Rejected note file remains locked while its text is preserved',(await fileGet(rejected.attachments[0].id)).status===423&&rejected.content==='Preserved synthetic unsafe note');
  const leadOpened=await api('POST','/corporate/conversations','A',{channel:'telegram',phone:'+79990000111'});
  check('Lead customer chat opened',leadOpened.status===200);
  const leadId=leadOpened.data.conversation_id;
  const link=await until(async()=>{const r=await api('GET',`/corporate/crm/conversations/${leadId}`);return r.data?.state==='applied'&&r.data;});
  check('Last open lead is selected when no deal exists',link.entity_type==='lead'&&link.deal_id==='901');
  const crm=state();
  check('Lead Messenger URL points at protected Telegram chat',crm.leads['901'].UF_CRM_CW_MESSENGER===`http://localhost:8080/app/accounts/${fixture.account_id}/conversations/${leadId}?messenger=Telegram`);
  internal('integration-worker','import urllib.request,json; r=urllib.request.Request("https://synthetic.bitrix24.test:8443/test/convert",data=b"{}"); print(urllib.request.urlopen(r).read().decode())');
  internal('integration-worker','import os,django,json; os.environ.setdefault("DJANGO_SETTINGS_MODULE","config.settings"); django.setup(); from crm.reconcile import reconcile_batch; print(json.dumps({"cursor":reconcile_batch()}))');
  const converted=await until(async()=>{const r=await api('GET',`/corporate/crm/conversations/${leadId}`,'B');return r.data?.state==='applied'&&r.data?.entity_type==='deal'&&r.data;});
  check('Converted lead follows its deal and new manager',converted.deal_id==='903'&&converted.deal_url.endsWith('/crm/deal/details/903/'));
  check('Old manager loses the converted customer chat',[401,403,404].includes((await api('GET',`/conversations/${leadId}/messages`)).status));
  check('Supervisor retains access to converted customer',(await api('GET',`/conversations/${leadId}/messages`,'R')).status===200);
  check('Deal Messenger field has the same protected chat URL',state().deals['903'].UF_CRM_CW_MESSENGER===crm.leads['901'].UF_CRM_CW_MESSENGER);
  const health=await api('GET','/corporate/health','R');
  check('Supervisor can inspect pipeline health without customer content',health.status===200&&health.data.telegram.connected&&health.data.workers.delivery.healthy);
  check('Manager cannot inspect account-wide pipeline health',(await api('GET','/corporate/health')).status===404);
  fs.writeFileSync('.state/reliability-case.json',JSON.stringify({conversation:id,message:sent.id,content:'Synthetic edit from official client',leadConversation:leadId}));
  report.passed=true;
} catch(error) {
  report.passed=false;report.error=error.message;process.exitCode=1;
} finally {
  report.executed_at=new Date().toISOString();
  fs.writeFileSync('docs/evidence/audit-fixes-integration.json',JSON.stringify(report,null,2)+'\n');
}
