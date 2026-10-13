import Foundation
import CryptoKit

public protocol ReqGramPluginArchiveInspector {
    func entryNames(in archive: URL) throws -> [String]
    func readEntry(named: String, from archive: URL) throws -> Data
    func contents(in archive: URL) throws -> [String: Data]
}

public extension ReqGramPluginArchiveInspector {
    func contents(in archive: URL) throws -> [String: Data] {
        let names = try entryNames(in: archive)
        guard Set(names).count == names.count else { throw ReqGramPluginError.invalidPackage }
        var result: [String: Data] = [:]
        for name in names { result[name] = try readEntry(named: name, from: archive) }
        return result
    }
}

public protocol ReqGramPluginExecutor {
    func execute(module: String, directory: URL, start: Bool, host: @escaping (String, Data?) -> [String: Any], boundary: @escaping (Bool) -> Bool, completion: @escaping (Error?) -> Void)
}

public struct ReqGramPluginManifest: Codable, Equatable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let author: String
    public let entry: String
    public let api_version: String
    public let permissions: [String]
    /// Declares bounded, explicit message change delivery. This is not peer-wide discovery.
    public let capabilities: [String]?
    /// Only a declaration, not permission to render arbitrary native UI.
    public let settings: [String: String]?
    public let settings_schema: ReqGramSettingsSchema?
    public let settings_transfer: Bool?
}

public enum ReqGramSettingValue: Codable, Equatable {
    case boolean(Bool), string(String)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .boolean(b) }
        else { self = .string(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case let .boolean(v): try c.encode(v); case let .string(v): try c.encode(v) }
    }
    public var display: String { switch self { case let .boolean(v): return v ? "On" : "Off"; case let .string(v): return v } }
}
public struct ReqGramSettingField: Codable, Equatable {
    public let key: String
    public let label: String
    public let type: String
    public let default_value: ReqGramSettingValue
    public let options: [String]?
    /// Explicit declaration that this field contains portable, non-secret preferences.
    public let transferable: Bool?
    public func accepts(_ value: ReqGramSettingValue) -> Bool {
        switch (type, value) {
        case ("boolean", .boolean): return true
        case ("string", let .string(v)): return v.utf8.count <= 1024
        case ("selection", let .string(v)): return options?.contains(v) == true
        default: return false
        }
    }
}
public struct ReqGramSettingsSchema: Codable, Equatable {
    public let version: Int
    public let fields: [ReqGramSettingField]
    public var valid: Bool {
        version == 1 && fields.count <= 32 && Set(fields.map { $0.key }).count == fields.count && fields.allSatisfy {
            $0.key.range(of: "^[A-Za-z][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil &&
            !$0.label.isEmpty && $0.label.count <= 128 && $0.accepts($0.default_value) &&
            ($0.type == "selection" ? ($0.options?.isEmpty == false && $0.options!.count <= 32 && Set($0.options!).count == $0.options!.count && $0.options!.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 }) : $0.options == nil)
        }
    }
}

public enum ReqGramPluginError: Error, LocalizedError {
    case invalidPackage, unsafePath, corruptStorage, developerModeRequired, trustedOnly, confirmationRequired, expiredImport, runtimeUnavailable, invalidSettingsTransfer, consentRequired, invalidConsent
    public var errorDescription: String? {
        switch self {
        case .invalidPackage: return "Invalid or unsupported .ixplugin package."
        case .unsafePath: return "Plugin storage contains an unsafe filesystem path."
        case .corruptStorage: return "Plugin storage could not be decoded; it has not been overwritten."
        case .developerModeRequired: return "ReqGram Developer Mode is required for plugin management."
        case .trustedOnly: return "Local files are untrusted. Turn off Trusted installs only to import one."
        case .confirmationRequired: return "Review the warning for at least 10 seconds before installing."
        case .expiredImport: return "This import is no longer available. Select the file again."
        case .runtimeUnavailable: return "Installed, not running. The Python runtime is not connected in this build."
        case .invalidSettingsTransfer: return "Settings transfer is disabled or the file does not match this plugin's declared transferable settings. No settings were changed."
        case .consentRequired: return "Explicit consent is required before this plugin can be enabled."
        case .invalidConsent: return "Plugin consent no longer matches the installed archive or declared access. Review it again."
        }
    }
}

