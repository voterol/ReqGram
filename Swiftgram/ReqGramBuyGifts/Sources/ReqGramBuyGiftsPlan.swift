import Foundation
import TelegramCore
import AccountContext

/// Everything needed to describe one "Buy Gifts" bulk-send request before it is
/// committed. Built by the caller (GiftSetupScreen) from the already-resolved,
/// server-recognized `StarGift.Gift` the user picked in the normal catalog flow.
/// There is deliberately no path here that invents a gift id: every unit sent by
/// `ReqGramBuyGiftsEngine` is the exact same real gift already validated by the
/// native gift-selection screen.
public struct ReqGramBuyGiftsRequest {
    public var giftId: Int64
    public var hideName: Bool
    public var includeUpgrade: Bool
    public var text: String?
    public var entities: [MessageTextEntity]?
    /// Price of ONE unit of this gift (including upgrade stars if requested),
    /// as already computed by the normal composer. Not re-derived here so the
    /// confirmation total can never drift from what the composer displayed.
    public var unitPrice: Int64
    /// Deduplicated recipient list, already capped to the configured maximum.
    public var recipients: [EnginePeer.Id]
    /// Quantity sent to EACH recipient. Already clamped to the real gift's own
    /// `limited`/`limitedPerUser` remaining counts by the caller.
    public var quantityPerRecipient: Int

    public init(
        giftId: Int64,
        hideName: Bool,
        includeUpgrade: Bool,
        text: String?,
        entities: [MessageTextEntity]?,
        unitPrice: Int64,
        recipients: [EnginePeer.Id],
        quantityPerRecipient: Int
    ) {
        self.giftId = giftId
        self.hideName = hideName
        self.includeUpgrade = includeUpgrade
        self.text = text
        self.entities = entities
        self.unitPrice = unitPrice
        self.recipients = recipients
        self.quantityPerRecipient = max(1, quantityPerRecipient)
    }

    /// Total number of individual gift sends this request will perform.
    public var totalUnits: Int {
        return self.recipients.count * self.quantityPerRecipient
    }

    /// Total stars this request will spend if every send succeeds.
    public var totalPrice: Int64 {
        return self.unitPrice * Int64(self.totalUnits)
    }
}

/// Pure helpers for bounding user input before a `ReqGramBuyGiftsRequest` is
/// built. Kept free of any UI or network so they can be unit-tested and reused
/// identically by the settings screen and the gift composer.
public enum ReqGramBuyGiftsLimits {
    /// Hard ceiling mirroring the Android original's `_MAX_QUANTITY_CEILING`,
    /// applied regardless of the user's configured "max recipients" setting.
    public static let absoluteMaxRecipients = 500

    /// Default list of selectable send-delay values, in milliseconds, offered
    /// by the settings UI. Mirrors the Android original's `_CFG_DELAY_STEPS`
    /// (trimmed to the range this fork exposes).
    public static let delayStepsMs: [Int] = [0, 100, 200, 350, 500, 750, 1000, 1500, 2000, 3000, 5000]

    /// Default list of selectable "max recipients per batch" values offered by
    /// the settings UI. Mirrors the Android original's `_CFG_MAX_QUANTITY_STEPS`
    /// but scaled down: on iOS this bounds recipients, not raw quantity, and a
    /// recipient picker showing thousands of rows is not a realistic UI.
    public static let maxRecipientsSteps: [Int] = [5, 10, 25, 50, 100, 250, 500]

    /// Deduplicates a recipient list (first occurrence wins) and caps it at
    /// `maxRecipients`, which itself is clamped to `absoluteMaxRecipients`.
    public static func normalizedRecipients(_ recipients: [EnginePeer.Id], maxRecipients: Int) -> [EnginePeer.Id] {
        var seen = Set<EnginePeer.Id>()
        var result: [EnginePeer.Id] = []
        let cap = min(max(1, maxRecipients), self.absoluteMaxRecipients)
        for id in recipients {
            if seen.contains(id) {
                continue
            }
            seen.insert(id)
            result.append(id)
            if result.count >= cap {
                break
            }
        }
        return result
    }

    /// Caps a requested quantity against the real gift's own remaining-count
    /// limits (if any) and a global sanity ceiling. `nil` limit values mean the
    /// gift reports no limit on that axis.
    public static func normalizedQuantity(_ requested: Int, perUserRemains: Int32?, availabilityRemains: Int32?) -> Int {
        var value = max(1, requested)
        if let perUserRemains, perUserRemains > 0 {
            value = min(value, Int(perUserRemains))
        }
        if let availabilityRemains, availabilityRemains > 0 {
            value = min(value, Int(availabilityRemains))
        }
        // Sanity ceiling independent of any per-gift limit; matches the
        // Android original's `_MAX_QUANTITY_CEILING` guard against a typo'd
        // value from manual entry.
        value = min(value, 9999)
        return max(1, value)
    }

    public static func normalizedDelayMs(_ value: Int) -> Int {
        return min(max(0, value), 5000)
    }

    public static func normalizedMaxRecipients(_ value: Int) -> Int {
        return min(max(1, value), self.absoluteMaxRecipients)
    }
}
