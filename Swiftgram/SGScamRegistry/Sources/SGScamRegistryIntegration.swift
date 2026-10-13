import AccountContext
import SwiftSignalKit
import TelegramApi
import TelegramCore

/// Installs the account-bound source used by the process-wide registry.
/// The source follows the active primary account; passing nil disables network
/// access while the app has no authorized account.
public enum SGScamRegistryIntegration {
    public static func configure(for context: AccountContext?) {
        if let context {
            SGScamRegistryService.shared.setDataSource(SGScamRegistryAccountDataSource(context: context))
        } else {
            SGScamRegistryService.shared.setDataSource(nil)
        }
        SGScamRegistryService.shared.start()
    }
}

private final class SGScamRegistryAccountDataSource: SGScamRegistryDataSource {
    private enum FetchError: Error {
        case invalidPeer, invalidHistory, sourceLimitExceeded, timedOut, incomplete
    }

    private let context: AccountContext

    init(context: AccountContext) {
        self.context = context
    }

    func fetchScamRegistryTexts(completion: @escaping (Result<[String], Error>) -> Void) {
        let maximumMessages = 1_000_000
        let maximumPageSize = 100
        // Allow one final empty/short page, while keeping the page-count guard
        // derived from the message bound rather than using an overflowing
        // message counter or an unbounded recursive request chain.
        let maximumPageCount = maximumMessages / maximumPageSize + 1
        let maximumSourceBytes = 4 * 1024 * 1024
        var texts: [String] = []
        var messageCount = 0
        var sourceBytes = 0

        func inputPeer(_ peer: EnginePeer) -> Api.InputPeer? {
            switch peer {
            case let .user(user):
                guard let accessHash = user.accessHash else { return nil }
                return .inputPeerUser(.init(userId: user.id.id._internalGetInt64Value(), accessHash: accessHash.value))
            case let .legacyGroup(group):
                return .inputPeerChat(.init(chatId: group.id.id._internalGetInt64Value()))
            case let .channel(channel):
                guard let accessHash = channel.accessHash else { return nil }
                return .inputPeerChannel(.init(channelId: channel.id.id._internalGetInt64Value(), accessHash: accessHash.value))
            case let .community(community):
                guard let accessHash = community.accessHash else { return nil }
                return .inputPeerChannel(.init(channelId: community.id.id._internalGetInt64Value(), accessHash: accessHash.value))
            case .secretChat:
                return nil
            }
        }

        func fetchPage(peer: Api.InputPeer, offsetId: Int32, pageCount: Int) -> Signal<[String], Error> {
            guard pageCount < maximumPageCount else { return .fail(FetchError.sourceLimitExceeded) }
            return context.account.network.request(Api.functions.messages.getHistory(peer: peer, offsetId: offsetId, offsetDate: 0, addOffset: 0, limit: Int32(maximumPageSize), maxId: Int32.max, minId: 0, hash: 0), automaticFloodWait: false)
            |> mapError { _ -> Error in FetchError.incomplete }
            |> mapToSignal { response -> Signal<[String], Error> in
                let messages: [Api.Message]
                switch response {
                case let .channelMessages(value): messages = value.messages
                case let .messages(value): messages = value.messages
                case let .messagesSlice(value): messages = value.messages
                case .messagesNotModified: return .fail(FetchError.invalidHistory)
                }
                guard !messages.isEmpty else { return .single(texts) }
                guard messages.count <= maximumPageSize, messageCount <= maximumMessages - messages.count else {
                    return .fail(FetchError.sourceLimitExceeded)
                }
                messageCount += messages.count
                var nextOffsetId = offsetId == 0 ? Int32.max : offsetId
                for message in messages {
                    let id: Int32
                    switch message {
                    case let .message(value):
                        id = value.id
                        let bytes = value.message.utf8.count
                        guard bytes <= maximumSourceBytes - sourceBytes else { return .fail(FetchError.sourceLimitExceeded) }
                        sourceBytes += bytes
                        texts.append(value.message)
                    case let .messageService(value): id = value.id
                    case let .messageEmpty(value): id = value.id
                    }
                    guard id > 0, offsetId == 0 || id < offsetId else { return .fail(FetchError.invalidHistory) }
                    nextOffsetId = min(nextOffsetId, id)
                }
                guard nextOffsetId > 0, offsetId == 0 || nextOffsetId < offsetId else { return .fail(FetchError.invalidHistory) }
                if messageCount == maximumMessages { return .single(texts) }
                return fetchPage(peer: peer, offsetId: nextOffsetId, pageCount: pageCount + 1)
            }
        }

        let signal = context.engine.peers.resolvePeerByName(name: SGScamRegistryService.channelUsername, referrer: nil)
        var finished = false
        func finish(_ result: Result<[String], Error>) {
            guard !finished else { return }
            finished = true
            completion(result)
        }
        _ = (signal |> filter { result in
            if case .result = result { return true }
            return false
        } |> take(1) |> castError(Error.self) |> mapToSignal { result -> Signal<[String], Error> in
            guard case let .result(peer) = result, let peer, let peer = inputPeer(peer), case .inputPeerChannel = peer else {
                return .fail(FetchError.invalidPeer)
            }
            return fetchPage(peer: peer, offsetId: 0, pageCount: 0)
        } |> timeout(120.0, queue: Queue.concurrentDefaultQueue(), alternate: .fail(FetchError.timedOut))
          |> deliverOnMainQueue).start(next: { finish(.success($0)) }, error: { finish(.failure($0)) }, completed: { finish(.failure(FetchError.incomplete)) })
    }
}
