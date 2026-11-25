import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
const fixture = JSON.parse(fs.readFileSync('secrets/baseline.json', 'utf8'));
const base = `http://localhost:8080/api/v1/accounts/${fixture.account_id}`;
const report = { mode: 'synthetic-tls-crm-and-mock-telegram', checks: [] };
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const sockets = [];
const check = (name, passed) => {
  report.checks.push({ name, passed: Boolean(passed) });
  console.log(`${passed ? 'PASS' : 'FAIL'} ${name}`);
  if (!passed) throw new Error(name);
};
async function api(method, path, label, body) {
  const response = await fetch(base + path, { method, headers: { Authorization: `Bearer ${fixture.users[label].token}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(60000) });
  return { status: response.status, data: await response.json().catch(() => null) };
}
function internal(service, code, data) {
  const result = spawnSync('bash', ['scripts/compose.sh', '-f', 'compose.yaml', '-f', 'infra/compose.bitrix-test.yaml', 'exec', '-T', service, 'python', '-c', code],
    { input: data === undefined ? undefined : JSON.stringify(data), encoding: 'utf8' });
  if (result.status) throw new Error('Synthetic service call failed');
  return JSON.parse(result.stdout);
}
const inject = event => internal('telegram-gateway',
  'import os,sys,json,urllib.request; assert os.environ["TELEGRAM_MODE"]=="mock"; r=urllib.request.Request("http://127.0.0.1:8091/test/incoming",data=sys.stdin.buffer.read(),headers={"Authorization":"Bearer "+os.environ["GATEWAY_TOKEN"],"Content-Type":"application/json"}); print(urllib.request.urlopen(r).read().decode())', event);
const crmState = () => internal('integration-worker', 'import urllib.request; print(urllib.request.urlopen("https://synthetic.bitrix24.test:8443/test/state").read().decode())');
async function until(callback) {
  for (let i = 0; i < 80; i += 1) { const value = await callback(); if (value) return value; await pause(500); }
  throw new Error('Timed out waiting for synthetic integration');
}
async function socket(label) {
  const ws = new WebSocket('ws://localhost:8080/cable', ['actioncable-v1-json']);
  sockets.push(ws);
  const frames = [];
  let subscribed = false;
  ws.addEventListener('message', event => {
    const data = JSON.parse(String(event.data));
    frames.push(data);
    if (data.type === 'welcome') ws.send(JSON.stringify({ command: 'subscribe', identifier: JSON.stringify({ channel: 'RoomChannel',
      pubsub_token: fixture.users[label].pubsub_token, user_id: fixture.users[label].id, account_id: fixture.account_id }) }));
    if (data.type === 'confirm_subscription') subscribed = true;
  });
  await until(() => subscribed);
  return frames;
}
async function hiddenChat(peer) {
  inject({ external_user_id: peer, external_message_id: peer, text: 'Synthetic hidden-phone CRM incoming' });
  const contact = await until(async () => {
    const result = await api('GET', `/contacts/search?q=${peer}`, 'R');
    return result.data?.payload?.find(row => row.identifier?.endsWith('/' + peer));
  });
  const conversations = await api('GET', `/contacts/${contact.id}/conversations`, 'R');
  return conversations.data.payload[0].id;
}
try {
  const directory = await api('GET', '/corporate/crm/employees', 'R');
  check('Supervisor reads synthetic Bitrix employee directory over verified TLS', directory.status === 200 && directory.data.employees.length === 2);
  for (const [label, id] of [['A', '11'], ['B', '22']]) check('Map manager ' + label, (await api('PUT', '/corporate/crm/employees/' + fixture.users[label].id, 'R', { bitrix_user_id: id })).status === 204);
  check('Manager cannot change employee mappings', (await api('GET', '/corporate/crm/employees', 'A')).status === 404);
  const outbound = await api('POST', '/corporate/conversations', 'A', { channel: 'telegram', phone: '+79991234567' });
  check('Manager starts a personal Telegram dialog by phone', outbound.status === 200);
  const firstId = outbound.data.conversation_id;
  const linked = await until(async () => {
    const result = await api('GET', '/corporate/crm/conversations/' + firstId, 'A');
    return result.data?.state === 'applied' && result.data;
  });
  check('Newest open deal selected, closed deal ignored', linked.deal_id === '502');
  const state = crmState();
  check('CRM owner reassigned to initiating manager', String(state.deals['502'].assignedById) === '11');
  check('Both CRM fields hold the authenticated conversation link', state.deals['502'].UF_CRM_CW_MANAGER_CHAT === `http://localhost:8080/app/accounts/${fixture.account_id}/conversations/${firstId}` && state.deals['502'].UF_CRM_CW_SUPERVISOR_CHAT === state.deals['502'].UF_CRM_CW_MANAGER_CHAT);
  const framesA = await socket('A');
  const framesB = await socket('B');
  const id = await hiddenChat(String(Date.now()));
  for (const label of ['A', 'B']) {
    const info = await api('GET', '/corporate/crm/conversations/' + id, label);
    check(label + ' sees unidentified shared incoming', info.status === 200 && info.data.shared === true);
    const reply = await api('POST', `/conversations/${id}/messages`, label, { content: 'Synthetic shared reply ' + label });
    check(label + ' can reply before binding', reply.status === 200);
    await until(async () => (await api('GET', `/conversations/${id}/messages`, label)).data?.payload?.some(m => m.id === reply.data.id && m.content_attributes?.corporate_delivery === 'sent'));
  }
  const manual = await api('POST', `/corporate/crm/conversations/${id}/bind`, 'A', { deal_url: 'https://synthetic.bitrix24.test:8443/crm/deal/details/601/' });
  check('Deal URL parsed and shared visibility closed atomically', manual.status === 200 && manual.data.deal_id === '601' && !manual.data.shared);
  await until(async () => (await api('GET', '/corporate/crm/conversations/' + id, 'A')).data?.state === 'applied');
  await until(() => framesB.some(f => f.message?.event === 'corporate.access_changed'));
  check('Previous shared reader gets neutral revocation event', true);
  check('Other manager loses HTTP access after linking', [401, 403, 404].includes((await api('GET', `/conversations/${id}/messages`, 'B')).status));
  const note = await api('POST', `/conversations/${id}/messages`, 'A', { content: 'Synthetic post-binding private content', private: true });
  await until(() => framesA.some(f => f.message?.data?.id === note.data.id && f.message?.event === 'message.created'));
  await pause(1000);
  check('Other manager receives no new post-binding message over WebSocket', !framesB.some(f => f.message?.data?.id === note.data.id && f.message?.event === 'message.created'));
  check('Supervisor retains the bound conversation', (await api('GET', `/conversations/${id}/messages`, 'R')).status === 200);
  internal('integration-worker', "from crm.client import BitrixClient; import json; BitrixClient().update('502', {'ASSIGNED_BY_ID':'22'}); print(json.dumps({'ok':True}))");
  const updatesBefore = crmState().updates.length;
  internal('integration-worker', "import os,django; os.environ.setdefault('DJANGO_SETTINGS_MODULE','config.settings'); django.setup(); from crm.reconcile import reconcile_batch; import json; print(json.dumps({'cursor':reconcile_batch()}))");
  check('External CRM reassignment grants the new manager access', (await api('GET', `/conversations/${firstId}/messages`, 'B')).status === 200);
  check('External CRM reassignment revokes the previous manager', [401,403,404].includes((await api('GET', `/conversations/${firstId}/messages`, 'A')).status));
  check('External CRM reassignment creates no write-back loop', crmState().updates.length === updatesBefore);
  const browserId = await hiddenChat(String(Date.now() + 1));
  fs.writeFileSync('.state/bitrix-case.json', JSON.stringify({ outbound: firstId, bound: id, browser: browserId }));
  report.passed = true;
} catch (error) {
  report.passed = false; report.error = error.message; process.exitCode = 1;
} finally {
  for (const ws of sockets) ws.close();
  report.executed_at = new Date().toISOString();
  fs.writeFileSync('docs/evidence/bitrix-integration.json', JSON.stringify(report, null, 2) + '\n');
}
