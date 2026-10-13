import Foundation

public extension Notification.Name {
    static let sgScamRegistryDidChange = Notification.Name("sg.scamRegistry.didChange")
    static let sgScamRegistrySettingsDidChange = Notification.Name("sg.scamRegistry.settingsDidChange")
    static let sgScamRegistryRefreshDidFinish = Notification.Name("sg.scamRegistry.refreshDidFinish")
}

public enum SGScamRegistryRefreshResult: Equatable {
    case updated(count: Int, usedCache: Bool)
    case failed(usedCache: Bool)
}

/// The source boundary deliberately contains no Telegram or plugin-runtime types.
/// An adapter can use TelegramCore's account context and API, but the registry is
/// disabled and inert until one is explicitly supplied and enabled.
public protocol SGScamRegistryDataSource: AnyObject {
    func fetchScamRegistryTexts(completion: @escaping (Result<[String], Error>) -> Void)
}

public final class SGScamRegistryService {
    public static let shared = SGScamRegistryService()

    public static let channelUsername = "GID_ScamBase"
    public static let channelLink = "https://t.me/GID_ScamBase"

    private struct Cache: Codable {
        let ids: [Int64]
        let fetchedAt: TimeInterval
    }

    private static let cacheKey = "sg.scamRegistry.cache"
    private static let maximumSourceBytes = 4 * 1024 * 1024
    private static let maximumTextCount = 1_000_000
    private static let maximumIDCount = 100_000
    private static let maximumCacheBytes = 2 * 1024 * 1024

    private let queue = DispatchQueue(label: "sg.scamRegistry.serial")
    private let defaults: UserDefaults
    private var dataSource: SGScamRegistryDataSource?
    private var dataSourceGeneration = 0
    private var ids = Set<Int64>()
    private var fetchedAt: Date?
    private var settings: SGScamRegistrySettings
    private var timer: DispatchSourceTimer?
    private var refreshing = false

    public init(defaults: UserDefaults = .standard, dataSource: SGScamRegistryDataSource? = nil) {
        self.defaults = defaults
        self.dataSource = dataSource
        self.settings = SGScamRegistrySettings(defaults: defaults)
        loadCache()
    }

    deinit { timer?.cancel() }

    public func setDataSource(_ dataSource: SGScamRegistryDataSource?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.dataSourceGeneration += 1
            self.dataSource = dataSource
        }
    }

    public func currentSettings() -> SGScamRegistrySettings {
        queue.sync { settings }
    }

    public func updateSettings(_ value: SGScamRegistrySettings) {
        queue.async { [weak self] in
            guard let self else { return }
            self.settings = value
            value.save(to: self.defaults)
            self.configureTimerLocked()
            NotificationCenter.default.post(name: .sgScamRegistrySettingsDidChange, object: self)
        }
    }

    public func contains(_ userID: Int64) -> Bool {
        guard userID > 0 else { return false }
        return queue.sync { ids.contains(userID) }
    }

    public func snapshot() -> Set<Int64> { queue.sync { ids } }

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

    private func configureTimerLocked() {
        timer?.cancel(); timer = nil
        guard settings.enabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(settings.interval.rawValue), repeating: .seconds(settings.interval.rawValue))
        timer.setEventHandler { [weak self] in self?.refreshLocked(completion: nil) }
        self.timer = timer
        timer.resume()
    }

    private func refreshLocked(completion: ((SGScamRegistryRefreshResult) -> Void)?) {
        guard !refreshing else { completion?(.failed(usedCache: true)); return }
        guard let dataSource else { completion?(.failed(usedCache: true)); return }
        let sourceGeneration = dataSourceGeneration
        refreshing = true
        dataSource.fetchScamRegistryTexts { [weak self] result in
            self?.queue.async {
                guard let self else { return }
                self.refreshing = false
                guard sourceGeneration == self.dataSourceGeneration else {
                    completion?(.failed(usedCache: true))
                    return
                }
                let output: SGScamRegistryRefreshResult
                switch result {
                case let .success(texts):
                    // Empty is a valid successful registry, not a failed fetch.
                    let parsed = Self.parse(texts: texts)
                    self.ids = parsed
                    self.fetchedAt = Date()
                    self.persistLocked()
                    output = .updated(count: parsed.count, usedCache: false)
                    NotificationCenter.default.post(name: .sgScamRegistryDidChange, object: self)
                case .failure:
                    output = .failed(usedCache: !self.ids.isEmpty || self.fetchedAt != nil)
                }
                NotificationCenter.default.post(name: .sgScamRegistryRefreshDidFinish, object: self, userInfo: ["result": output])
                completion?(output)
            }
        }
    }

    private func loadCache() {
        guard let data = defaults.data(forKey: Self.cacheKey), data.count <= Self.maximumCacheBytes,
              let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.ids.count <= Self.maximumIDCount,
              cache.ids.allSatisfy({ $0 > 0 }) else { return }
        ids = Set(cache.ids)
        fetchedAt = Date(timeIntervalSince1970: cache.fetchedAt)
    }

    private func persistLocked() {
        let cache = Cache(ids: ids.sorted(), fetchedAt: fetchedAt?.timeIntervalSince1970 ?? 0)
        guard let data = try? JSONEncoder().encode(cache), data.count <= Self.maximumCacheBytes else { return }
        defaults.set(data, forKey: Self.cacheKey)
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
}