public enum ReqGramPluginPackage {
    /// Permission declarations accepted by the host runtime. Capabilities are
    /// declared separately and are intentionally not included here.
    public static let recognizedPermissions: Set<String> = [
        "ui.alert", "ui.notice", "ios.safe", "accounts.read", "accounts.profile",
        "peer.read", "network", "network.insecure", "messages.context", "full_access",
        "chat.context", "message.get", "message.history", "message.search", "storage", "log"
    ]
    /// Metadata for the install warning. `full_access` is recognized and displayed
    /// as high risk; the executor still decides which operations are implemented.
    public static let permissionRisk: [String: String] = ["full_access": "high"]

    public static func validate(manifestData: Data, filename: String) throws -> ReqGramPluginManifest {
        guard (filename as NSString).lastPathComponent == filename, filename.lowercased().hasSuffix(".ixplugin"), manifestData.count <= 256 * 1024,
              let m = try? JSONDecoder().decode(ReqGramPluginManifest.self, from: manifestData),
              m.id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,126}$", options: .regularExpression) != nil, !m.id.contains(".."),
              !m.name.isEmpty, m.name.count <= 128, !m.version.isEmpty, m.version.count <= 256,
              !m.description.isEmpty, m.description.count <= 4096, !m.author.isEmpty, m.author.count <= 256,
               m.entry == "main.py", m.api_version == "1", m.permissions.count <= 64,
               (m.capabilities ?? []).count <= 16,
               (m.capabilities ?? []).allSatisfy({ $0 == "message.events" || $0 == "message.send" || $0 == "message.edit" || $0 == "message.delete" || $0 == "message.forward" }),
               m.permissions.allSatisfy({ Self.recognizedPermissions.contains($0) && $0.count <= 128 }),
                (m.settings?.count ?? 0) <= 64, m.settings_schema?.valid != false,
                m.settings_transfer != true || m.settings_schema?.fields.contains(where: { $0.transferable == true }) == true else { throw ReqGramPluginError.invalidPackage }
        return m
    }
    public static func inspect(_ url: URL, inspector: ReqGramPluginArchiveInspector) throws -> ReqGramPluginManifest {
        return try inspect(contents: inspector.contents(in: url), filename: url.lastPathComponent)
    }
    public static func inspect(contents: [String: Data], filename: String) throws -> ReqGramPluginManifest {
        let names = Array(contents.keys)
        guard names.count <= 512, Set(names).count == names.count, names.contains("manifest.json"), names.contains("main.py"), names.allSatisfy({ path in
            !path.contains("\\") && !path.contains(":") && !path.contains("\0") && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        }) else { throw ReqGramPluginError.invalidPackage }
        return try validate(manifestData: contents["manifest.json"]!, filename: filename)
    }
}

public struct ReqGramPluginRecord: Codable, Equatable {
    public let manifest: ReqGramPluginManifest
    public let installedAt: Date
    public var quarantineReason: String?
    public var id: String { manifest.id }
    public var trusted: Bool { false } // No authenticated distribution channel exists yet.
    public var enabled: Bool { executionStatus == "Running" }
    public var executionStatus: String? = nil // Session-only; never restore execution intent.
}

public struct ReqGramPluginConsent: Codable, Equatable {
    public let archiveDigest: String
    public let permissions: [String]
    public let capabilities: [String]
}

public struct ReqGramPluginImportTicket {
    public let manifest: ReqGramPluginManifest
    fileprivate let token: UUID
}

