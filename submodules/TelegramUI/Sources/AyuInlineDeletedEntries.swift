import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit
import Display
import AccountContext
import TelegramPresentationData
import ChatHistoryEntry
import ChatMessageItemCommon
import SGSimpleSettings
import SGStrings
import AyuGram

// MARK: AyuGram - inline deleted messages (kept in place after deletion)

/// Namespace for building synthetic in-memory `Message` entries for messages
/// that were deleted but preserved by `AyuMessageStore`, so they stay visible
/// in place in the chat history (AyuGram-Android style).
enum AyuInlineDeletedEntries {
    /// Synthetic ids are currently derived from the original id. Their sign
    /// is deliberately not a type discriminator: Telegram can expose other
    /// negative Cloud ids to UI callbacks.
    static func syntheticMessageId(originalId: Int32) -> Int32 {
        return AyuSyntheticMessageIdentity.syntheticMessageId(originalId: originalId)
    }

    /// Reserved synthetic stable-id range: [UInt32.max - 6000 - 500_000, UInt32.max - 6000).
    /// Other local synthetic messages (UInt32.max - 1000/1001/1002, max - 5000)
    /// sit above it and never collide.
    static let syntheticStableIdRange: Range<UInt32> = (UInt32.max - 6000 - 500_000) ..< (UInt32.max - 6000)

    /// Synthetic stable ids are a splitmix-style mix of the full 64-bit
    /// magnitude of the original id, folded into the reserved high range.
    /// This is deterministic and collision-resistant for realistic id spaces
    /// (the previous `% 500_000` scheme collided for ids 500k apart).
    ///
    /// NOTE: the mapping is not reversible, so id/stableId-based checks are
    /// necessarily approximate (they only confirm membership in the synthetic
    /// range). The authoritative check is the `AyuSyntheticMessageAttribute`
    /// marker where the `Message` itself is available.
    static func syntheticStableId(originalId: Int32) -> UInt32 {
        // Reject id 0: it cannot be mapped (mixing would fold it into a fixed
        // slot) and it is never a valid original message id for capture.
        precondition(originalId != 0, "syntheticStableId requires a non-zero originalId")
        var z = UInt64(originalId.magnitude) &+ 0x9e3779b97f4a7c15
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        z ^= z >> 31
        return (UInt32.max - 6000 - 500_000) + UInt32(z % 500_000)
    }

    static func isSynthetic(_ message: EngineRawMessage) -> Bool {
        return message.isAyuSyntheticDeletedMessage
    }

    static func isSyntheticId(_ id: MessageId) -> Bool {
        // There is no sound ID-only predicate for the current mapping: its
        // output overlaps Telegram's negative Cloud-id space. Callers with a
        // Message must use isSynthetic(_:) instead. Returning false here is
        // preferable to suppressing interaction for an unrelated message.
        return false
    }

    /// Builds synthetic chat entries for preserved-but-deleted messages of the
    /// given peer, limited to the timestamp window currently loaded in the
    /// history view (so pagination/scroll positioning works naturally).
    ///
    /// Returns the entries sorted by index, ready to be merged into the
    /// filtered entry list.
    static func entriesForWindow(
        context: AccountContext,
        peerId: PeerId,
        accountId: Int64,
        presentationData: ChatPresentationData,
        lowerBound: MessageIndex?,
        upperBound: MessageIndex?,
        existingMessageIds: Set<MessageId>,
        existingStableIds: Set<UInt32>,
        threadId: Int64?,
        emptyNewestPageLimit: Int?
    ) -> [ChatHistoryEntry] {
        // MARK: AyuGram - master gate: preservation off or inline display off
        guard SGSimpleSettings.shared.ayuSaveDeletedMessages,
              SGSimpleSettings.shared.ayuShowDeletedInline else {
            return []
        }

        var saved = AyuMessageStore.shared.deletedMessages(peerId: peerId.toInt64(), accountId: accountId)
            .filter { savedMessage in
                if peerId.namespace == Namespaces.Peer.CloudChannel && threadId == nil {
                    return savedMessage.threadId == nil || savedMessage.threadId == 1
                }
                return savedMessage.threadId == threadId
            }
        if let emptyNewestPageLimit {
            guard lowerBound == nil && upperBound == nil && emptyNewestPageLimit > 0 else { return [] }
            saved = Array(saved.suffix(emptyNewestPageLimit))
        }

        var result: [ChatHistoryEntry] = []
        var usedStableIds = existingStableIds
        for savedMessage in saved {
            let originalId = savedMessage.messageId
            // Reject id 0: it cannot be mapped to a synthetic stable id and is
            // never a valid captured original message id.
            guard originalId != 0 else {
                continue
            }
            let index = MessageIndex(
                id: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: syntheticMessageId(originalId: originalId)),
                timestamp: savedMessage.date
            )
            guard !existingMessageIds.contains(index.id) else {
                continue
            }
            // Window membership is decided by the ORIGINAL index: synthetic
            // ids are negative, so comparing them against bounds derived from
            // real messages would always exclude them at the edges.
            let originalIndex = MessageIndex(
                id: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: originalId),
                timestamp: savedMessage.date
            )

