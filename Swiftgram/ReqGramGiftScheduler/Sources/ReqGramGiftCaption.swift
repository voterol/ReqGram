import Foundation
import TelegramCore
import TextFormat

/// Converts a composed caption into the persisted representation, and back.
///
/// This file is the whole point of the iOS port. The Android plugin lost custom
/// emoji for three compounding reasons, all of which are avoided here:
///
/// * it hardcoded the invoice entity list to an empty `ArrayList`;
/// * it flattened the input `Spannable` with `str(text)`, discarding every
///   `AnimatedEmojiSpan` document id;
/// * its persisted task schema had no entities field, so even a correct capture
///   could not survive until the send moment.
///
/// On iOS the caption is captured as an `NSAttributedString`, converted with
/// `generateChatInputTextEntities` (which handles
/// `ChatTextInputAttributes.customEmoji`), persisted with UTF-16 offsets, and
/// replayed into `BotPaymentInvoiceSource.starGift(... entities:)`.
public enum ReqGramGiftCaption {
    /// Result of capturing a caption, after cap enforcement.
    public struct Captured: Equatable {
        public var text: String
        public var entities: [ReqGramGiftTask.Entity]
        /// True when the caption was longer than the configured cap and was
        /// trimmed. Callers surface this rather than silently losing content.
        public var wasTruncated: Bool

        public init(text: String, entities: [ReqGramGiftTask.Entity], wasTruncated: Bool) {
            self.text = text
            self.entities = entities
            self.wasTruncated = wasTruncated
        }
    }

    /// Captures an attributed caption into persistable form.
    ///
    /// `maxLength` must come from the app config value
    /// `stargifts_message_length_max`, never a hardcoded 255.
    public static func capture(_ attributedText: NSAttributedString, maxLength: Int) -> Captured {
        let engineEntities = generateChatInputTextEntities(attributedText)
        return self.capture(text: attributedText.string, engineEntities: engineEntities, maxLength: maxLength)
    }

    /// Capture path for callers that already hold engine entities (for example
    /// the gift composer, which generates them for its own send flow).
    public static func capture(text: String, engineEntities: [MessageTextEntity], maxLength: Int) -> Captured {
        let mapped = self.map(engineEntities: engineEntities)
        return self.clamp(text: text, entities: mapped, maxLength: maxLength)
    }

    /// Maps engine entities onto the persisted subset.
    ///
    /// Engine `MessageTextEntity.range` is expressed in UTF-16 code units for
    /// text produced by `generateChatInputTextEntities`, which enumerates
    /// `NSAttributedString` ranges. The offsets are therefore stored as-is.
    private static func map(engineEntities: [MessageTextEntity]) -> [ReqGramGiftTask.Entity] {
        var result: [ReqGramGiftTask.Entity] = []
        for entity in engineEntities {
            let kind: ReqGramGiftTask.Entity.Kind
            var documentId: Int64?
            switch entity.type {
            case let .CustomEmoji(_, fileId):
                kind = .customEmoji
                documentId = fileId
            case .Bold:
                kind = .bold
            case .Italic:
                kind = .italic
            case .Code:
                kind = .monospace
            case .Strikethrough:
                kind = .strikethrough
            case .Underline:
                kind = .underline
            case .Spoiler:
                kind = .spoiler
            default:
                // Gift captions do not carry links, mentions, quotes or
                // pre-blocks. Dropping them here is intentional and matches
                // what the server accepts for a star-gift message.
                continue
            }
            result.append(ReqGramGiftTask.Entity(
                offset: entity.range.lowerBound,
                length: entity.range.count,
                kind: kind,
                documentId: documentId
            ))
        }
        return result
    }

    /// Enforces the caption cap without corrupting entity offsets.
    ///
    /// Truncation is done on UTF-16 code units because that is the unit the
    /// entity offsets use. The cut point is additionally pulled back off any
    /// composed character sequence or surrogate pair boundary, so a trimmed
    /// caption never ends in half an emoji. Entities that fall entirely outside
    /// the retained text are dropped; entities that straddle the boundary are
    /// clamped, and a custom emoji is dropped outright rather than clamped,
    /// since a partial custom emoji range is not meaningful.
    private static func clamp(text: String, entities: [ReqGramGiftTask.Entity], maxLength: Int) -> Captured {
        let nsText = text as NSString
        let fullLength = nsText.length
        guard maxLength > 0 else {
            return Captured(text: "", entities: [], wasTruncated: fullLength > 0)
        }
        var retained = fullLength
        var wasTruncated = false
        if fullLength > maxLength {
            wasTruncated = true
            // Pull the cut back to a character-sequence boundary so we never
            // split a surrogate pair or a ZWJ emoji cluster.
            let boundaryRange = nsText.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: maxLength))
            retained = boundaryRange.length
            if retained > maxLength {
                // The boundary expansion would exceed the cap; step back to the
                // start of the straddling cluster instead.
                let clusterStart = nsText.rangeOfComposedCharacterSequence(at: maxLength).location
                retained = min(clusterStart, maxLength)
            }
        }
        let clampedText = retained >= fullLength ? text : nsText.substring(to: retained)

        var clampedEntities: [ReqGramGiftTask.Entity] = []
        for entity in entities {
            guard entity.length > 0, entity.offset >= 0, entity.offset < retained else {
                continue
            }
            let end = entity.offset + entity.length
            if end <= retained {
                clampedEntities.append(entity)
                continue
            }
            // Straddles the cut.
            if case .customEmoji = entity.kind {
                // A clipped custom emoji range would not render; drop it.
                continue
            }
            var trimmed = entity
            trimmed.length = retained - entity.offset
            if trimmed.length > 0 {
                clampedEntities.append(trimmed)
            }
        }

        return Captured(text: clampedText, entities: clampedEntities, wasTruncated: wasTruncated)
    }

    /// Reads the caption cap from the app configuration.
    ///
    /// Mirrors `GiftConfiguration.with(appConfiguration:)` in GiftSetupScreen so
    /// the scheduler and the native composer agree on the limit.
    public static func maxCaptionLength(appConfiguration: AppConfiguration) -> Int {
        if let data = appConfiguration.data, let value = data["stargifts_message_length_max"] as? Double {
            let intValue = Int(value)
            if intValue > 0 {
                return intValue
            }
        }
        return 255
    }
}
