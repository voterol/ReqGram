import Foundation
import AccountContext

/// Polling engine of the Now Playing plugin — native port of reSwaga's
/// `now_playing.py` loop: fetch the current track from every configured
/// platform, pick one by source/priority, and hand the result to the
/// streamer. Ticks every ~15s with the original 10–17s jitter.
public final class SGNowPlayingService {
    public static let shared = SGNowPlayingService()

    private let queue = DispatchQueue(label: "sg.nowPlaying.service")
    /// Guards `settings`; every accessor is callable from any queue (the
    /// streamer calls back from its own queue and from the main queue).
    private let lock = NSLock()
    private var settings: SGNowPlayingSettings

    private weak var account: AccountContext?
    private var streamer: SGNowPlayingStreamer?

    private var pollGeneration = 0
    private var pendingRestartGeneration = 0
    /// Read from the main thread (settings UI rows), written on `queue`; always
    /// access through `lock`. Never dispatch-sync into `queue` for these — a
    /// stalled service queue must not be able to freeze the UI.
    private var isPolling = false
    private var lastStatusText: String = ""
    /// Last actively-playing track chosen by source/priority (lock-guarded
    /// mirror of the queue-confined poll state, for the send menu on main).
    private var lastChosenTrack: SGNowPlayingTrack?
    /// Queue-confined state (no cross-thread reads).
    private var isScheduled = false
    private var lastTracks: [SGNowPlayingPlatformId: SGNowPlayingTrack] = [:]
    private var lastPlatformErrors: [SGNowPlayingPlatformId: String] = [:]
    private var pendingCheckCompletions: [(String) -> Void] = []

    private init() {
        self.settings = SGNowPlayingSettings.load()
        self.lastStatusText = SGNowPlayingSettings.loadStatus()
    }

    // MARK: - Lifecycle

    public func configure(account: AccountContext) {
        self.queue.async { [weak self] in
            guard let self else {
                return
            }
            // `configure` is re-invoked on every account-record update, not
            // only on login. Recreating the streamer each time would reset its
            // `lastPlaylistTrackId` bookkeeping and re-upload the current track
            // (duplicate Saved-Music entries), so only rebuild when the
            // account actually changed.
            if self.streamer == nil || self.account?.account.id != account.account.id {
                self.account = account
                self.streamer = SGNowPlayingStreamer(context: account)
                sgNowPlayingLog("configured for account \(account.account.id.int64)")
            }
            self.restartPolling()
        }
    }

    // MARK: - Settings

    public func currentSettings() -> SGNowPlayingSettings {
        return self.currentSettingsInternal()
    }

    /// Lock-safe settings snapshot; also used by the streamer's callbacks.
    func currentSettingsInternal() -> SGNowPlayingSettings {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.settings
    }

    /// Persisted settings mutation from the streamer (playlist bookkeeping).
    /// Does not restart the poll loop.
    func updateSettingsInternal(_ updated: SGNowPlayingSettings) {
        self.applySettings(updated, restart: false)
    }

    /// Marks whether plugin-written profile content is currently outstanding,
    /// so the restore path (and only the restore path) knows to run.
    func setDidWriteProfile(_ value: Bool) {
        var settings = self.currentSettingsInternal()
        guard settings.didWriteProfile != value else {
            return
        }
        settings.didWriteProfile = value
        self.updateSettingsInternal(settings)
    }

    /// Settings mutation from the UI. Restarts the poll loop so changes take
    /// effect immediately.
    public func updateSettings(_ transform: (inout SGNowPlayingSettings) -> Void) {
        var updated = self.currentSettingsInternal()
        transform(&updated)
        self.applySettings(updated, restart: true)
    }

