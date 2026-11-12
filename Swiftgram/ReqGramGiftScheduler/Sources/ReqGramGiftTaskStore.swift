import Foundation
import Postbox
import TelegramCore
import SGLogging

/// Atomic on-disk store for scheduled gift tasks.
///
/// Deliberately NOT part of `ReqGramSettingsTransfer`: that allowlist performs
/// strict key set-equality, and scheduled tasks are device-local pending
/// financial actions that must not travel in an exported settings JSON.
public final class ReqGramGiftTaskStore {
    public static let didChangeNotification = Notification.Name("ReqGramGiftScheduler.tasksDidChange")

    /// Hard ceiling on stored tasks, to bound both file size and tick cost.
    public static let maximumTaskCount = 200

    public static let shared = ReqGramGiftTaskStore(
        root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReqGramGiftScheduler")
    )

    private struct Store: Codable {
        var version: Int
        var tasks: [ReqGramGiftTask]

        init(version: Int = 1, tasks: [ReqGramGiftTask] = []) {
            self.version = version
            self.tasks = tasks
        }
    }

    private let root: URL
    private let lock = NSLock()
    private var cache: [ReqGramGiftTask]?

    public init(root: URL) {
        self.root = root
    }

    private var file: URL {
        return self.root.appendingPathComponent("tasks.json")
    }

    // MARK: - Reading

