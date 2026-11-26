"""Private durable MAX delivery journal. A timed-out send is never replayed."""
import hashlib
import json
from pathlib import Path
import sqlite3
import time


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


class Journal:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.db = sqlite3.connect(self.directory / 'delivery.sqlite3')
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS operations (
                id TEXT PRIMARY KEY, hash TEXT NOT NULL, cid INTEGER NOT NULL UNIQUE,
                peer TEXT NOT NULL, state TEXT NOT NULL, payload TEXT NOT NULL, result TEXT NOT NULL DEFAULT '{}');
            CREATE INDEX IF NOT EXISTS operation_peer_state ON operations(peer,state);
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT, hash TEXT UNIQUE NOT NULL,
                payload TEXT NOT NULL, acked INTEGER NOT NULL DEFAULT 0, completed REAL);
            CREATE INDEX IF NOT EXISTS event_window ON events(acked,id);
            CREATE TABLE IF NOT EXISTS messages (
                peer TEXT NOT NULL, id TEXT NOT NULL, hash TEXT NOT NULL, revision INTEGER NOT NULL,
                payload TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(peer,id));
            CREATE TABLE IF NOT EXISTS media (
                id TEXT PRIMARY KEY, payload TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                due REAL NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        ''')
        self.db.execute("UPDATE operations SET state='unknown' WHERE state='sending'")
        self.db.commit()

    def get(self, key, default=None):
        row = self.db.execute('SELECT value FROM metadata WHERE key=?', (key,)).fetchone()
        return json.loads(row[0]) if row else default

    def put(self, key, value):
        self.db.execute('INSERT INTO metadata VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value', (key, json.dumps(value)))
        self.db.commit()

    def operation(self, operation_id):
        row = self.db.execute('SELECT state,result FROM operations WHERE id=?', (operation_id,)).fetchone()
        return {**json.loads(row['result']), 'state': row['state']} if row else {'state': 'absent'}

    def begin(self, payload):
        stable = {k: payload.get(k) for k in ('channel', 'external_account_id', 'external_user_id', 'action', 'target_message_id', 'text', 'reply_to', 'attachments')}
        hashed = digest(stable)
        existing = self.db.execute('SELECT * FROM operations WHERE id=?', (payload['operation_id'],)).fetchone()
        if existing:
            if existing['hash'] != hashed:
                raise ValueError('operation_conflict')
            return existing['cid'], self.operation(payload['operation_id'])
        # Below JS's exact-integer ceiling; fixed across retries and restarts.
        cid = int(hashlib.sha256(payload['operation_id'].encode()).hexdigest()[:12], 16)
        stored = {k: v for k, v in stable.items() if k != 'attachments'}
        self.db.execute('INSERT INTO operations(id,hash,cid,peer,state,payload) VALUES(?,?,?,?,?,?)',
                        (payload['operation_id'], hashed, cid, str(payload['external_user_id']), 'sending', json.dumps(stored)))
        self.db.commit()
        return cid, None

    def finish(self, operation_id, state, **result):
        self.db.execute('UPDATE operations SET state=?,result=? WHERE id=?', (state, json.dumps(result), operation_id))
        if state in ('sent', 'failed'):
            self.db.execute("UPDATE operations SET payload='{}' WHERE id=?", (operation_id,))
        self.db.commit()
        return {'state': state, **result}

    def confirm_echo(self, peer, cid, message_id, message_time=None):
        if cid is None:
            return False
        row = self.db.execute('SELECT id FROM operations WHERE cid=? AND peer=?', (cid, str(peer))).fetchone()
        if row:
            previous = self.operation(row['id']).get('external_message_time')
            self.finish(row['id'], 'sent', external_message_id=str(message_id),
                        **({'external_message_time': message_time or previous} if message_time or previous else {}))
        return bool(row)

    def remember_sent_time(self, peer, message_id, timestamp):
        self.db.execute("UPDATE operations SET result=json_set(result,'$.external_message_time',?) WHERE peer=? AND json_extract(result,'$.external_message_id')=?",
                        (timestamp, str(peer), str(message_id)))
        self.db.commit()

    def own(self, peer, message_id):
        return bool(self.db.execute("SELECT 1 FROM operations WHERE peer=? AND json_extract(result,'$.external_message_id')=?", (str(peer), str(message_id))).fetchone())

    def emit(self, event):
        key = digest([event.get(k) for k in ('channel', 'external_account_id', 'external_chat_id', 'external_message_id', 'event_type', 'revision')])
        self.db.execute('INSERT OR IGNORE INTO events(hash,payload) VALUES(?,?)', (key, json.dumps(event)))

    def save_message(self, event, signature, has_media=False):
        peer, mid = event['external_chat_id'], event['external_message_id']
        previous = self.db.execute('SELECT * FROM messages WHERE peer=? AND id=?', (peer, mid)).fetchone()
        if previous and (previous['deleted'] or previous['hash'] == signature):
            return False
        revision = max(int(time.time() * 1000), previous['revision'] + 1 if previous else 0)
        event = {**event, 'revision': str(revision).zfill(16)}
        if previous:
            event['event_type'] = 'edited'
        self.db.execute('INSERT INTO messages(peer,id,hash,revision,payload) VALUES(?,?,?,?,?) ON CONFLICT(peer,id) DO UPDATE SET hash=excluded.hash,revision=excluded.revision,payload=excluded.payload',
                        (peer, mid, signature, revision, json.dumps({**event, 'text': '', 'sender_name': 'MAX', 'phone': None})))
        self.emit(event)
        if has_media:
            media_id = digest([peer, mid, event['revision']])
            self.db.execute('INSERT OR IGNORE INTO media(id,payload) VALUES(?,?)', (media_id, json.dumps(event)))
        self.db.commit()
        return True

    def delete(self, peer, mid, fallback=None):
        row = self.db.execute('SELECT * FROM messages WHERE peer=? AND id=?', (str(peer), str(mid))).fetchone()
        if row and not row['deleted']:
            event = json.loads(row['payload'])
            self.emit({**event, 'event_type': 'deleted', 'text': '', 'attachments': [], 'revision': str(int(time.time() * 1000)).zfill(16)})
        if not row and fallback:
            self.emit(fallback)
        self.db.execute('INSERT INTO messages(peer,id,hash,revision,payload,deleted) VALUES(?,?,?,0,?,1) ON CONFLICT(peer,id) DO UPDATE SET deleted=1', (str(peer), str(mid), '', '{}'))
        self.db.commit()

    def events(self):
        after = self.get('event_cursor', 0)
        rows = self.db.execute('SELECT * FROM events WHERE acked=0 AND id>? ORDER BY id LIMIT 200', (after,)).fetchall()
        if not rows:
            rows = self.db.execute('SELECT * FROM events WHERE acked=0 ORDER BY id LIMIT 200').fetchall()
        result, last = [], 0
        for row in rows:
            last = row['id']
            event = json.loads(row['payload'])
            echo_candidate = event['direction'] == 'outgoing' and (event['event_type'] == 'received' or
                              event['event_type'] == 'media' and event.get('source_event_type') != 'edited')
            if echo_candidate:
                peer = event['external_user_id']
                if self.own(peer, event['external_message_id']):
                    self.ack(last)
                    self.complete(last)
                    continue
                if self.db.execute("SELECT 1 FROM operations WHERE peer=? AND state IN ('sending','unknown') LIMIT 1", (peer,)).fetchone():
                    continue
            result.append({**event, 'journal_id': last})
            if len(result) == 50:
                break
        if rows:
            self.put('event_cursor', last)
        return result

    def ack(self, event_id):
        self.db.execute('UPDATE events SET acked=1 WHERE id=?', (event_id,))
        self.db.commit()

    def complete(self, event_id):
        self.db.execute('UPDATE events SET completed=? WHERE id=? AND acked=1', (time.time(), event_id))
        self.db.commit()

    def media_job(self):
        return self.db.execute('SELECT * FROM media WHERE due<=? ORDER BY due,id LIMIT 1', (time.time(),)).fetchone()

    def media_result(self, row, attachments=None, error=None):
        event = json.loads(row['payload'])
        media_event = {**event, 'event_type': 'media', 'source_revision': event['revision'], 'revision': event['revision'] + '/media',
                       'media_id': row['id'], 'source_event_type': event['event_type'], 'attachment_state': 'failed' if error else 'ready', 'attachments': attachments or []}
        if error:
            media_event['attachment_error'] = error
        self.emit(media_event)
        self.db.execute('DELETE FROM media WHERE id=?', (row['id'],))
        self.db.commit()

    def retry_media(self, row):
        attempts = row['attempts'] + 1
        self.db.execute('UPDATE media SET attempts=?,due=? WHERE id=?', (attempts, time.time() + min(300, 2 ** min(attempts, 8)), row['id']))
        self.db.commit()

    def metrics(self):
        return {'unacknowledged': self.db.execute('SELECT count(*) FROM events WHERE acked=0').fetchone()[0],
                'media_pending': self.db.execute('SELECT count(*) FROM media').fetchone()[0],
                'unknown': self.db.execute("SELECT count(*) FROM operations WHERE state='unknown'").fetchone()[0]}

    def cleanup(self):
        cutoff = time.time() - 30 * 86400
        self.db.execute('DELETE FROM events WHERE completed<?', (cutoff,))
        self.db.commit()
        # Completed files only: outstanding events may still reference old media.
        for file in self.directory.glob('attachment-*'):
            if file.stat().st_mtime >= cutoff:
                continue
            key = file.name.removeprefix('attachment-')
            referenced = self.db.execute('SELECT 1 FROM events WHERE completed IS NULL AND payload LIKE ? LIMIT 1', ('%' + key + '%',)).fetchone()
            if not referenced:
                file.unlink()
