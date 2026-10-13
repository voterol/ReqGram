import Foundation
import SGSimpleSettings
import ReqGramPythonRuntime
import ReqGramNativeBridge
import UIKit
import SwiftSignalKit
import TelegramCore
import Postbox

// Unlike account operations, startup without an account is allowed. Comparing
// optional scopes also detects nil→account and same-account generation changes.
private func reqGramStartupScopeIsCurrent(_ scope: ReqGramMessageActions.Scope?) -> Bool {
    ReqGramMessageActions.shared.currentScope() == scope
}

#if DEBUG
/// App-owned testing seam, not introspection of UIKit's private action handlers.
enum ReqGramAlertTesting {
    static var handlers: [ObjectIdentifier: () -> Void] = [:]
    static func handler(for action: UIAlertAction) -> (() -> Void)? {
        precondition(Thread.isMainThread)
        return handlers[ObjectIdentifier(action)]
    }
}
#endif

/// One capability lifetime per loaded module. Never waits for main while holding Python's GIL.
private final class ReqGramHostSession {
    private let lock = NSLock()
    private var active = true
    private let messageOwner = UUID()
    private let messageScope: ReqGramMessageActions.Scope?
    var messageAuthorization: (() -> [String: Any])?
    var messageSendAuthorization: (() -> [String: Any])?
    var messageEditAuthorization: (() -> [String: Any])?
    var messageDeleteAuthorization: (() -> [String: Any])?
    var messageForwardAuthorization: (() -> [String: Any])?
    var watchMessages: ((Int64, [String], @escaping ([String: String]) -> Void, @escaping (String?) -> Void) -> Disposable)?
    var sendText: ((Int64, String, MessageId?, @escaping () -> String?, @escaping (Result<MessageId, ReqGramProviderError>) -> Void) -> Disposable)?
    var editText: ((Int64, MessageId, String, @escaping () -> String?, @escaping (Result<Bool, ReqGramProviderError>) -> Void) -> Disposable)?
    var deleteMessage: ((Int64, MessageId, String, @escaping () -> String?, @escaping (Result<String, ReqGramProviderError>) -> Void) -> Disposable)?
    var forwardMessage: ((Int64, MessageId, Int64, @escaping () -> String?, @escaping (Result<MessageId, ReqGramProviderError>) -> Void) -> Disposable)?
    private var subscriptions = Set<String>()
    private var events: [[String: String]] = []
    private var callbackMode = false
    private var callbackReady = false
    private var callbackScheduled = false
    private var callbackFailed = false
    private var dropped = 0
    private var delivered = 0
    private var scheduleDelivery: (() -> Void)?
    private var pending = false
    // A Bool is insufficient here: a callback from an older alert can arrive
    // after a new request has become pending and otherwise consume it.
    private var pendingRequest: UUID?
    private var lastAlert: TimeInterval = -.infinity
    private var observers: [NSObjectProtocol] = []
    private var messageEventDisposables = DisposableSet()
    private var messageWatches: [String: Disposable] = [:]
    private var pendingWatches = Set<String>()
    private struct MutationRecord {
        let fingerprint: String
        var event: [String: String]?
    }
    private var mutations: [String: MutationRecord] = [:]
    private var mutationOrder: [String] = []
    private var pendingMutations = Set<String>()
    private var mutationDisposables = DisposableSet()
    private var mtprotoDisposables = DisposableSet()
    private var mtprotoCancellations: [UUID: () -> Void] = [:]
    private var network: ReqGramNetworkSession?
    private let center: NotificationCenter
    private weak var alert: UIAlertController?
    private let nativeBridge = RGNativeBridgeSession()
    var accountSnapshot: ReqGramAccountSnapshot?
    var peerSnapshots: [Int64: ReqGramPeerSnapshot] = [:]
    private struct MutationPermissions {
        let send: Bool, edit: Bool, delete: Bool, forward: Bool
        func allows(_ operation: String?) -> Bool {
            switch operation { case "message.send": return send; case "message.edit": return edit; case "message.delete": return delete; case "message.forward": return forward; default: return false }
        }
        var any: Bool { send || edit || delete || forward }
    }
    // Callbacks may enter the manager queue; never evaluate them with session lock held.
    private func mutationPermissions() -> MutationPermissions {
        MutationPermissions(send: messageSendAuthorization?()["error"] == nil,
                            edit: messageEditAuthorization?()["error"] == nil,
                            delete: messageDeleteAuthorization?()["error"] == nil,
                            forward: messageForwardAuthorization?()["error"] == nil)
    }
    #if DEBUG
    var debugSubscriptions: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return subscriptions
    }
    var debugClosedAndEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return !active && !pending && events.isEmpty && subscriptions.isEmpty && observers.isEmpty
    }
    #endif
    init(center: NotificationCenter = .default, protocolClasses: [AnyClass]? = nil, messageScope: ReqGramMessageActions.Scope? = ReqGramMessageActions.shared.currentScope()) {
        self.messageScope = messageScope
        self.center = center
        #if DEBUG
        self.network = ReqGramNetworkSession(events: { [weak self] values in
            values.forEach { self?.emit($0) }
        }, protocolClasses: protocolClasses)
        #else
        self.network = ReqGramNetworkSession { [weak self] values in
            values.forEach { value in
                self?.emit(value)
            }
        }
        #endif
        for (name, event) in [(UIApplication.didBecomeActiveNotification, "app.active"), (UIApplication.willResignActiveNotification, "app.inactive")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.emit(["event": event]) })
        }
    }
    private func emit(_ event: [String: String], messageToken: UUID? = nil) {
        let mutationAllowed = event["event"] != "message.mutation" || mutationPermissions().allows(event["operation"])
        let scopeCurrent = ReqGramMessageActions.shared.isCurrent(messageScope)
        let actionRegistered = event["event"] != "message.action" || messageToken.map { ReqGramMessageActions.shared.isRegistered($0, owner: messageOwner) } == true
        lock.lock()
        if event["event"] == "message.change", !scopeCurrent {
            let watches = messageWatches.values
            messageWatches.removeAll()
            lock.unlock()
            watches.forEach { $0.dispose() }
            return
        }
        defer { lock.unlock() }
        guard active, subscriptions.contains(event["event"] ?? "") else { return }
        if event["event"] == "message.mutation" {
            guard accountContextErrorLocked(scopeCurrent: scopeCurrent) == nil, mutationAllowed else { return }
        }
        if event["event"] == "message.action" {
            guard messageToken != nil, scopeCurrent, actionRegistered else { return }
        }
        guard !callbackFailed else { return }
        if events.count == 64 { events.removeFirst(); dropped += 1 }
        events.append(event)
        scheduleLocked()
    }
    // Called with lock held; the scheduler only enqueues, never enters Python.
    private func scheduleLocked() {
        guard active, callbackMode, callbackReady, !callbackFailed, !callbackScheduled, !events.isEmpty,
              let scheduleDelivery else { return }
        callbackScheduled = true
        scheduleDelivery()
    }
    func armCallbacks(_ schedule: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        scheduleDelivery = schedule; callbackReady = true; scheduleLocked()
    }
    func takeCallbackEvent() -> Data? {
        let messageAllowed = messageAuthorization?()["plugin_id"] != nil
        let permissions = mutationPermissions()
        let scopeCurrent = ReqGramMessageActions.shared.isCurrent(messageScope)
        lock.lock(); defer { lock.unlock() }
        discardStaleMessageEvents(scopeCurrent: scopeCurrent)
        if !messageAllowed { events.removeAll { $0["event"] == "message.action" } }
        if accountContextErrorLocked(scopeCurrent: scopeCurrent) != nil { events.removeAll { $0["event"] == "message.mutation" } }
        else { events.removeAll { event in
            guard event["event"] == "message.mutation" else { return false }
            return !permissions.allows(event["operation"])
        } }
        guard active, callbackMode, callbackReady, !callbackFailed, !events.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: events.removeFirst())
    }
    func finishCallback(_ error: Error?) {
        lock.lock()
        callbackScheduled = false
        guard active else { lock.unlock(); return }
        if error != nil {
            callbackFailed = true; events.removeAll()
            NSLog("[ReqGramPython] event delivery suspended (callback or execution boundary failure)")
        } else { delivered += 1 }
        scheduleLocked()
        let removeActions = error != nil
        lock.unlock()
        if removeActions { ReqGramMessageActions.shared.remove(owner: messageOwner) }
    }
    func close() {
        lock.lock()
        guard active else { lock.unlock(); return }
        active = false; pending = false; pendingRequest = nil; subscriptions.removeAll(); events.removeAll(); pendingMutations.removeAll(); pendingWatches.removeAll(); mutations.removeAll(); mutationOrder.removeAll()
        callbackReady = false; scheduleDelivery = nil
        let tokens = observers; observers.removeAll()
        let watches = Array(messageWatches.values); messageWatches.removeAll()
        let mtprotoCancellations = Array(self.mtprotoCancellations.values); self.mtprotoCancellations.removeAll()
        lock.unlock()
        ReqGramMessageActions.shared.remove(owner: messageOwner)
        tokens.forEach { center.removeObserver($0) }
        network?.close(); network = nil
        nativeBridge.close()
        messageEventDisposables.dispose()
        mutationDisposables.dispose()
        mtprotoDisposables.dispose()
        mtprotoCancellations.forEach { $0() }
        watches.forEach { $0.dispose() }
        DispatchQueue.main.async { [self] in
            #if DEBUG
            alert?.actions.forEach { ReqGramAlertTesting.handlers.removeValue(forKey: ObjectIdentifier($0)) }
            #endif
            alert?.dismiss(animated: false); alert = nil
        }
    }
    deinit { observers.forEach { center.removeObserver($0) } }
    private func discardStaleMessageEvents(scopeCurrent: Bool) {
        if !scopeCurrent {
            events.removeAll { $0["event"] == "message.action" }
        }
    }
    // The captured scope includes a generation: returning to the same account
    // must not revive this session or its snapshots.
    private func accountContextErrorLocked(scopeCurrent: Bool) -> String? {
        guard active else { return "session_inactive" }
        guard scopeCurrent else { return "account_context_unavailable" }
        return nil
    }
    func accountContextError() -> String? {
        let scopeCurrent = ReqGramMessageActions.shared.isCurrent(messageScope)
        lock.lock(); defer { lock.unlock() }
        return accountContextErrorLocked(scopeCurrent: scopeCurrent)
    }
    func cancelNetwork(_ bytes: Data?) -> [String: Any] {
        network?.cancel(bytes) ?? ["error": "session_inactive"]
    }
    func nativeRequest(_ operation: String, _ bytes: Data?) -> [String: Any] {
        nativeBridge.requestOperation(operation, payload: bytes)
    }
    func mtprotoRequest(_ operation: String, _ bytes: Data?, provider: ReqGramAccountProvider?) -> [String: Any] {
        guard !Thread.isMainThread else { return ["error": "main_thread_unavailable"] }
        guard let provider, accountContextError() == nil else { return ["error": accountContextError() ?? "account_context_unavailable"] }
        let input: ReqGramMTProtoInput
        switch ReqGramMTProtoInput.parse(bytes, jsonTL: operation == "mtproto.json") {
        case let .success(value): input = value
        case let .failure(error): return ["error": error.code]
        }
        let semaphore = DispatchSemaphore(value: 0); let resultLock = NSLock(); let launchLock = NSLock()
        var result: [String: Any] = ["error": "mtproto_timeout", "request_id": input.requestId]
        var finished = false
        var disposable: Disposable?
        let cancellationId = UUID()
        let complete: (Result<Data, ReqGramMTProtoError>) -> Void = { value in
            resultLock.lock(); defer { resultLock.unlock() }
            guard !finished else { return }
            finished = true
            self.lock.lock(); self.mtprotoCancellations.removeValue(forKey: cancellationId); self.lock.unlock()
            let terminalValue: Result<Data, ReqGramMTProtoError>
            if self.accountContextError() != nil {
                terminalValue = .failure(ReqGramMTProtoError(code: "session_inactive", rpcCode: nil, rpcMessage: nil))
            } else {
                terminalValue = value
            }
            switch terminalValue {
            case let .success(body): result = ["data": body.base64EncodedString(), "request_id": input.requestId]
            case let .failure(failure):
                var error: [String: Any] = ["code": failure.code]; if let code = failure.rpcCode { error["rpc_code"] = code }; if let message = failure.rpcMessage { error["rpc_message"] = message }
                result = ["error": error, "request_id": input.requestId]
            }
            if let current = disposable {
                self.mtprotoDisposables.remove(current)
                current.dispose()
            }
            semaphore.signal()
        }
        self.lock.lock()
        guard active else { self.lock.unlock(); return ["error": "session_inactive"] }
        mtprotoCancellations[cancellationId] = {
            complete(.failure(ReqGramMTProtoError(code: "session_inactive", rpcCode: nil, rpcMessage: nil)))
        }
        self.lock.unlock()
        // Account.network is main-thread owned. Queue creation asynchronously:
        // this both avoids a main-thread deadlock and lets the deadline win
        // before a congested main queue can create a new request.
        DispatchQueue.main.async {
            launchLock.lock(); defer { launchLock.unlock() }
            resultLock.lock()
            let alreadyFinished = finished
            resultLock.unlock()
            guard !alreadyFinished else { return }
            guard self.accountContextError() == nil else {
                complete(.failure(ReqGramMTProtoError(code: "account_context_unavailable", rpcCode: nil, rpcMessage: nil)))
                return
            }
            let created = provider.mtproto(body: input.body, completion: complete)
            resultLock.lock()
            if finished {
                resultLock.unlock()
                created.dispose()
            } else {
                disposable = created
                // Registration is thread-safe and DisposableSet immediately
                // disposes a request racing with session close.
                self.mtprotoDisposables.add(created)
                resultLock.unlock()
            }
        }
        if semaphore.wait(timeout: .now() + input.timeout) == .timedOut {
            launchLock.lock()
            resultLock.lock()
            if !finished {
                finished = true
                let current = disposable
                resultLock.unlock()
                launchLock.unlock()
                self.lock.lock(); self.mtprotoCancellations.removeValue(forKey: cancellationId); self.lock.unlock()
                if let current {
                    self.mtprotoDisposables.remove(current)
                    current.dispose()
                }
            } else {
                resultLock.unlock()
                launchLock.unlock()
            }
        }
        resultLock.lock(); let finalResult = result; resultLock.unlock()
        return finalResult
    }
    private func mutationAdmissionError(key: String, authorization: @escaping () -> [String: Any]?) -> String? {
        // Authorization may enter the manager queue, so never evaluate it while
        // holding the session lock (disable closes this session from that queue).
        if let failure = authorization()?["error"] as? String { return failure }
        let scopeCurrent = ReqGramMessageActions.shared.isCurrent(messageScope)
        lock.lock(); defer { lock.unlock() }
        if let failure = accountContextErrorLocked(scopeCurrent: scopeCurrent) { return failure }
        guard pendingMutations.contains(key) else { return "session_inactive" }
        return nil
    }
    private func hasSubscription(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && subscriptions.contains(name)
    }
    func request(_ operation: String, _ bytes: Data?, networkInsecureAllowed: Bool = false) -> [String: Any] {
        func error(_ code: String) -> [String: Any] { ["error": code] }
        func data(_ value: Any) -> [String: Any] { ["data": (try? JSONSerialization.data(withJSONObject: value)) ?? Data()] }
        // Never synchronously enter the manager queue while holding the session lock:
        // disable closes this session from that queue.
        let messagePermission = messageAuthorization?()
        let messageSendPermission = messageSendAuthorization?()
        let mutationPermissionSnapshot = operation == "events.poll" || operation == "events.subscribe" || operation == "events.unsubscribe" ? mutationPermissions() : nil
        let scopeCurrentSnapshot = ReqGramMessageActions.shared.isCurrent(messageScope)
        // Watch setup is provider-owned and must run on main. Keep it outside the
        // session lock; provider validation errors are reported by the completion
        // event (the synchronous result only acknowledges admission).
        if operation == "message.events.watch" || operation == "message.events.unwatch" {
            guard messagePermission?["plugin_id"] != nil else { return error("permission_denied") }
             guard hasSubscription("message.change") else { return error("subscription_required") }
            guard let bytes, bytes.count <= 4096,
                  let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(object.keys) == ["peer_id", "message_ids"],
                  let peer = object["peer_id"] as? String, let peerId = Int64(peer), String(peerId) == peer,
                  let ids = object["message_ids"] as? [String], !ids.isEmpty, ids.count <= 8,
                  Set(ids).count == ids.count,
                  ids.allSatisfy({ id in guard let parsed = reqGramMessageId(id) else { return false }; return parsed.peerId == PeerId(peerId) && parsed.namespace == Namespaces.Message.Cloud }) else { return error("invalid_payload") }
            let key = "\(peerId):" + ids.sorted().joined(separator: ",")
            if operation == "message.events.unwatch" {
                lock.lock(); pendingWatches.remove(key); let disposable = messageWatches.removeValue(forKey: key); lock.unlock()
                disposable?.dispose()
                return [:]
            }
            lock.lock()
            guard active else { lock.unlock(); return error("session_inactive") }
             guard messageWatches[key] == nil, !pendingWatches.contains(key) else { lock.unlock(); return [:] }
             guard messageWatches.count < 16 else { lock.unlock(); return error("watch_limit") }
             pendingWatches.insert(key)
             lock.unlock()
             guard let watchMessages else {
                 lock.lock(); pendingWatches.remove(key); lock.unlock()
                 return error("provider_unavailable")
             }
            let setup = {
                var installed: Disposable?
                installed = watchMessages(peerId, ids, { [weak self] event in self?.emit(event) }) { [weak self] failure in
                    guard let self, let failure else { return }
                    self.emit(["event": "message.change", "error": failure, "peer_id": String(peerId)])
                }
                self.lock.lock(); defer { self.lock.unlock() }
                 guard self.active, self.subscriptions.contains("message.change"), self.pendingWatches.remove(key) != nil, let installed else { installed?.dispose(); return }
                self.messageWatches[key] = installed
            }
            if Thread.isMainThread { setup() } else { DispatchQueue.main.async(execute: setup) }
            return ["status": "pending"]
        }
        if operation == "message.send" {
            guard messageSendPermission?["error"] == nil else { return error("permission_denied") }
             guard hasSubscription("message.mutation") else { return error("subscription_required") }
            guard accountContextError() == nil else { return error(accountContextError() ?? "account_context_unavailable") }
            guard let bytes, bytes.count <= 20 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(object.keys).isSubset(of: ["request_id", "idempotency_key", "peer_id", "text", "reply_to_message_id"]),
                  Set(object.keys).isSuperset(of: ["request_id", "idempotency_key", "peer_id", "text"]),
                  let requestId = object["request_id"] as? String,
                  let idempotencyKey = object["idempotency_key"] as? String,
                  requestId.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil,
                  idempotencyKey.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
                  let peerString = object["peer_id"] as? String, let peerId = Int64(peerString), String(peerId) == peerString, peerId != 0,
                  [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(PeerId(peerId).namespace),
                  let text = object["text"] as? String, !text.isEmpty, text.utf8.count <= 16 * 1024 else { return error("invalid_payload") }
            if object.keys.contains("reply_to_message_id"), !(object["reply_to_message_id"] is String) { return error("invalid_payload") }
            let replyString = object["reply_to_message_id"] as? String
            let replyId = replyString.flatMap(reqGramMessageId)
            guard replyString == nil || (replyId?.peerId == PeerId(peerId) && replyId?.namespace == Namespaces.Message.Cloud) else { return error("invalid_payload") }
            let fingerprint = [requestId, peerString, text, replyString ?? ""].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
            lock.lock()
            if let existing = mutations[idempotencyKey] {
                guard existing.fingerprint == fingerprint else { lock.unlock(); return error("idempotency_conflict") }
                let cached = existing.event
                lock.unlock()
                if let cached { emit(cached) }
                return ["status": "pending"]
            }
            guard pendingMutations.count < 16 else { lock.unlock(); return error("mutation_limit") }
            while mutations.count >= 64, let oldest = mutationOrder.first, !pendingMutations.contains(oldest) {
                mutationOrder.removeFirst(); mutations.removeValue(forKey: oldest)
            }
            guard mutations.count < 64 else { lock.unlock(); return error("mutation_limit") }
            mutations[idempotencyKey] = MutationRecord(fingerprint: fingerprint, event: nil)
            mutationOrder.append(idempotencyKey)
            pendingMutations.insert(idempotencyKey)
            lock.unlock()
            guard let sendText else {
                lock.lock(); pendingMutations.remove(idempotencyKey); mutations.removeValue(forKey: idempotencyKey); mutationOrder.removeAll { $0 == idempotencyKey }; lock.unlock()
                return error("provider_unavailable")
            }
            let setup = { [weak self] in
                guard let self else { return }
                guard self.accountContextError() == nil, self.messageSendAuthorization?()["error"] == nil else {
                    self.finishMutation(key: idempotencyKey, event: ["event": "message.mutation", "operation": "message.send", "request_id": requestId, "idempotency_key": idempotencyKey, "error": "account_context_unavailable"])
                    return
                }
                let disposable = sendText(peerId, text, replyId, { [weak self] in
                    self?.mutationAdmissionError(key: idempotencyKey, authorization: { self?.messageSendAuthorization?() }) ?? "session_inactive"
                }) { [weak self] result in
                    guard let self else { return }
                    let event: [String: String]
                    if let failure = self.accountContextError() ?? (self.messageSendAuthorization?()["error"] as? String) {
                        event = ["event": "message.mutation", "operation": "message.send", "request_id": requestId, "idempotency_key": idempotencyKey, "error": failure]
                    } else {
                        switch result {
                        case let .success(id):
                            event = ["event": "message.mutation", "operation": "message.send", "request_id": requestId, "idempotency_key": idempotencyKey, "status": "queued", "consistency": "local", "peer_id": peerString, "local_message_id": "\(id.peerId.toInt64())_\(id.namespace)_\(id.id)"]
                        case let .failure(failure):
                            event = ["event": "message.mutation", "operation": "message.send", "request_id": requestId, "idempotency_key": idempotencyKey, "error": failure.code]
                        }
                    }
                    self.finishMutation(key: idempotencyKey, event: event)
                }
                self.lock.lock(); let live = self.active && self.pendingMutations.contains(idempotencyKey); self.lock.unlock()
                if live { self.mutationDisposables.add(disposable) } else { disposable.dispose() }
            }
            if Thread.isMainThread { setup() } else { DispatchQueue.main.async(execute: setup) }
            return ["status": "pending"]
        }
        if operation == "message.media.send" {
            return error("unsupported_operation")
            /*
            guard messageMediaSendAuthorization?()["error"] == nil else { return error("permission_denied") }
             guard hasSubscription("message.mutation") else { return error("subscription_required") }
            guard accountContextError() == nil else { return error(accountContextError() ?? "account_context_unavailable") }
            guard let bytes, bytes.count <= 20 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(object.keys) == ["request_id", "idempotency_key", "peer_id", "file_token", "file_name", "mime_type", "caption"],
                  let requestId = object["request_id"] as? String, let key = object["idempotency_key"] as? String,
                  requestId.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil,
                  key.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
                  let peerString = object["peer_id"] as? String, let peerId = Int64(peerString), String(peerId) == peerString, peerId != 0,
                  let token = object["file_token"] as? String, token.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil,
                  let name = object["file_name"] as? String, !name.isEmpty, name.utf8.count <= 255, !name.contains("/"), !name.contains("\\"),
                  let mime = object["mime_type"] as? String, mime.utf8.count <= 255,
                  let caption = object["caption"] as? String, caption.utf8.count <= 16 * 1024 else { return error("invalid_payload") }
            let fingerprint = [requestId, peerString, token, name, mime, caption].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
            lock.lock()
            if let existing = mutations[key] { guard existing.fingerprint == fingerprint else { lock.unlock(); return error("idempotency_conflict") }; let cached = existing.event; lock.unlock(); if let cached { emit(cached) }; return ["status": "pending"] }
            guard pendingMutations.count < 16 else { lock.unlock(); return error("mutation_limit") }
            mutations[key] = MutationRecord(fingerprint: fingerprint, event: nil); mutationOrder.append(key); pendingMutations.insert(key); lock.unlock()
            guard let sendMedia else { lock.lock(); pendingMutations.remove(key); mutations.removeValue(forKey: key); lock.unlock(); return error("provider_unavailable") }
            let setup = { [weak self] in
                guard let self else { return }
                guard self.accountContextError() == nil, self.messageMediaSendAuthorization?()["error"] == nil else { self.finishMutation(key: key, event: ["event":"message.mutation", "operation":"message.media.send", "request_id":requestId, "idempotency_key":key, "error":"permission_denied"]); return }
                let disposable = sendMedia(peerId, token, name, mime, caption, { [weak self] in self?.mutationAdmissionError(key: key, authorization: { self?.messageMediaSendAuthorization?() }) ?? "session_inactive" }) { [weak self] result in
                    guard let self else { return }; var event = ["event":"message.mutation", "operation":"message.media.send", "request_id":requestId, "idempotency_key":key]
                    if let failure = self.accountContextError() ?? (self.messageMediaSendAuthorization?()["error"] as? String) { event["error"] = failure } else { switch result { case let .success(id): event["status"] = "queued"; event["consistency"] = "local"; event["peer_id"] = peerString; event["local_message_id"] = "\(id.peerId.toInt64())_\(id.namespace)_\(id.id)"; case let .failure(failure): event["error"] = failure } }
                    self.finishMutation(key: key, event: event)
                }
                self.lock.lock(); let live = self.active && self.pendingMutations.contains(key); self.lock.unlock(); if live { self.mutationDisposables.add(disposable) } else { disposable.dispose() }
            }
             if Thread.isMainThread { setup() } else { DispatchQueue.main.async(execute: setup) }; return ["status": "pending"] */
        }
        if operation == "message.forward" {
            guard messageForwardAuthorization?()["error"] == nil else { return error("permission_denied") }
             guard hasSubscription("message.mutation") else { return error("subscription_required") }
            guard accountContextError() == nil else { return error(accountContextError() ?? "account_context_unavailable") }
            guard let bytes, bytes.count <= 20 * 1024, let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], Set(object.keys) == ["request_id", "idempotency_key", "source_peer_id", "source_message_id", "destination_peer_id"], let requestId = object["request_id"] as? String, let key = object["idempotency_key"] as? String, requestId.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil, key.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil, let sourceString = object["source_peer_id"] as? String, let source = Int64(sourceString), String(source) == sourceString, let destinationString = object["destination_peer_id"] as? String, let destination = Int64(destinationString), String(destination) == destinationString, source != 0, destination != 0, let messageString = object["source_message_id"] as? String, let message = reqGramMessageId(messageString), message.peerId == PeerId(source), message.namespace == Namespaces.Message.Cloud, [source, destination].allSatisfy({ [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(PeerId($0).namespace) }) else { return error("invalid_payload") }
            let fingerprint = [requestId, sourceString, messageString, destinationString].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
            lock.lock()
            if let existing = mutations[key] { guard existing.fingerprint == fingerprint else { lock.unlock(); return error("idempotency_conflict") }; let cached = existing.event; lock.unlock(); if let cached { emit(cached) }; return ["status": "pending"] }
            guard pendingMutations.count < 16 else { lock.unlock(); return error("mutation_limit") }
            while mutations.count >= 64, let oldest = mutationOrder.first, !pendingMutations.contains(oldest) { mutationOrder.removeFirst(); mutations.removeValue(forKey: oldest) }
            guard mutations.count < 64 else { lock.unlock(); return error("mutation_limit") }
            mutations[key] = MutationRecord(fingerprint: fingerprint, event: nil); mutationOrder.append(key); pendingMutations.insert(key); lock.unlock()
            guard let forwardMessage else { lock.lock(); pendingMutations.remove(key); mutations.removeValue(forKey: key); lock.unlock(); return error("provider_unavailable") }
            let setup = { [weak self] in
                guard let self else { return }
                guard self.accountContextError() == nil, self.messageForwardAuthorization?()["error"] == nil else { self.finishMutation(key: key, event: ["event":"message.mutation", "operation":"message.forward", "request_id":requestId, "idempotency_key":key, "error":"permission_denied"]); return }
                let disposable = forwardMessage(source, message, destination, { [weak self] in self?.mutationAdmissionError(key: key, authorization: { self?.messageForwardAuthorization?() }) ?? "session_inactive" }) { [weak self] result in
                    guard let self else { return }; var event = ["event":"message.mutation", "operation":"message.forward", "request_id":requestId, "idempotency_key":key]
                     if let failure = self.accountContextError() ?? (self.messageForwardAuthorization?()["error"] as? String) { event["error"] = self.forwardErrorCode(failure) } else { switch result { case let .success(id): event["status"] = "queued"; event["consistency"] = "local"; event["source_peer_id"] = sourceString; event["source_message_id"] = messageString; event["destination_peer_id"] = destinationString; event["local_message_id"] = "\(id.peerId.toInt64())_\(id.namespace)_\(id.id)"; case let .failure(failure): event["error"] = self.forwardErrorCode(failure.code) } }
                    self.finishMutation(key: key, event: event)
                }
                self.lock.lock(); let live = self.active && self.pendingMutations.contains(key); self.lock.unlock(); if live { self.mutationDisposables.add(disposable) } else { disposable.dispose() }
            }
             if Thread.isMainThread { setup() } else { DispatchQueue.main.async(execute: setup) }
              return ["status": "pending"]
        }
        if operation == "message.edit" {
            guard messageEditAuthorization?()["error"] == nil else { return error("permission_denied") }
             guard hasSubscription("message.mutation") else { return error("subscription_required") }
            guard accountContextError() == nil else { return error(accountContextError() ?? "account_context_unavailable") }
            guard let bytes, bytes.count <= 20 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(object.keys) == ["request_id", "idempotency_key", "peer_id", "message_id", "text"],
                  let requestId = object["request_id"] as? String, let idempotencyKey = object["idempotency_key"] as? String,
                  requestId.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil,
                  idempotencyKey.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
                  let peerString = object["peer_id"] as? String, let peerId = Int64(peerString), String(peerId) == peerString, peerId != 0,
                  [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(PeerId(peerId).namespace),
                  let messageString = object["message_id"] as? String, let messageId = reqGramMessageId(messageString),
                  messageId.peerId == PeerId(peerId), messageId.namespace == Namespaces.Message.Cloud,
                  let text = object["text"] as? String, !text.isEmpty, text.utf8.count <= 16 * 1024 else { return error("invalid_payload") }
            let fingerprint = [requestId, peerString, messageString, text].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
            lock.lock()
            if let existing = mutations[idempotencyKey] {
                guard existing.fingerprint == fingerprint else { lock.unlock(); return error("idempotency_conflict") }
                let cached = existing.event; lock.unlock(); if let cached { emit(cached) }; return ["status": "pending"]
            }
            guard pendingMutations.count < 16 else { lock.unlock(); return error("mutation_limit") }
            while mutations.count >= 64, let oldest = mutationOrder.first, !pendingMutations.contains(oldest) { mutationOrder.removeFirst(); mutations.removeValue(forKey: oldest) }
            guard mutations.count < 64 else { lock.unlock(); return error("mutation_limit") }
            mutations[idempotencyKey] = MutationRecord(fingerprint: fingerprint, event: nil); mutationOrder.append(idempotencyKey); pendingMutations.insert(idempotencyKey); lock.unlock()
            guard let editText else { lock.lock(); pendingMutations.remove(idempotencyKey); mutations.removeValue(forKey: idempotencyKey); lock.unlock(); return error("provider_unavailable") }
            let setup = { [weak self] in
                guard let self else { return }
                 guard self.accountContextError() == nil, self.messageEditAuthorization?()["error"] == nil else { self.finishMutation(key: idempotencyKey, event: ["event":"message.mutation","operation":"message.edit","request_id":requestId,"idempotency_key":idempotencyKey,"error":"permission_denied"]); return }
                 let disposable = editText(peerId, messageId, text, { [weak self] in self?.mutationAdmissionError(key: idempotencyKey, authorization: { self?.messageEditAuthorization?() }) ?? "session_inactive" }) { [weak self] result in
                    guard let self else { return }; var event = ["event":"message.mutation","operation":"message.edit","request_id":requestId,"idempotency_key":idempotencyKey]
                    if let failure = self.accountContextError() ?? (self.messageEditAuthorization?()["error"] as? String) { event["error"] = failure }
                      else { switch result { case let .success(changed): event["status"] = changed ? "succeeded" : "unchanged"; case let .failure(failure): event["status"] = ["restricted","text_too_long","invalid_grouping","invalid_target","permission_denied","edit_failed"].contains(failure.code) ? failure.code : "edit_failed" } }
                    self.finishMutation(key: idempotencyKey, event: event)
                }
                self.lock.lock(); let live = self.active && self.pendingMutations.contains(idempotencyKey); self.lock.unlock(); if live { self.mutationDisposables.add(disposable) } else { disposable.dispose() }
            }
            if Thread.isMainThread { setup() } else { DispatchQueue.main.async(execute: setup) }
            return ["status": "pending"]
        }
        if operation == "message.delete" {
             if let failure = messageDeleteAuthorization?()["error"] as? String { return error(failure) }
             guard hasSubscription("message.mutation") else { return error("subscription_required") }
             if let failure = accountContextError() { return error(failure) }
             guard let bytes, bytes.count <= 20 * 1024, let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], Set(object.keys) == ["request_id", "idempotency_key", "peer_id", "message_id", "scope"], let requestId = object["request_id"] as? String, let key = object["idempotency_key"] as? String, requestId.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil, key.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil, let peerString = object["peer_id"] as? String, let peer = Int64(peerString), String(peer) == peerString, [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(PeerId(peer).namespace), let messageString = object["message_id"] as? String, let message = reqGramMessageId(messageString), message.peerId == PeerId(peer), message.namespace == Namespaces.Message.Cloud, let scope = object["scope"] as? String, scope == "local" else { return error("invalid_payload") }
            let fingerprint = [requestId, peerString, messageString, scope].joined(separator: "|")
            lock.lock()
            if let existing = mutations[key] { let cached = existing.event; let same = existing.fingerprint == fingerprint; lock.unlock(); guard same else { return error("idempotency_conflict") }; if let cached { emit(cached) }; return ["status": "pending"] }
            guard pendingMutations.count < 16 else { lock.unlock(); return error("mutation_limit") }
            while mutations.count >= 64, let oldest = mutationOrder.first, !pendingMutations.contains(oldest) { mutationOrder.removeFirst(); mutations.removeValue(forKey: oldest) }
            guard mutations.count < 64 else { lock.unlock(); return error("mutation_limit") }
            mutations[key] = MutationRecord(fingerprint: fingerprint, event: nil); mutationOrder.append(key); pendingMutations.insert(key); lock.unlock()
             guard let deleteMessage else { lock.lock(); pendingMutations.remove(key); mutations.removeValue(forKey: key); mutationOrder.removeAll { $0 == key }; lock.unlock(); return error("provider_unavailable") }
             let setup = { [weak self] in
                 guard let self else { return }
                   if let failure = self.accountContextError() ?? (self.messageDeleteAuthorization?()["error"] as? String) {
                       self.finishMutation(key: key, event: ["event":"message.mutation", "operation":"message.delete", "request_id":requestId, "idempotency_key":key, "consistency":"local", "error":failure]); return
                   }
                 let disposable = deleteMessage(peer, message, scope, { [weak self] in self?.mutationAdmissionError(key: key, authorization: { self?.messageDeleteAuthorization?() }) ?? "session_inactive" }) { [weak self] result in
                     guard let self else { return }; var event = ["event":"message.mutation", "operation":"message.delete", "request_id":requestId, "idempotency_key":key, "consistency":"local"]
                       if let failure = self.accountContextError() ?? (self.messageDeleteAuthorization?()["error"] as? String) { event["error"] = failure }
                       else { switch result { case let .success(status): event["status"] = status; event["remote_confirmation"] = "not_requested"; case let .failure(failure): event["error"] = failure.code } }
                     self.finishMutation(key: key, event: event)
                 }
                 self.lock.lock(); let live = self.active && self.pendingMutations.contains(key); self.lock.unlock()
                 if live { self.mutationDisposables.add(disposable) } else { disposable.dispose() }
             }
             if Thread.isMainThread { setup() } else { DispatchQueue.main.async(execute: setup) }; return ["status":"pending"]
        }
        lock.lock(); defer { lock.unlock() }
        guard active else { return error("session_inactive") }
        if operation == "accounts.list" || operation == "account.context" || operation == "peer.lookup",
           let failure = accountContextErrorLocked(scopeCurrent: scopeCurrentSnapshot) { return error(failure) }
        switch operation {
        case "messages.register", "messages.unregister":
            guard let authorization = messagePermission, authorization["error"] == nil,
                  let plugin = authorization["plugin_id"] as? String else { return error("permission_denied") }
            if operation == "messages.unregister" {
                let failure = ReqGramMessageActions.shared.unregister(owner: messageOwner, bytes: bytes)
                if failure == nil, let bytes, let object = try? JSONDecoder().decode([String: String].self, from: bytes) {
                    events.removeAll { $0["event"] == "message.action" && $0["action_id"] == object["id"] }
                }
                return failure.map(error) ?? [:]
            }
            guard subscriptions.contains("message.action") else { return error("subscription_required") }
            let failure = ReqGramMessageActions.shared.register(owner: messageOwner, scope: messageScope, plugin: plugin, bytes: bytes) { [weak self] event, token in
                guard let self, self.messageAuthorization?()["error"] == nil else { return }
                self.emit(event, messageToken: token)
            }
            return failure.map(error) ?? [:]
        case "accounts.list", "account.context":
            guard bytes == nil else { return error("invalid_payload") }
            guard let snapshot = accountSnapshot else { return error("account_context_unavailable") }
            if operation == "accounts.list" { return data(["accounts": snapshot.accounts, "consistency": "session_snapshot"]) }
            return data(["current_account": snapshot.current as Any? ?? NSNull(), "consistency": "session_snapshot"])
        case "peer.lookup":
            guard let bytes, let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  object.keys.count == 1, object.keys.contains("peer_id"),
                  let number = object["peer_id"] as? NSNumber, number.int64Value != 0,
                  number.stringValue == String(number.int64Value) else { return error("invalid_payload") }
            guard let peer = peerSnapshots[number.int64Value] else { return error("peer_not_found") }
            return data(peer.dictionary())
        case "app.info":
            guard bytes == nil else { return error("invalid_payload") }
            return data(["platform": "ios", "client": "ReqGram", "bundle_id": Bundle.main.bundleIdentifier ?? "", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "", "os_version": ProcessInfo.processInfo.operatingSystemVersionString, "api_version": "1"])
        case "events.subscribe", "events.unsubscribe":
            guard let bytes = bytes, bytes.count <= 512, let names = try? JSONDecoder().decode([String].self, from: bytes), names.count <= 3, Set(names).isSubset(of: ["app.active", "app.inactive", "ui.action", "network.response", "message.action", "message.change", "message.mutation"]) else { return error("invalid_payload") }
            if names.contains("message.action"), messagePermission?["plugin_id"] == nil { return error("permission_denied") }
            if names.contains("message.mutation"), mutationPermissionSnapshot?.any != true { return error("permission_denied") }
            if operation == "events.subscribe" { subscriptions.formUnion(names) }
            else {
                subscriptions.subtract(names); events.removeAll { names.contains($0["event"] ?? "") }
                if names.contains("message.action") { ReqGramMessageActions.shared.remove(owner: messageOwner) }
                if names.contains("message.change") {
                    let watches = messageWatches.values
                    messageWatches.removeAll()
                    watches.forEach { $0.dispose() }
                }
            }
            return [:]
        case "events.poll":
            discardStaleMessageEvents(scopeCurrent: scopeCurrentSnapshot)
            if messagePermission?["plugin_id"] == nil { events.removeAll { $0["event"] == "message.action" } }
            if accountContextErrorLocked(scopeCurrent: scopeCurrentSnapshot) != nil { events.removeAll { $0["event"] == "message.mutation" } }
            else { events.removeAll { $0["event"] == "message.mutation" && mutationPermissionSnapshot?.allows($0["operation"]) != true } }
            guard bytes == nil else { return error("invalid_payload") }
            guard !callbackMode else { return error("callback_mode") }
            let result = data(events); events.removeAll(); return result
        case "events.callback":
            guard bytes == nil else { return error("invalid_payload") }
            callbackMode = true; scheduleLocked(); return [:]
        case "events.status":
            guard bytes == nil else { return error("invalid_payload") }
            return data(["mode": callbackMode ? "callback" : "poll", "failed": callbackFailed,
                         "queued": events.count, "dropped": dropped, "delivered": delivered])
        case "network.request":
            guard subscriptions.contains("network.response") else { return error("subscription_required") }
            return network?.request(bytes, insecureAllowed: networkInsecureAllowed) ?? error("session_inactive")
        case "ui.alert", "ui.notice":
            guard let bytes = bytes, let value = try? JSONDecoder().decode([String: String].self, from: bytes), Set(value.keys) == ["title", "message"], let title = value["title"], !title.isEmpty, title.utf8.count <= 128, let message = value["message"], message.utf8.count <= 2048 else { return error("invalid_payload") }
            guard subscriptions.contains("ui.action") else { return error("subscription_required") }
            guard !pending else { return error("ui_busy") }
            guard ProcessInfo.processInfo.systemUptime - lastAlert >= 5 else { return error("rate_limited") }
            lastAlert = ProcessInfo.processInfo.systemUptime
            pending = true
            let requestID = UUID()
            let request = requestID.uuidString
            pendingRequest = requestID
            DispatchQueue.main.async { [self] in
                lock.lock(); let live = active; lock.unlock()
                guard live else { return }
                var finished = false
                func finish(_ action: String) {
                    guard !finished else { return }
                    finished = true
                    self.lock.lock()
                    guard self.active, self.pending, self.pendingRequest == requestID else { self.lock.unlock(); return }
                    self.pending = false; self.pendingRequest = nil; self.lock.unlock()
                    self.emit(["event": "ui.action", "request_id": request, "action": action])
                }
                guard UIApplication.shared.applicationState == .active,
                      let window = Self.foregroundKeyWindow(), var presenter = window.rootViewController else { finish("unavailable"); return }
                while let presented = presenter.presentedViewController { presenter = presented }
                guard !(presenter is UIAlertController), !presenter.isBeingDismissed, presenter.viewIfLoaded?.window != nil else { finish("unavailable"); return }
                let controller = UIAlertController(title: "Plugin: \(title)", message: message, preferredStyle: .alert)
                let actions: [(String, UIAlertAction.Style, String)] = operation == "ui.notice"
                    ? [("OK", .default, "ok")]
                    : [("OK", .default, "ok"), ("Cancel", .cancel, "cancel")]
                for (title, style, value) in actions {
                    let handler: () -> Void = { [weak controller] in
                        #if DEBUG
                        controller?.actions.forEach { ReqGramAlertTesting.handlers.removeValue(forKey: ObjectIdentifier($0)) }
                        #endif
                        finish(value)
                    }
                    let action = UIAlertAction(title: title, style: style) { _ in handler() }
                    controller.addAction(action)
                    #if DEBUG
                    ReqGramAlertTesting.handlers[ObjectIdentifier(action)] = handler
                    #endif
                }
                alert = controller
                presenter.present(controller, animated: true)
            }
            return data(["request_id": request])
        default: return error("unsupported_operation")
        }
    }

    private func finishMutation(key: String, event: [String: String]) {
        lock.lock()
        guard active, let record = mutations[key] else { lock.unlock(); return }
        pendingMutations.remove(key)
        mutations[key] = MutationRecord(fingerprint: record.fingerprint, event: event)
        while mutations.count > 64, let oldest = mutationOrder.first, !pendingMutations.contains(oldest) {
            mutationOrder.removeFirst(); mutations.removeValue(forKey: oldest)
        }
        lock.unlock()
        emit(event)
    }

    private func forwardErrorCode(_ error: String) -> String {
        let stable = ["invalid_payload", "invalid_target", "ineligible_message", "peer_not_found",
                      "message_not_found", "peer_not_sendable", "protected_content", "secret_chat",
                      "permission_denied", "session_inactive", "account_context_unavailable",
                      "provider_unavailable", "enqueue_failed", "idempotency_conflict", "mutation_limit"]
        return stable.contains(error) ? error : "forward_failed"
    }

    private static func foregroundKeyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .sorted { lhs, rhs in
                lhs.activationState == .foregroundActive && rhs.activationState != .foregroundActive
            }
        return scenes.lazy
            .flatMap { $0.windows }
            .first { $0.isKeyWindow && !$0.isHidden && $0.alpha > 0 && $0.rootViewController != nil }
    }
}

