import Foundation

struct Inspector: ReqGramPluginArchiveInspector {
    var names = ["manifest.json", "main.py"]
    var json = """
    {"id":"demo","name":"Demo","version":"1","description":"Test","author":"Test","entry":"main.py","api_version":"1","permissions":["peer.read","storage","log"]}
    """
    func entryNames(in archive: URL) throws -> [String] { names }
    func readEntry(named: String, from archive: URL) throws -> Data { Data(json.utf8) }
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
func rejects(_ expected: ReqGramPluginError? = nil, _ body: () throws -> Void) throws {
    do { try body() } catch {
        if let expected = expected { check(String(describing: error) == String(describing: expected), "expected \(expected), got \(error)") }
        return
    }
    fatalError("Expected failure")
}
let fm = FileManager.default
let fixture = fm.temporaryDirectory.appendingPathComponent("reqgram-test-" + UUID().uuidString)
try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: fixture) }
let root = fixture.appendingPathComponent("store")
let source = fixture.appendingPathComponent("demo.ixplugin")
try Data("original snapshot".utf8).write(to: source)
var uptime: TimeInterval = 100
var now = Date(timeIntervalSince1970: 1_000_000)
var fail = false
let manager = ReqGramPluginManager(root: root, clock: { uptime }, date: { now }, checkpoint: { if fail { throw NSError(domain: "injected", code: 1) } })
try rejects(.developerModeRequired) { _ = try manager.prepare(source, inspector: Inspector()) }
try manager.setPolicy(developerMode: true)
try rejects(.trustedOnly) { _ = try manager.prepare(source, inspector: Inspector()) }
try manager.setPolicy(trustedOnly: false)
let ticket = try manager.prepare(source, inspector: Inspector())
try rejects(.confirmationRequired) { try manager.install(ticket) }
uptime += 9.9
try rejects(.confirmationRequired) { try manager.install(ticket) }
uptime += 0.1
manager.setReviewActive(ticket, active: false)
uptime += 1000
try rejects(.confirmationRequired) { try manager.install(ticket) }
check(manager.remainingSeconds(ticket) == 10, "Background never completes review")
manager.setReviewActive(ticket, active: true)
uptime += 9.9
try rejects(.confirmationRequired) { try manager.install(ticket) }
uptime += 0.1
try Data("changed source".utf8).write(to: source)
// Losing foreground after the button becomes eligible must revoke eligibility.
manager.setReviewActive(ticket, active: false)
try rejects(.confirmationRequired) { try manager.install(ticket) }
manager.setReviewActive(ticket, active: true)
try rejects(.confirmationRequired) { try manager.install(ticket) }
uptime += 10
try manager.install(ticket)
let records = try manager.plugins()
check(records.count == 1 && !records[0].enabled && !records[0].trusted, "No fake trust/runtime")
let stateURL = root.appendingPathComponent("state.json")
let original = try Data(contentsOf: stateURL)
let object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
let installs = object["installations"] as! [String: Any]
let installed = installs["demo"] as! [String: Any]
check(Data(base64Encoded: installed["archive"] as! String) == Data("original snapshot".utf8), "Exact reviewed snapshot")
try rejects(.expiredImport) { try manager.install(ticket) }
fail = true
try rejects { try manager.remove("demo", deleteData: true) }
let unchanged = try Data(contentsOf: stateURL)
check(unchanged == original, "Failed transaction preserves all state")
fail = false
try manager.setPolicy(developerMode: true, trustedOnly: false)
let second = try manager.prepare(source, inspector: Inspector())
uptime += 10
ReqGramMessageActions.shared.setAccount("account_policy_fixture")
let beforeSafeMode = ReqGramMessageActions.shared.currentScope()
fail = true
try rejects { try manager.setPolicy(safeMode: true) }
fail = false
check(ReqGramMessageActions.shared.isCurrent(beforeSafeMode), "Failed policy persistence does not revoke authorization")
try manager.setPolicy(trustedOnly: true, safeMode: true)
check(!ReqGramMessageActions.shared.isCurrent(beforeSafeMode), "Safe mode revokes message authorization generation")
check(ReqGramMessageActions.shared.currentScope()?.account == "account_policy_fixture", "Revocation preserves account")
ReqGramMessageActions.shared.setAccount(nil)
try manager.setPolicy(developerMode: true, trustedOnly: false)
try manager.install(second)
let policy = try manager.policy()
check(policy.developerMode && policy.safeMode && !policy.trustedOnly && policy.retentionDays == 7, "Distinct policies, seven day default")
now = now.addingTimeInterval(8 * 86400)
let logs = try manager.logs(for: "demo")
check(logs.isEmpty, "Log expiry")
try manager.setPolicy(retentionDays: 30)
let reopened = ReqGramPluginManager(root: root)
let reopenedPolicy = try reopened.policy()
check(reopenedPolicy.retentionDays == 30, "Persisted retention")
try rejects(.invalidPackage) { _ = try manager.prepare(source, inspector: Inspector(names: ["manifest.json", "main.py", "../escape"])) }
try rejects(.invalidPackage) { _ = try manager.prepare(source, inspector: Inspector(names: ["manifest.json", "main.py", "main.py"])) }
// Seed opaque runtime data without introducing a pretend runtime API.
var seeded = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
seeded["data"] = ["demo": Data("persistent data".utf8).base64EncodedString()]
try JSONSerialization.data(withJSONObject: seeded).write(to: stateURL, options: .atomic)
try manager.remove("demo", deleteData: false)
let empty = try manager.plugins()
check(empty.isEmpty, "Removal")
let retained = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
check((retained["data"] as! [String: String])["demo"] != nil, "Keep data")
try manager.remove("demo", deleteData: true)
let deleted = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
check((deleted["data"] as! [String: String]).isEmpty, "Delete retained data")
let target = fixture.appendingPathComponent("outside")
try fm.createDirectory(at: target, withIntermediateDirectories: true)
let link = fixture.appendingPathComponent("link")
try fm.createSymbolicLink(at: link, withDestinationURL: target)
let linkedManager = ReqGramPluginManager(root: link)
try rejects(.unsafePath) { try linkedManager.setPolicy(trustedOnly: false) }
let outsideContents = try fm.contentsOfDirectory(atPath: target.path)
check(outsideContents.isEmpty, "Existing root link must not be canonicalized away")
try Data("corrupt".utf8).write(to: stateURL)
try rejects(.corruptStorage) { try manager.setPolicy(safeMode: false) }
let settingsRoot = fixture.appendingPathComponent("settings")
let settingsManager = ReqGramPluginManager(root: settingsRoot, clock: { uptime }, checkpoint: { if fail { throw NSError(domain: "injected", code: 1) } })
var settingsJSON = try JSONSerialization.jsonObject(with: Data(Inspector().json.utf8)) as! [String: Any]
let fields: [[String: Any]] = [
    ["key": "flag", "label": "Flag", "type": "boolean", "default_value": true, "transferable": true],
    ["key": "text", "label": "Text", "type": "string", "default_value": "hello"],
    ["key": "choice", "label": "Choice", "type": "selection", "default_value": "a", "options": ["a", "b"], "transferable": true]
]
settingsJSON["settings_schema"] = ["version": 1, "fields": fields]
settingsJSON["settings_transfer"] = true
let settingsBytes = try JSONSerialization.data(withJSONObject: settingsJSON)
let settingsInspector = Inspector(json: String(decoding: settingsBytes, as: UTF8.self))
try settingsManager.setPolicy(developerMode: true, trustedOnly: false)
let settingsTicket = try settingsManager.prepare(source, inspector: settingsInspector)
uptime += 10
try settingsManager.install(settingsTicket)
var consentError: Error?
let consentProbe = HeldExecutor()
settingsManager.setEnabled("demo", enabled: true, inspector: settingsInspector, executor: consentProbe) { consentError = $0 }
waitUntil { consentError != nil }
check(String(describing: consentError!).contains("consentRequired"), "Manager rejects enable without consent")
let hasImplicitConsent = try settingsManager.hasValidConsent("demo")
check(!hasImplicitConsent, "Install does not grant implicit consent")
try settingsManager.setPolicy(developerMode: false)
try rejects(.developerModeRequired) { _ = try settingsManager.logs(for: "demo") }
try rejects(.developerModeRequired) { try settingsManager.grantConsent("demo") }
try rejects(.developerModeRequired) { _ = try settingsManager.hasValidConsent("demo") }
let disabledPolicy = try settingsManager.policy()
check(disabledPolicy.trustedOnly, "Disabling Developer Mode restores Trusted Only")
try settingsManager.setPolicy(developerMode: true, trustedOnly: false)
try settingsManager.grantConsent("demo")
let hasPersistedConsent = try settingsManager.hasValidConsent("demo")
check(hasPersistedConsent, "Consent is persisted for exact install")
settingsJSON["permissions"] = ["full_access"]
let fullAccessBytes = try JSONSerialization.data(withJSONObject: settingsJSON)
let fullAccessManifest = String(decoding: fullAccessBytes, as: UTF8.self)
let fullAccessInspector = Inspector(json: fullAccessManifest)
let fullAccessManager = ReqGramPluginManager(root: fixture.appendingPathComponent("full-access"), clock: { uptime })
try fullAccessManager.setPolicy(developerMode: true, trustedOnly: false)
let fullAccessTicket = try fullAccessManager.prepare(source, inspector: fullAccessInspector)
uptime += 10
try fullAccessManager.install(fullAccessTicket)
try fullAccessManager.grantConsent("demo")
let fullAccessExecutor = HeldExecutor()
var fullAccessError: Error?
fullAccessManager.setEnabled("demo", enabled: true, inspector: fullAccessInspector, executor: fullAccessExecutor) { fullAccessError = $0 }
waitUntil { fullAccessExecutor.count == 1 }
check(fullAccessError == nil, "full_access consent permits enable")
let fullAccessAuthorization = fullAccessExecutor.host!
// Keep this matrix independent of authorizationRules.  It is the contract the
// host exposes, rather than a test which merely repeats the implementation.
let authorizationOperations = [
    "authorize.host", "authorize.ui", "authorize.notice", "authorize.accounts",
    "authorize.profile", "authorize.peer", "authorize.network",
    "authorize.network.insecure", "authorize.messages", "authorize.chat.context",
    "authorize.message.get", "authorize.message.history", "authorize.message.search",
    "authorize.message.events", "authorize.message.send", "authorize.message.media.send",
    "authorize.message.edit", "authorize.message.delete", "authorize.message.forward",
    "authorize.mtproto", "authorize.native", "authorize.ios.safe"
]
let allowed = "<allowed>"
func checkAuthorization(_ host: (String, Data?) -> [String: Any], _ expected: [String: String], _ context: String) {
    for operation in authorizationOperations {
        let actual = host(operation, nil)["error"] as? String ?? allowed
        check(actual == expected[operation], "\(context): \(operation), expected \(expected[operation] ?? "missing"), got \(actual)")
    }
}
let fullAccessExpected = Dictionary(uniqueKeysWithValues: authorizationOperations.map {
    ($0, $0 == "authorize.message.media.send" ? "unsupported_operation" : ($0 == "authorize.ios.safe" ? "permission_denied" : allowed))
})
let zeroAuthorityExpected = Dictionary(uniqueKeysWithValues: authorizationOperations.map {
    ($0, $0 == "authorize.host" ? allowed : ($0 == "authorize.message.media.send" ? "unsupported_operation" : "permission_denied"))
})
check(Set(ReqGramPluginManager.authorizationRules.keys) == Set(authorizationOperations), "exact authorization operation names")
checkAuthorization(fullAccessAuthorization, fullAccessExpected, "full_access authorization row")
check(fullAccessAuthorization("authorize.messages", nil)["plugin_id"] as? String == "demo",
      "authorize.messages returns plugin_id")
