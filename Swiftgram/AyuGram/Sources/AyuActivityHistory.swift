import Foundation

/// A local, non-invasive observation of Telegram's already-published peer
/// status. This is not a read-receipt bypass: callers must pass data that the
/// normal Telegram UI has received. No message contents are retained.
public struct AyuActivityObservation: Codable, Equatable {
    public enum Kind: String, Codable {
        case presence
        case readDate
    }

    public let accountId: Int64
    public let peerId: Int64
    public let kind: Kind
    public let observedAt: Int64
    public let activityAt: Int64?
    public let state: String?

    public init(accountId: Int64, peerId: Int64, kind: Kind, observedAt: Int64 = Int64(Date().timeIntervalSince1970), activityAt: Int64? = nil, state: String? = nil) {
        self.accountId = accountId
        self.peerId = peerId
        self.kind = kind
        self.observedAt = observedAt
        self.activityAt = activityAt
        self.state = state
    }
}

/// Bounded JSON persistence for AyuGram's local Spy/read-date/last-seen
/// history. "Spy" here means history of observations visible to this client;
/// it does not attempt to infer or alter server state.
public final class AyuActivityHistory {
    public static let shared = AyuActivityHistory()
    public static let maxObservations = 2_000

    private let queue = DispatchQueue(label: "app.swiftgram.ayugram.activity-history", qos: .utility)
    private var loaded = false
    private var observations: [AyuActivityObservation] = []

    private init() {}

    public func recordPresence(accountId: Int64, peerId: Int64, activityAt: Int64?, state: String?, observedAt: Int64 = Int64(Date().timeIntervalSince1970)) {
        record(AyuActivityObservation(accountId: accountId, peerId: peerId, kind: .presence, observedAt: observedAt, activityAt: activityAt, state: state))
    }

    /// Available for a future read-state hook. It is intentionally explicit:
    /// callers must provide a read date from Telegram's normal read-state
    /// signal, rather than deriving one from UI visibility.
    public func recordReadDate(accountId: Int64, peerId: Int64, readDate: Int64, observedAt: Int64 = Int64(Date().timeIntervalSince1970)) {
        record(AyuActivityObservation(accountId: accountId, peerId: peerId, kind: .readDate, observedAt: observedAt, activityAt: readDate, state: nil))
    }

    public func observations(accountId: Int64, peerId: Int64, kind: AyuActivityObservation.Kind? = nil) -> [AyuActivityObservation] {
        queue.sync {
            loadIfNeeded()
            return observations.filter { $0.accountId == accountId && $0.peerId == peerId && (kind == nil || $0.kind == kind) }
        }
    }

    public func allObservations(accountId: Int64) -> [AyuActivityObservation] {
        queue.sync {
            loadIfNeeded()
            return observations.filter { $0.accountId == accountId }
        }
    }

    public func removeAll(accountId: Int64? = nil) {
        queue.sync {
            loadIfNeeded()
            if let accountId {
                observations.removeAll { $0.accountId == accountId }
            } else {
                observations.removeAll()
            }
            save()
        }
    }

    private func record(_ observation: AyuActivityObservation) {
        guard observation.accountId != 0, observation.peerId != 0 else { return }
        queue.async {
            self.loadIfNeeded()
            // Coalesce identical renders; title nodes can refresh frequently.
            if let index = self.observations.lastIndex(where: {
                $0.accountId == observation.accountId && $0.peerId == observation.peerId && $0.kind == observation.kind && $0.activityAt == observation.activityAt && $0.state == observation.state
            }) {
                self.observations[index] = observation
            } else {
                self.observations.append(observation)
            }
            if self.observations.count > Self.maxObservations {
                self.observations.removeFirst(self.observations.count - Self.maxObservations)
            }
            self.save()
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let values = try? AyuStorage.activityHistoryPathURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 512 * 1024,
              let data = try? Data(contentsOf: AyuStorage.activityHistoryPathURL),
              let decoded = try? JSONDecoder().decode([AyuActivityObservation].self, from: data) else { return }
        observations = Array(decoded.suffix(Self.maxObservations))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(observations) else { return }
        try? data.write(to: AyuStorage.activityHistoryURL, options: [.atomic])
    }
}
