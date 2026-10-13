import Foundation

/// Metadata for a media attachment preserved alongside a deleted message.
/// The bytes live in a file under `AyuStorage.attachmentsURL`; only the
/// relative path is stored here.
public struct AyuSavedMedia: Codable, Equatable {
    public enum Kind: String, Codable {
        case photo
        case video
        case file
        case voice
    }

    public let kind: Kind
    public let fileName: String?
    public let mimeType: String?
    public let size: Int64?
    public let width: Int32?
    public let height: Int32?
    public let relativePath: String
    /// Postbox-encoded TelegramMediaImage / TelegramMediaFile metadata. The
    /// resource itself is deliberately replaced with an Ayu-owned local copy
    /// during reconstruction.
    public let nativeMetadata: Data?

    public init(
        kind: Kind,
        fileName: String?,
        mimeType: String?,
        size: Int64?,
        width: Int32?,
        height: Int32?,
        relativePath: String,
        nativeMetadata: Data? = nil
    ) {
        self.kind = kind
        self.fileName = fileName
        self.mimeType = mimeType
        self.size = size
        self.width = width
        self.height = height
        self.relativePath = relativePath
        self.nativeMetadata = nativeMetadata
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case fileName
        case mimeType
        case size
        case width
        case height
        case relativePath
        case nativeMetadata
    }

    /// Older stores contain only the attachment identity/path fields. Decode
    /// every additive metadata field with `decodeIfPresent` so adding optional
    /// keys never makes one legacy media record reject the complete payload.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(Kind.self, forKey: .kind),
            fileName: try container.decodeIfPresent(String.self, forKey: .fileName),
            mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType),
            size: try container.decodeIfPresent(Int64.self, forKey: .size),
            width: try container.decodeIfPresent(Int32.self, forKey: .width),
            height: try container.decodeIfPresent(Int32.self, forKey: .height),
            relativePath: try container.decode(String.self, forKey: .relativePath),
            nativeMetadata: try container.decodeIfPresent(Data.self, forKey: .nativeMetadata)
        )
    }
}

/// A custom-emoji file referenced by TextEntitiesMessageAttribute. It is kept
/// separately from message.media because Telegram resolves it through
/// Message.associatedMedia.
public struct AyuSavedAssociatedMedia: Codable, Equatable {
    public let namespace: Int32
    public let id: Int64
    public let nativeMetadata: Data
    public let relativePath: String?

    public init(namespace: Int32, id: Int64, nativeMetadata: Data, relativePath: String?) {
        self.namespace = namespace
        self.id = id
        self.nativeMetadata = nativeMetadata
        self.relativePath = relativePath
    }
}

/// Lightweight snapshot of a Telegram message stored outside Postbox.
/// We persist only what's needed to display the message after it gets deleted
/// or after a newer revision overwrites it.
public struct AyuSavedMessage: Codable, Equatable {
    public let accountId: Int64
    public let peerId: Int64
    public let messageId: Int32
    public let threadId: Int64?
    public let globallyUniqueId: Int64?
    public let authorId: Int64?
    public let date: Int32
    public let editDate: Int32?
    public let text: String
    public let media: [AyuSavedMedia]
    public let flags: UInt32?
    /// Effective protection at capture time (message OR owning peer). This is
    /// independent of serialized peer metadata, which is display-only data.
    public let effectiveCopyProtected: Bool?
    public let textEntitiesAttribute: Data?
    public let authorPeer: Data?
    public let associatedMedia: [AyuSavedAssociatedMedia]
    public let savedAt: Int64

    public init(
        accountId: Int64,
        peerId: Int64,
        messageId: Int32,
        threadId: Int64? = nil,
        globallyUniqueId: Int64?,
        authorId: Int64?,
        date: Int32,
        editDate: Int32?,
        text: String,
        media: [AyuSavedMedia] = [],
        flags: UInt32? = nil,
        effectiveCopyProtected: Bool? = nil,
        textEntitiesAttribute: Data? = nil,
        authorPeer: Data? = nil,
        associatedMedia: [AyuSavedAssociatedMedia] = [],
        savedAt: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        self.accountId = accountId
        self.peerId = peerId
        self.messageId = messageId
        self.threadId = threadId
        self.globallyUniqueId = globallyUniqueId
        self.authorId = authorId
        self.date = date
        self.editDate = editDate
        self.text = text
        self.media = media
        self.flags = flags
        self.effectiveCopyProtected = effectiveCopyProtected
        self.textEntitiesAttribute = textEntitiesAttribute
        self.authorPeer = authorPeer
        self.associatedMedia = associatedMedia
        self.savedAt = savedAt
    }

    private enum CodingKeys: String, CodingKey {
        case accountId, peerId, messageId, threadId, globallyUniqueId, authorId, date, editDate, text, media, flags, effectiveCopyProtected, textEntitiesAttribute, authorPeer, associatedMedia, savedAt
    }

