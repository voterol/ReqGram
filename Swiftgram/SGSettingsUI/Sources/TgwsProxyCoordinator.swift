import Foundation
import UIKit
import os.log
import CryptoKit
import Postbox
import TelegramCore
import SwiftSignalKit
import SGSimpleSettings
import ReqGramPythonRuntime

/// Pure route policy; ownership is committed in the SAME transaction as routing.
public struct TgwsManagedRoute: Codable {
    public let previous: ProxySettings
    public let server: ProxyServerSettings
    public init(previous: ProxySettings, server: ProxyServerSettings) {
        self.previous = previous
        self.server = server
    }
    public func install(into current: ProxySettings) -> ProxySettings {
        var result = current
        result.servers.removeAll { $0 == server }
        result.servers.append(server)
        result.enabled = true
        result.activeServer = server
        result.useForCalls = false
        return result
    }
    public func restore(from current: ProxySettings) -> ProxySettings {
        var result = current
        result.servers.removeAll { $0 == server }
        // Compare the whole owned routing tuple, not just the selected server.
        // A concurrent explicit edit wins; never clobber its active route/list.
        if current.enabled && current.activeServer == server && !current.useForCalls {
            // A deleted snapshot must never reactivate a proxy. Explicit disable
            // falls back to direct in this case; no deleted entry is reinserted.
            let available = previous.activeServer.flatMap { result.servers.contains($0) ? $0 : nil }
            result.enabled = previous.enabled && available != nil
            result.activeServer = available
            result.useForCalls = previous.useForCalls && available != nil
        }
        return result
    }
}

/// Used inside the actual AccountManager transaction, not at scheduling time.
/// Holds the version lock through both ownership and route writes. Tests can
/// deterministically queue closures against this same transaction boundary.
public final class TgwsRouteTransactionFence {
    private let lock = NSLock()
    private var version: UInt64 = 0
    public init() {}
    @discardableResult public func advance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        version += 1
        return version
    }
    public func mutate(version: UInt64, settings: TgwsProxySettings,
                       snapshot: TgwsProxySettings.Snapshot?, mutation: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard version == self.version else { return false }
        if let snapshot = snapshot {
            return settings.withCurrentSnapshot(snapshot, mutation: mutation)
        }
        mutation() // entropy-failure startup: install a blocking route only
        return true
    }
}

public final class TgwsProxyCoordinator {
    public static let shared = TgwsProxyCoordinator()
    // Private, namespaced key, outside Telegram's 4-byte shared-key namespace.
    private static let ownershipKey: ValueBoxKey = {
        let key = ValueBoxKey(length: 8)
        key.setInt64(0, value: 0x5447575350525831)
        return key
    }()
    private var accountManager: AccountManager<TelegramAccountManagerTypes>?
    private var observers: [NSObjectProtocol] = []
    private var busy = false
    private var initialStarting = false
    private var pending = false
    private var generation = 0
    private let routeFence = TgwsRouteTransactionFence()
    private let operation = MetaDisposable()
    // The native service is a singleton, so the disposable also carries the
    // identity of the operation which is allowed to stop it.  In particular,
    // an old callback must not stop a newer generation's listener.
    private let nativeOperation = MetaDisposable()
    private var nativeOwnerToken: Int?
    private var nativeOwnerID = 0
    private let settings = TgwsProxySettings.shared
    private init() {}

    private func lifecycleLog(_ phase: String, token: Int? = nil) {
        os_log("phase=%{public}@ gen=%{public}d busy=%{public}@ pending=%{public}@ initial=%{public}@ owner=%{public}@/%{public}d token=%{public}@ app=%{public}@",
               log: OSLog(subsystem: "org.telegram.TgwsProxyCoordinator", category: "lifecycle"), type: .info,
               phase, generation, String(busy), String(pending), String(initialStarting),
               nativeOwnerToken.map { String($0) } ?? "none", nativeOwnerID,
               token.map { String($0) } ?? "none", String(describing: UIApplication.shared.applicationState))
    }