#if DEBUG
func reqGramAlertLifecycleRegression(completion: @escaping (Bool) -> Void) {
    let payload = Data("{\"title\":\"Lifecycle cleanup\",\"message\":\"Local diagnostic\"}".utf8)
    func subscribe(_ session: ReqGramHostSession) { _ = session.request("events.subscribe", Data("[\"ui.action\"]".utf8)) }
    // Close before the queued main-thread presentation can execute.
    for _ in 0..<20 {
        let session = ReqGramHostSession()
        subscribe(session)
        guard session.request("ui.alert", payload)["data"] != nil else { completion(false); return }
        session.close()
        guard session.request("events.poll", nil)["error"] as? String == "session_inactive" else { completion(false); return }
    }
    let session = ReqGramHostSession()
    subscribe(session)
    _ = session.request("ui.alert", payload)
    guard session.request("ui.alert", payload)["error"] as? String == "ui_busy" else { session.close(); completion(false); return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        var top = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let alert = top as? UIAlertController, alert.title == "Plugin: Lifecycle cleanup",
              let action = alert.actions.first, let stale = ReqGramAlertTesting.handler(for: action) else { session.close(); completion(false); return }
        session.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            stale()
            completion(alert.presentingViewController == nil && ReqGramAlertTesting.handlers.isEmpty && session.debugClosedAndEmpty)
        }
    }
}

