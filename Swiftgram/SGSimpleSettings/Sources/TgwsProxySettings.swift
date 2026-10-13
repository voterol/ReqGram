import Foundation
import Security

/// Native Tgws supports only a loopback port and a 16-byte secret. Desktop
/// upstreams, DNS overrides, executable/plugin updates and background service
/// operation are intentionally unsupported. Updates require a trusted GitHub
/// release/checks and installing a signed (or re-signed) IPA, not downloaded code.
public final class TgwsProxySettings {
    public static let shared = TgwsProxySettings()
    public static let didChange = Notification.Name("TgwsProxySettings.didChange")
    public static let stateDidChange = Notification.Name("TgwsProxySettings.stateDidChange")
    public static let supportedEditableFields = ["enabled", "port", "secret", "dcRedirects", "bufferKB", "poolSize", "cfProxyEnabled", "cfProxyDomains", "cfWorkerDomains"]
    public static let unsupportedDesktopFeatures = ["upstream", "dns", "background", "hotUpdate", "customExecutable"]
    public static let defaultCFProxyDomains = [
        "pclead.co.uk", "offshor.co.uk", "cakeisalie.co.uk", "noskomnadzor.co.uk",
        "lovetrue.co.uk", "sorokdva.co.uk", "pyatdesyatdva.co.uk", "kartoshka.co.uk",
        "sorokodin.co.uk", "pyatdesyatodin.co.uk", "notelega.co.uk", "ebally.co.uk",
        "nebally.co.uk", "havegreatday.co.uk", "pomogite.co.uk", "fixtelega.co.uk",
        "sadnews.co.uk", "onedaychamp.co.uk", "stopblocking.co.uk", "nothingthere.co.uk"
    ]

    public enum State: Equatable {
        case disabled, starting, ready, upstreamConnected, handshakeRejected, suspended
        case upstreamConnectFailed(String)
        case failed(String)
    }
    public private(set) var state: State = .disabled
    public private(set) var lastNativeErrorCode: String?
    public private(set) var lastClientHandshakeRejectionCode: String?
    private let defaults: UserDefaults
    private let lock = NSRecursiveLock()
    private let key = "reqgram.tgws.settings.v1"
    private var revision: UInt64 = 0
    public var recoveryNotice: String? { defaults.string(forKey: key + ".recovery") }
    public struct Snapshot {
        public let configuration: Configuration
        public let revision: UInt64
    }

