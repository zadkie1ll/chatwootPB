import uuid
from datetime import timedelta
from unittest.mock import Mock, patch
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient
from delivery.models import CrmMutation
from .client import BitrixClient, CrmError, normalize_phone
from .mutations import publish


class BitrixTestCase(TestCase):
    def setUp(self):
        environment = patch.dict('os.environ', {
            'BITRIX_ENABLED': 'true', 'BITRIX_WEBHOOK_URL': 'https://crm.example.test/rest/1/private/',
            'BITRIX_DIRECTORY_WEBHOOK_URL': 'https://crm.example.test/rest/1/directory/',
            'BITRIX_PORTAL_URL': 'https://crm.example.test', 'CHATWOOT_PUBLIC_URL': 'https://chat.example.test',
            'INTEGRATION_API_TOKEN': 'a' * 64})
        environment.start()
        self.addCleanup(environment.stop)
        self.client = BitrixClient()

class BitrixTests(BitrixTestCase):
    def test_phone_normalization_and_invalid_input(self):
        for text in ['+7 (999) 123-45-67', '89991234567', '9991234567']:
            self.assertEqual(normalize_phone(text), '+79991234567')
        for text in ['', 'abc79991234567', '+0 9991234567', '123']:
            with self.assertRaises(CrmError):
                normalize_phone(text)

    def test_deal_url_is_parsed_without_fetching_arbitrary_hosts(self):
        self.assertEqual(self.client.deal_id('https://crm.example.test/crm/deal/details/42/?IFRAME=Y'), 42)
        for url in ['https://evil.test/crm/deal/details/42/', 'http://crm.example.test/crm/deal/details/42/',
                    'https://crm.example.test@evil.test/crm/deal/details/42/', 'https://crm.example.test/rest/1/private/']:
            with self.assertRaises(CrmError):
                self.client.deal_id(url)

    def test_no_contacts_never_queries_all_deals(self):
        with patch.object(self.client, 'call', return_value={'result': {}}) as call:
            self.assertFalse(self.client.resolve(phone='+79991234567')['found'])
        self.assertEqual([c.args[0] for c in call.call_args_list], ['crm.duplicate.findbycomm'] * 3)

    def test_latest_open_deal_uses_multi_contact_filter_and_creation_time(self):
        def respond(method, params):
            if method == 'crm.duplicate.findbycomm':
                return {'result': {params['entity_type']: [12]}}
            self.assertEqual(method, 'crm.item.list')
            self.assertEqual(params['filter']['=closed'], 'N')
            self.assertEqual(params['order'], {'createdTime': 'DESC', 'id': 'DESC'})
            contact_query = '@contactIds' in params['filter']
            return {'result': {'items': [{'id': 200 if contact_query else 100, 'title': 'Synthetic deal', 'assignedById': 2,
                                         'createdTime': '2026-11-20T12:00:00+03:00' if contact_query else '2026-11-21T12:00:00+03:00'}]}}
        with patch.object(self.client, 'call', side_effect=respond):
            result = self.client.resolve(phone='+79991234567')
        self.assertEqual(result['deal_id'], '100')
        self.assertEqual(result['phone'], '+79991234567')

    def test_employee_endpoint_requires_service_auth(self):
        self.assertEqual(APIClient().get('/crm/employees/').status_code, 401)

    def test_fixed_method_allowlist_and_token_free_errors(self):
        with self.assertRaises(CrmError) as caught:
            self.client.call('user.admin')
        self.assertNotIn('private', str(caught.exception))
        self.assertEqual(caught.exception.code, 'crm_method_forbidden')

    def test_crm_fields_contain_only_authenticated_chat_urls(self):
        fields = self.client.desired_fields({'chat_url': 'https://chat.example.test/app/accounts/1/conversations/12', 'assigned_user_id': '23'})
        self.assertEqual(fields['ASSIGNED_BY_ID'], 23)
        self.assertEqual(fields['UF_CRM_CW_MANAGER_CHAT'], fields['UF_CRM_CW_SUPERVISOR_CHAT'])
        for url in ['https://evil.test/app/accounts/1/conversations/12',
                    'https://chat.example.test/app/accounts/1/conversations/12?token=secret']:
            with self.assertRaises(CrmError):
                self.client.desired_fields({'chat_url': url})