/// Foundation-only installation store. Python execution belongs to the runtime agent.
/// One atomic state file contains metadata, archives and retained opaque plugin data,
/// avoiding a split UserDefaults/filesystem commit. No package entries are executed.
public final class ReqGramPluginManager {
    public static let shared = ReqGramPluginManager(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ReqGramPlugins"))
    public static let didChangeNotification = Notification.Name("ReqGramPluginManager.didChange")
    private static let queue = DispatchQueue(label: "reqgram.plugins.storage")
    private struct Installation: Codable {
        var record: ReqGramPluginRecord; var archive: Data; var archiveDigest: String?
        enum CodingKeys: String, CodingKey { case record, archive, archiveDigest }
        init(record: ReqGramPluginRecord, archive: Data) { self.record = record; self.archive = archive; self.archiveDigest = Self.digest(archive) }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            record = try c.decode(ReqGramPluginRecord.self, forKey: .record)
            archive = try c.decode(Data.self, forKey: .archive)
            archiveDigest = try c.decodeIfPresent(String.self, forKey: .archiveDigest)
        }
        static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }
    private struct Log: Codable { let date: Date; let id: String; let message: String }
    private struct State: Codable {
        var settingsValues: [String: [String: ReqGramSettingValue]]? = nil
        var installations: [String: Installation] = [:]
        var consents: [String: ReqGramPluginConsent] = [:]
        var data: [String: Data] = [:]
        var developerMode = false
        var trustedOnly = true
        var safeMode = false
        var retentionDays = 7
        var logs: [Log] = []
        var executing: String? = nil
        enum CodingKeys: String, CodingKey { case settingsValues, installations, data, consents, developerMode, trustedOnly, safeMode, retentionDays, logs, executing }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            settingsValues = try c.decodeIfPresent([String: [String: ReqGramSettingValue]].self, forKey: .settingsValues)
            installations = try c.decodeIfPresent([String: Installation].self, forKey: .installations) ?? [:]
            data = try c.decodeIfPresent([String: Data].self, forKey: .data) ?? [:]
            consents = try c.decodeIfPresent([String: ReqGramPluginConsent].self, forKey: .consents) ?? [:]
            developerMode = try c.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false
            trustedOnly = try c.decodeIfPresent(Bool.self, forKey: .trustedOnly) ?? true
            safeMode = try c.decodeIfPresent(Bool.self, forKey: .safeMode) ?? false
            retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 7
            logs = try c.decodeIfPresent([Log].self, forKey: .logs) ?? []
            executing = try c.decodeIfPresent(String.self, forKey: .executing)
        }
    }
    private struct Pending { let manifest: ReqGramPluginManifest; let bytes: Data; var readyAt: TimeInterval }

    /// The host authorization surface is deliberately data-driven.  Keep this
    /// table in sync with the executor's `authorize.*` calls: an absent row is
    /// an unsupported operation, never an implicit grant.
    public struct AuthorizationRule: Equatable {
        public let permission: String?
        public let capability: String?
        public let baselineAllowed: Bool
        public let fullAccessAllowed: Bool
        public let unsupported: Bool

        public init(permission: String? = nil, capability: String? = nil, baselineAllowed: Bool = false,
                    fullAccessAllowed: Bool, unsupported: Bool = false) {
            self.permission = permission
            self.capability = capability
            self.baselineAllowed = baselineAllowed
            self.fullAccessAllowed = fullAccessAllowed
            self.unsupported = unsupported
        }
    }

    public static let authorizationRules: [String: AuthorizationRule] = [
        // This is only the bounded session/host gate. It does not grant any
        // capability; every privileged row below is checked independently.
        "authorize.host": AuthorizationRule(baselineAllowed: true, fullAccessAllowed: false),
        "authorize.ui": AuthorizationRule(permission: "ui.alert", fullAccessAllowed: true),
        "authorize.notice": AuthorizationRule(permission: "ui.notice", fullAccessAllowed: true),
        "authorize.ios.safe": AuthorizationRule(permission: "ios.safe", fullAccessAllowed: false),
        "authorize.accounts": AuthorizationRule(permission: "accounts.read", fullAccessAllowed: true),
        "authorize.profile": AuthorizationRule(permission: "accounts.profile", fullAccessAllowed: true),
        "authorize.peer": AuthorizationRule(permission: "peer.read", fullAccessAllowed: true),
        "authorize.network": AuthorizationRule(permission: "network", fullAccessAllowed: true),
        "authorize.network.insecure": AuthorizationRule(permission: "network.insecure", fullAccessAllowed: true),
        "authorize.messages": AuthorizationRule(permission: "messages.context", fullAccessAllowed: true),
        "authorize.chat.context": AuthorizationRule(permission: "chat.context", fullAccessAllowed: true),
        "authorize.message.get": AuthorizationRule(permission: "message.get", fullAccessAllowed: true),
        "authorize.message.history": AuthorizationRule(permission: "message.history", fullAccessAllowed: true),
        "authorize.message.search": AuthorizationRule(permission: "message.search", fullAccessAllowed: true),
        "authorize.message.events": AuthorizationRule(capability: "message.events", fullAccessAllowed: true),
        "authorize.message.send": AuthorizationRule(capability: "message.send", fullAccessAllowed: true),
        // Media mutation is intentionally not implemented, including for full_access.
        "authorize.message.media.send": AuthorizationRule(fullAccessAllowed: false, unsupported: true),
        "authorize.message.edit": AuthorizationRule(capability: "message.edit", fullAccessAllowed: true),
        "authorize.message.delete": AuthorizationRule(capability: "message.delete", fullAccessAllowed: true),
        "authorize.message.forward": AuthorizationRule(capability: "message.forward", fullAccessAllowed: true),
        // Raw MTProto is deliberately available only through the high-risk
        // full_access grant, never through a narrower permission.
        "authorize.mtproto": AuthorizationRule(fullAccessAllowed: true),
        "authorize.native": AuthorizationRule(fullAccessAllowed: true)
    ]

    private var pending: [UUID: Pending] = [:]
    private var statuses: [String: String] = [:]
    private var modules: [String: String] = [:]
    private var directories: [String: URL] = [:]
    private var recovered = false
    private let root: URL
    private let clock: () -> TimeInterval
    private let date: () -> Date
    private let checkpoint: () throws -> Void
    public convenience init(root: URL) { self.init(root: root, clock: { ProcessInfo.processInfo.systemUptime }, date: Date.init, checkpoint: {}) }
    init(root: URL, clock: @escaping () -> TimeInterval, date: @escaping () -> Date = Date.init, checkpoint: @escaping () throws -> Void = {}) {
        // Canonicalize platform parents (/var), NEVER the installer-owned leaf.
        self.root = root.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(root.lastPathComponent)
        self.clock = clock; self.date = date; self.checkpoint = checkpoint
    }
    private func validateStorage() throws {
        let fm = FileManager.default
        var path = root
        while path.path != "/" {
            if let attributes = try? fm.attributesOfItem(atPath: path.path), attributes[.type] as? FileAttributeType != .typeDirectory {
                // Foundation on Darwin may retain /var even after resolution.
                // Permit only Apple's fixed system alias, never the owned root.
                let systemAlias = path != root && path.path == "/var" && (try? fm.destinationOfSymbolicLink(atPath: path.path)) == "private/var"
                guard systemAlias else { throw ReqGramPluginError.unsafePath }
            }
            path.deleteLastPathComponent()
        }
        let file = root.appendingPathComponent("state.json")
        if let attributes = try? fm.attributesOfItem(atPath: file.path), attributes[.type] as? FileAttributeType != .typeRegular { throw ReqGramPluginError.unsafePath }
    }
    private func read() throws -> State {
        try validateStorage()
        let file = root.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return State() }
        guard let state = try? JSONDecoder().decode(State.self, from: Data(contentsOf: file)) else { throw ReqGramPluginError.corruptStorage }
        return state
    }
    private func prune(_ state: inout State) {
        let cutoff = date().addingTimeInterval(-Double(state.retentionDays) * 86400)
        state.logs.removeAll { $0.date < cutoff }
    }
    private func write(_ state: State) throws {
        try validateStorage()
        let bytes = try JSONEncoder().encode(state)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try checkpoint()
        try bytes.write(to: root.appendingPathComponent("state.json"), options: .atomic)
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
    }
    private func recover() throws {
        guard !recovered else { return }
        var s = try read()
        if let id = s.executing {
            s.safeMode = true
            s.installations[id]?.record.quarantineReason = "Interrupted execution: crash, termination or force-quit cannot be distinguished."
            s.executing = nil
            try write(s)
            ReqGramMessageActions.shared.revoke()
        }
        recovered = true
    }
    public func plugins() throws -> [ReqGramPluginRecord] { try Self.queue.sync { try recover(); return try read().installations.values.map { installation in var r = installation.record; r.executionStatus = statuses[r.id] ?? "Stopped"; return r }.sorted { $0.id < $1.id } } }
    public func policy() throws -> (developerMode: Bool, trustedOnly: Bool, safeMode: Bool, retentionDays: Int) { try Self.queue.sync { let s = try read(); return (s.developerMode, s.trustedOnly, s.safeMode, s.retentionDays) } }
    public func setPolicy(developerMode: Bool? = nil, trustedOnly: Bool? = nil, safeMode: Bool? = nil, retentionDays: Int? = nil) throws {
        try Self.queue.sync {
            var s = try read()
            if developerMode == false && !modules.isEmpty { throw ReqGramPluginError.runtimeUnavailable }
            if let value = developerMode {
                s.developerMode = value
                if !value { s.trustedOnly = true }
            }
            if let value = trustedOnly { s.trustedOnly = value }
            if !s.developerMode { s.trustedOnly = true }
            if let value = safeMode { s.safeMode = value }
            if let value = retentionDays { s.retentionDays = min(365, max(1, value)) }
            prune(&s); try write(s)
            // Invalidate queued message events and captured registration scopes,
            // including requests authorized just before this policy write.
            // Registry revocation never enters a session lock or this queue.
            if s.safeMode { ReqGramMessageActions.shared.revoke() }
        }
    }
    public func prepare(_ source: URL, inspector: ReqGramPluginArchiveInspector) throws -> ReqGramPluginImportTicket {
        try Self.queue.sync {
            let state = try read()
            guard state.developerMode else { throw ReqGramPluginError.developerModeRequired }
            guard !state.trustedOnly else { throw ReqGramPluginError.trustedOnly }
            guard source.pathExtension.lowercased() == "ixplugin" else { throw ReqGramPluginError.invalidPackage }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: source)
            defer { handle.closeFile() }
            let bytes = handle.readData(ofLength: 8 * 1024 * 1024 + 1)
            guard bytes.count <= 8 * 1024 * 1024 else { throw ReqGramPluginError.invalidPackage }
            let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ixplugin")
            defer { try? FileManager.default.removeItem(at: snapshot) }
            try bytes.write(to: snapshot, options: .atomic)
            let manifest = try ReqGramPluginPackage.inspect(snapshot, inspector: inspector)
            let token = UUID()
            pending.removeAll() // At most one retained, bounded import snapshot.
            pending[token] = Pending(manifest: manifest, bytes: bytes, readyAt: clock() + 10)
            return ReqGramPluginImportTicket(manifest: manifest, token: token)
        }
    }
    /// UI resets on loss of foreground review; infinity keeps install blocked even
    /// if timers are suspended. Resume requires a fresh ten seconds of review.
    public func setReviewActive(_ ticket: ReqGramPluginImportTicket, active: Bool) {
        Self.queue.sync { pending[ticket.token]?.readyAt = active ? clock() + 10 : .infinity }
    }
    public func remainingSeconds(_ ticket: ReqGramPluginImportTicket) -> Int { Self.queue.sync { guard let p = pending[ticket.token], p.readyAt.isFinite else { return 10 }; return max(0, Int(ceil(p.readyAt - clock()))) } }
    public func cancel(_ ticket: ReqGramPluginImportTicket) { Self.queue.sync { _ = pending.removeValue(forKey: ticket.token) } }
    public func install(_ ticket: ReqGramPluginImportTicket) throws {
        try Self.queue.sync {
            var s = try read()
            guard s.developerMode else { throw ReqGramPluginError.developerModeRequired }
            guard !s.trustedOnly else { throw ReqGramPluginError.trustedOnly }
            guard let p = pending[ticket.token] else { throw ReqGramPluginError.expiredImport }
            guard modules[p.manifest.id] == nil else { throw ReqGramPluginError.runtimeUnavailable }
            guard clock() >= p.readyAt else { throw ReqGramPluginError.confirmationRequired }
            let retainedBytes = s.installations.filter { $0.key != p.manifest.id }.values.reduce(0) { $0 + $1.archive.count }
            guard retainedBytes + p.bytes.count <= 64 * 1024 * 1024 else { throw ReqGramPluginError.invalidPackage }
            s.installations[p.manifest.id] = Installation(record: ReqGramPluginRecord(manifest: p.manifest, installedAt: date()), archive: p.bytes)
            // Installation is deliberately not consent. Existing and newly
            // installed plugins remain disabled until the user opts in.
            s.consents.removeValue(forKey: p.manifest.id)
            s.logs.append(Log(date: date(), id: p.manifest.id, message: "Installed local untrusted package; runtime not started"))
            prune(&s); try write(s); pending.removeValue(forKey: ticket.token)
        }
    }
    /// Records explicit user consent for the exact retained archive and access
    /// declarations. It is invalidated automatically by reinstall/mismatch.
    public func grantConsent(_ id: String) throws {
        try Self.queue.sync {
            var s = try read()
            guard s.developerMode else { throw ReqGramPluginError.developerModeRequired }
            guard let installation = s.installations[id] else { throw ReqGramPluginError.expiredImport }
            let permissions = installation.record.manifest.permissions.sorted()
            let capabilities = (installation.record.manifest.capabilities ?? []).sorted()
            let digest = Installation.digest(installation.archive)
            s.consents[id] = ReqGramPluginConsent(archiveDigest: digest, permissions: permissions, capabilities: capabilities)
            try write(s)
        }
    }
    public func hasValidConsent(_ id: String) throws -> Bool {
        try Self.queue.sync {
            let s = try read()
            guard s.developerMode else { throw ReqGramPluginError.developerModeRequired }
            guard let i = s.installations[id], let c = s.consents[id] else { return false }
            return c.archiveDigest == Installation.digest(i.archive) && c.permissions == i.record.manifest.permissions.sorted() && c.capabilities == (i.record.manifest.capabilities ?? []).sorted()
        }
    }
    public func remove(_ id: String, deleteData: Bool) throws {
        try Self.queue.sync { let state = try read(); guard state.developerMode else { throw ReqGramPluginError.developerModeRequired }; guard modules[id] == nil else { throw ReqGramPluginError.runtimeUnavailable }; var s = state; s.installations.removeValue(forKey: id); if deleteData { s.data.removeValue(forKey: id); s.settingsValues?.removeValue(forKey: id) }; s.logs.append(Log(date: date(), id: id, message: deleteData ? "Removed with data" : "Removed; data retained")); prune(&s); try write(s); statuses.removeValue(forKey: id) }
    }
    private func settings(_ id: String, state: State) throws -> [String: ReqGramSettingValue] {
        guard let schema = state.installations[id]?.record.manifest.settings_schema, schema.valid else { throw ReqGramPluginError.invalidPackage }
        var result: [String: ReqGramSettingValue] = [:]
        for field in schema.fields {
            let stored = state.settingsValues?[id]?[field.key]
            result[field.key] = stored.flatMap { field.accepts($0) ? $0 : nil } ?? field.default_value
        }
        return result
    }
    public func settings(_ id: String) throws -> [String: ReqGramSettingValue] { try Self.queue.sync { let state = try read(); guard state.developerMode else { throw ReqGramPluginError.developerModeRequired }; return try settings(id, state: state) } }
    private struct TransferField: Codable, Equatable {
        let key: String
        let type: String
        let options: [String]?
    }
    private struct SettingsTransfer: Codable {
        let format: Int
        let plugin_id: String
        let schema_version: Int
        let fields: [TransferField]
        let values: [String: ReqGramSettingValue]
    }
    private func transferSchema(_ id: String, state: State) throws -> ReqGramSettingsSchema {
        guard let m = state.installations[id]?.record.manifest, m.settings_transfer == true,
              let schema = m.settings_schema, schema.valid,
              schema.fields.contains(where: { $0.transferable == true }) else { throw ReqGramPluginError.invalidSettingsTransfer }
        return schema
    }
    private func transferFields(_ schema: ReqGramSettingsSchema) -> [TransferField] {
        schema.fields.filter { $0.transferable == true }.map { TransferField(key: $0.key, type: $0.type, options: $0.options) }.sorted { $0.key < $1.key }
    }
    /// Returns only explicitly portable settings, never archives, opaque storage, logs or private fields.
    public func exportSettings(_ id: String) throws -> Data {
        try Self.queue.sync {
            let s = try read(); guard s.developerMode else { throw ReqGramPluginError.developerModeRequired }; let schema = try transferSchema(id, state: s)
            let fields = transferFields(schema), values = try settings(id, state: s)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(SettingsTransfer(format: 1, plugin_id: id, schema_version: schema.version, fields: fields, values: values.filter { key, _ in fields.contains { $0.key == key } }))
        }
    }
    /// Data-only boundary: imported JSON cannot select paths or another installation.
    public func importSettings(_ id: String, data: Data) throws {
        try Self.queue.sync {
            var s = try read()
            guard s.developerMode else { throw ReqGramPluginError.developerModeRequired }; let schema = try transferSchema(id, state: s)
            guard data.count <= 128 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(["format", "plugin_id", "schema_version", "fields", "values"]),
                  let transfer = try? JSONDecoder().decode(SettingsTransfer.self, from: data),
                  transfer.format == 1, transfer.plugin_id == id, transfer.schema_version == schema.version,
                  transfer.fields == transferFields(schema),
                  Set(transfer.values.keys) == Set(transfer.fields.map { $0.key }),
                  schema.fields.filter({ $0.transferable == true }).allSatisfy({ field in transfer.values[field.key].map { field.accepts($0) } == true }) else { throw ReqGramPluginError.invalidSettingsTransfer }
            var values = try settings(id, state: s)
            values.merge(transfer.values) { _, new in new }
            if s.settingsValues == nil { s.settingsValues = [:] }
            s.settingsValues?[id] = values
            try write(s)
        }
    }
    public func setSetting(_ id: String, key: String, value: ReqGramSettingValue) throws {
        try Self.queue.sync {
            var s = try read()
            guard s.developerMode else { throw ReqGramPluginError.developerModeRequired }
            guard let field = s.installations[id]?.record.manifest.settings_schema?.fields.first(where: { $0.key == key }), field.accepts(value) else { throw ReqGramPluginError.invalidPackage }
            var values = try settings(id, state: s)
            values[key] = value
            if s.settingsValues == nil { s.settingsValues = [:] }
            s.settingsValues?[id] = values
            try write(s)
        }
    }
    /// Extraction writes regular files into a fresh private directory, never archive paths directly.
    public func setEnabled(_ id: String, enabled: Bool, inspector: ReqGramPluginArchiveInspector, executor: ReqGramPluginExecutor, completion: @escaping (Error?) -> Void) {
        Self.queue.async {
            do {
                try self.recover()
                let s = try self.read()
                guard let installation = s.installations[id], !(enabled && s.safeMode), self.statuses[id] != "Starting", self.statuses[id] != "Stopping" else { throw ReqGramPluginError.runtimeUnavailable }
                if enabled {
                    guard s.developerMode else { throw ReqGramPluginError.developerModeRequired }
                    guard let consent = s.consents[id] else { throw ReqGramPluginError.consentRequired }
                    let digest = Installation.digest(installation.archive)
                    guard consent.archiveDigest == digest && consent.permissions == installation.record.manifest.permissions.sorted() && consent.capabilities == (installation.record.manifest.capabilities ?? []).sorted() else { throw ReqGramPluginError.invalidConsent }
                }
                if enabled == (self.statuses[id] == "Running") { DispatchQueue.main.async { completion(nil) }; return }
                let module: String
                let directory: URL
                if enabled {
                    guard self.modules[id] == nil else { throw ReqGramPluginError.runtimeUnavailable }
                    module = "reqgram_plugin_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    directory = self.root.appendingPathComponent(module)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    do {
                        let archive = directory.appendingPathComponent("snapshot.ixplugin")
                        try installation.archive.write(to: archive, options: .atomic)
                        let contents = try inspector.contents(in: archive)
                        guard try ReqGramPluginPackage.inspect(contents: contents, filename: archive.lastPathComponent) == installation.record.manifest else { throw ReqGramPluginError.invalidPackage }
                        let names = Array(contents.keys)
                        // Current API accepts Python source and JSON assets only; no native code or links.
                        guard names.allSatisfy({ $0.hasSuffix(".py") || $0.hasSuffix(".json") }), Set(names.map { $0.lowercased() }).count == names.count else { throw ReqGramPluginError.invalidPackage }
                        var total = 0
                        for name in names {
                            let bytes = contents[name]!
                            total += bytes.count
                            guard bytes.count <= 8 * 1024 * 1024, total <= 32 * 1024 * 1024, !name.hasSuffix(".py") || !bytes.contains(0) else { throw ReqGramPluginError.invalidPackage }
                            let target = directory.appendingPathComponent(name)
                            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try bytes.write(to: target, options: .withoutOverwriting)
                        }
                        try FileManager.default.removeItem(at: archive)
                    } catch { try? FileManager.default.removeItem(at: directory); throw error }
                    self.modules[id] = module; self.directories[id] = directory
                } else {
                    guard let m = self.modules[id], let d = self.directories[id] else { throw ReqGramPluginError.runtimeUnavailable }
                    module = m; directory = d
                }
                self.statuses[id] = enabled ? "Starting" : "Stopping"
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
                // Accessed only on Self.queue. An exit is permitted exactly once
                // for an admitted turn, never as a retry that erases failed recovery evidence.
                var boundaryEntered = false
                executor.execute(module: module, directory: directory, start: enabled, host: { operation, bytes in
                    Self.queue.sync {
                        do {
                            guard self.modules[id] == module else { throw ReqGramPluginError.runtimeUnavailable }
                            var state = try self.read()
                            let permissions = installation.record.manifest.permissions
                             let fullAccess = permissions.contains("full_access")
                             if let rule = Self.authorizationRules[operation] {
                                 // Safe mode gates every authorization row, including host.
                                  guard state.developerMode && !state.safeMode && (self.statuses[id] == "Starting" || self.statuses[id] == "Running") else { return ["error": "session_inactive"] }
                                 guard !rule.unsupported else { return ["error": "unsupported_operation"] }
                                 let capabilities = installation.record.manifest.capabilities ?? []
                                 let permitted = rule.baselineAllowed ||
                                     (rule.fullAccessAllowed && fullAccess) ||
                                     (rule.permission.map { permissions.contains($0) } ?? false) ||
                                     (rule.capability.map { capabilities.contains($0) } ?? false)
                                 guard permitted else { return ["error": "permission_denied"] }
                                 return operation == "authorize.messages" ? ["plugin_id": id] : [:]
                             }
                             switch operation {
                             case "settings":
                                  guard state.developerMode && !state.safeMode else { return ["error": "session_inactive"] }
                                 guard bytes == nil else { throw ReqGramPluginError.invalidPackage }
                                return ["data": try JSONEncoder().encode(self.settings(id, state: state))]
                             case "load":
                                  guard state.developerMode && !state.safeMode else { return ["error": "session_inactive"] }
                                  guard fullAccess || permissions.contains("storage") else { throw ReqGramPluginError.invalidPackage }
                                return state.data[id].map { ["data": $0] } ?? [:]
                             case "save":
                                  guard state.developerMode && !state.safeMode else { return ["error": "session_inactive"] }
                                  guard fullAccess || permissions.contains("storage"), let bytes = bytes, bytes.count <= 65536 else { throw ReqGramPluginError.invalidPackage }
                                state.data[id] = bytes
                             case "log":
                                  guard state.developerMode && !state.safeMode else { return ["error": "session_inactive"] }
                                  guard fullAccess || permissions.contains("log"), let bytes = bytes, bytes.count <= 4096, let text = String(data: bytes, encoding: .utf8) else { throw ReqGramPluginError.invalidPackage }
                                state.logs.append(Log(date: self.date(), id: id, message: text))
                                NSLog("[ReqGramPlugin %@] %@", id, text)
                             default: return ["error": "unsupported_operation"]
                            }
                            if state.logs.count > 1000 { state.logs.removeFirst(state.logs.count - 1000) }
                            self.prune(&state); try self.write(state); return [:]
                        } catch { return ["error": error.localizedDescription] }
                    }
                }, boundary: { entering in
                    Self.queue.sync {
                        let wasEntered = boundaryEntered
                        if !entering { boundaryEntered = false }
                        do {
                            var state = try self.read()
                            if entering {
                                guard !boundaryEntered, state.executing == nil,
                                      self.modules[id] == module,
                                      !(enabled && state.safeMode) else { return false }
                                state.executing = id
                                try self.write(state)
                                boundaryEntered = true
                            } else {
                                guard wasEntered else { return false }
                                guard state.executing == id else { return false }
                                state.executing = nil
                                try self.write(state)
                            }
                            return true
                        } catch { return false }
                    }
                }, completion: { error in
                    Self.queue.async {
                        var finalError = error
                        self.statuses[id] = error.map { "Failed: \($0.localizedDescription)" } ?? (enabled ? "Running" : "Stopped")
                        if error != nil || !enabled {
                            self.modules.removeValue(forKey: id); self.directories.removeValue(forKey: id)
                            try? FileManager.default.removeItem(at: directory)
                        }
                        do {
                            var state = try self.read()
                            state.installations[id]?.record.quarantineReason = error?.localizedDescription
                            state.logs.append(Log(date: self.date(), id: id, message: self.statuses[id]!))
                            self.prune(&state); try self.write(state)
                        } catch { finalError = error }
                        let result = finalError
                        DispatchQueue.main.async { completion(result) }
                    }
                })
            } catch { DispatchQueue.main.async { completion(error) } }
        }
    }
    public func logs(for id: String) throws -> [String] {
        try Self.queue.sync { var s = try read(); guard s.developerMode else { throw ReqGramPluginError.developerModeRequired }; prune(&s); try write(s); return s.logs.filter { $0.id == id }.map { "\($0.date): \($0.message)" } }
    }
}
