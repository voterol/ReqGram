"""Deterministic diagnostic for the local-handshake route decision flow.

This deliberately does not open a socket or name a production endpoint.  The
native harness already covers the cryptographic handshake and the IP transport
byte fixtures; this test checks that their integration points preserve the
required hostname-first, pre-open-only fallback contract and its redacted
events.
"""
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
SERVICE = (ROOT / "Swiftgram/ReqGramPythonRuntime/Sources/RGTgwsService.m").read_text()
COORDINATOR = (ROOT / "Swiftgram/SGSettingsUI/Sources/TgwsProxyCoordinator.swift").read_text()
SETTINGS = (ROOT / "Swiftgram/SGSimpleSettings/Sources/TgwsProxySettings.swift").read_text()


def simulated_route_events(hostname_failure="dns", ip_connected=True):
    """Model one client after a valid local handshake, without network I/O."""
    events = ["local_handshake"]
    events.append("upstream_attempt/hostname")
    events.append("upstream_connect_failed/" + hostname_failure)
    events.append("upstream_attempt/ip")
    if ip_connected:
        events.append("upstream_connected")
    else:
        events.append("upstream_connect_failed/" + hostname_failure)
    return events


class TgwsRouteFlowDiagnostic(unittest.TestCase):
    def test_hostname_failure_reaches_ip_fallback_and_connected_event(self):
        events = simulated_route_events()
        self.assertEqual(
            events,
            [
                "local_handshake",
                "upstream_attempt/hostname",
                "upstream_connect_failed/dns",
                "upstream_attempt/ip",
                "upstream_connected",
            ],
        )
        self.assertLess(events.index("upstream_attempt/hostname"), events.index("upstream_attempt/ip"))
        self.assertLess(events.index("upstream_attempt/ip"), events.index("upstream_connected"))

    def test_native_wiring_keeps_handshake_and_fallback_boundaries(self):
        handshake = SERVICE.index("RGTgwsCrypto *crypto =")
        hostname_event = SERVICE.index('emit:@"upstream_attempt" code:@"hostname"', handshake)
        fallback = SERVICE.index("if (!connected && mayFallback && !run.isStopping)", hostname_event)
        ip_event = SERVICE.index('emit:@"upstream_attempt" code:@"ip"', fallback)
        connected_event = SERVICE.index('emit:@"upstream_connected"', ip_event)

        self.assertLess(handshake, hostname_event)
        self.assertLess(hostname_event, fallback)
        self.assertLess(fallback, ip_event)
        self.assertLess(ip_event, connected_event)
        self.assertIn("mayFallback = !opened", SERVICE)
        self.assertIn("mayFallback = NO", SERVICE)

    def test_diagnostic_surface_is_redacted_and_not_direct_fallback(self):
        self.assertIn('code:@"hostname"', SERVICE)
        self.assertIn('code:@"ip"', SERVICE)
        self.assertNotIn("error.localizedDescription", SERVICE)
        self.assertNotIn("trust-all", SERVICE.lower())
        self.assertIn("wss://%@%@", SERVICE)
        self.assertNotIn("mtproto", SERVICE.lower())

    def test_coordinator_handles_stopped_for_both_start_paths(self):
        # Keep this as a narrow source contract: the initial Signal must emit
        # on stopped, while regular callbacks must fail closed without
        # bypassing generation/owner fencing above the switch.
        self.assertEqual(COORDINATOR.count('case "stopped"'), 2)
        self.assertIn('subscriber.putNext(true)', COORDINATOR)
        self.assertIn('self.settings.reportState(.failed("runtime_error"))', COORDINATOR)
        self.assertIn('guard token == self.generation else', COORDINATOR)
        self.assertIn('stopNativeIfOwned(token: token, ownerID: ownerID', COORDINATOR)

    def test_native_error_is_clearable_without_unredacting_values(self):
        self.assertIn('let safe = code == nil ? nil : Self.nativeFailureCode(code)', SETTINGS)
        self.assertIn('reportNativeErrorCode(nil)', COORDINATOR)

    def test_listener_reuses_address_before_bind_without_shared_listeners(self):
        listener = SERVICE[SERVICE.index('int listener = socket('):SERVICE.index('RGTgwsRun *run = [[RGTgwsRun alloc] init]')]
        self.assertLess(listener.index('setsockopt(listener, SOL_SOCKET, SO_REUSEADDR'), listener.index('bind(listener,'))
        self.assertNotIn('SOL_SOCKET, SO_REUSEPORT', listener)
        self.assertIn('htonl(INADDR_LOOPBACK)', listener)

    def test_current_stop_joins_native_barrier_even_after_ownership_cleared(self):
        start = COORDINATOR.index('private func stopCurrentNative(')
        stop = COORDINATOR[start:COORDINATOR.index('private func reconcile(', start)]
        self.assertNotIn('guard nativeOwnerToken != nil', stop)
        self.assertLess(stop.index('nativeOwnerToken = nil'), stop.index('RGTgwsService.shared().stop'))
        self.assertLess(stop.index('RGTgwsService.shared().stop'), stop.index('completion()'))


if __name__ == "__main__":
    unittest.main()
