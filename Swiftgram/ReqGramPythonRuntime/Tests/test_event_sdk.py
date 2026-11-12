"""Local SDK/package checks only; native scheduler coverage lives in DEBUG diagnostics."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def load(path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class EventSDKTests(unittest.TestCase):
    def test_bounded_read_sdk_contract(self):
        calls = []
        def host(operation, payload=None):
            calls.append((operation, json.loads(payload) if payload else None))
            return b'{}'
        client = load(ROOT / 'SDK/reqgram.py').Client(host)
        client.chat_context(123)
        client.message(123, '123_0_7')
        client.history(123, limit=3, anchor_id='123_0_6')
        self.assertEqual(calls, [
            ('chat.context', {'peer_id': '123'}),
            ('message.get', {'peer_id': '123', 'message_id': '123_0_7'}),
            ('message.history', {'peer_id': '123', 'limit': 3, 'anchor_id': '123_0_6'}),
        ])

    def test_explicit_message_event_sdk_contract(self):
        calls = []
        def host(operation, payload=None):
            calls.append((operation, json.loads(payload) if payload else None))
        client = load(ROOT / 'SDK/reqgram.py').Client(host)
        client.watch_messages(123, ['123_0_7'])
        client.unwatch_messages(123, ['123_0_7'])
        self.assertEqual(calls, [
            ('message.events.watch', {'peer_id': '123', 'message_ids': ['123_0_7']}),
            ('message.events.unwatch', {'peer_id': '123', 'message_ids': ['123_0_7']}),
        ])

    def test_text_send_sdk_contract(self):
        calls = []
        def host(operation, payload=None):
            calls.append((operation, json.loads(payload) if payload else None))
            return b'{"status":"pending"}'
        client = load(ROOT / 'SDK/reqgram.py').Client(host)
        self.assertEqual(client.send_text('request-1', 'key_1', 123, 'hello', '123_0_7'), {'status': 'pending'})
        self.assertEqual(calls, [('message.send', {'request_id': 'request-1', 'idempotency_key': 'key_1',
                                                   'peer_id': '123', 'text': 'hello',
                                                   'reply_to_message_id': '123_0_7'})])

    def test_delete_message_sdk_contract(self):
        calls = []
        def host(operation, payload=None):
            calls.append((operation, json.loads(payload) if payload else None))
            return b'{"status":"pending"}'
        client = load(ROOT / 'SDK/reqgram.py').Client(host)
        self.assertEqual(client.delete_message('delete-1', 'delete-key', 123, '123_0_7'), {'status': 'pending'})
        self.assertEqual(calls, [('message.delete', {'request_id': 'delete-1', 'idempotency_key': 'delete-key',
                                                      'peer_id': '123', 'message_id': '123_0_7', 'scope': 'local'})])

    def test_message_info_contract(self):
        calls = []
        def host(operation, payload=None):
            calls.append((operation, json.loads(payload) if payload else None))
        client = load(ROOT / 'SDK/reqgram.py').Client(host)
        client.register_message_action('info', 'Info')
        client.unregister_message_action('info')
        self.assertEqual(calls, [('messages.register', {'id': 'info', 'label': 'Info'}),
                                 ('messages.unregister', {'id': 'info'})])
        calls.clear()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / '05-message-info.ixplugin'
            load(ROOT / 'Examples/create_message_info_plugin.py').create(path)
            with zipfile.ZipFile(path) as archive:
                manifest = json.loads(archive.read('manifest.json'))
                self.assertEqual(manifest['permissions'], ['messages.context', 'ui.notice'])
                namespace = {'host_request': host}
                exec(compile(archive.read('main.py'), 'main.py', 'exec'), namespace)
            namespace['on_enable']()
            self.assertEqual([op for op, _ in calls], ['events.subscribe', 'events.callback', 'messages.register'])
            namespace['on_event']({'event': 'message.action', 'action_id': 'info',
                                   'text': 'PRIVATE', 'text_truncated': 'false', 'message_id': '123'})
            self.assertEqual(calls[-1], ('ui.notice', {'title': 'Message info', 'message': 'Text length: 7; message ID: 123'}))
            namespace['on_event']({'event': 'ui.action'})
            namespace['on_disable']()
            self.assertFalse(any(op.startswith(('log', 'network.', 'accounts.', 'peer.')) for op, _ in calls))

    def test_wire_contract_and_poll_compatibility(self):
        calls = []

        def host(*args):
            calls.append(args)
            return b'[]' if args[0] == 'events.poll' else None

        client = load(ROOT / 'SDK/reqgram.py').Client(host)
        self.assertEqual(client.poll(), [])
        client.enable_callbacks()
        client.event_status()
        self.assertEqual(calls, [('events.poll',), ('events.callback',), ('events.status',)])

    def test_errors_are_not_swallowed(self):
        def host(*args):
            raise RuntimeError('{"operation":"events.poll","error":"callback_mode"}')

        with self.assertRaisesRegex(RuntimeError, 'callback_mode'):
            load(ROOT / 'SDK/reqgram.py').Client(host).poll()

    def test_package_storage_round_trip(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'events.ixplugin'
            generator = load(ROOT / 'Examples/create_events_plugin.py')
            generator.create(path)
            with self.assertRaises(FileExistsError):
                generator.create(path)
            with zipfile.ZipFile(path) as archive:
                self.assertEqual(set(archive.namelist()), {'manifest.json', 'main.py'})
                manifest = json.loads(archive.read('manifest.json'))
                self.assertEqual(manifest['permissions'], ['storage', 'log'])
                source = archive.read('main.py')
            stored = None
            operations = []

            def host(operation, payload=None):
                nonlocal stored
                operations.append(operation)
                if operation == 'load':
                    return stored
                if operation == 'save':
                    stored = payload

            namespace = {'host_request': host}
            exec(compile(source, 'main.py', 'exec'), namespace)
            self.assertEqual(operations, [])
            namespace['on_enable']()
            self.assertEqual(operations, ['load', 'events.subscribe', 'events.callback'])
            for event in ['app.active', 'app.inactive']:
                namespace['on_event']({'event': event})
            self.assertEqual(stored, b'2')
            namespace['on_disable']()
            namespace['on_enable']()
            namespace['on_event']({'event': 'app.active'})
            self.assertEqual(stored, b'3')
            self.assertFalse(any(op.startswith(('network.', 'accounts.', 'peer.')) for op in operations))


if __name__ == '__main__':
    unittest.main()
