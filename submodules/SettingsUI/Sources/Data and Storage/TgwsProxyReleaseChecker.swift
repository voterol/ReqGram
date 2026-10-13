import Foundation

/// Metadata only; never fetch assets, bodies, executables or supplied URLs.
final class TgwsProxyReleaseChecker {
    static let shared = TgwsProxyReleaseChecker()
    static let didChange = Notification.Name("SettingsUI.TgwsRelease.didChange")
    static let endpoint = URL(string: "https://api.github.com/repos/Flowseal/tg-ws-proxy/releases/latest")!
    static let releasesURL = URL(string: "https://github.com/Flowseal/tg-ws-proxy/releases")!
    static let bundledRevision = "3c54c54d36ae59e5e09885fad3ddf6aa60f9cdea"
    struct Release: Codable, Equatable {
        let tag: String
        let checkedAt: Date
    }
    private let defaults: UserDefaults
    private let cacheKey = "SettingsUI.tgws.release.cache.v1"
    private let autoKey = "SettingsUI.tgws.release.auto.v1"
    private var request: TgwsReleaseRequest?
    private var lastAttempt: Date?
    private(set) var cached: Release?
    private(set) var checking = false
    private(set) var error: String?
    var automatic: Bool {
        get { defaults.bool(forKey: autoKey) }
        set { defaults.set(newValue, forKey: autoKey); notify() }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: cacheKey), data.count <= 1024,
           let release = try? JSONDecoder().decode(Release.self, from: data),
           Self.validTag(release.tag), release.checkedAt <= Date() { cached = release }
    }
    static func validTag(_ tag: String) -> Bool {
        !tag.isEmpty && tag.utf8.count <= 80 && tag.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95, 43].contains($0)
        }
    }
    static func decode(_ data: Data, now: Date = Date()) -> Release? {
        guard data.count <= 65536,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, validTag(tag),
              let draft = json["draft"] as? Bool, !draft,
              let prerelease = json["prerelease"] as? Bool, !prerelease else { return nil }
        return Release(tag: tag, checkedAt: now)
    }
    func check(manual: Bool) {
        precondition(Thread.isMainThread)
        guard !checking else { return }
        let now = Date()
        if !manual {
            guard automatic,
                  cached.map({ now.timeIntervalSince($0.checkedAt) >= 86400 }) ?? true,
                  lastAttempt.map({ now.timeIntervalSince($0) >= 900 }) ?? true else { return }
        }
        checking = true
        error = nil
        lastAttempt = now
        notify()
        let request = TgwsReleaseRequest()
        self.request = request
        request.start { [weak self] data, status, failure in
            guard let self = self else { return }
            self.request = nil
            self.checking = false
            if failure != nil {
                self.error = "Could not check GitHub. You may be offline; try again later."
            } else if status == 403 || status == 429 {
                self.error = "GitHub rate limit reached. Try again later."
            } else if status == 404 {
                self.error = "No published upstream release is available."
            } else if status == 200, let data = data, let release = Self.decode(data) {
                self.cached = release
                if let encoded = try? JSONEncoder().encode(release) { self.defaults.set(encoded, forKey: self.cacheKey) }
            } else {
                self.error = "GitHub returned an unsupported response. Try again later."
            }
            self.notify()
        }
    }
    func cancel() { request?.cancel() }
    private func notify() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}

private final class TgwsReleaseRequest: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private var session: URLSession?
    private var data = Data()
    private var status: Int?
    private var completion: ((Data?, Int?, Error?) -> Void)?
    func start(completion: @escaping (Data?, Int?, Error?) -> Void) {
        self.completion = completion
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main)
        self.session = session
        var request = URLRequest(url: TgwsProxyReleaseChecker.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ReqGram-Tgws-Version-Check", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request).resume()
    }
    func cancel() { session?.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode
        completionHandler(response.expectedContentLength > 65536 ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.data.count + data.count <= 65536 else { dataTask.cancel(); return }
        self.data.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion = self.completion
        self.completion = nil
        session.finishTasksAndInvalidate()
        self.session = nil
        completion?(data, status, error)
    }
}
