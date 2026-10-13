import Foundation
import AccountContext
import SwiftSignalKit
import TelegramCore
import Postbox
import TelegramApi

/// Provider-internal typed failure. `code` is the stable string exposed by the
/// host boundary; keeping the type local avoids changing `String` process-wide.
struct ReqGramProviderError: Error, ExpressibleByStringLiteral {
    let code: String
    init(_ code: String) { self.code = code }
    init(stringLiteral value: String) { self.code = value }
}

struct ReqGramMTProtoError: Error {
    let code: String
    let rpcCode: Int32?
    let rpcMessage: String?
}

/// Allowlisted value snapshot only. Never retains Account, peers, or credential objects.
struct ReqGramAccountSnapshot {
    var accounts: [[String: Any]]
    var current: String?
    var peers: [[String: Any]] = []
}

struct ReqGramPeerSnapshot {
    let id: Int64
    let type: String
    let title: String
    let username: String?
    func dictionary() -> [String: Any] {
        ["id": id, "type": type, "title": title, "username": username as Any? ?? NSNull()]
    }
}

protocol ReqGramAccountProvider {
    /// Called on main; completion on main. Profiles are fetched only with explicit permission.
    func snapshot(profile: Bool, completion: @escaping (ReqGramAccountSnapshot) -> Void) -> Disposable
    /// Resolves only an already-known peer from the active account's local engine data.
    func peer(id: Int64, completion: @escaping (ReqGramPeerSnapshot?) -> Void) -> Disposable
    /// Read-only, allowlisted DTOs. The provider never returns engine objects or media.
    func read(operation: String, payload: Data?, completion: @escaping (Result<Data, ReqGramProviderError>) -> Void) -> Disposable
    func watchMessages(peerId: Int64, messageIds: [String], emit: @escaping ([String: String]) -> Void, completion: @escaping (String?) -> Void) -> Disposable
    /// Enqueues exactly one plain-text message into Telegram's normal local pending path.
    /// `admit` is the final session/capability check and is called immediately
    /// before enqueueing, after all asynchronous local validation has completed.
    func sendText(peerId: Int64, text: String, replyTo: MessageId?, admit: @escaping () -> String?, completion: @escaping (Result<MessageId, ReqGramProviderError>) -> Void) -> Disposable
    /// Sends one host-issued file token. The token registry is deliberately the
    /// only source of file URLs; callers never pass filesystem paths.
    func sendMedia(peerId: Int64, fileToken: String, fileName: String, mimeType: String, caption: String, admit: @escaping () -> String?, completion: @escaping (Result<MessageId, ReqGramProviderError>) -> Void) -> Disposable
    /// Edits one existing cloud text message, retaining native media. The callback is
    /// terminal evidence only: `done(false)` means native reported no change.
    func editText(peerId: Int64, messageId: MessageId, text: String, admit: @escaping () -> String?, completion: @escaping (Result<Bool, ReqGramProviderError>) -> Void) -> Disposable
    func deleteMessage(peerId: Int64, messageId: MessageId, scope: String, admit: @escaping () -> String?, completion: @escaping (Result<String, ReqGramProviderError>) -> Void) -> Disposable
    /// Forwards one eligible cloud message to one cloud peer through Telegram's
    /// normal local pending queue. Success proves local enqueue only.
    func forwardMessage(sourcePeerId: Int64, sourceMessageId: MessageId, destinationPeerId: Int64, admit: @escaping () -> String?, completion: @escaping (Result<MessageId, ReqGramProviderError>) -> Void) -> Disposable
    /// Sends one already serialized, boxed TL function through this provider's
    /// account network. The response is returned exactly as received.
    func mtproto(body: Data, completion: @escaping (Result<Data, ReqGramMTProtoError>) -> Void) -> Disposable
}

func reqGramMessageId(_ value: String) -> MessageId? {
    let parts = value.split(separator: "_", omittingEmptySubsequences: false)
    guard parts.count == 3, let peer = Int64(parts[0]), String(peer) == parts[0], let namespace = Int32(parts[1]), String(namespace) == parts[1], let id = Int32(parts[2]), String(id) == parts[2], peer != 0, id > 0 else { return nil }
    return MessageId(peerId: PeerId(peer), namespace: namespace, id: id)
}

private let reqGramMaximumTextBytes = 16 * 1024
private let reqGramMaximumMediaBytes: Int64 = 32 * 1024 * 1024
private let reqGramMaximumSearchQueryBytes = 512

