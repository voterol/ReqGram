import Foundation
import SGLogging

public struct AyuCustomBadge: Codable, Equatable {
    public let documentId: Int64
    public let text: String?

    public init(documentId: Int64, text: String?) {
        self.documentId = documentId
        self.text = text
    }
}

public enum AyuBadgeKind: Equatable {
    case custom(AyuCustomBadge)
    case owner
    case official
    case team
    case developer
    case sponsor
    case supporter
}

public enum AyuBadgeSource: String, Codable, CaseIterable, Equatable, Hashable {
    case reqGram
    case ayuGram
    case exteraGram
}

public enum AyuBadgePeerType: String, Codable, Equatable, Hashable {
    case user
    case group
    case channel
}

public struct AyuBadgePeer: Codable, Equatable, Hashable {
    public let type: AyuBadgePeerType
    public let id: Int64

    public init(type: AyuBadgePeerType, id: Int64) {
        self.type = type
        self.id = id
    }
}

/// A validated grant. `source` and `assignmentId` together are its stable
/// identity; document ids are deliberately not used for cross-source deduping.
public struct AyuRemoteBadge: Equatable {
    public let source: AyuBadgeSource
    public let assignmentId: String
    public let peer: AyuBadgePeer
    public let kind: AyuBadgeKind
    public let documentId: Int64?
    public let title: String?
    public let text: String?
}

/// Retained for source compatibility with callers which inspect the old compact
/// AyuGram payload. Aggregate resolution uses namespace-qualified grants below.
public struct AyuRemoteConfigPayload: Codable, Equatable {
    public var developers: Set<Int64>
    public var officialChannels: Set<Int64>
    public var supporters: Set<Int64>
    public var supporterChannels: Set<Int64>
    public var customBadges: [Int64: AyuCustomBadge]

    public static let empty = AyuRemoteConfigPayload(developers: [], officialChannels: [], supporters: [], supporterChannels: [], customBadges: [:])

    public init(developers: Set<Int64>, officialChannels: Set<Int64>, supporters: Set<Int64>, supporterChannels: Set<Int64>, customBadges: [Int64: AyuCustomBadge]) {
        self.developers = developers
        self.officialChannels = officialChannels
        self.supporters = supporters
        self.supporterChannels = supporterChannels
        self.customBadges = customBadges
    }

    public var isEmpty: Bool {
        return developers.isEmpty && officialChannels.isEmpty && supporters.isEmpty && supporterChannels.isEmpty && customBadges.isEmpty
    }
}

private struct CachedGrant: Codable {
    let source: AyuBadgeSource
    let assignmentId: String
    let peer: AyuBadgePeer
    let kind: String
    let documentId: Int64?
    let title: String?
    let text: String?
}

private struct SourceCache: Codable {
    let fetchedAt: TimeInterval
    let revision: Int64?
    let expiresAt: TimeInterval?
    let grants: [CachedGrant]
}

private final class BoundedDataDelegate: NSObject, URLSessionDataDelegate {
    private let limit: Int
    private let completion: (Data?, URLResponse?, Error?) -> Void
    private var data = Data()
    private var response: URLResponse?
    private var exceededLimit = false

