import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import SGSimpleSettings

/// Creates scheduled gift tasks from the gift composer.
///
/// Kept in this module rather than inline in the composer so that the caption
/// capture, the entity persistence and the confirmation invariants live in one
/// place and are exercised by the same code path regardless of entry point.
public enum ReqGramGiftSchedulerRequest {
    public enum Error: Swift.Error {
        case schedulerDisabled
        case timeInPast
        case tooManyTasks
        /// The caption contains custom emoji but the account is not premium.
        /// Checked here as well as at send time, because the subscription can
        /// lapse in between.
        case premiumRequiredForCustomEmoji
    }

    /// Minimum lead time. The original rejected anything within 30s of now;
    /// preserved so a task is never scheduled into a moment that the very next
    /// tick would already treat as late.
    public static let minimumLeadTime: Double = 30.0

    /// Everything the confirmation sheet needs to describe the pending action,
    /// computed once so the UI cannot drift from what gets persisted.
    public struct Draft {
        public var when: Double
        public var recipientPeerId: EnginePeer.Id
        public var giftId: Int64
        public var label: String
        public var stars: Int64
        public var giftFileId: Int64?
        public var caption: ReqGramGiftCaption.Captured
        public var hide: Bool
        public var includeUpgrade: Bool
        public var customEmojiCount: Int

        public init(
            when: Double,
            recipientPeerId: EnginePeer.Id,
            giftId: Int64,
            label: String,
            stars: Int64,
            giftFileId: Int64?,
            caption: ReqGramGiftCaption.Captured,
            hide: Bool,
            includeUpgrade: Bool,
            customEmojiCount: Int
        ) {
            self.when = when
            self.recipientPeerId = recipientPeerId
            self.giftId = giftId
            self.label = label
            self.stars = stars
            self.giftFileId = giftFileId
            self.caption = caption
            self.hide = hide
            self.includeUpgrade = includeUpgrade
            self.customEmojiCount = customEmojiCount
        }
    }

    /// Builds a draft from composer state.
    ///
    /// `attributedCaption` must be the live `NSAttributedString` from the input
    /// panel, NOT its `.string`. Flattening it here is exactly the bug that
    /// destroyed custom emoji in the Android original.
    public static func makeDraft(
        context: AccountContext,
        when: Double,
        recipientPeerId: EnginePeer.Id,
        giftId: Int64,
        label: String,
        stars: Int64,
        giftFileId: Int64?,
        attributedCaption: NSAttributedString,
        hide: Bool,
        includeUpgrade: Bool
    ) -> Draft {
        let maxLength = ReqGramGiftCaption.maxCaptionLength(
            appConfiguration: context.currentAppConfiguration.with { $0 }
        )
        let caption = ReqGramGiftCaption.capture(attributedCaption, maxLength: maxLength)
        let customEmojiCount = caption.entities.filter { $0.kind == .customEmoji }.count
        return Draft(
            when: when,
            recipientPeerId: recipientPeerId,
            giftId: giftId,
            label: label,
            stars: stars,
            giftFileId: giftFileId,
            caption: caption,
            hide: hide,
            includeUpgrade: includeUpgrade,
            customEmojiCount: customEmojiCount
        )
    }

    /// Validates a draft without persisting it.
    ///
    /// `isPremium` must be the account's current premium state; pass nil to
    /// skip the check when it is not yet known (the send-time re-validation
    /// still applies).
    public static func validate(_ draft: Draft, now: Double = Date().timeIntervalSince1970, isPremium: Bool?) -> Error? {
        guard SGSimpleSettings.shared.reqGramGiftSchedulerEnabled else {
            return .schedulerDisabled
        }
        guard draft.when > now + self.minimumLeadTime else {
            return .timeInPast
        }
        if draft.customEmojiCount > 0, let isPremium, !isPremium {
            return .premiumRequiredForCustomEmoji
        }
        return nil
    }

    /// Persists a validated draft as a `pending` task.
    ///
    /// Callers MUST have obtained explicit user confirmation first: this
    /// commits a future charge of real stars.
    public static func commit(
        _ draft: Draft,
        context: AccountContext,
        isPremium: Bool?,
        store: ReqGramGiftTaskStore = .shared
    ) throws -> ReqGramGiftTask {
        if let error = self.validate(draft, isPremium: isPremium) {
            throw error
        }
        let task = ReqGramGiftTask(
            // Millisecond timestamp, as in the original, but with a random low
            // component so two taps in the same millisecond cannot collide.
            id: Int64(Date().timeIntervalSince1970 * 1000.0) &* 1000 &+ Int64.random(in: 0 ..< 1000),
            when: draft.when,
            recipientPeerId: draft.recipientPeerId,
            giftId: draft.giftId,
            label: draft.label,
            stars: draft.stars,
            giftFileId: draft.giftFileId,
            text: draft.caption.text,
            entities: draft.caption.entities,
            hide: draft.hide,
            includeUpgrade: draft.includeUpgrade,
            accountId: context.account.id.int64,
            status: .pending,
            error: "",
            nextTry: 0.0,
            sentAt: nil
        )
        do {
            try store.add(task)
        } catch ReqGramGiftTaskStore.AddError.tooManyTasks {
            throw Error.tooManyTasks
        }
        return task
    }

    /// Current premium state of the signed-in account.
    public static func accountIsPremium(context: AccountContext) -> Signal<Bool, NoError> {
        return context.engine.data.get(
            TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId)
        )
        |> map { peer -> Bool in
            guard case let .user(user) = peer else {
                return false
            }
            return user.isPremium
        }
    }
}
