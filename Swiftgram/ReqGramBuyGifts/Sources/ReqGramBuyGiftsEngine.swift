import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import Display
import SGSimpleSettings
import SGLogging

/// Sequential bulk-send engine for the "Buy Gifts" plugin.
///
/// # Real payment path
///
/// Every unit sent by this engine goes through the exact same engine calls
/// already used by `ReqGramGiftScheduler.send(task:context:)`:
/// `context.engine.payments.fetchBotPaymentForm(source:themeParams:)` followed
/// by `context.engine.payments.sendStarsPaymentForm(formId:source:)`. There is
/// no alternate, lower-level or hand-rolled payment call anywhere in this
/// file. The `giftId` inside `source` always comes from a `StarGift.Gift`
/// already resolved by the normal gift catalog (`GiftOptionsScreen` /
/// `resolveStarGiftById`), never invented by this plugin.
///
/// # Double-charge guard
///
/// Identical boundary to `ReqGramGiftScheduler`: a `paymentIssued` flag flips
/// the instant `sendStarsPaymentForm` is handed to the engine. Failures before
/// that point are retried (bounded); failures at or after that point are
/// terminal for that unit and STOP the remaining batch, exactly like the
/// Android original's `_finish_send_sheet_bulk`, which never auto-continues
/// past an error.
///
/// # Cancellation
///
/// `cancel()` only prevents the NEXT unit from starting. A send already
/// in flight always runs to completion; nothing already charged is ever
/// rolled back or retried.
public final class ReqGramBuyGiftsEngine {
    public enum UnitFailureReason {
        case fetchFormFailed(SendBotPaymentFormError)
        case paymentFailed(SendBotPaymentFormError)
    }

    public struct Progress: Equatable {
        public var sent: Int
        public var total: Int
        public var spent: Int64
    }

    public struct Result {
        public var sent: Int
        public var total: Int
        public var spent: Int64
        public var cancelled: Bool
        public var failureReason: UnitFailureReason?
    }

    /// Bounded retry count for PRE-payment failures only, mirroring the
    /// Android original's `_FLOOD_RETRIES = 3`. Chosen as a conservative cap:
    /// high enough to absorb a brief connectivity hiccup or a single
    /// transient server error, low enough that a persistently failing batch
    /// still terminates quickly instead of retrying indefinitely while
    /// holding the user's attention on an open sheet.
    public static let maxPrePaymentRetries = 3

    private let context: AccountContext
    private var cancelled = false
    private var running = false
    private var sendDisposable: Disposable?
    private var delayTimer: SwiftSignalKit.Timer?

    public init(context: AccountContext) {
        self.context = context
    }

    deinit {
        self.sendDisposable?.dispose()
        self.delayTimer?.invalidate()
    }

    public var isRunning: Bool {
        return self.running
    }

    /// Requests cancellation. Takes effect before the NEXT unit starts; a
    /// unit already in flight is never aborted.
    public func cancel() {
        self.cancelled = true
    }

    /// Starts sending `request.totalUnits` individual gifts, sequentially,
    /// with `delayMs` between each. Calls `onProgress` after every completed
    /// unit (on the main queue) and `onFinished` exactly once when the batch
    /// stops, whether by completion, cancellation or an unrecoverable error.
    public func start(
        request: ReqGramBuyGiftsRequest,
        delayMs: Int,
        onProgress: @escaping (Progress) -> Void,
        onFinished: @escaping (Result) -> Void
    ) {
        assert(Queue.mainQueue().isCurrent())
        guard !self.running else {
            return
        }
        self.running = true
        self.cancelled = false

        var plan: [EnginePeer.Id] = []
        for recipient in request.recipients {
            for _ in 0 ..< request.quantityPerRecipient {
                plan.append(recipient)
            }
        }

        guard !plan.isEmpty else {
            self.running = false
            onFinished(Result(sent: 0, total: 0, spent: 0, cancelled: false, failureReason: nil))
            return
        }

        self.step(
            request: request,
            plan: plan,
            index: 0,
            spent: 0,
            retriesUsed: 0,
            delayMs: ReqGramBuyGiftsLimits.normalizedDelayMs(delayMs),
            onProgress: onProgress,
            onFinished: onFinished
        )
    }

