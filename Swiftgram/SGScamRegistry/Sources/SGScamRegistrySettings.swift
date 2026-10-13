import Foundation

/// User-controlled refresh cadence. The raw values are stable storage/API values.
public enum SGScamRegistryRefreshInterval: Int, CaseIterable, Codable {
    case oneHour = 3_600
    case twoHours = 7_200
    case threeHours = 10_800
    case sixHours = 21_600
    case twelveHours = 43_200
    case oneDay = 86_400

    public var title: String {
        switch self {
        case .oneHour: return "1h"
        case .twoHours: return "2h"
        case .threeHours: return "3h"
        case .sixHours: return "6h"
        case .twelveHours: return "12h"
        case .oneDay: return "1d"
        }
    }
}

public struct SGScamRegistrySettings {
    public static let enabledKey = "sg.scamRegistry.enabled"
    public static let intervalKey = "sg.scamRegistry.interval"

    public var enabled: Bool
    public var interval: SGScamRegistryRefreshInterval

    public init(enabled: Bool = false, interval: SGScamRegistryRefreshInterval = .oneDay) {
        self.enabled = enabled
        self.interval = interval
    }

    public init(defaults: UserDefaults = .standard) {
        self.enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        self.interval = SGScamRegistryRefreshInterval(rawValue: defaults.integer(forKey: Self.intervalKey)) ?? .oneDay
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(interval.rawValue, forKey: Self.intervalKey)
    }
}
