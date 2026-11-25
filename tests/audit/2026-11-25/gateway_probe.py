import asyncio,json,tempfile,sys
from pathlib import Path
from types import SimpleNamespace
from datetime import datetime,timezone
from unittest.mock import AsyncMock
from telethon.client.downloads import DownloadMethods
sys.path.insert(0, '/app')
from tg_gateway.driver import PersonalDriver
from tg_gateway.journal import Journal

async def run():
 result={}
 with tempfile.TemporaryDirectory() as directory:
  journal=Journal(directory);driver=PersonalDriver(directory,journal);driver.account_id='1';driver.ready.set()
  message=SimpleNamespace(id=10,sender_id=2,message='synthetic document',out=False,edit_date=None,date=datetime.now(timezone.utc),media=SimpleNamespace(ttl_seconds=None),ttl_period=None,photo=None,document=SimpleNamespace(size=8),file=SimpleNamespace(name='synthetic.pdf',mime_type='application/pdf'),voice=False)
  event=SimpleNamespace(is_private=True,chat_id=2,message=message,get_chat=AsyncMock(return_value=SimpleNamespace(id=2,first_name='Synthetic',last_name='',phone=None,bot=False)))
  async def download(message,file):
   target=DownloadMethods._get_proper_filename(file,'document','.pdf')
   Path(target).write_bytes(b'%PDF-1.4')
   return target
  driver.client=SimpleNamespace(download_media=download)
  await driver.save_message(event,'received')
  saved=journal.events()[0]
  result['pdf_downloaded_but_not_attached']=saved['attachments']==[]
  result['small_valid_file_misreported_too_large']=saved['attachment_error']=='attachment_too_large'
  result['suffixed_file_left_orphaned']=bool(list(Path(directory).glob('attachment-*.pdf')))
  journal.db.close()
 with tempfile.TemporaryDirectory() as directory:
  journal=Journal(directory);driver=PersonalDriver(directory,journal);driver.account_id='1';driver.ready.set()
  driver.client=SimpleNamespace(download_media=AsyncMock(side_effect=OSError('synthetic transient download failure')))
  failed=False
  try: await driver.save_message(event,'received')
  except OSError: failed=True
  result['transient_download_failure_escapes_handler']=failed
  result['no_durable_event_saved_on_download_failure']=journal.db.execute('select count(*) from events').fetchone()[0]==0
  journal.db.close()
 assert all(result.values()),result
 print(json.dumps(result,indent=2))
asyncio.run(run())