check(fullAccessAuthorization("authorize.unknown", nil)["error"] as? String == "unsupported_operation", "unknown authorization is denied")
check(fullAccessAuthorization("authorize.message.media.send", Data("media".utf8))["error"] as? String == "unsupported_operation",
      "unsupported media remains denied with full_access")
fullAccessExecutor.finish(0)
let defaults = try settingsManager.settings("demo")
check(defaults == ["flag": .boolean(true), "text": .string("hello"), "choice": .string("a")], "Typed defaults")
try settingsManager.setSetting("demo", key: "flag", value: .boolean(false))
try settingsManager.setSetting("demo", key: "text", value: .string("edited"))
try settingsManager.setSetting("demo", key: "choice", value: .string("b"))
let saved = try ReqGramPluginManager(root: settingsRoot).settings("demo")
check(saved["flag"] == .boolean(false) && saved["text"] == .string("edited") && saved["choice"] == .string("b"), "Settings persist")
try rejects { try settingsManager.setSetting("demo", key: "unknown", value: .string("x")) }
try rejects { try settingsManager.setSetting("demo", key: "flag", value: .string("true")) }
try rejects { try settingsManager.setSetting("demo", key: "choice", value: .string("c")) }
try rejects { try settingsManager.setSetting("demo", key: "text", value: .string(String(repeating: "x", count: 1025))) }
fail = true
try rejects { try settingsManager.setSetting("demo", key: "text", value: .string("lost")) }
fail = false
let afterFailure = try settingsManager.settings("demo")
check(afterFailure == saved, "Settings atomic failure")
let exported = try settingsManager.exportSettings("demo")
let envelope = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
check((envelope["values"] as! [String: Any])["text"] == nil, "Private field excluded")
let beforeImport = try Data(contentsOf: settingsRoot.appendingPathComponent("state.json"))
var badImports = [Data("not JSON".utf8)]
for key in ["plugin_id", "schema_version", "fields", "values", "unexpected"] {
    var bad = envelope
    switch key {
    case "plugin_id": bad[key] = "another.plugin"
    case "schema_version": bad[key] = 2
    case "fields": bad[key] = []
    case "values": bad[key] = ["flag": false, "choice": "b", "unknown": "x"]
    default: bad[key] = true
    }
    badImports.append(try JSONSerialization.data(withJSONObject: bad))
}
for values: [String: Any] in [["flag": "true", "choice": "a"], ["flag": 1, "choice": "a"], ["flag": true, "choice": "invalid"], ["flag": true], ["flag": true, "choice": "a", "text": "private overwrite"]] {
    var bad = envelope; bad["values"] = values
    badImports.append(try JSONSerialization.data(withJSONObject: bad))
}
for bytes in badImports {
    try rejects(.invalidSettingsTransfer) { try settingsManager.importSettings("demo", data: bytes) }
    let unchanged = try Data(contentsOf: settingsRoot.appendingPathComponent("state.json"))
    check(unchanged == beforeImport, "Invalid import preserves exact state")
}
var replacement = envelope; replacement["values"] = ["flag": true, "choice": "a"]
let replacementBytes = try JSONSerialization.data(withJSONObject: replacement)
fail = true
try rejects { try settingsManager.importSettings("demo", data: replacementBytes) }
fail = false
let failedImport = try Data(contentsOf: settingsRoot.appendingPathComponent("state.json"))
check(failedImport == beforeImport, "Import transaction failure preserves exact state")
try settingsManager.importSettings("demo", data: replacementBytes)
let imported = try ReqGramPluginManager(root: settingsRoot).settings("demo")
check(imported == ["flag": .boolean(true), "choice": .string("a"), "text": .string("edited")], "Import persists portable fields and preserves private fields")
try settingsManager.importSettings("demo", data: exported)
print("PASS: settings transfer roundtrip, ID/schema/keys/types/selection validation, private exclusion, atomic failure")
for invalidFields in [fields + [fields[0]], [["key": "bad", "label": "Bad", "type": "number", "default_value": 2]], [["key": "bad", "label": "Bad", "type": "boolean", "default_value": "true"]]] {
    settingsJSON["settings_schema"] = ["version": 1, "fields": invalidFields]
    try rejects { _ = try ReqGramPluginPackage.validate(manifestData: JSONSerialization.data(withJSONObject: settingsJSON), filename: "demo.ixplugin") }
}
settingsJSON["settings_schema"] = nil
settingsJSON["permissions"] = ["log", "unknown.permission"]
try rejects(.invalidPackage) { _ = try ReqGramPluginPackage.validate(manifestData: JSONSerialization.data(withJSONObject: settingsJSON), filename: "demo.ixplugin") }
settingsJSON["permissions"] = ["log"]
try settingsManager.remove("demo", deleteData: false)
let reinstall = try settingsManager.prepare(source, inspector: settingsInspector)
uptime += 10
try settingsManager.install(reinstall)
let retainedSettings = try settingsManager.settings("demo")
check(retainedSettings == saved, "Keep settings")
try settingsManager.remove("demo", deleteData: true)
let fresh = try settingsManager.prepare(source, inspector: settingsInspector)
uptime += 10
try settingsManager.install(fresh)
try settingsManager.grantConsent("demo")
let freshSettings = try settingsManager.settings("demo")
check(freshSettings == defaults, "Delete settings")
// Hold executor completion to deterministically overlap requests at manager boundaries.
final class HeldExecutor: ReqGramPluginExecutor {
    private let lock = NSLock()
    private var callbacks: [(Error?) -> Void] = []
    private var boundaries: [(Bool) -> Bool] = []
    private(set) var host: ((String, Data?) -> [String: Any])?
    var count: Int { lock.lock(); defer { lock.unlock() }; return callbacks.count }
    func execute(module: String, directory: URL, start: Bool, host: @escaping (String, Data?) -> [String: Any], boundary: @escaping (Bool) -> Bool, completion: @escaping (Error?) -> Void) {
        lock.lock(); self.host = host; callbacks.append(completion); boundaries.append(boundary); lock.unlock()
    }
    func finish(_ index: Int) { lock.lock(); let callback = callbacks[index]; lock.unlock(); callback(nil) }
    func boundary(_ index: Int, _ entering: Bool) -> Bool {
        lock.lock(); let callback = boundaries[index]; lock.unlock(); return callback(entering)
    }
}
func waitUntil(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    check(condition(), "Timed out waiting for lifecycle callback")
}
func authorizationHost(permissions: [String], capabilities: [String] = [], name: String) throws -> (String, Data?) -> [String: Any] {
    var manifest = try JSONSerialization.jsonObject(with: Data(Inspector().json.utf8)) as! [String: Any]
    manifest["permissions"] = permissions
    manifest["capabilities"] = capabilities
    let bytes = try JSONSerialization.data(withJSONObject: manifest)
    let inspector = Inspector(json: String(decoding: bytes, as: UTF8.self))
    let manager = ReqGramPluginManager(root: fixture.appendingPathComponent("authorization-\(name)"), clock: { uptime })
    try manager.setPolicy(developerMode: true, trustedOnly: false)
    let ticket = try manager.prepare(source, inspector: inspector)
    uptime += 10
    try manager.install(ticket)
    try manager.grantConsent("demo")
    let executor = HeldExecutor()
    var error: Error?
    manager.setEnabled("demo", enabled: true, inspector: inspector, executor: executor) { error = $0 }
    waitUntil { executor.count == 1 || error != nil }
    check(error == nil, "authorization fixture starts: \(name)")
    return executor.host!
}
let zeroAuthority = try authorizationHost(permissions: [], name: "zero")
checkAuthorization(zeroAuthority, zeroAuthorityExpected, "zero-authority authorization row")

