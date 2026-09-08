import Foundation
import AccountContext

/// Matches Spotify web links so they can be handed to the native app.
///
/// Ported from AyuGram's `TryHandleSpotify`. The identifier may contain nested
/// segments (`user/<id>/playlist/<id>`), which become colon-separated in the
/// `spotify:` URI form.
private let ayuSpotifyRegex = try? NSRegularExpression(
    pattern: "^(?:https?://)?(?:[a-zA-Z0-9_-]+\\.)?spotify\\.com/(?:intl-[a-zA-Z-]+/)?(track|album|artist|user|playlist|show|episode)/([a-zA-Z0-9_/-]+?)(?:\\?.*)?$",
    options: [.caseInsensitive]
)

/// Converts a Spotify web URL into its `spotify:` app URI, or `nil` if the URL
/// is not a recognised Spotify link.
func ayuSpotifyAppURI(for url: URL) -> String? {
    let absolute = url.absoluteString
    // Cheap pre-filter so the regex only runs on plausible candidates.
    guard absolute.lowercased().contains("spotify.com") else { return nil }
    guard let regex = ayuSpotifyRegex else { return nil }

    let range = NSRange(absolute.startIndex ..< absolute.endIndex, in: absolute)
    guard let match = regex.firstMatch(in: absolute, options: [], range: range), match.numberOfRanges >= 3 else {
        return nil
    }
    guard let typeRange = Range(match.range(at: 1), in: absolute),
          let identifierRange = Range(match.range(at: 2), in: absolute) else {
        return nil
    }

    let type = String(absolute[typeRange]).lowercased()
    let identifier = String(absolute[identifierRange]).replacingOccurrences(of: "/", with: ":")
    guard !identifier.isEmpty else { return nil }
    return "spotify:\(type):\(identifier)"
}

/// Opens a Spotify link in the native app when it is installed.
///
/// - Returns: `true` when the link was handed off, so the caller must stop
///   processing. `false` leaves the URL to normal handling, which matters when
///   Spotify is not installed — otherwise the link would silently do nothing.
func ayuTryHandleSpotify(_ url: URL, applicationBindings: TelegramApplicationBindings) -> Bool {
    guard let appURI = ayuSpotifyAppURI(for: url) else { return false }
    guard applicationBindings.canOpenUrl(appURI) else { return false }
    applicationBindings.openUrl(appURI)
    return true
}
