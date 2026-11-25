import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
const fixture = JSON.parse(fs.readFileSync('secrets/baseline.json', 'utf8'));
const root = `http://localhost:8080/api/v1/accounts/${fixture.account_id}`;
const results = [];
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const sockets = [];

async function request(method, route, user, body, headers = {}) {
  const url = route.startsWith('http') ? route : `${root}${route}`;
  const response = await fetch(url, { method,
    headers: { 'Content-Type': 'application/json', ...(user ? { Authorization: `Bearer ${fixture.users[user].token}` } : {}), ...headers },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(15000) });
  const text = await response.text();
  let json; try { json = JSON.parse(text); } catch { json = null; }
  return { status: response.status, text, json, headers: response.headers };
}
function check(name, passed) {
  results.push({ name, passed: passed === true });
  console.log(`${passed ? 'PASS' : 'FAIL'} ${name}`);
}
const denied = response => [401, 403, 404].includes(response.status) && !response.text.includes('Synthetic Client X');

async function subscribe(user) {
  const member = fixture.users[user];
  const socket = new WebSocket('ws://localhost:8080/cable', ['actioncable-v1-json']);
  sockets.push(socket);
  const frames = [];
  let confirmed = false;
  socket.addEventListener('error', () => {});
  socket.addEventListener('message', event => {
    const data = JSON.parse(String(event.data));
    frames.push(data);
    if (data.type === 'welcome') socket.send(JSON.stringify({ command: 'subscribe', identifier: JSON.stringify({
      channel: 'RoomChannel', pubsub_token: member.pubsub_token, user_id: member.id, account_id: fixture.account_id,
    }) }));
    if (data.type === 'confirm_subscription') confirmed = true;
  });
  for (let attempt = 0; attempt < 100 && !confirmed; attempt += 1) await pause(100);
  if (!confirmed) throw new Error('Socket subscription failed');
  return frames;
}
const hasMessage = (frames, id) => frames.some(frame => frame.message?.event === 'message.created' && frame.message?.data?.id === id);
function compose(...args) {
  const result = spawnSync('bash', ['scripts/compose.sh', ...args], { encoding: 'utf8' });
  if (result.status) throw new Error('Compose operation failed');
}

