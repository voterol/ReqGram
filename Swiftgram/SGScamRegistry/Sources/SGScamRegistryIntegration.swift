import AccountContext
import Foundation
import SwiftSignalKit
import TelegramApi
import TelegramCore

/// Installs the account-bound source used by the process-wide registry.
/// The source follows the active primary account; passing nil disables network
/// access while the app has no authorized account.
public enum SGScamRegistryIntegration {
    public static func configure(for context: AccountContext?) {
        sgScamRegistryLog("configure: account=\(context.map { String(describing: $0.account.id) } ?? "nil")")
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
        case cancelled, invalidPeer, invalidHistory, timedOut
    }

    /// One `fetchScamRegistryChunk` invocation. Pages are requested strictly
    /// one at a time with `pagePacing` between requests, up to the caller's
    /// page budget, and the advanced checkpoint travels back with the result
    /// so the next run resumes exactly where this one stopped.
    ///
    /// The signal callbacks capture `self` strongly on purpose: the instance
    /// must live exactly as long as the in-flight chain, and the chain is
    /// always bounded (budget) or disposed (`cancelFetch`).
    private final class Run {
        private static let pageSize = 100
        private static let pagePacing: TimeInterval = 0.5
        /// Soft per-run byte budget (checked between pages, so a single page
        /// may push slightly past it).
        private static let maximumRunBytes = 1024 * 1024

        private let source: SGScamRegistryAccountDataSource
        private let context: AccountContext
        private var state: SGScamRegistryFetchState
        private let pageBudget: Int
        private let completion: (Result<SGScamRegistryFetchChunk, Error>) -> Void

        private let lock = NSLock()
        private var finished = false
        /// Guards the `completed:` safety net below: `take(1)` completes the
        /// resolve chain right after `next`, which is a success — not a
        /// timeout. Only completing without ever delivering a peer is fatal.
        private var peerDelivered = false

        private var texts: [String] = []
        private var runBytes = 0
        private var pages = 0
        private var runMinId: Int32 = Int32.max
        private var runMaxId: Int32 = 0

        init(source: SGScamRegistryAccountDataSource, context: AccountContext, state: SGScamRegistryFetchState, pageBudget: Int, completion: @escaping (Result<SGScamRegistryFetchChunk, Error>) -> Void) {
            self.source = source
            self.context = context
            self.state = state
            self.pageBudget = max(1, pageBudget)
            self.completion = completion
        }

        func start() {
            let signal = context.engine.peers.resolvePeerByName(name: SGScamRegistryService.channelUsername, referrer: nil)
            let disposable = (signal |> filter { result in
                if case .result = result { return true }
                return false
            } |> take(1) |> castError(Error.self) |> mapToSignal { result -> Signal<Api.InputPeer, Error> in
                guard case let .result(peer) = result, let peer, let peer = Self.inputPeer(peer), case .inputPeerChannel = peer else {
                    return .fail(FetchError.invalidPeer)
                }
                return .single(peer)
            } |> timeout(30.0, queue: Queue.concurrentDefaultQueue(), alternate: .fail(FetchError.timedOut))
            ).start(next: { peer in
                sgScamRegistryLog("run: peer resolved, starting pages from offsetId=\(self.state.offsetId)")
                self.setPeerDelivered()
                self.requestNextPage(peer: peer)
            }, error: { error in
                sgScamRegistryLog("run: peer resolve failed: \(error)")
                self.deliver(.failure(error))
            }, completed: {
                // The chain uses `take(1)`, so completion fires immediately
                // after a successful `next`. Completing without a peer means
                // the resolve signal ended empty-handed — only then is this a
                // failure; otherwise the run continues asynchronously.
                guard self.wasPeerDelivered() else {
                    self.deliver(.failure(FetchError.timedOut))
                    return
                }
            })
            source.track(disposable)
        }

