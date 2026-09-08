import Foundation
import SGLogging
import SGSimpleSettings

/// A user-defined regex filter that hides matching messages.
public struct AyuRegexFilter: Codable, Equatable {
    public let id: String
    public var text: String
    public var enabled: Bool
    /// Invert the match: hide everything that does *not* match.
    public var reversed: Bool
    public var caseInsensitive: Bool
    /// `nil` means the filter applies to every dialog.
    public var peerId: Int64?

    public init(
        id: String = UUID().uuidString,
        text: String,
        enabled: Bool = true,
        reversed: Bool = false,
        caseInsensitive: Bool = true,
        peerId: Int64? = nil
    ) {
        self.id = id
        self.text = text
        self.enabled = enabled
        self.reversed = reversed
        self.caseInsensitive = caseInsensitive
        self.peerId = peerId
    }
}

/// Evaluates AyuGram regex filters against message text.
///
/// Differences from the original Android/desktop implementations, on purpose:
/// * Patterns are compiled defensively. A pattern that `NSRegularExpression`
///   rejects is dropped with a log line instead of throwing on every render —
///   filters imported from Android use a different regex dialect, so invalid
///   patterns are expected in practice, not exceptional.
/// * The per-message verdict cache is bounded and is invalidated whenever the
///   filter set changes, so an edited message cannot keep a stale verdict.
public final class AyuFilters {
    public static let shared = AyuFilters()

    /// Upper bound on cached verdicts; oldest entries are dropped wholesale.
    private static let maxCachedVerdicts = 4096
    /// Refuse pathological patterns outright.
    private static let maxPatternLength = 512

    private let lock = NSLock()

    private struct CompiledFilter {
        let regex: NSRegularExpression
        let reversed: Bool
        let peerId: Int64?
    }

    private var compiled: [CompiledFilter] = []
    private var compiledGeneration: Int = -1
    private var generation: Int = 0

    private struct VerdictKey: Hashable {
        let peerId: Int64
        let messageId: Int32
        let text: String
    }

    private var verdicts: [VerdictKey: Bool] = [:]

    /// Peers for which the user chose to reveal filtered messages this session.
    /// Intentionally not persisted, matching upstream behavior.
    private var revealedPeers = Set<Int64>()

    private init() {}

    // MARK: Filter storage

    public var filters: [AyuRegexFilter] {
        get {
            let raw = SGSimpleSettings.shared.ayuRegexFilters
            guard let data = raw.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([AyuRegexFilter].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue), let string = String(data: data, encoding: .utf8) {
                SGSimpleSettings.shared.ayuRegexFilters = string
            }
            self.invalidate()
        }
    }

    public func addFilter(_ filter: AyuRegexFilter) {
        var current = self.filters
        current.append(filter)
        self.filters = current
    }

    public func removeFilter(id: String) {
        self.filters = self.filters.filter { $0.id != id }
    }

    public func updateFilter(_ filter: AyuRegexFilter) {
        self.filters = self.filters.map { $0.id == filter.id ? filter : $0 }
    }

    /// Drops compiled patterns and all cached verdicts.
    public func invalidate() {
        self.lock.lock()
        self.generation &+= 1
        self.verdicts.removeAll(keepingCapacity: false)
        self.lock.unlock()
    }

    // MARK: Shadow bans

