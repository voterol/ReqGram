import Foundation

/// NSLog-based diagnostics. Custom os_log categories are not visible in the
/// simulator's unified log (same lesson as SGScamRegistry), so NSLog it is.
public func sgNowPlayingLog(_ message: String) {
    NSLog("[SGNowPlaying] %@", message)
}

/// HTTP + parsing layer of the Now Playing plugin.
///
/// Endpoint, header, parameter and response shapes are ported one-to-one from the
/// original reSwaga plugin (`utils/platform_utils.py`, `utils/soundcloud_utils.py`).
/// Deviations are marked inline and limited to what iOS needs.
public final class SGNowPlayingClient {
    public static let shared = SGNowPlayingClient()

    public enum ClientResult {
        /// A decoded track (`nil` = platform answered "nothing playing").
        case track(SGNowPlayingTrack?)
        /// Human-readable failure description.
        case failure(String)
    }

    private let session: URLSession
    private let queue = DispatchQueue(label: "sg.nowPlaying.client", attributes: .concurrent)
    private let scLock = NSLock()
    private var scClientId: String?
    private var scClientIdFetchInProgress = false
    private var scClientIdWaiters: [(String) -> Void] = []

    private static let chromeMacUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    private static let chromeMobileUA = "Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
    private static let fallbackSoundCloudClientId = "1HxML01xkzWgtHfBreaeZfpANMe3ADjb"
    private static let requestTimeout: TimeInterval = 10.0

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = SGNowPlayingClient.requestTimeout
        configuration.timeoutIntervalForResource = SGNowPlayingClient.requestTimeout * 2.0
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Public API

