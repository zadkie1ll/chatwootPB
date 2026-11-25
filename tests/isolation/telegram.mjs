// Synthetic full-stack integration. The gateway must explicitly be in mock mode.
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const fixture = JSON.parse(fs.readFileSync('secrets/baseline.json', 'utf8'));
const base = `http://localhost:8080/api/v1/accounts/${fixture.account_id}`;
const checks = [];
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const check = (name, passed) => {
  checks.push({ name, passed: Boolean(passed) });
  console.log(`${passed ? 'PASS' : 'FAIL'} ${name}`);
  if (!passed) throw new Error(name);
};
async function request(method, path, user, body) {
  const form = body instanceof FormData;
  const response = await fetch(base + path, {
    method, headers: { Authorization: `Bearer ${fixture.users[user].token}`, ...(form ? {} : { 'Content-Type': 'application/json' }) },
    body: body === undefined ? undefined : form ? body : JSON.stringify(body), signal: AbortSignal.timeout(20000),
  });
  return { status: response.status, data: await response.json().catch(() => null) };
}
function inject(event) {
  const result = spawnSync('bash', ['scripts/compose.sh', 'exec', '-T', 'telegram-gateway', 'python', '-c',
    'import json,os,sys,urllib.request; assert os.environ["TELEGRAM_MODE"]=="mock"; data=sys.stdin.buffer.read(); req=urllib.request.Request("http://127.0.0.1:8091/test/incoming",data=data,headers={"Authorization":"Bearer "+os.environ["GATEWAY_TOKEN"],"Content-Type":"application/json"}); print(urllib.request.urlopen(req).status)'],
  { input: JSON.stringify(event), encoding: 'utf8' });
  if (result.status || !result.stdout.includes('200')) throw new Error('Mock injection failed');
}
async function messages(id, user = 'A') {
  const response = await request('GET', `/conversations/${id}/messages`, user);
  if (response.status !== 200) throw new Error('Message listing failed');
  return response.data.payload;
}
async function until(callback) {
  for (let i = 0; i < 60; i += 1) {
    const result = await callback();
    if (result) return result;
    await pause(500);
  }
  throw new Error('Timed out awaiting durable delivery');
}
const suffix = String(Date.now()).slice(-8);
const phone = '+799' + suffix;
const peer = phone.slice(1);
const report = { mode: 'mock-only', checks };
try {
  const access = await request('GET', '/corporate/access', 'A');
  check('Mock mode is explicit in account metadata', access.data.gateway_mode === 'mock');
  const opened = await request('POST', '/corporate/conversations', 'A', { channel: 'telegram', phone });
  check('New dialog resolves and claims numeric Telegram identity', opened.status === 200 && opened.data.conversation_id);
  const id = opened.data.conversation_id;
  const foreign = await request('POST', '/corporate/conversations', 'B', { channel: 'telegram', phone });
  check('Another manager cannot claim existing owned identity', [403, 404, 422].includes(foreign.status) && !foreign.data?.conversation_id);
  const outgoing = await request('POST', `/conversations/${id}/messages`, 'A', { content: 'Synthetic Telegram outgoing', message_type: 'outgoing' });
  check('Outgoing persisted through corporate API', outgoing.status === 200);
  const sent = await until(async () => (await messages(id)).find(m => m.id === outgoing.data.id && m.content_attributes?.corporate_delivery === 'sent'));
  check('Durable worker receives gateway acknowledgement', /^\d+$/.test(sent.source_id));
  const event = { external_user_id: peer, external_message_id: '2000000001', text: 'Synthetic inbound' };
  inject(event);
  inject(event);
  await until(async () => (await messages(id)).some(m => m.content === event.text));
  check('Duplicate inbound events create one message', (await messages(id)).filter(m => m.source_id === event.external_message_id).length === 1);
  inject({ ...event, event_type: 'edited', revision: 'synthetic-edit-1', text: 'Synthetic edited' });
  await until(async () => (await messages(id)).some(m => m.source_id === event.external_message_id && m.content === 'Synthetic edited'));
  check('External edit reaches the original message', true);
  inject({ ...event, event_type: 'deleted', text: '' });
  await until(async () => (await messages(id)).some(m => m.source_id === event.external_message_id && m.content_attributes?.deleted));
  check('External deletion replaces content with tombstone', true);
  inject({ external_user_id: peer, external_message_id: sent.source_id, direction: 'outgoing', origin: 'official_client', text: sent.content });
  await pause(2000);
  check('Own outgoing echo is not duplicated', (await messages(id)).filter(m => m.source_id === sent.source_id).length === 1);
  const note = await request('POST', `/conversations/${id}/messages`, 'A', { content: 'Synthetic internal note', private: true });
  check('Internal note has no external delivery operation', note.status === 200 && !note.data.content_attributes?.corporate_operation_id);
  const form = new FormData();
  form.set('content', 'Synthetic document');
  form.set('message_type', 'outgoing');
  form.append('attachments[]', new Blob(['Synthetic document bytes'], { type: 'text/plain' }), 'synthetic.txt');
  const file = await request('POST', `/conversations/${id}/messages`, 'A', form);
  check('Document accepted by guarded upload', file.status === 200);
  await until(async () => (await messages(id)).some(m => m.id === file.data.id && m.content_attributes?.corporate_delivery === 'sent'));
  check('Attachment passes integration and mock gateway', true);
  const blocked = await request('POST', '/corporate/conversations', 'A', { channel: 'telegram', phone: '+79990000000' });
  check('Unavailable recipient returns actionable failure', blocked.status === 422);
  const other = await request('GET', `/conversations/${id}/messages`, 'B');
  check('Foreign manager cannot read integrated messages', [401, 403, 404].includes(other.status));
  report.passed = true;
} catch (error) {
  report.error = error.message;
  report.passed = false;
  process.exitCode = 1;
} finally {
  report.executed_at = new Date().toISOString();
  fs.writeFileSync('docs/evidence/stage-3-integration.json', JSON.stringify(report, null, 2) + '\n');
}
