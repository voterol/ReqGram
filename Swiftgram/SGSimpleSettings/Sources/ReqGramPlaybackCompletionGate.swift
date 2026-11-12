/// Main-queue-owned, single-use completion tickets. Capture a ticket when installing
/// a player's callback, not when the callback is eventually delivered.
public struct ReqGramPlaybackCompletionGate {
    private var revision: UInt64 = 0
    private var armed = false

    public init() {}

    public mutating func invalidate() {
        self.revision &+= 1
        self.armed = false
    }

    public mutating func arm() -> UInt64 {
        self.invalidate()
        self.armed = true
        return self.revision
    }

    public mutating func consume(_ ticket: UInt64) -> Bool {
        guard self.armed && ticket == self.revision else { return false }
        self.armed = false
        return true
    }
}
