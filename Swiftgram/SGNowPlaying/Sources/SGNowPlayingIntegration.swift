import AccountContext

/// Entry point wired from `SharedAccountContext` — mirrors
/// `SGScamRegistryIntegration.configure(for:)`.
public enum SGNowPlayingIntegration {
    public static func configure(for context: AccountContext?) {
        guard let context else {
            return
        }
        SGNowPlayingService.shared.configure(account: context)
    }
}
