import hashlib
import json
import sqlite3
import time
from datetime import datetime
from pathlib import Path


class Journal:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(self.directory / 'journal.sqlite3')
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS operations (
                operation_id TEXT PRIMARY KEY, payload_hash TEXT NOT NULL,
                peer TEXT NOT NULL, random_id INTEGER NOT NULL UNIQUE,
                state TEXT NOT NULL, result TEXT NOT NULL DEFAULT '{}');
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT, event_key TEXT NOT NULL UNIQUE,
                peer TEXT NOT NULL, message_id TEXT NOT NULL, direction TEXT NOT NULL,
                payload TEXT NOT NULL, acked INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS media_jobs (
                job_key TEXT PRIMARY KEY, payload TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'pending',
                attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0, completed_at REAL);
            CREATE TABLE IF NOT EXISTS deleted_messages (message_id TEXT PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS sent_messages (peer TEXT NOT NULL, message_id TEXT NOT NULL, PRIMARY KEY(peer,message_id));
            CREATE TABLE IF NOT EXISTS message_index (
                message_id TEXT PRIMARY KEY, payload TEXT NOT NULL);
        ''')
        self.db.executescript('CREATE INDEX IF NOT EXISTS event_delivery_window ON events(acked,id); CREATE INDEX IF NOT EXISTS operation_peer ON operations(peer); CREATE INDEX IF NOT EXISTS media_schedule ON media_jobs(state,next_attempt);')
        columns = {r['name'] for r in self.db.execute('PRAGMA table_info(events)')}
        for name in ('created_at', 'completed_at'):
            if name not in columns:
                self.db.execute('ALTER TABLE events ADD COLUMN ' + name + ' REAL')
        operation_columns = {r['name'] for r in self.db.execute('PRAGMA table_info(operations)')}
        if 'payload' not in operation_columns:
            self.db.execute("ALTER TABLE operations ADD COLUMN payload TEXT NOT NULL DEFAULT '{}'")
        media_columns = {r['name'] for r in self.db.execute('PRAGMA table_info(media_jobs)')}
        if 'completed_at' not in media_columns:
            self.db.execute('ALTER TABLE media_jobs ADD COLUMN completed_at REAL')
        self.db.execute('CREATE INDEX IF NOT EXISTS completed_events ON events(completed_at,id)')
        self.db.execute('CREATE INDEX IF NOT EXISTS operation_peer_state ON operations(peer,state)')
        if not self.db.execute("SELECT 1 FROM metadata WHERE key='own_message_index_ready'").fetchone():
            self.db.execute("INSERT OR IGNORE INTO sent_messages(peer,message_id) SELECT operations.peer,CAST(value AS TEXT) FROM operations,json_each(operations.result,'$.external_message_ids')")
            self.db.execute("INSERT INTO metadata(key,value) VALUES('own_message_index_ready','1')")
        self.db.execute("UPDATE operations SET state='unknown' WHERE state='sending'")
        self.db.commit()

    def operation(self, operation_id):
        row = self.db.execute('SELECT * FROM operations WHERE operation_id=?', (operation_id,)).fetchone()
        return {**json.loads(row['result']), 'state': row['state']} if row else {'state': 'absent'}

    def begin_operation(self, data):
        operation_id = data['operation_id']
        stable = {key: data.get(key) for key in ('external_account_id', 'external_user_id', 'text', 'attachments', 'reply_to', 'action', 'target_message_id')}
        # Preserve the hash of send operations created before edit support.
        if stable['action'] in (None, 'send') and not stable['target_message_id']:
            stable.pop('action')
            stable.pop('target_message_id')
        digest = hashlib.sha256(json.dumps(stable, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        row = self.db.execute('SELECT * FROM operations WHERE operation_id=?', (operation_id,)).fetchone()
        if row:
            if row['payload_hash'] != digest:
                raise ValueError('operation_conflict')
            if row['state'] != 'retry':
                return None, self.operation(operation_id)
            result = json.loads(row['result'])
            if result.get('retry_at', 0) > time.time():
                return None, {**result, 'retry_after': max(1, int(result['retry_at'] - time.time()))}
            self.db.execute("UPDATE operations SET state='sending' WHERE operation_id=?", (operation_id,))
            self.db.commit()
            return row['random_id'], None
        random_id = int.from_bytes(hashlib.sha256(operation_id.encode()).digest()[:8], 'big') & ((1 << 63) - 1)
        self.db.execute('INSERT INTO operations(operation_id,payload_hash,peer,random_id,state) VALUES(?,?,?,?,?)',
                        (operation_id, digest, str(data['external_user_id']), random_id, 'sending'))
        self.db.execute('UPDATE operations SET payload=? WHERE operation_id=?', (json.dumps(stable) if data.get('action') == 'edit' else '{}', operation_id))
        self.db.commit()
        return random_id, None

    def finish(self, operation_id, state, **result):
        result['state'] = state
        self.db.execute('UPDATE operations SET state=?,result=? WHERE operation_id=?', (state, json.dumps(result), operation_id))
        if state == 'sent':
            peer = self.db.execute('SELECT peer FROM operations WHERE operation_id=?', (operation_id,)).fetchone()['peer']
            self.db.executemany('INSERT OR IGNORE INTO sent_messages(peer,message_id) VALUES(?,?)', [(peer, str(mid)) for mid in result.get('external_message_ids', [])])
        if state in ('sent', 'failed'):
            self.db.execute("UPDATE operations SET payload='{}' WHERE operation_id=?", (operation_id,))
        self.db.commit()
        return result

    def edit_payload(self, operation_id):
        row = self.db.execute("SELECT payload FROM operations WHERE operation_id=? AND state='unknown'", (operation_id,)).fetchone()
        payload = json.loads(row['payload']) if row else {}
        return payload if payload.get('action') == 'edit' else None

    def map_random_id(self, random_id, message_id):
        row = self.db.execute('SELECT operation_id FROM operations WHERE random_id=?', (random_id,)).fetchone()
        if row:
            self.finish(row['operation_id'], 'sent', external_message_id=str(message_id), external_message_ids=[str(message_id)])

    def save_event(self, event, media=False):
        if event['event_type'] != 'deleted' and self.db.execute('SELECT 1 FROM deleted_messages WHERE message_id=?', (str(event['external_message_id']),)).fetchone():
            return False
        key = hashlib.sha256('/'.join(str(event.get(k, '')) for k in ('external_account_id', 'external_chat_id', 'external_message_id', 'event_type', 'revision')).encode()).hexdigest()
        self.db.execute('INSERT OR IGNORE INTO events(event_key,peer,message_id,direction,payload,created_at) VALUES(?,?,?,?,?,?)',
                        (key, str(event['external_chat_id']), str(event['external_message_id']), event['direction'], json.dumps(event), time.time()))
        if media:
            job_key = '/'.join(str(event.get(k, '')) for k in ('external_chat_id', 'external_message_id', 'revision'))
            self.db.execute('INSERT OR IGNORE INTO media_jobs(job_key,payload) VALUES(?,?)', (job_key, json.dumps(event)))
        index = {k: event.get(k) for k in ('schema_version', 'channel', 'external_account_id', 'external_chat_id',
                                          'external_user_id', 'external_message_id', 'sender_id', 'direction', 'origin')}
        self.db.execute('INSERT OR REPLACE INTO message_index(message_id,payload) VALUES(?,?)', (str(event['external_message_id']), json.dumps(index)))
        self.db.commit()
        return True

    def events(self):
        cursor = self.db.execute("SELECT value FROM metadata WHERE key='events_cursor'").fetchone()
        after = int(cursor[0]) if cursor else 0
        rows = self.db.execute('SELECT * FROM events WHERE acked=0 AND id>? ORDER BY id LIMIT 200', (after,)).fetchall()
        if not rows:
            rows = self.db.execute('SELECT * FROM events WHERE acked=0 ORDER BY id LIMIT 200').fetchall()
        result = []
        last = 0
        for row in rows:
            last = row['id']
            event = json.loads(row['payload'])
            if row['direction'] == 'outgoing' and event['event_type'] == 'received':
                own = self.db.execute('SELECT 1 FROM sent_messages WHERE peer=? AND message_id=?', (row['peer'], row['message_id'])).fetchone()
                if own:
                    self.ack(row['id'])
                    self.complete(row['id'])
                    continue
                if self.db.execute("SELECT 1 FROM operations WHERE peer=? AND state IN ('sending','unknown') LIMIT 1", (row['peer'],)).fetchone():
                    continue
            result.append({**event, 'journal_id': row['id']})
            if len(result) == 50:
                break
        self.db.execute("INSERT INTO metadata(key,value) VALUES('events_cursor',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (str(last),))
        self.db.commit()
        return result

    def ack(self, event_id):
        self.db.execute('UPDATE events SET acked=1 WHERE id=?', (event_id,))
        self.db.commit()

    def complete(self, event_id):
        self.db.execute('UPDATE events SET completed_at=? WHERE id=? AND acked=1', (time.time(), event_id))
        self.db.commit()

    def queue_media(self, event):
        key = '/'.join(str(event.get(k, '')) for k in ('external_chat_id', 'external_message_id', 'revision'))
        self.db.execute('INSERT OR IGNORE INTO media_jobs(job_key,payload) VALUES(?,?)', (key, json.dumps(event)))
        self.db.commit()

    def pending_media(self):
        return self.db.execute("SELECT * FROM media_jobs WHERE state='pending' AND next_attempt<=? ORDER BY next_attempt,job_key LIMIT 1", (time.time(),)).fetchone()

    def media_finished(self, key):
        self.db.execute("UPDATE media_jobs SET state='completed',completed_at=? WHERE job_key=?", (time.time(), key))
        self.db.commit()

    def media_retry(self, row, seconds=None):
        attempts = row['attempts'] + 1
        seconds = seconds if seconds is not None else min(300, 2 ** min(attempts, 8))
        self.db.execute('UPDATE media_jobs SET attempts=?,next_attempt=? WHERE job_key=?', (attempts, time.time() + max(1, seconds), row['job_key']))
        self.db.commit()

    def deleted_events(self, message_id):
        self.db.execute('INSERT OR IGNORE INTO deleted_messages(message_id) VALUES(?)', (str(message_id),))
        row = self.db.execute('SELECT payload FROM message_index WHERE message_id=?', (str(message_id),)).fetchone()
        if not row:
            row = self.db.execute('SELECT payload FROM events WHERE message_id=? ORDER BY id DESC LIMIT 1', (str(message_id),)).fetchone()
        self.db.execute("UPDATE media_jobs SET state='completed',completed_at=? WHERE json_extract(payload,'$.external_message_id')=?", (time.time(), str(message_id)))
        self.db.commit()
        return [json.loads(row['payload'])] if row else []

    def metrics(self):
        oldest = self.db.execute("SELECT MIN(json_extract(payload,'$.timestamp')) FROM media_jobs WHERE state='pending'").fetchone()[0]
        try:
            age = max(0, time.time() - datetime.fromisoformat(oldest).timestamp()) if oldest else 0
        except (ValueError, TypeError):
            age = 0
        return {'media_oldest_seconds': age, 'unacknowledged': self.db.execute('SELECT count(*) FROM events WHERE acked=0').fetchone()[0],
                'media_pending': self.db.execute("SELECT count(*) FROM media_jobs WHERE state='pending'").fetchone()[0],
                'unknown_operations': self.db.execute("SELECT count(*) FROM operations WHERE state='unknown'").fetchone()[0]}

    def cleanup(self):
        cutoff = time.time() - 86400
        for row in self.db.execute('SELECT id,payload FROM events WHERE completed_at<? LIMIT 100', (cutoff,)).fetchall():
            for item in json.loads(row['payload']).get('attachments', []):
                (self.directory / ('attachment-' + item['key'])).unlink(missing_ok=True)
            self.db.execute('DELETE FROM events WHERE id=?', (row['id'],))
        self.db.execute("DELETE FROM media_jobs WHERE state='completed' AND completed_at<?", (time.time() - 30 * 86400,))
        self.db.commit()

    def next_mock_id(self):
        self.db.execute("INSERT INTO metadata(key,value) VALUES('mock_id','10000') ON CONFLICT(key) DO UPDATE SET value=CAST(value AS INTEGER)+1")
        value = self.db.execute("SELECT value FROM metadata WHERE key='mock_id'").fetchone()[0]
        self.db.commit()
        return str(value)

    def retry_after(self):
        row = self.db.execute("SELECT value FROM metadata WHERE key='flood_until'").fetchone()
        return max(0, int(float(row[0]) - time.time()) + 1) if row else 0

    def pause(self, seconds):
        until = time.time() + max(seconds, self.retry_after())
        self.db.execute("INSERT INTO metadata(key,value) VALUES('flood_until',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (str(until),))
        self.db.commit()