            // Only inject into the currently loaded window. A nil bound means
            // the history view has an open edge at that side (or is empty),
            // so entries beyond it are allowed rather than dropped — this
            // keeps a newly deleted newest/oldest message visible.
            if let lowerBound = lowerBound, originalIndex < lowerBound {
                continue
            }
            if let upperBound = upperBound, originalIndex > upperBound {
                continue
            }

            var stableId = syntheticStableId(originalId: originalId)
            var collisionAttempts = 0
            while usedStableIds.contains(stableId) && collisionAttempts < syntheticStableIdRange.count {
                collisionAttempts += 1
                stableId += 1
                if stableId >= syntheticStableIdRange.upperBound {
                    stableId = syntheticStableIdRange.lowerBound
                }
            }
            guard !usedStableIds.contains(stableId) else {
                continue
            }
            usedStableIds.insert(stableId)
            let message = makeMessage(
                peerId: peerId,
                savedMessage: savedMessage,
                index: index,
                stableId: stableId,
                mediaBox: context.account.postbox.mediaBox,
                presentationData: presentationData
            )

            let attributes = ChatMessageEntryAttributes(
                rank: nil,
                isContact: false,
                contentTypeHint: .generic,
                updatingMedia: nil,
                isPlaying: false,
                isCentered: false,
                authorStoryStats: nil,
                displayContinueThreadFooter: false,
                pinToTop: false
            )

