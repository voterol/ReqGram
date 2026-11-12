import importlib.util
import json
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ExteraGramFacadeTests(unittest.TestCase):
    def setUp(self):
        self.calls = []

        def host(operation, payload=None):
            self.calls.append((operation, json.loads(payload) if payload else None))
            return b'{}'

        # Model the documented plugin boundary: the host injects the packaged SDK path.
        sys.path.insert(0, str(ROOT / "SDK"))
        self.addCleanup(sys.path.pop, 0)
        self.facade = load("exteragram", ROOT / "SDK/exteragram.py")
        self.plugin = self.facade.BasePlugin(host)

    def test_lifecycle_aliases(self):
        events = []
        self.plugin.on_plugin_load = lambda: events.append("load")
        self.plugin.on_plugin_unload = lambda: events.append("unload")
        self.plugin.on_enable()
        self.plugin.on_disable()
        self.assertEqual(events, ["load", "unload"])

    def test_event_constants_and_bounded_wrappers(self):
        self.assertEqual(self.facade.AppEvent.MESSAGE_ACTION, "message.action")
        self.plugin.add_message_action("info", "Info")
        self.plugin.remove_message_action("info")
        self.plugin.show_alert("Title", "Message")
        self.plugin.show_notice("Title", "Message")
        self.plugin.send_message("r1", "k1", 42, "hello")
        self.assertEqual([call[0] for call in self.calls], [
            "messages.register", "messages.unregister", "ui.alert", "ui.notice",
            "message.send",
        ])

    def test_android_only_surfaces_fail_explicitly(self):
        with self.assertRaisesRegex(NotImplementedError, "Android-only"):
            self.facade.MethodHook()
        with self.assertRaisesRegex(NotImplementedError, "Android-only"):
            self.facade.java("org.example.Type")
        with self.assertRaisesRegex(NotImplementedError, "Android-only"):
            self.facade.dynamic_proxy(object())

    def test_safe_ios_helpers_are_available(self):
        def host(operation, payload=None):
            self.calls.append((operation, json.loads(payload) if payload else None))
            return {
                "ios.safe.app_info": b'{"platform":"ios"}',
                "ios.safe.output_volume": b'{"value":0.5}',
                "ios.safe.set_output_volume": b'{"requested_value":0.5}',
            }.get(operation, b'{}')
        self.plugin = self.facade.BasePlugin(host)
        self.assertEqual(self.plugin.app_info(), {"platform": "ios"})
        self.assertEqual(self.plugin.output_volume(), {"value": 0.5})
        self.assertEqual(self.plugin.set_output_volume(0.5), {"requested_value": 0.5})
        self.assertEqual([call[0] for call in self.calls], [
            "ios.safe.app_info", "ios.safe.output_volume", "ios.safe.set_output_volume"])

    def test_unsupported_facade_surface_is_explicit(self):
        with self.assertRaisesRegex(NotImplementedError, "Android-only"):
            self.facade.java("android.os.Build")


if __name__ == "__main__":
    unittest.main()