let permissionMappings = [
    "ui.alert": "authorize.ui", "ui.notice": "authorize.notice", "ios.safe": "authorize.ios.safe",
    "accounts.read": "authorize.accounts", "accounts.profile": "authorize.profile",
    "peer.read": "authorize.peer", "network": "authorize.network",
    "network.insecure": "authorize.network.insecure", "messages.context": "authorize.messages",
    "chat.context": "authorize.chat.context", "message.get": "authorize.message.get",
    "message.history": "authorize.message.history", "message.search": "authorize.message.search"
]
for (permission, grantedOperation) in permissionMappings.sorted(by: { $0.key < $1.key }) {
    let host = try authorizationHost(permissions: [permission], name: "permission-\(permission)")
    var expected = zeroAuthorityExpected
    expected[grantedOperation] = allowed
    checkAuthorization(host, expected, "individual permission \(permission)")
    if grantedOperation == "authorize.messages" {
        check(host(grantedOperation, nil)["plugin_id"] as? String == "demo", "messages permission returns plugin_id")
    }
}

let capabilityMappings = [
    "message.events": "authorize.message.events", "message.send": "authorize.message.send",
    "message.edit": "authorize.message.edit", "message.delete": "authorize.message.delete",
    "message.forward": "authorize.message.forward"
]
for (capability, grantedOperation) in capabilityMappings.sorted(by: { $0.key < $1.key }) {
    let host = try authorizationHost(permissions: [], capabilities: [capability], name: "capability-\(capability)")
    var expected = zeroAuthorityExpected
    expected[grantedOperation] = allowed
    checkAuthorization(host, expected, "individual capability \(capability)")
}
let held = HeldExecutor()
var started = false, stopped = false, overlaps = 0
settingsManager.setEnabled("demo", enabled: true, inspector: settingsInspector, executor: held) { error in check(error == nil, "Start succeeds"); started = true }
waitUntil { held.count == 1 }
for enabled in [false, true] {
    settingsManager.setEnabled("demo", enabled: enabled, inspector: settingsInspector, executor: held) { error in check(error != nil, "Overlap during start rejected"); overlaps += 1 }
}
waitUntil { overlaps == 2 }
check(held.count == 1, "No overlapping executor start/stop")
held.finish(0); waitUntil { started }
let runningRecords = try settingsManager.plugins()
check(runningRecords.first!.enabled, "Running after held start")
try rejects(.runtimeUnavailable) { try settingsManager.setPolicy(developerMode: false) }
let runningPolicy = try settingsManager.policy()
check(runningPolicy.developerMode, "Developer Mode cannot be disabled with an active session")
check(held.host?("authorize.peer", nil)["error"] == nil, "peer.read authorization reaches manager case")
let leastPrivilegeAuthorization = held.host!
// This plugin declares only peer.read.  The explicit baseline/zero-authority
// matrix makes the two intentional grants visible without deriving outcomes
// from the production table.
let leastPrivilegeExpected = Dictionary(uniqueKeysWithValues: authorizationOperations.map {
    ($0, $0 == "authorize.host" || $0 == "authorize.peer" ? allowed :
        ($0 == "authorize.message.media.send" ? "unsupported_operation" : "permission_denied"))
})
checkAuthorization(leastPrivilegeAuthorization, leastPrivilegeExpected, "least-privilege authorization row")
check(leastPrivilegeAuthorization("authorize.unknown", nil)["error"] as? String == "unsupported_operation", "unknown authorization remains denied")
check(leastPrivilegeAuthorization("authorize.messages", nil)["error"] as? String == "permission_denied", "Message context is denied by default")
try settingsManager.setPolicy(safeMode: true)
check(held.host?("authorize.host", nil)["error"] as? String == "session_inactive", "Safe mode blocks authorization for running sessions")
for (operation, payload) in [("settings", nil), ("load", nil), ("save", Data("blocked".utf8)), ("log", Data("blocked".utf8))] {
    check(held.host?(operation, payload)["error"] as? String == "session_inactive", "Safe mode blocks \(operation) for running sessions")
}
try settingsManager.setPolicy(safeMode: false)
settingsManager.setEnabled("demo", enabled: false, inspector: settingsInspector, executor: held) { error in check(error == nil, "Stop succeeds"); stopped = true }
waitUntil { held.count == 2 }
for enabled in [true, false] {
    settingsManager.setEnabled("demo", enabled: enabled, inspector: settingsInspector, executor: held) { error in check(error != nil, "Overlap during stop rejected"); overlaps += 1 }
}
waitUntil { overlaps == 4 }
check(held.count == 2, "No overlapping executor stop/start")
held.finish(1); waitUntil { stopped }
check(leastPrivilegeAuthorization("authorize.host", nil)["error"] != nil,
      "stopped session blocks authorization")
