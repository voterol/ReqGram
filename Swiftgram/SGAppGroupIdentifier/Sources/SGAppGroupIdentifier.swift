import Foundation

public let FALLBACK_BASE_BUNDLE_ID: String = "app.swiftgram.ios"

public func sgBaseBundleIdentifier() -> String {
    let baseBundleId: String
    if let bundleId: String = Bundle.main.bundleIdentifier {
        if Bundle.main.bundlePath.hasSuffix(".appex") {
            if let lastDotRange: Range<String.Index> = bundleId.range(of: ".", options: [.backwards]) {
                baseBundleId = String(bundleId[..<lastDotRange.lowerBound])
            } else {
                baseBundleId = FALLBACK_BASE_BUNDLE_ID
            }
        } else {
            baseBundleId = bundleId
        }
    } else {
        baseBundleId = FALLBACK_BASE_BUNDLE_ID
    }
    return baseBundleId
}

public func sgAppGroupIdentifier() -> String {
    let result: String = "group.\(sgBaseBundleIdentifier())"
    
    #if DEBUG
    print("APP_GROUP_IDENTIFIER: \(result)")
    #endif
    
    return result
}

// MARK: Swiftgram
// The shared container is only reachable when the running build is signed with
// the matching `com.apple.security.application-groups` entitlement. Builds that
// are re-signed for personal distribution routinely lose it, and every caller
// used to bail out, which left the app with no writable root path at all.
//
// When no app extension is present the container is not actually shared with
// anybody, so a private directory is an equivalent location and lets the app
// keep working instead of failing to launch.
//
// The fallback is deliberately a dedicated subdirectory rather than Application
// Support itself: `performAppGroupUpgrades` deletes every directory in the
// container root that it does not recognise, which would destroy unrelated data
// such as `<Application Support>/AyuGram` on every launch.
//
// This intentionally does not migrate data: a build that gains or loses the
// entitlement switches between two distinct storage roots.
public func sgAppGroupUrl() -> URL? {
    if let containerUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sgAppGroupIdentifier()) {
        return containerUrl
    }

    // An `.appex` has no usable private container of its own to fall back to,
    // and must keep sharing the host app's container.
    if Bundle.main.bundlePath.hasSuffix(".appex") {
        return nil
    }

    guard let applicationSupportUrl = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return nil
    }
    let fallbackUrl = applicationSupportUrl.appendingPathComponent("TelegramContainer", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: fallbackUrl, withIntermediateDirectories: true, attributes: nil)
    } catch {
        return nil
    }
    return fallbackUrl
}

// MARK: Swiftgram
// Mirrors `sgAppGroupUrl()` for shared preferences: without the entitlement the
// group suite cannot be used, so the app falls back to its standard defaults
// instead of silently discarding every write.
public func sgAppGroupUserDefaults() -> UserDefaults? {
    if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sgAppGroupIdentifier()) != nil {
        return UserDefaults(suiteName: sgAppGroupIdentifier())
    }

    if Bundle.main.bundlePath.hasSuffix(".appex") {
        return UserDefaults(suiteName: sgAppGroupIdentifier())
    }

    return UserDefaults.standard
}
