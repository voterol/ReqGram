import Foundation
import AyuGram
import Postbox
import SGLogging
import SGSimpleSettings
import SwiftSignalKit

public enum AyuHooks {
    private static let pendingLock = NSLock()
    private static var pendingDisposables: [String: Disposable] = [:]
    /// Legacy default per-file cap (50 MB), used when the setting is somehow unset.
    private static let defaultAttachmentBytes: Int64 = 50 * 1024 * 1024

    /// Batch cap used when the per-file limit is at or below 50 MB.
    private static let defaultBatchBytes: Int64 = 200 * 1024 * 1024

    /// User-configured per-file media limit (SGSimpleSettings.ayuMediaLimitBytes).
    /// 0 means no per-file limit.
    private static func maxAttachmentBytes() -> Int64 {
        let value = SGSimpleSettings.shared.ayuMediaLimitBytes
        return value > 0 ? value : Int64.max
    }

    /// Total bytes a single delete operation may copy. Bounds the time the
    /// postbox transaction queue can be blocked by bulk media-heavy deletes.
    ///
    /// Policy: 200 MB while the per-file limit stays <= 50 MB (including an
    /// unlimited per-file setting); otherwise the finite batch cap scales to
    /// 4x the per-file limit.
    private static func maxBatchBytes() -> Int64 {
        let perFile = SGSimpleSettings.shared.ayuMediaLimitBytes
        if perFile <= 0 {
            return defaultBatchBytes
        }
        if perFile <= defaultAttachmentBytes {
            return defaultBatchBytes
        }
        let (scaled, overflow) = perFile.multipliedReportingOverflow(by: 4)
        return overflow ? Int64.max : scaled
    }

    static func willDeleteMessages(transaction: Transaction, ids: [MessageId], accountPeerId: PeerId, postbox: Postbox) {
        SGLogger.shared.log("AyuGram", "willDeleteMessages ids=\(ids.count)")
        guard SGSimpleSettings.shared.ayuSaveDeletedMessages else { return }
        let accountId = accountPeerId.toInt64()
        var remainingBatchBytes = maxBatchBytes()
        let snapshots = ids.compactMap { id -> AyuSavedMessage? in
            guard let message = transaction.getMessage(id), shouldPreserve(transaction: transaction, message: message, allowCloudEphemeralMedia: false, allowOutgoingMessages: true) else { return nil }
            let preserveMedia = shouldPreserveMedia(transaction: transaction, message: message)
            let snapshot = self.snapshot(message, accountId: accountId, mediaBox: postbox.mediaBox, preserveMedia: preserveMedia, remainingBatchBytes: &remainingBatchBytes, effectiveCopyProtected: effectiveCopyProtection(transaction: transaction, message: message))
            // Do not create empty snapshots for media-only messages whose
            // attachments were not cached locally or are excluded.
            guard !snapshot.text.isEmpty || !snapshot.media.isEmpty else { return nil }
            return snapshot
        }
        AyuMessageStore.shared.saveDeleted(messages: snapshots)
    }

    static func willDeleteMessagesWithGlobalIds(transaction: Transaction, globalIds: [Int32], accountPeerId: PeerId, postbox: Postbox) {
        SGLogger.shared.log("AyuGram", "willDeleteMessagesWithGlobalIds ids=\(globalIds.count)")
        willDeleteMessages(
            transaction: transaction,
            ids: transaction.messageIdsForGlobalIds(globalIds),
            accountPeerId: accountPeerId,
            postbox: postbox
        )
    }

    /// Match the store's per-peer retention bound before snapshot construction,
    /// so candidates that would immediately be pruned never synchronously copy
    /// media on the Postbox queue.
    private static func newestCandidateIds(transaction: Transaction, peerId: PeerId, namespace: MessageId.Namespace, threadId: Int64? = nil, minTimestamp: Int32? = nil, maxTimestamp: Int32? = nil, minId: MessageId.Id? = nil, maxId: MessageId.Id? = nil) -> [MessageId] {
        var ids: [MessageId] = []
        ids.reserveCapacity(AyuMessageStore.maxMessagesPerPeer)
        transaction.withAllMessages(peerId: peerId, namespace: namespace, reversed: true) { message in
            guard ids.count < AyuMessageStore.maxMessagesPerPeer else { return false }
            if let threadId, message.threadId != threadId { return true }
            if let minTimestamp, message.timestamp < minTimestamp { return true }
            if let maxTimestamp, message.timestamp > maxTimestamp { return true }
            if let minId, message.id.id < minId { return true }
            if let maxId, message.id.id > maxId { return true }
            guard shouldPreserve(transaction: transaction, message: message, allowCloudEphemeralMedia: false, allowOutgoingMessages: true) else { return true }
            ids.append(message.id)
            return true
        }
        return ids
    }