func reqGramHostSessionRegression() -> Bool {
    guard reqGramNativeBridgeRegression() else { return false }
    guard reqGramEventSubscriptionLimitRegression() else { return false }
    guard reqGramCallbackSessionRegression() else { return false }
    guard reqGramAccountSessionRegression() else { return false }
    guard reqGramMessageSessionRegression() else { return false }
    guard reqGramMessageMutationRegression() else { return false }
    let center = NotificationCenter()
    let first = ReqGramHostSession(center: center), second = ReqGramHostSession(center: center)
    defer { first.close(); second.close() }
    func count(_ session: ReqGramHostSession) -> Int {
        guard let bytes = session.request("events.poll", nil)["data"] as? Data,
              let events = try? JSONDecoder().decode([[String: String]].self, from: bytes) else { return -1 }
        return events.count
    }
    guard first.request("app.info", Data())["error"] as? String == "invalid_payload",
          first.request("events.subscribe", Data("[\"messages\"]".utf8))["error"] as? String == "invalid_payload",
          first.request("ui.alert", Data("{\"title\":\"test\",\"message\":\"test\"}".utf8))["error"] as? String == "subscription_required" else { return false }
    _ = first.request("events.subscribe", Data("[\"app.active\"]".utf8))
    for _ in 0..<70 { center.post(name: UIApplication.didBecomeActiveNotification, object: nil) }
    guard count(first) == 64, count(first) == 0, count(second) == 0 else { return false }
    _ = first.request("events.unsubscribe", Data("[\"app.active\"]".utf8))
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    guard count(first) == 0 else { return false }
    first.close()
    return first.request("events.poll", nil)["error"] as? String == "session_inactive"
}

