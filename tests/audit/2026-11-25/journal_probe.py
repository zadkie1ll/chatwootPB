import json,tempfile,sys
sys.path.insert(0,'gateways/telegram')
from tg_gateway.journal import Journal
r={}
with tempfile.TemporaryDirectory() as directory:
 j=Journal(directory)
 j.begin_operation({'operation_id':'00000000-0000-0000-0000-000000000001','external_user_id':'11','text':'synthetic'})
 j.finish('00000000-0000-0000-0000-000000000001','sent',external_message_ids=['1'])
 j.save_event({'external_account_id':'mock','external_chat_id':'11','external_message_id':'1','direction':'outgoing','event_type':'edited','revision':'edit-1','text':'synthetic changed'})
 r['own_sent_edit_discarded'] = j.events()==[]
 r['edit_marked_acked'] = j.db.execute('select acked from events').fetchone()[0]==1
 j.db.close()
with tempfile.TemporaryDirectory() as directory:
 j=Journal(directory)
 j.begin_operation({'operation_id':'00000000-0000-0000-0000-000000000002','external_user_id':'11','text':'synthetic'})
 j.finish('00000000-0000-0000-0000-000000000002','unknown')
 for n in range(100):
  j.save_event({'external_account_id':'mock','external_chat_id':'11','external_message_id':str(n),'direction':'outgoing','event_type':'received'})
 j.save_event({'external_account_id':'mock','external_chat_id':'22','external_message_id':'999','direction':'incoming','event_type':'received','text':'new synthetic incoming'})
 r['head_100_ambiguous_outgoing_hide_later_incoming'] = j.events()==[]
 r['same_on_next_poll'] = j.events()==[]
 j.db.close()
assert all(r.values()),r
print(json.dumps(r,indent=2))