    public var shadowBanIds: Set<Int64> {
        get {
            let raw = SGSimpleSettings.shared.ayuShadowBanIds
            guard let data = raw.data(using: .utf8) else { return [] }
            return Set((try? JSONDecoder().decode([Int64].self, from: data)) ?? [])
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue).sorted()),
               let string = String(data: data, encoding: .utf8) {
                SGSimpleSettings.shared.ayuShadowBanIds = string
            }
            self.invalidate()
        }
    }

    public func isShadowBanned(peerId: Int64) -> Bool {
        return self.shadowBanIds.contains(peerId)
    }

    public func setShadowBan(peerId: Int64, banned: Bool) {
        var ids = self.shadowBanIds
        if banned {
            ids.insert(peerId)
        } else {
            ids.remove(peerId)
        }
        self.shadowBanIds = ids
    }

    // MARK: Reveal

    public func isRevealed(peerId: Int64) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.revealedPeers.contains(peerId)
    }

    public func setRevealed(peerId: Int64, revealed: Bool) {
        self.lock.lock()
        if revealed {
            self.revealedPeers.insert(peerId)
        } else {
            self.revealedPeers.remove(peerId)
        }
        self.lock.unlock()
    }

    // MARK: Evaluation

    /// Whether a message should be hidden.
    ///
    /// - Parameters:
    ///   - text: full extracted message text (caption included).
    ///   - peerId: bare id of the dialog.
    ///   - messageId: message id, used only for caching.
    ///   - isOutgoing: own messages are never filtered.
    ///   - isBroadcast: filters apply to channels always, elsewhere only when
    ///     `ayuFiltersInChats` is on.
    public func shouldHide(
        text: String,
        peerId: Int64,
        messageId: Int32,
        isOutgoing: Bool,
        isBroadcast: Bool
    ) -> Bool {
        guard SGSimpleSettings.shared.ayuFiltersEnabled else { return false }
        guard !isOutgoing else { return false }
        if self.isRevealed(peerId: peerId) { return false }
        if !isBroadcast && !SGSimpleSettings.shared.ayuFiltersInChats { return false }
        if self.isShadowBanned(peerId: peerId) { return true }
        let cacheKey = VerdictKey(peerId: peerId, messageId: messageId, text: text)

        self.lock.lock()
        let generationAtRead = self.generation
        if let cached = self.verdicts[cacheKey] {
            self.lock.unlock()
            return cached
        }
        self.rebuildIfNeededLocked()
        let patterns = self.compiled
        self.lock.unlock()

        var hide = false
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        for pattern in patterns {
            if let filterPeerId = pattern.peerId, filterPeerId != peerId {
                continue
            }
            let matched = pattern.regex.firstMatch(in: text, options: [], range: range) != nil
            if matched != pattern.reversed {
                hide = true
                break
            }
        }

        self.lock.lock()
        // Discard the write if the filter set changed while we were evaluating.
        if self.generation == generationAtRead {
            if self.verdicts.count >= AyuFilters.maxCachedVerdicts {
                self.verdicts.removeAll(keepingCapacity: true)
            }
            self.verdicts[cacheKey] = hide
        }
        self.lock.unlock()

        return hide
    }

    /// Validates a pattern for the filter editor UI.
    public static func isValidPattern(_ pattern: String, caseInsensitive: Bool) -> Bool {
        guard !pattern.isEmpty, pattern.count <= AyuFilters.maxPatternLength else { return false }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if caseInsensitive {
            options.insert(.caseInsensitive)
        }
        return (try? NSRegularExpression(pattern: pattern, options: options)) != nil
    }

    private func rebuildIfNeededLocked() {
        guard self.compiledGeneration != self.generation else { return }
        self.compiledGeneration = self.generation

        let globalCaseInsensitive = SGSimpleSettings.shared.ayuFiltersCaseInsensitive
        var result: [CompiledFilter] = []
        for filter in self.filters where filter.enabled {
            let pattern = filter.text
            guard !pattern.isEmpty, pattern.count <= AyuFilters.maxPatternLength else { continue }
            var options: NSRegularExpression.Options = [.anchorsMatchLines]
            if filter.caseInsensitive || globalCaseInsensitive {
                options.insert(.caseInsensitive)
            }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                // Expected for patterns authored against Java's regex dialect.
                SGLogger.shared.log("AyuGram", "Filters: dropping invalid pattern \(filter.id)")
                continue
            }
            result.append(CompiledFilter(regex: regex, reversed: filter.reversed, peerId: filter.peerId))
        }
        self.compiled = result
    }
}
