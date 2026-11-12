import Foundation

/// CHAT-03 is deliberately a presentation-only counter. Swift's String.count
/// counts extended grapheme clusters, matching what a user sees in the draft;
/// it is not a Telegram/server limit calculation.
public enum ReqGramCharacterCounter {
    public static func count(_ text: String) -> Int {
        return text.count
    }

    public static func label(for text: String) -> String {
        return String(count(text))
    }
}
