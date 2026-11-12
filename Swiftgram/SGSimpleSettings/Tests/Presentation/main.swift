import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

let policy = ReqGramPresentationPolicy.self
expect(policy.defaultDeletedOpacityPercent == 70, "legacy default")
for (input, expected) in [(Int.min, 30), (-1, 30), (0, 30), (29, 30), (30, 30), (70, 70), (100, 100), (101, 100), (Int.max, 100)] {
    expect(policy.validatedDeletedOpacityPercent(input) == expected, "clamp \(input)")
    expect(policy.deletedMessageAlpha(semiTransparent: true, percent: input) == Double(expected) / 100, "alpha \(input)")
    expect(policy.deletedMessageAlpha(semiTransparent: false, percent: input) == 1, "off remains opaque \(input)")
}
expect(policy.deletedMessageAlpha(semiTransparent: true, percent: policy.defaultDeletedOpacityPercent) == 0.7, "legacy enabled default")
for compact in [false, true] {
    expect(policy.showsNotice(.warning, compact: compact), "warnings must remain visible")
    expect(policy.showsNotice(.explanation, compact: compact) == !compact, "optional explanation visibility")
}
print("Presentation policy tests passed")
