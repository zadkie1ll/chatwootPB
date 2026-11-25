#!/usr/bin/env python3
"""Reuse the server's configured CRM profile. Secrets never leave this host."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

ROOT = Path(__file__).resolve().parents[2]


def call(base, method, payload=None):
    try:
        request = Request(base.rstrip('/') + '/' + method + '.json', data=json.dumps(payload or {}).encode(),
                          headers={'Content-Type': 'application/json'})
        with urlopen(request, timeout=20) as response:
            result = json.load(response)
    except (HTTPError, URLError, TimeoutError, ValueError):
        raise SystemExit('Bitrix metadata call failed: ' + method) from None
    if 'error' in result or 'result' not in result:
        raise SystemExit('Bitrix metadata permission/response error: ' + method)
    return result['result']


def expose_messenger_fields(base, values):
    """Preserve card layouts and append only our URL field, including existing personal views."""
    categories = call(base, 'crm.category.list', {'entityTypeId': 2}).get('categories', [])
    category_ids = sorted({0, *(int(item['id']) for item in categories)})
    owner_id = int(urlsplit(base).path.rstrip('/').split('/')[-2])
    users = sorted({owner_id, 460, 110})
    changed = []
    snapshot = ROOT / 'secrets' / 'bitrix-card-layouts-before-messenger'
    snapshot.mkdir(mode=0o700, exist_ok=True)
    for entity in ('lead', 'deal'):
        prefix = 'BITRIX_' if entity == 'deal' else 'BITRIX_LEAD_'
        field = values[prefix + 'MESSENGER_FIELD']
        for category in category_ids if entity == 'deal' else [0]:
            for user in [None, *users]:
                params = {'scope': 'C' if user is None else 'P'}
                if entity == 'deal':
                    params['extras'] = {'dealCategoryId': category}
                if user is not None:
                    params['userId'] = user
                sections = call(base, 'crm.' + entity + '.details.configuration.get', params)
                # An absent personal configuration inherits the common one.
                # Do not replace a generated default view with a one-field form.
                if not sections:
                    continue
                if any(e.get('name') == field for section in sections for e in section.get('elements', [])):
                    continue
                key = entity + '-' + str(category) + '-' + ('common' if user is None else str(user))
                location = snapshot / (key + '.json')
                if not location.exists():
                    location.write_text(json.dumps({'params': params, 'sections': sections}, ensure_ascii=False, indent=2) + '\n')
                    location.chmod(0o600)
                sections.append({'name': 'corporate_messenger', 'title': 'Переписка в Telegram', 'type': 'section', 'elements': [{'name': field}]})
                call(base, 'crm.' + entity + '.details.configuration.set', {**params, 'data': sections})
                verified = call(base, 'crm.' + entity + '.details.configuration.get', params)
                if not any(e.get('name') == field for section in verified for e in section.get('elements', [])):
                    raise SystemExit('Messenger field not present in updated card layout')
                changed.append(key)
    return changed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--create-fields', action='store_true')
    parser.add_argument('--enable', action='store_true')
    parser.add_argument('--messenger-fields', action='store_true', help='Rename original text fields and create URL messenger fields')
    options = parser.parse_args()
    os.umask(0o077)
    location = ROOT / '.env'
    values = dict(line.split('=', 1) for line in location.read_text().splitlines() if line and not line.startswith('#'))
    container = json.loads(subprocess.check_output(['docker', 'inspect', 'bitrix_gateway_backend']))[0]
    profiles = dict(item.split('=', 1) for item in container['Config']['Env'])
    messaging = values.get('BITRIX_WEBHOOK_URL') or profiles.get('BITRIX_PROFILE_MESSAGING_WEBHOOK_URL')
    directory = values.get('BITRIX_DIRECTORY_WEBHOOK_URL') or profiles.get('BITRIX_PROFILE_DEFAULT_WEBHOOK_URL')
    if not messaging or not directory:
        raise SystemExit('Existing Bitrix messaging/directory connection is missing')
    parsed = urlsplit(messaging)
    portal = parsed.scheme + '://' + parsed.netloc
    if parsed.scheme != 'https' or urlsplit(directory).netloc != parsed.netloc:
        raise SystemExit('CRM profile domains do not match')
    call(messaging, 'crm.deal.fields')
    owner_id = urlsplit(directory).path.rstrip('/').split('/')[-2]
    call(directory, 'user.get', {'filter': {'ID': owner_id}})
    definitions = [
        ('BITRIX_MANAGER_CHAT_FIELD', 'UF_CRM_CW_MANAGER_CHAT', 'Переписка Telegram — менеджер', 'Telegram chat — manager'),
        ('BITRIX_SUPERVISOR_CHAT_FIELD', 'UF_CRM_CW_SUPERVISOR_CHAT', 'Переписка Telegram — руководитель', 'Telegram chat — supervisor'),
    ]
    created = []
    renamed = []
    for entity in ['deal', 'lead']:
        prefix = 'BITRIX_' if entity == 'deal' else 'BITRIX_LEAD_'
        fields_to_manage = [(prefix + 'MANAGER_CHAT_FIELD', definitions[0][1], definitions[0][2], definitions[0][3]),
                            (prefix + 'SUPERVISOR_CHAT_FIELD', definitions[1][1], definitions[1][2], definitions[1][3])]
        if options.messenger_fields:
            original = 'UF_CRM_1795592293' if entity == 'deal' else 'UF_CRM_1795592257'
            prior = call(directory, 'crm.' + entity + '.userfield.list', {'filter': {'FIELD_NAME': original}})
            if prior and prior[0].get('USER_TYPE_ID') == 'string':
                call(directory, 'crm.' + entity + '.userfield.update', {'id': prior[0]['ID'], 'fields': {
                    'EDIT_FORM_LABEL': {'ru': 'Мессенджер (прежнее текстовое поле)', 'en': 'Messenger (original text field)'},
                    'LIST_COLUMN_LABEL': {'ru': 'Мессенджер (прежнее текстовое поле)', 'en': 'Messenger (original text field)'},
                    'LIST_FILTER_LABEL': {'ru': 'Мессенджер (прежнее текстовое поле)', 'en': 'Messenger (original text field)'}}})
                renamed.append(entity + ':' + original)
            fields_to_manage.append((prefix + 'MESSENGER_FIELD', 'UF_CRM_CW_MESSENGER', 'Мессенджер', 'Messenger'))
        for variable, default, russian, english in fields_to_manage:
            code = values.get(variable) or default
            if not re.fullmatch(r'UF_CRM_[A-Z0-9_]{1,43}', code):
                raise SystemExit('Invalid managed CRM field name')
            fields = call(directory, 'crm.' + entity + '.userfield.list', {'filter': {'FIELD_NAME': code}})
            if fields:
                if fields[0].get('USER_TYPE_ID') != 'url' or fields[0].get('MULTIPLE') != 'N':
                    raise SystemExit('Existing CRM field has incompatible type: ' + code)
            elif options.create_fields:
                call(directory, 'crm.' + entity + '.userfield.add', {'fields': {
                    'FIELD_NAME': code.removeprefix('UF_CRM_'), 'USER_TYPE_ID': 'url', 'MULTIPLE': 'N', 'MANDATORY': 'N',
                    'XML_ID': 'chatwoot_' + code.lower(), 'SHOW_IN_LIST': 'Y', 'EDIT_IN_LIST': 'N', 'IS_SEARCHABLE': 'N', 'SORT': 700,
                    'EDIT_FORM_LABEL': {'ru': russian, 'en': english}, 'LIST_COLUMN_LABEL': {'ru': russian, 'en': english}}})
                created.append(entity + ':' + code)
            else:
                raise SystemExit('CRM fields are missing; use --create-fields after implementation checks')
            values[variable] = code
    layouts = expose_messenger_fields(directory, values) if options.messenger_fields else []
    values.update(BITRIX_WEBHOOK_URL=messaging.rstrip('/'), BITRIX_DIRECTORY_WEBHOOK_URL=directory.rstrip('/'), BITRIX_PORTAL_URL=portal)
    values.setdefault('BITRIX_ENABLED', 'false')
    values.setdefault('CORPORATE_SHARED_INTAKE_ENABLED', 'false')
    if options.enable:
        values.update(BITRIX_ENABLED='true', CORPORATE_SHARED_INTAKE_ENABLED='true')
    location.write_text('# Private server configuration\n' + ''.join(key + '=' + value + '\n' for key, value in values.items()))
    os.chmod(location, 0o600)
    report = {'portal': portal, 'fields_created': created, 'text_fields_renamed': renamed, 'card_layouts_updated': layouts, 'employee_directory_verified': True,
              'enabled': values['BITRIX_ENABLED'] == 'true', 'secrets_printed': False}
    (ROOT / 'docs/evidence/bitrix-configuration.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
