import Foundation
import os

/// Lightweight diagnostics for the scam registry pipeline. NSLog (rather
/// than bare os_log) so the lines reliably reach the unified log and
/// stderr on both devices and simulators.
func sgScamRegistryLog(_ message: @autoclosure () -> String) {
    NSLog("[SGScamRegistry] %@", message())
}

public extension Notification.Name {
    static let sgScamRegistryDidChange = Notification.Name("sg.scamRegistry.didChange")
    static let sgScamRegistrySettingsDidChange = Notification.Name("sg.scamRegistry.settingsDidChange")
    static let sgScamRegistryRefreshDidFinish = Notification.Name("sg.scamRegistry.refreshDidFinish")
    /// Posted the moment a refresh actually begins (i.e. the re-entrancy guard
    /// was passed and a data source is present) — not posted for calls that get
    /// rejected by `refreshing`/missing-data-source. Lets UI surface a "scanning"
    /// state immediately without polling `isRefreshing()`.
    static let sgScamRegistryRefreshDidStart = Notification.Name("sg.scamRegistry.refreshDidStart")
}

public enum SGScamRegistryRefreshResult: Equatable {
    case updated(count: Int, usedCache: Bool)
    case failed(usedCache: Bool)
    /// The call was vetoed because another refresh is already running — not
    /// an error. Surfaced so UI can show "already in progress" instead of a
    /// misleading failure message.
    case alreadyInProgress
}

/// Resumable position in the source history. The field semantics are
/// source-specific (here: Telegram message ids), but the type itself
/// deliberately carries no Telegram or plugin-runtime types so the boundary
/// between the registry and its data source stays clean.
public struct SGScamRegistryFetchState: Codable, Equatable {
    /// Where the next run should continue fetching from (`0` = restart from
    /// the newest messages).
    public var offsetId: Int32 = 0
    /// Low-water diagnostic mark: oldest source message ever folded into the
    /// local id set.
    public var oldestParsedId: Int32 = 0
    /// High-water mark: newest source message already folded into the local
    /// id set (`0` = no completed traversal yet). Runs descending from the
    /// top stop as soon as they reach it — this is what makes steady-state
    /// refreshes "new posts only" instead of re-walking the whole channel.
    public var newestParsedId: Int32 = 0
    /// Wall clock of the last run that reached the very end of the history.
    public var lastFullSweepAt: TimeInterval = 0

    public init() {}

    /// Tolerant decoding: checkpoints persisted before `newestParsedId`
    /// existed decode with it as `0` (which correctly re-enables the
    /// walk-to-the-end behavior until the next completed traversal).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.offsetId = try container.decodeIfPresent(Int32.self, forKey: .offsetId) ?? 0
        self.oldestParsedId = try container.decodeIfPresent(Int32.self, forKey: .oldestParsedId) ?? 0
        self.newestParsedId = try container.decodeIfPresent(Int32.self, forKey: .newestParsedId) ?? 0
        self.lastFullSweepAt = try container.decodeIfPresent(TimeInterval.self, forKey: .lastFullSweepAt) ?? 0
    }
}

/// One incrementally-collected piece of the registry source. The service
/// merges each chunk into its id set as it arrives, so partial progress
/// survives interruptions and protection improves steadily instead of
/// all-or-nothing after a full sweep.
public struct SGScamRegistryFetchChunk {
    public let texts: [String]
    /// The advanced state to persist for the next run.
    public let state: SGScamRegistryFetchState
    /// `true` when the run stopped because of its page/byte budget — more
    /// history is known to remain.
    public let hasMore: Bool
    /// `true` when the run walked off the end of the source history.
    public let sweptToEnd: Bool
}

/// The source boundary deliberately contains no Telegram or plugin-runtime types.
/// An adapter can use TelegramCore's account context and API, but the registry is
/// disabled and inert until one is explicitly supplied and enabled.
public protocol SGScamRegistryDataSource: AnyObject {
    /// Fetches at most `pageBudget` pages (~100 messages each), pacing the
    /// requests so the source API is never hammered in a burst, starting from
    /// `state`. The completion may be invoked on any background queue.
    func fetchScamRegistryChunk(state: SGScamRegistryFetchState, pageBudget: Int, completion: @escaping (Result<SGScamRegistryFetchChunk, Error>) -> Void)
    /// Stops any in-flight chunk fetch (account switch/logout). The in-flight
    /// completion is still invoked exactly once (with a failure) so callers
    /// can always clear their in-progress state.
    func cancelFetch()
}

