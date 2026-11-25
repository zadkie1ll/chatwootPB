// Reproduce the unmodified CE baseline. PASS means expected CE behavior was observed,
// including behavior that FAILS the future owner-isolation requirements.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const fixture = JSON.parse(fs.readFileSync(path.join(root, 'secrets/baseline.json'), 'utf8'));
const base = 'http://localhost:8080';
const results = [];
const accountPath = `/api/v1/accounts/${fixture.account_id}`;
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function request(method, route, label, body) {
  const response = await fetch(new URL(route, base), {
    method,
    headers: { 'Content-Type': 'application/json', ...(label ? { Authorization: `Bearer ${fixture.users[label].token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(15000),
  });
  const text = await response.text();
  let json;
  try { json = JSON.parse(text); } catch { json = null; }
  return { status: response.status, text, json, headers: response.headers };
}

function record(id, observed, expected, requirementMet) {
  const passed = observed === expected;
  results.push({ id, observed, expected_for_unmodified_ce: expected, baseline_match: passed, owner_isolation_requirement_met: requirementMet });
  console.log(`${passed ? 'PASS' : 'FAIL'} ${id}: ${observed}`);
}

async function socketFor(label) {
  const user = fixture.users[label];
  const socket = new WebSocket('ws://localhost:8080/cable', ['actioncable-v1-json']);
  const frames = [];
  let confirmed = false;
  let failure;
  socket.addEventListener('error', () => { failure = 'WebSocket connection error'; });
  socket.addEventListener('message', event => {
    const data = JSON.parse(String(event.data));
    frames.push(data);
    if (data.type === 'welcome') {
      socket.send(JSON.stringify({ command: 'subscribe', identifier: JSON.stringify({
        channel: 'RoomChannel', pubsub_token: user.pubsub_token, user_id: user.id, account_id: fixture.account_id,
      }) }));
    }
    if (data.type === 'confirm_subscription') confirmed = true;
    if (data.type === 'reject_subscription') failure = 'Subscription rejected';
  });
  for (let iteration = 0; iteration < 100 && !confirmed && !failure; iteration += 1) await sleep(100);
  if (!confirmed) { socket.close(); throw new Error(failure || 'Subscription confirmation timed out'); }
  return { socket, frames };
}

async function main() {
  record('health', (await request('GET', '/health')).status, 200, null);
  const login = await request('GET', '/app/login');
  record('dashboard_html', login.status === 200 && login.text.includes('<html'), true, null);
  const assets = [...login.text.matchAll(/(?:src|href)="(\/vite\/assets\/[^\"]+)"/g)].map(match => match[1]);
  record('dashboard_has_compiled_assets', assets.length > 0, true, null);
  if (assets.length) record('compiled_asset_served', (await request('GET', assets[0])).status, 200, null);

  const secretEnv = fs.readFileSync(path.join(root, '.env'), 'utf8');
  const password = secretEnv.match(/^LAB_USER_PASSWORD=(.+)$/m)?.[1];
  for (const label of ['A', 'B', 'R']) {
    record(`dashboard_sign_in_${label}`, (await request('POST', '/auth/sign_in', null, {
      email: fixture.users[label].email, password,
    })).status, 200, null);
  }
  const x = fixture.contacts.X;
  const conversationX = fixture.conversations.X;
  const show = await request('GET', `${accountPath}/conversations/${conversationX}`, 'B');
  record('B_reads_A_conversation', show.status, 200, false);
  record('B_reads_A_contact', (await request('GET', `${accountPath}/contacts/${x}`, 'B')).status, 200, false);
  const contacts = await request('GET', `${accountPath}/contacts/search?q=stage1-x`, 'B');
  record('B_search_finds_A_contact', contacts.status === 200 && contacts.json?.payload?.some(contact => contact.id === x), true, false);
  const messages = await request('GET', `${accountPath}/conversations/${conversationX}/messages`, 'B');
  record('B_reads_A_messages', messages.status === 200 && messages.json?.payload?.some(message => message.content?.includes('Synthetic baseline')), true, false);
  const list = await request('GET', `${accountPath}/conversations?status=all`, 'B');
  record('B_list_contains_A_conversation', list.status === 200 && list.json?.data?.payload?.some(conversation => conversation.id === conversationX), true, false);
  record('B_reads_unassigned', (await request('GET', `${accountPath}/conversations/${fixture.conversations.Z}`, 'B')).status, 200, false);
  record('R_reads_A_conversation', (await request('GET', `${accountPath}/conversations/${conversationX}`, 'R')).status, 200, true);
  const cross = await request('GET', `/api/v1/accounts/${fixture.other_account_id}/contacts/${fixture.contacts.Q}`, 'B');
  record('cross_account_rejected', [401, 403, 404].includes(cross.status), true, true);
  record('anonymous_conversation_rejected', (await request('GET', `${accountPath}/conversations/${conversationX}`)).status, 401, true);

  const { socket, frames } = await socketFor('B');
  try {
    const update = await request('PUT', `${accountPath}/contacts/${x}`, 'A', { name: `Synthetic Client X ${Date.now()}` });
    record('A_updates_own_contact', update.status, 200, true);
    const sent = await request('POST', `${accountPath}/conversations/${conversationX}/messages`, 'A', {
      content: 'Synthetic baseline socket probe', message_type: 'outgoing', private: true,
    });
    record('A_creates_private_note', sent.status, 200, true);
    for (let iteration = 0; iteration < 150; iteration += 1) {
      if (frames.some(frame => frame.message?.event === 'contact.updated' && frame.message?.data?.id === x)
          && frames.some(frame => frame.message?.event === 'message.created' && frame.message?.data?.id === sent.json?.id)) break;
      await sleep(100);
    }
    record('B_socket_receives_A_contact', frames.some(frame => frame.message?.event === 'contact.updated' && frame.message?.data?.id === x), true, false);
    record('B_socket_receives_A_private_note', frames.some(frame => frame.message?.event === 'message.created' && frame.message?.data?.id === sent.json?.id), true, false);
  } finally {
    socket.close();
    await request('PUT', `${accountPath}/contacts/${x}`, 'A', { name: 'Synthetic Client X' });
  }
  const managerTransfer = await request('POST', `${accountPath}/conversations/${conversationX}/assignments`, 'A', { assignee_id: fixture.users.B.id });
  record('A_can_reassign_without_supervisor', managerTransfer.status, 200, false);
  await request('POST', `${accountPath}/conversations/${conversationX}/assignments`, 'R', { assignee_id: fixture.users.A.id });
  const file = await request('GET', fixture.attachment_url);
  record('signed_file_without_login', file.status === 200 && file.text === 'SYNTHETIC STAGE 1 FILE\n', true, false);
  const transfer = await request('POST', `${accountPath}/conversations/${conversationX}/assignments`, 'R', { assignee_id: fixture.users.B.id });
  record('R_assigns_to_B', transfer.status, 200, true);
  try {
    record('A_still_reads_after_transfer', (await request('GET', `${accountPath}/conversations/${conversationX}`, 'A')).status, 200, false);
    const oldLink = await request('GET', fixture.attachment_url);
    record('old_signed_file_after_transfer', oldLink.status === 200 && oldLink.text === 'SYNTHETIC STAGE 1 FILE\n', true, false);
  } finally {
    await request('POST', `${accountPath}/conversations/${conversationX}/assignments`, 'R', { assignee_id: fixture.users.A.id });
  }
}

let error;
try { await main(); } catch (caught) {
  error = caught.name; // Do not emit request URLs, headers or credential-bearing error objects.
  console.error(`Baseline aborted: ${error}. Inspect local services; no credentials printed.`);
} finally {
  const output = { executed_at: new Date().toISOString(), source_commit: fixture.source_commit,
    purpose: 'Unmodified CE baseline; expected leaks are not successful owner isolation',
    complete: !error, all_baseline_expectations_matched: !error && results.every(result => result.baseline_match),
    error: error ?? null, results };
  fs.mkdirSync(path.join(root, 'docs/evidence'), { recursive: true });
  fs.writeFileSync(path.join(root, 'docs/evidence/stage-1-baseline.json'), `${JSON.stringify(output, null, 2)}\n`);
  if (!output.all_baseline_expectations_matched) process.exitCode = 1;
}
