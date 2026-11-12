import Foundation

/// Data model of the "Now Playing" collector (native port of the reSwaga plugin's
/// track fetching / profile streaming functionality; visual design intentionally
/// not ported).

/// Music platforms supported for now-playing polling.
///
/// Token semantics (identical to reSwaga):
/// - `spotify`: stats.fm **username**
/// - `vkMusic`: VK API **access token**
/// - `lastFm`: Last.fm **username**
/// - `soundCloud`: SoundCloud **OAuth token**
/// - `yandexMusic`: Yandex Music **ya-token**
/// - `youTubeMusic`: raw **cookie string** (SAPISID extracted from it)
public enum SGNowPlayingPlatformId: String, CaseIterable, Codable, Hashable {
    case spotify = "spotify"
    case vkMusic = "vk_music"
    case lastFm = "last_fm"
    case soundCloud = "soundcloud"
    case yandexMusic = "yandex_music"
    case youTubeMusic = "youtube_music"

    /// Priority used by the `auto` stream source. Copied from reSwaga
    /// (`_get_track_from_priority`): the base order is the platform enum order with
    /// SoundCloud, Yandex and YouTube Music moved to the end, which resolves to
    /// [Spotify, VK, Last.fm, SoundCloud, Yandex, YouTube Music]; first active track wins.
    public static let autoPriority: [SGNowPlayingPlatformId] = [.spotify, .vkMusic, .lastFm, .soundCloud, .yandexMusic, .youTubeMusic]

    /// song.link platform code, used to build cross-platform links.
    public var songLinkCode: String? {
        switch self {
        case .spotify:
            return "s"
        case .yandexMusic:
            return "ya"
        case .vkMusic:
            return "vk"
        case .soundCloud:
            return "sc"
        case .youTubeMusic:
            return "y"
        case .lastFm:
            return nil
        }
    }

    public var displayKey: String {
        return "ReqGram.Plugin.NowPlaying.Platform.\(self.rawValue)"
    }
}

/// A single now-playing snapshot for one platform.
///
/// Equality mirrors reSwaga's `Track.__eq__` (id + active only), so a progress
/// update for the same playing track does not count as a change.
public struct SGNowPlayingTrack: Equatable {
    public var isActive: Bool
    public var id: String
    public var title: String
    public var artists: [String]
    public var artworkURL: String?
    public var duration: Int
    public var progress: Int
    public var link: String?
    public var downloadURL: String?
    public var platform: SGNowPlayingPlatformId?

    public init(
        isActive: Bool,
        id: String,
        title: String,
        artists: [String],
        artworkURL: String?,
        duration: Int,
        progress: Int,
        link: String?,
        downloadURL: String? = nil,
        platform: SGNowPlayingPlatformId? = nil
    ) {
        self.isActive = isActive
        self.id = id
        self.title = title
        self.artists = artists
        self.artworkURL = artworkURL
        self.duration = duration
        self.progress = progress
        self.link = link
        self.downloadURL = downloadURL
        self.platform = platform
    }

    public static func == (lhs: SGNowPlayingTrack, rhs: SGNowPlayingTrack) -> Bool {
        return lhs.id == rhs.id && lhs.isActive == rhs.isActive
    }

    public var artistText: String {
        return self.artists.joined(separator: ", ")
    }

    /// reSwaga renders a track as `"{title} — {complete_artist}"` (em dash).
    public var displayText: String {
        return "\(self.title) — \(self.artistText)"
    }
}
