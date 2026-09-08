import Foundation
import UIKit
import Postbox
import TelegramCore
import AyuGram
import SGSimpleSettings
import SGStrings

/// MARK: AyuGram
/// Shared helpers for rendering AyuGram's remote-config badges next to peer
/// titles, and for honouring the `hidePremiumStatuses` setting.
///
public enum AyuBadges {
    /// Defense-in-depth boundary for all project badge providers combined.
    /// Individual surfaces may display fewer badges when horizontal space is
    /// constrained and expose the remainder through an overflow control.
    public static let maximumRenderedBadgeCount = 16

    /// Bare id used by the remote config, which stores plain positive ids for
    /// users and channels alike.
    public static func bareId(_ peerId: EnginePeer.Id) -> Int64 {
        return peerId.id._internalGetInt64Value()
    }

    /// Resolves the AyuGram badge for a peer, if the peer has one.
    public static func badge(for peerId: EnginePeer.Id) -> AyuBadgeKind? {
        return self.badges(for: peerId).first
    }

    /// Resolves every grant supplied by the current AyuGram remote-config
    /// provider. Additional providers should contribute their own issuer-tagged
    /// descriptors in `emojiStatusContents` rather than reusing this transport.
    public static func badges(for peerId: EnginePeer.Id) -> [AyuBadgeKind] {
        guard let peer = self.remotePeer(peerId) else { return [] }
        return AyuRemoteConfig.shared.badges(for: peer).map(\.kind)
    }

    /// Emoji-status content for an AyuGram badge, or `nil` when the peer has
    /// none or the badge cannot be rendered as an emoji.
    ///
    /// Developer and supporter badges reuse the verified checkmark so they read
    /// as a project mark rather than as an official Telegram verification of a
    /// different kind; only custom badges carry a distinct emoji.
    public static func emojiStatusContents(
        for peerId: EnginePeer.Id,
        placeholderColor: UIColor,
        themeColor: UIColor?
    ) -> [AyuBadgeContent] {
        var result: [AyuBadgeContent] = []
        guard let peer = self.remotePeer(peerId) else { return [] }
        for badge in AyuRemoteConfig.shared.badges(for: peer) {
            let content: AyuBadgeContent
            switch badge.kind {
            case let .custom(custom):
                content = AyuBadgeContent(issuer: AyuBadgeIssuer(badge.source), assignmentId: badge.assignmentId, kind: badge.kind, customEmojiFileId: custom.documentId, title: badge.title, text: badge.text)
            default:
                content = AyuBadgeContent(issuer: AyuBadgeIssuer(badge.source), assignmentId: badge.assignmentId, kind: badge.kind, customEmojiFileId: badge.documentId, title: badge.title, text: badge.text)
            }
            result.append(content)
        }
        return result
    }

    private static func remotePeer(_ peerId: EnginePeer.Id) -> AyuBadgePeer? {
        let type: AyuBadgePeerType
        switch peerId.namespace {
        case Namespaces.Peer.CloudUser: type = .user
        case Namespaces.Peer.CloudGroup: type = .group
        case Namespaces.Peer.CloudChannel: type = .channel
        default: return nil
        }
        return AyuBadgePeer(type: type, id: bareId(peerId))
    }

    /// Compatibility convenience for the existing one-slot chat-list/profile
    /// paths. New title paths consume the bounded descriptor collection.
    public static func emojiStatusContent(
        for peerId: EnginePeer.Id,
        placeholderColor: UIColor,
        themeColor: UIColor?
    ) -> AyuBadgeContent? {
        return self.emojiStatusContents(
            for: peerId,
            placeholderColor: placeholderColor,
            themeColor: themeColor
        ).first
    }

