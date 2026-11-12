import json
from pathlib import Path
import unittest

from reqgram import Client


class NativeSDKTests(unittest.TestCase):
    def test_tgws_route_keeps_hostname_tls_invariants(self):
        source = (Path(__file__).resolve().parents[1] / 'Sources' / 'RGTgwsService.m').read_text()
        self.assertIn('NSInteger dc = crypto.dc == 203 ? 2 : crypto.dc;', source)
        self.assertIn('kws%ld-1.web.telegram.org', source)
        self.assertIn('kws%ld.web.telegram.org', source)
        self.assertIn('wss://%@/apiws', source)
        self.assertIn('connectionProxyDictionary = @{}', source)
        self.assertNotIn('NSURLSessionAuthChallengeCancelAuthenticationChallenge', source)
        self.assertNotIn('NSURLAuthenticationMethodServerTrust', source)
        self.assertNotIn('inet_pton', source)
        self.assertNotIn('connect(', source)
        self.assertNotIn('Host",', source)

    def test_native_diagnostic_event_and_failure_code_are_bounded_at_boundary(self):
        source = (Path(__file__).resolve().parents[1] / 'Sources' / 'RGTgwsService.m').read_text()
        self.assertIn('@"upstream_attempt"', source)
        self.assertIn('@"hostname"', source)
        self.assertIn('@"ip"', source)
        self.assertIn('sanitizedCode:code forState:safeState', source)
        self.assertIn('@"timeout", @"dns", @"tls", @"refused", @"network", @"protocol", @"unknown"', source)
        self.assertNotIn('e[@"code"] = code;', source)

    def test_safe_ios_wrappers_use_only_symbolic_operations(self):
        calls = []
        def host(operation, payload=None):
            calls.append((operation, None if payload is None else json.loads(payload)))
            return b'{}'
        client = Client(host)
        client.ios_app_info(); client.ios_alert('T', 'M'); client.ios_notice('T', 'M')
        client.ios_output_volume(); client.ios_set_output_volume(0.25)
        client.ios_account_context(); client.ios_peer_lookup(42); client.ios_message_get(42, '42_0_7')
        self.assertEqual(calls, [
            ('ios.safe.app_info', None), ('ios.safe.alert', {'title': 'T', 'message': 'M'}),
            ('ios.safe.notice', {'title': 'T', 'message': 'M'}),
            ('ios.safe.output_volume', None), ('ios.safe.set_output_volume', {'value': 0.25}),
            ('ios.safe.account_context', None), ('ios.safe.peer_lookup', {'peer_id': 42}),
            ('ios.safe.message_get', {'peer_id': '42', 'message_id': '42_0_7'}),
        ])

    def test_native_wrappers_emit_canonical_operations_and_payloads(self):
        calls = []

        def host(operation, payload=None):
            calls.append((operation, None if payload is None else json.loads(payload)))
            return b'{"value":0.5}'

        client = Client(host)
        client.native_class_call('UIDevice', 'currentDevice')
        client.native_instance_call('h1', 'setName:', 'x')
        client.native_get('h1', 'name')
        client.native_set('h1', 'name', 'x')
        client.native_release('h1')
        client.output_volume()
        client.set_output_volume(0.25)
        self.assertEqual(calls, [
            ('native.class_call', {'class': 'UIDevice', 'selector': 'currentDevice', 'arguments': []}),
            ('native.instance_call', {'handle': 'h1', 'selector': 'setName:', 'arguments': ['x']}),
            ('native.get', {'handle': 'h1', 'property': 'name'}),
            ('native.set', {'handle': 'h1', 'property': 'name', 'value': 'x'}),
            ('native.release', {'handle': 'h1'}),
            ('native.audio.output_volume', None),
            ('native.audio.set_output_volume', {'value': 0.25}),
        ])

    def test_mtproto_wrappers(self):
        calls = []
        def host(operation, payload=None):
            calls.append((operation, json.loads(payload)))
            return b'{}'
        client = Client(host)
        client.mtproto_raw('r1', b'\x01\x00\x00\x00')
        client.mtproto_json('r2', {'constructor': '0x1', 'arguments': []})
        self.assertEqual(calls[0][0], 'mtproto.raw')
        self.assertEqual(calls[0][1]['body'], 'AQAAAA==')
        self.assertEqual(calls[1][0], 'mtproto.json')


if __name__ == '__main__':
    unittest.main()
