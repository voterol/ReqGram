import Foundation

// Standalone assertions, like Tests/Tgws/main.swift. Compile only with the
// Foundation-only FullChannelViewCount.swift; no generated project is needed.
let english = Locale(identifier: "en_US")
for (count, expected) in [
    (0, "0"), (1, "1"), (999, "999"), (1000, "1,000"),
    (1234, "1,234"), (1000000, "1,000,000"),
    (2147483647, "2,147,483,647"),
    (Int.max, "9,223,372,036,854,775,807")
] {
    precondition(fullChannelViewCountString(count, locale: english) == expected)
}
precondition(fullChannelViewCountString(1234567, locale: Locale(identifier: "de_DE")) == "1.234.567")
precondition(fullChannelViewCountString(1234567, locale: Locale(identifier: "hi_IN")) == "12,34,567")
for identifier in ["fr_FR", "ru_RU", "ar", "he"] {
    let locale = Locale(identifier: identifier)
    let result = fullChannelViewCountString(1234567, locale: locale)
    let parser = NumberFormatter()
    parser.locale = locale
    parser.numberStyle = .decimal
    precondition(parser.number(from: result)?.intValue == 1234567)
    precondition(!result.contains("K") && !result.contains("M"))
}
print("Full channel view count formatter checks passed")