    private func step(
        request: ReqGramBuyGiftsRequest,
        plan: [EnginePeer.Id],
        index: Int,
        spent: Int64,
        retriesUsed: Int,
        delayMs: Int,
        onProgress: @escaping (Progress) -> Void,
        onFinished: @escaping (Result) -> Void
    ) {
        assert(Queue.mainQueue().isCurrent())

        if self.cancelled {
            self.running = false
            onFinished(Result(sent: index, total: plan.count, spent: spent, cancelled: true, failureReason: nil))
            return
        }
        if index >= plan.count {
            self.running = false
            onFinished(Result(sent: index, total: plan.count, spent: spent, cancelled: false, failureReason: nil))
            return
        }

        let recipientId = plan[index]
        let source: BotPaymentInvoiceSource = .starGift(
            hideName: request.hideName,
            includeUpgrade: request.includeUpgrade,
            peerId: recipientId,
            giftId: request.giftId,
            text: request.text,
            entities: request.entities
        )

        let context = self.context
        // Flips the instant sendStarsPaymentForm is handed to the engine.
        // See the double-charge guard note above `ReqGramBuyGiftsEngine`.
        let paymentIssued = Atomic<Bool>(value: false)

        let signal = context.engine.payments.fetchBotPaymentForm(source: source, themeParams: nil)
        |> mapError { error -> SendBotPaymentFormError in
            switch error {
            case .disallowedStarGift:
                return .disallowedStarGift
            case .starGiftUserLimit:
                return .starGiftUserLimit
            case .generic, .alreadyActive, .noPaymentNeeded, .starGiftResellTooEarly:
                return .generic
            }
        }
        |> mapToSignal { form -> Signal<SendBotPaymentResult, SendBotPaymentFormError> in
            let _ = paymentIssued.swap(true)
            return context.engine.payments.sendStarsPaymentForm(formId: form.id, source: source)
        }
        |> deliverOnMainQueue

        self.sendDisposable?.dispose()
        self.sendDisposable = signal.start(
            next: { [weak self] _ in
                guard let self else {
                    return
                }
                let nextSpent = spent + request.unitPrice
                let nextIndex = index + 1
                if SGSimpleSettings.shared.reqGramBuyGiftsHapticFeedback {
                    HapticFeedback().success()
                }
                onProgress(Progress(sent: nextIndex, total: plan.count, spent: nextSpent))
                if nextIndex >= plan.count || self.cancelled {
                    self.running = false
                    onFinished(Result(sent: nextIndex, total: plan.count, spent: nextSpent, cancelled: self.cancelled, failureReason: nil))
                    return
                }
                self.scheduleNext(delayMs: delayMs) { [weak self] in
                    self?.step(
                        request: request,
                        plan: plan,
                        index: nextIndex,
                        spent: nextSpent,
                        retriesUsed: 0,
                        delayMs: delayMs,
                        onProgress: onProgress,
                        onFinished: onFinished
                    )
                }
            },
            error: { [weak self] error in
                guard let self else {
                    return
                }
                let didIssuePayment = paymentIssued.with { $0 }
                if didIssuePayment {
                    // NEVER retry once sendStarsPaymentForm has been issued:
                    // the request may have succeeded with a lost response.
                    SGLogger.shared.log("ReqGramBuyGiftsEngine", "unit \(index) failed after payment attempt; stopping batch, not retrying")
                    self.running = false
                    onFinished(Result(sent: index, total: plan.count, spent: spent, cancelled: false, failureReason: .paymentFailed(error)))
                    return
                }
                // Pre-payment failure (resolving the invoice / fetching the
                // payment form). Safe to retry a bounded number of times;
                // nothing has been charged yet.
                if retriesUsed < ReqGramBuyGiftsEngine.maxPrePaymentRetries {
                    SGLogger.shared.log("ReqGramBuyGiftsEngine", "unit \(index) pre-payment failure, retry \(retriesUsed + 1)/\(ReqGramBuyGiftsEngine.maxPrePaymentRetries)")
                    self.scheduleNext(delayMs: max(delayMs, 500)) { [weak self] in
                        self?.step(
                            request: request,
                            plan: plan,
                            index: index,
                            spent: spent,
                            retriesUsed: retriesUsed + 1,
                            delayMs: delayMs,
                            onProgress: onProgress,
                            onFinished: onFinished
                        )
                    }
                    return
                }
                self.running = false
                onFinished(Result(sent: index, total: plan.count, spent: spent, cancelled: false, failureReason: .fetchFormFailed(error)))
            }
        )
    }

    private func scheduleNext(delayMs: Int, _ run: @escaping () -> Void) {
        self.delayTimer?.invalidate()
        guard delayMs > 0 else {
            Queue.mainQueue().async(run)
            return
        }
        let timer = SwiftSignalKit.Timer(timeout: Double(delayMs) / 1000.0, repeat: false, completion: { run() }, queue: Queue.mainQueue())
        self.delayTimer = timer
        timer.start()
    }
}
