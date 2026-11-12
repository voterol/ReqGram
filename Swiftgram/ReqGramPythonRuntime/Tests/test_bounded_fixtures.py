"""Generated package tests using a deterministic fake ReqGram host.

These tests deliberately stop at the Python/host wire boundary. Native-only
eligibility, provider admission, and URLSession scheduling remain native tests.
"""
import importlib.util
import inspect
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CHECKED_ALL_API = ROOT.parents[1] / "all-api.ixplugin"

# Maintained independently of reflection so SDK drift cannot silently redefine coverage.
EXPECTED_CLIENT_METHODS = {
    "app_info", "settings", "accounts", "account_context", "peer", "chat_context",
    "message", "history", "subscribe", "unsubscribe", "watch_messages",
    "search",
    "unwatch_messages", "send_text", "edit_message", "poll", "delete_message",
    "forward_message", "enable_callbacks", "event_status", "alert", "notice",
    "register_message_action", "unregister_message_action", "load", "save", "log",
    "network_request", "cancel_network_request",
    "native_class_call", "native_instance_call", "native_get", "native_set",
    "native_release", "output_volume", "set_output_volume",
    "ios_app_info", "ios_alert", "ios_notice", "ios_output_volume", "ios_set_output_volume",
    "ios_account_context", "ios_peer_lookup", "ios_message_get",
    "mtproto_raw", "mtproto_json",
}