    init(limit: Int, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        self.limit = limit
        self.completion = completion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        if response.expectedContentLength > Int64(self.limit) {
            self.exceededLimit = true
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !self.exceededLimit else { return }
        guard self.data.count <= self.limit - data.count else {
            self.exceededLimit = true
            dataTask.cancel()
            return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.completion(self.exceededLimit ? nil : self.data, self.response, error)
    }
}

public final class AyuRemoteConfig {
    public static let shared = AyuRemoteConfig()

    public final class Observation {
        private let disposeImpl: () -> Void
        private var disposed = false
        fileprivate init(_ disposeImpl: @escaping () -> Void) { self.disposeImpl = disposeImpl }
        deinit { dispose() }
        public func dispose() { guard !disposed else { return }; disposed = true; disposeImpl() }
    }

    private struct SourceDefinition {
        let id: AyuBadgeSource
        let endpoint: URL?
        let reqGramShape: Bool
    }

    private static let sources = [
        SourceDefinition(id: .reqGram, endpoint: ReqGramBadgeConfiguration.endpoint, reqGramShape: true),
        SourceDefinition(id: .ayuGram, endpoint: URL(string: "https://update.ayugram.one/rc/current/desktop2"), reqGramShape: false),
        SourceDefinition(id: .exteraGram, endpoint: URL(string: "https://api.exteragram.app/api/v1/profiles/compact"), reqGramShape: false)
    ]
    private static let refreshInterval: TimeInterval = 60 * 60
    private static let maximumCacheAge: TimeInterval = 7 * 24 * 60 * 60
    private static let requestTimeout: TimeInterval = 15
    static let maxResponseBytes = 1024 * 1024
    private static let maximumBadgesPerSource = 10_000
    private static let maximumBadgesPerPeer = 16
    private static let maximumTextBytes = 1024
    private static let maximumTextCharacters = 160
    private static let cachePrefix = "ReqGram.Badges.Cache.v1."

    private let queue = DispatchQueue(label: "app.reqgram.badges", qos: .utility)
    private let lock = NSLock()
    private var grantsBySource: [AyuBadgeSource: [AyuRemoteBadge]] = [:]
    private var fetchDates: [AyuBadgeSource: TimeInterval] = [:]
    private var expiryDates: [AyuBadgeSource: TimeInterval] = [:]
    private var loaded = false
    private var refreshing = false
    private var revisionStorage: UInt64 = 0
    private var observations: [UUID: (UInt64) -> Void] = [:]

    private init() { queue.async { [weak self] in self?.loadCaches() } }

    public var revision: UInt64 { dispatchPrecondition(condition: .onQueue(.main)); return revisionStorage }

    public var payload: AyuRemoteConfigPayload {
        let grants = snapshot()[.ayuGram] ?? []
        var value = AyuRemoteConfigPayload.empty
        for grant in grants {
            switch (grant.peer.type, grant.kind) {
            case (.user, .developer): value.developers.insert(grant.peer.id)
            case (.channel, .official), (.channel, .developer): value.officialChannels.insert(grant.peer.id)
            case (.user, .supporter): value.supporters.insert(grant.peer.id)
            case (.channel, .supporter): value.supporterChannels.insert(grant.peer.id)
            case (_, .custom(let custom)): value.customBadges[grant.peer.id] = custom
            default: break
            }
        }
        return value
    }

    public func observe(_ callback: @escaping (UInt64) -> Void) -> Observation {
        dispatchPrecondition(condition: .onQueue(.main))
        let id = UUID(); observations[id] = callback; callback(revisionStorage)
        return Observation { [weak self] in
            let remove: () -> Void = {
                self?.observations.removeValue(forKey: id)
            }
            if Thread.isMainThread { remove() } else { DispatchQueue.main.async(execute: remove) }
        }
    }

    /// Compatibility no-op: mandatory authorities are not controlled by the
    /// legacy appearance setting.
    public func enabledStateDidChange() { startIfNeeded() }

    public func startIfNeeded() {
        queue.async { [weak self] in
            guard let self else { return }
            self.loadCaches()
            let now = Date().timeIntervalSince1970
            if Self.sources.contains(where: { source in
                source.endpoint != nil && (self.fetchDates[source.id].map { now - $0 >= Self.refreshInterval || now < $0 } ?? true)
            }) { self.refreshLocked() }
        }
    }

    public func badges(for peer: AyuBadgePeer) -> [AyuRemoteBadge] {
        var result: [AyuRemoteBadge] = []
        var compatibleFixedRoles = Set<String>()
        let values = snapshot()
        let compatibleSources: Set<AyuBadgeSource> = [.ayuGram, .exteraGram]
        let hasCompatibleCustomBadge = compatibleSources.contains { source in
            return (values[source] ?? []).contains { badge in
                guard badge.peer == peer else { return false }
                if case .custom = badge.kind { return true }
                return false
            }
        }
        for source in AyuBadgeSource.allCases {
            let matching = (values[source] ?? []).filter { $0.peer == peer }.sorted { Self.kindRank($0.kind) < Self.kindRank($1.kind) }
            for badge in matching {
                if hasCompatibleCustomBadge, compatibleSources.contains(source) {
                    switch badge.kind {
                    case .sponsor, .supporter:
                        continue
                    default:
                        break
                    }
                }
                if source == .ayuGram || source == .exteraGram, let role = Self.compatibleFixedRole(badge.kind) {
                    guard compatibleFixedRoles.insert(role).inserted else { continue }
                }
                result.append(badge)
            }
        }
        return Array(result.prefix(Self.maximumBadgesPerPeer))
    }

    /// Legacy bare-id lookup is user-scoped to avoid granting a user badge to a
    /// channel with the same numeric component.
    public func badges(forPeerId peerId: Int64) -> [AyuBadgeKind] { badges(for: AyuBadgePeer(type: .user, id: peerId)).map(\.kind) }
    public func badge(forPeerId peerId: Int64) -> AyuBadgeKind? { badges(forPeerId: peerId).first }

    private func snapshot() -> [AyuBadgeSource: [AyuRemoteBadge]] {
        let now = Date().timeIntervalSince1970
        lock.lock(); defer { lock.unlock() }
        return grantsBySource.filter { source, _ in
            guard let fetchedAt = fetchDates[source], now >= fetchedAt, now - fetchedAt <= Self.maximumCacheAge else { return false }
            return expiryDates[source].map { now <= $0 } ?? true
        }
    }

    private func loadCaches() {
        guard !loaded else { return }; loaded = true
        let now = Date().timeIntervalSince1970
        for source in AyuBadgeSource.allCases {
            guard let data = UserDefaults.standard.data(forKey: Self.cachePrefix + source.rawValue),
                  data.count <= Self.maxResponseBytes,
                  let cache = try? JSONDecoder().decode(SourceCache.self, from: data),
                  now >= cache.fetchedAt,
                  now - cache.fetchedAt <= Self.maximumCacheAge,
                  cache.expiresAt.map({ now <= $0 }) ?? true else { continue }
            let grants: [AyuRemoteBadge] = cache.grants.prefix(Self.maximumBadgesPerSource).compactMap { grant -> AyuRemoteBadge? in
                guard grant.source == source else { return nil }
                return Self.decodeCachedGrant(grant)
            }
            guard !grants.isEmpty || (source == .reqGram && cache.revision != nil && cache.expiresAt != nil) else { continue }
            lock.lock(); grantsBySource[source] = grants; fetchDates[source] = cache.fetchedAt; if let expiry = cache.expiresAt { expiryDates[source] = expiry }; lock.unlock()
        }
        publishRevision()
    }

    private func refreshLocked() {
        guard !refreshing else { return }; refreshing = true
        let active = Self.sources.compactMap { source -> (SourceDefinition, URL)? in
            guard let endpoint = source.endpoint, endpoint.scheme?.lowercased() == "https" else { return nil }
            return (source, endpoint)
        }
        guard !active.isEmpty else { refreshing = false; return }
        let group = DispatchGroup()
        for (source, url) in active {
            group.enter(); fetch(source: source, url: url) { _ in group.leave() }
        }
        group.notify(queue: queue) { [weak self] in self?.refreshing = false }
    }

    private func fetch(source: SourceDefinition, url: URL, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url); request.httpMethod = "GET"; request.timeoutInterval = Self.requestTimeout; request.cachePolicy = .reloadIgnoringLocalCacheData
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = Self.requestTimeout; config.timeoutIntervalForResource = Self.requestTimeout
        var session: URLSession!
        let delegate = BoundedDataDelegate(limit: Self.maxResponseBytes) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            self?.queue.async {
                guard let self,
                      error == nil,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      http.expectedContentLength <= Int64(Self.maxResponseBytes),
                      let data, !data.isEmpty, data.count <= Self.maxResponseBytes,
                       let parsed = source.reqGramShape ? Self.parseReqGram(data, source: source.id) : Self.parseCompact(data, source: source.id),
                       !parsed.grants.isEmpty || (source.id == .reqGram && parsed.revision != nil && parsed.expiresAt != nil) else {
                    SGLogger.shared.log("AyuGram", "Badge source \(source.id.rawValue) failed; retaining its cache")
                    completion(false); return
                }
                self.store(source: source.id, parsed: parsed); completion(true)
            }
        }
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: request).resume()
    }

    typealias Parsed = (grants: [AyuRemoteBadge], revision: Int64?, expiresAt: TimeInterval?)

    static func parseCompact(_ data: Data, source: AyuBadgeSource) -> Parsed? {
        guard source != .reqGram, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var result: [AyuRemoteBadge] = []
        func addIds(_ key: String, type: AyuBadgePeerType, kind: AyuBadgeKind) {
            guard let array = object[key] as? [Any] else { return }
            for value in array.prefix(maximumBadgesPerSource) { guard let id = positiveId(value) else { continue }; result.append(makeBadge(source, "\(key):\(id)", AyuBadgePeer(type: type, id: id), kind, nil, nil, nil)) }
        }
        addIds("developers", type: .user, kind: .developer)
        addIds("officialChannels", type: .channel, kind: .official)
        addIds("supporters", type: .user, kind: .supporter)
        addIds("supporterChannels", type: .channel, kind: .supporter)
        if let array = object["customBadges"] as? [Any] {
            for value in array.prefix(maximumBadgesPerSource) {
                guard let entry = value as? [String: Any], let id = positiveId(entry["id"]), let badge = entry["badge"] as? [String: Any], let documentId = positiveId(badge["documentId"]) else { continue }
                let text = sanitizeText(badge["text"] as? String)
                let custom = AyuCustomBadge(documentId: documentId, text: text)
                // Existing compact custom badges have historically been user-scoped.
                result.append(makeBadge(source, "custom:\(id):\(documentId)", AyuBadgePeer(type: .user, id: id), .custom(custom), documentId, nil, text))
            }
        }
        return (Array(result.prefix(maximumBadgesPerSource)), nil, nil)
    }

    static func parseReqGram(_ data: Data, source: AyuBadgeSource = .reqGram) -> Parsed? {
        guard source == .reqGram, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], positiveId(object["schemaVersion"]) == 1, let array = object["badges"] as? [Any] else { return nil }
        let revision = positiveId(object["revision"])
        let expiresAt = positiveId(object["expiresAt"]).map(TimeInterval.init)
        var result: [AyuRemoteBadge] = []
        for value in array.prefix(maximumBadgesPerSource) {
            guard let entry = value as? [String: Any], let stableId = sanitizeIdentity(entry["id"] as? String),
                  let peerObject = entry["peer"] as? [String: Any], let typeRaw = peerObject["type"] as? String,
                  let type = AyuBadgePeerType(rawValue: typeRaw), let peerId = positiveId(peerObject["id"]),
                  let kindRaw = entry["kind"] as? String else { continue }
            let documentId = positiveId(entry["documentId"])
            let title = sanitizeText(entry["title"] as? String); let text = sanitizeText(entry["text"] as? String)
            guard let kind = reqKind(kindRaw, customDocumentId: documentId, text: text) else { continue }
            let resolvedDocumentId = documentId ?? configuredDocumentId(for: kind)
            result.append(makeBadge(source, stableId, AyuBadgePeer(type: type, id: peerId), kind, resolvedDocumentId, title, text))
        }
        return (result, revision, expiresAt)
    }

    /// Compatibility parser for focused tests and old internal callers.
    static func parse(_ data: Data) -> AyuRemoteConfigPayload? {
        guard let parsed = parseCompact(data, source: .ayuGram) else { return nil }
        var payload = AyuRemoteConfigPayload.empty
        for grant in parsed.grants {
            switch (grant.peer.type, grant.kind) {
            case (.user, .developer): payload.developers.insert(grant.peer.id)
            case (.channel, .official): payload.officialChannels.insert(grant.peer.id)
            case (.user, .supporter): payload.supporters.insert(grant.peer.id)
            case (.channel, .supporter): payload.supporterChannels.insert(grant.peer.id)
            case (.user, .custom(let badge)): payload.customBadges[grant.peer.id] = badge
            default: break
            }
        }
        return payload
    }

    static func sanitizeBadgeText(_ raw: String) -> String? { sanitizeText(raw) }

    private func store(source: AyuBadgeSource, parsed: Parsed) {
        let now = Date().timeIntervalSince1970
        var seen = Set<String>()
        let grants = Array(parsed.grants.filter { seen.insert($0.assignmentId).inserted }.prefix(Self.maximumBadgesPerSource))
        guard !grants.isEmpty || (source == .reqGram && parsed.revision != nil && parsed.expiresAt != nil) else { return }
        lock.lock(); grantsBySource[source] = grants; fetchDates[source] = now; if let expiry = parsed.expiresAt { expiryDates[source] = expiry } else { expiryDates.removeValue(forKey: source) }; lock.unlock()
        let cache = SourceCache(fetchedAt: now, revision: parsed.revision, expiresAt: parsed.expiresAt, grants: grants.map(Self.encodeCachedGrant))
        if let data = try? JSONEncoder().encode(cache), data.count <= Self.maxResponseBytes { UserDefaults.standard.set(data, forKey: Self.cachePrefix + source.rawValue) }
        publishRevision()
    }

    private func publishRevision() {
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.revisionStorage &+= 1; let value = self.revisionStorage; self.observations.values.forEach { $0(value) } }
    }

    private static func positiveId(_ value: Any?) -> Int64? {
        if let string = value as? String { guard !string.isEmpty, string.first != "0", string.utf8.allSatisfy({ (48...57).contains($0) }), let id = Int64(string), id > 0 else { return nil }; return id }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), !CFNumberIsFloatType(number) else { return nil }
            // JSONSerialization preserves integer tokens as integer NSNumber
            // storage. Parse its decimal representation directly so IDs above
            // 2^53 never pass through Double. Reject floating storage entirely,
            // including values such as 1.0, rather than normalizing fractions.
            let decimal = number.stringValue
            guard !decimal.isEmpty, decimal.first != "0", decimal.utf8.allSatisfy({ (48...57).contains($0) }), let id = Int64(decimal), id > 0 else { return nil }
            return id
        }
        return nil
    }

    private static func sanitizeIdentity(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= 128, !raw.isEmpty, raw.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)) }) else { return nil }; return raw
    }

    private static func sanitizeText(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= maximumTextBytes else { return nil }
        let clean = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format && !CharacterSet.newlines.contains($0) }))
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        guard !clean.isEmpty else { return nil }; return String(clean.prefix(maximumTextCharacters))
    }

    private static func reqKind(_ raw: String, customDocumentId: Int64? = nil, text: String? = nil) -> AyuBadgeKind? {
        switch raw { case "owner": return .owner; case "official": return .official; case "team": return .team; case "developer": return .developer; case "sponsor": return .sponsor; case "supporter": return .supporter; case "custom": guard let customDocumentId else { return nil }; return .custom(AyuCustomBadge(documentId: customDocumentId, text: text)); default: return nil }
    }

    private static func kindRank(_ kind: AyuBadgeKind) -> Int {
        switch kind { case .owner: return 0; case .official: return 1; case .team, .developer: return 2; case .sponsor, .supporter: return 3; case .custom: return 4 }
    }

    private static func compatibleFixedRole(_ kind: AyuBadgeKind) -> String? {
        switch kind {
        case .owner: return "owner"
        case .official: return "official"
        case .team, .developer: return "team"
        case .sponsor, .supporter: return "supporter"
        case .custom: return nil
        }
    }

    private static func configuredDocumentId(for kind: AyuBadgeKind) -> Int64? {
        switch kind {
        case .owner: return ReqGramBadgeConfiguration.ownerDocumentId
        case .official: return ReqGramBadgeConfiguration.officialDocumentId
        case .team: return ReqGramBadgeConfiguration.teamDocumentId
        case .developer: return ReqGramBadgeConfiguration.developerDocumentId
        case .sponsor: return ReqGramBadgeConfiguration.sponsorDocumentId
        case .supporter: return ReqGramBadgeConfiguration.supporterDocumentId
        case let .custom(custom): return custom.documentId
        }
    }

    private static func makeBadge(_ source: AyuBadgeSource, _ id: String, _ peer: AyuBadgePeer, _ kind: AyuBadgeKind, _ documentId: Int64?, _ title: String?, _ text: String?) -> AyuRemoteBadge {
        let resolvedDocumentId: Int64?
        if source == .ayuGram || source == .exteraGram {
            switch kind {
            case .custom: resolvedDocumentId = documentId
            case .sponsor, .supporter: resolvedDocumentId = 5391059537102927631
            case .owner, .official, .team, .developer: resolvedDocumentId = 5390820689676633124
            }
        } else {
            resolvedDocumentId = documentId
        }
        return AyuRemoteBadge(source: source, assignmentId: id, peer: peer, kind: kind, documentId: resolvedDocumentId, title: title, text: text)
    }

    private static func encodeCachedGrant(_ grant: AyuRemoteBadge) -> CachedGrant {
        let kind: String
        switch grant.kind { case .owner: kind = "owner"; case .official: kind = "official"; case .team: kind = "team"; case .developer: kind = "developer"; case .sponsor: kind = "sponsor"; case .supporter: kind = "supporter"; case .custom: kind = "custom" }
        return CachedGrant(source: grant.source, assignmentId: grant.assignmentId, peer: grant.peer, kind: kind, documentId: grant.documentId, title: grant.title, text: grant.text)
    }

    private static func decodeCachedGrant(_ value: CachedGrant) -> AyuRemoteBadge? {
        guard value.peer.id > 0, let id = sanitizeIdentity(value.assignmentId) else { return nil }
        let base: AyuBadgeKind
        if value.kind == "custom" { guard let document = value.documentId, document > 0 else { return nil }; base = .custom(AyuCustomBadge(documentId: document, text: sanitizeText(value.text))) }
        else { guard let parsed = reqKind(value.kind) else { return nil }; base = parsed }
        return makeBadge(value.source, id, value.peer, base, value.documentId, sanitizeText(value.title), sanitizeText(value.text))
    }
}
