import Foundation

/// Filesystem layout helpers for AyuGram local store.
/// Everything lives under `<Application Support>/AyuGram/` so we don't touch Postbox.
public enum AyuStorage {
    private static let queue = DispatchQueue(label: "app.swiftgram.ayugram.storage", qos: .utility)

    /// Pure path resolution. This must be used by swap/rollback code so merely
    /// asking for a path cannot create the directory being tested.
    public static var rootPathURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("AyuGram", isDirectory: true)
    }

    public static var rootURL: URL {
        let url = rootPathURL
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(resourceValues)
        } catch {
            assertionFailure("Unable to configure AyuGram storage: \(error)")
        }
        return url
    }

    public static var storeURL: URL {
        return rootURL.appendingPathComponent("store.json", isDirectory: false)
    }

    public static var storePathURL: URL {
        return rootPathURL.appendingPathComponent("store.json", isDirectory: false)
    }

    public static var pendingCapturesURL: URL {
        return rootURL.appendingPathComponent("pending-captures.json", isDirectory: false)
    }

    public static var pendingCapturesPathURL: URL {
        return rootPathURL.appendingPathComponent("pending-captures.json", isDirectory: false)
    }

    public static var attachmentsPathURL: URL {
        return rootPathURL.appendingPathComponent("attachments", isDirectory: true)
    }

    public static var attachmentsURL: URL {
        let url = attachmentsPathURL
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        } catch {
            assertionFailure("Unable to create AyuGram attachments directory: \(error)")
        }
        return url
    }

    /// Serialized access to the on-disk store. Use for all write/read operations.
    public static func sync<T>(_ body: () throws -> T) rethrows -> T {
        return try queue.sync(execute: body)
    }

    public static func async(_ body: @escaping () -> Void) {
        queue.async(execute: body)
    }

    // MARK: Attachments

    /// Destination for a preserved attachment, creating intermediate directories.
    /// Returns the absolute file URL and the path relative to `attachmentsURL`
    /// (the value persisted in `AyuSavedMedia.relativePath`).
    public static func attachmentDestinationURL(accountId: Int64, peerId: Int64, fileName: String) -> (url: URL, relativePath: String) {
        let directoryURL = attachmentsURL
            .appendingPathComponent("\(accountId)", isDirectory: true)
            .appendingPathComponent("\(peerId)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        } catch {
            assertionFailure("Unable to create AyuGram attachment directory: \(error)")
        }
        let relativePath = "\(accountId)/\(peerId)/\(fileName)"
        return (directoryURL.appendingPathComponent(fileName, isDirectory: false), relativePath)
    }

    public static func attachmentFileURL(relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.contains("\0") else {
            return nil
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return nil
        }
        let root = attachmentsPathURL.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    /// Resolves only paths generated for this record's account/peer. Older
    /// unscoped layouts are deliberately not accepted during reconstruction.
    public static func attachmentFileURL(relativePath: String, accountId: Int64, peerId: Int64) -> URL? {
        let expectedPrefix = "\(accountId)/\(peerId)/"
        guard relativePath.hasPrefix(expectedPrefix) else { return nil }
        return attachmentFileURL(relativePath: relativePath)
    }

    /// Resolves an attachment only when every existing path component stays a
    /// real directory/file rather than crossing a symlink. Checking only the
    /// final URL is insufficient because a parent directory could itself be a
    /// symlink outside the attachment root.
    public static func regularAttachmentFileURL(relativePath: String) -> URL? {
        guard let candidate = attachmentFileURL(relativePath: relativePath) else { return nil }
        guard let rootValues = try? attachmentsPathURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { return nil }
        let components = relativePath.split(separator: "/").map(String.init)
        var current = attachmentsPathURL
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component, isDirectory: index != components.count - 1)
            guard let values = try? current.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return nil }
            if index == components.count - 1 {
                guard values.isRegularFile == true else { return nil }
            } else {
                guard values.isDirectory == true else { return nil }
            }
        }
        return candidate
    }

    /// Applies both record scoping and component-by-component symlink checks.
    public static func regularAttachmentFileURL(relativePath: String, accountId: Int64, peerId: Int64) -> URL? {
        let expectedPrefix = "\(accountId)/\(peerId)/"
        guard relativePath.hasPrefix(expectedPrefix) else { return nil }
        return regularAttachmentFileURL(relativePath: relativePath)
    }

    /// Destructive operations use the same component-by-component policy as
    /// reads. In particular, never hand `removeItem` a path whose attachment
    /// root or parent is a symlink. The second check immediately before removal
    /// narrows Foundation's unavoidable check/use window and fails closed if
    /// the tree changes.
    private static func regularAttachmentDirectoryURL(relativeComponents: [String]) -> URL? {
        guard !relativeComponents.isEmpty else { return nil }
        guard let rootValues = try? attachmentsPathURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { return nil }
        var current = attachmentsPathURL
        for component in relativeComponents {
            guard !component.isEmpty, component != ".", component != "..", !component.contains("/"), !component.contains("\\"), !component.contains("\0") else {
                return nil
            }
            current.appendPathComponent(component, isDirectory: true)
            guard let values = try? current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        }
        return current
    }

    public static func removeAttachment(relativePath: String) {
        guard regularAttachmentFileURL(relativePath: relativePath) != nil,
              let candidate = regularAttachmentFileURL(relativePath: relativePath) else { return }
        try? FileManager.default.removeItem(at: candidate)
    }

    public static func removeAttachments(accountId: Int64) {
        let component = "\(accountId)"
        guard regularAttachmentDirectoryURL(relativeComponents: [component]) != nil,
              let directoryURL = regularAttachmentDirectoryURL(relativeComponents: [component]) else { return }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    public static func removeAllAttachments() {
        guard let values = try? attachmentsPathURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let secondValues = try? attachmentsPathURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              secondValues.isDirectory == true, secondValues.isSymbolicLink != true else { return }
        try? FileManager.default.removeItem(at: attachmentsPathURL)
    }
}