    // MARK: Backward compatibility — stores written before attachments existed
    // have no `media` key.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            accountId: try container.decode(Int64.self, forKey: .accountId),
            peerId: try container.decode(Int64.self, forKey: .peerId),
            messageId: try container.decode(Int32.self, forKey: .messageId),
            threadId: try container.decodeIfPresent(Int64.self, forKey: .threadId),
            globallyUniqueId: try container.decodeIfPresent(Int64.self, forKey: .globallyUniqueId),
            authorId: try container.decodeIfPresent(Int64.self, forKey: .authorId),
            date: try container.decode(Int32.self, forKey: .date),
            editDate: try container.decodeIfPresent(Int32.self, forKey: .editDate),
            text: try container.decode(String.self, forKey: .text),
            media: try container.decodeIfPresent([AyuSavedMedia].self, forKey: .media) ?? [],
            flags: try container.decodeIfPresent(UInt32.self, forKey: .flags),
            effectiveCopyProtected: try container.decodeIfPresent(Bool.self, forKey: .effectiveCopyProtected),
            textEntitiesAttribute: try container.decodeIfPresent(Data.self, forKey: .textEntitiesAttribute),
            authorPeer: try container.decodeIfPresent(Data.self, forKey: .authorPeer),
            associatedMedia: try container.decodeIfPresent([AyuSavedAssociatedMedia].self, forKey: .associatedMedia) ?? [],
            savedAt: try container.decodeIfPresent(Int64.self, forKey: .savedAt) ?? Int64(Date().timeIntervalSince1970)
        )
    }
}

/// One revision of an edited message. The newest revision is the current Postbox
/// state; every previous text is preserved here with its edit timestamp.
public struct AyuMessageRevision: Codable, Equatable {
    public let accountId: Int64
    public let peerId: Int64
    public let messageId: Int32
    public let threadId: Int64?
    public let text: String
    public let editDate: Int32
    public let capturedAt: Int64

    public init(
        accountId: Int64,
        peerId: Int64,
        messageId: Int32,
        threadId: Int64? = nil,
        text: String,
        editDate: Int32,
        capturedAt: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        self.accountId = accountId
        self.peerId = peerId
        self.messageId = messageId
        self.threadId = threadId
        self.text = text
        self.editDate = editDate
        self.capturedAt = capturedAt
    }
}

/// On-disk container. Everything in one JSON file for MVP — fine for a few
/// thousand messages. Phase 2 will switch to per-peer plist/sqlite if needed.
public struct AyuStorePayload: Codable {
    public var deletedMessages: [AyuSavedMessage]
    public var editedRevisions: [AyuMessageRevision]

    public static let empty = AyuStorePayload(deletedMessages: [], editedRevisions: [])

    public init(deletedMessages: [AyuSavedMessage], editedRevisions: [AyuMessageRevision]) {
        self.deletedMessages = deletedMessages
        self.editedRevisions = editedRevisions
    }
}

/// Authoritative policy facts captured while the source transaction peer is
/// available. This token is intentionally in-memory only: immediate cached
/// media needs settings revalidation at its asynchronous store commit, not
/// restart recovery.
public struct AyuMediaCapturePolicyContext: Equatable {
    public let isDirectDialogBot: Bool
    public let isIncoming: Bool
    public let mediaPolicy: AyuPendingMediaCapture.MediaPolicy

    public init(isDirectDialogBot: Bool, isIncoming: Bool, mediaPolicy: AyuPendingMediaCapture.MediaPolicy) {
        self.isDirectDialogBot = isDirectDialogBot
        self.isIncoming = isIncoming
        self.mediaPolicy = mediaPolicy
    }
}

/// Durable intent to preserve one cloud instant-video resource once MediaBox
/// has promoted it to a complete file. Partial bytes are never referenced.
public struct AyuPendingMediaCapture: Codable, Equatable {
    public enum MediaPolicy: String, Codable {
        case privateChat
        case publicGroup
        case privateGroup
        case publicChannel
        case privateChannel
    }

    public let message: AyuSavedMessage
    public let mediaIndex: Int
    public let fileMetadata: Data
    public let expectedSize: Int64?
    /// Authoritative classification of the containing dialog peer at capture
    /// time. Optional so pending records written by older builds still decode.
    public let isDirectDialogBot: Bool?
    /// Durable proof that the source Message was incoming. Older records that
    /// lack this proof are decoded but must not be resumed or finalized.
    public let isIncoming: Bool?
    /// Peer/media-setting classification captured from the authoritative peer.
    /// Legacy records omit it and remain decodable.
    public let mediaPolicy: MediaPolicy?
    public let createdAt: Int64
    /// Identifies one replacement generation for compare-and-remove and
    /// observer ownership. `nil` remains valid for pre-generation records.
    public let generationId: UUID?

    /// New records carry `isIncoming` explicitly. A pending record from the
    /// immediately preceding format can still prove the invariant through its
    /// sanitized persisted MessageFlags (`Incoming` is the stable raw bit 4).
    /// Records older than both representations fail closed.
    public var hasIncomingSourceProof: Bool {
        if let isIncoming {
            return isIncoming
        }
        return ((message.flags ?? 0) & 4) != 0
    }

    /// PeerId's durable representation stores its namespace in bits 32...34.
    /// This lets the model distinguish legacy direct-user records without a
    /// dependency on Postbox or TelegramCore.
    public var isCloudUserPeer: Bool {
        return ((UInt64(bitPattern: message.peerId) >> 32) & 0x7) == 0
    }

    public init(message: AyuSavedMessage, mediaIndex: Int, fileMetadata: Data, expectedSize: Int64?, isDirectDialogBot: Bool?, isIncoming: Bool, mediaPolicy: MediaPolicy, createdAt: Int64 = Int64(Date().timeIntervalSince1970), generationId: UUID? = UUID()) {
        self.message = message
        self.mediaIndex = mediaIndex
        self.fileMetadata = fileMetadata
        self.expectedSize = expectedSize
        self.isDirectDialogBot = isDirectDialogBot
        self.isIncoming = isIncoming
        self.mediaPolicy = mediaPolicy
        self.createdAt = createdAt
        self.generationId = generationId
    }
}