    /// Must complete before SharedAccountContext creates any account networks.
    public func prepare(accountManager: AccountManager<TelegramAccountManagerTypes>) -> Signal<Bool, NoError> {
        precondition(Thread.isMainThread)
        lifecycleLog("prepare_enter")
        self.accountManager = accountManager
        if observers.isEmpty {
            for name in [TgwsProxySettings.didChange, UIApplication.didBecomeActiveNotification,
                         UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    guard let self = self else { return }
                    self.lifecycleLog("notification_\(notification.name.rawValue)")
                    if notification.name == UIApplication.didBecomeActiveNotification {
                        // UIApplication can post didBecomeActive before
                        // applicationState has caught up.  startRegularNative
                        // deliberately refuses to start while the state is
                        // inactive, so reconciling synchronously here can
                        // strand a foreground generation in .suspended with
                        // no later notification to retry it.  Let UIKit finish
                        // its state transition; generation fencing still makes
                        // this safe if another lifecycle event arrives first.
                        self.reconcileAfterActivation(attempt: 0)
                    } else {
                        self.reconcile()
                    }
                })
            }
        }
        let snapshot = try? settings.snapshot()
        let version = routeFence.advance()
        let token = generation
        // Keep reconciliation behind the initial startup barrier. The route is
        // intentionally installed first, so a startup failure remains
        // fail-closed while the listener is being brought up.
        busy = true
        initialStarting = true
        return route(snapshot, version: version, accountManager: accountManager)
        |> deliverOnMainQueue
        |> mapToSignal { value -> Signal<Bool, NoError> in
            // A superseded initial transaction is not readiness. Retry with the
            // latest intent before releasing account network construction.
            if !value {
                self.lifecycleLog("initial_route_rejected", token: token)
                self.busy = false
                self.initialStarting = false
                self.pending = false
                return self.prepare(accountManager: accountManager)
            }
            guard token == self.generation else {
                self.lifecycleLog("initial_route_stale", token: token)
                // A lifecycle/settings change fenced this attempt. Do not
                // release account creation until the current generation has
                // completed its own route and listener startup.
                self.busy = false
                self.initialStarting = false
                self.pending = false
                return self.prepare(accountManager: accountManager)
            }
            return self.startInitial(snapshot: snapshot, token: token, accountManager: accountManager)
            |> deliverOnMainQueue
            |> mapToSignal { started -> Signal<Bool, NoError> in
                // A lifecycle/settings change can arrive after the listener
                // reports ready but before this signal is observed. Restart
                // the latest generation before releasing account construction.
                if !started || self.pending || token != self.generation {
                    self.lifecycleLog("initial_barrier_retry", token: token)
                    self.busy = false
                    self.initialStarting = false
                    self.pending = false
                    return self.prepare(accountManager: accountManager)
                }
                self.busy = false
                self.initialStarting = false
                self.lifecycleLog("initial_barrier_released", token: token)
                return .single(true)
            }
        }
    }

    private func reconcileAfterActivation(attempt: Int) {
        precondition(Thread.isMainThread)
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.1)) { [weak self] in
            guard let self = self else { return }
            self.lifecycleLog("activation_reconcile_\(attempt)")
            self.reconcile()
            if UIApplication.shared.applicationState != .active && attempt < 3 {
                self.reconcileAfterActivation(attempt: attempt + 1)
            }
        }
    }

    private func startInitial(snapshot: TgwsProxySettings.Snapshot?, token: Int,
                              accountManager: AccountManager<TelegramAccountManagerTypes>,
                              retryCount: Int = 0) -> Signal<Bool, NoError> {
        lifecycleLog("start_initial_enter", token: token)
        guard token == self.generation else {
            lifecycleLog("start_initial_stale", token: token)
            return self.prepare(accountManager: accountManager)
        }
        guard let config = snapshot?.configuration else {
            lifecycleLog("start_initial_no_config", token: token)
            settings.reportNativeErrorCode(nil)
            settings.reportState(.disabled)
            return .single(true)
        }
        guard config.enabled else {
            lifecycleLog("start_initial_disabled", token: token)
            settings.reportNativeErrorCode(nil)
            settings.reportState(.disabled)
            return .single(true)
        }
        guard UIApplication.shared.applicationState == .active else {
            lifecycleLog("start_initial_not_active", token: token)
            settings.reportNativeErrorCode(nil)
            settings.reportState(.suspended)
            return .single(true)
        }
        guard let json = try? JSONSerialization.data(withJSONObject: ["port": config.port, "secret": config.secret, "cfProxyEnabled": config.cfProxyEnabled, "cfProxyDomains": config.cfProxyDomains, "cfWorkerDomains": config.cfWorkerDomains, "dcRedirects": config.dcRedirects, "bufferKB": config.bufferKB, "poolSize": config.poolSize]) else {
            settings.reportNativeErrorCode(nil)
            settings.reportState(.failed("invalid_config"))
            return .single(true)
        }

        settings.reportState(.starting)
        settings.reportNativeErrorCode(nil)
        settings.reportClientHandshakeRejectionCode(nil)
        let ownerID = nativeOwnerID &+ 1
        nativeOwnerID = ownerID
        nativeOwnerToken = token
        nativeOperation.set(ActionDisposable { [weak self] in
            guard let self = self, self.nativeOwnerToken == token, self.nativeOwnerID == ownerID else { return }
            self.nativeOwnerToken = nil
            self.nativeOwnerID &+= 1
            RGTgwsService.shared().stop(completion: {})
        })
            return Signal { subscriber in
            var finished = false
            var cancelled = false
            let retryOperation = MetaDisposable()
                RGTgwsService.shared().start(withConfigJSON: json, event: { [weak self] event in
                    guard let self = self else { return }
                    self.lifecycleLog("initial_event_\((event["state"] as? String) ?? "unknown")", token: token)
                if cancelled || token != self.generation {
                    if !finished {
                        finished = true
                        subscriber.putNext(false)
                        subscriber.putCompletion()
                    }
                    return
                }
                // A retry can reuse the generation while replacing the
                // singleton listener. Ignore callbacks from that old owner.
                guard self.nativeOwnerToken == token, self.nativeOwnerID == ownerID else { return }
                switch event["state"] as? String {
                case "ready":
                    self.settings.reportNativeErrorCode(nil)
                    self.settings.reportState(.ready)
                    if !finished {
                        finished = true
                        subscriber.putNext(true)
                        subscriber.putCompletion()
                    }
                case "error":
                    let code = event["code"] as? String
                    self.settings.reportNativeErrorCode(code)
                    if TgwsProxySettings.isTransientStartupFailure(code) {
                        // UIKit lifecycle notifications and the native control
                        // queue can cross here. Do not turn that race into a
                        // permanent Unavailable state. Retry only a few times,
                        // while still fenced to this generation; the route
                        // remains the blocking localhost route throughout.
                        if TgwsProxySettings.shouldRetryStartupFailure(code, isActive: UIApplication.shared.applicationState == .active, retryCount: retryCount) {
                            self.stopNativeIfOwned(token: token, ownerID: ownerID) {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    guard !cancelled, token == self.generation else {
                                        if !finished { finished = true; subscriber.putNext(false); subscriber.putCompletion() }
                                        return
                                    }
                                    retryOperation.set(self.startInitial(snapshot: snapshot, token: token, accountManager: accountManager, retryCount: retryCount + 1)
                                        .start(next: { value in
                                            if !finished { finished = true; subscriber.putNext(value); subscriber.putCompletion() }
                                        }))
                                }
                            }
                        } else {
                            let safeCode = TgwsProxySettings.nativeFailureCode(code)
                            self.settings.reportState(UIApplication.shared.applicationState == .active ? .failed(safeCode) : .suspended)
                            if !finished { finished = true; subscriber.putNext(true); subscriber.putCompletion() }
                        }
                        return
                    }
                    self.settings.reportState(.failed(TgwsProxySettings.nativeFailureCode(code)))
                    if !finished {
                        finished = true
                        // Startup failure is a successful preparation outcome:
                        // the blocking localhost route must remain installed.
                        subscriber.putNext(true)
                        subscriber.putCompletion()
                    }
                case "upstream_connected":
                    self.settings.reportNativeErrorCode(nil)
                    self.settings.reportState(.upstreamConnected)
                case "client_handshake_rejected":
                    self.settings.reportNativeErrorCode(nil)
                    self.settings.reportClientHandshakeRejectionCode(event["code"] as? String)
                    self.settings.reportState(.handshakeRejected)
                case "upstream_connect_failed":
                    self.settings.reportNativeErrorCode(nil)
                    self.settings.reportState(.upstreamConnectFailed(TgwsProxySettings.upstreamFailureCode(event["code"] as? String)))
                case "stopped":
                    // A current stop is a terminal, fail-closed startup
                    // outcome. A stale stop is rejected by the generation
                    // fence above (and cannot stop a replacement owner).
                    self.settings.reportNativeErrorCode(nil)
                    self.settings.reportState(.failed("runtime_error"))
                    if !finished {
                        finished = true
                        subscriber.putNext(true)
                        subscriber.putCompletion()
                    }
                default:
                    break
                }
            })
            return ActionDisposable {
                if !finished {
                    cancelled = true
                    // Signal completion disposes the generator disposable, so
                    // a normal ready/error path must not stop the service. On
                    // cancellation, stop only the attempt which still owns
                    // this generation; a stale attempt must never stop its
                    // replacement. Cancellation does not complete a Signal,
                    // therefore release the initial barrier here as well.
                    if token == self.generation {
                        self.stopNativeIfOwned(token: token, ownerID: ownerID, completion: {})
                        DispatchQueue.main.async { [weak self] in
                            guard let self = self, token == self.generation else { return }
                            guard self.initialStarting else { return }
                            self.busy = false
                            self.initialStarting = false
                            if self.pending {
                                self.pending = false
                                self.reconcile()
                            }
                        }
                    }
                }
                retryOperation.dispose()
            }
        }
    }

    private func route(_ snapshot: TgwsProxySettings.Snapshot?, version: UInt64, accountManager: AccountManager<TelegramAccountManagerTypes>) -> Signal<Bool, NoError> {
        return accountManager.transaction { transaction -> Bool in
            return self.routeFence.mutate(version: version, settings: self.settings, snapshot: snapshot) {
            let current = transaction.getSharedData(SharedDataKeys.proxySettings)?.get(ProxySettings.self) ?? .defaultSettings
            let owned = transaction.getSharedData(Self.ownershipKey)?.get(TgwsManagedRoute.self)
            var updated = current
            var record: TgwsManagedRoute?
            if snapshot?.configuration.enabled ?? false {
                let config = snapshot?.configuration
                // Secure randomness failure must not freeze app UI or allow
                // direct networking. This identity is NEVER started as a service.
                let server = config.map {
                    let secretFingerprint = SHA256.hash(data: $0.secretData).prefix(8).map { String(format: "%02x", $0) }.joined()
                    self.lifecycleLog("route_secret_fp_\(secretFingerprint)")
                    return ProxyServerSettings(host: "127.0.0.1", port: Int32($0.port), connection: .mtp(secret: Data([0xdd]) + $0.secretData))
                } ?? owned?.server ?? ProxyServerSettings(host: "127.0.0.1", port: 0, connection: .mtp(secret: Data([0xdd]) + Data(repeating: 0, count: 16)))
                if let owned = owned, owned.server == server {
                    record = owned
                    // Do not repeatedly overwrite another actor's proxy edits.
                } else {
                    let base = owned?.restore(from: current) ?? current
                    let new = TgwsManagedRoute(previous: base, server: server)
                    record = new
                    updated = new.install(into: base)
                }
            } else {
                updated = owned?.restore(from: current) ?? current
            }
            transaction.updateSharedData(Self.ownershipKey, { _ in record.flatMap { PreferencesEntry($0) } })
            transaction.updateSharedData(SharedDataKeys.proxySettings, { _ in PreferencesEntry(updated) })
            }
        }
    }

    private func startRegularNative(snapshot: TgwsProxySettings.Snapshot?, token: Int,
                                    retryCount: Int) {
        precondition(Thread.isMainThread)
        lifecycleLog("start_regular_enter", token: token)
        guard token == self.generation else { return }
        guard let config = snapshot?.configuration else {
            lifecycleLog("start_regular_no_config", token: token)
            settings.reportState(.disabled)
            return
        }
        guard config.enabled else {
            lifecycleLog("start_regular_disabled", token: token)
            settings.reportState(.disabled)
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            lifecycleLog("start_regular_not_active", token: token)
            settings.reportState(.suspended)
            return
        }
        guard let json = try? JSONSerialization.data(withJSONObject: ["port": config.port, "secret": config.secret, "cfProxyEnabled": config.cfProxyEnabled, "cfProxyDomains": config.cfProxyDomains, "cfWorkerDomains": config.cfWorkerDomains, "dcRedirects": config.dcRedirects, "bufferKB": config.bufferKB, "poolSize": config.poolSize]) else {
            settings.reportState(.failed("invalid_config"))
            return
        }

        settings.reportState(.starting)
        settings.reportNativeErrorCode(nil)
        settings.reportClientHandshakeRejectionCode(nil)
        let ownerID = nativeOwnerID &+ 1
        nativeOwnerID = ownerID
        nativeOwnerToken = token
        nativeOperation.set(ActionDisposable { [weak self] in
            guard let self = self, self.nativeOwnerToken == token, self.nativeOwnerID == ownerID else { return }
            self.nativeOwnerToken = nil
            self.nativeOwnerID &+= 1
            RGTgwsService.shared().stop(completion: {})
        })
        RGTgwsService.shared().start(withConfigJSON: json, event: { [weak self] event in
            guard let self = self else { return }
            self.lifecycleLog("regular_event_\((event["state"] as? String) ?? "unknown")", token: token)
            guard token == self.generation else {
                // This callback can arrive after a replacement was started.
                // stopNativeIfOwned therefore cannot affect that replacement.
                self.stopNativeIfOwned(token: token, ownerID: ownerID, completion: {})
                return
            }
            guard self.nativeOwnerToken == token, self.nativeOwnerID == ownerID else { return }
            switch event["state"] as? String {
            case "ready":
                self.settings.reportNativeErrorCode(nil)
                self.settings.reportState(.ready)
            case "upstream_connected":
                self.settings.reportNativeErrorCode(nil)
                self.settings.reportState(.upstreamConnected)
            case "client_handshake_rejected":
                self.settings.reportNativeErrorCode(nil)
                self.settings.reportClientHandshakeRejectionCode(event["code"] as? String)
                self.settings.reportState(.handshakeRejected)
            case "upstream_connect_failed":
                self.settings.reportNativeErrorCode(nil)
                self.settings.reportState(.upstreamConnectFailed(TgwsProxySettings.upstreamFailureCode(event["code"] as? String)))
            case "stopped":
                // Do not restart or release ownership here. The current
                // generation has stopped, so keep the blocking route and
                // surface a redacted terminal native failure.
                self.settings.reportNativeErrorCode(nil)
                self.settings.reportState(.failed("runtime_error"))
            case "error":
                let code = event["code"] as? String
                self.settings.reportNativeErrorCode(code)
                if TgwsProxySettings.isTransientStartupFailure(code) {
                    guard TgwsProxySettings.shouldRetryStartupFailure(code, isActive: UIApplication.shared.applicationState == .active, retryCount: retryCount) else {
                        let safeCode = TgwsProxySettings.nativeFailureCode(code)
                        self.settings.reportState(UIApplication.shared.applicationState == .active ? .failed(safeCode) : .suspended)
                        return
                    }
                    self.settings.reportState(.starting)
                    // Do not call reconcile here: it is still busy with this
                    // generation.  Stop this owned attempt and retry its
                    // native start after the singleton has exited.
                    self.stopNativeIfOwned(token: token, ownerID: ownerID) { [weak self] in
                        guard let self = self else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            guard token == self.generation else { return }
                            self.startRegularNative(snapshot: snapshot, token: token, retryCount: retryCount + 1)
                        }
                    }
                } else {
                    self.settings.reportState(.failed(TgwsProxySettings.nativeFailureCode(code)))
                }
            default: break
            }
        })
    }

    private func stopNativeIfOwned(token: Int, ownerID: Int? = nil, completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        lifecycleLog("stop_if_owned_enter", token: token)
        guard nativeOwnerToken == token, ownerID == nil || nativeOwnerID == ownerID else {
            lifecycleLog("stop_if_owned_skip", token: token)
            completion()
            return
        }
        nativeOwnerToken = nil
        nativeOwnerID &+= 1
        // Replace the disposable before stopping. Its action is now inert,
        // while this explicit stop gives retry the actual exit boundary.
        nativeOperation.set(ActionDisposable {})
        RGTgwsService.shared().stop { [weak self] in
            self?.lifecycleLog("stop_if_owned_complete", token: token)
            completion()
        }
    }

    private func stopCurrentNative(completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        lifecycleLog("stop_current_enter")
        // Ownership is cleared when stop is requested, not when workers exit.
        // Even without an owner, join the native stop barrier: a retry or
        // cancellation may still be tearing down the singleton listener.
        nativeOwnerToken = nil
        nativeOwnerID &+= 1
        nativeOperation.set(ActionDisposable {})
        RGTgwsService.shared().stop { [weak self] in
            self?.lifecycleLog("stop_current_complete")
            completion()
        }
    }

    private func reconcile(retryCount: Int = 0) {
        precondition(Thread.isMainThread)
        generation += 1
        lifecycleLog("reconcile_enter")
        let version = routeFence.advance()
        if busy {
            pending = true
            lifecycleLog("reconcile_queued")
            // Initial preparation has no disposable operation to cancel.
            // Invalidate its native start so the startup signal can observe
            // the generation fence and retry with the current intent.
            if initialStarting {
                self.stopCurrentNative(completion: {})
            }
            return
        }
        guard let accountManager = accountManager else { return }
        let snapshot = try? settings.snapshot()
        busy = true
        pending = false
        let token = generation
        // Always wait for native workers to exit before restore or restart.
        self.stopCurrentNative { [weak self] in
            guard let self = self else { return }
            if self.pending || token != self.generation {
                self.lifecycleLog("stop_then_reconcile_stale", token: token)
                self.busy = false
                self.reconcile()
                return
            }
            self.lifecycleLog("stop_then_route", token: token)
            self.operation.set((self.route(snapshot, version: version, accountManager: accountManager)
            |> deliverOnMainQueue).start(next: { [weak self] applied in
                guard let self = self else { return }
                self.lifecycleLog("route_complete_\(applied)", token: token)
                self.busy = false
                if self.pending || token != self.generation { self.reconcile(); return }
                if !applied { self.reconcile(); return }
                self.startRegularNative(snapshot: snapshot, token: token, retryCount: retryCount)
            }))
        }
    }
}