    /// Captures real cloud messages before a local clear/delete removes them
    /// from Postbox. Existing snapshots intentionally remain untouched.
    static func willClearHistoryLocally(transaction: Transaction, accountPeerId: PeerId, peerId: PeerId, threadId: Int64?, minTimestamp: Int32?, maxTimestamp: Int32?, mediaBox: MediaBox) {
        guard peerId.namespace == Namespaces.Peer.CloudUser
            || peerId.namespace == Namespaces.Peer.CloudGroup
            || peerId.namespace == Namespaces.Peer.CloudChannel else { return }
        guard SGSimpleSettings.shared.ayuSaveDeletedMessages else { return }
        let ids = newestCandidateIds(transaction: transaction, peerId: peerId, namespace: Namespaces.Message.Cloud, threadId: threadId, minTimestamp: minTimestamp, maxTimestamp: maxTimestamp)
        let accountId = accountPeerId.toInt64()
        var remainingBatchBytes = maxBatchBytes()
        let snapshots = ids.compactMap { id -> AyuSavedMessage? in
            guard let message = transaction.getMessage(id), shouldPreserve(transaction: transaction, message: message, allowCloudEphemeralMedia: false, allowOutgoingMessages: true) else { return nil }
            let preserveMedia = shouldPreserveMedia(transaction: transaction, message: message)
            let value = snapshot(message, accountId: accountId, mediaBox: mediaBox, preserveMedia: preserveMedia, remainingBatchBytes: &remainingBatchBytes, effectiveCopyProtected: effectiveCopyProtection(transaction: transaction, message: message))
            return !value.text.isEmpty || !value.media.isEmpty ? value : nil
        }
        AyuMessageStore.shared.saveDeleted(messages: snapshots)
    }

