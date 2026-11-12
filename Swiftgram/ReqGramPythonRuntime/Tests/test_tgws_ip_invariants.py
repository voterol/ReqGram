"""Offline source-wiring checks complement the native byte-fixture harness."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
TRANSPORT = (ROOT / "Swiftgram/ReqGramPythonRuntime/Sources/RGTgwsIPTransport.m").read_text()
SERVICE = (ROOT / "Swiftgram/ReqGramPythonRuntime/Sources/RGTgwsService.m").read_text()


class SecureIPInvariants(unittest.TestCase):
    def test_production_seed_map_matches_repository(self):
        network = (ROOT / "submodules/TelegramCore/Sources/Network/Network.swift").read_text()
        for dc in range(1, 6):
            seeds = re.search(rf"{dc}: \[(\"149\.[^\]]+2001[^\]]+)\]", network).group(1)
            actual = re.search(rf"case {dc}: return @\[(.*?)\];", TRANSPORT).group(1)
            self.assertEqual(re.findall(r'"([^"]+)"', seeds), re.findall(r'@"([^"]+)"', actual))

    def test_same_identity_for_sni_and_host_no_trust_override(self):
        self.assertIn("_host = RGTgwsCanonicalHost(dc, media)", TRANSPORT)
        self.assertIn("NSString *identity = _host", TRANSPORT)
        self.assertIn("sec_protocol_options_set_tls_server_name(security, identity.UTF8String)", TRANSPORT)
        self.assertIn("RGTgwsUpgradeRequest(_host, key)", TRANSPORT)
        self.assertIn('nw_endpoint_create_host(address.UTF8String, "443")', TRANSPORT)
        self.assertIn('sec_protocol_options_add_tls_application_protocol(security, "http/1.1")', TRANSPORT)
        for unsafe in ("set_verify_block", "set_tls_peer_authentication_required", "SecTrustSet", "useCredential", "set_local_identity"):
            self.assertNotIn(unsafe, TRANSPORT + SERVICE)

    def test_no_init_before_upgrade_or_post_open_retry(self):
        self.assertIn("if (opened && sendWS(run, (id<RGTgwsMessageSender>)ws, crypto.relayInit", SERVICE)
        self.assertIn("mayFallback = !opened", SERVICE)
        self.assertIn("if (!connected && mayFallback && !run.isStopping)", SERVICE)
        self.assertIn("if ([ip openWithCategory:&ipCategory])", SERVICE)
        self.assertIn("mayFallback = NO", SERVICE)
        self.assertIn("[ip finish]", SERVICE)

    def test_ip_open_reports_bounded_category_and_send_timeout_is_preserved(self):
        self.assertIn("- (BOOL)openWithCategory:(NSString **)category", TRANSPORT)
        self.assertIn('if (category) *category = @"timeout"', TRANSPORT)
        self.assertIn('if (category) *category = ipFailureCategory(failure)', TRANSPORT)
        self.assertIn('result == RGTgwsWaitTimedOut ? @"timeout" : nil', SERVICE)
        self.assertIn('failureCategory = ipCategory', SERVICE)
        self.assertIn('client_handshake_rejected', SERVICE)
        self.assertIn('invalid_protocol', SERVICE)
        self.assertIn("dispatch_data_create(ownedBytes, bytes.length, _network, DISPATCH_DATA_DESTRUCTOR_FREE)", TRANSPORT)
        self.assertIn("if (completion)", TRANSPORT)
        for unsafe in ("nw_error_get_description", "localizedDescription", "absoluteString"):
            self.assertNotIn(unsafe, TRANSPORT)


if __name__ == "__main__":
    unittest.main()
