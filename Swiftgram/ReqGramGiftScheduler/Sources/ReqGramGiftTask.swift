import Foundation
import Postbox
import TelegramCore

/// Persisted model for the "Gift Scheduler" built-in plugin.
///
/// Ported from the Android plugin, with three deliberate schema corrections:
///
/// 1. `entities` exists. The Android schema had no entities field at all, so
///    custom emoji in the caption could never survive a round-trip.
/// 2. `recipientPeerId` is a typed `EnginePeer.Id`, not a numeric string. The
///    Android original round-tripped the recipient through a decimal string and
///    then had to re-resolve it, which produced PEER_ID_INVALID whenever the
///    peer was not already cached.
/// 3. `giftFileId` persists only the document id. `TelegramMediaFile` is
///    resolved lazily for previews and is never written to disk.
public struct ReqGramGiftTask: Codable, Equatable {
    /// Lifecycle states. Semantics are preserved exactly from the original:
    /// a task in `sending` has passed the point where cancellation is safe,
    /// and `missed` is a terminal state reached when the app was not running
    /// within the grace window.
    public enum Status: String, Codable, Equatable {
        case pending
        case sending
        case sent
        case failed
        case missed
    }

    /// A caption entity, persisted with UTF-16 offsets.
    ///
    /// Only the subset the gift caption can carry is modelled. `documentId` is
    /// the custom emoji document id; a nil `documentId` means a plain styled
    /// range.
    public struct Entity: Codable, Equatable {
        public enum Kind: String, Codable, Equatable {
            case customEmoji
            case bold
            case italic
            case monospace
            case strikethrough
            case underline
            case spoiler
        }

        /// UTF-16 code-unit offset into `ReqGramGiftTask.text`.
        public var offset: Int
        /// Length in UTF-16 code units.
        public var length: Int
        public var kind: Kind
        /// Custom emoji document id. Set only when `kind == .customEmoji`.
        public var documentId: Int64?

        public init(offset: Int, length: Int, kind: Kind, documentId: Int64?) {
            self.offset = offset
            self.length = length
            self.kind = kind
            self.documentId = documentId
        }
    }

    public var id: Int64
    /// Unix timestamp of the requested delivery moment.
    public var when: Double
    public var recipientPeerId: EnginePeer.Id
    public var giftId: Int64
    /// Human-readable gift title, captured at schedule time for list display.
    public var label: String
    public var stars: Int64
    /// Document id of the gift sticker, for lazy preview resolution.
    public var giftFileId: Int64?
    public var text: String
    public var entities: [Entity]
    public var hide: Bool
    /// `includeUpgrade` is persisted but defaults to false, matching the
    /// original plugin, which never offered the upgrade option.
    public var includeUpgrade: Bool
    /// Account that scheduled the task; tasks are only ever evaluated by the
    /// account that created them.
    public var accountId: Int64
    public var status: Status
    public var error: String
    /// Earliest timestamp at which a retry may be attempted.
    public var nextTry: Double
    public var sentAt: Double?

    public init(
        id: Int64,
        when: Double,
        recipientPeerId: EnginePeer.Id,
        giftId: Int64,
        label: String,
        stars: Int64,
        giftFileId: Int64?,
        text: String,
        entities: [Entity],
        hide: Bool,
        includeUpgrade: Bool,
        accountId: Int64,
        status: Status,
        error: String,
        nextTry: Double,
        sentAt: Double?
    ) {
        self.id = id
        self.when = when
        self.recipientPeerId = recipientPeerId
        self.giftId = giftId
        self.label = label
        self.stars = stars
        self.giftFileId = giftFileId
        self.text = text
        self.entities = entities
        self.hide = hide
        self.includeUpgrade = includeUpgrade
        self.accountId = accountId
        self.status = status
        self.error = error
        self.nextTry = nextTry
        self.sentAt = sentAt
    }

    /// A task may be cancelled only while still `pending`. Once it reaches
    /// `sending` a payment request may already be in flight, so the original's
    /// refusal to cancel is preserved.
    public var isCancellable: Bool {
        return self.status == .pending
    }
}

public extension ReqGramGiftTask {
    /// Decodes persisted entities back into engine entities.
    ///
    /// This is the read side of the custom emoji fix: `.CustomEmoji` is
    /// reconstructed with the persisted `documentId`, so an animated emoji
    /// scheduled days earlier still sends as an animated emoji.
    var messageTextEntities: [MessageTextEntity] {
        let utf16Count = (self.text as NSString).length
        var result: [MessageTextEntity] = []
        for entity in self.entities {
            // Defensive clamp: never hand the engine a range outside the text.
            guard entity.length > 0, entity.offset >= 0, entity.offset < utf16Count else {
                continue
            }
            let upper = min(entity.offset + entity.length, utf16Count)
            guard upper > entity.offset else {
                continue
            }
            let range = entity.offset ..< upper
            let type: MessageTextEntityType
            switch entity.kind {
            case .customEmoji:
                guard let documentId = entity.documentId else {
                    continue
                }
                type = .CustomEmoji(stickerPack: nil, fileId: documentId)
            case .bold:
                type = .Bold
            case .italic:
                type = .Italic
            case .monospace:
                type = .Code
            case .strikethrough:
                type = .Strikethrough
            case .underline:
                type = .Underline
            case .spoiler:
                type = .Spoiler
            }
            result.append(MessageTextEntity(range: range, type: type))
        }
        return result
    }

    /// Document ids of every custom emoji in the caption. Used to re-validate
    /// premium availability at send time and to resolve previews.
    var customEmojiFileIds: [Int64] {
        return self.entities.compactMap { entity in
            guard case .customEmoji = entity.kind else {
                return nil
            }
            return entity.documentId
        }
    }

    var hasCustomEmoji: Bool {
        return !self.customEmojiFileIds.isEmpty
    }
}
