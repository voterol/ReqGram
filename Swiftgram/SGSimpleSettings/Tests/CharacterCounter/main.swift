import Foundation
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

check(ReqGramCharacterCounter.count("") == 0, "empty draft")
check(ReqGramCharacterCounter.count("hello") == 5, "ascii graphemes")
check(ReqGramCharacterCounter.count("e\u{301}") == 1, "combining mark")
check(ReqGramCharacterCounter.count("👩‍👩‍👧‍👦") == 1, "zwj emoji")
check(ReqGramCharacterCounter.label(for: "🙂🙂") == "2", "label")
print("character counter tests passed")