    /// Fetches the current track for one platform. `completion` runs on the
    /// client queue.
    public func currentTrack(
        platform: SGNowPlayingPlatformId,
        token: String,
        completion: @escaping (ClientResult) -> Void
    ) {
        switch platform {
        case .spotify:
            let username = token.split(separator: "/").last.map(String.init) ?? token
            guard !username.isEmpty else {
                completion(.failure("empty stats.fm username"))
                return
            }
            self.jsonRequest(
                url: "https://api.stats.fm/api/v1/users/\(username)/streams/current",
                method: "GET",
                headers: ["User-Agent": "Mozilla/5.0", "Accept": "application/json"]
            ) { result in
                switch result {
                case let .success(response):
                    completion(.track(Self.decodeStatsFm(response, platform: platform)))
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        case .lastFm:
            var components = URLComponents(string: "http://ws.audioscrobbler.com/2.0")
            components?.queryItems = [
                URLQueryItem(name: "method", value: "user.getrecenttracks"),
                URLQueryItem(name: "user", value: token),
                URLQueryItem(name: "api_key", value: "19e0b83fb81f7043c02e4f070848a57a"),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "limit", value: "1")
            ]
            guard let url = components?.url else {
                completion(.failure("invalid last.fm url"))
                return
            }
            self.jsonRequest(url: url.absoluteString, method: "GET", headers: nil) { [weak self] result in
                switch result {
                case let .success(response):
                    let decoded = Self.decodeLastFm(response, platform: platform)
                    guard let self else {
                        completion(.track(decoded))
                        return
                    }
                    self.enrichLastFmTrack(decoded) { enriched in
                        completion(.track(enriched))
                    }
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        case .vkMusic:
            var components = URLComponents(string: "https://api.vk.ru/method/users.get")
            components?.queryItems = [
                URLQueryItem(name: "fields", value: "status"),
                URLQueryItem(name: "v", value: "5.199"),
                URLQueryItem(name: "access_token", value: token)
            ]
            guard let url = components?.url else {
                completion(.failure("invalid vk url"))
                return
            }
            self.jsonRequest(url: url.absoluteString, method: "GET", headers: nil) { result in
                switch result {
                case let .success(response):
                    completion(.track(Self.decodeVk(response, platform: platform)))
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        case .yandexMusic:
            self.jsonRequest(
                url: "https://track.mipoh.gay/get_current_track_beta",
                method: "GET",
                headers: ["ya-token": token]
            ) { result in
                switch result {
                case let .success(response):
                    completion(.track(Self.decodeYandex(response, platform: platform)))
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        case .soundCloud:
            self.soundCloudClientId { [weak self] clientId in
                guard let self else {
                    return
                }
                var components = URLComponents(string: "https://api-v2.soundcloud.com/me/play-history/tracks")
                components?.queryItems = [
                    URLQueryItem(name: "client_id", value: clientId),
                    URLQueryItem(name: "app_version", value: "1739181955"),
                    URLQueryItem(name: "app_locale", value: "en"),
                    URLQueryItem(name: "limit", value: "20"),
                    URLQueryItem(name: "offset", value: "0"),
                    URLQueryItem(name: "linked_partitioning", value: "1")
                ]
                guard let url = components?.url else {
                    completion(.failure("invalid soundcloud url"))
                    return
                }
                self.authenticatedJsonRequest(
                    url: url.absoluteString,
                    method: "GET",
                    headers: [
                        "User-Agent": SGNowPlayingClient.chromeMobileUA,
                        "Authorization": "OAuth \(token)",
                        "Origin": "https://soundcloud.com",
                        "Referer": "https://soundcloud.com/"
                    ],
                    unauthorizedHandler: { [weak self] in
                        // reSwaga invalidates the scraped client_id on 401/403.
                        self?.invalidateSoundCloudClientId()
                    },
                    completion: { result in
                        switch result {
                        case let .success(response):
                            completion(.track(Self.decodeSoundCloud(response, platform: platform)))
                        case let .failure(error):
                            completion(.failure(error))
                        }
                    }
                )
            }
        case .youTubeMusic:
            guard let sapisid = Self.extractSapisid(fromCookie: token) else {
                completion(.failure("SAPISID not found in cookie"))
                return
            }
            let timestamp = String(Int(Date().timeIntervalSince1970))
            let origin = "https://music.youtube.com"
            let authorization = "SAPISIDHASH \(timestamp)_\(SGNowPlayingSHA1.hexDigest(of: "\(timestamp) \(sapisid) \(origin)"))"
            let body: [String: Any] = [
                "context": [
                    "client": [
                        "clientName": "WEB_REMIX",
                        "clientVersion": "1.20231212.01.00",
                        "hl": "en"
                    ],
                    "user": [:]
                ],
                "browseId": "FEmusic_history"
            ]
            // Deviation from the letter of the bytecode (which passes the dict as
            // request params): the youtubei/v1 endpoint requires a JSON body with
            // the same dict, so the body carries it.
            self.authenticatedJsonRequest(
                url: "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false",
                method: "POST",
                headers: [
                    "Authorization": authorization,
                    "Cookie": token,
                    "Content-Type": "application/json",
                    "Origin": origin,
                    "Referer": origin + "/",
                    "User-Agent": SGNowPlayingClient.chromeMacUA
                ],
                body: body,
                unauthorizedHandler: nil,
                completion: { result in
                    switch result {
                    case let .success(response):
                        completion(.track(Self.decodeYouTubeMusic(response, platform: platform)))
                    case let .failure(error):
                        completion(.failure(error))
                    }
                }
            )
        }
    }

    /// Downloads artwork bytes for the playlist cover. `completion` runs on the
    /// client queue; `nil` on any failure.
    public func artworkData(from urlString: String?, completion: @escaping (Data?) -> Void) {
        guard let urlString, let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.setValue(SGNowPlayingClient.chromeMobileUA, forHTTPHeaderField: "User-Agent")
        let task = self.session.dataTask(with: request) { data, response, _ in
            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                completion(nil)
                return
            }
            completion(data)
        }
        task.resume()
    }

    // MARK: - Request plumbing

    /// Stdlib `Result` requires `Failure: Error`, and `String` is not one — a
    /// two-case enum keeps every `.success`/`.failure` call site unchanged.
    private enum SGJsonResult {
        case success([String: Any])
        case failure(String)
    }

    private func jsonRequest(
        url: String,
        method: String,
        headers: [String: String]?,
        body: [String: Any]? = nil,
        unauthorizedHandler: (() -> Void)? = nil,
        completion: @escaping (SGJsonResult) -> Void
    ) {
        self.authenticatedJsonRequest(
            url: url,
            method: method,
            headers: headers,
            body: body,
            unauthorizedHandler: unauthorizedHandler,
            completion: completion
        )
    }

    private func authenticatedJsonRequest(
        url: String,
        method: String,
        headers: [String: String]?,
        body: [String: Any]? = nil,
        unauthorizedHandler: (() -> Void)?,
        completion: @escaping (SGJsonResult) -> Void
    ) {
        guard let requestUrl = URL(string: url) else {
            completion(.failure("invalid url"))
            return
        }
        var request = URLRequest(url: requestUrl)
        request.httpMethod = method
        for (name, value) in headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let task = self.session.dataTask(with: request) { [weak self] data, response, error in
            self?.queue.async {
                if let error {
                    completion(.failure(error.localizedDescription))
                    return
                }
                guard let response = response as? HTTPURLResponse else {
                    completion(.failure("no response"))
                    return
                }
                let payload = data ?? Data()
                if response.statusCode == 401 || response.statusCode == 403 {
                    unauthorizedHandler?()
                    completion(.failure("unauthorized (\(response.statusCode))"))
                    return
                }
                guard (200..<300).contains(response.statusCode) else {
                    let snippet = String(data: payload.prefix(120), encoding: .utf8) ?? ""
                    completion(.failure("HTTP \(response.statusCode) \(snippet)"))
                    return
                }
                guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
                    completion(.failure("invalid json"))
                    return
                }
                // reSwaga treats any top-level "error" key as "nothing to decode".
                if object["error"] != nil {
                    completion(.failure("api error: \(object["error"] ?? "")"))
                    return
                }
                completion(.success(object))
            }
        }
        task.resume()
    }

    // MARK: - SoundCloud client_id

    private func soundCloudClientId(forceRefresh: Bool = false, completion: @escaping (String) -> Void) {
        self.scLock.lock()
        if !forceRefresh, let cached = self.scClientId {
            self.scLock.unlock()
            completion(cached)
            return
        }
        self.scClientIdWaiters.append(completion)
        let shouldFetch = !self.scClientIdFetchInProgress
        self.scClientIdFetchInProgress = true
        self.scLock.unlock()

        guard shouldFetch else {
            return
        }
        let finish: (String) -> Void = { [weak self] value in
            guard let self else {
                return
            }
            self.scLock.lock()
            self.scClientId = value
            self.scClientIdFetchInProgress = false
            let waiters = self.scClientIdWaiters
            self.scClientIdWaiters.removeAll()
            self.scLock.unlock()
            for waiter in waiters {
                waiter(value)
            }
        }

        var request = URLRequest(url: URL(string: "https://soundcloud.com/")!)
        request.setValue(SGNowPlayingClient.chromeMobileUA, forHTTPHeaderField: "User-Agent")
        let task = self.session.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else {
                return
            }
            guard let data, let html = String(data: data, encoding: .utf8) else {
                finish(SGNowPlayingClient.fallbackSoundCloudClientId)
                return
            }
            let scripts = SGNowPlayingRegex.matches(pattern: "src=\"(https://[^\"]+\\.js)\"", in: html)
            let group = DispatchGroup()
            var found: String?
            let foundLock = NSLock()
            // reSwaga walks the script list in reverse and takes the first match.
            for scriptUrl in scripts.reversed() {
                if found != nil {
                    break
                }
                var scriptRequest = URLRequest(url: URL(string: scriptUrl)!)
                scriptRequest.setValue(SGNowPlayingClient.chromeMobileUA, forHTTPHeaderField: "User-Agent")
                group.enter()
                let scriptTask = self.session.dataTask(with: scriptRequest) { data, _, _ in
                    defer {
                        group.leave()
                    }
                    guard found == nil, let data, let source = String(data: data, encoding: .utf8) else {
                        return
                    }
                    if let clientId = SGNowPlayingRegex.firstMatch(pattern: "client_id[:=]\"([a-zA-Z0-9]{32})\"", in: source) {
                        foundLock.lock()
                        if found == nil {
                            found = clientId
                        }
                        foundLock.unlock()
                    }
                }
                scriptTask.resume()
            }
            group.notify(queue: self.queue) {
                finish(found ?? SGNowPlayingClient.fallbackSoundCloudClientId)
            }
        }
        task.resume()
    }

    private func invalidateSoundCloudClientId() {
        self.scLock.lock()
        self.scClientId = nil
        self.scLock.unlock()
    }

    private static func extractSapisid(fromCookie cookie: String) -> String? {
        return SGNowPlayingRegex.firstMatch(pattern: "(?:^|;\\s*)(?:SAPISID|__Secure-3PAPISID)=([^;]+)", in: cookie)
    }

    // MARK: - Response decoders

    private static func decodeStatsFm(_ response: [String: Any], platform: SGNowPlayingPlatformId) -> SGNowPlayingTrack? {
        guard let item = response["item"] as? [String: Any], let track = item["track"] as? [String: Any] else {
            return nil
        }
        var trackId = ""
        if let externalIds = track["externalIds"] as? [String: Any] {
            if let spotify = externalIds["spotify"] as? String {
                trackId = spotify
            } else if let first = (externalIds["spotify"] as? [Any])?.first as? String {
                // Faithful to reSwaga's literal `[0]` indexing quirk.
                trackId = first
            }
        }
        let artists = (track["artists"] as? [Any])?.compactMap { ($0 as? [String: Any])?["name"] as? String } ?? []
        let albumImage = (track["albums"] as? [Any])?.compactMap { ($0 as? [String: Any])?["image"] as? String }.first
        return SGNowPlayingTrack(
            isActive: item["isPlaying"] as? Bool ?? false,
            id: trackId,
            title: track["name"] as? String ?? "",
            artists: artists,
            artworkURL: albumImage,
            duration: (track["durationMs"] as? Int ?? 0) / 1000,
            progress: (item["progressMs"] as? Int ?? 0) / 1000,
            link: trackId.isEmpty ? nil : "https://open.spotify.com/track/\(trackId)",
            platform: platform
        )
    }

    /// reSwaga's image size priority over a last.fm `image` array:
    /// mega → extralarge → large, then any non-empty entry.
    static func pickLastFmImage(_ images: [[String: Any]]) -> String? {
        let bySize = Dictionary(images.compactMap { entry -> (String, String)? in
            guard let size = entry["size"] as? String, let text = entry["#text"] as? String else {
                return nil
            }
            return (size, text)
        }, uniquingKeysWith: { first, _ in first })
        if let best = ["mega", "extralarge", "large"].lazy.compactMap({ bySize[$0] }).first(where: { !$0.isEmpty }) {
            return best
        }
        return images.reversed().compactMap { $0["#text"] as? String }.first { !$0.isEmpty }
    }

    /// recenttracks omits both duration and album art for many tracks, while
    /// the same data exists on the album level — `track.getInfo` fills both.
    /// Lookups run once per (artist, title), cached for the session including
    /// negative results so the polling loop does not hammer the API.
    private func enrichLastFmTrack(_ track: SGNowPlayingTrack?, completion: @escaping (SGNowPlayingTrack?) -> Void) {
        guard var enriched = track, enriched.isActive, !enriched.title.isEmpty else {
            completion(track)
            return
        }
        guard enriched.artworkURL == nil || enriched.duration <= 0 else {
            completion(enriched)
            return
        }
        let artist = enriched.artistText
        let cacheKey = "\(artist)|\(enriched.title)"
        Self.lastFmInfoLock.lock()
        let cached = Self.lastFmInfoCache[cacheKey]
        Self.lastFmInfoLock.unlock()
        if let cached {
            if enriched.artworkURL == nil {
                enriched.artworkURL = cached.artworkURL
            }
            if enriched.duration <= 0 {
                enriched.duration = cached.duration
            }
            completion(enriched)
            return
        }
        var components = URLComponents(string: "http://ws.audioscrobbler.com/2.0")
        components?.queryItems = [
            URLQueryItem(name: "method", value: "track.getInfo"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "track", value: enriched.title),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "api_key", value: "19e0b83fb81f7043c02e4f070848a57a"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else {
            completion(enriched)
            return
        }
        self.jsonRequest(url: url.absoluteString, method: "GET", headers: nil) { result in
            var artworkURL: String?
            var duration = 0
            if case let .success(response) = result,
               let info = response["track"] as? [String: Any] {
                duration = (Int(info["duration"] as? String ?? "") ?? 0) / 1000
                if let album = info["album"] as? [String: Any], let images = album["image"] as? [[String: Any]] {
                    artworkURL = Self.pickLastFmImage(images)
                }
            }
            Self.lastFmInfoLock.lock()
            Self.lastFmInfoCache[cacheKey] = (artworkURL, duration)
            Self.lastFmInfoLock.unlock()
            if enriched.artworkURL == nil {
                enriched.artworkURL = artworkURL
            }
            if enriched.duration <= 0 {
                enriched.duration = duration
            }
            sgNowPlayingLog("last.fm info for '\(enriched.title)': duration=\(enriched.duration)s artwork=\(enriched.artworkURL != nil)")
            completion(enriched)
        }
    }

    private static let lastFmInfoLock = NSLock()
    private static var lastFmInfoCache: [String: (artworkURL: String?, duration: Int)] = [:]

    private static func decodeLastFm(_ response: [String: Any], platform: SGNowPlayingPlatformId) -> SGNowPlayingTrack? {
        guard let recent = response["recenttracks"] as? [String: Any] else {
            return SGNowPlayingTrack(isActive: false, id: "", title: "", artists: [], artworkURL: nil, duration: 0, progress: 0, link: nil, platform: platform)
        }
        let rawTracks = recent["track"]
        var tracks: [[String: Any]] = []
        if let list = rawTracks as? [[String: Any]] {
            tracks = list
        } else if let single = rawTracks as? [String: Any] {
            tracks = [single]
        }
        guard let first = tracks.first else {
            return SGNowPlayingTrack(isActive: false, id: "", title: "", artists: [], artworkURL: nil, duration: 0, progress: 0, link: nil, platform: platform)
        }
        // last.fm serializes track attributes under the literal key "@attr".
        let isPlaying = ((first["@attr"] as? [String: Any])?["nowplaying"] as? String) == "true"
        let title = first["name"] as? String ?? ""
        let artist: String
        if let artistDict = first["artist"] as? [String: Any], let text = artistDict["#text"] as? String {
            artist = text
        } else {
            artist = ""
        }
        var image = ""
        if let images = first["image"] as? [[String: Any]] {
            image = Self.pickLastFmImage(images) ?? ""
        }
        return SGNowPlayingTrack(
            isActive: isPlaying,
            id: title.replacingOccurrences(of: " ", with: "_").lowercased(),
            title: title,
            artists: artist.isEmpty ? [] : [artist],
            artworkURL: image.isEmpty ? nil : image,
            duration: 0,
            progress: 0,
            link: first["url"] as? String,
            platform: platform
        )
    }

    private static func decodeVk(_ response: [String: Any], platform: SGNowPlayingPlatformId) -> SGNowPlayingTrack? {
        guard let first = (response["response"] as? [[String: Any]])?.first else {
            return nil
        }
        guard let audio = first["status_audio"] as? [String: Any] else {
            return SGNowPlayingTrack(isActive: false, id: "", title: "", artists: [], artworkURL: nil, duration: 0, progress: 0, link: nil, platform: platform)
        }
        let ownerId = audio["owner_id"] as? Int ?? 0
        let audioId = audio["id"] as? Int ?? 0
        var thumbnail: String?
        if let album = audio["album"] as? [String: Any] {
            let photoKey = album.keys.filter { $0.hasPrefix("photo") }.sorted().last
            if let photoKey {
                thumbnail = album[photoKey] as? String
            }
        }
        return SGNowPlayingTrack(
            isActive: true,
            id: String(audioId),
            title: audio["title"] as? String ?? "No title provided",
            artists: [audio["artist"] as? String ?? "Artist w/out name"],
            artworkURL: thumbnail,
            duration: 0,
            progress: 0,
            link: "https://vk.ru/audio\(ownerId)_\(audioId)",
            platform: platform
        )
    }

    private static func decodeYandex(_ response: [String: Any], platform: SGNowPlayingPlatformId) -> SGNowPlayingTrack? {
        guard let track = response["track"] as? [String: Any] else {
            return nil
        }
        var artists: [String] = []
        if let artistString = track["artist"] as? String {
            artists = artistString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else if let artistList = track["artist"] as? [Any] {
            artists = artistList.compactMap { $0 as? String }
        }
        let trackId: String
        if let intId = track["track_id"] as? Int {
            trackId = String(intId)
        } else {
            trackId = track["track_id"] as? String ?? ""
        }
        return SGNowPlayingTrack(
            isActive: true,
            id: trackId,
            title: track["title"] as? String ?? "",
            artists: artists,
            artworkURL: track["img"] as? String,
            duration: track["duration"] as? Int ?? 0,
            progress: (response["progress_ms"] as? Int ?? 0) / 1000,
            link: trackId.isEmpty ? nil : "https://music.yandex.ru/track/\(trackId)",
            downloadURL: track["download_link"] as? String,
            platform: platform
        )
    }

    private static func decodeSoundCloud(_ response: [String: Any], platform: SGNowPlayingPlatformId) -> SGNowPlayingTrack? {
        guard let collection = (response["collection"] as? [[String: Any]])?.first else {
            return SGNowPlayingTrack(isActive: false, id: "", title: "", artists: [], artworkURL: nil, duration: 0, progress: 0, link: nil, platform: platform)
        }
        guard let track = collection["track"] as? [String: Any] else {
            return SGNowPlayingTrack(isActive: false, id: "", title: "", artists: [], artworkURL: nil, duration: 0, progress: 0, link: nil, platform: platform)
        }
        var artist = (track["publisher_metadata"] as? [String: Any])?["artist"] as? String
        if artist == nil || artist?.isEmpty == true {
            artist = (track["user"] as? [String: Any])?["username"] as? String
        }
        if artist == nil || artist?.isEmpty == true {
            artist = "anonymous_artist"
        }
        // Deviation: reSwaga leaves duration at 0 here; taking the API's value
        // makes the profile playlist entry a sensible length.
        let duration = (track["duration"] as? Int ?? 0) / 1000
        return SGNowPlayingTrack(
            isActive: true,
            id: String(collection["track_id"] as? Int ?? 0),
            title: track["title"] as? String ?? "No title provided",
            artists: [artist ?? ""],
            artworkURL: track["artwork_url"] as? String,
            duration: duration,
            progress: 0,
            link: track["permalink_url"] as? String,
            platform: platform
        )
    }

    private static func decodeYouTubeMusic(_ response: [String: Any], platform: SGNowPlayingPlatformId) -> SGNowPlayingTrack? {
        let inactive = SGNowPlayingTrack(isActive: false, id: "", title: "", artists: [], artworkURL: nil, duration: 0, progress: 0, link: nil, platform: platform)
        guard
            let contents = response["contents"] as? [String: Any],
            let singleColumn = contents["singleColumnBrowseResultsRenderer"] as? [String: Any],
            let tabs = singleColumn["tabs"] as? [[String: Any]],
            let firstTab = tabs.first,
            let tabRenderer = firstTab["tabRenderer"] as? [String: Any],
            let tabContent = tabRenderer["content"] as? [String: Any],
            let sectionList = tabContent["sectionListRenderer"] as? [String: Any],
            let sectionContents = sectionList["contents"] as? [[String: Any]],
            let firstSection = sectionContents.first,
            let shelf = firstSection["musicShelfRenderer"] as? [String: Any],
            let shelfContents = shelf["contents"] as? [[String: Any]],
            let listItem = shelfContents.first,
            let itemRenderer = listItem["musicResponsiveListItemRenderer"] as? [String: Any],
            let flexColumns = itemRenderer["flexColumns"] as? [[String: Any]],
            flexColumns.count >= 2
        else {
            return inactive
        }

        func runsText(_ column: [String: Any]) -> (text: String, videoId: String?) {
            guard
                let textRenderer = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                let text = textRenderer["text"] as? [String: Any],
                let runs = text["runs"] as? [[String: Any]]
            else {
                return ("", nil)
            }
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            var videoId: String?
            if
                let firstRun = runs.first,
                let navigationEndpoint = firstRun["navigationEndpoint"] as? [String: Any],
                let watchEndpoint = navigationEndpoint["watchEndpoint"] as? [String: Any],
                let id = watchEndpoint["videoId"] as? String
            {
                videoId = id
            }
            return (joined, videoId)
        }

        let titleColumn = runsText(flexColumns[0])
        let artistColumn = runsText(flexColumns[1])
        guard let videoId = titleColumn.videoId else {
            return inactive
        }
        var cover: String?
        if
            let thumbnail = itemRenderer["thumbnail"] as? [String: Any],
            let musicThumbnail = thumbnail["musicThumbnailRenderer"] as? [String: Any],
            let thumbs = musicThumbnail["thumbnail"] as? [String: Any],
            let thumbList = thumbs["thumbnails"] as? [[String: Any]],
            let lastThumb = thumbList.last,
            let lastUrl = lastThumb["url"] as? String
        {
            cover = lastUrl
        }
        let artist = artistColumn.text.split(separator: "•").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return SGNowPlayingTrack(
            isActive: true,
            id: videoId,
            title: titleColumn.text,
            artists: artist.isEmpty ? [] : [artist],
            artworkURL: cover,
            duration: 0,
            progress: 0,
            link: "https://music.youtube.com/watch?v=\(videoId)",
            platform: platform
        )
    }
}

// MARK: - Regex helper

enum SGNowPlayingRegex {
    static func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: [String] = []
        for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
            if let captureRange = Range(match.range(at: 1), in: text) {
                result.append(String(text[captureRange]))
            }
        }
        return result
    }

    static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }
}

// MARK: - SHA-1 (pure Swift, used for the YouTube Music SAPISIDHASH header)

enum SGNowPlayingSHA1 {
    static func hexDigest(of input: String) -> String {
        return digest(of: Array(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(of message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        var data = message
        let originalBitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 {
            data.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((originalBitLength >> UInt64(shift)) & 0xFF))
        }

        for chunkStart in stride(from: 0, to: data.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                w[index] = (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
            }
            for index in 16..<80 {
                let value = w[index - 3] ^ w[index - 8] ^ w[index - 14] ^ w[index - 16]
                w[index] = value.rotateLeft(1)
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4

            for index in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch index {
                case 0..<20:
                    f = (b & c) | ((~b) & d)
                    k = 0x5A827999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }
                let temp = a.rotateLeft(5) &+ f &+ e &+ k &+ w[index]
                e = d
                d = c
                c = b.rotateLeft(30)
                b = a
                a = temp
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
        }

        var output: [UInt8] = []
        for value in [h0, h1, h2, h3, h4] {
            output.append(UInt8((value >> 24) & 0xFF))
            output.append(UInt8((value >> 16) & 0xFF))
            output.append(UInt8((value >> 8) & 0xFF))
            output.append(UInt8(value & 0xFF))
        }
        return output
    }
}

private extension UInt32 {
    func rotateLeft(_ amount: UInt32) -> UInt32 {
        return (self << amount) | (self >> (32 - amount))
    }
}