    public struct Configuration: Codable, Equatable {
        public var enabled: Bool
        public var port: Int
        public let secret: String
        /// These are persisted compatibility settings only. The pinned iOS
        /// listener deliberately does not consume them until each transport
        /// path has a reviewed, TLS-verified implementation.
        public var dcRedirects: [String: String] = [:]
        public var bufferKB: Int = 256
        public var poolSize: Int = 4
        public var cfProxyEnabled: Bool = false
        public var cfProxyDomains: [String] = []
        public var cfWorkerDomains: [String] = []
        public init(enabled: Bool, port: Int, secret: String, dcRedirects: [String: String] = [:], bufferKB: Int = 256, poolSize: Int = 4, cfProxyEnabled: Bool = true, cfProxyDomains: [String] = [], cfWorkerDomains: [String] = []) {
            self.enabled = enabled; self.port = port; self.secret = secret; self.dcRedirects = dcRedirects
            self.bufferKB = bufferKB; self.poolSize = poolSize; self.cfProxyEnabled = cfProxyEnabled; self.cfProxyDomains = cfProxyDomains; self.cfWorkerDomains = cfWorkerDomains
        }
        private enum CodingKeys: String, CodingKey { case enabled, port, secret, dcRedirects, bufferKB, poolSize, cfProxyEnabled, cfProxyDomains, cfWorkerDomains }
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decode(Bool.self, forKey: .enabled)
            port = try container.decode(Int.self, forKey: .port)
            secret = try container.decode(String.self, forKey: .secret)
            dcRedirects = try container.decodeIfPresent([String: String].self, forKey: .dcRedirects) ?? [:]
            bufferKB = try container.decodeIfPresent(Int.self, forKey: .bufferKB) ?? 256
            poolSize = try container.decodeIfPresent(Int.self, forKey: .poolSize) ?? 4
            cfProxyEnabled = try container.decodeIfPresent(Bool.self, forKey: .cfProxyEnabled) ?? true
            cfProxyDomains = try container.decodeIfPresent([String].self, forKey: .cfProxyDomains) ?? []
            cfWorkerDomains = try container.decodeIfPresent([String].self, forKey: .cfWorkerDomains) ?? []
        }
        public var secretData: Data {
            guard TgwsProxySettings.validate(secret: secret) else { return Data() }
            return Data(stride(from: 0, to: secret.count, by: 2).compactMap { offset in
                let start = secret.index(secret.startIndex, offsetBy: offset)
                let end = secret.index(start, offsetBy: 2)
                return UInt8(secret[start..<end], radix: 16)
            })
        }
    }
    public enum ValidationError: Error { case invalidPort, invalidSecret, invalidBufferKB, invalidPoolSize, invalidDcRedirects, invalidProxyDomains, invalidWorkerDomains, randomGenerationFailed, invalidStoredSettings }
    public static func upstreamFailureCode(_ value: String?) -> String {
        let allowed = ["timeout", "dns", "tls", "refused", "network", "protocol", "unknown"]
        return value.flatMap { allowed.contains($0) ? $0 : nil } ?? "unknown"
    }
    /// Native lifecycle failures are deliberately reduced to a small, stable
    /// vocabulary before they reach UI or logs. These two codes describe a
    /// start race, not a broken listener configuration.
    public static func startupLifecycleCode(_ value: String?) -> String? {
        guard let value else { return nil }
        return ["not_foreground", "start_cancelled"].contains(value) ? value : nil
    }
    public static func isTransientStartupFailure(_ value: String?) -> Bool {
        startupLifecycleCode(value) != nil
    }
    public static func shouldRetryStartupFailure(_ value: String?, isActive: Bool, retryCount: Int) -> Bool {
        isTransientStartupFailure(value) && isActive && retryCount < 3
    }
    public static func nativeFailureCode(_ value: String?) -> String {
        let allowed = ["not_foreground", "start_cancelled", "already_running", "invalid_config", "listener_failed", "secure_random_unavailable", "runtime_error"]
        return value.flatMap { allowed.contains($0) ? $0 : nil } ?? "unknown"
    }
    public static func clientHandshakeRejectionCode(_ value: String?) -> String? {
        let allowed = ["invalid_length", "decrypt_failed", "invalid_protocol", "unsupported_dc"]
        return value.flatMap { allowed.contains($0) ? $0 : nil }
    }
    public static func validate(port: Int) -> Bool { (1024...65535).contains(port) }
    public static func validate(secret: String) -> Bool {
        secret.utf8.count == 32 && secret.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
    public static func validate(bufferKB: Int) -> Bool { (16...4096).contains(bufferKB) }
    public static func validate(poolSize: Int) -> Bool { (1...64).contains(poolSize) }
    private static func validateDomain(_ value: String) -> Bool {
        guard value.count <= 253, !value.isEmpty, !value.contains("/"), !value.contains(":") else { return false }
        return value.split(separator: ".").allSatisfy { part in
            !part.isEmpty && part.count <= 63 && part.first != "-" && part.last != "-" && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
    public static func validate(dcRedirects: [String: String]) -> Bool {
        dcRedirects.count <= 8 && dcRedirects.allSatisfy { key, value in
            ["1", "2", "4", "5", "203"].contains(key) && validateDomain(value)
        }
    }
    public static func validate(cfWorkerDomains: [String]) -> Bool {
        cfWorkerDomains.count <= 8 && Set(cfWorkerDomains).count == cfWorkerDomains.count && cfWorkerDomains.allSatisfy(validateDomain)
    }
    public static func validate(cfProxyDomains: [String]) -> Bool {
        cfProxyDomains.count <= 64 && Set(cfProxyDomains).count == cfProxyDomains.count && cfProxyDomains.allSatisfy(validateDomain)
    }
    /// Accept the MTProxy wire form (dd + 32 hex characters) as well as the
    /// native 16-byte identity. The dd marker is transport framing, not part
    /// of the persisted identity.
    public static func normalizedSecret(_ secret: String) -> String? {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if validate(secret: value) { return value.lowercased() }
        if value.count == 34, value.prefix(2).lowercased() == "dd" {
            let raw = String(value.dropFirst(2))
            return validate(secret: raw) ? raw.lowercased() : nil
        }
        return nil
    }
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Corrupt storage is repaired to a new default-enabled identity. A durable
    /// notice explains the repair; it never authorizes a direct startup route.
    public func configuration() throws -> Configuration {
        lock.lock()
        defer { lock.unlock() }
        let stored = defaults.object(forKey: key)
        if let data = stored as? Data,
           let value = try? JSONDecoder().decode(Configuration.self, from: data),
            Self.validate(port: value.port), Self.validate(secret: value.secret),
            Self.validate(bufferKB: value.bufferKB), Self.validate(poolSize: value.poolSize),
             Self.validate(dcRedirects: value.dcRedirects), Self.validate(cfProxyDomains: value.cfProxyDomains), Self.validate(cfWorkerDomains: value.cfWorkerDomains) {
            return value
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ValidationError.randomGenerationFailed
        }
        let value = Configuration(enabled: false, port: 1443, secret: bytes.map { String(format: "%02x", $0) }.joined(), dcRedirects: ["2": "149.154.167.220", "4": "149.154.167.220"], bufferKB: 256, poolSize: 4, cfProxyEnabled: true, cfProxyDomains: Self.defaultCFProxyDomains, cfWorkerDomains: [])
        defaults.set(try JSONEncoder().encode(value), forKey: key)
        revision += 1
        if stored != nil { defaults.set("invalid_settings_repaired", forKey: key + ".recovery") }
        return value
    }
    public func snapshot() throws -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(configuration: try configuration(), revision: revision)
    }
    /// The validity check AND the caller's database mutations are synchronized
    /// with model edits. Revision rejects ABA disable/enable/disable sequences.
    public func withCurrentSnapshot(_ snapshot: Snapshot, mutation: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard revision == snapshot.revision,
              (try? configuration()) == snapshot.configuration,
              revision == snapshot.revision else { return false }
        mutation()
        return true
    }
    public var enabled: Bool {
        get { (try? configuration().enabled) ?? false }
        set { try? update(enabled: newValue) }
    }
    public var port: Int { (try? configuration().port) ?? 1443 }
    /// Proxy UI can omit the managed entry from sharing without importing the
    /// coordinator. Compare identity, never hide arbitrary localhost proxies.
    public func isManagedProxy(host: String, port: Int, secret: Data) -> Bool {
        guard let config = try? configuration() else { return false }
        return host == "127.0.0.1" && port == config.port && secret == Data([0xdd]) + config.secretData
    }
    public func update(enabled: Bool? = nil, port: Int? = nil) throws {
        try update(enabled: enabled, port: port, secret: nil)
    }
    public func update(enabled: Bool? = nil, port: Int? = nil, secret: String?) throws {
        precondition(Thread.isMainThread)
        if let port = port, !Self.validate(port: port) { throw ValidationError.invalidPort }
        lock.lock()
        do {
        var value = try configuration()
        if let port = port {
            guard Self.validate(port: port) else { throw ValidationError.invalidPort }
            value.port = port
        }
        if let enabled = enabled { value.enabled = enabled }
        let normalizedSecret: String?
        if let secret {
            guard let normalized = Self.normalizedSecret(secret) else { throw ValidationError.invalidSecret }
            normalizedSecret = normalized
        } else {
            normalizedSecret = nil
        }
        if let normalizedSecret {
            value = Configuration(enabled: value.enabled, port: value.port, secret: normalizedSecret, dcRedirects: value.dcRedirects, bufferKB: value.bufferKB, poolSize: value.poolSize, cfProxyEnabled: value.cfProxyEnabled, cfProxyDomains: value.cfProxyDomains, cfWorkerDomains: value.cfWorkerDomains)
        }
        defaults.set(try JSONEncoder().encode(value), forKey: key)
        revision += 1
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        // Never notify while holding the model lock (coordinator lock ordering).
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
    public func update(dcRedirects: [String: String]? = nil, bufferKB: Int? = nil, poolSize: Int? = nil, cfProxyEnabled: Bool? = nil, cfProxyDomains: [String]? = nil, cfWorkerDomains: [String]? = nil) throws {
        precondition(Thread.isMainThread)
        lock.lock()
        do {
            var value = try configuration()
            if let valueToSet = bufferKB { guard Self.validate(bufferKB: valueToSet) else { throw ValidationError.invalidBufferKB }; value.bufferKB = valueToSet }
            if let valueToSet = poolSize { guard Self.validate(poolSize: valueToSet) else { throw ValidationError.invalidPoolSize }; value.poolSize = valueToSet }
            if let valueToSet = dcRedirects { guard Self.validate(dcRedirects: valueToSet) else { throw ValidationError.invalidDcRedirects }; value.dcRedirects = valueToSet }
            if let valueToSet = cfProxyDomains { guard Self.validate(cfProxyDomains: valueToSet) else { throw ValidationError.invalidProxyDomains }; value.cfProxyDomains = valueToSet }
            if let valueToSet = cfWorkerDomains { guard Self.validate(cfWorkerDomains: valueToSet) else { throw ValidationError.invalidWorkerDomains }; value.cfWorkerDomains = valueToSet }
            if let valueToSet = cfProxyEnabled { value.cfProxyEnabled = valueToSet }
            defaults.set(try JSONEncoder().encode(value), forKey: key)
            revision += 1
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
    public func regenerateSecret() throws {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ValidationError.randomGenerationFailed
        }
        try update(secret: bytes.map { String(format: "%02x", $0) }.joined())
    }
    public func reportState(_ state: State) {
        precondition(Thread.isMainThread)
        guard self.state != state else { return }
        self.state = state
        NotificationCenter.default.post(name: Self.stateDidChange, object: self)
    }
    public func reportNativeErrorCode(_ code: String?) {
        precondition(Thread.isMainThread)
        // A new current attempt supersedes the previous native diagnostic.
        // nil is intentionally the only way to clear it; unknown native input
        // remains redacted to the stable "unknown" value.
        let safe = code == nil ? nil : Self.nativeFailureCode(code)
        guard lastNativeErrorCode != safe else { return }
        lastNativeErrorCode = safe
        NotificationCenter.default.post(name: Self.stateDidChange, object: self)
    }
    public func reportClientHandshakeRejectionCode(_ code: String?) {
        precondition(Thread.isMainThread)
        let safe = Self.clientHandshakeRejectionCode(code)
        guard lastClientHandshakeRejectionCode != safe else { return }
        lastClientHandshakeRejectionCode = safe
        NotificationCenter.default.post(name: Self.stateDidChange, object: self)
    }
}
