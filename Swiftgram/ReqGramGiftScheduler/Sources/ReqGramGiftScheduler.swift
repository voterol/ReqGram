import Foundation
import UIKit
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import SGLogging
import SGSimpleSettings

/// Foreground scheduler for the Gift Scheduler plugin.
///
/// # How scheduling degrades on iOS
///
/// The Android original used `AlarmManager` + partial wake locks to wake the
/// process at an exact wall-clock moment. iOS has no equivalent: a terminated
/// or suspended app cannot be woken on a schedule. This implementation is
/// therefore explicitly best-effort and the UI says so:
///
/// * while the app is active, a 15s repeating tick evaluates due tasks
///   (same cadence as the original `TICK_SECONDS`);
/// * on launch and on `didBecomeActive`, a catch-up evaluation runs after a
///   short connectivity warm-up (the original waited 8s for the client to
///   connect; here we wait for the account to actually report a usable network
///   state, with the same 8s as a ceiling);
/// * a task whose moment passed while the app was not running is still sent on
///   the next activation, but only if it is within the `max_late_min` grace
///   window; otherwise it becomes `missed`.
///
/// No background wall-clock wakeup is attempted. See the plugin screen copy.
public final class ReqGramGiftScheduler {
    /// Matches the original plugin's `TICK_SECONDS`.
    public static let tickInterval: Double = 15.0
    /// Matches the original plugin's `RETRY_DELAY`.
    public static let retryDelay: Double = 30.0
    /// Upper bound on the pre-evaluation connectivity warm-up, matching the
    /// original's fixed 8s wait for the client to connect.
    public static let connectivityWarmUp: Double = 8.0
    /// Default grace window in MINUTES.
    ///
    /// NOTE: the Android plugin's docstring claims 60 minutes, but its code
    /// default is the string "360" (`get_setting("max_late_min", "360")`); the
    /// 3600-second value appears only as a parse-failure fallback. 360 minutes
    /// is the real default and is what we use.
    public static let defaultMaxLateMinutes: Int = 360

    public static let shared = ReqGramGiftScheduler()

    private let store: ReqGramGiftTaskStore
    private let queue = Queue.mainQueue()

    private var tickTimer: SwiftSignalKit.Timer?
    private weak var context: AccountContext?
    private var warmUpDisposable: Disposable?
    private var sendDisposables: [Int64: Disposable] = [:]
    private var activeObserver: NSObjectProtocol?
    private var didRecover = false

    public init(store: ReqGramGiftTaskStore = .shared) {
        self.store = store
    }

    // MARK: - Lifecycle

    /// Binds the scheduler to the active account context.
    ///
    /// Safe to call repeatedly; re-binding to the same context is a no-op.
    /// Called from `AppDelegate` on context change and on `didBecomeActive`.
    public func setup(context: AccountContext) {
        assert(Queue.mainQueue().isCurrent())

        if self.context === context {
            self.refreshRunState()
            return
        }
        self.teardownTimer()
        self.context = context

        // One-shot recovery of tasks interrupted by a crash or force-quit.
        // Never retried: see ReqGramGiftTaskStore.recoverInterruptedTasks.
        if !self.didRecover {
            self.didRecover = true
            let recovered = self.store.recoverInterruptedTasks()
            if !recovered.isEmpty {
                SGLogger.shared.log("ReqGramGiftScheduler", "recovered \(recovered.count) interrupted task(s) as failed")
            }
        }

        if self.activeObserver == nil {
            self.activeObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refreshRunState()
            }
        }

