import Foundation

/// Native-only capability registry. Menu enumeration never supplies message data.
public final class ReqGramMessageActions {
    public static let shared = ReqGramMessageActions()
    public struct Scope: Equatable {
        public let account: String
        fileprivate let generation: UUID
    }
    public struct Action {
        public let title: String
        fileprivate let token: UUID
    }
    private struct Entry {
        let owner: UUID
        let scope: Scope
        let id: String
        let title: String
        let deliver: ([String: String], UUID) -> Void
    }
    private let lock = NSLock()
    private var scope: Scope?
    private var entries: [UUID: Entry] = [:]
    public init() {}
    public func setAccount(_ account: String?) {
        lock.lock(); defer { lock.unlock() }
        guard scope?.account != account else { return }
        scope = account.map { Scope(account: $0, generation: UUID()) }
        entries.removeAll()
    }
    public func currentScope() -> Scope? {
        lock.lock(); defer { lock.unlock() }; return scope
    }
    /// Revoke existing sessions without changing the selected account. Old scopes
    /// stay invalid even after safe mode is disabled; a new session is required.
    /// Never calls session or manager code while holding the registry lock.
    public func revoke() {
        lock.lock(); defer { lock.unlock() }
        scope = scope.map { Scope(account: $0.account, generation: UUID()) }
        entries.removeAll()
    }
    public func isCurrent(_ value: Scope?) -> Bool {
        lock.lock(); defer { lock.unlock() }; return value != nil && scope == value
    }
    public func register(owner: UUID, scope: Scope?, plugin: String, bytes: Data?, deliver: @escaping ([String: String], UUID) -> Void) -> String? {
        guard plugin.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._-]{0,126}\\z", options: .regularExpression) != nil,
              let bytes, bytes.count <= 512,
              let object = try? JSONDecoder().decode([String: String].self, from: bytes),
              Set(object.keys) == ["id", "label"], let id = object["id"], let label = object["label"],
              Self.validID(id), !label.isEmpty, label.utf8.count <= 64,
              label == label.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.illegalCharacters.contains($0) || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) else { return "invalid_payload" }
        lock.lock(); defer { lock.unlock() }
        guard let scope, self.scope == scope else { return "account_context_unavailable" }
        let owned = entries.values.filter { $0.owner == owner }
        guard !owned.contains(where: { $0.id == id }) else { return "duplicate_action" }
        guard owned.count < 2, entries.count < 8 else { return "action_limit" }
        entries[UUID()] = Entry(owner: owner, scope: scope, id: id, title: "Plugin [\(plugin)]: \(label)", deliver: deliver)
        return nil
    }
    private static func validID(_ id: String) -> Bool {
        id.range(of: "\\A[A-Za-z][A-Za-z0-9_]{0,31}\\z", options: .regularExpression) != nil
    }
    /// Check while holding the owning session lock, so unregister/close cannot
    /// race an already captured delivery into that session's queue.
    public func isRegistered(_ token: UUID, owner: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[token] else { return false }
        return entry.owner == owner && entry.scope == scope
    }
    public func unregister(owner: UUID, bytes: Data?) -> String? {
        guard let bytes, bytes.count <= 128, let object = try? JSONDecoder().decode([String: String].self, from: bytes),
              Set(object.keys) == ["id"], let id = object["id"], Self.validID(id) else { return "invalid_payload" }
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { !($0.value.owner == owner && $0.value.id == id) }
        return nil
    }
    public func remove(owner: UUID) {
        lock.lock(); defer { lock.unlock() }; entries = entries.filter { $0.value.owner != owner }
    }
    public func actions(account: String) -> [Action] {
        lock.lock(); defer { lock.unlock() }
        guard scope?.account == account else { return [] }
        return entries.map { Action(title: $0.value.title, token: $0.key) }.sorted { $0.title < $1.title }
    }
    /// Called only by the native selected-message menu after its policy checks.
    public func tap(_ action: Action, account: String, peer: String, namespace: String, message: String, text: String) {
        lock.lock()
        guard let entry = entries[action.token], entry.scope == scope, entry.scope.account == account else { lock.unlock(); return }
        lock.unlock()
        // Unicode-scalar prefix, at most 4096 UTF-8 bytes. No media, peers or credentials.
        var selected = "", size = 0
        for scalar in text.unicodeScalars {
            let part = String(scalar)
            guard size + part.utf8.count <= 4096 else { break }
            selected += part; size += part.utf8.count
        }
        let event = ["event": "message.action", "action_id": entry.id, "account_id": account,
                     "peer_id": peer, "message_namespace": namespace, "message_id": message,
                     "text": selected, "text_truncated": selected == text ? "false" : "true"]
        guard let bytes = try? JSONSerialization.data(withJSONObject: event), bytes.count <= 32768 else { return }
        entry.deliver(event, action.token)
    }
}
