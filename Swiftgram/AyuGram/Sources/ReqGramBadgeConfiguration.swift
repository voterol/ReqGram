import Foundation

/// First-party values which are not yet assigned by product/operations.
/// Keep these absent rather than substituting another project's endpoint or
/// custom emoji identifiers.
public enum ReqGramBadgeConfiguration {
    public static let displayName = "ReqGram"
    public static let heroMonogram = "R"

    public static let endpoint: URL? = URL(string: "https://api-reqgram.tgstorage.space/v1/badges")

    public static let ownerDocumentId: Int64? = nil
    public static let officialDocumentId: Int64? = nil
    public static let teamDocumentId: Int64? = nil
    public static let developerDocumentId: Int64? = nil
    public static let sponsorDocumentId: Int64? = nil
    public static let supporterDocumentId: Int64? = nil

    /// Product-owned actions. Keep an action absent until its production value
    /// is supplied. UI must use `validatedActionURL(_:)`, not these values
    /// directly.
    public static let donationURL: URL? = URL(string: "https://t.me/ReqGramDonation_bot")
    public static let proofOfPaymentURL: URL? = nil
    public static let learnMoreURL: URL? = nil
    public static let officialResourceURL: URL? = nil

    public enum Action: CaseIterable, Equatable {
        case donate
        case proofOfPayment
        case learnMore
        case officialResource
    }

    public static func validatedActionURL(_ action: Action) -> URL? {
        let value: URL?
        switch action {
        case .donate:
            value = self.donationURL
        case .proofOfPayment:
            value = self.proofOfPaymentURL
        case .learnMore:
            value = self.learnMoreURL
        case .officialResource:
            value = self.officialResourceURL
        }
        guard let value, let scheme = value.scheme?.lowercased() else {
            return nil
        }
        switch scheme {
        case "https":
            guard value.host != nil, value.user == nil, value.password == nil else {
                return nil
            }
            if action == .donate && (value.host?.lowercased() != "t.me" || value.path != "/ReqGramDonation_bot" || value.query != nil || value.fragment != nil) {
                return nil
            }
        case "tg":
            guard let host = value.host?.lowercased(), ["resolve", "join", "joinchat"].contains(host) else {
                return nil
            }
        default:
            return nil
        }
        return value
    }
}
