import Foundation
import Postbox
import SGLogging

/// MARK: AyuGram
/// Carries the "keep locally" choice from the delete confirmation sheet down to
/// the deletion hook in TelegramCore.
///
/// The UI registers the intent immediately before committing an explicitly
/// user-initiated delete, and the deletion hook consumes the matching entry.
///
/// Safety properties that make this narrow rather than a general global:
/// * The intent is scoped to an account and a specific set of message ids, so
///   an unrelated concurrent deletion cannot accidentally consume it.
/// * It is single-use: consuming clears it.
/// * It expires, so a registration whose delete never happened cannot leak into
///   a much later, unrelated deletion.
public enum AyuDeleteIntent {
    /// How long a registered intent stays valid. Deletion follows registration
    /// within the same runloop turn in practice; this is only a safety net.
    private static let validity: TimeInterval = 5.0

    private static let lock = NSLock()
    private struct Pending {
        let token: UUID
        let accountPeerId: PeerId
        let ids: Set<MessageId>
        let registeredAt: TimeInterval
    }
    private static var pending: [Pending] = []

    /// Records that the given messages should keep their archived copies.
    @discardableResult
    public static func registerKeepLocally(accountPeerId: PeerId, ids: [MessageId]) -> UUID? {
        let ids = Set(ids)
        guard !ids.isEmpty else { return nil }
        let token = UUID()
        AyuDeleteIntent.lock.lock()
        let now = Date().timeIntervalSince1970
        AyuDeleteIntent.pending.removeAll { now - $0.registeredAt > AyuDeleteIntent.validity }
        AyuDeleteIntent.pending.append(Pending(token: token, accountPeerId: accountPeerId, ids: ids, registeredAt: now))
        AyuDeleteIntent.lock.unlock()
        SGLogger.shared.log("AyuGram", "DeleteIntent: keep locally registered for \(ids.count) message(s)")
        return token
    }

    /// Clears any pending intent. Called when the user cancels the sheet.
    public static func clear(token: UUID) {
        AyuDeleteIntent.lock.lock()
        AyuDeleteIntent.pending.removeAll { $0.token == token }
        AyuDeleteIntent.lock.unlock()
    }

    /// Pure selection policy kept separate from locking/storage so fixtures can
    /// verify ambiguity behavior. Registration order is preserved: duplicate
    /// exact matches deterministically consume the oldest one. A broader
    /// deletion may match a selected album subset only when that match is
    /// unique; ambiguity must preserve nothing rather than the wrong intent.
    static func selectionIndex(pendingIdSets: [Set<MessageId>], deletedIds: Set<MessageId>) -> Int? {
        guard !deletedIds.isEmpty else { return nil }
        if let exactIndex = pendingIdSets.firstIndex(of: deletedIds) {
            return exactIndex
        }
        let subsetIndices = pendingIdSets.indices.filter { pendingIdSets[$0].isSubset(of: deletedIds) }
        return subsetIndices.count == 1 ? subsetIndices[0] : nil
    }

    /// Returns exactly the originally selected IDs to preserve. `ids` may be a
    /// superset after Telegram expands an album/group; expansion is deletion
    /// behavior and must not silently broaden the user's keep-local choice.
    static func consumeKeepLocally(accountPeerId: PeerId, ids: [MessageId]) -> Set<MessageId> {
        AyuDeleteIntent.lock.lock()
        defer { AyuDeleteIntent.lock.unlock() }
        let now = Date().timeIntervalSince1970
        AyuDeleteIntent.pending.removeAll { now - $0.registeredAt > AyuDeleteIntent.validity }
        let accountIndices = AyuDeleteIntent.pending.indices.filter {
            AyuDeleteIntent.pending[$0].accountPeerId == accountPeerId
        }
        let deletedIds = Set(ids)
        let accountIdSets = accountIndices.map { AyuDeleteIntent.pending[$0].ids }
        guard let accountIndex = selectionIndex(pendingIdSets: accountIdSets, deletedIds: deletedIds) else { return [] }
        let index = accountIndices[accountIndex]
        return AyuDeleteIntent.pending.remove(at: index).ids
    }
}