let workerStopped = false;
let transferred = false;
let error;
try {
  if ((await request('GET', 'http://localhost:8080/health')).status !== 200) throw new Error('Application health is not ready');
  const X = fixture.contacts.X;
  const C = fixture.conversations.X;
  const own = await request('GET', `/contacts/${X}`, 'A');
  check('A reads own contact', own.status === 200);
  const cookieA = own.headers.get('set-cookie')?.split(';')[0];
  const ownB = await request('GET', `/contacts/${fixture.contacts.Y}`, 'B');
  const cookieB = ownB.headers.get('set-cookie')?.split(';')[0];
  check('Media cookies are HttpOnly and scoped', own.headers.get('set-cookie')?.includes('httponly') === true);
  for (const method of ['GET', 'PUT', 'PATCH', 'DELETE']) {
    check(`B cannot ${method} A contact`, denied(await request(method, `/contacts/${X}`, 'B', ['PUT', 'PATCH'].includes(method) ? { name: 'Forbidden' } : undefined)));
  }
  check('A cannot read B', denied(await request('GET', `/contacts/${fixture.contacts.Y}`, 'A')));
  check('A cannot read unassigned', denied(await request('GET', `/conversations/${fixture.conversations.Z}`, 'A')));
  check('R can read unassigned', (await request('GET', `/conversations/${fixture.conversations.Z}`, 'R')).status === 200);
  check('T cannot read client', denied(await request('GET', `/contacts/${X}`, 'T')));
  check('T can manage channel view', (await request('GET', `/inboxes/${fixture.inbox_id}`, 'T')).status === 200);
  const rInbox = await request('GET', `/inboxes/${fixture.inbox_id}`, 'R');
  check('R receives no channel secrets', rInbox.status === 200 && !Object.hasOwn(rInbox.json ?? {}, 'secret') && !Object.hasOwn(rInbox.json ?? {}, 'hmac_token'));
  const bSearch = await request('GET', '/contacts/search?q=stage1-x', 'B');
  check('B search hides X', bSearch.status === 200 && bSearch.json?.payload?.length === 0);
  const allSearch = await request('GET', '/search?q=Synthetic%20baseline%20message%20X', 'B');
  check('Global search hides foreign payload', allSearch.status === 200 && !allSearch.text.includes('Synthetic Client X') && !allSearch.text.includes('Synthetic baseline message X'));
  const list = await request('GET', '/conversations?status=all', 'B');
  check('B list excludes A and unassigned', list.status === 200 && list.json?.data?.payload?.every(c => c.id === fixture.conversations.Y));
  const notifications = await request('GET', '/notifications', 'B');
  check('Old notifications hide foreign client', notifications.status === 200 && !notifications.text.includes('Synthetic Client X'));
  const counts = await request('GET', '/conversations/meta?status=all', 'B');
  check('Counts reflect visible conversations', counts.status === 200 && counts.json?.meta?.all_count === 1);
  const cross = await request('GET', `http://localhost:8080/api/v1/accounts/${fixture.other_account_id}/contacts/${fixture.contacts.Q}`, 'A');
  check('Cross-account rejected', denied(cross));
  for (const [method, route] of [
    ['POST', '/bulk_actions'], ['POST', '/contacts/export'], ['GET', '/data_exports'],
    ['GET', '/automation_rules'], ['GET', '/macros'], ['POST', `/conversations/${C}/assignments`],
    ['GET', `http://localhost:8080/api/v2/accounts/${fixture.account_id}/reports`],
  ]) check(`Closed surface ${method} ${route.replace(/http.*?\/api/, '/api')}`, denied(await request(method, route, 'A', method === 'POST' ? {} : undefined)));

  let messages = await request('GET', `/conversations/${C}/messages`, 'A');
  let file;
  for (let page = 0; page < 20; page += 1) {
    const payload = messages.json?.payload ?? [];
    file = payload.flatMap(message => message.attachments ?? []).find(attachment => attachment.data_url)?.data_url;
    if (file || !payload.length) break;
    messages = await request('GET', `/conversations/${C}/messages?before=${Math.min(...payload.map(message => message.id))}`, 'A');
  }
  check('Own messages supply protected file URL', messages.status === 200 && file?.includes('/api/v1/corporate_files/'));
  if (!file) throw new Error('No protected fixture file URL');
  check('A reads file using API token', (await request('GET', file, 'A')).text === 'SYNTHETIC STAGE 1 FILE\n');
  check('Browser cookie reads own media', (await request('GET', file, undefined, undefined, { Cookie: cookieA })).status === 200);
  check('Copied URL with B cookie rejected', denied(await request('GET', file, undefined, undefined, { Cookie: cookieB })));
  check('Copied URL with B token rejected', denied(await request('GET', file, 'B')));
  check('Anonymous file rejected', denied(await request('GET', file)));
  check('Old signed storage URL blocked', denied(await request('GET', fixture.attachment_url, 'A')));
  check('Own file Range supported', (await request('GET', file, 'A', undefined, { Range: 'bytes=0-8' })).status === 206);
  check('Foreign file Range rejected', denied(await request('GET', file, 'B', undefined, { Range: 'bytes=0-8' })));
  check('Foreign file HEAD rejected', denied(await request('HEAD', file, 'B')));
  check('Cannot forge incoming message', [400, 422].includes((await request('POST', `/conversations/${C}/messages`, 'A', { content: 'Synthetic spoof', message_type: 'incoming' })).status));
  check('Cannot modify foreign message stream', denied(await request('POST', `/conversations/${C}/messages`, 'B', { content: 'Forbidden', private: true })));
  check('Foreign direct upload rejected', denied(await request('POST', `/conversations/${C}/direct_uploads`, 'B', { blob: { filename: 'x.txt', byte_size: 1, checksum: 'abc', content_type: 'text/plain' } })));
  const aFrames = await subscribe('A');
  const bFrames = await subscribe('B');
  const rFrames = await subscribe('R');
  const note = await request('POST', `/conversations/${C}/messages`, 'A', { content: 'Synthetic isolation note', private: true });
  check('A can create private note', note.status === 200);
  for (let attempt = 0; attempt < 100 && (!hasMessage(aFrames, note.json?.id) || !hasMessage(rFrames, note.json?.id)); attempt += 1) await pause(100);
  check('A receives own live message', hasMessage(aFrames, note.json?.id));
  check('R receives live message', hasMessage(rFrames, note.json?.id));
  check('B receives no foreign live message', !hasMessage(bFrames, note.json?.id));

  // Queue a snapshot before transfer, then execute its job under the new owner.
  compose('stop', '--timeout', '5', 'chatwoot-worker');
  workerStopped = true;
  const queued = await request('POST', `/conversations/${C}/messages`, 'A', { content: 'Synthetic queued transfer probe', private: true });
  check('Queued note persisted before transfer', queued.status === 200);
  const transfer = await request('PUT', `/corporate/ownerships/${X}`, 'R', { owner_id: fixture.users.B.id, reason: 'Synthetic isolation transfer' });
  transferred = transfer.status === 200;
  check('R transfers whole client', transferred);
  check('Old owner loses HTTP immediately', denied(await request('GET', `/conversations/${C}`, 'A')));
  check('New owner reads full history', (await request('GET', `/conversations/${C}/messages`, 'B')).json?.payload?.some(message => message.id === note.json?.id) === true);
  check('Old owner media cookie revoked by ownership', denied(await request('GET', file, undefined, undefined, { Cookie: cookieA })));
  check('New owner reads same protected URL', (await request('GET', file, 'B')).status === 200);
  compose('start', 'chatwoot-worker');
  workerStopped = false;
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (hasMessage(bFrames, queued.json?.id) && aFrames.some(frame => frame.message?.event === 'corporate.access_changed')) break;
    await pause(100);
  }
  check('Queued old snapshot reaches new owner', hasMessage(bFrames, queued.json?.id));
  check('Queued old snapshot never reaches previous owner', !hasMessage(aFrames, queued.json?.id));
  check('Previous owner receives neutral access change', aFrames.some(frame => frame.message?.event === 'corporate.access_changed' && !frame.message?.data?.contact_id));
  const audit = await request('GET', '/corporate/ownerships/audit', 'R');
  check('Transfer audited', audit.status === 200 && audit.json?.some(row => row.contact_id === X && row.old_owner_id === fixture.users.A.id && row.new_owner_id === fixture.users.B.id));
  check('Manager cannot read audit', denied(await request('GET', '/corporate/ownerships/audit', 'B')));
  check('Manager cannot release client', denied(await request('PUT', `/corporate/ownerships/${X}`, 'B', { owner_id: null, reason: 'Forbidden' })));
} catch (caught) {
  error = caught.message;
  console.error(`Isolation probe aborted: ${error}`);
} finally {
  if (transferred) await request('PUT', `/corporate/ownerships/${fixture.contacts.X}`, 'R', { owner_id: fixture.users.A.id, reason: 'Restore synthetic fixture' });
  if (workerStopped) compose('start', 'chatwoot-worker');
  sockets.forEach(socket => socket.close());
  const passed = !error && results.every(result => result.passed);
  fs.writeFileSync('docs/evidence/stage-2-isolation.json', `${JSON.stringify({ executed_at: new Date().toISOString(), all_passed: passed, error: error ?? null, results }, null, 2)}\n`);
  if (!passed) process.exitCode = 1;
}