            result.append(.MessageEntry(message, presentationData, true, nil, .none, attributes))
        }

        result.sort(by: { $0 < $1 })
        return result
    }

    /// Constructs an in-memory `Message` for a preserved deleted message.
    /// Rendered as an incoming-neutral text bubble; attachments are listed as
    /// a textual description (Phase 1 — local file re-rendering is Phase 2).
    private static func makeMessage(
        peerId: PeerId,
        savedMessage: AyuSavedMessage,
        index: MessageIndex,
        stableId: UInt32,
        mediaBox: MediaBox,
        presentationData: ChatPresentationData
    ) -> Message {
        var attributes: [MessageAttribute] = [AyuSyntheticMessageAttribute(accountId: savedMessage.accountId, peerId: savedMessage.peerId, threadId: savedMessage.threadId, originalMessageId: savedMessage.messageId)]
        if let data = savedMessage.textEntitiesAttribute,
           data.count <= 2 * 1024 * 1024,
           let attribute = PostboxDecoder(buffer: MemoryBuffer(data: data)).decodeRootObject() as? TextEntitiesMessageAttribute {
            attributes.insert(attribute, at: 0)
        }
        var nativeMedia: [Media] = []
        var fallbackMedia: [AyuSavedMedia] = []
        for (i, savedMedia) in savedMessage.media.prefix(32).enumerated() {
            guard let data = savedMedia.nativeMetadata, data.count <= 2 * 1024 * 1024,
                   let url = AyuStorage.regularAttachmentFileURL(relativePath: savedMedia.relativePath, accountId: savedMessage.accountId, peerId: savedMessage.peerId),
                  let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])),
                  fileSize.isRegularFile == true, fileSize.isSymbolicLink != true,
                    let byteCount = fileSize.fileSize, byteCount > 0,
                   savedMedia.size == nil || Int64(byteCount) == savedMedia.size else {
                fallbackMedia.append(savedMedia)
                continue
            }
            let resource = LocalFileMediaResource(fileId: localResourceId(accountId: savedMessage.accountId, peerId: savedMessage.peerId, messageId: savedMessage.messageId, role: i), size: Int64(byteCount), isSecretRelated: false)
            guard mediaBox.materializeResourceByLinkSynchronously(resource.id, fromCompletePath: url.path, expectedSize: Int64(byteCount)),
                  mediaBox.completedResourcePath(resource) != nil else {
                fallbackMedia.append(savedMedia)
                continue
            }
            if let image = PostboxDecoder(buffer: MemoryBuffer(data: data)).decodeRootObject() as? TelegramMediaImage,
               let representation = image.representations.max(by: { Int64($0.dimensions.width) * Int64($0.dimensions.height) < Int64($1.dimensions.width) * Int64($1.dimensions.height) }) {
                nativeMedia.append(TelegramMediaImage(imageId: image.imageId, representations: [TelegramMediaImageRepresentation(dimensions: representation.dimensions, resource: resource, progressiveSizes: [], immediateThumbnailData: representation.immediateThumbnailData)], immediateThumbnailData: image.immediateThumbnailData, reference: nil, partialReference: nil, flags: []))
            } else if let file = PostboxDecoder(buffer: MemoryBuffer(data: data)).decodeRootObject() as? TelegramMediaFile {
                nativeMedia.append(TelegramMediaFile(fileId: file.fileId, partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: file.immediateThumbnailData, mimeType: file.mimeType, size: Int64(byteCount), attributes: safeFileAttributes(file.attributes), alternativeRepresentations: []))
            } else {
                fallbackMedia.append(savedMedia)
            }
        }
        var text = savedMessage.text
        for media in fallbackMedia {
            let description: String
            switch media.kind {
            case .photo: description = "AyuGram.Media.Photo".i18n(presentationData.strings.baseLanguageCode)
            case .video: description = "AyuGram.Media.Video".i18n(presentationData.strings.baseLanguageCode)
            case .voice: description = "AyuGram.Media.Voice".i18n(presentationData.strings.baseLanguageCode)
            case .file: description = media.fileName ?? "AyuGram.Media.File".i18n(presentationData.strings.baseLanguageCode)
            }
            if !text.isEmpty { text.append("\n") }
            text.append(description)
            if let size = media.size { text.append(", " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        }
        var associatedMedia: [MediaId: Media] = [:]
        for (i, saved) in savedMessage.associatedMedia.prefix(64).enumerated() {
            guard saved.nativeMetadata.count <= 2 * 1024 * 1024,
                  let file = PostboxDecoder(buffer: MemoryBuffer(data: saved.nativeMetadata)).decodeRootObject() as? TelegramMediaFile else { continue }
            guard let path = saved.relativePath,
                let url = AyuStorage.regularAttachmentFileURL(relativePath: path, accountId: savedMessage.accountId, peerId: savedMessage.peerId),
               let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
               values.isRegularFile == true, values.isSymbolicLink != true,
               let count = values.fileSize, count > 0,
               file.size == nil || file.size == Int64(count) else { continue }
            let local = LocalFileMediaResource(fileId: localResourceId(accountId: savedMessage.accountId, peerId: savedMessage.peerId, messageId: savedMessage.messageId, role: 1000 + i), size: Int64(count), isSecretRelated: false)
            guard mediaBox.materializeResourceByLinkSynchronously(local.id, fromCompletePath: url.path, expectedSize: Int64(count)),
                  mediaBox.completedResourcePath(local) != nil else { continue }
            let resource: TelegramMediaResource = local
            associatedMedia[MediaId(namespace: saved.namespace, id: saved.id)] = TelegramMediaFile(fileId: file.fileId, partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: file.immediateThumbnailData, mimeType: file.mimeType, size: file.size, attributes: safeFileAttributes(file.attributes), alternativeRepresentations: [])
        }
        let author: Peer? = savedMessage.authorPeer.flatMap { data in
            guard data.count <= 2 * 1024 * 1024 else { return nil }
            return PostboxDecoder(buffer: MemoryBuffer(data: data)).decodeRootObject() as? Peer
        }
        var peers = SimpleDictionary<PeerId, Peer>()
        if let author = author { peers[author.id] = author }
        let legacyOutgoing = savedMessage.flags == nil && savedMessage.authorId == savedMessage.accountId
        var safeFlagsRaw = savedMessage.flags ?? (legacyOutgoing ? 0 : MessageFlags.Incoming.rawValue)
        if savedMessage.effectiveCopyProtected == true {
            safeFlagsRaw |= MessageFlags.CopyProtected.rawValue
        }
        let flags = MessageFlags(rawValue: safeFlagsRaw & (MessageFlags.Incoming.rawValue | MessageFlags.CountedAsIncoming.rawValue | MessageFlags.CopyProtected.rawValue | MessageFlags.IsForumTopic.rawValue))

        return Message(
            stableId: stableId,
            stableVersion: 0,
            id: index.id,
            globallyUniqueId: savedMessage.globallyUniqueId,
            groupingKey: nil,
            groupInfo: nil,
            threadId: savedMessage.threadId,
            timestamp: savedMessage.date,
            flags: flags,
            tags: [],
            globalTags: [],
            localTags: [],
            customTags: [],
            forwardInfo: nil,
            author: author,
            text: text,
            attributes: attributes,
            media: nativeMedia,
            peers: peers,
            associatedMessages: SimpleDictionary<MessageId, Message>(),
            associatedMessageIds: [],
            associatedMedia: associatedMedia,
            associatedThreadInfo: nil,
            associatedStories: [:]
        )
    }

    private static func localResourceId(accountId: Int64, peerId: Int64, messageId: Int32, role: Int) -> Int64 {
        // Stable FNV-1a over the complete ownership tuple. Unlike Swift.Hashable,
        // this remains stable across launches while separating accounts/peers.
        var hash: UInt64 = 1469598103934665603
        for value in [UInt64(bitPattern: accountId), UInt64(bitPattern: peerId), UInt64(UInt32(bitPattern: messageId)), UInt64(role)] {
            var value = value
            for _ in 0 ..< 8 {
                hash ^= value & 0xff
                hash &*= 1099511628211
                value >>= 8
            }
        }
        return Int64(bitPattern: hash)
    }

    private static func safeFileAttributes(_ attributes: [TelegramMediaFileAttribute]) -> [TelegramMediaFileAttribute] {
        // File attributes describe rendering only. Pending/TTL/reaction state is
        // represented by message attributes and is never decoded above.
        return Array(attributes.prefix(32))
    }

    /// Merge synthetic entries into an already-built filtered entry array,
    /// keeping the result sorted by entry index (timestamp, namespace, id).
    static func mergeIntoEntries(_ entries: [ChatHistoryEntry], synthetic: [ChatHistoryEntry]) -> [ChatHistoryEntry] {
        guard !synthetic.isEmpty else {
            return entries
        }
        var result = entries
        for entry in synthetic {
            guard case let .MessageEntry(syntheticMessage, _, _, _, _, _) = entry,
                  let marker = syntheticMessage.ayuSyntheticDeletedMessageAttribute else { continue }
            let originalId = MessageId(peerId: syntheticMessage.id.peerId, namespace: Namespaces.Message.Cloud, id: marker.originalMessageId)
            var hasLiveOriginal = false
            var filteredResult: [ChatHistoryEntry] = []
            filteredResult.reserveCapacity(result.count)
            for existing in result {
                switch existing {
                case let .MessageEntry(message, _, _, _, _, _) where message.id == originalId:
                    let isExpiredPlaceholder = !message.media.isEmpty && message.media.allSatisfy { $0 is TelegramMediaExpiredContent }
                    if isExpiredPlaceholder {
                        continue
                    }
                    hasLiveOriginal = true
                    filteredResult.append(existing)
                case let .MessageGroupEntry(groupInfo, messages, presentationData):
                    var retainedMessages = messages
                    retainedMessages.removeAll { member in
                        guard member.0.id == originalId else { return false }
                        let isExpiredPlaceholder = !member.0.media.isEmpty && member.0.media.allSatisfy { $0 is TelegramMediaExpiredContent }
                        if !isExpiredPlaceholder {
                            hasLiveOriginal = true
                        }
                        return isExpiredPlaceholder
                    }
                    if !retainedMessages.isEmpty {
                        filteredResult.append(.MessageGroupEntry(groupInfo, retainedMessages, presentationData))
                    }
                default:
                    filteredResult.append(existing)
                }
            }
            result = filteredResult
            // A pre-expiry snapshot must not duplicate a still-live message;
            // an expired-content placeholder, however, is replaced by it.
            if hasLiveOriginal { continue }
            var inserted = false
            for i in 0 ..< result.count {
                if entry < result[i] {
                    result.insert(entry, at: i)
                    inserted = true
                    break
                }
            }
            if !inserted {
                result.append(entry)
            }
        }
        return result
    }
}