private func reqGramNativeBridgeRegression() -> Bool {
    let bridge = RGNativeBridgeSession()
    func payload(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    let created = bridge.requestOperation("native.class_call", payload: payload([
        "class": "UIView", "selector": "new", "arguments": []
    ]))
    guard let handle = created["handle"] as? String,
          bridge.requestOperation("native.get", payload: payload(["handle": handle, "property": "alpha"]))["value"] as? Double == 1.0,
          bridge.requestOperation("native.set", payload: payload(["handle": handle, "property": "alpha", "value": true]))["error"] as? String == "unsupported_type",
          bridge.requestOperation("native.set", payload: payload(["handle": handle, "property": "alpha", "value": 0.5]))["error"] == nil,
          bridge.requestOperation("native.instance_call", payload: payload(["handle": handle, "selector": "frame", "arguments": []]))["error"] as? String == "unsupported_type",
          bridge.requestOperation("native.audio.set_output_volume", payload: payload(["value": true]))["error"] as? String == "invalid_payload",
          bridge.requestOperation("native.release", payload: payload(["handle": handle]))["error"] == nil,
          bridge.requestOperation("native.get", payload: payload(["handle": handle, "property": "alpha"]))["error"] as? String == "invalid_handle" else { return false }
    bridge.close()
    return bridge.requestOperation("native.audio.output_volume", payload: nil)["error"] as? String == "session_inactive"
}

/// Deterministic fake-provider contract: no account engine or live send.
private func reqGramMessageMutationRegression() -> Bool {
    guard ReqGramMessageActions.shared.currentScope() == nil else { return true }
    ReqGramMessageActions.shared.setAccount("account_fixture")
    defer { ReqGramMessageActions.shared.setAccount(nil) }
    let session = ReqGramHostSession(center: NotificationCenter())
    defer { session.close() }
    session.messageSendAuthorization = { [:] }
    let editAllowed = false
    session.messageEditAuthorization = { editAllowed ? [:] : ["error": "permission_denied"] }
    var calls = 0
    var deferredAdmission: (() -> String?)?
    var deferredEnqueues = 0
    session.sendText = { peer, text, reply, admit, completion in
        calls += 1
        if text == "deferred" {
            deferredAdmission = admit
            return EmptyDisposable
        }
        guard peer == 4242, text == "fixture", reply?.id == 7 else { completion(.failure("bad_fixture")); return EmptyDisposable }
        if let failure = admit() { completion(.failure(ReqGramProviderError(failure))); return EmptyDisposable }
        completion(.success(MessageId(peerId: PeerId(peer), namespace: Namespaces.Message.Local, id: 1)))
        return EmptyDisposable
    }
    // Send-only capability must not admit edit, and revocation must prevent the
    // provider/native seam from being reached after asynchronous admission.
    let editPayload = Data("{\"request_id\":\"edit-1\",\"idempotency_key\":\"edit-key\",\"peer_id\":\"4242\",\"message_id\":\"4242_0_7\",\"text\":\"changed\"}".utf8)
    guard session.request("message.edit", editPayload)["error"] as? String == "permission_denied" else { return false }
    _ = session.request("events.subscribe", Data("[\"message.mutation\"]".utf8))
    let payload = Data("{\"request_id\":\"request-1\",\"idempotency_key\":\"key_1\",\"peer_id\":\"4242\",\"text\":\"fixture\",\"reply_to_message_id\":\"4242_0_7\"}".utf8)
    guard session.request("message.send", payload)["status"] as? String == "pending",
          session.request("message.send", payload)["status"] as? String == "pending", calls == 1,
          session.request("message.send", Data("{\"request_id\":\"request-1\",\"idempotency_key\":\"key_1\",\"peer_id\":\"4242\",\"text\":\"changed\"}".utf8))["error"] as? String == "idempotency_conflict",
           let bytes = session.request("events.poll", nil)["data"] as? Data,
           let events = try? JSONDecoder().decode([[String: String]].self, from: bytes), events.count == 2,
           events.allSatisfy({ $0["status"] == "queued" && $0["consistency"] == "local" && $0["delivered"] == nil }) else { return false }
    // Model native validation returning after capability/account revocation. The
    // provider's final callback must reject before its enqueue side effect.
    let deferred = Data("{\"request_id\":\"request-2\",\"idempotency_key\":\"key_2\",\"peer_id\":\"4242\",\"text\":\"deferred\"}".utf8)
    guard session.request("message.send", deferred)["status"] as? String == "pending",
          let deferredAdmission else { return false }
    ReqGramMessageActions.shared.revoke()
    if deferredAdmission() == nil { deferredEnqueues += 1 }
    guard deferredEnqueues == 0 else { return false }

    // Forward contract: capability denial, exact payload, idempotency, local
    // result/source IDs, provider-unavailable admission, and revoke-before-
    // admission are all exercised without launching the app or touching a
    // live account provider.
    let forwardSession = ReqGramHostSession(center: NotificationCenter())
    defer { forwardSession.close() }
    var forwardAllowed = true
    forwardSession.messageForwardAuthorization = { forwardAllowed ? [:] : ["error": "permission_denied"] }
    _ = forwardSession.request("events.subscribe", Data("[\"message.mutation\"]".utf8))
    var forwardCalls = 0
    forwardSession.forwardMessage = { sourcePeer, sourceId, destinationPeer, admit, completion in
        forwardCalls += 1
        guard sourcePeer == 4242, sourceId == MessageId(peerId: PeerId(4242), namespace: Namespaces.Message.Cloud, id: 7), destinationPeer == 4343 else { completion(.failure("bad_fixture")); return EmptyDisposable }
        if forwardCalls == 1 { guard admit() == nil else { completion(.failure("permission_denied")); return EmptyDisposable } }
        completion(.success(MessageId(peerId: PeerId(destinationPeer), namespace: Namespaces.Message.Local, id: 9)))
        return EmptyDisposable
    }
    let forwardPayload = Data("{\"request_id\":\"forward-1\",\"idempotency_key\":\"forward-key\",\"source_peer_id\":\"4242\",\"source_message_id\":\"4242_0_7\",\"destination_peer_id\":\"4343\"}".utf8)
    guard forwardSession.request("message.forward", forwardPayload)["status"] as? String == "pending",
          forwardCalls == 1,
          forwardSession.request("message.forward", forwardPayload)["status"] as? String == "pending",
          forwardCalls == 1,
          forwardSession.request("message.forward", Data("{\"request_id\":\"forward-1\",\"idempotency_key\":\"forward-key\",\"source_peer_id\":\"4242\",\"source_message_id\":\"4242_0_8\",\"destination_peer_id\":\"4343\"}".utf8))["error"] as? String == "idempotency_conflict" else { return false }
    guard let forwardBytes = forwardSession.request("events.poll", nil)["data"] as? Data,
          let forwardEvents = try? JSONDecoder().decode([[String: String]].self, from: forwardBytes),
          forwardEvents.first?["status"] == "queued",
          forwardEvents.first?["source_peer_id"] == "4242",
          forwardEvents.first?["source_message_id"] == "4242_0_7",
          forwardEvents.first?["destination_peer_id"] == "4343" else { return false }
    forwardAllowed = false
    guard forwardSession.request("message.forward", Data("{\"request_id\":\"forward-denied\",\"idempotency_key\":\"forward-denied\",\"source_peer_id\":\"4242\",\"source_message_id\":\"4242_0_7\",\"destination_peer_id\":\"4343\"}".utf8))["error"] as? String == "permission_denied" else { return false }
    forwardAllowed = true
    let unavailable = ReqGramHostSession(center: NotificationCenter())
    defer { unavailable.close() }
    unavailable.messageForwardAuthorization = { [:] }
    guard unavailable.request("message.forward", forwardPayload)["error"] as? String == "provider_unavailable" else { return false }
    var revokedAdmission: (() -> String?)?
    unavailable.forwardMessage = { _, _, _, admit, _ in revokedAdmission = admit; return EmptyDisposable }
    guard unavailable.request("message.forward", forwardPayload)["status"] as? String == "pending" else { return false }
    ReqGramMessageActions.shared.revoke()
    guard revokedAdmission?() != nil else { return false }

    // Delete is deliberately local-only: reject remote-looking scope and keep
    // the mutation record retryable when its provider is unavailable.
    let deleteSession = ReqGramHostSession(center: NotificationCenter())
    defer { deleteSession.close() }
    deleteSession.messageDeleteAuthorization = { [:] }
    _ = deleteSession.request("events.subscribe", Data("[\"message.mutation\"]".utf8))
    let deletePayload = Data("{\"request_id\":\"delete-1\",\"idempotency_key\":\"delete-key\",\"peer_id\":\"4242\",\"message_id\":\"4242_0_7\",\"scope\":\"local\"}".utf8)
    let everyonePayload = Data("{\"request_id\":\"delete-2\",\"idempotency_key\":\"delete-key-2\",\"peer_id\":\"4242\",\"message_id\":\"4242_0_7\",\"scope\":\"everyone\"}".utf8)
    guard deleteSession.request("message.delete", everyonePayload)["error"] as? String == "invalid_payload",
          deleteSession.request("message.delete", Data("{\"request_id\":\"delete-3\",\"idempotency_key\":\"delete-key-3\",\"peer_id\":\"1_1\",\"message_id\":\"1_1_7\",\"scope\":\"local\"}".utf8))["error"] as? String == "invalid_payload" else { return false }
    // No provider means no stuck idempotency entry; installing one permits an
    // exact retry. The fake also proves the native seam is local-only.
    guard deleteSession.request("message.delete", deletePayload)["error"] as? String == "provider_unavailable" else { return false }
    var nativeCalls = 0
    deleteSession.deleteMessage = { peer, id, scope, admit, completion in
        guard peer == 4242, id.namespace == Namespaces.Message.Cloud, scope == "local" else { completion(.failure("bad_fixture")); return EmptyDisposable }
        nativeCalls += 1
        guard admit() == nil else { completion(.failure("session_inactive")); return EmptyDisposable }
        completion(.success("local_deleted")); return EmptyDisposable
    }
    guard deleteSession.request("message.delete", deletePayload)["status"] as? String == "pending", nativeCalls == 1,
          deleteSession.request("message.delete", deletePayload)["status"] as? String == "pending", nativeCalls == 1 else { return false }
    guard let bytes = deleteSession.request("events.poll", nil)["data"] as? Data,
          let deleteEvents = try? JSONDecoder().decode([[String: String]].self, from: bytes),
          deleteEvents.count == 1, deleteEvents[0]["status"] == "local_deleted",
          deleteEvents[0]["remote_confirmation"] == "not_requested" else { return false }

    // A provider-reported missing target is stable and a revoked/closed
    // session must not cross the native seam after setup was queued.
    let missingSession = ReqGramHostSession(center: NotificationCenter())
    defer { missingSession.close() }
    missingSession.messageDeleteAuthorization = { [:] }
    _ = missingSession.request("events.subscribe", Data("[\"message.mutation\"]".utf8))
    var missingCalls = 0
    missingSession.deleteMessage = { _, _, _, admit, completion in
        missingCalls += 1
        guard admit() == nil else { completion(.failure("session_inactive")); return EmptyDisposable }
        completion(.failure("message_not_found")); return EmptyDisposable
    }
    let missingPayload = Data("{\"request_id\":\"delete-missing\",\"idempotency_key\":\"delete-missing-key\",\"peer_id\":\"4242\",\"message_id\":\"4242_0_999\",\"scope\":\"local\"}".utf8)
    guard missingSession.request("message.delete", missingPayload)["status"] as? String == "pending",
          missingCalls == 1,
          let missingBytes = missingSession.request("events.poll", nil)["data"] as? Data,
          let missingEvents = try? JSONDecoder().decode([[String: String]].self, from: missingBytes),
          missingEvents.first?["error"] == "message_not_found" else { return false }

    let revokedSession = ReqGramHostSession(center: NotificationCenter())
    defer { revokedSession.close() }
    revokedSession.messageDeleteAuthorization = { [:] }
    _ = revokedSession.request("events.subscribe", Data("[\"message.mutation\"]".utf8))
    var revokedDeleteAdmission: (() -> String?)?
    var revokedCalls = 0
    revokedSession.deleteMessage = { _, _, _, admit, _ in revokedDeleteAdmission = admit; revokedCalls += 1; return EmptyDisposable }
    guard revokedSession.request("message.delete", deletePayload)["status"] as? String == "pending" else { return false }
    ReqGramMessageActions.shared.revoke()
    guard revokedDeleteAdmission?() != nil, revokedCalls == 1 else { return false }

    // Delete must reserve mutation capacity before scheduling provider work,
    // exactly like send/edit/forward. Keep all admitted mutations pending so
    // the seventeenth request deterministically exercises the 16-slot gate.
    ReqGramMessageActions.shared.setAccount("account_fixture")
    let limitedDeleteSession = ReqGramHostSession(center: NotificationCenter())
    defer { limitedDeleteSession.close() }
    limitedDeleteSession.messageDeleteAuthorization = { [:] }
    _ = limitedDeleteSession.request("events.subscribe", Data("[\"message.mutation\"]".utf8))
    var limitedDeleteCalls = 0
    limitedDeleteSession.deleteMessage = { _, _, _, _, _ in limitedDeleteCalls += 1; return EmptyDisposable }
    for index in 0..<16 {
        let payload = Data("{\"request_id\":\"delete-limit-\(index)\",\"idempotency_key\":\"delete-limit-\(index)\",\"peer_id\":\"4242\",\"message_id\":\"4242_0_7\",\"scope\":\"local\"}".utf8)
        guard limitedDeleteSession.request("message.delete", payload)["status"] as? String == "pending" else { return false }
    }
    let overflow = Data("{\"request_id\":\"delete-limit-overflow\",\"idempotency_key\":\"delete-limit-overflow\",\"peer_id\":\"4242\",\"message_id\":\"4242_0_7\",\"scope\":\"local\"}".utf8)
    guard limitedDeleteSession.request("message.delete", overflow)["error"] as? String == "mutation_limit",
          limitedDeleteCalls == 16 else { return false }

    // The 64-record gate preserves insertion order: if the oldest record is
    // still pending it is not skipped to evict a newer completed record.
    let retainedDeleteSession = ReqGramHostSession(center: NotificationCenter())
    defer { retainedDeleteSession.close() }
    retainedDeleteSession.messageDeleteAuthorization = { [:] }
    _ = retainedDeleteSession.request("events.subscribe", Data("[\"message.mutation\"]".utf8))
    var retainedDeleteCalls = 0
    retainedDeleteSession.deleteMessage = { _, _, _, _, completion in
        retainedDeleteCalls += 1
        if retainedDeleteCalls > 1 { completion(.success("local_deleted")) }
        return EmptyDisposable
    }
    for index in 0..<64 {
        let payload = Data("{\"request_id\":\"delete-retained-\(index)\",\"idempotency_key\":\"delete-retained-\(index)\",\"peer_id\":\"4242\",\"message_id\":\"4242_0_7\",\"scope\":\"local\"}".utf8)
        guard retainedDeleteSession.request("message.delete", payload)["status"] as? String == "pending" else { return false }
    }
    let retainedOverflow = Data("{\"request_id\":\"delete-retained-overflow\",\"idempotency_key\":\"delete-retained-overflow\",\"peer_id\":\"4242\",\"message_id\":\"4242_0_7\",\"scope\":\"local\"}".utf8)
    guard retainedDeleteSession.request("message.delete", retainedOverflow)["error"] as? String == "mutation_limit",
          retainedDeleteCalls == 64 else { return false }
    return true
}

/// The limit is per input array, not per distinct name or accumulated session.
private func reqGramEventSubscriptionLimitRegression() -> Bool {
    let session = ReqGramHostSession(center: NotificationCenter())
    defer { session.close() }
    var allowed = true
    session.messageAuthorization = { allowed ? ["plugin_id": "fixture"] : ["error": "permission_denied"] }
    let firstThree = ["app.active", "app.inactive", "ui.action"]
    let remaining = ["network.response", "message.action"]
    let all = firstThree + remaining
    func request(_ operation: String, _ names: [String]) -> [String: Any] {
        guard let bytes = try? JSONEncoder().encode(names) else { return ["error": "encoding_failed"] }
        return session.request(operation, bytes)
    }
    for operation in ["events.subscribe", "events.unsubscribe"] {
        let before = session.debugSubscriptions
        // Unique and duplicate-heavy arrays must both count all input entries.
        for names in [Array(all.prefix(4)), all,
                      Array(repeating: "app.active", count: 4),
                      Array(repeating: "app.active", count: 5)] {
            guard request(operation, names)["error"] as? String == "invalid_payload",
                  session.debugSubscriptions == before else { return false }
        }
        allowed = false
        guard request(operation, remaining)["error"] as? String == "permission_denied",
              session.debugSubscriptions == before else { return false }
        allowed = true
        guard request(operation, []).isEmpty,
              request(operation, Array(repeating: "app.active", count: 3)).isEmpty,
              request(operation, firstThree).isEmpty,
              session.debugSubscriptions == (operation == "events.subscribe" ? Set(firstThree) : Set(remaining)),
              request(operation, remaining).isEmpty,
              session.debugSubscriptions == (operation == "events.subscribe" ? Set(all) : Set<String>()) else { return false }
    }
    return true
}

/// Uses the existing scope and value-snapshot seams; no Python or account data.
private func reqGramAccountSessionRegression() -> Bool {
    // As with the message regression, never switch an interactive user's account.
    guard ReqGramMessageActions.shared.currentScope() == nil else { return true }
    defer { ReqGramMessageActions.shared.setAccount(nil) }
    guard reqGramStartupScopeIsCurrent(nil) else { return false }
    ReqGramMessageActions.shared.setAccount("account_fixture")
    guard !reqGramStartupScopeIsCurrent(nil) else { return false }
    let startupScope = ReqGramMessageActions.shared.currentScope()
    guard reqGramStartupScopeIsCurrent(startupScope) else { return false }
    // Model snapshot completion after A→B, A→B→A, and same-account refresh.
    ReqGramMessageActions.shared.setAccount("account_other")
    guard !reqGramStartupScopeIsCurrent(startupScope) else { return false }
    ReqGramMessageActions.shared.setAccount("account_fixture")
    guard !reqGramStartupScopeIsCurrent(startupScope) else { return false }
    let refreshedScope = ReqGramMessageActions.shared.currentScope()
    ReqGramMessageActions.shared.revoke()
    guard !reqGramStartupScopeIsCurrent(refreshedScope) else { return false }
    // A change after admission but before construction must not rebind a session.
    let late = ReqGramHostSession(center: NotificationCenter(), messageScope: refreshedScope)
    defer { late.close() }
    guard late.accountContextError() == "account_context_unavailable" else { return false }
    ReqGramMessageActions.shared.setAccount(nil)
    guard !reqGramStartupScopeIsCurrent(startupScope) else { return false }
    let operations: [(String, Data?)] = [
        ("accounts.list", nil), ("account.context", nil),
        ("peer.lookup", Data("{\"peer_id\":4242}".utf8))
    ]
    func fixture() -> ReqGramHostSession {
        let session = ReqGramHostSession(center: NotificationCenter())
        session.accountSnapshot = ReqGramAccountSnapshot(accounts: [["handle": "account_fixture", "is_primary": true]], current: "account_fixture")
        session.peerSnapshots[4242] = ReqGramPeerSnapshot(id: 4242, type: "user", title: "Fixture Peer", username: nil)
        return session
    }
    func rejected(_ session: ReqGramHostSession, _ error: String) -> Bool {
        // Also checks the gate used before/after asynchronous native peer lookup.
        session.accountContextError() == error && operations.allSatisfy {
            let result = session.request($0.0, $0.1)
            return result["error"] as? String == error && result["data"] == nil
        }
    }
    let unbound = fixture()
    defer { unbound.close() }
    guard rejected(unbound, "account_context_unavailable") else { return false }
    ReqGramMessageActions.shared.setAccount("account_fixture")
    let original = fixture()
    defer { original.close() }
    guard original.accountContextError() == nil,
          operations.allSatisfy({ original.request($0.0, $0.1)["data"] != nil }),
          original.request("peer.lookup", Data("{\"peer_id\":4243}".utf8))["error"] as? String == "peer_not_found",
          original.request("accounts.list", Data())["error"] as? String == "invalid_payload" else { return false }
    // No request between switches in the second pass: invalidation must not
    // depend on observing B, nor on comparing account handles alone.
    for observeB in [true, false] {
        let session = observeB ? original : fixture()
        defer { if !observeB { session.close() } }
        ReqGramMessageActions.shared.setAccount("account_other")
        if observeB && !rejected(session, "account_context_unavailable") { return false }
        ReqGramMessageActions.shared.setAccount("account_fixture")
        guard rejected(session, "account_context_unavailable"),
              session.request("app.info", nil)["data"] != nil else { return false }
    }
    guard rejected(original, "account_context_unavailable"),
          rejected(unbound, "account_context_unavailable") else { return false }
    let fresh = fixture()
    defer { fresh.close() }
    guard fresh.accountContextError() == nil,
          operations.allSatisfy({ fresh.request($0.0, $0.1)["data"] != nil }) else { return false }
    original.close()
    return rejected(original, "session_inactive")
}

/// Deterministic scheduler seam: no Python, UI presentation or network traffic.
private func reqGramMessageSessionRegression() -> Bool {
    // Do not disturb a real primary account in an interactive diagnostic run.
    guard ReqGramMessageActions.shared.currentScope() == nil else { return true }
    ReqGramMessageActions.shared.setAccount("account_fixture")
    defer { ReqGramMessageActions.shared.setAccount(nil) }
    // Revocation must survive reauthorization without requiring an intervening
    // poll. Exercise both delivery modes and a stale authorization snapshot.
    for callback in [false, true] {
        let revoked = ReqGramHostSession(center: NotificationCenter())
        defer { revoked.close() }
        revoked.messageAuthorization = { ["plugin_id": "fixture"] }
        _ = revoked.request("events.subscribe", Data("[\"message.action\"]".utf8))
        let payload = Data("{\"id\":\"info\",\"label\":\"Info\"}".utf8)
        guard revoked.request("messages.register", payload)["error"] == nil,
              let stale = ReqGramMessageActions.shared.actions(account: "account_fixture").first else { return false }
        if callback {
            _ = revoked.request("events.callback", nil)
            revoked.armCallbacks {}
        }
        ReqGramMessageActions.shared.tap(stale, account: "account_fixture", peer: "42", namespace: "0", message: "1", text: "Queued before revocation")
        ReqGramMessageActions.shared.revoke()
        guard ReqGramMessageActions.shared.actions(account: "account_fixture").isEmpty,
              revoked.request("messages.register", payload)["error"] as? String == "account_context_unavailable" else { return false }
        ReqGramMessageActions.shared.tap(stale, account: "account_fixture", peer: "42", namespace: "0", message: "1", text: "Stale menu")
        if callback {
            guard revoked.takeCallbackEvent() == nil else { return false }
        } else {
            guard let bytes = revoked.request("events.poll", nil)["data"] as? Data,
                  let events = try? JSONDecoder().decode([[String: String]].self, from: bytes), events.isEmpty else { return false }
        }
    }
    let session = ReqGramHostSession(center: NotificationCenter())
    defer { session.close() }
    var allowed = false
    session.messageAuthorization = { allowed ? ["plugin_id": "fixture"] : ["error": "permission_denied"] }
    let subscription = Data("[\"message.action\"]".utf8)
    let registration = Data("{\"id\":\"info\",\"label\":\"Info\"}".utf8)
    guard session.request("events.subscribe", subscription)["error"] as? String == "permission_denied",
          session.request("messages.register", registration)["error"] as? String == "permission_denied" else { return false }
    allowed = true
    guard session.request("messages.register", registration)["error"] as? String == "subscription_required" else { return false }
    _ = session.request("events.subscribe", subscription)
    guard session.request("messages.register", registration)["error"] == nil,
          let action = ReqGramMessageActions.shared.actions(account: "account_fixture").first else { return false }
    func tap() { ReqGramMessageActions.shared.tap(action, account: "account_fixture", peer: "42", namespace: "0", message: "1", text: "Fixture") }
    func count() -> Int {
        guard let bytes = session.request("events.poll", nil)["data"] as? Data,
              let events = try? JSONDecoder().decode([[String: String]].self, from: bytes) else { return -1 }
        return events.count
    }
    guard count() == 0 else { return false }
    tap(); guard count() == 1 else { return false }
    tap(); allowed = false
    guard count() == 0 else { return false }
    allowed = true
    tap()
    guard session.request("messages.unregister", Data("{\"id\":\"info\"}".utf8))["error"] == nil,
          count() == 0 else { return false }
    tap(); guard count() == 0 else { return false }
    guard session.request("messages.register", registration)["error"] == nil else { return false }
    tap(); guard count() == 0 else { return false } // Stale token after replacement.
    _ = session.request("events.unsubscribe", subscription)
    guard ReqGramMessageActions.shared.actions(account: "account_fixture").isEmpty else { return false }
    _ = session.request("events.subscribe", subscription)
    guard session.request("messages.register", registration)["error"] == nil,
          let replacement = ReqGramMessageActions.shared.actions(account: "account_fixture").first else { return false }
    ReqGramMessageActions.shared.tap(replacement, account: "account_fixture", peer: "42", namespace: "0", message: "1", text: "Fixture")
    // Verify the live replacement queued an event without draining it before A→B→A.
    guard let bytes = session.request("events.status", nil)["data"] as? Data,
          let status = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
          status["queued"] as? Int == 1 else { return false }
    ReqGramMessageActions.shared.setAccount("account_other")
    ReqGramMessageActions.shared.setAccount("account_fixture")
    guard count() == 0 else { return false }
    tap(); guard count() == 0 else { return false }
    session.close()
    return ReqGramMessageActions.shared.actions(account: "account_fixture").isEmpty
}

private func reqGramCallbackSessionRegression() -> Bool {
    let center = NotificationCenter()
    let session = ReqGramHostSession(center: center)
    defer { session.close() }
    var scheduled = 0
    func status() -> [String: Any] {
        guard let bytes = session.request("events.status", nil)["data"] as? Data else { return [:] }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
    }
    _ = session.request("events.subscribe", Data("[\"app.active\",\"app.inactive\"]".utf8))
    guard session.request("events.callback", Data())["error"] as? String == "invalid_payload" else { return false }
    _ = session.request("events.callback", nil)
    for _ in 0..<70 { center.post(name: UIApplication.didBecomeActiveNotification, object: nil) }
    guard session.takeCallbackEvent() == nil, scheduled == 0,
          status()["queued"] as? Int == 64, status()["dropped"] as? Int == 6,
          session.request("events.poll", nil)["error"] as? String == "callback_mode" else { return false }
    session.armCallbacks { scheduled += 1 }
    _ = session.request("events.callback", nil)
    guard scheduled == 1, session.takeCallbackEvent() != nil else { return false }
    session.finishCallback(nil)
    guard scheduled == 2, status()["delivered"] as? Int == 1 else { return false }
    _ = session.request("events.unsubscribe", Data("[\"app.active\"]".utf8))
    guard session.takeCallbackEvent() == nil else { return false }
    session.finishCallback(NSError(domain: "callback fixture", code: 1))
    center.post(name: UIApplication.willResignActiveNotification, object: nil)
    guard status()["failed"] as? Bool == true, status()["queued"] as? Int == 0, scheduled == 2 else { return false }
    session.close()
    session.armCallbacks { scheduled += 100 }
    guard session.takeCallbackEvent() == nil, session.debugClosedAndEmpty else { return false }
    let replacement = ReqGramHostSession(center: center)
    defer { replacement.close() }
    _ = replacement.request("events.subscribe", Data("[\"app.active\"]".utf8))
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    guard let bytes = replacement.request("events.poll", nil)["data"] as? Data,
          let events = try? JSONDecoder().decode([[String: String]].self, from: bytes) else { return false }
    return events.count == 1 && scheduled == 2 && session.takeCallbackEvent() == nil
}
#endif

final class ReqGramEmbeddedExecutor: ReqGramPluginExecutor {
    static let shared = ReqGramEmbeddedExecutor()
    private static let sessionLock = NSLock()
    private static var sessions: [String: ReqGramHostSession] = [:]
    #if DEBUG
    static var diagnosticSessionCount: Int {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return sessions.count
    }
    #endif
    private let accountProvider: ReqGramAccountProvider?
    #if DEBUG
    init(accountProvider: ReqGramAccountProvider? = nil, protocolClasses: [AnyClass]? = nil) {
        self.accountProvider = accountProvider
        self.protocolClasses = protocolClasses
    }
    private let protocolClasses: [AnyClass]?
    #else
    init(accountProvider: ReqGramAccountProvider? = nil) { self.accountProvider = accountProvider }
    #endif
    func execute(module: String, directory: URL, start: Bool, host: @escaping (String, Data?) -> [String: Any], boundary: @escaping (Bool) -> Bool, completion: @escaping (Error?) -> Void) {
        // Capture before authorization/snapshot work can yield to account refresh.
        let messageScope = ReqGramMessageActions.shared.currentScope()
        // Invalidate synchronously, before asynchronous snapshot/runtime teardown.
        if !start {
            Self.sessionLock.lock(); let stopping = Self.sessions[module]; Self.sessionLock.unlock()
            stopping?.close()
        }
        // execute is entered on the manager queue. Never call its synchronous host back there.
        DispatchQueue.global().async {
            guard start, host("authorize.accounts", nil)["error"] == nil, let provider = self.accountProvider else {
                self.run(module: module, directory: directory, start: start, messageScope: messageScope, snapshot: nil, peerProvider: self.accountProvider, host: host, boundary: boundary, completion: completion)
                return
            }
            let profile = host("authorize.profile", nil)["error"] == nil
            DispatchQueue.main.async {
                let disposable = MetaDisposable()
                var finished = false
                func finish(_ snapshot: ReqGramAccountSnapshot?) {
                    guard !finished else { return }; finished = true
                    disposable.dispose()
                    self.run(module: module, directory: directory, start: start, messageScope: messageScope, snapshot: snapshot, peerProvider: provider, host: host, boundary: boundary, completion: completion)
                }
                disposable.set(provider.snapshot(profile: profile, completion: { finish($0) }))
                // The fake provider uses this seam for diagnostics. Native callers can resolve
                // only IDs they explicitly ask for; no peer enumeration is performed here.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(nil) }
            }
        }
    }
    private func run(module: String, directory: URL, start: Bool, messageScope: ReqGramMessageActions.Scope?, snapshot: ReqGramAccountSnapshot?, peerProvider: ReqGramAccountProvider? = nil, host: @escaping (String, Data?) -> [String: Any], boundary: @escaping (Bool) -> Bool, completion: @escaping (Error?) -> Void) {
        Self.sessionLock.lock()
        let session: ReqGramHostSession
        if start {
            guard reqGramStartupScopeIsCurrent(messageScope) else {
                Self.sessionLock.unlock()
                DispatchQueue.main.async { completion(NSError(domain: "ReqGramPythonRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: "account_context_unavailable"])) }
                return
            }
            guard Self.sessions[module] == nil else {
                Self.sessionLock.unlock()
                DispatchQueue.main.async { completion(NSError(domain: "ReqGramPythonRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: "Plugin session already exists"])) }
                return
            }
            #if DEBUG
            session = ReqGramHostSession(protocolClasses: self.protocolClasses, messageScope: messageScope); Self.sessions[module] = session
            #else
            session = ReqGramHostSession(messageScope: messageScope); Self.sessions[module] = session
            #endif
        }
        else { session = Self.sessions.removeValue(forKey: module) ?? ReqGramHostSession(); session.close() }
        Self.sessionLock.unlock()
        if start { session.accountSnapshot = snapshot }
        session.messageAuthorization = { host("authorize.messages", nil) }
        session.messageSendAuthorization = { host("authorize.message.send", nil) }
        session.messageEditAuthorization = { host("authorize.message.edit", nil) }
        session.messageDeleteAuthorization = { host("authorize.message.delete", nil) }
        session.messageForwardAuthorization = { host("authorize.message.forward", nil) }
        session.watchMessages = { [weak session] peerId, ids, emit, completion in
            guard let session else { completion("session_inactive"); return EmptyDisposable }
            guard let provider = peerProvider, session.accountContextError() == nil else { completion(session.accountContextError() ?? "account_context_unavailable"); return EmptyDisposable }
            return provider.watchMessages(peerId: peerId, messageIds: ids, emit: emit, completion: completion)
        }
        session.sendText = { [weak session] peerId, text, replyTo, admit, completion in
            guard let session else { completion(.failure("session_inactive")); return EmptyDisposable }
            guard let provider = peerProvider, session.accountContextError() == nil else { completion(.failure(ReqGramProviderError(session.accountContextError() ?? "account_context_unavailable"))); return EmptyDisposable }
            return provider.sendText(peerId: peerId, text: text, replyTo: replyTo, admit: admit, completion: completion)
        }
        session.editText = { [weak session] peerId, messageId, text, admit, completion in
            guard let session else { completion(.failure("session_inactive")); return EmptyDisposable }
            guard let provider = peerProvider, session.accountContextError() == nil else { completion(.failure(ReqGramProviderError(session.accountContextError() ?? "account_context_unavailable"))); return EmptyDisposable }
            return provider.editText(peerId: peerId, messageId: messageId, text: text, admit: admit, completion: completion)
        }
        session.deleteMessage = { [weak session] peerId, messageId, scope, admit, completion in
            guard let session, let provider = peerProvider, session.accountContextError() == nil else { completion(.failure("account_context_unavailable")); return EmptyDisposable }
            return provider.deleteMessage(peerId: peerId, messageId: messageId, scope: scope, admit: admit, completion: completion)
        }
        session.forwardMessage = { [weak session] sourcePeerId, sourceMessageId, destinationPeerId, admit, completion in
            guard let session, let provider = peerProvider, session.accountContextError() == nil else { completion(.failure("account_context_unavailable")); return EmptyDisposable }
            return provider.forwardMessage(sourcePeerId: sourcePeerId, sourceMessageId: sourceMessageId, destinationPeerId: destinationPeerId, admit: admit, completion: completion)
        }
        RGPythonRuntime.shared().runPlugin(module, directory: directory.path, start: start, host: { operation, bytes in
            if operation == "peer.lookup" || operation == "ios.safe.peer_lookup" {
                if operation == "ios.safe.peer_lookup" {
                    let safeAuthorization = host("authorize.ios.safe", nil)
                    if safeAuthorization["error"] != nil { return safeAuthorization }
                }
                let authorization = host("authorize.peer", nil)
                if authorization["error"] != nil { return authorization }
                if let failure = session.accountContextError() { return ["error": failure] }
                guard let bytes, let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], object.keys.count == 1,
                      let number = object["peer_id"] as? NSNumber, number.int64Value != 0,
                      number.stringValue == String(number.int64Value), let provider = peerProvider else { return ["error": "invalid_payload"] }
                let semaphore = DispatchSemaphore(value: 0)
                var result: [String: Any] = ["error": "peer_not_found"]
                DispatchQueue.main.async {
                    if let failure = session.accountContextError() {
                        result = ["error": failure]; semaphore.signal(); return
                    }
                    _ = provider.peer(id: number.int64Value) { peer in
                        if let peer { result = ["data": (try? JSONSerialization.data(withJSONObject: peer.dictionary())) ?? Data()] }
                        semaphore.signal()
                    }
                }
                _ = semaphore.wait(timeout: .now() + 5)
                if let failure = session.accountContextError() { return ["error": failure] }
                return result
            }
            if operation == "chat.context" || operation == "message.get" || operation == "message.history" || operation == "message.search" || operation == "ios.safe.message_get" {
                let underlyingOperation = operation == "ios.safe.message_get" ? "message.get" : operation
                if operation == "ios.safe.message_get" {
                    let safeAuthorization = host("authorize.ios.safe", nil)
                    if safeAuthorization["error"] != nil { return safeAuthorization }
                }
                let authorization = host("authorize." + underlyingOperation, nil)
                if authorization["error"] != nil { return authorization }
                guard let provider = peerProvider, session.accountContextError() == nil else { return ["error": session.accountContextError() ?? "account_context_unavailable"] }
                let semaphore = DispatchSemaphore(value: 0)
                let completionLock = NSLock()
                var result: [String: Any] = ["error": "runtime_unavailable"]
                var finished = false
                var readDisposable: Disposable?
                DispatchQueue.main.async {
                    if let failure = session.accountContextError() { result = ["error": failure]; semaphore.signal(); return }
                    completionLock.lock()
                    let alreadyTimedOut = finished
                    completionLock.unlock()
                    if alreadyTimedOut { semaphore.signal(); return }
                    readDisposable = provider.read(operation: underlyingOperation, payload: bytes) { value in
                        completionLock.lock()
                        guard !finished else { completionLock.unlock(); return }
                        finished = true
                        if let failure = session.accountContextError() { result = ["error": failure] }
                        else {
                            switch value { case let .success(data): result = ["data": data]; case let .failure(error): result = ["error": error.code] }
                        }
                        completionLock.unlock()
                        semaphore.signal()
                    }
                    completionLock.lock()
                    let shouldDispose = finished
                    let disposable = readDisposable
                    completionLock.unlock()
                    if shouldDispose { disposable?.dispose() }
                }
                if semaphore.wait(timeout: .now() + 5) == .timedOut {
                    completionLock.lock()
                    finished = true
                    let disposable = readDisposable
                    completionLock.unlock()
                    // SwiftSignalKit providers normally honor disposal. If the
                    // underlying Postbox operation has already entered its
                    // terminal callback, the one-shot guard still prevents a
                    // late callback from racing this return value.
                    disposable?.dispose()
                } else {
                    completionLock.lock()
                    let disposable = readDisposable
                    completionLock.unlock()
                    disposable?.dispose()
                }
                return result
            }
            if operation == "accounts.list" || operation == "account.context" || operation == "ios.safe.account_context" {
                if operation == "ios.safe.account_context" {
                    let safeAuthorization = host("authorize.ios.safe", nil)
                    if safeAuthorization["error"] != nil { return safeAuthorization }
                }
                let authorization = host("authorize.accounts", nil)
                if authorization["error"] != nil { return authorization }
                return session.request(operation == "ios.safe.account_context" ? "account.context" : operation, bytes)
            }
            if operation == "mtproto.raw" || operation == "mtproto.json" {
                let authorization = host("authorize.mtproto", nil)
                if authorization["error"] != nil { return authorization }
                return session.mtprotoRequest(operation, bytes, provider: peerProvider)
            }
            if operation == "ios.safe.output_volume" {
                let authorization = host("authorize.ios.safe", nil)
                if authorization["error"] != nil { return authorization }
                return session.nativeRequest("native.audio.output_volume", bytes)
            }
            if operation == "ios.safe.set_output_volume" {
                let authorization = host("authorize.ios.safe", nil)
                if authorization["error"] != nil { return authorization }
                return session.nativeRequest("native.audio.set_output_volume", bytes)
            }
            if operation == "ios.safe.app_info" || operation == "ios.safe.alert" || operation == "ios.safe.notice" {
                let authorization = host("authorize.ios.safe", nil)
                if authorization["error"] != nil { return authorization }
                let mapped = operation == "ios.safe.app_info" ? "app.info" : operation == "ios.safe.alert" ? "ui.alert" : "ui.notice"
                return session.request(mapped, bytes)
            }
            if operation.hasPrefix("native.") {
                let authorization = host("authorize.native", nil)
                if authorization["error"] != nil { return authorization }
                return session.nativeRequest(operation, bytes)
            }
            if operation == "app.info" || operation.hasPrefix("events.") || operation.hasPrefix("message.events.") || operation == "message.send" || operation == "message.media.send" || operation == "message.edit" || operation == "message.delete" || operation == "message.forward" || operation == "messages.register" || operation == "messages.unregister" || operation == "ui.alert" || operation == "ui.notice" || operation == "network.request" || operation == "network.cancel" {
                let authorization = host(operation == "message.send" ? "authorize.message.send" : operation == "message.media.send" ? "authorize.message.media.send" : operation == "message.edit" ? "authorize.message.edit" : operation == "message.delete" ? "authorize.message.delete" : operation == "message.forward" ? "authorize.message.forward" : operation.hasPrefix("message.events.") ? "authorize.message.events" : operation == "ui.notice" ? "authorize.notice" : operation == "ui.alert" ? "authorize.ui" : "authorize.host", nil)
                if authorization["error"] != nil { return authorization }
                if operation == "network.request" {
                    let requestObject = (try? JSONSerialization.jsonObject(with: bytes ?? Data())) as? [String: Any]
                    let insecure = requestObject?["url"] as? String
                    let requiresInsecure = insecure.map { URL(string: $0)?.scheme?.lowercased() == "http" } ?? false
                    let networkAuthorization = host(requiresInsecure ? "authorize.network.insecure" : "authorize.network", nil)
                    if networkAuthorization["error"] != nil { return networkAuthorization }
                    return session.request(operation, bytes, networkInsecureAllowed: requiresInsecure)
                }
                if operation == "network.cancel" {
                    let networkAuthorization = host("authorize.network", nil)
                    if networkAuthorization["error"] != nil { return networkAuthorization }
                    return session.cancelNetwork(bytes)
                }
                return session.request(operation, bytes)
            }
            return host(operation, bytes)
        }, boundary: boundary, completion: { error in
            if error != nil || !start {
                session.close()
                Self.sessionLock.lock()
                if Self.sessions[module] === session { Self.sessions.removeValue(forKey: module) }
                Self.sessionLock.unlock()
            } else {
                session.armCallbacks { [weak session] in
                    RGPythonRuntime.shared().deliverEvent(module, takeEvent: { [weak session] in
                        // Authorization is rechecked for every event, including safe mode.
                        guard host("authorize.host", nil)["error"] == nil else { return nil }
                        return session?.takeCallbackEvent()
                    }, boundary: { entering in
                        if entering && host("authorize.host", nil)["error"] != nil { return false }
                        return boundary(entering)
                    }, completion: { [weak session] error in session?.finishCallback(error) })
                }
            }
            completion(error)
        })
    }
}
