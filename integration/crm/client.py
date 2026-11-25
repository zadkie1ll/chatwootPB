"""Narrow Bitrix adapter. Never expose webhook URLs in errors or log payloads."""
from datetime import datetime
import os
import re
from urllib.parse import urlsplit
import httpx


class CrmError(Exception):
    def __init__(self, code='crm_unavailable', definitive=False, retryable=False):
        self.code = code
        self.definitive = definitive
        self.retryable = retryable
        super().__init__(code)


def normalize_phone(value):
    if not isinstance(value, str) or not re.fullmatch(r'[+\d ()\-]+', value):
        raise CrmError('invalid_phone')
    digits = re.sub(r'\D', '', value)
    if len(digits) == 11 and digits.startswith('8'):
        digits = '7' + digits[1:]
    if len(digits) == 10 and not value.startswith('+'):
        digits = '7' + digits
    if not re.fullmatch(r'[1-9]\d{6,14}', digits):
        raise CrmError('invalid_phone')
    return '+' + digits


class BitrixClient:
    CRM_METHODS = {'crm.duplicate.findbycomm', 'crm.item.list', 'crm.item.get', 'crm.deal.get', 'crm.deal.list',
                   'crm.lead.list', 'crm.lead.update', 'crm.deal.update', 'crm.deal.userfield.list', 'crm.deal.userfield.add', 'crm.userfield.types'}

    def __init__(self):
        self.webhook = os.environ.get('BITRIX_WEBHOOK_URL', '').rstrip('/')
        self.directory_webhook = os.environ.get('BITRIX_DIRECTORY_WEBHOOK_URL', '').rstrip('/')
        self.portal = os.environ.get('BITRIX_PORTAL_URL', '').rstrip('/')
        if not self.webhook or not self.portal.startswith('https://'):
            raise CrmError('crm_not_configured')
        if urlsplit(self.webhook).netloc != urlsplit(self.portal).netloc:
            raise CrmError('crm_configuration_invalid')

    def call(self, method, params=None):
        if method == 'user.get':
            base = self.directory_webhook
        elif method in self.CRM_METHODS:
            base = self.webhook
        else:
            raise CrmError('crm_method_forbidden')
        if not base or urlsplit(base).scheme != 'https' or urlsplit(base).netloc != urlsplit(self.portal).netloc:
            raise CrmError('crm_configuration_invalid')
        try:
            response = httpx.post(base + '/' + method + '.json', json=params or {}, timeout=10, follow_redirects=False)
            data = response.json()
        except (httpx.HTTPError, ValueError):
            raise CrmError() from None
        if response.status_code >= 400 or 'error' in data:
            code = data.get('error', '')
            if code in ('insufficient_scope', 'INVALID_CREDENTIALS', 'NO_AUTH_FOUND', 'ACCESS_DENIED'):
                raise CrmError('crm_access_denied', definitive=True)
            if response.status_code == 429 or code in ('QUERY_LIMIT_EXCEEDED', 'OPERATION_TIME_LIMIT'):
                raise CrmError('crm_rate_limited', definitive=True, retryable=True)
            raise CrmError('crm_rejected', definitive=response.status_code in (400, 401, 403, 404, 422))
        if 'result' not in data:
            raise CrmError('crm_invalid_response')
        return data

    def employees(self, employee_id=None):
        result = []
        start = 0
        for _ in range(10):
            filters = {'ACTIVE': True, 'USER_TYPE': 'employee'}
            if employee_id is not None:
                filters['ID'] = employee_id
            page = self.call('user.get', {'filter': filters, 'start': start})
            for user in page['result']:
                if str(user.get('ACTIVE', True)).lower() not in ('true', 'y', '1'):
                    continue
                result.append({'id': str(user['ID']), 'name': ' '.join(filter(None, [user.get('NAME'), user.get('LAST_NAME')]))[:150],
                               'email': user.get('EMAIL', '')[:254]})
            if employee_id is not None or page.get('next') is None:
                return result
            start = page['next']
        raise CrmError('crm_directory_too_large')

    def deal_id(self, value):
        parsed = urlsplit(value)
        if parsed.scheme != 'https' or parsed.netloc != urlsplit(self.portal).netloc or parsed.username or parsed.password:
            raise CrmError('invalid_deal_url')
        match = re.fullmatch(r'/crm/deal/details/([1-9]\d{0,17})/?', parsed.path)
        if not match:
            raise CrmError('invalid_deal_url')
        return int(match[1])

    def entity_and_id(self, value):
        parsed = urlsplit(value)
        if parsed.scheme != 'https' or parsed.netloc != urlsplit(self.portal).netloc or parsed.username or parsed.password:
            raise CrmError('invalid_deal_url')
        match = re.fullmatch(r'/crm/(deal|lead)/details/([1-9]\d{0,17})/?', parsed.path)
        if not match:
            raise CrmError('invalid_deal_url')
        return match[1], int(match[2])

    def resolve_lead(self, variants, bindings):
        found = self.call('crm.duplicate.findbycomm', {'entity_type': 'LEAD', 'type': 'PHONE', 'values': variants})['result']
        ids = found.get('LEAD', []) if isinstance(found, dict) else []
        if len(ids) > 200:
            raise CrmError('crm_too_many_matches')
        matches = {'@id': ids, '@contactIds': bindings.get('CONTACT', []), '@companyId': bindings.get('COMPANY', [])}
        alternatives = [{field: values} for field, values in matches.items() if values]
        if not alternatives:
            return None
        # A lead can store its phone only on the linked contact in the Client
        # field. Match every linked contact, not only the legacy primary one.
        either = {'logic': 'OR', **{str(i): condition for i, condition in enumerate(alternatives)}}
        result = self.call('crm.item.list', {'entityTypeId': 1,
            'filter': {'=stageSemanticId': 'P', '0': either},
            'order': {'createdTime': 'DESC', 'id': 'DESC'},
            'select': ['id', 'title', 'assignedById', 'contactIds']})['result']['items']
        return self.present_item(result[0], 'lead') if result else None

    def present_lead(self, item):
        return {'found': True, 'entity_type': 'lead', 'deal_id': str(item['ID']), 'title': str(item.get('TITLE', ''))[:250],
                'assigned_user_id': str(item['ASSIGNED_BY_ID']), 'contact_ids': [],
                'deal_url': self.portal + '/crm/lead/details/' + str(item['ID']) + '/', 'portal': self.portal}

    def resolve(self, phone='', deal_url=''):
        if bool(phone) == bool(deal_url):
            raise CrmError('provide_phone_or_deal')
        if deal_url:
            entity_type, deal_id = self.entity_and_id(deal_url)
            if entity_type == 'lead':
                return self.present_lead(self.read_fields(deal_id, ['TITLE', 'ASSIGNED_BY_ID'], 'lead'))
            item = self.call('crm.item.get', {'entityTypeId': 2, 'id': deal_id})['result']['item']
            return self.present_item(item)
        phone = normalize_phone(phone)
        variants = [phone, phone[1:]]
        if phone.startswith('+7') and len(phone) == 12:
            variants.append('8' + phone[2:])
        candidates = []
        bindings = {}
        for entity, field in [('CONTACT', 'contactIds'), ('COMPANY', 'companyId')]:
            found = self.call('crm.duplicate.findbycomm', {'entity_type': entity, 'type': 'PHONE', 'values': variants})['result']
            ids = found.get(entity, []) if isinstance(found, dict) else []
            bindings[entity] = ids
            if not ids:
                continue
            if len(ids) > 200:
                raise CrmError('crm_too_many_matches')
            page = self.call('crm.item.list', {'entityTypeId': 2,
                'filter': {'@' + field: ids, '=closed': 'N'}, 'order': {'createdTime': 'DESC', 'id': 'DESC'},
                'select': ['id', 'title', 'assignedById', 'contactIds', 'companyId', 'createdTime', 'closed']})['result']
            # Each filtered query is sorted before paging; only its newest item is needed.
            if page.get('items'):
                candidates.append(page['items'][0])
        if not candidates:
            lead = self.resolve_lead(variants, bindings)
            return {**lead, 'phone': phone} if lead else {'found': False, 'phone': phone, 'portal': self.portal}
        def order(item):
            try:
                stamp = datetime.fromisoformat(item['createdTime']).timestamp()
            except (KeyError, ValueError):
                raise CrmError('crm_invalid_response') from None
            return stamp, int(item['id'])
        return {**self.present_item(max(candidates, key=order)), 'phone': phone}

    def present_item(self, item, entity_type='deal'):
        deal_id = str(item['id'])
        if not re.fullmatch(r'[1-9]\d{0,17}', deal_id):
            raise CrmError('crm_invalid_response')
        return {'found': True, 'entity_type': entity_type, 'deal_id': deal_id, 'title': str(item.get('title', ''))[:250],
                'assigned_user_id': str(item['assignedById']),
                'contact_ids': [str(value) for value in item.get('contactIds', [])],
                'deal_url': self.portal + '/crm/' + entity_type + '/details/' + deal_id + '/', 'portal': self.portal}

    def converted_deal(self, lead_id):
        result = self.call('crm.deal.list', {'filter': {'=LEAD_ID': int(lead_id), '=CLOSED': 'N'},
                                            'order': {'DATE_CREATE': 'DESC', 'ID': 'DESC'},
                                            'select': ['ID', 'TITLE', 'ASSIGNED_BY_ID']})['result']
        if not result:
            return None
        item = result[0]
        return {'deal_id': str(item['ID']), 'title': str(item.get('TITLE', ''))[:250],
                'assigned_user_id': str(item['ASSIGNED_BY_ID']),
                'deal_url': self.portal + '/crm/deal/details/' + str(item['ID']) + '/'}

    def desired_fields(self, payload):
        public_url = os.environ.get('CHATWOOT_PUBLIC_URL', '').rstrip('/')
        url = payload['chat_url']
        parsed = urlsplit(public_url)
        local_mock = (os.environ.get('TELEGRAM_MODE') == 'mock' and parsed.scheme == 'http'
                      and parsed.hostname in ('localhost', '127.0.0.1'))
        if (parsed.scheme != 'https' and not local_mock) or not url.startswith(public_url + '/app/accounts/'):
            raise CrmError('invalid_chat_url')
        suffix = url[len(public_url):]
        if not re.fullmatch(r'/app/accounts/[1-9]\d*/conversations/[1-9]\d*', suffix):
            raise CrmError('invalid_chat_url')
        entity = payload.get('entity_type', 'deal')
        prefix = 'BITRIX_LEAD_' if entity == 'lead' else 'BITRIX_'
        fields = {
            os.environ.get(prefix + 'MANAGER_CHAT_FIELD', 'UF_CRM_CW_MANAGER_CHAT'): url,
            os.environ.get(prefix + 'SUPERVISOR_CHAT_FIELD', 'UF_CRM_CW_SUPERVISOR_CHAT'): url,
        }
        messenger_field = os.environ.get(prefix + 'MESSENGER_FIELD')
        if messenger_field:
            fields[messenger_field] = url + '?messenger=Telegram'
        for name in fields:
            if not re.fullmatch(r'UF_CRM_[A-Z0-9_]{1,43}', name):
                raise CrmError('crm_configuration_invalid')
        if payload.get('assigned_user_id'):
            fields['ASSIGNED_BY_ID'] = int(payload['assigned_user_id'])
        return fields

    def matches(self, deal_id, fields, entity_type='deal'):
        item = self.read_fields(deal_id, list(fields), entity_type)
        return all(str(item.get(key, '')) == str(value) for key, value in fields.items())

    def read_fields(self, deal_id, names, entity_type='deal'):
        if entity_type not in ('deal', 'lead'):
            raise CrmError('crm_configuration_invalid')
        result = self.call('crm.' + entity_type + '.list', {'filter': {'=ID': int(deal_id)}, 'select': ['ID', *names]})['result']
        if not result:
            raise CrmError('crm_deal_unavailable', definitive=True)
        return result[0]

    def update(self, deal_id, fields, entity_type='deal'):
        if entity_type not in ('deal', 'lead'):
            raise CrmError('crm_configuration_invalid')
        result = self.call('crm.' + entity_type + '.update', {'id': deal_id, 'fields': fields})['result']
        if result is not True:
            raise CrmError('crm_rejected', definitive=True)
