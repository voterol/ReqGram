/// Local presentation policy only; does not change capture or retention behavior.
public enum ReqGramPresentationPolicy {
    public static let defaultDeletedOpacityPercent = 70
    public static let minimumDeletedOpacityPercent = 30
    public static let maximumDeletedOpacityPercent = 100

    public static func validatedDeletedOpacityPercent(_ value: Int) -> Int {
        return min(max(value, minimumDeletedOpacityPercent), maximumDeletedOpacityPercent)
    }

    public static func deletedMessageAlpha(semiTransparent: Bool, percent: Int) -> Double {
        // Keep the existing switch authoritative, including for older installations.
        guard semiTransparent else { return 1.0 }
        return Double(validatedDeletedOpacityPercent(percent)) / 100.0
    }

    public enum NoticeKind {
        case explanation
        case warning
    }

    public static func showsNotice(_ kind: NoticeKind, compact: Bool) -> Bool {
        switch kind {
        case .explanation: return !compact
        case .warning: return true
        }
    }
}