public final class SGScamRegistryService {
    public static let shared = SGScamRegistryService()

    public static let channelUsername = "GID_ScamBase"
    public static let channelLink = "https://t.me/GID_ScamBase"

    private struct Cache: Codable {
        let ids: [Int64]
        let fetchedAt: TimeInterval
    }

    /// Immutable snapshot published for the main thread. All public reads
    /// (`contains`, `snapshot`, `currentSettings`, `isRefreshing`) go through
    /// `stateLock` — nanosecond-scale access, never a dispatch `sync` into a
    /// queue that might be busy. This is what keeps chat/profile layout passes
    /// from ever blocking behind registry work.
    private struct State {
        var ids: Set<Int64> = []
        var settings = SGScamRegistrySettings()
        var refreshing = false
    }

    private static let cacheKey = "sg.scamRegistry.cache"
    private static let fetchStateKey = "sg.scamRegistry.fetchState"
    private static let maximumIDCount = 100_000
    private static let maximumCacheBytes = 2 * 1024 * 1024
    /// Pages (≈100 messages each) fetched per run. Runs are deliberately small
    /// so collection happens "little by little" in the background.
    private static let pagesPerRun = 50
    /// While a sweep is still catching up on backlog, continue it with short
    /// follow-up runs instead of waiting a whole refresh interval.
    private static let catchUpFollowUpDelay: TimeInterval = 60
    /// Re-traverse the entire history (not just new messages) at most this
    /// often, so edits of old posts eventually make it into the registry.
    private static let fullSweepRefreshInterval: TimeInterval = 7 * 24 * 3600

    private let stateLock = NSLock()
    private var state = State()

    /// Single mutation authority. Nothing ever calls `queue.sync` — including
    /// from the main thread — so work scheduled here (cache loads, chunk
    /// merges, timer ticks) can never stall a caller.
    private let queue = DispatchQueue(label: "sg.scamRegistry.serial")
    /// Regex parsing and JSON encoding of the cache run here, off both the
    /// main thread and `queue`, so merges on `queue` stay microsecond-scale.
    private static let parseQueue = DispatchQueue(label: "sg.scamRegistry.parse", qos: .utility)

    private let defaults: UserDefaults
    private var dataSource: SGScamRegistryDataSource?
    private var dataSourceGeneration = 0
    private var ids = Set<Int64>()
    private var fetchedAt: Date?
    private var fetchState = SGScamRegistryFetchState()
    private var settings: SGScamRegistrySettings
    private var timer: DispatchSourceTimer?
    private var refreshing = false
    private var followUpPending = false

    public init(defaults: UserDefaults = .standard, dataSource: SGScamRegistryDataSource? = nil) {
        self.defaults = defaults
        self.dataSource = dataSource
        self.settings = SGScamRegistrySettings(defaults: defaults)
        sgScamRegistryLog("init: enabled=\(self.settings.enabled) interval=\(self.settings.interval.rawValue) cachedIds=\(self.ids.count)")
        self.publishStateLocked()
        // The persisted cache (up to ~2 MB of JSON) and the fetch checkpoint
        // load on the serial queue, never in `init`: the first
        // `SGScamRegistryService.shared` touch happens on the main thread at
        // app start, and a synchronous plist read + decode here caused
        // launch-time jank. Until the load completes, reads simply see an
        // empty registry.
        queue.async { [weak self] in
            self?.loadPersistedStateLocked()
        }
    }

    deinit { timer?.cancel() }

