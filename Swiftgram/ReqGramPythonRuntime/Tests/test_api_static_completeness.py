"""Static guardrails for the bounded ReqGram v1 surface."""
import ast
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SDK = ROOT / "SDK" / "reqgram.py"
API = ROOT / "ReqGramPluginAPI.md"
EXECUTOR = ROOT.parent / "SGSettingsUI" / "Sources" / "ReqGramEmbeddedExecutor.swift"
PROVIDER = ROOT.parent / "SGSettingsUI" / "Sources" / "ReqGramAccountProvider.swift"
PROJECT = ROOT.parents[1]
EXPECTED_METHODS = {
    "app_info", "settings", "accounts", "account_context", "peer", "chat_context", "message", "history",
    "subscribe", "unsubscribe", "watch_messages", "unwatch_messages", "send_text", "edit_message", "poll",
    "delete_message", "forward_message", "enable_callbacks", "event_status", "alert", "notice",
    "register_message_action", "unregister_message_action", "load", "save", "log", "network_request", "search",
    "cancel_network_request",
    "native_class_call", "native_instance_call", "native_get", "native_set", "native_release",
    "output_volume", "set_output_volume",
    "ios_app_info", "ios_alert", "ios_notice", "ios_output_volume", "ios_set_output_volume",
    "ios_account_context", "ios_peer_lookup", "ios_message_get",
    "mtproto_raw", "mtproto_json",
}
EXPECTED_OPERATIONS = {
    "app.info", "settings", "accounts.list", "account.context", "peer.lookup", "chat.context", "message.get",
    "message.history", "message.search", "message.events.watch", "message.events.unwatch", "events.subscribe", "events.unsubscribe",
    "events.poll", "events.callback", "events.status", "message.send", "message.edit", "message.delete",
    "message.forward", "messages.register", "messages.unregister", "ui.alert", "ui.notice", "network.request",
    "network.cancel", "load", "save", "log",
    "native.class_call", "native.instance_call", "native.get", "native.set", "native.release",
    "native.audio.output_volume", "native.audio.set_output_volume",
    "ios.safe.app_info", "ios.safe.alert", "ios.safe.notice", "ios.safe.output_volume", "ios.safe.set_output_volume",
    "ios.safe.account_context", "ios.safe.peer_lookup", "ios.safe.message_get",
    "mtproto.raw", "mtproto.json",
}


class ReqGramStaticCompletenessTests(unittest.TestCase):
    def test_tgws_media_route_fallback_stays_canonical_and_sequential(self):
        source = (ROOT / "Sources" / "RGTgwsService.m").read_text()
        media_hosts = re.search(r"NSArray<NSString \*> \*canonicalHosts = crypto\.media(.*?)NSString \*failureCategory", source, re.S)
        self.assertIsNotNone(media_hosts)
        block = media_hosts.group(1)
        self.assertLess(block.index('kws%ld-1.web.telegram.org'), block.index('kws%ld.web.telegram.org'))
        self.assertNotIn("https://", block)
        self.assertNotRegex(block, r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
        self.assertIn("if (opened && sendWS(run, (id<RGTgwsMessageSender>)ws, crypto.relayInit, &failureCategory))", source)
        self.assertNotIn("if (sendWS(run, ws, crypto.relayInit, &failureCategory))", source)
        self.assertIn("mayFallback = !opened", source)
        self.assertIn("mayFallback = NO", source)
        self.assertIn("openingErrors", source)
        self.assertIn('return @"protocol"', source)
        self.assertIn("while (!run.isStopping)", source)

    def test_tgws_default_cf_domains_match_swift_contract(self):
        source = (ROOT / "Sources" / "RGTgwsService.m").read_text()
        settings = (ROOT.parent / "SGSimpleSettings" / "Sources" / "TgwsProxySettings.swift").read_text()
        domains = [
            "pclead.co.uk", "offshor.co.uk", "cakeisalie.co.uk", "noskomnadzor.co.uk",
            "lovetrue.co.uk", "sorokdva.co.uk", "pyatdesyatdva.co.uk", "kartoshka.co.uk",
            "sorokodin.co.uk", "pyatdesyatodin.co.uk", "notelega.co.uk", "ebally.co.uk",
            "nebally.co.uk", "havegreatday.co.uk", "pomogite.co.uk", "fixtelega.co.uk",
            "sadnews.co.uk", "onedaychamp.co.uk", "stopblocking.co.uk", "nothingthere.co.uk"
        ]
        for domain in domains:
            self.assertIn(f'"{domain}"', source)
            self.assertIn(f'"{domain}"', settings)
        self.assertIn("configuredCFDomains == nil || configuredCFDomains.count == 0", source)

    def test_sdk_has_exact_single_public_method_inventory(self):
        tree = ast.parse(SDK.read_text())
        client = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "Client")
        methods = [node.name for node in client.body if isinstance(node, ast.FunctionDef) and not node.name.startswith("_")]
        self.assertEqual(len(methods), len(set(methods)))
        self.assertEqual(set(methods), EXPECTED_METHODS)

    def test_documented_public_method_count_matches_sdk(self):
        tree = ast.parse(SDK.read_text())
        client = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "Client")
        methods = [node.name for node in client.body if isinstance(node, ast.FunctionDef) and not node.name.startswith("_")]
        self.assertRegex(API.read_text(), rf"The {len(methods)} public `Client` methods are implemented")

    def test_documented_operations_are_routed_natively(self):
        api, executor, provider = API.read_text(), EXECUTOR.read_text(), PROVIDER.read_text()
        for operation in EXPECTED_OPERATIONS:
            self.assertIn(operation, api, operation)
            if operation not in {"load", "save", "log", "settings", "accounts.list", "account.context", "app.info"} and not operation.startswith("native."):
                self.assertIn(operation, executor, operation)
        self.assertIn('operation.hasPrefix("native.")', executor)
        for operation in ("chat.context", "message.get", "message.history", "message.search"):
            self.assertIn(operation, provider, operation)
        self.assertIn("watchMessages", provider)

    def test_docs_use_actual_history_and_event_fields(self):
        docs = "\n".join(path.read_text() for path in (PROJECT / "docs/reqgram-full-access-api.md", PROJECT / "docs/reqgram-message-events.md"))
        self.assertIn("hole_before", docs)
        self.assertIn("hole_after", docs)
        self.assertIn("network_fetched", docs)
        self.assertRegex(docs, re.compile(r"transition=created\|edited\|deleted"))
        self.assertNotIn("hole/network_fetched", SDK.read_text())


if __name__ == "__main__":
    unittest.main()