    public func setToken(platform: SGNowPlayingPlatformId, value: String?) {
        self.updateSettings { settings in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                settings.tokens.removeValue(forKey: platform.rawValue)
            } else {
                settings.tokens[platform.rawValue] = trimmed
            }
        }
    }

    public func setDefaultText(_ text: String) {
        // No restart: the idle text only matters when the streamer next writes,
        // and the input fires per keystroke — a restart per keystroke would
        // hammer the platforms.
        var updated = self.currentSettingsInternal()
        updated.defaultText = text
        self.applySettings(updated, restart: false)
    }

    private func applySettings(_ updated: SGNowPlayingSettings, restart: Bool) {
        self.lock.lock()
        self.settings = updated
        self.lock.unlock()
        // Persist off the caller's thread and strictly serialized on `queue`:
        // applySettings runs on the main thread (per-keystroke token/default
        // text input) and on the streamer's queue (playlist bookkeeping), and
        // concurrent UserDefaults writes from several threads are both slow on
        // main and a known way to wedge a process on cfprefsd contention.
        let queue = self.queue
        queue.async {
            updated.save()
        }
        NotificationCenter.default.post(name: .sgNowPlayingSettingsDidChange, object: nil)
        if restart {
            // Debounced: token/default-text input fires per keystroke, and an
            // immediate restart per keystroke would poll the platforms dozens
            // of times while the user is still typing.
            self.queue.async { [weak self] in
                guard let self else {
                    return
                }
                self.pendingRestartGeneration += 1
                let generation = self.pendingRestartGeneration
                self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, generation == self.pendingRestartGeneration else {
                        return
                    }
                    self.restartPolling()
                }
            }
        }
    }

    // MARK: - Status

    /// Last poll outcome shown in the plugin's UI row. Lock-guarded snapshot —
    /// never dispatch-sync into `queue` from the main thread here.
    public var lastStatus: String {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.lastStatusText
    }

    /// Whether a poll is in flight (drives the "Check now" row's label).
    public var isPollingNow: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.isPolling
    }

    /// The actively-playing track, or nil when nothing plays. Lock-guarded
    /// snapshot — safe to read from the main thread (send menu / attach button).
    public var currentTrack: SGNowPlayingTrack? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.lastChosenTrack
    }

    private func setCurrentTrack(_ track: SGNowPlayingTrack?) {
        self.lock.lock()
        self.lastChosenTrack = track
        self.lock.unlock()
    }

    private func setStatus(_ status: String) {
        self.lock.lock()
        self.lastStatusText = status
        self.lock.unlock()
        SGNowPlayingSettings.saveStatus(status)
    }

    private func setPolling(_ value: Bool) {
        self.lock.lock()
        self.isPolling = value
        self.lock.unlock()
    }

    // MARK: - Polling

    /// One-shot poll regardless of `isEnabled`; used by the "Check now" action.
    public func checkNow(completion: ((String) -> Void)? = nil) {
        self.queue.async { [weak self] in
            guard let self else {
                completion?("")
                return
            }
            if let completion {
                self.pendingCheckCompletions.append(completion)
            }
            if self.isPollingNow {
                return
            }
            self.pollOnce()
        }
    }

    /// Must run on `queue`. Cancels any scheduled continuation and either
    /// starts polling immediately or restores the profile defaults.
    private func restartPolling() {
        self.pollGeneration += 1
        self.isScheduled = false
        let settings = self.currentSettingsInternal()
        if settings.isEnabled, !settings.configuredPlatforms.isEmpty, self.account != nil {
            sgNowPlayingLog("polling started (\(settings.configuredPlatforms.map(\.rawValue).joined(separator: ", ")))")
            if !self.isPollingNow {
                self.pollOnce()
            }
        } else if !settings.isEnabled {
            self.lastTracks = [:]
            self.lastPlatformErrors = [:]
            self.setCurrentTrack(nil)
            if let streamer = self.streamer {
                streamer.apply(tracks: nil, settings: settings)
            }
            self.setStatus("")
        }
    }

    /// Must run on `queue`; must not be called while `isPolling`.
    private func pollOnce() {
        self.setPolling(true)
        let generation = self.pollGeneration
        let settings = self.currentSettingsInternal()
        let platforms = settings.configuredPlatforms

        guard !platforms.isEmpty else {
            self.finishPoll(
                generation: generation,
                settings: settings,
                results: [:],
                errors: [:],
                status: "No platform tokens configured"
            )
            return
        }

        NotificationCenter.default.post(name: .sgNowPlayingPollDidStart, object: nil)
        var results: [SGNowPlayingPlatformId: SGNowPlayingTrack] = [:]
        var errors: [SGNowPlayingPlatformId: String] = [:]
        let resultsLock = NSLock()
        let group = DispatchGroup()
        for platform in platforms {
            guard let token = settings.token(for: platform) else {
                continue
            }
            group.enter()
            SGNowPlayingClient.shared.currentTrack(platform: platform, token: token) { result in
                switch result {
                case let .track(track):
                    if let track {
                        resultsLock.lock()
                        results[platform] = track
                        resultsLock.unlock()
                    }
                case let .failure(message):
                    resultsLock.lock()
                    errors[platform] = message
                    resultsLock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: self.queue) { [weak self] in
            guard let self else {
                return
            }
            let chosen = SGNowPlayingService.chooseTrack(tracks: results, source: settings.source)
            let status = SGNowPlayingService.statusText(chosen: chosen, errors: errors)
            self.setCurrentTrack(chosen)
            self.finishPoll(generation: generation, settings: settings, results: results, errors: errors, status: status)
        }
    }

    /// Must run on `queue`.
    private func finishPoll(
        generation: Int,
        settings: SGNowPlayingSettings,
        results: [SGNowPlayingPlatformId: SGNowPlayingTrack],
        errors: [SGNowPlayingPlatformId: String],
        status: String
    ) {
        self.setPolling(false)
        let generationValid = generation == self.pollGeneration

        // Polled platforms replace their slot; platforms that were removed
        // from the settings during the poll drop out entirely.
        for platform in settings.configuredPlatforms {
            self.lastTracks.removeValue(forKey: platform)
            self.lastPlatformErrors.removeValue(forKey: platform)
        }
        for (platform, track) in results {
            self.lastTracks[platform] = track
        }
        for (platform, message) in errors {
            self.lastPlatformErrors[platform] = message
        }
        // Tokens removed while a poll was in flight must not leave a stale
        // track behind (auto-priority would keep streaming it forever).
        let currentPlatforms = Set(self.currentSettingsInternal().configuredPlatforms)
        self.lastTracks = self.lastTracks.filter { currentPlatforms.contains($0.key) }
        self.lastPlatformErrors = self.lastPlatformErrors.filter { currentPlatforms.contains($0.key) }

        self.setStatus(status)
        sgNowPlayingLog("poll finished: \(status)")

        let completions = self.pendingCheckCompletions
        self.pendingCheckCompletions.removeAll()
        for completion in completions {
            completion(status)
        }
        NotificationCenter.default.post(name: .sgNowPlayingPollDidFinish, object: nil)

        guard generationValid else {
            // A restart superseded this poll while it was in flight, so the
            // restart itself skipped launching a new one (`isPolling`). Keep
            // the loop alive under the current generation; if the superseding
            // restart also disabled polling, the continuation's own checks
            // drop it.
            let current = self.currentSettingsInternal()
            if current.isEnabled, !current.configuredPlatforms.isEmpty, self.account != nil {
                self.scheduleNextPoll(generation: self.pollGeneration)
            }
            return
        }
        if settings.isEnabled {
            self.streamer?.apply(tracks: self.lastTracks, settings: settings)
            self.scheduleNextPoll(generation: generation)
        }
    }

    /// Must run on `queue`.
    private func scheduleNextPoll(generation: Int) {
        guard !self.isScheduled else {
            return
        }
        self.isScheduled = true
        let interval = Double.random(in: 10.0...17.0)
        self.queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self else {
                return
            }
            self.isScheduled = false
            guard generation == self.pollGeneration, self.currentSettingsInternal().isEnabled else {
                return
            }
            if !self.isPollingNow {
                self.pollOnce()
            }
        }
    }

    // MARK: - Track selection (mirrors the streamer's rules for status text)

    private static func chooseTrack(tracks: [SGNowPlayingPlatformId: SGNowPlayingTrack], source: SGNowPlayingSource) -> SGNowPlayingTrack? {
        switch source {
        case .auto:
            for platform in SGNowPlayingPlatformId.autoPriority {
                if let track = tracks[platform], track.isActive {
                    return track
                }
            }
            return nil
        case let .platform(platform):
            guard let track = tracks[platform] else {
                return nil
            }
            return track.isActive ? track : nil
        }
    }

    private static func statusText(chosen: SGNowPlayingTrack?, errors: [SGNowPlayingPlatformId: String]) -> String {
        if let chosen, chosen.isActive {
            return chosen.displayText
        }
        if !errors.isEmpty {
            let parts = errors
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue): \($0.value)" }
                .joined(separator: "; ")
            return String("Error — " + parts).prefix(200).description
        }
        return "Nothing is playing"
    }
}