/// Session/host-owned registry seam. A future UIDocumentPicker integration
/// must copy the selected security-scoped URL into this registry; it must never
/// expose that URL to a plugin. There is intentionally no public path-based
/// issuance API in this build.
final class ReqGramMediaFileTokenRegistry {
    struct Entry { let url: URL; let owner: UUID; let name: String; let mime: String; let size: Int64; let expires: TimeInterval }
    private let lock = NSLock()
    private var values: [String: Entry] = [:]
    fileprivate let owner: UUID
    private let root: URL
    init(owner: UUID) {
        self.owner = owner
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("ReqGramMedia", isDirectory: true).appendingPathComponent(owner.uuidString, isDirectory: true)
    }
    func issue(source: URL, name: String, mime: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> String {
        guard name.utf8.count <= 255, !name.isEmpty, !name.contains("/"), !name.contains("\\") else { throw NSError(domain: "ReqGramMedia", code: 1) }
        guard let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value, size >= 0, size <= reqGramMaximumMediaBytes else { throw NSError(domain: "ReqGramMedia", code: 2) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let destination = root.appendingPathComponent(token, isDirectory: false)
        try FileManager.default.copyItem(at: source, to: destination)
        let entry = Entry(url: destination, owner: owner, name: name, mime: mime, size: size, expires: now + 300)
        lock.lock(); values[token] = entry; lock.unlock()
        return token
    }
    func consume(_ token: String, owner: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[token], value.owner == owner, value.expires > now else { values.removeValue(forKey: token).map { try? FileManager.default.removeItem(at: $0.url) }; return nil }
        values.removeValue(forKey: token); return value
    }
    func removeAll() { lock.lock(); let entries = values.values; values.removeAll(); lock.unlock(); entries.forEach { try? FileManager.default.removeItem(at: $0.url) }; try? FileManager.default.removeItem(at: root) }
}

private func reqGramTruncatedText(_ text: String) -> (String, Bool) {
    guard text.utf8.count > reqGramMaximumTextBytes else { return (text, false) }
    var bytes = Array(text.utf8.prefix(reqGramMaximumTextBytes))
    while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
    return (String(bytes: bytes, encoding: .utf8) ?? "", true)
}

private func reqGramMessageRejection(_ message: Message) -> String? {
    // Keep this list deliberately conservative: this API is text-only local export.
    if message.id.namespace != Namespaces.Message.Cloud || message.id.id <= 0 { return "ineligible_message" }
    if !message.media.isEmpty || message.groupingKey != nil || message.groupInfo != nil || message.threadId != nil { return "ineligible_message" }
    if !message.flags.intersection([.Unsent, .Failed, .Sending, .CopyProtected]).isEmpty { return "ineligible_message" }
    // Forward accepts the plain, attribute-free representation only. This is
    // deliberately conservative as Telegram adds new MessageAttribute types.
    guard message.attributes.isEmpty else { return "ineligible_message" }
    return nil
}

private func reqGramPeerRejection(_ peer: Peer?) -> String? {
    guard let peer else { return "peer_not_found" }
    guard [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(peer.id.namespace) else { return "invalid_peer" }
    if peer is TelegramSecretChat { return "secret_chat" }
    if peer.isCopyProtectionEnabled { return "protected_content" }
    return nil
}

private func reqGramSendPeerRejection(_ peer: Peer?) -> String? {
    if let rejection = reqGramPeerRejection(peer) { return rejection }
    guard let peer, canSendMessagesToPeer(EnginePeer(peer)) else { return "peer_not_sendable" }
    return nil
}

private func reqGramMessageDTO(_ message: Message) -> [String: Any] {
    let (text, truncated) = reqGramTruncatedText(message.text)
    let protected = message.flags.contains(.CopyProtected)
    var result: [String: Any] = ["id": "\(message.id.peerId.toInt64())_\(message.id.namespace)_\(message.id.id)", "peer_id": String(message.id.peerId.toInt64()), "namespace": message.id.namespace, "message_id": message.id.id, "date": message.timestamp, "text": text, "text_truncated": truncated, "has_media": false, "protected": protected]
    if let author = message.author { result["author_id"] = String(author.id.toInt64()) }
    return result
}

/// JSONSerialization uses NSNumber for JSON numbers. Its Objective-C type is
/// the only Foundation-preserved distinction between `1` and `1.0`; accepting
/// both would make the API's integer contract depend on the parser's coercion.
private func reqGramHistoryLimit(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let type = String(cString: number.objCType)
    guard ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(type) else { return nil }
    let doubleValue = number.doubleValue
    guard doubleValue.isFinite, doubleValue.rounded() == doubleValue,
          doubleValue >= 1, doubleValue <= 50 else { return nil }
    return Int(doubleValue)
}

private func reqGramSearchQuery(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty,
          value.utf8.count <= reqGramMaximumSearchQueryBytes,
          !value.contains("\0") else { return nil }
    return value
}

private func reqGramJSON(_ value: Any) -> Result<Data, ReqGramProviderError> {
    guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value), data.count <= 256 * 1024 else { return .failure("output_limit") }
    return .success(data)
}

final class ReqGramNativeAccountProvider: ReqGramAccountProvider {
    private let context: AccountContext
    let mediaTokens: ReqGramMediaFileTokenRegistry
    init(context: AccountContext) {
        self.context = context
        self.mediaTokens = ReqGramMediaFileTokenRegistry(owner: UUID())
    }
    func mtproto(body: Data, completion: @escaping (Result<Data, ReqGramMTProtoError>) -> Void) -> Disposable {
        let request = (FunctionDescription(name: "reqgram.raw", parameters: []), Buffer(data: body), DeserializeFunctionResponse<Buffer> { $0 })
        return (context.account.network.request(request, automaticFloodWait: false) |> deliverOnMainQueue).start(next: { buffer in
            let response = buffer.makeData()
            guard response.count <= reqGramMTProtoMaximumBody else {
                completion(.failure(ReqGramMTProtoError(code: "response_limit", rpcCode: nil, rpcMessage: nil)))
                return
            }
            completion(.success(response))
        }, error: { error in
            completion(.failure(ReqGramMTProtoError(code: "rpc_error", rpcCode: error.errorCode, rpcMessage: error.errorDescription)))
        })
    }
    func snapshot(profile: Bool, completion: @escaping (ReqGramAccountSnapshot) -> Void) -> Disposable {
        precondition(Thread.isMainThread)
        let current = context.account.id
        return (context.sharedContext.activeAccountsWithInfo |> take(1) |> deliverOnMainQueue).start(next: { value in
            let accounts: [[String: Any]] = value.accounts.map { info in
                var row: [String: Any] = ["handle": "account_\(info.account.id.int64)", "is_primary": info.account.id == value.primary]
                if profile, case let .user(user) = info.peer {
                    row["profile"] = ["first_name": user.firstName ?? "", "last_name": user.lastName ?? "", "username": user.username ?? ""]
                }
                return row
            }.sorted { ($0["handle"] as! String) < ($1["handle"] as! String) }
            completion(ReqGramAccountSnapshot(accounts: accounts, current: value.accounts.contains(where: { $0.account.id == current }) ? "account_\(current.int64)" : nil))
        })
    }
    func peer(id: Int64, completion: @escaping (ReqGramPeerSnapshot?) -> Void) -> Disposable {
        precondition(Thread.isMainThread)
        let peerId = EnginePeer.Id(id)
        return (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)) |> take(1) |> deliverOnMainQueue).start(next: { peer in
            guard let peer else { completion(nil); return }
            let type: String
            switch peer {
            case .user: type = "user"
            case .legacyGroup, .community: type = "group"
            case .channel: type = "channel"
            case .secretChat: completion(nil); return
            }
            let username = peer.usernames.first(where: { $0.flags.contains(.isActive) })?.username ?? peer.usernames.first?.username
            completion(ReqGramPeerSnapshot(id: peer.id.toInt64(), type: type, title: peer.debugDisplayTitle, username: username))
        })
    }
    func read(operation: String, payload: Data?, completion: @escaping (Result<Data, ReqGramProviderError>) -> Void) -> Disposable {
        precondition(Thread.isMainThread)
        guard let payload, payload.count <= 4096, let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], object.keys.count <= 3 else { completion(.failure("invalid_payload")); return EmptyDisposable }
        guard let peerNumber = object["peer_id"] as? String, let peerId = Int64(peerNumber), String(peerId) == peerNumber, peerId != 0 else { completion(.failure("invalid_payload")); return EmptyDisposable }
        let requestedPeer = PeerId(peerId)
        if operation == "chat.context" {
            guard Set(object.keys) == Set(["peer_id"]) else { completion(.failure("invalid_payload")); return EmptyDisposable }
            return (context.account.postbox.transaction { transaction -> Result<Data, ReqGramProviderError> in
                guard let peer = transaction.getPeer(PeerId(peerId)) else { return .failure("peer_not_found") }
                if let rejection = reqGramPeerRejection(peer) { return .failure(ReqGramProviderError(rejection)) }
                let type: String = peer is TelegramUser ? "user" : (peer is TelegramChannel ? "channel" : "group")
                return reqGramJSON(["peer_id": peerNumber, "type": type, "title": peer.debugDisplayTitle, "username": peer.usernames.first?.username as Any? ?? NSNull(), "protected": false, "consistency": "local"])
            } |> deliverOnMainQueue).start(next: completion)
        }
        if operation == "message.get" {
            guard Set(object.keys) == Set(["peer_id", "message_id"]) else { completion(.failure("invalid_payload")); return EmptyDisposable }
            guard let messageValue = object["message_id"] as? String, let messageId = reqGramMessageId(messageValue), messageId.peerId == requestedPeer else { completion(.failure("invalid_payload")); return EmptyDisposable }
            return (context.account.postbox.transaction { transaction -> Result<Data, ReqGramProviderError> in
                guard let peer = transaction.getPeer(PeerId(peerId)) else { return .failure("peer_not_found") }
                if let rejection = reqGramPeerRejection(peer) { return .failure(ReqGramProviderError(rejection)) }
                guard let message = transaction.getMessage(messageId) else { return .failure("message_not_found") }
                guard reqGramMessageRejection(message) == nil else { return .failure("ineligible_message") }
                return reqGramJSON(["message": reqGramMessageDTO(message), "consistency": "local"])
            } |> deliverOnMainQueue).start(next: completion)
        }
        if operation == "message.search" {
            guard Set(object.keys) == Set(["peer_id", "query", "limit"]),
                  let query = reqGramSearchQuery(object["query"]),
                  let limit = reqGramHistoryLimit(object["limit"]),
                  [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(requestedPeer.namespace) else {
                completion(.failure("invalid_payload")); return EmptyDisposable
            }
            return (context.account.postbox.transaction { transaction -> Result<Data, ReqGramProviderError> in
                guard let peer = transaction.getPeer(requestedPeer) else { return .failure("peer_not_found") }
                if let rejection = reqGramPeerRejection(peer) { return .failure(ReqGramProviderError(rejection)) }
                let messages = transaction.searchMessages(peerId: requestedPeer, query: query, tags: nil)
                    .compactMap { reqGramMessageRejection($0) == nil ? reqGramMessageDTO($0) : nil }
                    .prefix(limit)
                return reqGramJSON(["messages": Array(messages), "consistency": "local", "network_fetched": false])
            } |> deliverOnMainQueue).start(next: completion)
        }
        guard operation == "message.history", Set(object.keys).isSubset(of: ["peer_id", "limit", "anchor_id"]), let limit = reqGramHistoryLimit(object["limit"]) else { completion(.failure("invalid_payload")); return EmptyDisposable }
        // A missing anchor means the upper bound. A present value must still
        // be a string; do not silently turn malformed JSON into an unanchored
        // history request.
        let anchor: String?
        if let rawAnchor = object["anchor_id"] {
            guard let stringAnchor = rawAnchor as? String else {
                completion(.failure("invalid_payload")); return EmptyDisposable
            }
            anchor = stringAnchor
        } else {
            anchor = nil
        }
        let anchorId = anchor.flatMap(reqGramMessageId)
        guard anchor == nil || (anchorId?.peerId == requestedPeer && anchorId?.namespace == Namespaces.Message.Cloud) else { completion(.failure("invalid_payload")); return EmptyDisposable }
        guard [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(requestedPeer.namespace) else { completion(.failure("invalid_peer")); return EmptyDisposable }
        // Use Postbox's semantic anchors. An indexed anchor must contain the
        // stored message timestamp; fabricating one (including Int32.max for
        // the no-anchor case) can trip HistoryViewLoadedState assertions.
        let historyAnchor: HistoryViewInputAnchor = anchorId.map { .message($0) } ?? .upperBound
        let readHistory: () -> Disposable = { [weak self] in
            guard let self else { completion(.failure("account_context_unavailable")); return EmptyDisposable }
            return (self.context.account.postbox.aroundMessageHistoryViewForLocation(.peer(peerId: PeerId(peerId), threadId: nil), anchor: historyAnchor, ignoreMessagesInTimestampRange: nil, ignoreMessageIds: Set(), count: limit, fixedCombinedReadStates: nil, topTaggedMessageIdNamespaces: Set(), tag: nil, appendMessagesFromTheSameGroup: false, namespaces: .just(Set([Namespaces.Message.Cloud])), orderStatistics: .combinedLocation) |> take(1) |> map { view, _, _ -> Result<Data, ReqGramProviderError> in
                guard let peer = view.entries.first?.message.peers[PeerId(peerId)] ?? view.entries.first?.message.author else { return .failure("peer_not_found") }
                if let rejection = reqGramPeerRejection(peer) { return .failure(ReqGramProviderError(rejection)) }
                let messages = view.entries.compactMap { reqGramMessageRejection($0.message) == nil ? reqGramMessageDTO($0.message) : nil }
                return reqGramJSON(["messages": messages, "consistency": "local", "hole_before": view.holeEarlier, "hole_after": view.holeLater, "network_fetched": false])
            } |> deliverOnMainQueue).start(next: completion)
        }
        guard let anchorId else { return readHistory() }
        return (context.account.postbox.transaction { transaction -> String? in
            guard transaction.getMessage(anchorId) != nil else { return "message_not_found" }
            return nil
        } |> deliverOnMainQueue).start(next: { failure in
            guard failure == nil else { completion(.failure(ReqGramProviderError(failure!))); return }
            _ = readHistory()
        })
    }

    func watchMessages(peerId: Int64, messageIds: [String], emit: @escaping ([String: String]) -> Void, completion: @escaping (String?) -> Void) -> Disposable {
        precondition(Thread.isMainThread)
        guard messageIds.count <= 8, !messageIds.isEmpty, Set(messageIds).count == messageIds.count else { completion("invalid_payload"); return EmptyDisposable }
        let ids = messageIds.compactMap(reqGramMessageId)
        guard ids.count == messageIds.count, ids.allSatisfy({ $0.peerId == PeerId(peerId) && $0.namespace == Namespaces.Message.Cloud }) else { completion("invalid_payload"); return EmptyDisposable }
        let set = DisposableSet()
        set.add((context.account.postbox.transaction { transaction in reqGramPeerRejection(transaction.getPeer(PeerId(peerId))) } |> deliverOnMainQueue).start(next: { failure in
            guard failure == nil else { completion(failure); return }
            for id in ids {
                var known = false
                set.add((self.context.account.postbox.messageView(id) |> deliverOnMainQueue).start(next: { view in
                    // Protection is deliberately checked for every emission. A peer can
                    // become protected after the watch was installed.
                    guard let message = view.message,
                          let peer = message.peers[PeerId(peerId)],
                          reqGramPeerRejection(peer) == nil,
                          reqGramMessageRejection(message) == nil else {
                        if known { emit(["event": "message.change", "transition": "deleted", "peer_id": String(peerId), "message_id": String(id.id), "namespace": String(id.namespace)]) }
                        known = false; return
                    }
                    let (text, truncated) = reqGramTruncatedText(message.text)
                    emit(["event": "message.change", "transition": known ? "edited" : "created", "peer_id": String(peerId), "message_id": String(id.id), "namespace": String(id.namespace), "text": text, "text_truncated": truncated ? "true" : "false", "has_media": "false"])
                    known = true
                }))
            }
            completion(nil)
        }))
        return set
    }

    func sendText(peerId: Int64, text: String, replyTo: MessageId?, admit: @escaping () -> String?, completion: @escaping (Result<MessageId, ReqGramProviderError>) -> Void) -> Disposable {
        precondition(Thread.isMainThread)
        let target = PeerId(peerId)
        guard !text.isEmpty, text.utf8.count <= reqGramMaximumTextBytes,
              [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(target.namespace),
              replyTo == nil || (replyTo?.peerId == target && replyTo?.namespace == Namespaces.Message.Cloud) else {
            completion(.failure("invalid_payload")); return EmptyDisposable
        }
        let set = DisposableSet()
        set.add((context.account.postbox.transaction { transaction -> String? in
            if let rejection = reqGramSendPeerRejection(transaction.getPeer(target)) { return rejection }
            if let replyTo {
                guard let message = transaction.getMessage(replyTo) else { return "reply_not_found" }
                if let rejection = reqGramMessageRejection(message) { return rejection }
            }
            return nil
        } |> deliverOnMainQueue).start(next: { [weak self] failure in
            guard let self else { completion(.failure("account_context_unavailable")); return }
            guard let failure = failure else {
                // This is intentionally the last admission point. Validation above is
                // asynchronous, so its callback may outlive a revoked/closed session.
                if let failure = admit() { completion(.failure(ReqGramProviderError(failure))); return }
                let message: EnqueueMessage = .message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: replyTo.map { EngineMessageReplySubject(messageId: $0, quote: nil, innerSubject: nil) }, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
                set.add((enqueueMessages(account: self.context.account, peerId: target, messages: [message]) |> take(1) |> deliverOnMainQueue).start(next: { ids in
                    guard ids.count == 1, let id = ids[0] else { completion(.failure("enqueue_failed")); return }
                    completion(.success(id))
                }))
                return
            }
            completion(.failure(ReqGramProviderError(failure)))
        }))
        return set
    }

    func sendMedia(peerId: Int64, fileToken: String, fileName: String, mimeType: String, caption: String, admit: @escaping () -> String?, completion: @escaping (Result<MessageId, ReqGramProviderError>) -> Void) -> Disposable {
        precondition(Thread.isMainThread)
        let target = PeerId(peerId)
        guard fileToken.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil,
              !fileName.isEmpty, fileName.utf8.count <= 255, !fileName.contains("/"), !fileName.contains("\\"),
              mimeType.range(of: "^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}$", options: .regularExpression) != nil,
              caption.utf8.count <= reqGramMaximumTextBytes,
              [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(target.namespace),
              let source = mediaTokens.consume(fileToken, owner: mediaTokens.owner) else { completion(.failure("invalid_payload")); return EmptyDisposable }
        let set = DisposableSet()
        // A consumed token transfers ownership here. Remove its source on
        // cancellation and every terminal path; staging gets its own copy.
        var stagedURL: URL?
        set.add(ActionDisposable { try? FileManager.default.removeItem(at: source.url) })
        set.add(ActionDisposable { if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) } })
        set.add((context.account.postbox.transaction { transaction -> String? in
            return reqGramSendPeerRejection(transaction.getPeer(target))
        } |> deliverOnMainQueue).start(next: { [weak self] failure in
            guard let self else { try? FileManager.default.removeItem(at: source.url); completion(.failure("account_context_unavailable")); return }
            if let failure { try? FileManager.default.removeItem(at: source.url); completion(.failure(ReqGramProviderError(failure))); return }
            guard let values = try? FileManager.default.attributesOfItem(atPath: source.url.path),
                  let size = values[.size] as? NSNumber, size.int64Value == source.size, size.int64Value <= reqGramMaximumMediaBytes,
                  source.name == fileName, source.mime == mimeType else { try? FileManager.default.removeItem(at: source.url); completion(.failure("invalid_payload")); return }
              guard let staging = try? self.stageMedia(source: source.url, token: fileToken, size: size.int64Value) else { try? FileManager.default.removeItem(at: source.url); completion(.failure("file_unavailable")); return }
              stagedURL = staging
              try? FileManager.default.removeItem(at: source.url)
              if let failure = admit() { try? FileManager.default.removeItem(at: staging); stagedURL = nil; completion(.failure(ReqGramProviderError(failure))); return }
            let randomId = Int64.random(in: Int64.min ... Int64.max)
            let resource = LocalFileReferenceMediaResource(localFilePath: staging.path, randomId: randomId, isUniquelyReferencedTemporaryFile: true, size: size.int64Value)
            let file = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: randomId), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: mimeType, size: size.int64Value, attributes: [.FileName(fileName: fileName)], alternativeRepresentations: [])
            let message = EnqueueMessage.message(text: caption, attributes: [], inlineStickers: [:], mediaReference: .standalone(media: file), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
            set.add((enqueueMessages(account: self.context.account, peerId: target, messages: [message]) |> take(1) |> deliverOnMainQueue).start(next: { ids in
                 guard ids.count == 1, let id = ids[0] else { try? FileManager.default.removeItem(at: staging); stagedURL = nil; completion(.failure("enqueue_failed")); return }
                 // The successful enqueue is the ownership hand-off. Until
                 // this point cancellation and every failure path own cleanup.
                 stagedURL = nil
                 completion(.success(id))
            }))
        }))
        return set
    }

