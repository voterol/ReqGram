import Foundation

/// The deliberately small, presentation-only ReqGram settings interchange.
/// Keep this list explicit: adding a UserDefaults key here is a security review.
public enum ReqGramSettingsTransfer {
    public static let formatVersion = 1
    public static let fileName = "reqgram-presentation-settings.json"
    public static let keys: [String] = [
        "fullChannelViewCounts", "reqGramShowForwardCounts", "reqGramCompactDescriptions",
        "stopAfterVoiceMessage", "reqGramCharacterCounter", "secondsInMessages",
        "wideChannelPosts", "ayuSemiTransparentDeleted", "reqGramDeletedOpacityPercent",
        "compactChatList", "showProfileId", "showDC"
    ]

    public enum Error: Swift.Error, LocalizedError {
        case invalidFormat, unsupportedVersion, invalidKey, invalidValue, tooLarge, unableToRead
        public var errorDescription: String? {
            switch self {
            case .invalidFormat: return "This is not a ReqGram presentation settings file."
            case .unsupportedVersion: return "This settings file uses an unsupported version."
            case .invalidKey: return "The settings file contains an unsupported setting."
            case .invalidValue: return "The settings file contains an invalid value or range."
            case .tooLarge: return "The settings file is too large."
            case .unableToRead: return "The settings file could not be read."
            }
        }
    }

    private static let boolKeys: Set<String> = [
        "fullChannelViewCounts", "reqGramShowForwardCounts", "reqGramCompactDescriptions",
        "stopAfterVoiceMessage", "reqGramCharacterCounter", "secondsInMessages",
        "wideChannelPosts", "ayuSemiTransparentDeleted", "compactChatList", "showProfileId", "showDC"
    ]

    public static func exportData(settings: SGSimpleSettings = .shared) throws -> Data {
        var values: [String: Any] = [:]
        for key in keys { values[key] = value(forKey: key, settings: settings) }
        let object: [String: Any] = ["formatVersion": formatVersion, "settings": values]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    }

    /// Validates the complete document before changing UserDefaults. All setters below are
    /// non-throwing, so applying the already validated typed values is all-or-nothing.
    public static func importData(_ data: Data, settings: SGSimpleSettings = .shared) throws {
        guard data.count <= 128 * 1024 else { throw Error.tooLarge }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["formatVersion"] as? Int, version == formatVersion,
              let raw = root["settings"] as? [String: Any], Set(raw.keys) == Set(keys) else { throw Error.invalidFormat }
        var checked: [String: Any] = [:]
        for key in keys {
            guard let value = raw[key] else { throw Error.invalidKey }
            if boolKeys.contains(key) {
                guard let bool = value as? Bool else { throw Error.invalidValue }; checked[key] = bool
            } else {
                guard let number = value as? Int, (30...100).contains(number) else { throw Error.invalidValue }
                checked[key] = number
            }
        }
        // No validation or throwing work is performed after this point.
        for key in keys { set(checked[key]!, forKey: key, settings: settings) }
    }

    public static func reset(settings: SGSimpleSettings = .shared) {
        let defaults = SGSimpleSettings.defaultValues
        for key in keys {
            if let value = defaults[key] { set(value, forKey: key, settings: settings) }
        }
    }

    private static func value(forKey key: String, settings: SGSimpleSettings) -> Any {
        switch key {
        case "fullChannelViewCounts": return settings.fullChannelViewCounts
        case "reqGramShowForwardCounts": return settings.reqGramShowForwardCounts
        case "reqGramCompactDescriptions": return settings.reqGramCompactDescriptions
        case "stopAfterVoiceMessage": return settings.stopAfterVoiceMessage
        case "reqGramCharacterCounter": return settings.reqGramCharacterCounter
        case "secondsInMessages": return settings.secondsInMessages
        case "wideChannelPosts": return settings.wideChannelPosts
        case "ayuSemiTransparentDeleted": return settings.ayuSemiTransparentDeleted
        case "reqGramDeletedOpacityPercent": return settings.reqGramDeletedOpacityPercent
        case "compactChatList": return settings.compactChatList
        case "showProfileId": return settings.showProfileId
        default: return settings.showDC
        }
    }

    private static func set(_ value: Any, forKey key: String, settings: SGSimpleSettings) {
        switch key {
        case "fullChannelViewCounts": settings.fullChannelViewCounts = value as! Bool
        case "reqGramShowForwardCounts": settings.reqGramShowForwardCounts = value as! Bool
        case "reqGramCompactDescriptions": settings.reqGramCompactDescriptions = value as! Bool
        case "stopAfterVoiceMessage": settings.stopAfterVoiceMessage = value as! Bool
        case "reqGramCharacterCounter": settings.reqGramCharacterCounter = value as! Bool
        case "secondsInMessages": settings.secondsInMessages = value as! Bool
        case "wideChannelPosts": settings.wideChannelPosts = value as! Bool
        case "ayuSemiTransparentDeleted": settings.ayuSemiTransparentDeleted = value as! Bool
        case "reqGramDeletedOpacityPercent": settings.reqGramDeletedOpacityPercent = value as! Int
        case "compactChatList": settings.compactChatList = value as! Bool
        case "showProfileId": settings.showProfileId = value as! Bool
        case "showDC": settings.showDC = value as! Bool
        default: break
        }
    }
}