        private func requestNextPage(peer: Api.InputPeer) {
            guard !isFinished else { return }
            if source.isCancelled() {
                deliver(.failure(FetchError.cancelled))
                return
            }
            let offsetId = state.offsetId
            let disposable = (context.account.network.request(Api.functions.messages.getHistory(peer: peer, offsetId: offsetId, offsetDate: 0, addOffset: 0, limit: Int32(Self.pageSize), maxId: Int32.max, minId: 0, hash: 0), automaticFloodWait: true)
            |> mapError { _ -> Error in FetchError.invalidHistory }
            |> timeout(60.0, queue: Queue.concurrentDefaultQueue(), alternate: .fail(FetchError.timedOut))
            ).start(next: { response in
                self.handlePage(response: response, peer: peer, offsetId: offsetId)
            }, error: { error in
                sgScamRegistryLog("run: page \(self.pages) failed: \(error)")
                // Keep partial progress: pages already collected this run are
                // delivered as a resumable chunk instead of discarding them.
                if self.pages == 0 && self.texts.isEmpty {
                    self.deliver(.failure(error))
                } else {
                    self.finish(hasMore: true, sweptToEnd: false)
                }
            })
            source.track(disposable)
        }

        private func handlePage(response: Api.messages.Messages, peer: Api.InputPeer, offsetId: Int32) {
            guard !isFinished else { return }
            if source.isCancelled() {
                deliver(.failure(FetchError.cancelled))
                return
            }
            let messages: [Api.Message]
            switch response {
            case let .channelMessages(value): messages = value.messages
            case let .messages(value): messages = value.messages
            case let .messagesSlice(value): messages = value.messages
            case .messagesNotModified:
                // Defensive: with `hash: 0` the server should not send this,
                // and honoring it as "end of history" would fake a completed
                // full sweep (skipping backlog for up to a week). Treat it as
                // a fetch error, preserving any partial run progress.
                if pages == 0 && texts.isEmpty {
                    deliver(.failure(FetchError.invalidHistory))
                } else {
                    finish(hasMore: true, sweptToEnd: false)
                }
                return
            }
            guard !messages.isEmpty else {
                finish(hasMore: false, sweptToEnd: true)
                return
            }

            var pageMinId = Int32.max
            var pageMaxId: Int32 = 0
            var nextOffsetId = offsetId == 0 ? Int32.max : offsetId
            for message in messages {
                let id: Int32
                switch message {
                case let .message(value):
                    id = value.id
                    runBytes += value.message.utf8.count
                    texts.append(value.message)
                case let .messageService(value): id = value.id
                case let .messageEmpty(value): id = value.id
                }
                guard id > 0 else { continue }
                pageMinId = min(pageMinId, id)
                pageMaxId = max(pageMaxId, id)
                nextOffsetId = min(nextOffsetId, id)
            }
            runMinId = min(runMinId, pageMinId)
            runMaxId = max(runMaxId, pageMaxId)
            pages += 1
            // Default checkpoint: continue descending from the oldest message
            // of this page. `finish` overrides it for stop conditions.
            state.offsetId = nextOffsetId

            // End of history: Telegram returns a short final page.
            if messages.count < Self.pageSize {
                finish(hasMore: false, sweptToEnd: true)
                return
            }
            // Caught up: this page reaches into already-traversed territory
            // below the high-water mark. Only valid once a full traversal has
            // actually completed (`lastFullSweepAt > 0`) — during an initial
            // catch-up sweep the watermark may already point at the channel
            // top while everything below is still unknown, so the run must
            // keep descending all the way to the bottom of the history.
            if state.lastFullSweepAt > 0, state.newestParsedId > 0, pageMinId <= state.newestParsedId {
                finish(hasMore: false, sweptToEnd: false)
                return
            }
            // Run budget reached — pause and let the service resume from the
            // checkpoint shortly ("little by little", never a mega-burst).
            if pages >= pageBudget || runBytes >= Self.maximumRunBytes {
                finish(hasMore: true, sweptToEnd: false)
                return
            }
            guard nextOffsetId > 0 else {
                finish(hasMore: false, sweptToEnd: true)
                return
            }
            // Pace: never fire pages back-to-back.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.pagePacing) {
                self.requestNextPage(peer: peer)
            }
        }