    private func stageMedia(source: URL, token: String, size: Int64) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("ReqGramMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("\(token)-\(UUID().uuidString)", isDirectory: false)
        try FileManager.default.copyItem(at: source, to: destination)
        guard FileManager.default.fileExists(atPath: destination.path), (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value == size else { try? FileManager.default.removeItem(at: destination); throw NSError(domain: "ReqGramMedia", code: 1) }
        return destination
    }

    func editText(peerId: Int64, messageId: MessageId, text: String, admit: @escaping () -> String?, completion: @escaping (Result<Bool, ReqGramProviderError>) -> Void) -> Disposable {
        precondition(Thread.isMainThread)
        let target = PeerId(peerId)
        guard messageId.peerId == target, messageId.namespace == Namespaces.Message.Cloud,
              !text.isEmpty, text.utf8.count <= reqGramMaximumTextBytes,
              [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(target.namespace) else {
            completion(.failure("invalid_payload")); return EmptyDisposable
        }
        let set = DisposableSet()
        set.add((context.account.postbox.transaction { transaction -> String? in
            guard let peer = transaction.getPeer(target) else { return "peer_not_found" }
            if let rejection = reqGramPeerRejection(peer) { return rejection }
            guard let message = transaction.getMessage(messageId), message.id.peerId == target else { return "message_not_found" }
            if let rejection = reqGramMessageRejection(message) { return rejection }
            return nil
        } |> deliverOnMainQueue).start(next: { [weak self] failure in
                    guard let self else { completion(.failure("account_context_unavailable")); return }
                    guard let failure else {
                        if let failure = admit() { completion(.failure(ReqGramProviderError(failure))); return }
                        // Re-read the target after the final capability admission. This
                        // closes the local-cache race between the first validation and
                        // the native request (including protection and grouping changes).
                        set.add((self.context.account.postbox.transaction { transaction -> String? in
                            guard let peer = transaction.getPeer(target), reqGramPeerRejection(peer) == nil else { return "restricted" }
                            guard let message = transaction.getMessage(messageId), reqGramMessageRejection(message) == nil else { return "invalid_target" }
                            return nil
                        } |> deliverOnMainQueue).start(next: { latestFailure in
                            guard latestFailure == nil else { completion(.failure(ReqGramProviderError(latestFailure!))); return }
                            set.add((self.context.engine.messages.requestEditMessage(messageId: messageId, text: text, media: .keep, entities: nil, richText: nil, inlineStickers: [:], webpagePreviewAttribute: nil, disableUrlPreview: false, scheduleInfoAttribute: nil) |> deliverOnMainQueue).start(next: { result in
                            switch result {
                            case .progress: break
                            case let .done(changed): completion(.success(changed))
                            }
                            }, error: { error in
                                switch error {
                                case .restricted: completion(.failure("restricted"))
                                case .textTooLong: completion(.failure("text_too_long"))
                                case .invalidGrouping: completion(.failure("invalid_grouping"))
                                case .generic: completion(.failure("edit_failed"))
                                }
                            }))
                        }))
                        return
            }
            completion(.failure(ReqGramProviderError(failure)))
        }))
        return set
    }

    func deleteMessage(peerId: Int64, messageId: MessageId, scope: String, admit: @escaping () -> String?, completion: @escaping (Result<String, ReqGramProviderError>) -> Void) -> Disposable {
        precondition(Thread.isMainThread)
        let target = PeerId(peerId)
        guard messageId.peerId == target, messageId.namespace == Namespaces.Message.Cloud,
              [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(target.namespace),
               scope == "local" else { completion(.failure("invalid_payload")); return EmptyDisposable }
        let set = DisposableSet()
        set.add((context.account.postbox.transaction { transaction -> String? in
            guard let peer = transaction.getPeer(target) else { return "peer_not_found" }
            if let rejection = reqGramPeerRejection(peer) { return rejection }
             guard let message = transaction.getMessage(messageId) else { return "message_not_found" }
             if reqGramMessageRejection(message) != nil { return "ineligible_message" }
            return nil
        } |> deliverOnMainQueue).start(next: { [weak self] failure in
            guard let self else { completion(.failure("account_context_unavailable")); return }
            guard failure == nil else { completion(.failure(ReqGramProviderError(failure!))); return }
            guard let admissionFailure = admit() else {
                set.add((self.context.account.postbox.transaction { transaction -> String? in
                    guard let peer = transaction.getPeer(target), reqGramPeerRejection(peer) == nil else { return "restricted" }
                    guard let message = transaction.getMessage(messageId) else { return "message_not_found" }
                    if reqGramMessageRejection(message) != nil { return "invalid_target" }
                    return nil
                } |> deliverOnMainQueue).start(next: { latestFailure in
                    guard latestFailure == nil else { completion(.failure(ReqGramProviderError(latestFailure!))); return }
                    guard let admissionFailure = admit() else {
                        set.add((self.context.engine.messages.deleteMessagesInteractively(messageIds: [messageId], type: .forLocalPeer, deleteAllInGroup: false, userInitiated: true) |> deliverOnMainQueue).start(completed: { completion(.success("local_deleted")) }))
                        return
                    }
                    completion(.failure(ReqGramProviderError(admissionFailure)))
                }))
                return
            }
            completion(.failure(ReqGramProviderError(admissionFailure)))
        }))
        return set
    }

    func forwardMessage(sourcePeerId: Int64, sourceMessageId: MessageId, destinationPeerId: Int64, admit: @escaping () -> String?, completion: @escaping (Result<MessageId, ReqGramProviderError>) -> Void) -> Disposable {
        precondition(Thread.isMainThread)
        let sourcePeer = PeerId(sourcePeerId)
        let destinationPeer = PeerId(destinationPeerId)
        guard sourceMessageId.peerId == sourcePeer, sourceMessageId.namespace == Namespaces.Message.Cloud,
              [sourcePeer, destinationPeer].allSatisfy({ [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains($0.namespace) }) else {
            completion(.failure("invalid_payload")); return EmptyDisposable
        }
        let set = DisposableSet()
        set.add((context.account.postbox.transaction { transaction -> String? in
            if let rejection = reqGramPeerRejection(transaction.getPeer(sourcePeer)) { return rejection }
            if let rejection = reqGramSendPeerRejection(transaction.getPeer(destinationPeer)) { return rejection }
            guard let message = transaction.getMessage(sourceMessageId) else { return "message_not_found" }
            if let rejection = reqGramMessageRejection(message) { return rejection }
            return nil
        } |> deliverOnMainQueue).start(next: { [weak self] failure in
            guard let self else { completion(.failure("account_context_unavailable")); return }
            guard failure == nil else { completion(.failure(ReqGramProviderError(failure!))); return }
            // Revalidate source and destination after capability admission and
            // immediately before the enqueue side effect.
            set.add((self.context.account.postbox.transaction { transaction -> String? in
                guard reqGramPeerRejection(transaction.getPeer(sourcePeer)) == nil,
                      reqGramSendPeerRejection(transaction.getPeer(destinationPeer)) == nil,
                      let message = transaction.getMessage(sourceMessageId),
                      reqGramMessageRejection(message) == nil else { return "invalid_target" }
                return nil
            } |> deliverOnMainQueue).start(next: { latestFailure in
                guard latestFailure == nil else { completion(.failure(ReqGramProviderError(latestFailure!))); return }
                if let admissionFailure = admit() { completion(.failure(ReqGramProviderError(admissionFailure))); return }
                let message: EnqueueMessage = .forward(source: sourceMessageId, threadId: nil, grouping: .auto, attributes: [], correlationId: nil)
                set.add((enqueueMessages(account: self.context.account, peerId: destinationPeer, messages: [message]) |> take(1) |> deliverOnMainQueue).start(next: { ids in
                    guard ids.count == 1, let id = ids[0] else { completion(.failure("enqueue_failed")); return }
                    completion(.success(id))
                }))
            }))
        }))
        return set
    }
}

#if DEBUG
final class ReqGramFakeAccountProvider: ReqGramAccountProvider {
    private(set) var sent: [(Int64, String, MessageId?)] = []
    private(set) var mediaSent: [(Int64, String, String, String, String)] = []
    private(set) var edited: [(Int64, MessageId, String)] = []
    var editOutcome: Result<Bool, ReqGramProviderError> = .success(false)
    var deferEditAdmission = false
    private(set) var pendingEditAdmission: (() -> String?)?
    private(set) var deleted: [(Int64, MessageId, String)] = []
    private(set) var forwarded: [(Int64, MessageId, Int64)] = []
    var forwardOutcome: Result<MessageId, ReqGramProviderError>?
    var deferForwardAdmission = false
    private(set) var pendingForwardAdmission: (() -> String?)?
    var deleteOutcome: Result<String, ReqGramProviderError> = .success("local_deleted")
    var deferDeleteAdmission = false
    private(set) var pendingDeleteAdmission: (() -> String?)?
    func snapshot(profile: Bool, completion: @escaping (ReqGramAccountSnapshot) -> Void) -> Disposable {
        precondition(Thread.isMainThread)
        var row: [String: Any] = ["handle": "account_fixture", "is_primary": true]
        if profile { row["profile"] = ["first_name": "Fixture", "last_name": "Only", "username": "fixture_only"] }
        completion(ReqGramAccountSnapshot(accounts: [row], current: "account_fixture"))
        return EmptyDisposable
    }
    func peer(id: Int64, completion: @escaping (ReqGramPeerSnapshot?) -> Void) -> Disposable {
        precondition(Thread.isMainThread)
        completion(id == 4242 ? ReqGramPeerSnapshot(id: 4242, type: "user", title: "Fixture Peer", username: "fixture_peer") : nil)
        return EmptyDisposable
    }
    func read(operation: String, payload: Data?, completion: @escaping (Result<Data, ReqGramProviderError>) -> Void) -> Disposable { completion(.failure("runtime_fixture_unavailable")); return EmptyDisposable }
    func mtproto(body: Data, completion: @escaping (Result<Data, ReqGramMTProtoError>) -> Void) -> Disposable {
        completion(.success(body)); return EmptyDisposable
    }
    func watchMessages(peerId: Int64, messageIds: [String], emit: @escaping ([String: String]) -> Void, completion: @escaping (String?) -> Void) -> Disposable { completion(nil); return EmptyDisposable }
    func sendText(peerId: Int64, text: String, replyTo: MessageId?, admit: @escaping () -> String?, completion: @escaping (Result<MessageId, ReqGramProviderError>) -> Void) -> Disposable {
        if let failure = admit() { completion(.failure(ReqGramProviderError(failure))); return EmptyDisposable }
        sent.append((peerId, text, replyTo))
        completion(.success(MessageId(peerId: PeerId(peerId), namespace: Namespaces.Message.Local, id: Int32(sent.count))))
        return EmptyDisposable
    }
    func sendMedia(peerId: Int64, fileToken: String, fileName: String, mimeType: String, caption: String, admit: @escaping () -> String?, completion: @escaping (Result<MessageId, ReqGramProviderError>) -> Void) -> Disposable {
        if let failure = admit() { completion(.failure(ReqGramProviderError(failure))); return EmptyDisposable }
        mediaSent.append((peerId, fileToken, fileName, mimeType, caption))
        completion(.success(MessageId(peerId: PeerId(peerId), namespace: Namespaces.Message.Local, id: Int32(mediaSent.count))))
        return EmptyDisposable
    }
    func editText(peerId: Int64, messageId: MessageId, text: String, admit: @escaping () -> String?, completion: @escaping (Result<Bool, ReqGramProviderError>) -> Void) -> Disposable {
        edited.append((peerId, messageId, text))
        if deferEditAdmission { pendingEditAdmission = admit; return EmptyDisposable }
        if let failure = admit() { completion(.failure(ReqGramProviderError(failure))); return EmptyDisposable }
        completion(editOutcome); return EmptyDisposable
    }
    func deleteMessage(peerId: Int64, messageId: MessageId, scope: String, admit: @escaping () -> String?, completion: @escaping (Result<String, ReqGramProviderError>) -> Void) -> Disposable {
        if deferDeleteAdmission { pendingDeleteAdmission = admit; return EmptyDisposable }
        if let failure = admit() { completion(.failure(ReqGramProviderError(failure))); return EmptyDisposable }
        deleted.append((peerId, messageId, scope)); completion(deleteOutcome); return EmptyDisposable
    }
    func forwardMessage(sourcePeerId: Int64, sourceMessageId: MessageId, destinationPeerId: Int64, admit: @escaping () -> String?, completion: @escaping (Result<MessageId, ReqGramProviderError>) -> Void) -> Disposable {
        if deferForwardAdmission { pendingForwardAdmission = admit; return EmptyDisposable }
        if let failure = admit() { completion(.failure(ReqGramProviderError(failure))); return EmptyDisposable }
        forwarded.append((sourcePeerId, sourceMessageId, destinationPeerId))
        completion(forwardOutcome ?? .success(MessageId(peerId: PeerId(destinationPeerId), namespace: Namespaces.Message.Local, id: Int32(forwarded.count))))
        return EmptyDisposable
    }
}
#endif
