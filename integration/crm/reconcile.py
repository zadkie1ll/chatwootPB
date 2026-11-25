import time
import httpx
from delivery import transport
from delivery.maintenance import heartbeat
from .client import BitrixClient, CrmError


def reconcile_batch(after=0):
    records = transport.cw('GET', '/crm/links', params={'after': after}).get('links', [])
    if not records:
        return 0
    client = BitrixClient()
    for link in records:
        heartbeat('crm')
        try:
            external = str(client.read_fields(link['deal_id'], ['ASSIGNED_BY_ID'], link.get('entity_type', 'deal'))['ASSIGNED_BY_ID'])
        except CrmError as error:
            if not error.definitive or error.retryable:
                raise
            # A deleted/inaccessible deal must not starve all later bindings.
            time.sleep(0.6)
            continue
        if link.get('entity_type') == 'lead':
            converted = client.converted_deal(link['deal_id'])
            if converted:
                try:
                    transport.cw('POST', '/crm/target', json={**converted, 'id': link['id'], 'operation_id': link['operation_id'],
                                                            'assignment_version': link['assignment_version']})
                except httpx.HTTPStatusError as error:
                    if error.response.status_code != 409:
                        raise
                time.sleep(0.6)
                continue
        if external != link.get('owner_external_user_id'):
            try:
                transport.cw('POST', '/crm/owner', json={
                    'id': link['id'], 'operation_id': link['operation_id'], 'assignment_version': link['assignment_version'],
                    'external_user_id': external})
            except httpx.HTTPStatusError as error:
                if error.response.status_code != 409:
                    raise
        # This process is separate from Telegram delivery. Stay below a 2 req/s read rate.
        time.sleep(0.6)
    return records[-1]['id'] if len(records) == 20 else 0