        private func finish(hasMore: Bool, sweptToEnd: Bool) {
            guard !isFinished else { return }
            if runMinId < Int32.max {
                state.oldestParsedId = state.oldestParsedId == 0 ? runMinId : min(state.oldestParsedId, runMinId)
            }
            if runMaxId > 0 {
                state.newestParsedId = max(state.newestParsedId, runMaxId)
            }
            if sweptToEnd {
                state.lastFullSweepAt = Date().timeIntervalSince1970
            }
            sgScamRegistryLog("run: finish pages=\(pages) texts=\(texts.count) bytes=\(runBytes) hasMore=\(hasMore) sweptToEnd=\(sweptToEnd) nextOffsetId=\(state.offsetId) newestParsedId=\(state.newestParsedId)")
            // Swept to the end or caught up with known history → the next run
            // starts again from the newest messages. Only a budget pause keeps
            // a descending checkpoint.
            if sweptToEnd || !hasMore {
                state.offsetId = 0
            }
            deliver(.success(SGScamRegistryFetchChunk(texts: texts, state: state, hasMore: hasMore, sweptToEnd: sweptToEnd)))
        }

        /// External cancellation (account switch/logout). Disposing the
        /// in-flight network request alone would silence the signal — the
        /// service would then never receive the completion and its
        /// `refreshing` flag would be stuck forever. Delivering through the
        /// exactly-once `deliver` is what fulfills the data-source contract.
        func cancel() {
            deliver(.failure(FetchError.cancelled))
        }

        private var isFinished: Bool {
            lock.lock(); defer { lock.unlock() }
            return finished
        }

        private func setPeerDelivered() {
            lock.lock(); peerDelivered = true; lock.unlock()
        }

        private func wasPeerDelivered() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return peerDelivered
        }

        /// Exactly-once delivery. Must be called for every code path that
        /// started a run — including cancellation — so the service can always
        /// clear its `refreshing` flag.
        private func deliver(_ result: Result<SGScamRegistryFetchChunk, Error>) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()
            completion(result)
        }

        private static func inputPeer(_ peer: EnginePeer) -> Api.InputPeer? {
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
    }

    private let context: AccountContext
    let lock = NSLock()
    private var cancelled = false
    private var activeDisposable: Disposable?
    /// Retained so `cancelFetch` can deliver a terminal result to the service
    /// even after the in-flight network disposable has been disposed (a
    /// disposed signal never fires callbacks, so the Run itself must be told).
    private var activeRun: Run?

    init(context: AccountContext) {
        self.context = context
    }

    func fetchScamRegistryChunk(state: SGScamRegistryFetchState, pageBudget: Int, completion: @escaping (Result<SGScamRegistryFetchChunk, Error>) -> Void) {
        guard !isCancelled() else {
            completion(.failure(FetchError.cancelled))
            return
        }
        let run = Run(source: self, context: context, state: state, pageBudget: pageBudget, completion: completion)
        lock.lock()
        activeRun = run
        lock.unlock()
        run.start()
    }

    func cancelFetch() {
        lock.lock()
        cancelled = true
        let disposable = activeDisposable
        activeDisposable = nil
        let run = activeRun
        activeRun = nil
        lock.unlock()
        disposable?.dispose()
        // Must happen after `cancelled = true` so a pacing continuation that
        // races this call also observes cancellation. Exactly-once: a Run
        // that already finished ignores this.
        run?.cancel()
    }

    func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Tracks the currently in-flight request so `cancelFetch` can dispose it.
    /// If cancellation already happened, the disposable is disposed right away.
    func track(_ disposable: Disposable) {
        lock.lock()
        if cancelled {
            activeDisposable = nil
        } else {
            activeDisposable = disposable
        }
        lock.unlock()
        if cancelled {
            disposable.dispose()
        }
    }
}
