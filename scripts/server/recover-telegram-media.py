#!/usr/bin/env python3
"""Requeue legacy failed media from the server journal, without exporting content."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[2]
code = '''
import json,os
from tg_gateway.journal import Journal
journal = Journal(os.environ['TELEGRAM_DATA_DIR'])
rows = journal.db.execute("SELECT payload FROM events WHERE json_extract(payload,'$.attachment_error')='attachment_too_large' AND json_extract(payload,'$.event_type') IN ('received','edited') LIMIT 1000").fetchall()
for row in rows:
    event=json.loads(row['payload'])
    event.pop('attachment_error',None)
    event['attachment_state']='pending'
    journal.queue_media(event)
print(json.dumps({'legacy_media_candidates':len(rows),'requeued_without_exporting_customer_data':True}))
journal.db.close()
'''
# Run while the gateway process is stopped: Journal startup marks interrupted
# sends unknown. Never open a second active Journal writer against its session.
config = subprocess.check_output(['bash',str(root/'scripts/compose.sh'),'ps','--services','--status','running'],cwd=root,text=True)
if 'telegram-gateway' in config.splitlines():
    raise SystemExit('Stop only telegram-gateway before legacy recovery, then start it again')
subprocess.run(['bash',str(root/'scripts/compose.sh'),'run','--rm','--no-deps','telegram-gateway','python','-c',code],cwd=root,check=True)
