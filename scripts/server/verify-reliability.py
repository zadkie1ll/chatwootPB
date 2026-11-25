import json,subprocess,hashlib
from pathlib import Path
from datetime import datetime,timezone
root=Path(__file__).resolve().parents[2]
def run(args,code=None):
    return subprocess.check_output(['bash',str(root/'scripts/compose.sh')]+args,cwd=root,input=code,text=True).strip()
rails='''
require 'sidekiq/api'
a=Account.find(ENV.fetch('CORPORATE_ACCOUNT_ID'))
raise 'Enterprise enabled' if ChatwootApp.enterprise?
rows=CorporateCrmEmployee.where(account:a).order(:user_id).pluck(:user_id,:external_user_id)
puts JSON.generate({enterprise:false,crm_enabled:Corporate.crm_enabled?(a),staff_mappings:rows,edit_action_column:CorporateDelivery.column_names.include?('action'),lead_entity_column:CorporateCrmLink.column_names.include?('entity_type'),attachment_states:Attachment.where(account:a).map{|f|f.meta.to_h['scan_state']}.tally,sidekiq_healthy:Sidekiq::ProcessSet.new.any?{|p|Time.current.to_f-p['beat'].to_f<120}})
'''
# Metadata only: no message content, phone numbers, CRM records or session export.
runtime=json.loads(run(['exec','-T','chatwoot-web','bundle','exec','rails','runner','-'],rails).splitlines()[-1])
code='''
import os,json,urllib.request
req=urllib.request.Request('http://127.0.0.1:8090/health/details/',headers={'Authorization':'Bearer '+os.environ['INTEGRATION_API_TOKEN']})
print(json.dumps(json.load(urllib.request.urlopen(req,timeout=20))))
'''
health=json.loads(run(['exec','-T','integration-web','python','-c',code]))
services=[json.loads(s) for s in run(['ps','--format','json']).splitlines()]
services=[{k:s.get(k) for k in ['Service','State','Health']} for s in services]
container_ids=run(['ps','-q']).splitlines()
containers=json.loads(subprocess.check_output(['docker','inspect',*container_ids],text=True))
limits=[{'service':c['Config']['Labels']['com.docker.compose.service'],'memory_bytes':c['HostConfig']['Memory'],'log_config':c['HostConfig']['LogConfig']} for c in containers]
import urllib.request
values=dict(line.split('=',1) for line in (root/'.env').read_text().splitlines() if line and not line.startswith('#'))
def crm_call(method,payload):
    request=urllib.request.Request(values['BITRIX_DIRECTORY_WEBHOOK_URL'].rstrip('/')+'/'+method+'.json',data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'})
    result=json.load(urllib.request.urlopen(request,timeout=30))
    assert 'error' not in result, 'CRM metadata verification failed'
    return result['result']
crm_fields={}
for entity,old in [('deal','UF_CRM_1795592293'),('lead','UF_CRM_1795592257')]:
    fields=crm_call('crm.'+entity+'.userfield.list',{})
    selected={f['FIELD_NAME']:f for f in fields if f['FIELD_NAME'] in (old,'UF_CRM_CW_MESSENGER')}
    assert selected['UF_CRM_CW_MESSENGER']['USER_TYPE_ID']=='url'
    assert selected[old]['USER_TYPE_ID']=='string'
    verified={}
    for key,f in selected.items():
        detail=crm_call('crm.'+entity+'.userfield.get',{'id':f['ID']})
        verified[key]={'type':detail['USER_TYPE_ID'],'label':detail.get('EDIT_FORM_LABEL')}
    assert verified['UF_CRM_CW_MESSENGER']['label']['ru']=='Мессенджер'
    assert 'прежнее текстовое поле' in verified[old]['label']['ru']
    crm_fields[entity]=verified
config=json.loads((root/'docs/evidence/bitrix-configuration.json').read_text())
report={'executed_at':datetime.now(timezone.utc).isoformat(),'runtime':runtime,'pipeline':health,'services':services,'resource_limits':limits,'crm_configuration':config,'crm_field_verification':crm_fields,'real_customer_test_messages_sent':False,'backup_automation_changed':False}
assert [5,'460'] in runtime['staff_mappings'] and [6,'110'] in runtime['staff_mappings']
assert runtime['enterprise'] is False and runtime['crm_enabled'] and runtime['edit_action_column'] and runtime['lead_entity_column'] and runtime['sidekiq_healthy']
assert health['telegram']['connected']
assert all(s['State']=='running' and s['Health']=='healthy' for s in services)
assert all(c['memory_bytes']>0 and c['log_config']['Config'].get('max-size')=='10m' for c in limits)
report['passed']=True
(root/'docs/evidence/audit-fixes-production.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
