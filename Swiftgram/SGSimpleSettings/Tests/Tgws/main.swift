import Foundation

let suite = "tgws.offline.tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let settings = TgwsProxySettings(defaults: defaults)
let initial = try settings.configuration()
precondition(initial.enabled && initial.port == 1443)
precondition(initial.secretData.count == 16 && TgwsProxySettings.validate(secret: initial.secret))
precondition(initial.cfProxyEnabled)
precondition(initial.cfProxyDomains == TgwsProxySettings.defaultCFProxyDomains)
precondition(initial.cfWorkerDomains.isEmpty)
let reloaded = try TgwsProxySettings(defaults: defaults).configuration()
precondition(reloaded == initial)
let independent = try TgwsProxySettings(defaults: UserDefaults(suiteName: "tgws.independent.\(UUID().uuidString)")!).configuration()
precondition(independent.secret != initial.secret)
try settings.update(enabled: false, port: 65535)
precondition(!settings.enabled && settings.port == 65535)
let changed = try settings.configuration()
precondition(changed.secret == initial.secret)
for port in [0, 443, 1023, 65536, Int.max] {
    precondition(!TgwsProxySettings.validate(port: port))
    do { try settings.update(port: port); fatalError("accepted invalid port") }
    catch TgwsProxySettings.ValidationError.invalidPort {}
}
for secret in ["", "dd" + initial.secret, String(repeating: "g", count: 32), String(repeating: "é", count: 16)] {
    precondition(!TgwsProxySettings.validate(secret: secret))
}
precondition(TgwsProxySettings.normalizedSecret("dd" + initial.secret) == initial.secret)
do { try settings.update(secret: "bad"); fatalError("accepted invalid secret") }
catch TgwsProxySettings.ValidationError.invalidSecret {}
let priorSecret = changed.secret
try settings.update(secret: "dd" + String(repeating: "a", count: 32))
precondition(settings.enabled == false && settings.port == 65535)
let rotated = try settings.configuration()
precondition(rotated.secret != priorSecret)
precondition(rotated.dcRedirects == changed.dcRedirects)
precondition(rotated.bufferKB == changed.bufferKB)
precondition(rotated.poolSize == changed.poolSize)
precondition(rotated.cfProxyEnabled == changed.cfProxyEnabled)
precondition(rotated.cfProxyDomains == changed.cfProxyDomains)
precondition(rotated.cfWorkerDomains == changed.cfWorkerDomains)
precondition(TgwsProxySettings.validate(secret: initial.secret.uppercased()))
var changes = 0
let observer = NotificationCenter.default.addObserver(forName: TgwsProxySettings.didChange, object: nil, queue: nil) { _ in changes += 1 }
try settings.update(enabled: true, port: 1443)
precondition(changes == 1)
NotificationCenter.default.removeObserver(observer)
defaults.set(Data("corrupt".utf8), forKey: "reqgram.tgws.settings.v1")
let repaired = try settings.configuration()
precondition(repaired.enabled && repaired.port == 1443)
precondition(repaired.secretData.count == 16 && repaired.secret != initial.secret)
precondition(settings.recoveryNotice == "invalid_settings_repaired")
let repairedReload = try settings.configuration()
precondition(repairedReload == repaired)
defaults.set("wrong stored type", forKey: "reqgram.tgws.settings.v1")
try settings.update(enabled: false)
precondition(!settings.enabled) // explicit disable also works on corrupt storage
defaults.set(Data("corrupt again".utf8), forKey: "reqgram.tgws.settings.v1")
let safeStartup = try settings.snapshot()
precondition(safeStartup.configuration.enabled)
var mutated = false
precondition(settings.withCurrentSnapshot(safeStartup) { mutated = true })
precondition(mutated)
try settings.update(enabled: false)
mutated = false
precondition(!settings.withCurrentSnapshot(safeStartup) { mutated = true })
precondition(!mutated)
for (badPort, badSecret) in [(443, initial.secret), (1443, "not-a-secret")] {
    defaults.set(try JSONSerialization.data(withJSONObject: [
        "enabled": false, "port": badPort, "secret": badSecret
    ]), forKey: "reqgram.tgws.settings.v1")
    let recovered = try settings.snapshot()
    precondition(recovered.configuration.enabled && recovered.configuration.port == 1443)
    precondition(recovered.configuration.secretData.count == 16)
    precondition(settings.recoveryNotice == "invalid_settings_repaired")
}
for code in ["not_foreground", "start_cancelled"] {
    precondition(TgwsProxySettings.isTransientStartupFailure(code))
    precondition(TgwsProxySettings.startupLifecycleCode(code) == code)
    settings.reportNativeErrorCode(code)
    precondition(settings.lastNativeErrorCode == code)
    for attempt in 0..<3 {
        precondition(TgwsProxySettings.shouldRetryStartupFailure(code, isActive: true, retryCount: attempt))
    }
    precondition(!TgwsProxySettings.shouldRetryStartupFailure(code, isActive: true, retryCount: 3))
    precondition(!TgwsProxySettings.shouldRetryStartupFailure(code, isActive: false, retryCount: 0))
}
for code in ["listener_failed", "invalid_config", "already_running", "NSError(domain: secret)"] {
    precondition(!TgwsProxySettings.isTransientStartupFailure(code))
    precondition(TgwsProxySettings.startupLifecycleCode(code) == nil)
    precondition(!TgwsProxySettings.shouldRetryStartupFailure(code, isActive: true, retryCount: 0))
}
precondition(!TgwsProxySettings.isTransientStartupFailure(nil))
settings.reportNativeErrorCode("raw secret")
precondition(settings.lastNativeErrorCode == "unknown")
print("Tgws settings offline tests passed")
