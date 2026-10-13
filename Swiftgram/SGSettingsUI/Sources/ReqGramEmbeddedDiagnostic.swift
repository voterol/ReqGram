import Foundation
import UIKit
@preconcurrency import SGSimpleSettings
import ZipArchive
import ReqGramPythonRuntime

/// Local debug diagnostic in the real client process. No account context or auth changes.
/// Fixture permissions intentionally cover both the allowed and denied notice paths.
#if DEBUG
extension ReqGramPluginManager: @unchecked @retroactive Sendable {}
#endif
public func reqGramRunEmbeddedDiagnosticIfRequested() {
    #if DEBUG
    struct Once { static var started = false }
    guard ProcessInfo.processInfo.arguments.contains("--reqgram-plugin-diagnostic"), !Once.started else { return }
    Once.started = true
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ReqGramPluginDiagnostic")
    let manager = ReqGramPluginManager(root: root)
    let inspector = ReqGramPluginZIPInspector()
    let fakeProvider = ReqGramFakeAccountProvider()
    let executor = ReqGramEmbeddedExecutor(accountProvider: fakeProvider, protocolClasses: [ReqGramDiagnosticURLProtocol.self])
    func report(_ message: String) { NSLog("[ReqGramEmbeddedDiagnostic pid=%d] %@", ProcessInfo.processInfo.processIdentifier, message) }
    func rapidLifecycle(_ id: String, remaining: Int, completion: @escaping () -> Void) {
        guard remaining > 0 else {
            report("PASS 20 actual manager/executor enable-disable cycles; stopped Python host rejected; modules/sessions/extraction cleaned")
            completion(); return
        }
        manager.setEnabled(id, enabled: true, inspector: inspector, executor: executor) { error in
            guard error == nil else { report("FAIL rapid enable \(String(describing: error))"); return }
            // Retain the old callable deliberately, even after sys.modules unloads it.
            let capture = "(lambda b, m: (setattr(b, '_reqgram_stale_host', m.host_request), setattr(b, '_reqgram_stale_module', m.__name__), True)[2])(__import__('builtins'), next(m for n,m in __import__('sys').modules.items() if n.startswith('reqgram_plugin_')))"
            RGPythonRuntime.shared().evaluateExpression(capture) { value, error in
                guard value == "True", error == nil else { report("FAIL rapid capture"); return }
                manager.setEnabled(id, enabled: false, inspector: inspector, executor: executor) { error in
                    guard error == nil, ReqGramEmbeddedExecutor.diagnosticSessionCount == 0,
                          (try? manager.plugins().first(where: { $0.id == id })?.enabled) == false,
                          let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path),
                          !entries.contains(where: { $0.hasPrefix("reqgram_plugin_") }) else { report("FAIL rapid native cleanup"); return }
                    let check = """
                    import builtins, sys
                    assert builtins._reqgram_stale_module not in sys.modules
                    try:
                        builtins._reqgram_stale_host('events.poll')
                        raise AssertionError('stopped callback accepted')
                    except RuntimeError:
                        pass
                    del builtins._reqgram_stale_host, builtins._reqgram_stale_module
                    """
                    let literal = String(data: try! JSONEncoder().encode(check), encoding: .utf8)!
                    RGPythonRuntime.shared().evaluateExpression("(__import__('builtins').exec(\(literal)), True)[1]") { value, error in
                        guard value == "True", error == nil else { report("FAIL stopped Python callback cleanup"); return }
                        DispatchQueue.main.async { rapidLifecycle(id, remaining: remaining - 1, completion: completion) }
                    }
                }
            }
        }
    }
    @Sendable func run(_ index: Int) {
        if index == 6 { report("PASS all lifecycle cases"); return }
        let id = index == 1 ? "local.reqgram.notice.fixture.1" : "local.reqgram.fixture.\(index)"
        do {
            try manager.setPolicy(developerMode: true, trustedOnly: false)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let manifest: [String: Any] = ["id": id, "name": "Self-authored diagnostic \(index)", "version": "1", "description": "Benign log, storage and error fixture", "author": "ReqGram integration test", "entry": "main.py", "api_version": "1", "permissions": index == 1 ? ["log", "storage", "ui.alert", "ui.notice", "accounts.read", "chat.context", "message.get", "message.history"] : ["log", "storage"], "settings_schema": ["version": 1, "fields": [["key": "enabled", "label": "Enabled", "type": "boolean", "default_value": true], ["key": "greeting", "label": "Greeting", "type": "string", "default_value": "hello"], ["key": "style", "label": "Style", "type": "selection", "default_value": "quiet", "options": ["quiet", "verbose"]]]]]
            let nextGreeting = (try? manager.settings(id)["greeting"]) == .string("edited-A") ? "edited-B" : "edited-A"
            let hostChecks = index == 3 ? """
                peer = json.loads(host_request('peer.lookup', b'{"peer_id": 4242}'))
                assert peer == {'id': 4242, 'type': 'user', 'title': 'Fixture Peer', 'username': 'fixture_peer'}
                for payload in [b'{}', b'{"peer_id": 0}', b'{"peer_id": 4242, "extra": 1}', b'{"peer_id": "4242"}']:
                    try:
                        host_request('peer.lookup', payload)
                        assert False, 'malformed peer payload accepted'
                    except RuntimeError as error:
                        assert json.loads(str(error))['error'] == 'invalid_payload'
                try:
                    host_request('peer.lookup', b'{"peer_id": 9999}')
                    assert False, 'stale peer accepted'
                except RuntimeError as error:
                    assert json.loads(str(error))['error'] == 'peer_not_found'
                host_request('log', b'PASS peer lookup allowed/denied malformed stale cases')
            """ : index == 1 ? """
                host_request('events.subscribe', b'["ui.action"]')
                request = json.loads(host_request('ui.alert', b'{"title":"ReqGram diagnostic", "message":"Self-authored plugin inside the main client. No account operations."}'))
                assert request['request_id']
                global diagnostic_request
                diagnostic_request = request['request_id']
                host_request('log', b'PASS alert request accepted')
            """ : """
                info = json.loads(host_request('app.info'))
                assert info['platform'] == 'ios' and info['bundle_id'] == 'ph.telegra.Telegraph' and info['version']
                host_request('events.subscribe', b'["app.active", "app.inactive", "ui.action"]')
                assert json.loads(host_request('events.poll')) == []
                host_request('events.unsubscribe', b'["app.active", "app.inactive"]')
                try:
                    host_request('ui.alert', b'{"title":"Denied", "message":"Must not appear"}')
                    assert False, 'permission accepted'
                except RuntimeError as error:
                    assert json.loads(str(error)) == {'operation': 'ui.alert', 'error': 'permission_denied'}
                try:
                    host_request('ui.notice', b'{"title":"Denied", "message":"Must not appear"}')
                    assert False, 'notice permission accepted'
                except RuntimeError as error:
                    assert json.loads(str(error)) == {'operation': 'ui.notice', 'error': 'permission_denied'}
                host_request('log', b'PASS host info/events/permission errors')
            """
            let source = index == 5 ? """
            import time

            client = None

            def wait_for(operation, key, status=None, error=None):
                for _ in range(80):
                    for event in client.poll():
                        if event.get('operation') == operation and event.get('idempotency_key') == key:
                            if status is not None:
                                assert event.get('status') == status, event
                            if error is not None:
                                assert event.get('error') == error, event
                            return event
                    time.sleep(0.025)
                raise AssertionError('terminal mutation event timeout: ' + operation)

            def on_enable():
                global client
                client = Client(host_request)

                # Watch/unwatch is deliberately asserted only at admission. The
                # fake provider emits no message.change event.
                assert client.subscribe('message.change') == {}
                watch = {'peer_id': '4242', 'message_ids': ['4242_0_7']}
                assert client.watch_messages(**watch)['status'] == 'pending'
                time.sleep(0.05)
                assert client.watch_messages(**watch) == {}
                assert client.poll() == []
                assert client.unwatch_messages(**watch) == {}
                assert client.unwatch_messages(**watch) == {}
                assert client.poll() == []

                assert client.subscribe('message.mutation') == {}
                assert client.send_text('send-1', 'send-key', '4242', 'fixture', '4242_0_7')['status'] == 'pending'
                wait_for('message.send', 'send-key', status='queued')
                assert client.send_text('send-1', 'send-key', '4242', 'fixture', '4242_0_7')['status'] == 'pending'
                wait_for('message.send', 'send-key', status='queued')
                try:
                    client.send_text('send-1', 'send-key', '4242', 'changed')
                    assert False, 'send conflict was admitted'
                except RuntimeError as error:
                    assert 'idempotency_conflict' in str(error)

                edit = {'request_id': 'edit-1', 'idempotency_key': 'edit-key',
                        'peer_id': '4242', 'message_id': '4242_0_7', 'text': 'edited'}
                assert client.edit_message(**edit)['status'] == 'pending'
                wait_for('message.edit', 'edit-key', status='unchanged')
                assert client.edit_message(**edit)['status'] == 'pending'
                wait_for('message.edit', 'edit-key', status='unchanged')
                edit_conflict = dict(edit); edit_conflict['text'] = 'different'
                assert client.edit_message(**edit_conflict)['error'] == 'idempotency_conflict'

                delete = {'request_id': 'delete-1', 'idempotency_key': 'delete-key',
                          'peer_id': '4242', 'message_id': '4242_0_7', 'scope': 'local'}
                assert client.delete_message(**delete)['status'] == 'pending'
                wait_for('message.delete', 'delete-key', status='local_deleted')
                assert client.delete_message(**delete)['status'] == 'pending'
                event = wait_for('message.delete', 'delete-key', status='local_deleted')
                assert event['remote_confirmation'] == 'not_requested'
                delete_conflict = dict(delete); delete_conflict['message_id'] = '4242_0_8'
                assert client.delete_message(**delete_conflict)['error'] == 'idempotency_conflict'
                try:
                    client.delete_message('delete-invalid', 'delete-invalid-key', '4242', '4242_0_7', 'everyone')
                    assert False, 'remote delete admitted'
                except RuntimeError as error:
                    assert 'invalid_payload' in str(error)

                forward = {'request_id': 'forward-1', 'idempotency_key': 'forward-key',
                           'source_peer_id': '4242', 'source_message_id': '4242_0_7',
                           'destination_peer_id': '4343'}
                assert client.forward_message(**forward)['status'] == 'pending'
                event = wait_for('message.forward', 'forward-key', status='queued')
                assert event['consistency'] == 'local'
                assert client.forward_message(**forward)['status'] == 'pending'
                wait_for('message.forward', 'forward-key', status='queued')
                forward_conflict = dict(forward); forward_conflict['destination_peer_id'] = '4344'
                assert client.forward_message(**forward_conflict)['error'] == 'idempotency_conflict'
                client.unsubscribe('message.change', 'message.mutation')
                host_request('log', b'PASS real manager/executor/fake provider message fixture; no message.change claimed')

            def on_disable():
                global client
                client = None
                host_request('log', b'DISABLE case=5')
            """ : index == 4 ? """
            def on_enable():
                import json
                host_request('events.subscribe', b'["network.response"]')
                result = json.loads(host_request('network.request', b'{"url":"https://reqgram.test/ok","method":"GET","timeout":1}'))
                assert result['request_id'] > 0
                global diagnostic_network_request
                diagnostic_network_request = str(result['request_id'])
                host_request('log', b'PASS real plugin network admission through executor')
            def on_disable():
                host_request('log', b'DISABLE case=4')
            """ : """
            def on_enable():
                import sys
                import json
            \(hostChecks)
                if \(index == 1 || index == 2 ? "True" : "False"):
                    listing = json.loads(host_request('accounts.list'))
                    row = {'handle': 'account_fixture', 'is_primary': True}
                    if \(index == 2 ? "True" : "False"):
                        row['profile'] = {'first_name': 'Fixture', 'last_name': 'Only', 'username': 'fixture_only'}
                    assert listing == {'accounts': [row], 'consistency': 'session_snapshot'}
                    assert json.loads(host_request('account.context')) == {'current_account': 'account_fixture', 'consistency': 'session_snapshot'}
                    try:
                        host_request('accounts.list', b'{}')
                        assert False
                    except RuntimeError as error:
                        assert json.loads(str(error))['error'] == 'invalid_payload'
                else:
                    for operation in ['accounts.list', 'account.context']:
                        try:
                            host_request(operation)
                            assert False
                        except RuntimeError as error:
                            assert json.loads(str(error))['error'] == 'permission_denied'
                if \(index != 3 ? "True" : "False"):
                    try:
                        host_request('peer.lookup', b'{"peer_id": 4242}')
                        assert False, 'denied peer lookup accepted'
                    except RuntimeError as error:
                        assert json.loads(str(error))['error'] == 'permission_denied'
                host_request('log', b'PASS account capability and exact schema fixture-only')
                settings = json.loads(host_request('settings'))
                assert isinstance(settings['enabled'], bool)
                assert settings['style'] in ['quiet', 'verbose']
                assert settings == {'enabled': \(index == 0 ? "False" : "True"), 'greeting': '\(index == 0 ? nextGreeting : "hello")', 'style': '\(index == 0 ? "verbose" : "quiet")'}, settings
                host_request('log', ('SETTINGS ' + json.dumps(settings, sort_keys=True)).encode())
                assert sys.version_info[:3] == (3, 13, 15), sys.version
                previous = host_request('load')
                count = int(previous or b'0') + 1
                host_request('save', str(count).encode())
                assert host_request('load') == str(count).encode()
                host_request('log', ('ENABLE case=\(index) count=%d module=%s' % (count, __name__)).encode())
                \(index == 2 ? "raise RuntimeError('intentional benign fixture error')" : "pass")
                pass
            def on_disable():
                host_request('log', b'DISABLE case=\(index)')
            """
            let manifestURL = folder.appendingPathComponent("manifest.json")
            let sourceURL = folder.appendingPathComponent("main.py")
            var effectiveManifest = manifest
            if index == 0, var schema = effectiveManifest["settings_schema"] as? [String: Any], var fields = schema["fields"] as? [[String: Any]] {
                effectiveManifest["settings_transfer"] = true
                for i in fields.indices { fields[i]["transferable"] = true }
                schema["fields"] = fields; effectiveManifest["settings_schema"] = schema
            }
            if index == 2 { effectiveManifest["permissions"] = ["log", "storage", "accounts.read", "accounts.profile"] }
            if index == 3 { effectiveManifest["permissions"] = ["log", "storage", "peer.read"] }
            if index == 4 { effectiveManifest["permissions"] = ["log", "storage", "network"] }
            if index == 5 {
                effectiveManifest["capabilities"] = ["message.events", "message.send", "message.edit", "message.delete", "message.forward"]
                effectiveManifest["permissions"] = ["log"]
            }
            try JSONSerialization.data(withJSONObject: effectiveManifest).write(to: manifestURL)
            try Data(source.utf8).write(to: sourceURL)
            let archive = folder.appendingPathComponent("sample.ixplugin")
            guard SSZipArchive.createZipFile(atPath: archive.path, withFilesAtPaths: [manifestURL.path, sourceURL.path]) else { throw ReqGramPluginError.invalidPackage }
            let ticket = try manager.prepare(archive, inspector: inspector)
            do {
                try manager.install(ticket)
                report("FAIL early approval accepted"); return
            } catch ReqGramPluginError.confirmationRequired {
                report("PASS early approval rejected")
            }
            report("REVIEW case=\(index) ten-second gate")
            let installAndRun: @Sendable () -> Void = {
                do {
                    try manager.install(ticket)
                    if index == 0 {
                        let before = try manager.settings(id)
                        report("SETTINGS before edit \(before)")
                        let next = nextGreeting
                        try manager.setSetting(id, key: "greeting", value: .string(next))
                        try manager.setSetting(id, key: "enabled", value: .boolean(false))
                        try manager.setSetting(id, key: "style", value: .string("verbose"))
                        guard try ReqGramPluginManager(root: root).settings(id)["greeting"] == .string(next) else { report("FAIL settings reopen"); return }
                        report("PASS settings edited and reopened greeting=\(next)")
                        let exported = try manager.exportSettings(id)
                        try manager.setSetting(id, key: "greeting", value: .string("temporary local fixture"))
                        try manager.importSettings(id, data: exported)
                        guard try ReqGramPluginManager(root: root).settings(id)["greeting"] == .string(next) else { report("FAIL imported settings reopen"); return }
                        report("PASS settings export/import persisted; Python will read imported values")
                    }
                    manager.setEnabled(id, enabled: true, inspector: inspector, executor: executor) { error in
                        if index == 2 {
                            let expected = index == 2 ? "intentional benign" : "64 KiB"
                            guard error?.localizedDescription.contains(expected) == true, (try? manager.plugins().first(where: { $0.id == id })?.enabled) == false,
                                  (try? manager.logs(for: id).contains(where: { $0.contains(expected) })) == true else { report("FAIL expected error: \(String(describing: error))"); return }
                            report("PASS error propagated; not Running"); run(index + 1)
                        } else if let error = error { report("FAIL enable \(error)") }
                        else {
                            if index == 1 {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    var presenter = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController
                                    while let next = presenter?.presentedViewController { presenter = next }
                                    guard let alert = presenter as? UIAlertController, alert.title == "Plugin: ReqGram diagnostic" else { report("FAIL real host alert not visible"); return }
                                    func evaluate(_ expression: String, _ next: @escaping () -> Void) {
                                        RGPythonRuntime.shared().evaluateExpression(expression) { value, error in
                                            guard value == "True", error == nil else { report("FAIL alert round-trip \(String(describing: value)) \(String(describing: error))"); return }
                                            DispatchQueue.main.async(execute: next)
                                        }
                                    }
                                    let module = "next(m for n,m in __import__('sys').modules.items() if n.startswith('reqgram_plugin_') and hasattr(m, 'diagnostic_request'))"
                                    func select(_ alert: UIAlertController, title: String, value: String, next: @escaping () -> Void) {
                                        guard let action = alert.actions.first(where: { $0.title == title }), let handler = ReqGramAlertTesting.handler(for: action) else { report("FAIL missing supported action seam"); return }
                                        handler(); handler() // An accidental duplicate must not deliver twice.
                                        alert.dismiss(animated: false) {
                                            evaluate("(lambda m: __import__('json').loads(m.host_request('events.poll')) == [{'event':'ui.action','request_id':m.diagnostic_request,'action':'\(value)'}])(\(module))") {
                                                report("PASS presented \(title) handler -> Python ui.action exact request binding, no duplicate")
                                                next()
                                            }
                                        }
                                    }
                                    select(alert, title: "OK", value: "ok") {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) {
                                            evaluate("(lambda m: setattr(m, 'diagnostic_request', __import__('json').loads(m.host_request('ui.notice', b'{\"title\":\"Notice test\",\"message\":\"Local diagnostic\"}'))['request_id']) is None)(\(module))") {
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                                    var top = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController
                                                    while let next = top?.presentedViewController { top = next }
                                                     guard let noticeAlert = top as? UIAlertController, noticeAlert.title == "Plugin: Notice test", noticeAlert.actions.count == 1 else { report("FAIL single-action notice missing"); return }
                                                     report("PASS ui.notice presented exactly one action")
                                                     select(noticeAlert, title: "OK", value: "ok") {
                                                        reqGramAlertLifecycleRegression { passed in
                                                            guard passed else { report("FAIL alert lifecycle cleanup"); return }
                                                            report("PASS rapid 20 host session start/close, pending dismissal, stopped callback ignored, handlers/events/observers cleaned")
                                                            stop()
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            } else if index == 4 {
                                let deadline = ProcessInfo.processInfo.systemUptime + 2.0
                                let module = "next(m for n,m in __import__('sys').modules.items() if n.startswith('reqgram_plugin_') and hasattr(m, 'diagnostic_network_request'))"
                                func pollNetworkResponse() {
                                    let expression = "any(e.get('event') == 'network.response' and str(e.get('request_id')) == \(module).diagnostic_network_request and e.get('status') == '200' for e in __import__('json').loads(\(module).host_request('events.poll')))"
                                    RGPythonRuntime.shared().evaluateExpression(expression) { value, error in
                                        guard error == nil else { report("FAIL real plugin network response \(String(describing: value)) \(String(describing: error))"); return }
                                        if value == "True" {
                                            report("PASS real plugin network response through ReqGram manager/executor/host/session")
                                            stop()
                                        } else if ProcessInfo.processInfo.systemUptime >= deadline {
                                            report("FAIL real plugin network response timed out")
                                        } else {
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: pollNetworkResponse)
                                        }
                                    }
                                }
                                pollNetworkResponse()
                            } else { stop() }
                            func stop() {
                            manager.setEnabled(id, enabled: false, inspector: inspector, executor: executor) { error in
                                if let error = error { report("FAIL disable \(error)") } else {
                                    let reopened = ReqGramPluginManager(root: root)
                                    guard (try? reopened.logs(for: id).contains(where: { $0.contains("DISABLE case=\(index)") })) == true,
                                          (try? reopened.plugins().first(where: { $0.id == id })?.enabled) == false else { report("FAIL persisted logs or stopped state"); return }
                                    report("PASS CPython3.13.15 enable/storage/disable/persisted logs case=\(index)")
                                    if index == 0 { rapidLifecycle(id, remaining: 20) { run(index + 1) } }
                                    else { run(index + 1) }
                                }
                            }
                            }
                        }
                    }
                } catch { report("FAIL install \(error)") }
            }
            if index == 0 {
                manager.setReviewActive(ticket, active: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.2) {
                    do {
                        try manager.install(ticket)
                        report("FAIL inactive review elapsed"); return
                    } catch ReqGramPluginError.confirmationRequired {
                        manager.setReviewActive(ticket, active: true)
                        guard manager.remainingSeconds(ticket) == 10 else { report("FAIL resume review reset"); return }
                        report("PASS inactive review blocked after real 10s; resume resets gate")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10.2, execute: installAndRun)
                    } catch { report("FAIL inactive review \(error)") }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.2, execute: installAndRun)
            }
        } catch { report("FAIL prepare \(error)") }
    }
    report("BEGIN main bundle=\(Bundle.main.bundleIdentifier ?? "unknown") diagnostic_revision=notice-fixture-20260920")
    guard reqGramHostSessionRegression() else { report("FAIL host session regression"); return }
    report("PASS host event isolation/bounds/drain/unsubscribe/close/validation")
    ReqGramNetworkSession.runDiagnostic(report: report) {
        do { try reqGramZIPRegressions() } catch { report("FAIL ZIP regression \(error)"); return }
        reqGramBoundaryRegression { passed in
            guard passed else { report("FAIL boundary cleanup regression"); return }
            report("PASS boundary(NO) failure cleanup, same-name retry and stop cleanup")
            run(0)
        }
    }
    #endif
}