    public func setDataSource(_ dataSource: SGScamRegistryDataSource?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.dataSourceGeneration += 1
            let previous = self.dataSource
            self.dataSource = dataSource
            // Replacing the account (login/logout) must also stop any
            // in-flight page fetches of the old one, not just veto results.
            previous?.cancelFetch()
            self.followUpPending = false
        }
    }

    // MARK: - Lock-protected reads (main-thread safe)

    public func currentSettings() -> SGScamRegistrySettings {
        stateLock.lock(); defer { stateLock.unlock() }
        return state.settings
    }

    public func contains(_ userID: Int64) -> Bool {
        guard userID > 0 else { return false }
        stateLock.lock(); defer { stateLock.unlock() }
        return state.ids.contains(userID)
    }

    /// Copy-on-write makes this an O(1) reference bump while the lock is held;
    /// the set is only truly duplicated later, off the main thread, if a
    /// background mutation triggers the COW copy.
    public func snapshot() -> Set<Int64> {
        stateLock.lock(); defer { stateLock.unlock() }
        return state.ids
    }

    /// Lets UI (e.g. the "Scan Now" row) know a fetch is already underway so it
    /// can render a "Scanning…" state instead of silently no-op'ing a tap.
    public func isRefreshing() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return state.refreshing
    }

    // MARK: - Mutations (serialized on `queue`)

    public func updateSettings(_ value: SGScamRegistrySettings) {
        queue.async { [weak self] in
            guard let self else { return }
            self.settings = value
            value.save(to: self.defaults)
            self.publishStateLocked()
            self.configureTimerLocked()
            NotificationCenter.default.post(name: .sgScamRegistrySettingsDidChange, object: self)
        }
    }

    /// Manual refresh is explicit and works even while scheduled refresh is disabled.
    public func refresh(completion: ((SGScamRegistryRefreshResult) -> Void)? = nil) {
        queue.async { [weak self] in self?.refreshLocked(completion: completion) }
    }

    public func start() {
        queue.async { [weak self] in self?.configureTimerLocked() }
    }

    public func stop() {
        queue.async { [weak self] in self?.timer?.cancel(); self?.timer = nil }
    }

    // MARK: - Internals (queue-confined unless noted)

    private func configureTimerLocked() {
        timer?.cancel(); timer = nil
        guard settings.enabled else { sgScamRegistryLog("timer: plugin disabled, not scheduling"); return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(settings.interval.rawValue), repeating: .seconds(settings.interval.rawValue))
        timer.setEventHandler { [weak self] in self?.refreshLocked(completion: nil) }
        self.timer = timer
        timer.resume()
        // Enabling the plugin (or relaunching with it already enabled) with no
        // locally known IDs yet must not wait a full interval for protection to
        // do anything — kick an immediate background fetch. `refreshLocked`'s
        // own `refreshing` guard makes this safe to call unconditionally here.
        if ids.isEmpty {
            refreshLocked(completion: nil)
        }
    }

    private func refreshLocked(completion: ((SGScamRegistryRefreshResult) -> Void)?) {
        guard !refreshing else { sgScamRegistryLog("refresh: veto (already running)"); completion?(.alreadyInProgress); return }
        guard let dataSource else { sgScamRegistryLog("refresh: veto (no data source / no account)"); completion?(.failed(usedCache: true)); return }
        let sourceGeneration = dataSourceGeneration
        refreshing = true
        followUpPending = false
        publishStateLocked()
        NotificationCenter.default.post(name: .sgScamRegistryRefreshDidStart, object: self)

        // A weekly full re-traverse picks up edits of old posts; between full
        // sweeps, runs that already know the oldest parsed message stop as
        // soon as they walk back onto familiar history.
        if fetchState.lastFullSweepAt > 0,
           Date().timeIntervalSince1970 - fetchState.lastFullSweepAt > Self.fullSweepRefreshInterval {
            fetchState = SGScamRegistryFetchState()
        }
        let runState = fetchState

        dataSource.fetchScamRegistryChunk(state: runState, pageBudget: Self.pagesPerRun) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(chunk):
                // Parse on the utility queue, merge under `queue`: neither the
                // main thread nor the mutation queue ever carries the regex
                // work.
                Self.parseQueue.async {
                    let parsed = Self.parse(texts: chunk.texts)
                    self.queue.async {
                        self.finishRefreshLocked(sourceGeneration: sourceGeneration, parsed: parsed, chunk: chunk, completion: completion)
                    }
                }
            case let .failure(error):
                // A failure means nothing usable was fetched this run (the
                // source reports mid-run network trouble as a partial-success
                // chunk so progress is never thrown away).
                self.queue.async {
                    self.finishRefreshLocked(sourceGeneration: sourceGeneration, parsed: nil, chunk: nil, error: error, completion: completion)
                }
            }
        }
    }

    private func finishRefreshLocked(sourceGeneration: Int, parsed: Set<Int64>?, chunk: SGScamRegistryFetchChunk?, error: Error? = nil, completion: ((SGScamRegistryRefreshResult) -> Void)?) {
        refreshing = false
        guard sourceGeneration == self.dataSourceGeneration else {
            sgScamRegistryLog("refresh: finish (generation veto — account switched)")
            publishStateLocked()
            completion?(.failed(usedCache: true))
            return
        }
        let output: SGScamRegistryRefreshResult
        if let chunk {
            if let parsed, !parsed.isEmpty, self.ids.count < Self.maximumIDCount {
                self.ids.formUnion(parsed)
            }
            self.fetchState = chunk.state
            self.fetchedAt = Date()
            self.persistAsync()
            sgScamRegistryLog("refresh: chunk merged ids=\(self.ids.count) parsed=\(parsed?.count ?? 0) hasMore=\(chunk.hasMore) sweptToEnd=\(chunk.sweptToEnd) offsetId=\(chunk.state.offsetId) newestParsedId=\(chunk.state.newestParsedId)")
            output = .updated(count: self.ids.count, usedCache: false)
            NotificationCenter.default.post(name: .sgScamRegistryDidChange, object: self)
        } else {
            _ = error
            sgScamRegistryLog("refresh: failed error=\(String(describing: error))")
            output = .failed(usedCache: !self.ids.isEmpty || self.fetchedAt != nil)
        }
        publishStateLocked()
        NotificationCenter.default.post(name: .sgScamRegistryRefreshDidFinish, object: self, userInfo: ["result": output])
        completion?(output)

        // Mid-sweep backlog: keep collecting little by little with short
        // follow-up runs instead of fetching everything in one burst or
        // waiting a full interval between chunks.
        if let chunk, chunk.hasMore, self.settings.enabled {
            scheduleFollowUpLocked()
        }
    }

    private func scheduleFollowUpLocked() {
        guard !followUpPending else { return }
        followUpPending = true
        queue.asyncAfter(deadline: .now() + Self.catchUpFollowUpDelay) { [weak self] in
            guard let self else { return }
            self.followUpPending = false
            guard self.settings.enabled, !self.refreshing else { return }
            self.refreshLocked(completion: nil)
        }
    }

    /// Publishes the queue-confined state into the lock-protected snapshot.
    /// Callers must hold `queue`.
    private func publishStateLocked() {
        stateLock.lock()
        state.ids = ids
        state.settings = settings
        state.refreshing = refreshing
        stateLock.unlock()
    }

    private func loadPersistedStateLocked() {
        if let data = defaults.data(forKey: Self.cacheKey), data.count <= Self.maximumCacheBytes,
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.ids.count <= Self.maximumIDCount,
           cache.ids.allSatisfy({ $0 > 0 }) {
            ids = Set(cache.ids)
            fetchedAt = Date(timeIntervalSince1970: cache.fetchedAt)
        }
        if let data = defaults.data(forKey: Self.fetchStateKey),
           let saved = try? JSONDecoder().decode(SGScamRegistryFetchState.self, from: data) {
            fetchState = saved
        }
        publishStateLocked()
    }

    /// Encodes and writes the cache + checkpoint off `queue` and off the main
    /// thread. `UserDefaults` is thread-safe; the captures are copy-on-write
    /// references, so nothing expensive happens under the queue either.
    private func persistAsync() {
        let ids = self.ids
        let fetchedAt = self.fetchedAt
        let fetchState = self.fetchState
        let defaults = self.defaults
        Self.parseQueue.async {
            let cache = Cache(ids: ids.sorted(), fetchedAt: fetchedAt?.timeIntervalSince1970 ?? 0)
            if let data = try? JSONEncoder().encode(cache), data.count <= Self.maximumCacheBytes {
                defaults.set(data, forKey: Self.cacheKey)
            }
            if let data = try? JSONEncoder().encode(fetchState) {
                defaults.set(data, forKey: Self.fetchStateKey)
            }
        }
    }

    private static func parse(texts: [String]) -> Set<Int64> {
        var bytes = 0
        var result = Set<Int64>()
        let pattern = #"(?<![A-Za-zА-Яа-яЁё])ID\s+(\d{6,12})\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        for text in texts.prefix(maximumTextCount) {
            bytes += text.utf8.count
            guard bytes <= maximumSourceBytes else { break }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            expression.enumerateMatches(in: text, range: range) { match, _, stop in
                guard let match, let idRange = Range(match.range(at: 1), in: text),
                      let id = Int64(text[idRange]), id > 0 else { return }
                result.insert(id)
                if result.count >= maximumIDCount { stop.pointee = true }
            }
            if result.count >= maximumIDCount { break }
        }
        return result
    }

    private static let maximumTextCount = 1_000_000
    private static let maximumSourceBytes = 4 * 1024 * 1024
}
