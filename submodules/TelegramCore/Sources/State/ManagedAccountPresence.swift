import Foundation
import TelegramApi
import Postbox
import SwiftSignalKit
import MtProtoKit

private typealias SignalKitTimer = SwiftSignalKit.Timer


private final class AccountPresenceManagerImpl {
    private let queue: Queue
    private let network: Network
    let isPerformingUpdate = ValuePromise<Bool>(false, ignoreRepeated: true)

    private var shouldKeepOnlinePresenceDisposable: Disposable?
    private var connectionStatusDisposable: Disposable?
    private let currentRequestDisposable = MetaDisposable()
    private var onlineTimer: SignalKitTimer?
    private var shouldKeepOnlinePresence = false
    private var blockOnlinePresence = false
    private var isConnected = false
    private var requestInFlight = false
    private var currentRequestIsOffline = false
    private var pendingOfflineRequest = false
    private var pendingNormalRequest: Bool?
    private var offlineRetryDelay: Double = 5.0
    private var offlineNotBefore: Date?
    private var requestGeneration: Int = 0
    
    init(queue: Queue, shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network) {
        self.queue = queue
        self.network = network
        
        self.shouldKeepOnlinePresenceDisposable = (combineLatest(shouldKeepOnlinePresence, ayuBlockOnlinePresenceSignal())
        |> deliverOn(self.queue)).start(next: { [weak self] value in
            self?.updateState(shouldKeepOnlinePresence: value.0, blockOnlinePresence: value.1)
        })
        self.connectionStatusDisposable = (network.connectionStatus
        |> deliverOn(self.queue)).start(next: { [weak self] status in
            self?.updateConnectionStatus(status)
        })
    }
    
    deinit {
        assert(self.queue.isCurrent())
        self.shouldKeepOnlinePresenceDisposable?.dispose()
        self.connectionStatusDisposable?.dispose()
        self.currentRequestDisposable.dispose()
        self.onlineTimer?.invalidate()
    }
    
    private func updateState(shouldKeepOnlinePresence: Bool, blockOnlinePresence: Bool) {
        let wasKeepingOnlinePresence = self.shouldKeepOnlinePresence
        let blockOnlinePresenceChanged = self.blockOnlinePresence != blockOnlinePresence
        self.shouldKeepOnlinePresence = shouldKeepOnlinePresence
        self.blockOnlinePresence = blockOnlinePresence

        if blockOnlinePresence {
            if blockOnlinePresenceChanged && self.requestInFlight && !self.currentRequestIsOffline {
                self.supersedeCurrentRequest()
            }
            if blockOnlinePresenceChanged || wasKeepingOnlinePresence != shouldKeepOnlinePresence {
                self.requestOffline()
            }
            self.updateOfflineKeeper()
        } else {
            self.stopTimer()
            self.pendingOfflineRequest = false
            self.updateNormalPresence(shouldKeepOnlinePresence)
        }
    }

    private func updateConnectionStatus(_ status: ConnectionStatus) {
        let wasConnected = self.isConnected
        if case .online = status {
            self.isConnected = true
        } else {
            self.isConnected = false
        }
        if self.blockOnlinePresence {
            if !wasConnected && self.isConnected && self.shouldKeepOnlinePresence {
                if !self.isOfflineRateLimited {
                    self.requestOffline()
                }
            }
            self.updateOfflineKeeper()
        }
    }

    private func updateNormalPresence(_ isOnline: Bool) {
        if isOnline {
            let timer = SignalKitTimer(timeout: 30.0, repeat: false, completion: { [weak self] in
                self?.updateNormalPresence(true)
            }, queue: self.queue)
            self.onlineTimer = timer
            timer.start()
            self.performRequest(offline: false)
        } else {
            self.stopTimer()
            self.performRequest(offline: true)
        }
    }

    private func requestOffline() {
        if self.blockOnlinePresence && self.isOfflineRateLimited {
            self.updateOfflineKeeper()
            return
        }
        guard !self.requestInFlight else {
            if !self.currentRequestIsOffline {
                self.pendingOfflineRequest = true
            }
            return
        }
        self.performRequest(offline: true)
    }