    /// Repairs only the legacy inclusion shape Ayu itself created: an unpinned,
    /// empty cloud peer whose sole minimum timestamp exactly equals the latest
    /// saved snapshot. Unmatched and pinned inclusions are intentionally left
    /// alone. The repair is idempotent, so no separately-failable marker is
    /// needed.
    static func repairLegacySavedOnlyChatListInclusions(postbox: Postbox, accountPeerId: PeerId) {
        let latestTimestamps = AyuMessageStore.shared.latestDeletedMessageTimestamps(accountId: accountPeerId.toInt64())
        guard !latestTimestamps.isEmpty else { return }
        let _ = postbox.transaction { transaction -> Void in
            for (rawPeerId, timestamp) in latestTimestamps {
                let peerId = PeerId(rawPeerId)
                guard peerId.namespace == Namespaces.Peer.CloudUser
                    || peerId.namespace == Namespaces.Peer.CloudGroup
                    || peerId.namespace == Namespaces.Peer.CloudChannel else { continue }
                if let state = transaction.getPeerChatInterfaceState(peerId),
                   let scrollIndex = state.historyScrollMessageIndex,
                   isLegacySyntheticScrollIndex(scrollIndex, accountPeerId: accountPeerId, threadId: nil),
                   transaction.getMessage(scrollIndex.id) == nil {
                    var updatedData = state.data
                    if let data = state.data,
                       let internalState = try? AdaptedPostboxDecoder().decode(InternalChatInterfaceState.self, from: data),
                       let encoded = try? AdaptedPostboxEncoder().encode(InternalChatInterfaceState(
                           synchronizeableInputState: internalState.synchronizeableInputState,
                           historyScrollMessageIndex: nil,
                           mediaDraftState: internalState.mediaDraftState,
                           opaqueData: internalState.opaqueData
                       )) {
                        updatedData = encoded
                    }
                    transaction.setPeerChatInterfaceState(peerId, state: StoredPeerChatInterfaceState(
                        overrideChatTimestamp: state.overrideChatTimestamp,
                        historyScrollMessageIndex: nil,
                        associatedMessageIds: state.associatedMessageIds,
                        data: updatedData
                    ))
                }

                if transaction.getTopPeerMessageId(peerId: peerId, namespace: Namespaces.Message.Cloud) == nil,
                   case let .ifHasMessagesOrOneOf(_, pinningIndex, minTimestamp) = transaction.getPeerChatListInclusion(peerId),
                   pinningIndex == nil, minTimestamp == timestamp {
                    transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)
                }
            }
        }.start()
    }

    public static func isLegacySyntheticScrollIndex(_ index: MessageIndex, accountPeerId: PeerId, threadId: Int64?) -> Bool {
        guard index.id.namespace == Namespaces.Message.Cloud else { return false }
        return AyuMessageStore.shared.deletedMessages(peerId: index.id.peerId.toInt64(), accountId: accountPeerId.toInt64()).contains(where: { saved in
            let threadMatches: Bool
            if index.id.peerId.namespace == Namespaces.Peer.CloudChannel && threadId == nil {
                threadMatches = saved.threadId == nil || saved.threadId == 1
            } else {
                threadMatches = saved.threadId == threadId
            }
            return threadMatches
                && saved.date == index.timestamp
                && AyuSyntheticMessageIdentity.syntheticMessageId(originalId: saved.messageId) == index.id.id
        })
    }

    public static func repairLegacySyntheticScrollState(postbox: Postbox, accountPeerId: PeerId, peerId: PeerId, threadId: Int64?) -> Signal<Void, NoError> {
        return postbox.transaction { transaction -> Void in
            let state: StoredPeerChatInterfaceState?
            if let threadId {
                state = transaction.getPeerChatThreadInterfaceState(peerId, threadId: threadId)
            } else {
                state = transaction.getPeerChatInterfaceState(peerId)
            }
            guard let state,
                  let scrollIndex = state.historyScrollMessageIndex,
                  transaction.getMessage(scrollIndex.id) == nil,
                  isLegacySyntheticScrollIndex(scrollIndex, accountPeerId: accountPeerId, threadId: threadId) else {
                return
            }

            var updatedData = state.data
            if let data = state.data,
               let internalState = try? AdaptedPostboxDecoder().decode(InternalChatInterfaceState.self, from: data),
               let encoded = try? AdaptedPostboxEncoder().encode(InternalChatInterfaceState(
                   synchronizeableInputState: internalState.synchronizeableInputState,
                   historyScrollMessageIndex: nil,
                   mediaDraftState: internalState.mediaDraftState,
                   opaqueData: internalState.opaqueData
               )) {
                updatedData = encoded
            }
            let updatedState = StoredPeerChatInterfaceState(
                overrideChatTimestamp: state.overrideChatTimestamp,
                historyScrollMessageIndex: nil,
                associatedMessageIds: state.associatedMessageIds,
                data: updatedData
            )
            if let threadId {
                transaction.setPeerChatThreadInterfaceState(peerId, threadId: threadId, state: updatedState)
            } else {
                transaction.setPeerChatInterfaceState(peerId, state: updatedState)
            }
        }
    }

    static func willDeleteMessagesInRange(transaction: Transaction, peerId: PeerId, namespace: MessageId.Namespace, minId: MessageId.Id, maxId: MessageId.Id, accountPeerId: PeerId, postbox: Postbox) {
        SGLogger.shared.log("AyuGram", "willDeleteMessagesInRange peerId=\(peerId.toInt64()) minId=\(minId) maxId=\(maxId)")
        guard SGSimpleSettings.shared.ayuSaveDeletedMessages else { return }
        let ids = newestCandidateIds(transaction: transaction, peerId: peerId, namespace: namespace, minId: minId, maxId: maxId)
        willDeleteMessages(transaction: transaction, ids: ids, accountPeerId: accountPeerId, postbox: postbox)
    }

    /// Captures a message whose media is about to expire (TTL/autoremove media
    /// strip) or that is about to be removed by the TTL timer itself. Stored as
    /// a deleted snapshot so expired content stays viewable in the AyuGram
    /// deleted-messages viewer.
    static func willExpireMessage(transaction: Transaction, id: MessageId, accountPeerId: PeerId, mediaBox: MediaBox) {
        SGLogger.shared.log("AyuGram", "willExpireMessage id=\(id.id)")
        guard SGSimpleSettings.shared.ayuSaveDeletedMessages else { return }
        guard let message = transaction.getMessage(id) else { return }
        let cloudEphemeral = isEligibleCloudEphemeralMedia(message)
        // Do not turn this hook into a second general deletion entry point.
        // It accepts explicit cloud consumable/short-TTL media, or an ordinary
        // timed deletion (which remains subject to the normal save policy).
        guard cloudEphemeral || message.isSelfExpiring else { return }
        guard shouldPreserve(transaction: transaction, message: message, allowCloudEphemeralMedia: cloudEphemeral) else { return }
        if cloudEphemeral && effectiveCopyProtection(transaction: transaction, message: message) { return }
        let preserveMedia = shouldPreserveMedia(transaction: transaction, message: message)
        let immediatePolicy = cloudEphemeral && preserveMedia ? mediaCapturePolicyContext(transaction: transaction, message: message) : nil
        if cloudEphemeral && preserveMedia && immediatePolicy == nil { return }
        var remainingBatchBytes = maxBatchBytes()
        let snapshot = self.snapshot(message, accountId: accountPeerId.toInt64(), mediaBox: mediaBox, preserveMedia: preserveMedia, remainingBatchBytes: &remainingBatchBytes, directMediaOnly: cloudEphemeral, effectiveCopyProtected: effectiveCopyProtection(transaction: transaction, message: message))
        if cloudEphemeral && preserveMedia && snapshot.media.isEmpty {
            registerPendingEphemeralAudioCapture(message: message, snapshot: snapshot, isDirectDialogBot: isDirectDialogBot(transaction: transaction, message: message), mediaPolicy: pendingMediaPolicy(transaction: transaction, message: message), mediaBox: mediaBox)
        }
        guard !snapshot.text.isEmpty || !snapshot.media.isEmpty else { return }
        if cloudEphemeral && !snapshot.media.isEmpty, let policy = immediatePolicy {
            AyuMessageStore.shared.saveDeleted(messages: [snapshot], mediaCapturePolicy: policy)
        } else {
            AyuMessageStore.shared.saveDeleted(messages: [snapshot])
        }
    }

    /// Restores durable capture intents when an account starts. This does not
    /// touch Postbox or Telegram consumption state; it only observes/fetches the
    /// already-authorized cloud resource and copies it after MediaBox reports a
    /// complete file.
    static func resumePendingCaptures(accountPeerId: PeerId, mediaBox: MediaBox) {
        for capture in AyuMessageStore.shared.pendingCaptures(accountId: accountPeerId.toInt64()) {
            guard AyuMessageStore.shared.shouldCommitPendingCapture(capture) else {
                AyuMessageStore.shared.removePendingCapture(capture)
                continue
            }
            guard let file = decodePendingFile(capture.fileMetadata), file.isInstantVideo || file.isVoice else {
                AyuMessageStore.shared.removePendingCapture(capture)
                continue
            }
            monitorPendingCapture(capture, file: file, mediaBox: mediaBox)
        }
    }

    /// Called immediately after cloud updates have been inserted, while the
    /// complete Message and its authorized resource reference are available.
    static func didInsertIncomingMessages(transaction: Transaction, ids: [MessageId], accountPeerId: PeerId, mediaBox: MediaBox) {
        guard SGSimpleSettings.shared.ayuSaveDeletedMessages else { return }
        for id in ids {
            guard let message = transaction.getMessage(id), isEligibleCloudEphemeralMedia(message),
                  shouldPreserve(transaction: transaction, message: message, allowCloudEphemeralMedia: true),
                  !effectiveCopyProtection(transaction: transaction, message: message),
                  shouldPreserveMedia(transaction: transaction, message: message) else { continue }
            guard let immediatePolicy = mediaCapturePolicyContext(transaction: transaction, message: message) else { continue }
            var remainingBatchBytes = maxBatchBytes()
            let snapshot = self.snapshot(
                message, accountId: accountPeerId.toInt64(), mediaBox: mediaBox,
                preserveMedia: true, remainingBatchBytes: &remainingBatchBytes,
                directMediaOnly: true, effectiveCopyProtected: false
            )
            if snapshot.media.isEmpty {
                registerPendingEphemeralAudioCapture(message: message, snapshot: snapshot, isDirectDialogBot: isDirectDialogBot(transaction: transaction, message: message), mediaPolicy: pendingMediaPolicy(transaction: transaction, message: message), mediaBox: mediaBox)
            } else {
                AyuMessageStore.shared.saveDeleted(messages: [snapshot], mediaCapturePolicy: immediatePolicy)
            }
        }
    }

    static func willReplaceMessage(transaction: Transaction, id: MessageId, accountPeerId: PeerId) {
        SGLogger.shared.log("AyuGram", "willReplaceMessage id=\(id.id)")
        guard SGSimpleSettings.shared.ayuSaveEditedMessages else { return }
        guard let message = transaction.getMessage(id), shouldPreserve(transaction: transaction, message: message, allowCloudEphemeralMedia: false) else { return }
        guard !message.text.isEmpty else { return }
        let revision = AyuMessageRevision(
            accountId: accountPeerId.toInt64(),
            peerId: message.id.peerId.toInt64(),
            messageId: message.id.id,
            threadId: message.threadId,
            text: message.text,
            editDate: message.editedTime ?? message.timestamp
        )
        AyuMessageStore.shared.saveRevisions([revision])
    }

    /// Local (user-initiated) interactive deletion.
    ///
    /// MARK: AyuGram - the user deleted these messages on purpose, so any
    /// archived copy is dropped (AyuGram Android does the same through
    /// `AyuMessagesController.delete(...)`). Keeping them would resurrect the
    /// user's own deletions as ghost messages.
    ///
    /// The one exception is an explicit "keep locally" request, which is what
    /// the checkbox in the delete confirmation sheet sets.
    static func didDeleteMessagesLocally(transaction: Transaction, accountPeerId: PeerId, ids: [MessageId], postbox: Postbox) {
        guard !ids.isEmpty else { return }
        let accountId = accountPeerId.toInt64()
        var allIdsByPeer: [PeerId: [Int32]] = [:]
        for id in ids {
            allIdsByPeer[id.peerId, default: []].append(id.id)
        }
        for (peerId, messageIds) in allIdsByPeer {
            AyuMessageStore.shared.cancelPendingCaptures(accountId: accountId, peerId: peerId.toInt64(), messageIds: messageIds)
        }
        let preservedIds = AyuDeleteIntent.consumeKeepLocally(accountPeerId: accountPeerId, ids: ids)
        if !preservedIds.isEmpty {
            SGLogger.shared.log("AyuGram", "didDeleteMessagesLocally: keeping \(preservedIds.count) archived message(s)")
            willDeleteMessages(transaction: transaction, ids: Array(preservedIds), accountPeerId: accountPeerId, postbox: postbox)
        }
        var byPeer: [PeerId: [Int32]] = [:]
        for id in ids where !preservedIds.contains(id) {
            byPeer[id.peerId, default: []].append(id.id)
        }
        for (peerId, messageIds) in byPeer {
            AyuMessageStore.shared.removeDeleted(
                accountId: accountId,
                peerId: peerId.toInt64(),
                messageIds: messageIds
            )
        }
    }

    private static func snapshot(_ message: Message, accountId: Int64, mediaBox: MediaBox, preserveMedia: Bool, remainingBatchBytes: inout Int64, directMediaOnly: Bool = false, effectiveCopyProtected: Bool) -> AyuSavedMessage {
        let textEntities = message.attributes.first(where: { $0 is TextEntitiesMessageAttribute })
        return AyuSavedMessage(
            accountId: accountId,
            peerId: message.id.peerId.toInt64(),
            messageId: message.id.id,
            threadId: message.threadId,
            globallyUniqueId: message.globallyUniqueId,
            authorId: message.author?.id.toInt64(),
            date: message.timestamp,
            editDate: message.editedTime,
            text: message.text,
            media: preserveMedia ? captureMedia(message: message, accountId: accountId, mediaBox: mediaBox, remainingBatchBytes: &remainingBatchBytes, directMediaOnly: directMediaOnly) : [],
            flags: sanitizedFlags(message.flags).rawValue,
            effectiveCopyProtected: effectiveCopyProtected,
            textEntitiesAttribute: textEntities.flatMap(encodePostboxObject),
            authorPeer: message.author.flatMap(encodePostboxObject),
            associatedMedia: preserveMedia ? captureAssociatedMedia(message: message, accountId: accountId, mediaBox: mediaBox, remainingBatchBytes: &remainingBatchBytes) : []
        )
    }

    private static func effectiveCopyProtection(transaction: Transaction, message: Message) -> Bool {
        if message.flags.contains(.CopyProtected) {
            return true
        }
        if let group = transaction.getPeer(message.id.peerId) as? TelegramGroup {
            return group.flags.contains(.copyProtectionEnabled)
        }
        if let channel = transaction.getPeer(message.id.peerId) as? TelegramChannel {
            return channel.flags.contains(.copyProtectionEnabled)
        }
        if message.id.peerId.namespace == Namespaces.Peer.CloudUser,
           let data = transaction.getPeerCachedData(peerId: message.id.peerId) as? CachedUserData {
            return data.flags.contains(.copyProtectionEnabled) || data.flags.contains(.myCopyProtectionEnabled)
        }
        return false
    }

    private static func sanitizedFlags(_ flags: MessageFlags) -> MessageFlags {
        return MessageFlags(rawValue: flags.rawValue & (MessageFlags.Incoming.rawValue | MessageFlags.CountedAsIncoming.rawValue | MessageFlags.CopyProtected.rawValue | MessageFlags.IsForumTopic.rawValue))
    }

    private static func encodePostboxObject(_ value: PostboxCoding) -> Data? {
        let encoder = PostboxEncoder()
        encoder.encodeRootObject(value)
        let data = encoder.makeData()
        return data.count <= 2 * 1024 * 1024 ? data : nil
    }

    private static func decodePendingFile(_ data: Data) -> TelegramMediaFile? {
        guard data.count <= 2 * 1024 * 1024 else { return nil }
        return PostboxDecoder(buffer: MemoryBuffer(data: data)).decodeRootObject() as? TelegramMediaFile
    }

    private static func isDirectDialogBot(transaction: Transaction, message: Message) -> Bool? {
        guard message.id.peerId.namespace == Namespaces.Peer.CloudUser else { return false }
        guard let user = transaction.getPeer(message.id.peerId) as? TelegramUser else { return nil }
        return user.botInfo != nil
    }

    private static func pendingMediaPolicy(transaction: Transaction, message: Message) -> AyuPendingMediaCapture.MediaPolicy? {
        guard let peer = transaction.getPeer(message.id.peerId) else { return nil }
        let isPublic = peer.addressName?.isEmpty == false
        if peer is TelegramUser {
            return .privateChat
        } else if let channel = peer as? TelegramChannel {
            switch channel.info {
            case .broadcast:
                return isPublic ? .publicChannel : .privateChannel
            case .group:
                return isPublic ? .publicGroup : .privateGroup
            }
        } else if peer is TelegramGroup {
            return isPublic ? .publicGroup : .privateGroup
        }
        return nil
    }

    private static func mediaCapturePolicyContext(transaction: Transaction, message: Message) -> AyuMediaCapturePolicyContext? {
        guard let isDirectDialogBot = isDirectDialogBot(transaction: transaction, message: message),
              let mediaPolicy = pendingMediaPolicy(transaction: transaction, message: message) else { return nil }
        return AyuMediaCapturePolicyContext(
            isDirectDialogBot: isDirectDialogBot,
            isIncoming: message.flags.contains(.Incoming),
            mediaPolicy: mediaPolicy
        )
    }

    private static func registerPendingEphemeralAudioCapture(message: Message, snapshot: AyuSavedMessage, isDirectDialogBot: Bool?, mediaPolicy: AyuPendingMediaCapture.MediaPolicy?, mediaBox: MediaBox) {
        guard message.id.peerId.namespace != Namespaces.Peer.SecretChat,
              let isDirectDialogBot,
              let mediaPolicy,
              let (index, file) = message.media.enumerated().first(where: {
                  guard let file = $0.element as? TelegramMediaFile else { return false }
                  return file.isInstantVideo || file.isVoice
              }),
              let file = file as? TelegramMediaFile,
              let metadata = encodePostboxObject(file) else { return }
        let limit = maxAttachmentBytes()
        if let size = file.size, (size <= 0 || size > limit) { return }
        let pending = AyuPendingMediaCapture(message: snapshot, mediaIndex: index, fileMetadata: metadata, expectedSize: file.size, isDirectDialogBot: isDirectDialogBot, isIncoming: message.flags.contains(.Incoming), mediaPolicy: mediaPolicy)
        guard let registered = AyuMessageStore.shared.registerPendingCapture(pending) else { return }
        monitorPendingCapture(registered, file: file, mediaBox: mediaBox)
    }

    private static func monitorPendingCapture(_ capture: AyuPendingMediaCapture, file: TelegramMediaFile, mediaBox: MediaBox) {
        let generation = capture.generationId?.uuidString ?? "legacy"
        let identity = "\(capture.message.accountId):\(capture.message.peerId):\(capture.message.messageId):\(capture.mediaIndex):"
        let key = identity + generation
        pendingLock.lock()
        if pendingDisposables[key] != nil {
            pendingLock.unlock()
            return
        }
        let supersededKeys = pendingDisposables.keys.filter { $0.hasPrefix(identity) }
        let supersededDisposables = supersededKeys.compactMap { pendingDisposables.removeValue(forKey: $0) }
        let disposables = DisposableSet()
        pendingDisposables[key] = disposables
        pendingLock.unlock()
        for disposable in supersededDisposables {
            disposable.dispose()
        }

        // A standalone reference is sufficient for cloud document resources
        // carrying their file reference. Failure is harmless: resourceData
        // remains subscribed and can finish if another MediaBox client fetches.
        disposables.add(fetchedMediaResource(
            mediaBox: mediaBox,
            userLocation: .peer(PeerId(capture.message.peerId)),
            userContentType: MediaResourceUserContentType(file: file),
            reference: .standalone(resource: file.resource),
            continueInBackground: true
        ).start())
        disposables.add((mediaBox.resourceData(file.resource, option: .complete(waitUntilFetchStatus: false))
        |> filter { $0.complete }
        |> take(1)).start(next: { data in
            finalizePendingCapture(capture, file: file, completePath: data.path)
            pendingLock.lock()
            let disposable = pendingDisposables.removeValue(forKey: key)
            pendingLock.unlock()
            disposable?.dispose()
        }))
    }

    private static func finalizePendingCapture(_ capture: AyuPendingMediaCapture, file: TelegramMediaFile, completePath: String) {
        guard AyuMessageStore.shared.shouldCommitPendingCapture(capture) else {
            AyuMessageStore.shared.removePendingCapture(capture)
            return
        }
        guard AyuMessageStore.shared.isCurrentPendingCapture(capture) else { return }
        let limit = maxAttachmentBytes()
        guard let copied = copyAttachment(
            sourcePath: completePath,
            accountId: capture.message.accountId,
            peerId: capture.message.peerId,
            messageId: capture.message.messageId,
            index: capture.mediaIndex,
            pathExtension: file.fileName.flatMap { name in
                let ext = (name as NSString).pathExtension
                return ext.isEmpty ? nil : ext
            } ?? extensionForMimeType(file.mimeType),
            maxAttachmentBytes: limit
        ) else { return }
        guard capture.expectedSize == nil || capture.expectedSize == copied.0 else {
            AyuStorage.removeAttachment(relativePath: copied.1)
            return
        }
        let savedMedia = AyuSavedMedia(kind: file.isVoice ? .voice : .video, fileName: file.fileName, mimeType: file.mimeType, size: copied.0, width: nil, height: nil, relativePath: copied.1, nativeMetadata: capture.fileMetadata)
        let base = capture.message
        let completed = AyuSavedMessage(accountId: base.accountId, peerId: base.peerId, messageId: base.messageId, threadId: base.threadId, globallyUniqueId: base.globallyUniqueId, authorId: base.authorId, date: base.date, editDate: base.editDate, text: base.text, media: [savedMedia], flags: base.flags, effectiveCopyProtected: base.effectiveCopyProtected, textEntitiesAttribute: base.textEntitiesAttribute, authorPeer: base.authorPeer, associatedMedia: base.associatedMedia, savedAt: base.savedAt)
        AyuMessageStore.shared.saveDeleted(messages: [completed], requiringPendingCapture: capture) { success in
            if success {
                AyuMessageStore.shared.removePendingCapture(capture)
            } else {
                AyuStorage.removeAttachment(relativePath: copied.1)
            }
        }
    }

    private static func shouldPreserve(transaction: Transaction, message: Message, allowCloudEphemeralMedia: Bool, allowOutgoingMessages: Bool = false) -> Bool {
        // Secret chats are never preserved, regardless of any other condition.
        guard message.id.peerId.namespace != Namespaces.Peer.SecretChat else { return false }
        guard message.id.peerId.namespace == Namespaces.Peer.CloudUser
            || message.id.peerId.namespace == Namespaces.Peer.CloudGroup
            || message.id.peerId.namespace == Namespaces.Peer.CloudChannel else { return false }
        // Only real server messages are snapshot candidates. Synthetic/local
        // ids must never cross into either persistence or Telegram operations.
        guard message.id.namespace == Namespaces.Message.Cloud, message.id.id > 0 else { return false }
        // Deletion hooks also preserve outgoing messages: in groups and
        // channels another participant or administrator can remotely delete a
        // message sent by the current account. Ephemeral and edit hooks keep
        // the default incoming-only boundary.
        guard allowOutgoingMessages || message.flags.contains(.Incoming) else { return false }
        // This preference governs direct bot dialogs. Bot-authored messages in
        // groups and channels remain governed by their containing peer.
        if !SGSimpleSettings.shared.ayuSaveForBots,
           message.id.peerId.namespace == Namespaces.Peer.CloudUser {
            guard let user = transaction.getPeer(message.id.peerId) as? TelegramUser,
                  user.botInfo == nil else { return false }
        }
        // Outside the explicit pre-expiry path, retain the existing exclusion.
        // In that path, `containsSecretMedia` also describes ordinary cloud
        // view-once and short-TTL media, which is eligible for local capture.
        guard allowCloudEphemeralMedia || !message.containsSecretMedia else { return false }
        return !message.media.contains(where: { $0 is TelegramMediaAction })
    }

    private static func isEligibleCloudEphemeralMedia(_ message: Message) -> Bool {
        guard message.flags.contains(.Incoming), message.id.id > 0,
              message.id.namespace == Namespaces.Message.Cloud,
              message.id.peerId.namespace != Namespaces.Peer.SecretChat,
              !message.media.contains(where: { $0 is TelegramMediaAction }) else { return false }
        let hasExplicitExpiry = message.minAutoremoveOrClearTimeout.map {
            $0 == viewOnceTimeout || ($0 > 0 && $0 <= 60)
        } ?? false
        // Ordinary voice and round-video messages also carry an unconsumed
        // marker. It is playback state, not evidence that media is view-once.
        guard hasExplicitExpiry else { return false }
        // Deliberately inspect direct media rather than effectiveMedia: paid,
        // invoice and webpage wrappers are outside this capture contract.
        return message.media.contains { media in
            guard let file = media as? TelegramMediaFile else { return false }
            return file.isVoice || file.isInstantVideo
        }
    }

    private static func shouldPreserveMedia(transaction: Transaction, message: Message) -> Bool {
        guard let peer = transaction.getPeer(message.id.peerId) else { return false }
        let isPublic = peer.addressName?.isEmpty == false
        if peer is TelegramUser {
            return SGSimpleSettings.shared.ayuShouldSaveMedia(isPrivateChat: true, isChannel: false, isGroup: false, isPublic: false)
        } else if let channel = peer as? TelegramChannel {
            switch channel.info {
            case .broadcast:
                return SGSimpleSettings.shared.ayuShouldSaveMedia(isPrivateChat: false, isChannel: true, isGroup: false, isPublic: isPublic)
            case .group:
                return SGSimpleSettings.shared.ayuShouldSaveMedia(isPrivateChat: false, isChannel: false, isGroup: true, isPublic: isPublic)
            }
        } else if peer is TelegramGroup {
            return SGSimpleSettings.shared.ayuShouldSaveMedia(isPrivateChat: false, isChannel: false, isGroup: true, isPublic: isPublic)
        }
        return false
    }

    // MARK: Media capture

    /// Copies fully-cached media resources out of MediaBox before the message
    /// (and possibly its cached files) is removed. Media from secret chats and
    /// secret-chat media is never captured. Cloud view-once/short-TTL media is
    /// accepted only because callers first pass the explicit pre-expiry
    /// eligibility check. Only complete local files are eligible; partial or
    /// remote-only resources are skipped.
    private static func captureMedia(message: Message, accountId: Int64, mediaBox: MediaBox, remainingBatchBytes: inout Int64, directMediaOnly: Bool) -> [AyuSavedMedia] {
        guard message.id.peerId.namespace != Namespaces.Peer.SecretChat else {
            return []
        }
        guard remainingBatchBytes > 0 else {
            return []
        }
        let peerId = message.id.peerId.toInt64()
        var result: [AyuSavedMedia] = []
        let mediaItems = directMediaOnly ? message.media : message.effectiveMedia
        for (index, media) in mediaItems.enumerated() {
            if let image = media as? TelegramMediaImage {
                if directMediaOnly { continue }
                guard let representation = largestImageRepresentation(image.representations) else { continue }
                guard let sourcePath = mediaBox.completedResourcePath(representation.resource) else { continue }
                guard let (size, relativePath) = copyAttachment(
                    sourcePath: sourcePath,
                    accountId: accountId,
                    peerId: peerId,
                    messageId: message.id.id,
                    index: index,
                    pathExtension: "jpg",
                    maxAttachmentBytes: min(maxAttachmentBytes(), remainingBatchBytes)
                ) else { continue }
                remainingBatchBytes -= size
                result.append(AyuSavedMedia(
                    kind: .photo,
                    fileName: nil,
                    mimeType: "image/jpeg",
                    size: size,
                    width: representation.dimensions.width,
                    height: representation.dimensions.height,
                    relativePath: relativePath,
                    nativeMetadata: encodePostboxObject(image)
                ))
            } else if let file = media as? TelegramMediaFile {
                if directMediaOnly && !file.isVoice && !file.isInstantVideo { continue }
                guard let sourcePath = mediaBox.completedResourcePath(file.resource) else { continue }
                let kind: AyuSavedMedia.Kind
                if file.isVideo {
                    kind = .video
                } else if file.isVoice {
                    kind = .voice
                } else {
                    kind = .file
                }
                let pathExtension = file.fileName.flatMap({ name -> String? in
                    let ext = (name as NSString).pathExtension
                    return ext.isEmpty ? nil : ext
                }) ?? extensionForMimeType(file.mimeType)
        guard let (size, relativePath) = copyAttachment(
            sourcePath: sourcePath,
            accountId: accountId,
            peerId: peerId,
            messageId: message.id.id,
            index: index,
            pathExtension: pathExtension,
            maxAttachmentBytes: min(maxAttachmentBytes(), remainingBatchBytes)
        ) else { continue }
                remainingBatchBytes -= size
                result.append(AyuSavedMedia(
                    kind: kind,
                    fileName: file.fileName,
                    mimeType: file.mimeType,
                    size: size,
                    width: nil,
                    height: nil,
                    relativePath: relativePath,
                    nativeMetadata: encodePostboxObject(file)
                ))
            }
        }
        return result
    }

    private static func captureAssociatedMedia(message: Message, accountId: Int64, mediaBox: MediaBox, remainingBatchBytes: inout Int64) -> [AyuSavedAssociatedMedia] {
        guard let attribute = message.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute else { return [] }
        var ids = Set<MediaId>()
        for entity in attribute.entities {
            if case let .CustomEmoji(_, fileId) = entity.type {
                ids.insert(MediaId(namespace: Namespaces.Media.CloudFile, id: fileId))
            }
        }
        var result: [AyuSavedAssociatedMedia] = []
        for id in ids.prefix(64) {
            guard let file = message.associatedMedia[id] as? TelegramMediaFile,
                  let metadata = encodePostboxObject(file) else { continue }
            var relativePath: String?
            if remainingBatchBytes > 0, let sourcePath = mediaBox.completedResourcePath(file.resource), let copied = copyAttachment(
                sourcePath: sourcePath,
                accountId: accountId,
                peerId: message.id.peerId.toInt64(),
                messageId: message.id.id,
                index: 1000 + result.count,
                pathExtension: extensionForMimeType(file.mimeType),
                maxAttachmentBytes: min(maxAttachmentBytes(), remainingBatchBytes)
            ) {
                remainingBatchBytes -= copied.0
                relativePath = copied.1
            }
            result.append(AyuSavedAssociatedMedia(namespace: id.namespace, id: id.id, nativeMetadata: metadata, relativePath: relativePath))
        }
        return result
    }

    private static func copyAttachment(sourcePath: String, accountId: Int64, peerId: Int64, messageId: Int32, index: Int, pathExtension: String?, maxAttachmentBytes: Int64) -> (Int64, String)? {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: sourcePath),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size > 0, size <= maxAttachmentBytes else {
            return nil
        }
        // A snapshot is copied synchronously but merged into the store on its
        // serial queue. Use a unique staging name so a second observer cannot
        // overwrite the first snapshot's bytes before the quality merge has
        // decided which capture to retain.
        var fileName = "\(messageId)_\(index)_\(UUID().uuidString.lowercased())"
        if let pathExtension = pathExtension {
            fileName += ".\(pathExtension)"
        }
        let (destinationURL, relativePath) = AyuStorage.attachmentDestinationURL(accountId: accountId, peerId: peerId, fileName: fileName)
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(atPath: sourcePath, toPath: destinationURL.path)
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destinationURL.path)
            return (size, relativePath)
        } catch {
            return nil
        }
    }

    private static func extensionForMimeType(_ mimeType: String) -> String? {
        switch mimeType {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "video/mp4": return "mp4"
        case "audio/mpeg": return "mp3"
        case "audio/mp4", "audio/m4a": return "m4a"
        case "audio/ogg": return "ogg"
        case "application/pdf": return "pdf"
        default: return nil
        }
    }
}
