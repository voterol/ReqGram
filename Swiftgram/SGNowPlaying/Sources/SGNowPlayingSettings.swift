import Foundation

public extension Notification.Name {
    static let sgNowPlayingSettingsDidChange = Notification.Name("sg.nowPlaying.settingsDidChange")
    static let sgNowPlayingPollDidStart = Notification.Name("sg.nowPlaying.pollDidStart")
    static let sgNowPlayingPollDidFinish = Notification.Name("sg.nowPlaying.pollDidFinish")
}

/// Where the current track is streamed to (mirrors reSwaga's stream places).
public enum SGNowPlayingPlace: Int, Codable, CaseIterable {
    case bio = 0
    case playlist = 1
    case location = 2
}

/// Orientation of the "send as card" image (reSwaga's card types 0/1;
/// the "СуперSwaG" variant is intentionally not ported).
public enum SGNowPlayingCardType: Int, Codable, CaseIterable {
    case horizontal = 0
    case vertical = 1

    public var displayKey: String {
        return "ReqGram.Plugin.NowPlaying.Card.Type.\(self == .horizontal ? "Horizontal" : "Vertical")"
    }
}

/// Background style of the send card (reSwaga's settings_background_type_*).
public enum SGNowPlayingCardBackground: Int, Codable, CaseIterable {
    case trackCover = 0
    case accentColor = 1

    public var displayKey: String {
        return "ReqGram.Plugin.NowPlaying.Card.Background.\(self == .trackCover ? "TrackCover" : "AccentColor")"
    }
}

/// Font family of the send card (reSwaga's FONTS registry).
public enum SGNowPlayingCardFont: Int, Codable, CaseIterable {
    case ysMusic = 0
    case onest = 1

    public var displayKey: String {
        return "ReqGram.Plugin.NowPlaying.Card.Font.\(self == .ysMusic ? "YSMusic" : "Onest")"
    }
}

/// How the track link is presented on the send card: a small in-theme QR
/// tile or a plain text line.
public enum SGNowPlayingCardLinkStyle: Int, Codable, CaseIterable {
    case text = 0
    case qrCode = 1

    public var displayKey: String {
        return "ReqGram.Plugin.NowPlaying.Card.LinkStyle.\(self == .text ? "Text" : "QR")"
    }
}

/// Which platform provides the streamed track.
public enum SGNowPlayingSource: Equatable, Hashable {
    case auto
    case platform(SGNowPlayingPlatformId)
}

/// Persisted settings of the Now Playing plugin.
///
/// Stored as a single JSON blob under `sg.nowPlaying.settings` (the same
/// UserDefaults pattern SGScamRegistry uses). Tokens are stored in plaintext
/// defaults exactly like the original plugin stored them in its own settings —
/// treat the device as the security boundary.
public struct SGNowPlayingSettings: Equatable {
    public var isEnabled: Bool
    /// Platform raw value -> token / username / cookie.
    public var tokens: [String: String]
    public var placeRawValue: Int
    public var sourceIsAuto: Bool
    public var sourcePlatformRawValue: String?
    /// Text restored into the profile when nothing is playing.
    public var defaultText: String
    /// `true` once the original bio/location have been captured.
    public var hasStoredDefaults: Bool
    /// `true` while this plugin has actually written profile content (track
    /// text or a saved-music entry) that still needs restoring on stop.
    /// Gates the restore path so a never-used plugin performs no profile writes.
    public var didWriteProfile: Bool
    /// File ids of saved-music entries this plugin created (for cleanup).
    public var playlistFileIds: [Int64]
    /// Send-card customization (reSwaga's card customization settings).
    public var cardTypeRawValue: Int
    public var cardBackgroundRawValue: Int
    public var cardFontRawValue: Int
    public var cardLinkStyleRawValue: Int
    /// Append a cross-platform song.link link to text/card sends.
    public var useSongLink: Bool

    public init(
        isEnabled: Bool = false,
        tokens: [String: String] = [:],
        placeRawValue: Int = SGNowPlayingPlace.bio.rawValue,
        sourceIsAuto: Bool = true,
        sourcePlatformRawValue: String? = nil,
        defaultText: String = "",
        hasStoredDefaults: Bool = false,
        didWriteProfile: Bool = false,
        playlistFileIds: [Int64] = [],
        cardTypeRawValue: Int = SGNowPlayingCardType.horizontal.rawValue,
        cardBackgroundRawValue: Int = SGNowPlayingCardBackground.trackCover.rawValue,
        cardFontRawValue: Int = SGNowPlayingCardFont.ysMusic.rawValue,
        cardLinkStyleRawValue: Int = SGNowPlayingCardLinkStyle.qrCode.rawValue,
        useSongLink: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.tokens = tokens
        self.placeRawValue = placeRawValue
        self.sourceIsAuto = sourceIsAuto
        self.sourcePlatformRawValue = sourcePlatformRawValue
        self.defaultText = defaultText
        self.hasStoredDefaults = hasStoredDefaults
        self.didWriteProfile = didWriteProfile
        self.playlistFileIds = playlistFileIds
        self.cardTypeRawValue = cardTypeRawValue
        self.cardBackgroundRawValue = cardBackgroundRawValue
        self.cardFontRawValue = cardFontRawValue
        self.cardLinkStyleRawValue = cardLinkStyleRawValue
        self.useSongLink = useSongLink
    }