let stoppedRecords = try settingsManager.plugins()
check(stoppedRecords.first?.executionStatus == "Stopped", "Final stopped state")
try settingsManager.remove("demo", deleteData: false)
let noOptIn = try settingsManager.prepare(source, inspector: Inspector())
uptime += 10; try settingsManager.install(noOptIn)
try rejects(.invalidSettingsTransfer) { _ = try settingsManager.exportSettings("demo") }
try rejects(.invalidSettingsTransfer) { try settingsManager.importSettings("demo", data: exported) }
print("PASS: manager overlapping start/stop, duplicate start/stop rejected; explicit transfer opt-in enforced")
// Real manager persistence fault: successful start, then callback exit cannot
// clear its marker. A second plugin must not replace or clear that attribution.
let recoveryRoot = fixture.appendingPathComponent("callback-recovery")
var failRecoveryWrite = false
let recoveryManager = ReqGramPluginManager(root: recoveryRoot, clock: { uptime }, checkpoint: {
    if failRecoveryWrite { throw NSError(domain: "exit marker fault", code: 1) }
})
try recoveryManager.setPolicy(developerMode: true, trustedOnly: false)
let otherInspector = Inspector(json: Inspector().json.replacingOccurrences(of: "demo", with: "other"))
for inspector in [Inspector(), otherInspector] {
    let ticket = try recoveryManager.prepare(source, inspector: inspector)
    uptime += 10; try recoveryManager.install(ticket)
    try recoveryManager.grantConsent(inspector.json.contains("\"other\"") ? "other" : "demo")
}
let recoveryExecutor = HeldExecutor()
var recoveryStarted = false
recoveryManager.setEnabled("demo", enabled: true, inspector: Inspector(), executor: recoveryExecutor) { error in
    check(error == nil, "Recovery fixture start"); recoveryStarted = true
}
waitUntil { recoveryExecutor.count == 1 }
check(recoveryExecutor.boundary(0, true), "Start marker admitted")
check(recoveryExecutor.boundary(0, false), "Normal exit clears marker")
recoveryExecutor.finish(0); waitUntil { recoveryStarted }
check(recoveryExecutor.boundary(0, true), "Callback marker admitted")
failRecoveryWrite = true
check(!recoveryExecutor.boundary(0, false), "Injected callback exit write fails")
failRecoveryWrite = false
func recoveryMarker() throws -> String? {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: recoveryRoot.appendingPathComponent("state.json"))) as! [String: Any]
    return object["executing"] as? String
}
let failedMarker = try recoveryMarker()
check(failedMarker == "demo", "Failed exit retains original attribution")
check(!recoveryExecutor.boundary(0, false), "Duplicate exit cannot erase failed marker")
check(!recoveryExecutor.boundary(0, true), "Same plugin cannot overwrite failed marker")
recoveryManager.setEnabled("other", enabled: true, inspector: otherInspector, executor: recoveryExecutor) { _ in }
waitUntil { recoveryExecutor.count == 2 }
check(!recoveryExecutor.boundary(1, true), "Other execution refused before Python entry")
check(!recoveryExecutor.boundary(1, false), "Non-owner cannot clear marker")
var recoveryStopped = false
recoveryManager.setEnabled("demo", enabled: false, inspector: Inspector(), executor: recoveryExecutor) { _ in recoveryStopped = true }
waitUntil { recoveryExecutor.count == 3 }
check(!recoveryExecutor.boundary(2, true), "Stop hook cannot overwrite recovery evidence")
recoveryExecutor.finish(2); waitUntil { recoveryStopped }
let markerAfterStop = try recoveryMarker()
check(markerAfterStop == "demo", "Native stop completion preserves recovery evidence")
let afterRestart = ReqGramPluginManager(root: recoveryRoot)
let recoveredPlugins = try afterRestart.plugins()
let recoveredPolicy = try afterRestart.policy()
let markerAfterRecovery = try recoveryMarker()
check(recoveredPolicy.safeMode && markerAfterRecovery == nil, "Fresh manager performs normal recovery")
check(recoveredPlugins.first(where: { $0.id == "demo" })?.quarantineReason?.contains("Interrupted execution") == true,
      "Recovery quarantines original callback owner")
check(recoveredPlugins.first(where: { $0.id == "other" })?.quarantineReason == nil, "No misattribution to later plugin")
print("PASS: callback exit-marker write failure blocks later execution/clear, preserves teardown attribution and restart recovery")
print("PASS: plugin manager snapshot, gates, atomic failure, retention, removal, corruption, symlink; settings defaults/types/validation/persistence/atomic failure/keep/delete tests")