    public static func explanation(for content: AyuBadgeContent, peerName: String, languageCode: String) -> (title: String, text: String) {
        let name = self.nonemptyDisplayTitle(peerName, languageCode: languageCode)
        switch content.kind {
        case let .custom(custom):
            if content.issuer == .exteraGram {
                return (content.title ?? i18n("AyuGram.RemoteConfig.Badge.ExteraGram.Custom", languageCode), custom.text ?? content.text ?? SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.ExteraGram.Custom.Info", languageCode, args: name))
            }
            return (
                content.title ?? i18n("AyuGram.RemoteConfig.Badge.Custom", languageCode),
                custom.text ?? content.text ?? SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.Custom.Info", languageCode, args: name)
            )
        case .developer:
            if content.issuer == .exteraGram {
                return (content.title ?? i18n("AyuGram.RemoteConfig.Badge.ExteraGram.Developer", languageCode), content.text ?? SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.ExteraGram.Developer.Info", languageCode, args: name))
            }
            return (
                content.title ?? (content.issuer == .reqGram ? i18n("AyuGram.RemoteConfig.Badge.Developer", languageCode) : i18n("AyuGram.RemoteConfig.Badge.CompatibleDeveloper", languageCode)),
                content.text ?? SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.Developer.Info", languageCode, args: name)
            )
        case .supporter:
            switch content.issuer {
            case .reqGram:
                return (content.title ?? i18n("AyuGram.RemoteConfig.Badge.Supporter", languageCode), content.text ?? SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.Supporter.Info", languageCode, args: name))
            case .ayuGram:
                return (content.title ?? i18n("AyuGram.RemoteConfig.Badge.AyuGram.Supporter", languageCode), content.text ?? SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.AyuGram.Supporter.Info", languageCode, args: name))
            case .exteraGram:
                return (content.title ?? i18n("AyuGram.RemoteConfig.Badge.ExteraGram.Supporter", languageCode), content.text ?? SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.ExteraGram.Supporter.Info", languageCode, args: name))
            }
        case .owner:
            if content.issuer == .exteraGram {
                return (content.title ?? i18n("AyuGram.RemoteConfig.Badge.ExteraGram.Owner", languageCode), content.text ?? SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.ExteraGram.Owner.Info", languageCode, args: name))
            }
            return (content.title ?? (content.issuer == .reqGram ? i18n("AyuGram.RemoteConfig.Badge.Owner", languageCode) : i18n("AyuGram.RemoteConfig.Badge.CompatibleOwner", languageCode)), content.text ?? SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.Owner.Info", languageCode, args: name))
        case .official:
            if content.issuer == .exteraGram {
                return (content.title ?? i18n("AyuGram.RemoteConfig.Badge.ExteraGram.Official", languageCode), content.text ?? SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.ExteraGram.Official.Info", languageCode, args: name))
            }
            return (content.title ?? (content.issuer == .reqGram ? i18n("AyuGram.RemoteConfig.Badge.Official", languageCode) : i18n("AyuGram.RemoteConfig.Badge.CompatibleOfficial", languageCode)), content.text ?? SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.Official.Info", languageCode, args: name))
        case .team:
            if content.issuer == .exteraGram {
                return (content.title ?? i18n("AyuGram.RemoteConfig.Badge.ExteraGram.Team", languageCode), content.text ?? SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.ExteraGram.Team.Info", languageCode, args: name))
            }
            return (content.title ?? (content.issuer == .reqGram ? i18n("AyuGram.RemoteConfig.Badge.Team", languageCode) : i18n("AyuGram.RemoteConfig.Badge.CompatibleDeveloper", languageCode)), content.text ?? SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.Team.Info", languageCode, args: name))
        case .sponsor:
            switch content.issuer {
            case .reqGram:
                return (content.title ?? i18n("AyuGram.RemoteConfig.Badge.Sponsor", languageCode), content.text ?? SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.Sponsor.Info", languageCode, args: name))
            case .ayuGram:
                return (content.title ?? i18n("AyuGram.RemoteConfig.Badge.AyuGram.Supporter", languageCode), content.text ?? SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.AyuGram.Supporter.Info", languageCode, args: name))
            case .exteraGram:
                return (content.title ?? i18n("AyuGram.RemoteConfig.Badge.ExteraGram.Supporter", languageCode), content.text ?? SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.ExteraGram.Supporter.Info", languageCode, args: name))
            }
        }
    }

    /// Normalizes titles crossing optional Objective-C/Swift UI boundaries.
    /// In addition to an empty value, some legacy interpolation paths can
    /// surface Optional.none as the literal strings "(null)" or "nil".
    public static func nonemptyDisplayTitle(_ title: String?, languageCode: String) -> String {
        if let title {
            let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && value.caseInsensitiveCompare("(null)") != .orderedSame && value.caseInsensitiveCompare("nil") != .orderedSame {
                return value
            }
        }
        return i18n("AyuGram.RemoteConfig.Badge.PeerFallback", languageCode)
    }

    /// Whether Telegram's own premium emoji status should be suppressed.
    public static var hidePremiumStatuses: Bool {
        return SGSimpleSettings.shared.ayuHidePremiumStatuses
    }
}

/// Project that issued a badge. Transport fallback is deliberately not used to
/// infer this value: fetching AyuGram data through an exteraGram-compatible
/// endpoint does not make the grant an exteraGram badge.
public enum AyuBadgeIssuer: String, Equatable, Hashable {
    case ayuGram
    case exteraGram
    case reqGram
}

public extension AyuBadgeIssuer {
    var displayName: String {
        switch self {
        case .reqGram: return "ReqGram"
        case .ayuGram: return "AyuGram"
        case .exteraGram: return "exteraGram"
        }
    }

    var fallbackGlyph: String {
        switch self {
        case .reqGram, .ayuGram, .exteraGram: return "R"
        }
    }

    func displayName(languageCode: String) -> String {
        switch self {
        case .reqGram: return "ReqGram"
        case .ayuGram: return "AyuGram · \(i18n("AyuGram.RemoteConfig.Badge.CompatibleFamily", languageCode))"
        case .exteraGram: return "exteraGram"
        }
    }
}

private extension AyuBadgeIssuer {
    init(_ source: AyuBadgeSource) {
        switch source { case .reqGram: self = .reqGram; case .ayuGram: self = .ayuGram; case .exteraGram: self = .exteraGram }
    }
}

/// Resolved badge payload for the UI layer.
public struct AyuBadgeContent: Equatable {
    public struct Id: Equatable, Hashable {
        public enum Role: String, Equatable, Hashable {
            case custom
            case owner
            case official
            case team
            case developer
            case sponsor
            case supporter
        }

        public let issuer: AyuBadgeIssuer
        public let role: Role
        public let customEmojiFileId: Int64?
        public let assignmentId: String?

        public init(issuer: AyuBadgeIssuer, role: Role, customEmojiFileId: Int64?, assignmentId: String? = nil) {
            self.issuer = issuer
            self.role = role
            self.customEmojiFileId = customEmojiFileId
            self.assignmentId = assignmentId
        }
    }

    public let id: Id
    public let issuer: AyuBadgeIssuer
    public let kind: AyuBadgeKind
    /// Custom emoji document id, when the badge has a distinct glyph.
    public let customEmojiFileId: Int64?
    /// Optional label shown when the badge is tapped.
    public let text: String?
    public let title: String?

    public init(issuer: AyuBadgeIssuer = .ayuGram, assignmentId: String? = nil, kind: AyuBadgeKind, customEmojiFileId: Int64?, title: String? = nil, text: String?) {
        let role: Id.Role
        switch kind {
        case .custom:
            role = .custom
        case .owner:
            role = .owner
        case .official:
            role = .official
        case .team:
            role = .team
        case .developer:
            role = .developer
        case .sponsor:
            role = .sponsor
        case .supporter:
            role = .supporter
        }
        self.id = Id(issuer: issuer, role: role, customEmojiFileId: customEmojiFileId, assignmentId: assignmentId)
        self.issuer = issuer
        self.kind = kind
        self.customEmojiFileId = customEmojiFileId
        self.text = text
        self.title = title
    }
}