class MutationTests(TestCase):
    def payload(self):
        return {'operation_id': str(uuid.uuid4()), 'deal_id': '12', 'chat_url': 'https://chat.example.test/app/accounts/1/conversations/12'}

    def test_replay_changes_crm_once(self):
        client = Mock()
        client.desired_fields.return_value = {'URL': 'synthetic'}
        client.matches.side_effect = [False, True]
        payload = self.payload()
        self.assertEqual(publish(client, payload)['state'], 'applied')
        self.assertEqual(publish(client, payload)['state'], 'applied')
        client.update.assert_called_once()

    def test_timeout_after_update_reconciles_without_duplicate_update(self):
        client = Mock()
        client.desired_fields.return_value = {'URL': 'synthetic'}
        client.matches.side_effect = [False, True]
        client.update.side_effect = CrmError()
        payload = self.payload()
        self.assertEqual(publish(client, payload)['state'], 'unknown')
        self.assertEqual(publish(client, payload)['state'], 'applied')
        client.update.assert_called_once()

    def test_unconfirmed_result_never_blindly_repeats(self):
        client = Mock()
        client.desired_fields.return_value = {'URL': 'synthetic'}
        client.matches.return_value = False
        client.update.side_effect = CrmError()
        payload = self.payload()
        for _ in range(3):
            self.assertEqual(publish(client, payload)['state'], 'unknown')
        client.update.assert_called_once()

    @patch.dict('os.environ', {'BITRIX_MESSENGER_FIELD': 'MESSENGER'})
    def test_legacy_unknown_operation_reconciles_original_fields(self):
        import hashlib
        import json
        payload = self.payload()
        digest = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        CrmMutation.objects.create(operation_id=payload['operation_id'], payload_hash=digest,
                                   payload=payload, state='unknown')
        client = Mock()
        client.desired_fields.return_value = {'URL': 'synthetic', 'MESSENGER': 'new-url'}
        client.matches.return_value = True
        self.assertEqual(publish(client, payload)['state'], 'applied')
        client.matches.assert_called_once_with('12', {'URL': 'synthetic'})
        client.update.assert_not_called()

    def test_conflicting_payload_cannot_reuse_operation_id(self):
        client = Mock()
        client.desired_fields.return_value = {'URL': 'synthetic'}
        client.matches.return_value = True
        payload = self.payload()
        publish(client, payload)
        with self.assertRaises(CrmError):
            publish(client, {**payload, 'deal_id': '99'})

    def test_definitive_permission_denial_is_failed_not_ambiguous(self):
        client = Mock()
        client.desired_fields.return_value = {'URL': 'synthetic'}
        client.matches.return_value = False
        client.update.side_effect = CrmError('crm_access_denied', definitive=True)
        payload = self.payload()
        self.assertEqual(publish(client, payload)['state'], 'failed')
        self.assertEqual(publish(client, payload)['state'], 'failed')
        client.update.assert_called_once()

    def test_positive_ack_with_later_crm_automation_does_not_repeat_update(self):
        client = Mock()
        client.desired_fields.return_value = {'URL': 'synthetic'}
        client.matches.return_value = False
        payload = self.payload()
        self.assertEqual(publish(client, payload)['state'], 'applied')
        self.assertEqual(publish(client, payload)['state'], 'applied')
        client.update.assert_called_once()

    def test_rate_limit_is_retryable_without_ambiguous_outcome(self):
        client = Mock()
        client.desired_fields.return_value = {'URL': 'synthetic'}
        client.matches.return_value = False
        client.update.side_effect = CrmError('crm_rate_limited', definitive=True, retryable=True)
        self.assertEqual(publish(client, self.payload())['state'], 'pending')

class CrmTransportTests(TestCase):
    @patch.dict('os.environ', {'CHATWOOT_INTERNAL_URL': 'http://chatwoot-web:3000', 'CW_SERVICE_TOKEN': 'synthetic'})
    @patch('delivery.transport.httpx.request')
    def test_responsible_callback_accepts_empty_success_response(self, request):
        from delivery.transport import cw
        response = Mock(status_code=204)
        response.json.side_effect = ValueError('No content')
        request.return_value = response
        self.assertEqual(cw('POST', '/crm/owner', json={'id': 1}), {})
        response.json.assert_not_called()