def load(path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeHost:
    def __init__(self, enforce_ui_limits=True, missing_fixture_peer=False, forced_rejections=None):
        self.calls = []
        self.events = []
        self.callback_mode = False
        self.callback = None
        self.subscriptions = set()
        self.network_permissions = {"network", "network.insecure"}
        self.ios_permissions = {"ios.safe"}
        self.read_permissions = {"accounts.read", "peer.read", "message.get"}
        self.pending_requests = set()
        self.next_request_id = 1
        self.storage = None
        self.message_actions = {}
        self.accepted_mutations = []
        self.accepted_network_requests = []
        self.now = 0.0
        self.pending_ui = False
        self.last_ui_at = None
        self.enforce_ui_limits = enforce_ui_limits
        self.missing_fixture_peer = missing_fixture_peer
        self.forced_rejections = forced_rejections or {}
        self.rejections = []
        self.postbox_history_calls = 0

    def __call__(self, operation, payload=None):
        value = json.loads(payload) if payload is not None and operation not in ("save", "log") else None
        self.calls.append((operation, value, payload))
        if operation in self.forced_rejections:
            self.reject(operation, self.forced_rejections[operation])
        if operation == "events.poll":
            if self.callback_mode:
                self.reject(operation, "callback_mode")
            result, self.events = self.events, []
            return json.dumps(result).encode()
        if operation in ("events.subscribe", "events.unsubscribe"):
            if not isinstance(value, list) or len(value) > 3 or any(event not in {
                    "app.active", "app.inactive", "ui.action", "network.response",
                    "message.action", "message.change", "message.mutation"} for event in value):
                raise ValueError("malformed subscriptions")
            if operation == "events.subscribe":
                self.subscriptions.update(value)
            else:
                self.subscriptions.difference_update(value)
            return None
        if operation == "events.callback":
            self.callback_mode = True
            return None
        if operation == "events.status":
            return b'{"mode":"poll","failed":false,"queued":0,"dropped":0,"delivered":0}'
        if operation == "app.info":
            return b'{"platform":"ios","client":"ReqGram","bundle_id":"fixture","version":"1","build":"1","os_version":"fixture","api_version":"1"}'
        if operation == "settings":
            return b'{"enabled":true}'
        if operation == "accounts.list":
            return b'{"accounts":[{"handle":"account_fixture","is_primary":true}],"consistency":"session_snapshot"}'
        if operation == "account.context":
            return b'{"current_account":"account_fixture","consistency":"session_snapshot"}'
        if operation == "peer.lookup":
            if self.missing_fixture_peer:
                self.reject(operation, "peer_not_found")
            return b'{"id":4242,"type":"user","title":"Fixture","username":null}'
        if operation == "chat.context":
            if self.missing_fixture_peer:
                self.reject(operation, "peer_not_found")
            return b'{"peer_id":"4242","title":"Fixture"}'
        if operation == "message.get":
            if self.missing_fixture_peer:
                self.reject(operation, "peer_not_found")
            return b'{"peer_id":"4242","message_id":"4242_0_7","text":"fixture"}'
        if operation == "message.history":
            if value.get("anchor_id") == "4242_0_2147483647":
                self.reject(operation, "message_not_found")
            self.postbox_history_calls += 1
            return b'{"peer_id":"4242","messages":[],"hole":false,"network_fetched":false}'
        if operation == "message.search":
            return b'{"messages":[],"consistency":"local","network_fetched":false}'
        if operation in ("ui.alert", "ui.notice"):
            if self.pending_ui:
                self.reject(operation, "ui_busy")
            if self.enforce_ui_limits and self.last_ui_at is not None and self.now - self.last_ui_at < 5.0:
                self.reject(operation, "rate_limited")
            self.last_ui_at = self.now
            return b'{"request_id":"ui-fixture"}'
        if operation == "messages.register":
            action_id = value.get("id") if isinstance(value, dict) else None
            if action_id in self.message_actions:
                self.reject(operation, "duplicate_action")
            if len(self.message_actions) >= 2:
                self.reject(operation, "action_limit")
            self.message_actions[action_id] = value.get("label")
            return b'{}'
        if operation == "messages.unregister":
            action_id = value.get("id") if isinstance(value, dict) else None
            self.message_actions.pop(action_id, None)
            return b'{}'
        if operation in ("message.events.unwatch",):
            return b'{"status":"pending"}'
        if operation == "load":
            return self.storage
        if operation == "save":
            self.storage = payload
            return None
        if operation == "log":
            return None
        if operation == "network.request":
            if not isinstance(value, dict) or not isinstance(value.get("url"), str) or \
                    not value["url"].startswith(("https://", "http://")):
                self.reject(operation, "invalid_payload")
            if value.get("url", "").startswith("http://") and "network.insecure" not in self.network_permissions:
                raise PermissionError("network.insecure required for HTTP")
            self.accepted_network_requests.append(value)
            request_id = self.next_request_id
            self.next_request_id += 1
            self.pending_requests.add(request_id)
            return json.dumps({"request_id": request_id}).encode()
        if operation == "network.cancel":
            if "network" not in self.network_permissions:
                raise PermissionError("network required for cancellation")
            if not isinstance(value, dict) or value.get("request_id") not in self.pending_requests:
                self.reject(operation, "invalid_payload")
            self.pending_requests.remove(value["request_id"])
            return b'{}'
        if operation == "native.class_call":
            return b'{"handle":"fixture-handle","class":"NSObject"}'
        if operation in ("native.instance_call", "native.get"):
            return b'{"value":"fixture"}'
        if operation in ("native.set", "native.release"):
            return b'{}'
        if operation == "native.audio.output_volume":
            return b'{"value":0.5}'
        if operation == "native.audio.set_output_volume":
            return json.dumps({"value": value["value"]}).encode()
        if operation.startswith("ios.safe."):
            if "ios.safe" not in self.ios_permissions:
                raise PermissionError("ios.safe required")
            if operation == "ios.safe.app_info":
                return b'{"platform":"ios","client":"ReqGram","version":"1"}'
            if operation in ("ios.safe.alert", "ios.safe.notice"):
                if value != {"title": "ReqGram safe check", "message": "Local API check only."}:
                    self.reject(operation, "invalid_payload")
                return b'{"request_id":"ui-fixture"}'
            if operation == "ios.safe.output_volume":
                return b'{"value":0.5}'
            if operation == "ios.safe.set_output_volume":
                return json.dumps({"requested_value": value["value"]}).encode()
            if operation == "ios.safe.account_context":
                if "accounts.read" not in self.read_permissions:
                    raise PermissionError("accounts.read required")
                return b'{"current_account":"account_fixture","consistency":"session_snapshot"}'
            if operation == "ios.safe.peer_lookup":
                if "peer.read" not in self.read_permissions:
                    raise PermissionError("peer.read required")
                return b'{"id":4242,"type":"user","title":"Fixture","username":null}'
            if operation == "ios.safe.message_get":
                if "message.get" not in self.read_permissions:
                    raise PermissionError("message.get required")
                return b'{"peer_id":"4242","message_id":"4242_0_7","text":"fixture"}'
        if operation == "message.events.watch":
            return b'{"status":"pending"}'
        if operation in ("mtproto.raw", "mtproto.json"):
            if not isinstance(value, dict) or value.get("request_id") != "bad request id":
                self.reject(operation, "invalid_payload")
            self.reject(operation, "invalid_payload")
        if operation.startswith("message."):
            if value.get("request_id") in (None, "") or (isinstance(value.get("request_id"), str) and " " in value["request_id"]):
                self.reject(operation, "invalid_payload")
            if operation == "message.delete" and value.get("scope") != "local":
                self.reject(operation, "invalid_payload")
            if operation in {"message.send", "message.edit", "message.delete", "message.forward"}:
                self.accepted_mutations.append((operation, value))
            return b'{"status":"pending"}'
        raise RuntimeError(json.dumps({"operation": operation, "error": "unsupported_operation"}))

    def enqueue_event(self, event):
        """Model the documented 64-entry oldest-drop host queue."""
        self.events.append(event)
        if len(self.events) > 64:
            self.events.pop(0)

    def advance(self, seconds):
        if seconds < 0:
            raise ValueError("clock cannot move backwards")
        self.now += seconds

    def reject(self, operation, error):
        rejection = json.dumps({"operation": operation, "error": error}, sort_keys=True)
        self.rejections.append(rejection)
        raise RuntimeError(rejection)

    def route_callbacks_to(self, namespace):
        self.callback = namespace.get("on_event")

    def deliver_event(self, event):
        if event.get("event") not in self.subscriptions:
            return False
        if self.callback_mode and self.callback is not None:
            self.callback(event)
        else:
            self.enqueue_event(event)
        return True


def package(generator, name):
    directory = tempfile.TemporaryDirectory()
    path = Path(directory.name) / (name + ".ixplugin")
    generator.create(path, name)
    with zipfile.ZipFile(path) as archive:
        assert archive.namelist() == ["manifest.json", "main.py"]
        assert all(info.date_time == (1980, 1, 1, 0, 0, 0) for info in archive.infolist())
        assert all(info.compress_type == zipfile.ZIP_DEFLATED for info in archive.infolist())
        return directory, json.loads(archive.read("manifest.json")), archive.read("main.py")


def execute(source, host):
    namespace = {"host_request": host}
    exec(compile(source, "generated/main.py", "exec"), namespace)
    namespace["on_enable"]()
    host.route_callbacks_to(namespace)
    return namespace


class BoundedFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.generator = load(ROOT / "Examples/create_bounded_fixtures.py")
        cls.fixture_source = (ROOT / "Examples/create_bounded_fixtures.py").read_text()

    def test_message_watch_manifest_wire_and_callback(self):
        directory, manifest, source = package(self.generator, "message-watch")
        self.addCleanup(directory.cleanup)
        self.assertEqual(manifest["permissions"], [])
        self.assertEqual(manifest["capabilities"], ["message.events"])
        self.assertEqual(set(manifest), {"api_version", "author", "capabilities", "description", "entry", "id", "name", "permissions", "version"})
        self.assertEqual(manifest["entry"], "main.py")
        host = FakeHost()
        namespace = execute(source, host)
        self.assertEqual([(op, value) for op, value, _ in host.calls[:3]], [
            ("events.subscribe", ["message.change"]),
            ("message.events.watch", {"peer_id": "4242", "message_ids": ["4242_0_7"]}),
            ("events.callback", None),
        ])
        event = {"event": "message.change", "transition": "edited", "peer_id": "4242",
                 "message_id": "4242_0_7", "namespace": "0", "text": "new",
                 "text_truncated": "false", "has_media": "false"}
        self.assertTrue(host.deliver_event(event))
        self.assertEqual(namespace["observed"], [event])

    def test_all_api_package_manifest_archive_and_safe_enable(self):
        directory, manifest, source = package(self.generator, "all-api")
        self.addCleanup(directory.cleanup)
        self.assertEqual(manifest["entry"], "main.py")
        self.assertEqual(manifest["api_version"], "1")
        self.assertEqual(set(manifest["permissions"]), {
            "accounts.read", "peer.read", "chat.context", "message.get",
            "message.history", "message.search", "messages.context", "ui.alert", "ui.notice", "ios.safe", "storage", "log",
            "network", "full_access"})
        self.assertEqual(set(manifest["capabilities"]), {
            "message.events", "message.send", "message.edit", "message.delete", "message.forward"})
        self.assertEqual(manifest["settings_schema"]["version"], 1)

        host = FakeHost()
        namespace = execute(source, host)
        self.assertTrue(callable(namespace["run_safe_suite"]))
        self.assertEqual([(op, value) for op, value, _ in host.calls[:6]], [
            ("events.subscribe", ["message.action", "message.mutation", "network.response"]),
            ("events.subscribe", ["ui.action"]),
            ("messages.register", {"id": "safe_api_suite", "label": "Run safe API checks"}),
            ("messages.register", {"id": "safe_api_ui", "label": "Run safe UI check"}),
            ("events.poll", None),
            ("events.callback", None),
        ])
        self.assertEqual(set(namespace["report"]["methods"]), EXPECTED_CLIENT_METHODS - {"alert", "notice"})
        self.assertEqual(set(host.message_actions), {"safe_api_suite", "safe_api_ui"})
        self.assertEqual([op for op, _, _ in host.calls].count("messages.register"), 3)
        self.assertEqual(host.accepted_mutations, [])
        self.assertEqual(host.accepted_network_requests, [])
        self.assertNotIn("ui.alert", [op for op, _, _ in host.calls])
        self.assertNotIn("ui.notice", [op for op, _, _ in host.calls])
        text = source.decode()
        self.assertNotIn("threading", text)
        self.assertNotIn("sleep(", text)

    def test_all_api_suite_invokes_every_client_method_with_exact_safe_payloads(self):
        directory, _, source = package(self.generator, "all-api")
        self.addCleanup(directory.cleanup)
        host = FakeHost()
        namespace = execute(source, host)
        report = namespace["run_safe_suite"]()

        documented = {name for name, member in inspect.getmembers(namespace["Client"], inspect.isfunction)
                      if not name.startswith("_")}
        self.assertEqual(documented, EXPECTED_CLIENT_METHODS)
        self.assertEqual(set(report["methods"]), EXPECTED_CLIENT_METHODS - {"alert", "notice"})
        self.assertTrue(all(item["status"] == "PASS" for item in report["methods"].values()))

        self.assertEqual(host.accepted_mutations, [])
        self.assertEqual(host.accepted_network_requests, [])
        # The unknown-anchor probe is rejected at the host/provider boundary;
        # the native/Postbox history seam must never be entered for it.
        self.assertEqual(host.postbox_history_calls, 0)

        calls = [(op, value) for op, value, _ in host.calls]
        expected_probes = {
            "message.send": {"request_id": "bad request id", "idempotency_key": "safe", "peer_id": "4242", "text": "probe"},
            "message.edit": {"request_id": "bad request id", "idempotency_key": "safe", "peer_id": "4242",
                             "message_id": "4242_0_7", "text": "probe"},
            "message.delete": {"request_id": "bad request id", "idempotency_key": "safe", "peer_id": "4242",
                                "message_id": "4242_0_7", "scope": "local"},
            "message.forward": {"request_id": "bad request id", "idempotency_key": "safe", "source_peer_id": "4242",
                                "source_message_id": "4242_0_7", "destination_peer_id": "4242"},
            "network.request": {"url": "not a URL", "method": "GET", "headers": {}, "timeout": 15},
            "network.cancel": {"request_id": 0},
        }
        for operation, payload in expected_probes.items():
            self.assertIn((operation, payload), calls)
        self.assertIn(("message.history", {"peer_id": "4242", "limit": 1,
                                            "anchor_id": "4242_0_2147483647"}), calls)
        self.assertEqual(host.rejections.count('{"error": "message_not_found", "operation": "message.history"}'), 2)
        self.assertIn(("events.subscribe", ["app.active", "ui.action", "message.change"]), calls)
        self.assertIn(("events.unsubscribe", ["app.active"]), calls)
        self.assertNotIn("ui.alert", [op for op, _ in calls])
        self.assertNotIn("ui.notice", [op for op, _ in calls])
        self.assertLess([op for op, _ in calls].index("events.poll"),
                        [op for op, _ in calls].index("events.callback"))
        # on_enable enables callbacks once, and the automatic suite plus this
        # explicit rerun each exercise the idempotent enable_callbacks path.
        self.assertEqual([op for op, _ in calls].count("events.callback"), 3)

    def test_all_api_ios_safe_payloads_returns_and_permission(self):
        directory, _, source = package(self.generator, "all-api")
        self.addCleanup(directory.cleanup)
        host = FakeHost()
        namespace = execute(source, host)
        calls = [(op, value) for op, value, _ in host.calls]
        self.assertIn(("ios.safe.app_info", None), calls)
        self.assertIn(("ios.safe.output_volume", None), calls)
        self.assertIn(("ios.safe.set_output_volume", {"value": 0.5}), calls)
        self.assertEqual(namespace["client"].ios_set_output_volume(0.25), {"requested_value": 0.25})
        host.ios_permissions = set()
        with self.assertRaises(PermissionError):
            namespace["client"].ios_output_volume()

    def test_fake_host_ios_safe_reads_require_underlying_permissions(self):
        from reqgram import Client

        cases = [
            ("ios_account_context", "accounts.read", (), None,
             {"current_account": "account_fixture", "consistency": "session_snapshot"}),
            ("ios_peer_lookup", "peer.read", (4242,), {"peer_id": 4242},
             {"id": 4242, "type": "user", "title": "Fixture", "username": None}),
            ("ios_message_get", "message.get", (4242, "4242_0_7"),
             {"peer_id": "4242", "message_id": "4242_0_7"},
             {"peer_id": "4242", "message_id": "4242_0_7", "text": "fixture"}),
        ]
        # These are fake-host contract checks, not native permission-guard tests.
        for method, permission, args, payload, expected in cases:
            with self.subTest(method=method, missing_permission=permission):
                host = FakeHost()
                host.read_permissions.remove(permission)
                self.assertEqual(host.ios_permissions, {"ios.safe"})
                self.assertEqual(host.read_permissions,
                                 {"accounts.read", "peer.read", "message.get"} - {permission})
                call = getattr(Client(host), method)
                with self.assertRaises(PermissionError) as rejection:
                    call(*args)
                self.assertEqual(str(rejection.exception), permission + " required")
                operation = "ios.safe." + method.removeprefix("ios_")
                self.assertEqual([(op, value) for op, value, _ in host.calls],
                                 [(operation, payload)])

                host.read_permissions.add(permission)
                self.assertEqual(call(*args), expected)

    def test_all_api_suite_accepts_only_expected_missing_fixture_read_rejections(self):
        directory, _, source = package(self.generator, "all-api")
        self.addCleanup(directory.cleanup)
        host = FakeHost(missing_fixture_peer=True)
        namespace = execute(source, host)
        report = namespace["report"]

        for name in ("peer", "chat_context", "message"):
            self.assertEqual(report["methods"][name], {
                "status": "PASS", "detail": "safely_rejected"})

        # Strict matching must still expose a different provider error.
        host = FakeHost(missing_fixture_peer=True,
                        forced_rejections={"message.get": "message_not_found"})
        namespace = execute(source, host)
        self.assertEqual(namespace["report"]["methods"]["message"], {
            "status": "FAIL", "detail": "unexpected_RuntimeError"})

    def test_all_api_report_is_redacted_persisted_and_logged_per_method(self):
        directory, _, source = package(self.generator, "all-api")
        self.addCleanup(directory.cleanup)
        host = FakeHost()
        namespace = execute(source, host)
        persisted = json.loads(host.storage)
        self.assertEqual(persisted, namespace["report"])
        serialized = host.storage.decode()
        for sensitive in ("Fixture", "account_fixture", "4242", "4242_0_7", "private user data",
                          "safe_api_suite", "Local API check only."):
            self.assertNotIn(sensitive, serialized)
        logs = [payload.decode() for operation, _, payload in host.calls if operation == "log"]
        for method in persisted["methods"]:
            self.assertTrue(any(line.startswith("safe-suite " + method + " PASS ") for line in logs))
        self.assertFalse(any("Fixture" in line or "account_fixture" in line or "4242_0_7" in line
                              for line in logs))

    def test_all_api_enable_report_has_all_28_sdk_methods_except_ui_until_ui_action(self):
        directory, _, source = package(self.generator, "all-api")
        self.addCleanup(directory.cleanup)
        host = FakeHost()
        namespace = execute(source, host)

        methods = namespace["report"]["methods"]
        # The SDK exposes 28 methods total; alert and notice are the two
        # tap-gated UI methods, so enable runs the remaining 26 probes.
        self.assertEqual(len(methods), len(EXPECTED_CLIENT_METHODS) - 2)
        self.assertEqual(set(methods), EXPECTED_CLIENT_METHODS - {"alert", "notice"})
        self.assertNotIn("alert", methods)
        self.assertNotIn("notice", methods)
        self.assertEqual(json.loads(host.storage), namespace["report"])
        self.assertEqual(host.accepted_mutations, [])
        self.assertEqual(host.accepted_network_requests, [])
        self.assertNotIn("ui.alert", [op for op, _, _ in host.calls])
        self.assertNotIn("ui.notice", [op for op, _, _ in host.calls])

        host.deliver_event({"event": "message.action", "action_id": "safe_api_ui"})
        self.assertIn("alert", namespace["report"]["methods"])
        self.assertNotIn("notice", namespace["report"]["methods"])

    def test_all_api_callback_is_bounded_tap_gated_and_ignores_other_events(self):
        directory, _, source = package(self.generator, "all-api")
        self.addCleanup(directory.cleanup)
        host = FakeHost()
        namespace = execute(source, host)
        before = len(host.calls)
        host.deliver_event({"event": "message.action", "action_id": "other", "text": "private"})
        self.assertEqual(len(host.calls), before)
        host.deliver_event({"event": "message.action", "action_id": "safe_api_suite",
                            "text": "private user data"})
        self.assertIsNotNone(host.storage)
        self.assertNotIn(b"private user data", host.storage)

    def test_all_api_ui_phases_are_independently_tap_gated(self):
        directory, _, source = package(self.generator, "all-api")
        self.addCleanup(directory.cleanup)
        host = FakeHost()
        namespace = execute(source, host)
        before = len(host.calls)
        host.deliver_event({"event": "message.action", "action_id": "safe_api_ui"})
        first_tap = [op for op, _, _ in host.calls[before:]]
        self.assertIn("ui.alert", first_tap)
        self.assertNotIn("ui.notice", first_tap)
        self.assertEqual([op for op, _, _ in host.calls].count("ui.alert"), 1)
        self.assertEqual([op for op, _, _ in host.calls].count("ui.notice"), 0)
        self.assertEqual(namespace["report"]["methods"]["alert"]["status"], "PASS")
        self.assertEqual(namespace["_next_ui_phase"], "notice")
        before = len(host.calls)
        host.deliver_event({"event": "message.action", "action_id": "safe_api_ui"})
        second_tap = [op for op, _, _ in host.calls[before:]]
        self.assertIn("ui.notice", second_tap)
        self.assertNotIn("ui.alert", second_tap)
        self.assertEqual([op for op, _, _ in host.calls].count("ui.notice"), 1)
        self.assertEqual(host.rejections[-1], '{"error": "rate_limited", "operation": "ui.notice"}')
        self.assertEqual(namespace["report"]["methods"]["notice"], {
            "status": "FAIL", "detail": "unexpected_RuntimeError"})
        self.assertEqual(namespace["_next_ui_phase"], "notice")

        host.advance(5)
        before = len(host.calls)
        host.deliver_event({"event": "message.action", "action_id": "safe_api_ui"})
        third_tap = [op for op, _, _ in host.calls[before:]]
        self.assertIn("ui.notice", third_tap)
        self.assertNotIn("ui.alert", third_tap)
        self.assertEqual([op for op, _, _ in host.calls].count("ui.notice"), 2)
        self.assertEqual(namespace["report"]["methods"]["alert"]["status"], "PASS")
        self.assertEqual(namespace["report"]["methods"]["notice"]["status"], "PASS")
        self.assertEqual(namespace["_next_ui_phase"], "alert")

    def test_all_api_ui_busy_retains_phase_for_next_tap(self):
        directory, _, source = package(self.generator, "all-api")
        self.addCleanup(directory.cleanup)
        host = FakeHost()
        namespace = execute(source, host)
        host.pending_ui = True

        host.deliver_event({"event": "message.action", "action_id": "safe_api_ui"})

        self.assertEqual(host.rejections[-1], '{"error": "ui_busy", "operation": "ui.alert"}')
        self.assertEqual(namespace["report"]["methods"]["alert"], {
            "status": "FAIL", "detail": "unexpected_RuntimeError"})
        self.assertEqual(namespace["_next_ui_phase"], "alert")
        host.pending_ui = False
        host.deliver_event({"event": "message.action", "action_id": "safe_api_ui"})
        self.assertEqual(namespace["report"]["methods"]["alert"]["status"], "PASS")
        self.assertEqual(namespace["_next_ui_phase"], "notice")

    def test_generator_destination_semantics_and_reproducibility(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            self.generator.create(root / "nested" / "packages")
            first = (root / "nested" / "packages" / "message-watch.ixplugin").read_bytes()
            with self.assertRaises(FileExistsError):
                self.generator.create(root / "nested" / "packages", "message-watch")
            other = root / "single.ixplugin"
            self.generator.create(other, "message-watch")
            self.assertEqual(first, other.read_bytes())
            with self.assertRaises(NotADirectoryError):
                self.generator.create(other)

    def test_checked_all_api_artifact_matches_fresh_generator_output(self):
        with tempfile.TemporaryDirectory() as root:
            generated = Path(root) / "all-api.ixplugin"
            self.generator.create(generated, "all-api")
            self.assertTrue(CHECKED_ALL_API.is_file())
            self.assertEqual(generated.read_bytes(), CHECKED_ALL_API.read_bytes())

    def test_callback_fixture_handles_bounded_delivery(self):
        directory, _, source = package(self.generator, "message-watch")
        self.addCleanup(directory.cleanup)
        host = FakeHost()
        namespace = execute(source, host)
        for index in range(70):
            host.enqueue_event({"event": "message.change", "message_id": str(index)})
        queued = list(host.events)
        poll_host = FakeHost()
        poll_client = namespace["Client"](poll_host)
        for event in queued:
            poll_host.enqueue_event(event)
        self.assertEqual(poll_client.poll(), queued)
        poll_client.enable_callbacks()
        with self.assertRaises(RuntimeError):
            poll_client.poll()
        self.assertEqual(host.events, queued)
        for event in queued:
            host.deliver_event(event)
        self.assertEqual(len(namespace["observed"]), 64)
        self.assertEqual(namespace["observed"][0]["message_id"], "6")
        self.assertEqual(namespace["observed"][-1]["message_id"], "69")
        with self.assertRaises(RuntimeError):
            namespace["client"].poll()

    def test_mutations_are_parameterized_and_exactly_wired(self):
        directory, manifest, source = package(self.generator, "message-mutations")
        self.addCleanup(directory.cleanup)
        self.assertEqual(set(manifest["capabilities"]), {"message.send", "message.edit", "message.delete", "message.forward"})
        host = FakeHost()
        namespace = execute(source, host)
        self.assertEqual(namespace["send"](), {"status": "pending"})
        self.assertEqual(namespace["edit"](), {"status": "pending"})
        self.assertEqual(namespace["delete"](), {"status": "pending"})
        self.assertEqual(namespace["forward"](), {"status": "pending"})
        self.assertEqual([op for op, _, _ in host.calls], ["events.subscribe", "message.send", "message.edit", "message.delete", "message.forward"])
        self.assertEqual([value for _, value, _ in host.calls], [
            ["message.mutation"],
            {"request_id": "send-1", "idempotency_key": "send-key", "peer_id": "4242",
             "text": "hello", "reply_to_message_id": "4242_0_7"},
            {"request_id": "edit-1", "idempotency_key": "edit-key", "peer_id": "4242",
             "message_id": "4242_0_7", "text": "edited"},
            {"request_id": "delete-1", "idempotency_key": "delete-key", "peer_id": "4242",
             "message_id": "4242_0_7", "scope": "local"},
            {"request_id": "forward-1", "idempotency_key": "forward-key", "source_peer_id": "4242",
             "source_message_id": "4242_0_7", "destination_peer_id": "4343"},
        ])

    def test_network_fake_protocol_and_prohibited_surface(self):
        directory, manifest, source = package(self.generator, "network")
        self.addCleanup(directory.cleanup)
        self.assertEqual(set(manifest["permissions"]), {"network", "network.insecure"})
        host = FakeHost()
        namespace = execute(source, host)
        self.assertEqual(namespace["request"](), {"request_id": 1})
        self.assertEqual(host.calls[-1][:2], ("network.request", {"url": "http://fixture.invalid/echo", "method": "POST", "headers": {"X-Fixture": "yes"}, "timeout": 3, "body": "aGVsbG8="}))
        self.assertEqual(namespace["cancel"](1), {})
        self.assertEqual(host.calls[-1][:2], ("network.cancel", {"request_id": 1}))
        self.assertNotIn("accounts.read", manifest["permissions"])
        self.assertNotIn("messages.context", manifest["permissions"])
        with self.assertRaises(RuntimeError):
            FakeHost()("arbitrary.telegram.method", b"{}")

    def test_fake_host_rejects_documented_invalid_inputs(self):
        host = FakeHost()
        invalid = [
            ("message.delete", {"request_id": "d", "idempotency_key": "k", "peer_id": "p", "message_id": "p_0_1", "scope": "everyone"}),
            ("message.send", {"request_id": "", "idempotency_key": "k", "peer_id": "p", "text": "x"}),
            ("message.send", {"request_id": "bad id", "idempotency_key": "k", "peer_id": "p", "text": "x"}),
            ("network.cancel", {"request_id": "unknown"}),
            ("events.subscribe", ["not.a.documented.event"]),
            ("events.subscribe", ["message.change", ""]),
        ]
        for operation, payload in invalid:
            expected = RuntimeError if operation.startswith(("message.", "network.")) else ValueError
            with self.subTest(operation=operation, payload=payload), self.assertRaises(expected):
                host(operation, json.dumps(payload).encode())

    def test_fake_host_enforces_native_message_action_duplicate_and_owner_limit(self):
        host = FakeHost()
        register = lambda action_id: host("messages.register", json.dumps({
            "id": action_id, "label": "Fixture"
        }).encode())
        self.assertEqual(json.loads(register("first")), {})
        with self.assertRaisesRegex(RuntimeError, '"error": "duplicate_action"'):
            register("first")
        self.assertEqual(json.loads(register("second")), {})
        with self.assertRaisesRegex(RuntimeError, '"error": "action_limit"'):
            register("third")
        self.assertEqual(set(host.message_actions), {"first", "second"})
        self.assertEqual(json.loads(host("messages.unregister", b'{"id":"first"}')), {})
        self.assertEqual(json.loads(register("third")), {})

    def test_broad_read_ui_storage_fixture_covers_remaining_sdk_wire(self):
        directory, manifest, source = package(self.generator, "broad-read-ui-storage")
        self.addCleanup(directory.cleanup)
        self.assertEqual(manifest["permissions"], [
            "accounts.read", "peer.read", "chat.context", "message.get", "message.history",
            "message.search", "messages.context", "ui.alert", "ui.notice", "storage", "log"])
        host = FakeHost(enforce_ui_limits=False)
        namespace = execute(source, host)
        result = namespace["all_calls"]()
        self.assertEqual(set(result), {"app_info", "settings", "accounts", "account_context", "peer",
                                   "chat_context", "message", "history", "search", "unsubscribe",
                                       "unwatch_messages", "event_status", "alert", "notice",
                                       "register_message_action", "unregister_message_action", "load",
                                       "save", "log"})
        operations = [operation for operation, _, _ in host.calls]
        self.assertEqual(operations, [
            "app.info", "settings", "accounts.list", "account.context", "peer.lookup",
        "chat.context", "message.get", "message.history", "message.search", "events.unsubscribe",
            "message.events.unwatch", "events.status", "ui.alert", "ui.notice",
            "messages.register", "messages.unregister", "load", "save", "log"])
        self.assertEqual(host.calls[9][1], [])
        self.assertEqual(host.calls[9][2], b"[]")
        self.assertEqual(host.calls[10][1], {"peer_id": "4242", "message_ids": ["4242_0_7"]})
        self.assertEqual(host.calls[16][2], None)
        self.assertEqual(host.calls[17][2], b"fixture-storage")
        self.assertEqual(host.calls[18][2], b"fixture-log")
        self.assertEqual(namespace["client"].load(), b"fixture-storage")
        self.assertEqual([value for _, value, _ in host.calls[:16]], [
            None, None, None, None, {"peer_id": 4242}, {"peer_id": "4242"},
            {"peer_id": "4242", "message_id": "4242_0_7"},
             {"peer_id": "4242", "limit": 2, "anchor_id": "4242_0_6"},
             {"peer_id": "4242", "query": "fixture", "limit": 2}, [],
            {"peer_id": "4242", "message_ids": ["4242_0_7"]}, None,
            {"title": "Fixture", "message": "Alert"},
            {"title": "Fixture", "message": "Notice"},
            {"id": "fixture", "label": "Fixture action"}, {"id": "fixture"},
        ])

    def test_fake_host_accepts_empty_duplicate_and_all_documented_events(self):
        host = FakeHost()
        names = ["app.active", "app.active", "app.inactive", "ui.action", "network.response",
                 "message.action", "message.change", "message.mutation"]
        with self.assertRaises(ValueError):
            host("events.subscribe", json.dumps(names).encode())
        for payload in ([], ["message.change", "message.change"], ["app.active"], ["ui.action"]):
            self.assertIsNone(host("events.subscribe", json.dumps(payload).encode()))

    def test_network_ids_increase_and_response_events_are_wire_shaped(self):
        host = FakeHost()
        first = json.loads(host("network.request", b'{"url":"http://fixture.invalid/1"}'))
        second = json.loads(host("network.request", b'{"url":"http://fixture.invalid/2"}'))
        self.assertEqual((first["request_id"], second["request_id"]), (1, 2))
        host.enqueue_event({"event": "network.response", "request_id": "1", "status": "200",
                            "size": "5", "body": "aGVsbG8=", "error": ""})
        expected = list(host.events)
        self.assertEqual(json.loads(host("events.poll")), expected)

    def test_http_permission_asymmetry_is_enforced_by_fixture_host(self):
        host = FakeHost()
        with self.assertRaises(PermissionError):
            host.network_permissions = set()
            host("network.request", json.dumps({"url": "http://fixture.invalid"}).encode())
        host.network_permissions = {"network.insecure"}
        self.assertEqual(json.loads(host("network.request", b'{"url":"http://fixture.invalid"}')), {"request_id": 1})


if __name__ == "__main__":
    unittest.main()