    public var place: SGNowPlayingPlace {
        get {
            return SGNowPlayingPlace(rawValue: self.placeRawValue) ?? .bio
        }
        set {
            self.placeRawValue = newValue.rawValue
        }
    }

    public var source: SGNowPlayingSource {
        get {
            if self.sourceIsAuto {
                return .auto
            } else if let raw = self.sourcePlatformRawValue, let platform = SGNowPlayingPlatformId(rawValue: raw) {
                return .platform(platform)
            } else {
                return .auto
            }
        }
        set {
            switch newValue {
            case .auto:
                self.sourceIsAuto = true
                self.sourcePlatformRawValue = nil
            case let .platform(platform):
                self.sourceIsAuto = false
                self.sourcePlatformRawValue = platform.rawValue
            }
        }
    }

    public func token(for platform: SGNowPlayingPlatformId) -> String? {
        guard let value = self.tokens[platform.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    public var configuredPlatforms: [SGNowPlayingPlatformId] {
        return SGNowPlayingPlatformId.allCases.filter { self.token(for: $0) != nil }
    }

    public var cardType: SGNowPlayingCardType {
        get { return SGNowPlayingCardType(rawValue: self.cardTypeRawValue) ?? .horizontal }
        set { self.cardTypeRawValue = newValue.rawValue }
    }

    public var cardBackground: SGNowPlayingCardBackground {
        get { return SGNowPlayingCardBackground(rawValue: self.cardBackgroundRawValue) ?? .trackCover }
        set { self.cardBackgroundRawValue = newValue.rawValue }
    }

    public var cardFont: SGNowPlayingCardFont {
        get { return SGNowPlayingCardFont(rawValue: self.cardFontRawValue) ?? .ysMusic }
        set { self.cardFontRawValue = newValue.rawValue }
    }

    public var cardLinkStyle: SGNowPlayingCardLinkStyle {
        get { return SGNowPlayingCardLinkStyle(rawValue: self.cardLinkStyleRawValue) ?? .qrCode }
        set { self.cardLinkStyleRawValue = newValue.rawValue }
    }
}

extension SGNowPlayingSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case tokens
        case placeRawValue
        case sourceIsAuto
        case sourcePlatformRawValue
        case defaultText
        case hasStoredDefaults
        case didWriteProfile
        case playlistFileIds
        case cardTypeRawValue
        case cardBackgroundRawValue
        case cardFontRawValue
        case cardLinkStyleRawValue
        case useSongLink
    }

    /// Tolerant decoding: every missing key falls back to the default, so older
    /// blobs keep decoding after new fields are added.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            tokens: try container.decodeIfPresent([String: String].self, forKey: .tokens) ?? [:],
            placeRawValue: try container.decodeIfPresent(Int.self, forKey: .placeRawValue) ?? SGNowPlayingPlace.bio.rawValue,
            sourceIsAuto: try container.decodeIfPresent(Bool.self, forKey: .sourceIsAuto) ?? true,
            sourcePlatformRawValue: try container.decodeIfPresent(String.self, forKey: .sourcePlatformRawValue),
            defaultText: try container.decodeIfPresent(String.self, forKey: .defaultText) ?? "",
            hasStoredDefaults: try container.decodeIfPresent(Bool.self, forKey: .hasStoredDefaults) ?? false,
            didWriteProfile: try container.decodeIfPresent(Bool.self, forKey: .didWriteProfile) ?? false,
            playlistFileIds: try container.decodeIfPresent([Int64].self, forKey: .playlistFileIds) ?? [],
            cardTypeRawValue: try container.decodeIfPresent(Int.self, forKey: .cardTypeRawValue) ?? SGNowPlayingCardType.horizontal.rawValue,
            cardBackgroundRawValue: try container.decodeIfPresent(Int.self, forKey: .cardBackgroundRawValue) ?? SGNowPlayingCardBackground.trackCover.rawValue,
            cardFontRawValue: try container.decodeIfPresent(Int.self, forKey: .cardFontRawValue) ?? SGNowPlayingCardFont.ysMusic.rawValue,
            cardLinkStyleRawValue: try container.decodeIfPresent(Int.self, forKey: .cardLinkStyleRawValue) ?? SGNowPlayingCardLinkStyle.qrCode.rawValue,
            useSongLink: try container.decodeIfPresent(Bool.self, forKey: .useSongLink) ?? true
        )
    }

    public static func load(from defaults: UserDefaults = .standard) -> SGNowPlayingSettings {
        guard let data = defaults.data(forKey: SGNowPlayingSettings.settingsKey) else {
            return SGNowPlayingSettings()
        }
        if let settings = try? JSONDecoder().decode(SGNowPlayingSettings.self, from: data) {
            return settings
        }
        return SGNowPlayingSettings()
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: SGNowPlayingSettings.settingsKey)
        }
    }

    private static let settingsKey = "sg.nowPlaying.settings"
    private static let statusKey = "sg.nowPlaying.status"

    public static func loadStatus(from defaults: UserDefaults = .standard) -> String {
        return defaults.string(forKey: SGNowPlayingSettings.statusKey) ?? ""
    }

    public static func saveStatus(_ status: String, to defaults: UserDefaults = .standard) {
        defaults.set(status, forKey: SGNowPlayingSettings.statusKey)
    }
}