class CrmReconcileTests(TestCase):
    @patch('crm.reconcile.time.sleep')
    @patch('crm.reconcile.BitrixClient')
    @patch('crm.reconcile.transport.cw')
    def test_unavailable_deal_does_not_starve_later_bindings(self, cw, client, sleep):
        from crm.reconcile import reconcile_batch
        cw.return_value = {'links': [
            {'id': 1, 'deal_id': '501'},
            {'id': 2, 'deal_id': '502', 'owner_external_user_id': '22'}]}
        client.return_value.read_fields.side_effect = [CrmError('crm_deal_unavailable', definitive=True), {'ASSIGNED_BY_ID': 22}]
        self.assertEqual(reconcile_batch(), 0)
        self.assertEqual(client.return_value.read_fields.call_count, 2)
        self.assertEqual(cw.call_count, 1)


class LeadLinkTests(BitrixTestCase):
    def test_no_deal_falls_back_to_latest_open_lead(self):
        def api(method, data):
            if method == 'crm.duplicate.findbycomm':
                return {'result': {'LEAD': [900, 901]} if data['entity_type'] == 'LEAD' else {}}
            self.assertEqual(method, 'crm.item.list')
            self.assertEqual(data['entityTypeId'], 1)
            self.assertEqual(data['filter']['=stageSemanticId'], 'P')
            self.assertEqual(data['order'], {'createdTime': 'DESC', 'id': 'DESC'})
            return {'result': {'items': [{'id': 901, 'title': 'Synthetic lead', 'assignedById': 11}]}}
        with patch.object(self.client, 'call', side_effect=api):
            result = self.client.resolve(phone='+79991234567')
        self.assertEqual(result['entity_type'], 'lead')
        self.assertEqual(result['deal_id'], '901')
        self.assertEqual(result['deal_url'], 'https://crm.example.test/crm/lead/details/901/')

    def test_lead_is_found_through_client_contact_without_own_phone(self):
        def api(method, data):
            if method == 'crm.duplicate.findbycomm':
                return {'result': {'CONTACT': [101, 102]} if data['entity_type'] == 'CONTACT' else {}}
            self.assertEqual(method, 'crm.item.list')
            if data['entityTypeId'] == 2:
                return {'result': {'items': []}}
            self.assertEqual(data['filter']['=stageSemanticId'], 'P')
            alternatives = data['filter']['0']
            self.assertEqual(alternatives, {'logic': 'OR', '0': {'@contactIds': [101, 102]}})
            return {'result': {'items': [{'id': 903, 'title': 'Contact-only lead', 'assignedById': 11, 'contactIds': [102, 101]}]}}
        with patch.object(self.client, 'call', side_effect=api):
            result = self.client.resolve(phone='+79991234567')
        self.assertEqual(result['entity_type'], 'lead')
        self.assertEqual(result['deal_id'], '903')
        self.assertEqual(result['contact_ids'], ['102', '101'])

    def test_contact_lead_and_direct_phone_lead_are_sorted_together(self):
        def api(method, data):
            if method == 'crm.duplicate.findbycomm':
                ids = {'CONTACT': [101], 'LEAD': [901]}.get(data['entity_type'], [])
                return {'result': {data['entity_type']: ids} if ids else {}}
            if data['entityTypeId'] == 2:
                return {'result': {'items': []}}
            alternatives = data['filter']['0']
            self.assertEqual(alternatives['logic'], 'OR')
            self.assertEqual(alternatives['0'], {'@id': [901]})
            self.assertEqual(alternatives['1'], {'@contactIds': [101]})
            self.assertEqual(data['order'], {'createdTime': 'DESC', 'id': 'DESC'})
            return {'result': {'items': [{'id': 904, 'title': 'Latest open lead', 'assignedById': 11}]}}
        with patch.object(self.client, 'call', side_effect=api):
            self.assertEqual(self.client.resolve(phone='+79991234567')['deal_id'], '904')

    def test_explicit_lead_url_and_messenger_link(self):
        with patch.object(self.client, 'read_fields', return_value={'ID': '901', 'TITLE': 'Synthetic lead', 'ASSIGNED_BY_ID': '11'}):
            result = self.client.resolve(deal_url='https://crm.example.test/crm/lead/details/901/')
        self.assertEqual(result['entity_type'], 'lead')
        with patch.dict('os.environ', {'BITRIX_LEAD_MESSENGER_FIELD': 'UF_CRM_CW_MESSENGER'}):
            fields = self.client.desired_fields({'entity_type': 'lead', 'chat_url': 'https://chat.example.test/app/accounts/1/conversations/2'})
        self.assertEqual(fields['UF_CRM_CW_MESSENGER'], 'https://chat.example.test/app/accounts/1/conversations/2?messenger=Telegram')