    private func performRequest(offline: Bool) {
        // All callers are serialized on this manager's private queue. Re-check
        // the setting at the final boundary so this manager cannot originate an
        // online update while ghost presence blocking is active.
        let effectiveOffline = self.blockOnlinePresence || offline
        guard !self.requestInFlight else {
            self.pendingNormalRequest = effectiveOffline
            return
        }
        self.requestInFlight = true
        self.currentRequestIsOffline = effectiveOffline
        self.requestGeneration += 1
        let requestGeneration = self.requestGeneration
        self.isPerformingUpdate.set(true)
        var retryDelay: Double?
        var floodWaitDeadline: Date?
        let shouldRetryGhostOffline = self.blockOnlinePresence && effectiveOffline
        self.currentRequestDisposable.set((self.network.request(Api.functions.account.updateStatus(offline: effectiveOffline ? .boolTrue : .boolFalse), automaticFloodWait: !shouldRetryGhostOffline)
        |> `catch` { error -> Signal<Api.Bool, NoError> in
            if shouldRetryGhostOffline {
                let retry = Self.retryDelay(for: error, fallback: self.offlineRetryDelay)
                retryDelay = retry.delay
                if retry.isFloodWait {
                    floodWaitDeadline = Date().addingTimeInterval(retry.delay)
                }
            }
            return .single(.boolFalse)
        }
        |> deliverOn(self.queue)).start(completed: { [weak self] in
            guard let self else { return }
            guard requestGeneration == self.requestGeneration else { return }
            self.requestInFlight = false
            self.isPerformingUpdate.set(false)
            if let retryDelay {
                self.offlineNotBefore = floodWaitDeadline ?? Date().addingTimeInterval(retryDelay)
            } else if retryDelay == nil {
                self.offlineNotBefore = nil
            }
            if retryDelay == nil {
                self.offlineRetryDelay = 5.0
            } else {
                self.offlineRetryDelay = min(300.0, self.offlineRetryDelay * 2.0)
            }
            if self.blockOnlinePresence, let retryDelay {
                self.pendingOfflineRequest = false
                self.pendingNormalRequest = nil
                self.updateOfflineKeeper(delay: retryDelay)
            } else if self.blockOnlinePresence && self.pendingOfflineRequest {
                self.pendingOfflineRequest = false
                self.pendingNormalRequest = nil
                self.requestOffline()
            } else if let pendingNormalRequest = self.pendingNormalRequest {
                self.pendingNormalRequest = nil
                self.performRequest(offline: pendingNormalRequest)
            } else if self.blockOnlinePresence {
                self.updateOfflineKeeper(delay: retryDelay)
            }
        }))
    }

    private func updateOfflineKeeper(delay: Double? = nil) {
        guard self.blockOnlinePresence && self.shouldKeepOnlinePresence && self.isConnected else {
            self.stopTimer()
            return
        }
        guard self.onlineTimer == nil && !self.requestInFlight else { return }
        let deadlineDelay = self.offlineNotBefore.map { max(0.0, $0.timeIntervalSinceNow) }
        let timer = SignalKitTimer(timeout: deadlineDelay ?? delay ?? 30.0, repeat: false, completion: { [weak self] in
            guard let self else { return }
            self.onlineTimer = nil
            guard self.blockOnlinePresence && self.shouldKeepOnlinePresence && self.isConnected else { return }
            self.requestOffline()
        }, queue: self.queue)
        self.onlineTimer = timer
        timer.start()
    }

    private static func retryDelay(for error: MTRpcError, fallback: Double) -> (delay: Double, isFloodWait: Bool) {
        if let description = error.errorDescription {
            for token in ["FLOOD_WAIT_", "FLOOD_PREMIUM_WAIT_"] {
                if let tokenRange = description.range(of: token) {
                    let value = description[tokenRange.upperBound...].prefix(while: { $0.isNumber })
                    if let seconds = Double(value), seconds > 0.0, seconds.isFinite {
                        return (seconds, true)
                    }
                }
            }
        }
        return (max(5.0, min(300.0, fallback)), false)
    }

    private var isOfflineRateLimited: Bool {
        guard let offlineNotBefore = self.offlineNotBefore else { return false }
        if offlineNotBefore > Date() {
            return true
        }
        self.offlineNotBefore = nil
        return false
    }

    private func supersedeCurrentRequest() {
        self.requestGeneration += 1
        self.currentRequestDisposable.set(nil)
        self.requestInFlight = false
        self.currentRequestIsOffline = false
        self.pendingNormalRequest = nil
        self.isPerformingUpdate.set(false)
    }

    private func stopTimer() {
        self.onlineTimer?.invalidate()
        self.onlineTimer = nil
    }
}

final class AccountPresenceManager {
    private let queue = Queue()
    private let impl: QueueLocalObject<AccountPresenceManagerImpl>
    
    init(shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network) {
        let queue = self.queue
        self.impl = QueueLocalObject(queue: self.queue, generate: {
            return AccountPresenceManagerImpl(queue: queue, shouldKeepOnlinePresence: shouldKeepOnlinePresence, network: network)
        })
    }
    
    func isPerformingUpdate() -> Signal<Bool, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.isPerformingUpdate.get().start(next: { value in
                    subscriber.putNext(value)
                }))
            }
            return disposable
        }
    }
}
