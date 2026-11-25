"""Synthetic TLS Bitrix REST server. Never deployed to the company server."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import ssl

DEALS = {
    '501': {'id': 501, 'title': 'Synthetic older deal', 'assignedById': 22, 'contactIds': [101], 'companyId': 0,
            'createdTime': '2026-11-20T12:00:00+03:00', 'closed': False},
    '502': {'id': 502, 'title': 'Synthetic newest deal', 'assignedById': 22, 'contactIds': [101], 'companyId': 0,
            'createdTime': '2026-11-21T12:00:00+03:00', 'closed': False},
    '503': {'id': 503, 'title': 'Synthetic closed deal', 'assignedById': 22, 'contactIds': [101], 'companyId': 0,
            'createdTime': '2026-11-22T12:00:00+03:00', 'closed': True},
    '601': {'id': 601, 'title': 'Synthetic manual deal', 'assignedById': 22, 'contactIds': [102], 'companyId': 0,
            'createdTime': '2026-11-21T12:00:00+03:00', 'closed': False},
    '701': {'id': 701, 'title': 'Synthetic browser deal', 'assignedById': 22, 'contactIds': [103], 'companyId': 0,
            'createdTime': '2026-11-21T12:00:00+03:00', 'closed': False},
}
LEADS = {
    '901': {'ID': '901', 'TITLE': 'Synthetic open lead', 'ASSIGNED_BY_ID': 22, 'STATUS_SEMANTIC_ID': 'P', 'DATE_CREATE': '2026-11-25'},
    '905': {'ID': '905', 'TITLE': 'Synthetic contact-only lead', 'ASSIGNED_BY_ID': 22, 'STATUS_SEMANTIC_ID': 'P', 'DATE_CREATE': '2026-11-25', 'contactIds': [104]},
    '906': {'ID': '906', 'TITLE': 'Synthetic closed contact lead', 'ASSIGNED_BY_ID': 22, 'STATUS_SEMANTIC_ID': 'F', 'DATE_CREATE': '2026-11-26', 'contactIds': [104]},
    '902': {'ID': '902', 'TITLE': 'Synthetic converted lead', 'ASSIGNED_BY_ID': 22, 'STATUS_SEMANTIC_ID': 'S', 'DATE_CREATE': '2026-11-26'},
}
UPDATES = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/test/state':
            self.reply({'deals': DEALS, 'leads': LEADS, 'updates': UPDATES})
        else:
            self.reply({'status': 'synthetic-bitrix'})

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        method = self.path.rsplit('/', 1)[-1].removesuffix('.json')
        if method == 'convert':
            DEALS['903'] = {'id': 903, 'title': 'Synthetic converted deal', 'assignedById': 22, 'contactIds': [], 'companyId': 0,
                            'createdTime': '2026-11-25T12:00:00+03:00', 'closed': False, 'leadId': 901}
            LEADS['901']['STATUS_SEMANTIC_ID'] = 'S'
            self.reply({'ok': True})
        elif method == 'user.get':
            users = [{'ID': '11', 'NAME': 'Synthetic', 'LAST_NAME': 'A', 'EMAIL': 'lab-a@example.invalid', 'ACTIVE': True},
                     {'ID': '22', 'NAME': 'Synthetic', 'LAST_NAME': 'B', 'EMAIL': 'lab-b@example.invalid', 'ACTIVE': True}]
            target = data.get('filter', {}).get('ID')
            self.reply({'result': [u for u in users if target is None or u['ID'] == str(target)]})
        elif method == 'crm.duplicate.findbycomm':
            found = any(value.replace('+', '') in ('79991234567', '89991234567') for value in data['values'])
            result = {'CONTACT': [101]} if found and data['entity_type'] == 'CONTACT' else {}
            if data['entity_type'] == 'CONTACT' and any(value.replace('+', '') in ('79990000222', '89990000222') for value in data['values']):
                result = {'CONTACT': [104]}
            if data['entity_type'] == 'LEAD' and any(value.replace('+','') in ('79990000111','89990000111') for value in data['values']):
                result = {'LEAD': [902,901]}
            self.reply({'result': result})
        elif method == 'crm.item.list':
            filters = data.get('filter', {})
            if data['entityTypeId'] == 1:
                assert filters.get('=stageSemanticId') == 'P'
                alternatives = filters['0']
                assert alternatives['logic'] == 'OR'
                items = [{'id': int(l['ID']), 'title': l['TITLE'], 'assignedById': l['ASSIGNED_BY_ID'],
                          'contactIds': l.get('contactIds', []), 'companyId': l.get('companyId', 0),
                          'createdTime': l['DATE_CREATE'], 'stageSemanticId': l['STATUS_SEMANTIC_ID']} for l in LEADS.values()]
                def matches(item):
                    for key, condition in alternatives.items():
                        if key == 'logic':
                            continue
                        for field, ids in condition.items():
                            value = item.get(field[1:])
                            if any(v in ids for v in value) if isinstance(value, list) else value in ids:
                                return True
                    return False
                items = [i for i in items if i['stageSemanticId'] == 'P' and matches(i)]
                items.sort(key=lambda i: (i['createdTime'], i['id']), reverse=True)
                self.reply({'result': {'items': items}})
                return
            assert filters.get('=closed') == 'N' and ('@contactIds' in filters or '@companyId' in filters)
            matches = [d for d in DEALS.values() if not d['closed'] and any(v in d['contactIds'] for v in filters.get('@contactIds', []))]
            matches.sort(key=lambda d: (d['createdTime'], d['id']), reverse=True)
            self.reply({'result': {'items': matches}})
        elif method == 'crm.item.get':
            item = DEALS.get(str(data['id']))
            self.reply({'result': {'item': item}} if item else {'error': 'NOT_FOUND'}, 200 if item else 404)
        elif method == 'crm.deal.get':
            item = DEALS[str(data['id'])]
            self.reply({'result': {**item, 'ASSIGNED_BY_ID': item['assignedById']}})
        elif method == 'crm.deal.list':
            filters = data['filter']
            if '=LEAD_ID' in filters:
                found = [d for d in DEALS.values() if str(d.get('leadId')) == str(filters['=LEAD_ID']) and not d['closed']]
                found.sort(key=lambda d:(d['createdTime'],d['id']),reverse=True)
                item = found[0] if found else None
            else:
                item = DEALS.get(str(filters['=ID']))
            values = {**item, 'ID': item['id'], 'ASSIGNED_BY_ID': item['assignedById']} if item else {}
            self.reply({'result': [{key: values[key] for key in data['select'] if key in values}] if item else []})
        elif method == 'crm.lead.list':
            filters = data.get('filter', {})
            found = list(LEADS.values())
            if '=ID' in filters:
                found = [l for l in found if l['ID'] == str(filters['=ID'])]
            if '@ID' in filters:
                found = [l for l in found if l['ID'] in [str(v) for v in filters['@ID']]]
            if '=STATUS_SEMANTIC_ID' in filters:
                found = [l for l in found if l['STATUS_SEMANTIC_ID'] == filters['=STATUS_SEMANTIC_ID']]
            found.sort(key=lambda l:(l['DATE_CREATE'],int(l['ID'])),reverse=True)
            self.reply({'result': [{k:l[k] for k in data['select'] if k in l} for l in found]})
        elif method == 'crm.lead.update':
            item = LEADS[str(data['id'])]
            item.update(data['fields'])
            UPDATES.append({'entity_type':'lead',**data})
            self.reply({'result': True})
        elif method == 'crm.deal.update':
            item = DEALS[str(data['id'])]
            UPDATES.append(data)
            item.update(data['fields'])
            if 'ASSIGNED_BY_ID' in data['fields']:
                item['assignedById'] = data['fields']['ASSIGNED_BY_ID']
            self.reply({'result': True})
        else:
            self.reply({'error': 'METHOD_NOT_FOUND'}, 404)


server = HTTPServer(('0.0.0.0', 8443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain('/certs/cert.pem', '/certs/key.pem')
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