        self.refreshRunState()
    }

    /// Starts or stops the tick according to the feature gate.
    public func refreshRunState() {
        assert(Queue.mainQueue().isCurrent())

        guard SGSimpleSettings.shared.reqGramGiftSchedulerEnabled, self.context != nil else {
            self.teardownTimer()
            return
        }
        self.startTimerIfNeeded()
        self.scheduleCatchUpEvaluation()
    }

    private func startTimerIfNeeded() {
        guard self.tickTimer == nil else {
            return
        }
        let timer = SwiftSignalKit.Timer(
            timeout: ReqGramGiftScheduler.tickInterval,
            repeat: true,
            completion: { [weak self] in
                self?.evaluate()
            },
            queue: self.queue
        )
        self.tickTimer = timer
        timer.start()
    }

    private func teardownTimer() {
        self.tickTimer?.invalidate()
        self.tickTimer = nil
        self.warmUpDisposable?.dispose()
        self.warmUpDisposable = nil
    }

    // MARK: - Evaluation

    /// Runs a catch-up evaluation once the client reports a usable connection.
    ///
    /// Without this, the first evaluation after a cold launch would run while
    /// the client is still connecting and every due task would fail on a
    /// network error, burn a retry, and then be re-attempted 30s later.
    private func scheduleCatchUpEvaluation() {
        guard let context = self.context else {
            return
        }
        self.warmUpDisposable?.dispose()

        let connected = context.account.networkState
        |> filter { state in
            switch state {
            case .online, .updating:
                return true
            case .waitingForNetwork, .connecting:
                return false
            }
        }
        |> take(1)
        |> map { _ in true }

        // Evaluate as soon as we are connected, but never wait longer than the
        // warm-up ceiling: a task inside its grace window should still be tried
        // even on a flaky connection, and a network failure before payment is
        // retryable anyway.
        //
        // The alternate fires immediately once `timeout` elapses; adding a
        // further `delay` here would double the wait to 16s.
        // NOTE: the local value must not be named `timeout` -- that would
        // shadow the SwiftSignalKit `timeout` operator used just below.
        let warmUpFallback: Signal<Bool, NoError> = .single(false)

        self.warmUpDisposable = (
            connected
            |> timeout(
                ReqGramGiftScheduler.connectivityWarmUp,
                queue: self.queue,
                alternate: warmUpFallback
            )
            |> deliverOnMainQueue
        ).start(next: { [weak self] _ in
            self?.evaluate()
        })
    }

    /// Grace window in seconds, from settings.
    private func maxLateSeconds() -> Double {
        let minutes = SGSimpleSettings.shared.reqGramGiftSchedulerMaxLateMinutes
        // A non-positive value would make every late task instantly missed;
        // fall back to the documented default instead.
        guard minutes > 0 else {
            return Double(ReqGramGiftScheduler.defaultMaxLateMinutes) * 60.0
        }
        return Double(minutes) * 60.0
    }

    /// Claims and dispatches every due task.
    public func evaluate() {
        assert(Queue.mainQueue().isCurrent())

        guard SGSimpleSettings.shared.reqGramGiftSchedulerEnabled, let context = self.context else {
            return
        }
        let accountId = context.account.id.int64
        let now = Date().timeIntervalSince1970
        let claimed = self.store.claimDueTasks(
            accountId: accountId,
            now: now,
            maxLate: self.maxLateSeconds()
        )
        for task in claimed.missed {
            SGLogger.shared.log("ReqGramGiftScheduler", "task \(task.id) missed its window")
        }
        for task in claimed.due {
            self.send(task: task, context: context)
        }
    }

    // MARK: - Sending

    /// Executes one claimed task.
    ///
    /// # Double-charge guard
    ///
    /// The retry policy is strictly asymmetric and preserved from the original:
    ///
    /// * failures BEFORE `sendStarsPaymentForm` is issued (peer resolution,
    ///   premium re-validation, `fetchBotPaymentForm`) are retryable: no money
    ///   has moved, so the task returns to `pending` with `nextTry = now + 30`.
    /// * failures AT OR AFTER `sendStarsPaymentForm` are NEVER retried. The
    ///   request may have succeeded with a lost response, so the task goes
    ///   straight to `failed` and the user is told to verify whether the gift
    ///   arrived. Retrying here would risk charging stars twice.
    ///
    /// A `paymentIssued` flag makes the boundary explicit rather than implied.
    private func send(task: ReqGramGiftTask, context: AccountContext) {
        self.sendDisposables[task.id]?.dispose()

        let store = self.store
        let maxLate = self.maxLateSeconds()
        // Flipped the instant the payment request is handed to the engine.
        let paymentIssued = Atomic<Bool>(value: false)

        let entities = task.messageTextEntities
        // Same source value is used for BOTH fetchBotPaymentForm and
        // sendStarsPaymentForm. The engine re-serializes the invoice from the
        // source on each call, so a mismatch would invoice different content
        // than was quoted.
        let source: BotPaymentInvoiceSource = .starGift(
            hideName: task.hide,
            includeUpgrade: task.includeUpgrade,
            peerId: task.recipientPeerId,
            giftId: task.giftId,
            text: task.text.isEmpty ? nil : task.text,
            entities: entities.isEmpty ? nil : entities
        )

        // Re-validate the preconditions that can lapse between scheduling and
        // sending: the recipient must still be resolvable in the postbox (the
        // engine's invoice serialization needs `transaction.getPeer`), and
        // custom emoji in the caption still require an active premium
        // subscription.
        let preflight: Signal<ReqGramGiftPreflight, NoError> = context.account.postbox.transaction { transaction -> ReqGramGiftPreflight in
            let peerExists = transaction.getPeer(task.recipientPeerId) != nil
            var isPremium = false
            if let accountPeer = transaction.getPeer(context.account.peerId) as? TelegramUser {
                isPremium = accountPeer.isPremium
            }
            return ReqGramGiftPreflight(peerExists: peerExists, isPremium: isPremium)
        }

        let signal = preflight
        |> castError(SendBotPaymentFormError.self)
        |> mapToSignal { preflight -> Signal<SendBotPaymentResult, SendBotPaymentFormError> in
            guard preflight.peerExists else {
                // Peer not cached. Retryable: the client may simply not have
                // synced the peer yet, and nothing has been charged.
                return .fail(.generic)
            }
            if task.hasCustomEmoji && !preflight.isPremium {
                // Premium lapsed after scheduling. Not retryable in a way that
                // would ever succeed on its own, but still pre-payment, so it is
                // reported as a distinct terminal condition below.
                return .fail(.disallowedStarGift)
            }
            return context.engine.payments.fetchBotPaymentForm(source: source, themeParams: nil)
            |> mapError { _ -> SendBotPaymentFormError in
                return .generic
            }
            |> mapToSignal { form -> Signal<SendBotPaymentResult, SendBotPaymentFormError> in
                // === PAYMENT BOUNDARY ===
                // Everything past this point may move stars.
                let _ = paymentIssued.swap(true)
                return context.engine.payments.sendStarsPaymentForm(formId: form.id, source: source)
            }
        }
        |> deliverOnMainQueue

        let disposable = signal.start(
            next: { [weak self] _ in
                store.update(id: task.id) { stored in
                    stored.status = .sent
                    stored.error = ""
                    stored.sentAt = Date().timeIntervalSince1970
                }
                SGLogger.shared.log("ReqGramGiftScheduler", "task \(task.id) sent")
                self?.sendDisposables[task.id] = nil
            },
            error: { [weak self] error in
                let didIssuePayment = paymentIssued.with { $0 }
                if didIssuePayment {
                    // NEVER retry after a payment attempt.
                    store.update(id: task.id) { stored in
                        stored.status = .failed
                        stored.error = ReqGramGiftSchedulerError.serverPrefix + ReqGramGiftScheduler.describe(error)
                    }
                    SGLogger.shared.log("ReqGramGiftScheduler", "task \(task.id) failed after payment attempt; not retrying")
                } else if case .disallowedStarGift = error, task.hasCustomEmoji {
                    store.update(id: task.id) { stored in
                        stored.status = .failed
                        stored.error = ReqGramGiftSchedulerError.premiumRequired
                    }
                } else {
                    let now = Date().timeIntervalSince1970
                    // Pre-payment failure: safe to retry while inside the grace
                    // window, exactly as the original did.
                    if now - task.when < maxLate {
                        store.update(id: task.id) { stored in
                            stored.status = .pending
                            stored.nextTry = now + ReqGramGiftScheduler.retryDelay
                            stored.error = ReqGramGiftSchedulerError.retryPrefix + ReqGramGiftScheduler.describe(error)
                        }
                    } else {
                        store.update(id: task.id) { stored in
                            stored.status = .failed
                            stored.error = ReqGramGiftSchedulerError.serverPrefix + ReqGramGiftScheduler.describe(error)
                        }
                    }
                }
                self?.sendDisposables[task.id] = nil
            }
        )
        self.sendDisposables[task.id] = disposable
    }

    /// Maps an engine payment error onto a stable persisted token.
    ///
    /// Server-provided strings are passed through so the user can see the real
    /// cause (for example BALANCE_TOO_LOW), matching the original's
    /// `friendly_error` table behavior but without inventing text.
    private static func describe(_ error: SendBotPaymentFormError) -> String {
        switch error {
        case .generic:
            return "GENERIC"
        case .precheckoutFailed:
            return "PRECHECKOUT_FAILED"
        case .paymentFailed:
            return "PAYMENT_FAILED"
        case .alreadyPaid:
            return "ALREADY_PAID"
        case .starGiftOutOfStock:
            return "STARGIFT_USAGE_LIMITED"
        case .disallowedStarGift:
            return "USER_PRIVACY"
        case .starGiftUserLimit:
            return "STARGIFT_USER_LIMIT"
        case let .serverProvided(text):
            return text
        }
    }

    deinit {
        if let activeObserver = self.activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
        self.warmUpDisposable?.dispose()
        for (_, disposable) in self.sendDisposables {
            disposable.dispose()
        }
    }
}

private struct ReqGramGiftPreflight {
    let peerExists: Bool
    let isPremium: Bool
}
