import Postbox

public enum AyuSyntheticMessageIdentity {
    public static func syntheticMessageId(originalId: Int32) -> Int32 {
        if originalId < 0 {
            return originalId
        }
        return Int32.min &+ originalId
    }
}

/// Authoritative marker for an in-memory message reconstructed from an
/// AyuGram deleted-message snapshot. Synthetic ids are an implementation
/// detail and must not be used to decide whether a message is deleted.
public final class AyuSyntheticMessageAttribute: MessageAttribute {
    public let accountId: Int64
    public let peerId: Int64
    public let threadId: Int64?
    public let originalMessageId: Int32

    public init(accountId: Int64, peerId: Int64, threadId: Int64?, originalMessageId: Int32) {
        self.accountId = accountId
        self.peerId = peerId
        self.threadId = threadId
        self.originalMessageId = originalMessageId
    }

    public init(decoder: PostboxDecoder) {
        self.accountId = decoder.decodeInt64ForKey("a", orElse: 0)
        self.peerId = decoder.decodeInt64ForKey("p", orElse: 0)
        self.threadId = decoder.decodeOptionalInt64ForKey("t")
        self.originalMessageId = decoder.decodeInt32ForKey("m", orElse: 0)
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt64(self.accountId, forKey: "a")
        encoder.encodeInt64(self.peerId, forKey: "p")
        if let threadId = self.threadId {
            encoder.encodeInt64(threadId, forKey: "t")
        } else {
            encoder.encodeNil(forKey: "t")
        }
        encoder.encodeInt32(self.originalMessageId, forKey: "m")
    }

    public static func == (lhs: AyuSyntheticMessageAttribute, rhs: AyuSyntheticMessageAttribute) -> Bool {
        return lhs.accountId == rhs.accountId && lhs.peerId == rhs.peerId && lhs.threadId == rhs.threadId && lhs.originalMessageId == rhs.originalMessageId
    }
}

public extension Message {
    var isAyuSyntheticDeletedMessage: Bool {
        return self.attributes.contains(where: { $0 is AyuSyntheticMessageAttribute })
    }

    var ayuSyntheticDeletedMessageAttribute: AyuSyntheticMessageAttribute? {
        return self.attributes.first(where: { $0 is AyuSyntheticMessageAttribute }) as? AyuSyntheticMessageAttribute
    }
}