    /// All stored tasks, newest requested delivery first.
    public func tasks() -> [ReqGramGiftTask] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.loadLocked()
    }

    /// Tasks belonging to one account.
    public func tasks(accountId: Int64) -> [ReqGramGiftTask] {
        return self.tasks().filter { $0.accountId == accountId }
    }

    private func loadLocked() -> [ReqGramGiftTask] {
        if let cache = self.cache {
            return cache
        }
        guard FileManager.default.fileExists(atPath: self.file.path) else {
            self.cache = []
            return []
        }
        do {
            let data = try Data(contentsOf: self.file)
            let store = try JSONDecoder().decode(Store.self, from: data)
            self.cache = store.tasks
            return store.tasks
        } catch {
            // A corrupt store must never wedge the scheduler or crash the app.
            // Quarantine the file and continue with an empty list; the user's
            // pending tasks are lost but nothing is charged.
            SGLogger.shared.log("ReqGramGiftScheduler", "task store unreadable, quarantining")
            let quarantine = self.root.appendingPathComponent("tasks.corrupt.json")
            try? FileManager.default.removeItem(at: quarantine)
            try? FileManager.default.moveItem(at: self.file, to: quarantine)
            self.cache = []
            return []
        }
    }

    private func writeLocked(_ tasks: [ReqGramGiftTask]) {
        self.cache = tasks
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Store(tasks: tasks))
            try data.write(to: self.file, options: .atomic)
        } catch {
            SGLogger.shared.log("ReqGramGiftScheduler", "task store write failed")
        }
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: ReqGramGiftTaskStore.didChangeNotification, object: nil)
        }
    }

    // MARK: - Writing

    public enum AddError: Error {
        case tooManyTasks
    }

    /// Appends a new task. Rejects once the ceiling is reached rather than
    /// silently evicting a pending financial action.
    public func add(_ task: ReqGramGiftTask) throws {
        self.lock.lock()
        var tasks = self.loadLocked()
        let pendingCount = tasks.filter { $0.status == .pending || $0.status == .sending }.count
        guard pendingCount < ReqGramGiftTaskStore.maximumTaskCount else {
            self.lock.unlock()
            throw AddError.tooManyTasks
        }
        tasks.append(task)
        self.writeLocked(tasks)
        self.lock.unlock()
        self.notifyChanged()
    }

    /// Applies a mutation to one task, under the store lock.
    ///
    /// Returns the updated task, or nil when the id is unknown.
    @discardableResult
    public func update(id: Int64, _ mutate: (inout ReqGramGiftTask) -> Void) -> ReqGramGiftTask? {
        self.lock.lock()
        var tasks = self.loadLocked()
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            self.lock.unlock()
            return nil
        }
        mutate(&tasks[index])
        let updated = tasks[index]
        self.writeLocked(tasks)
        self.lock.unlock()
        self.notifyChanged()
        return updated
    }

    /// Atomically claims every task that is due, transitioning it from
    /// `pending` to `sending` (or to `missed` when past the grace window).
    ///
    /// This is the single point at which a task becomes eligible for payment.
    /// Claiming and the status write happen under one lock acquisition, so two
    /// concurrent evaluations cannot both claim the same task and double-charge.
    ///
    /// - Parameters:
    ///   - accountId: only tasks created by this account are considered.
    ///   - now: evaluation timestamp.
    ///   - maxLate: grace window in seconds.
    /// - Returns: the claimed tasks and the ones newly marked missed.
    public func claimDueTasks(accountId: Int64, now: Double, maxLate: Double) -> (due: [ReqGramGiftTask], missed: [ReqGramGiftTask]) {
        self.lock.lock()
        var tasks = self.loadLocked()
        var due: [ReqGramGiftTask] = []
        var missed: [ReqGramGiftTask] = []
        var changed = false
        for index in tasks.indices {
            guard tasks[index].accountId == accountId else {
                continue
            }
            guard tasks[index].status == .pending else {
                continue
            }
            guard tasks[index].when <= now else {
                continue
            }
            // Honour the retry backoff.
            guard tasks[index].nextTry <= now else {
                continue
            }
            if now - tasks[index].when > maxLate {
                tasks[index].status = .missed
                tasks[index].error = ReqGramGiftSchedulerError.missedWindow
                missed.append(tasks[index])
                changed = true
                continue
            }
            tasks[index].status = .sending
            due.append(tasks[index])
            changed = true
        }
        if changed {
            self.writeLocked(tasks)
        }
        self.lock.unlock()
        if changed {
            self.notifyChanged()
        }
        return (due, missed)
    }

    /// Removes a task. Refuses while the task is `sending`, because a payment
    /// request may be in flight and dropping the record would lose the only
    /// evidence of it.
    @discardableResult
    public func remove(id: Int64) -> Bool {
        self.lock.lock()
        var tasks = self.loadLocked()
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            self.lock.unlock()
            return false
        }
        guard tasks[index].status != .sending else {
            self.lock.unlock()
            return false
        }
        tasks.remove(at: index)
        self.writeLocked(tasks)
        self.lock.unlock()
        self.notifyChanged()
        return true
    }

    /// Cancels every still-pending task for an account. `sending` tasks are
    /// intentionally skipped.
    @discardableResult
    public func cancelAllPending(accountId: Int64) -> Int {
        self.lock.lock()
        var tasks = self.loadLocked()
        let before = tasks.count
        tasks.removeAll { $0.accountId == accountId && $0.status == .pending }
        let removed = before - tasks.count
        if removed > 0 {
            self.writeLocked(tasks)
        }
        self.lock.unlock()
        if removed > 0 {
            self.notifyChanged()
        }
        return removed
    }

    /// Drops finished records (sent / failed / missed) for an account.
    @discardableResult
    public func clearFinished(accountId: Int64) -> Int {
        self.lock.lock()
        var tasks = self.loadLocked()
        let before = tasks.count
        tasks.removeAll { task in
            guard task.accountId == accountId else {
                return false
            }
            switch task.status {
            case .sent, .failed, .missed:
                return true
            case .pending, .sending:
                return false
            }
        }
        let removed = before - tasks.count
        if removed > 0 {
            self.writeLocked(tasks)
        }
        self.lock.unlock()
        if removed > 0 {
            self.notifyChanged()
        }
        return removed
    }

    /// Recovers tasks left in `sending` by a crash or force-quit.
    ///
    /// CRITICAL: these are NOT returned to `pending`. A task in `sending` has
    /// already had a payment form fetched and possibly a `sendStarsForm` issued;
    /// the outcome is unknown. Retrying could charge the user twice, so the task
    /// is marked `failed` with an explicit "verify whether it was sent" message.
    /// This mirrors the original plugin's refusal to retry after payment.
    @discardableResult
    public func recoverInterruptedTasks() -> [ReqGramGiftTask] {
        self.lock.lock()
        var tasks = self.loadLocked()
        var recovered: [ReqGramGiftTask] = []
        var changed = false
        for index in tasks.indices where tasks[index].status == .sending {
            tasks[index].status = .failed
            tasks[index].error = ReqGramGiftSchedulerError.interrupted
            recovered.append(tasks[index])
            changed = true
        }
        if changed {
            self.writeLocked(tasks)
        }
        self.lock.unlock()
        if changed {
            self.notifyChanged()
        }
        return recovered
    }

    /// Timestamp of the soonest pending task for an account, if any.
    public func nextPendingDate(accountId: Int64) -> Double? {
        return self.tasks(accountId: accountId)
            .filter { $0.status == .pending }
            .map { max($0.when, $0.nextTry) }
            .min()
    }
}

/// Stable, non-localized error markers persisted in `ReqGramGiftTask.error`.
///
/// Stored values must stay stable across app versions, so these are opaque
/// tokens; the UI maps them to localized copy at render time. Server error
/// strings are persisted verbatim under the `server:` prefix.
public enum ReqGramGiftSchedulerError {
    public static let missedWindow = "missed_window"
    public static let interrupted = "interrupted"
    public static let noPaymentForm = "no_payment_form"
    public static let peerUnavailable = "peer_unavailable"
    public static let premiumRequired = "premium_required"
    public static let serverPrefix = "server:"
    public static let retryPrefix = "retry:"
}
