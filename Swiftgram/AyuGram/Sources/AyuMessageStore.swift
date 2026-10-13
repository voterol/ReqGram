import Foundation
import SGLogging
import SGSimpleSettings

/// Local JSON-backed store for AyuGram preserved messages.
///
/// All access goes through a serial queue. The store is loaded lazily on first
/// read and saved after every mutation. We cap total retained messages to keep
/// the JSON file from growing without bound (`maxMessagesPerPeer`).
public final class AyuMessageStore {
    public static let shared = AyuMessageStore()

    /// Notified on the main queue after a write commits, with the set of
    /// peer ids (Int64 form of PeerId) whose preserved data changed.
    /// Subscribers refresh chat history for matching peers. Keep callbacks
    /// main-thread safe; subscribers are responsible for avoiding retain
    /// cycles (use weak captures).
    private static let observersLock = NSLock()
    private static var storeChangedObservers: [UUID: (Set<Int64>) -> Void] = [:]

    /// Adds an independent store-change observer. The returned token must be
    /// removed by the owner; observers do not replace one another.
    public static func addStoreChangedObserver(_ observer: @escaping (Set<Int64>) -> Void) -> UUID {
        let token = UUID()
        observersLock.lock()
        storeChangedObservers[token] = observer
        observersLock.unlock()
        return token
    }

    public static func removeStoreChangedObserver(_ token: UUID) {
        observersLock.lock()
        storeChangedObservers.removeValue(forKey: token)
        observersLock.unlock()
    }

    private static func notifyChanged(peerIds: Set<Int64>) {
        guard !peerIds.isEmpty else { return }
        DispatchQueue.main.async {
            observersLock.lock()
            let observers = Array(storeChangedObservers.values)
            observersLock.unlock()
            for observer in observers {
                observer(peerIds)
            }
        }
    }

    public static let maxMessagesPerPeer = 500
    private static let maxStoreBytes: Int64 = 128 * 1024 * 1024
    private static let maxMetadataBytes = 2 * 1024 * 1024
    private static let maxPendingCaptures = 64
    private static let maxPendingAge: Int64 = 7 * 24 * 60 * 60

    private var payload: AyuStorePayload = .empty
    private var loaded = false

    private init() {}

    // MARK: Load / Save

    private func ensureLoaded() {
        if loaded { return }
        loaded = true
        guard let values = try? AyuStorage.storePathURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let fileSize = values.fileSize, fileSize >= 0, Int64(fileSize) <= AyuMessageStore.maxStoreBytes,
               let data = try? Data(contentsOf: AyuStorage.storePathURL) else {
            payload = .empty
            return
        }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(AyuStorePayload.self, from: data), validate(decoded) {
            let normalized = normalizeAttachmentPaths(decoded)
            if normalized.changed {
                payload = saveLocked(normalized.payload) ? normalized.payload : decoded
            } else {
                payload = decoded
            }
        } else {
            SGLogger.shared.log("AyuGram", "Failed to decode store, starting fresh")
            payload = .empty
        }
    }

    @discardableResult
    private func saveLocked(_ value: AyuStorePayload? = nil) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(value ?? payload)
            try data.write(to: AyuStorage.storeURL, options: [.atomic])
            return true
        } catch {
            SGLogger.shared.log("AyuGram", "Store write failed: \(error)")
            return false
        }
    }

    // MARK: Public API

    public func saveDeleted(messages: [AyuSavedMessage], requiringPendingCapture pendingCapture: AyuPendingMediaCapture? = nil, mediaCapturePolicy: AyuMediaCapturePolicyContext? = nil, completion: ((Bool) -> Void)? = nil) {
        guard !messages.isEmpty else {
            completion?(false)
            return
        }
        AyuStorage.async { [self] in
            if let mediaCapturePolicy, !shouldCommitMediaCapture(mediaCapturePolicy) {
                ensureLoaded()
                let retainedPaths = attachmentPaths(in: payload)
                for message in messages {
                    removeAttachmentFilesLocked(for: message, excluding: retainedPaths)
                }
                completion?(false)
                return
            }
            if let pendingCapture {
                guard isCurrentPendingCaptureLocked(pendingCapture) else {
                    completion?(false)
                    return
                }
                guard shouldCommitPendingCapture(pendingCapture) else {
                    removePendingCaptureLocked(pendingCapture)
                    completion?(false)
                    return
                }
            }
            ensureLoaded()
            let priorPayload = payload
            var rejectedOrReplaced: [AyuSavedMessage] = []
            for message in messages {
                let replaced = payload.deletedMessages.filter {
                    $0.accountId == message.accountId
                        && $0.peerId == message.peerId
                        && $0.messageId == message.messageId
                }
                let merged = replaced.reduce(message) { mergedCapture(new: $0, old: $1) }
                let messageToSave = AyuSavedMessage(
                        accountId: message.accountId,
                        peerId: message.peerId,
                        messageId: message.messageId,
                        threadId: message.threadId,
                        globallyUniqueId: message.globallyUniqueId,
                        authorId: message.authorId,
                        date: message.date,
                        editDate: message.editDate,
                        text: message.text,
                        media: merged.media,
                        flags: message.flags,
                        effectiveCopyProtected: merged.effectiveCopyProtected,
                        textEntitiesAttribute: message.textEntitiesAttribute,
                        authorPeer: message.authorPeer,
                        associatedMedia: merged.associatedMedia,
                        savedAt: message.savedAt
                    )
                rejectedOrReplaced.append(message)
                rejectedOrReplaced.append(contentsOf: replaced)
                payload.deletedMessages.removeAll {
                    $0.accountId == message.accountId
                        && $0.peerId == message.peerId
                        && $0.messageId == message.messageId
                }
                payload.deletedMessages.append(messageToSave)
            }
            rejectedOrReplaced.append(contentsOf: pruneDeletedLocked())
            guard saveLocked() else {
                payload = priorPayload
                completion?(false)
                return
            }
            let retainedPaths = attachmentPaths(in: payload)
            for entry in rejectedOrReplaced {
                removeAttachmentFilesLocked(for: entry, excluding: retainedPaths)
            }
            let changedPeerIds = Set(messages.map { $0.peerId })
            AyuMessageStore.notifyChanged(peerIds: changedPeerIds)
            completion?(true)
        }
    }

    public func saveRevisions(_ revisions: [AyuMessageRevision]) {
        guard !revisions.isEmpty else { return }
        AyuStorage.async { [self] in
            ensureLoaded()
            let priorPayload = payload
            for revision in revisions where !payload.editedRevisions.contains(revision) {
                payload.editedRevisions.append(revision)
            }
            pruneRevisionsLocked()
            if !saveLocked() {
                payload = priorPayload
            }
        }
    }

    /// Persists a bounded capture intent synchronously so the caller can mark
    /// Telegram content consumed only after restart-recovery metadata is safe.
    /// Registers one capture intent. Re-registering the same resource for the
    /// same message/media slot returns the existing generation so concurrent
    /// update delivery cannot replace an active observer with equivalent work.
    public func registerPendingCapture(_ capture: AyuPendingMediaCapture) -> AyuPendingMediaCapture? {
        guard capture.message.accountId != 0, capture.message.peerId != 0,
              capture.message.messageId > 0, capture.mediaIndex >= 0,
              capture.hasIncomingSourceProof,
              capture.isDirectDialogBot != nil,
              capture.mediaPolicy != nil,
              capture.fileMetadata.count <= AyuMessageStore.maxMetadataBytes,
              capture.message.media.isEmpty,
              capture.expectedSize == nil || (capture.expectedSize! > 0 && capture.expectedSize! <= Int64.max / 2) else {
            return nil
        }
        return AyuStorage.sync {
            var captures = loadPendingCapturesLocked()
            if let existing = captures.first(where: {
                pendingIdentity($0) == pendingIdentity(capture)
                    && $0.fileMetadata == capture.fileMetadata
                    && $0.expectedSize == capture.expectedSize
                    && $0.isDirectDialogBot == capture.isDirectDialogBot
                    && $0.isIncoming == capture.isIncoming
                    && $0.mediaPolicy == capture.mediaPolicy
            }) {
                return existing
            }
            captures.removeAll { pendingIdentity($0) == pendingIdentity(capture) }
            captures.append(capture)
            captures = Array(captures.sorted(by: { $0.createdAt < $1.createdAt }).suffix(AyuMessageStore.maxPendingCaptures))
            return savePendingCapturesLocked(captures) ? capture : nil
        }
    }

    /// Synchronously invalidates captures before an intentional deletion can
    /// race their asynchronous finalization and resurrect the message.
    public func cancelPendingCaptures(accountId: Int64, peerId: Int64, messageIds: [Int32]) {
        guard !messageIds.isEmpty else { return }
        let ids = Set(messageIds)
        AyuStorage.sync {
            var captures = loadPendingCapturesLocked()
            let count = captures.count
            captures.removeAll {
                $0.message.accountId == accountId && $0.message.peerId == peerId && ids.contains($0.message.messageId)
            }
            if captures.count != count {
                _ = savePendingCapturesLocked(captures)
            }
        }
    }

    public func cancelPendingCaptures(accountId: Int64, peerId: Int64, threadId: Int64?, minTimestamp: Int32?, maxTimestamp: Int32?) {
        AyuStorage.sync {
            var captures = loadPendingCapturesLocked()
            let count = captures.count
            captures.removeAll { capture in
                let message = capture.message
                guard message.accountId == accountId && message.peerId == peerId else { return false }
                if let threadId, message.threadId != threadId { return false }
                if let minTimestamp, message.date < minTimestamp { return false }
                if let maxTimestamp, message.date > maxTimestamp { return false }
                return true
            }
            if captures.count != count {
                _ = savePendingCapturesLocked(captures)
            }
        }
    }

    public func pendingCaptures(accountId: Int64) -> [AyuPendingMediaCapture] {
        return AyuStorage.sync {
            let captures = loadPendingCapturesLocked()
            let pruned = prunePendingCaptures(captures)
            if pruned.count != captures.count { _ = savePendingCapturesLocked(pruned) }
            return pruned.filter { $0.message.accountId == accountId }
        }
    }

    public func isCurrentPendingCapture(_ capture: AyuPendingMediaCapture) -> Bool {
        return AyuStorage.sync {
            isCurrentPendingCaptureLocked(capture)
        }
    }

    /// Applies settings that can be evaluated durably at resume/finalize time.
    /// Legacy records have no per-peer media classification, so they honor the
    /// global media switch but retain their prior subtype behavior.
    public func shouldCommitPendingCapture(_ capture: AyuPendingMediaCapture) -> Bool {
        guard capture.hasIncomingSourceProof else { return false }
        let settings = SGSimpleSettings.shared
        guard settings.ayuSaveDeletedMessages, settings.ayuSaveMediaAttachments else { return false }
        if !settings.ayuSaveForBots {
            if capture.isDirectDialogBot == true { return false }
            if capture.isDirectDialogBot == nil && capture.isCloudUserPeer { return false }
        }
        guard let policy = capture.mediaPolicy else { return true }
        return shouldCommitMediaPolicy(policy, settings: settings)
    }

    private func shouldCommitMediaCapture(_ context: AyuMediaCapturePolicyContext) -> Bool {
        guard context.isIncoming else { return false }
        let settings = SGSimpleSettings.shared
        guard settings.ayuSaveDeletedMessages, settings.ayuSaveMediaAttachments else { return false }
        guard settings.ayuSaveForBots || !context.isDirectDialogBot else { return false }
        return shouldCommitMediaPolicy(context.mediaPolicy, settings: settings)
    }

    private func shouldCommitMediaPolicy(_ policy: AyuPendingMediaCapture.MediaPolicy, settings: SGSimpleSettings) -> Bool {
        switch policy {
        case .privateChat:
            return settings.ayuShouldSaveMedia(isPrivateChat: true, isChannel: false, isGroup: false, isPublic: false)
        case .publicGroup:
            return settings.ayuShouldSaveMedia(isPrivateChat: false, isChannel: false, isGroup: true, isPublic: true)
        case .privateGroup:
            return settings.ayuShouldSaveMedia(isPrivateChat: false, isChannel: false, isGroup: true, isPublic: false)
        case .publicChannel:
            return settings.ayuShouldSaveMedia(isPrivateChat: false, isChannel: true, isGroup: false, isPublic: true)
        case .privateChannel:
            return settings.ayuShouldSaveMedia(isPrivateChat: false, isChannel: true, isGroup: false, isPublic: false)
        }
    }

    public func removePendingCapture(_ capture: AyuPendingMediaCapture) {
        AyuStorage.async { [self] in
            removePendingCaptureLocked(capture)
        }
    }

    /// Drops preserved copies of the given messages together with their
    /// attachment files.
    ///
    /// MARK: AyuGram - mirrors `AyuMessagesController.delete(userId, dialogId,
    /// messageId)` from AyuGram Android: when the user deletes a message
    /// themselves, the archived copy must not survive as a ghost. Only
    /// deletions performed by somebody else are preserved.
    public func removeDeleted(accountId: Int64, peerId: Int64, messageIds: [Int32]) {
        guard !messageIds.isEmpty else { return }
        let ids = Set(messageIds)
        AyuStorage.async { [self] in
            ensureLoaded()
            let doomed = payload.deletedMessages.filter {
                $0.accountId == accountId && $0.peerId == peerId && ids.contains($0.messageId)
            }
            let revisionsBefore = payload.editedRevisions.count
            let hasMatchingRevisions = payload.editedRevisions.contains {
                $0.accountId == accountId && $0.peerId == peerId && ids.contains($0.messageId)
            }
            // Revisions may exist without a deleted snapshot (for example when
            // snapshot capture was disabled), but still belong to this message.
            guard !doomed.isEmpty || hasMatchingRevisions else { return }
            let priorPayload = payload
            payload.deletedMessages.removeAll {
                $0.accountId == accountId && $0.peerId == peerId && ids.contains($0.messageId)
            }
            payload.editedRevisions.removeAll {
                $0.accountId == accountId && $0.peerId == peerId && ids.contains($0.messageId)
            }
            guard !doomed.isEmpty || payload.editedRevisions.count != revisionsBefore else { return }
            guard saveLocked() else {
                payload = priorPayload
                return
            }
            for entry in doomed { removeAttachmentFilesLocked(for: entry) }
            AyuMessageStore.notifyChanged(peerIds: [peerId])
        }
    }

    /// Purges one synthetic snapshot by its complete original identity.
    public func removeDeletedIdentity(accountId: Int64, peerId: Int64, threadId: Int64?, messageId: Int32) {
        AyuStorage.async { [self] in
            ensureLoaded()
            let matches: (AyuSavedMessage) -> Bool = {
                $0.accountId == accountId && $0.peerId == peerId && $0.threadId == threadId && $0.messageId == messageId
            }
            let doomed = payload.deletedMessages.filter(matches)
            guard !doomed.isEmpty else { return }
            let priorPayload = payload
            payload.deletedMessages.removeAll(where: matches)
            payload.editedRevisions.removeAll {
                $0.accountId == accountId && $0.peerId == peerId && $0.threadId == threadId && $0.messageId == messageId
            }
            guard saveLocked() else {
                payload = priorPayload
                return
            }
            for entry in doomed { removeAttachmentFilesLocked(for: entry) }
            AyuMessageStore.notifyChanged(peerIds: [peerId])
        }
    }

    /// Drops every preserved copy belonging to a chat, together with its
    /// attachment files.
    ///
    /// MARK: AyuGram - used when the user clears a history themselves: like a
    /// manual message deletion, that is an intentional action, so the archive
    /// must not resurrect the cleared chat as ghost messages.
    public func removeDeletedForPeer(accountId: Int64, peerId: Int64, threadId: Int64? = nil, minTimestamp: Int32? = nil, maxTimestamp: Int32? = nil) {
        AyuStorage.async { [self] in
            ensureLoaded()
            let priorPayload = payload
            let matchesScope: (AyuSavedMessage) -> Bool = { message in
                guard message.accountId == accountId && message.peerId == peerId else { return false }
                if let threadId = threadId, message.threadId != threadId { return false }
                if let minTimestamp = minTimestamp, message.date < minTimestamp { return false }
                if let maxTimestamp = maxTimestamp, message.date > maxTimestamp { return false }
                return true
            }
            let doomed = payload.deletedMessages.filter(matchesScope)
            payload.deletedMessages.removeAll(where: matchesScope)
            let revisionCount = payload.editedRevisions.count
            if threadId == nil && minTimestamp == nil && maxTimestamp == nil {
                payload.editedRevisions.removeAll {
                    $0.accountId == accountId && $0.peerId == peerId
                }
            } else {
                let doomedMessageIds = Set(doomed.map(\.messageId))
                payload.editedRevisions.removeAll {
                    guard $0.accountId == accountId && $0.peerId == peerId else { return false }
                    if let threadId = threadId, $0.threadId != threadId { return false }
                    // Revision records do not contain the original message
                    // date, so editDate is not comparable to a history window.
                    // Use only IDs of snapshots proven to be in that window.
                    // Residual: an orphan revision without such a snapshot is
                    // conservatively retained.
                    return doomedMessageIds.contains($0.messageId)
                }
            }
            guard !doomed.isEmpty || payload.editedRevisions.count != revisionCount else { return }
            guard saveLocked() else {
                payload = priorPayload
                return
            }
            for entry in doomed { removeAttachmentFilesLocked(for: entry) }
            AyuMessageStore.notifyChanged(peerIds: [peerId])
        }
    }

    public func deletedMessages(peerId: Int64, accountId: Int64) -> [AyuSavedMessage] {
        return AyuStorage.sync {
            ensureLoaded()
            return payload.deletedMessages
                .filter { $0.peerId == peerId && $0.accountId == accountId }
                .sorted(by: {
                    if $0.date != $1.date {
                        return $0.date < $1.date
                    }
                    return $0.messageId < $1.messageId
                })
        }
    }

    /// Latest preserved-message timestamp for each peer in an account. Used by
    /// the narrowly-scoped Postbox repair for legacy Ayu chat-list inclusions.
    public func latestDeletedMessageTimestamps(accountId: Int64) -> [Int64: Int32] {
        return AyuStorage.sync {
            ensureLoaded()
            var result: [Int64: Int32] = [:]
            for message in payload.deletedMessages where message.accountId == accountId {
                result[message.peerId] = max(result[message.peerId] ?? Int32.min, message.date)
            }
            return result
        }
    }

    public func revisions(peerId: Int64, accountId: Int64, messageId: Int32) -> [AyuMessageRevision] {
        return AyuStorage.sync {
            ensureLoaded()
            return payload.editedRevisions
                .filter { $0.peerId == peerId && $0.accountId == accountId && $0.messageId == messageId }
                .sorted(by: { $0.editDate < $1.editDate })
        }
    }

    /// Returns the most recent local-only text override, if one exists.
    public func localTextOverride(peerId: Int64, accountId: Int64, messageId: Int32) -> String? {
        return AyuStorage.sync {
            ensureLoaded()
            return payload.editedRevisions
                .filter { $0.peerId == peerId && $0.accountId == accountId && $0.messageId == messageId }
                .sorted(by: { $0.capturedAt < $1.capturedAt })
                .last?.text
        }
    }

    /// Stores a bounded local-only replacement. This never calls Telegram APIs.
    public func saveLocalTextOverride(peerId: Int64, accountId: Int64, messageId: Int32, text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 16_384 else { return }
        let saved = AyuStorage.sync {
            ensureLoaded()
            let priorPayload = payload
            payload.editedRevisions.append(AyuMessageRevision(accountId: accountId, peerId: peerId, messageId: messageId, text: value, editDate: Int32(Date().timeIntervalSince1970)))
            pruneRevisionsLocked()
            guard saveLocked() else {
                payload = priorPayload
                return false
            }
            return true
        }
        if saved {
            AyuMessageStore.notifyChanged(peerIds: [peerId])
        }
    }

    /// Removes the local-only replacement without touching server messages or saved deletions.
    public func removeLocalTextOverride(peerId: Int64, accountId: Int64, messageId: Int32) {
        let removed = AyuStorage.sync {
            ensureLoaded()
            let priorPayload = payload
            payload.editedRevisions.removeAll {
                $0.peerId == peerId && $0.accountId == accountId && $0.messageId == messageId
            }
            guard payload.editedRevisions.count != priorPayload.editedRevisions.count else {
                return false
            }
            guard saveLocked() else {
                payload = priorPayload
                return false
            }
            return true
        }
        if removed {
            AyuMessageStore.notifyChanged(peerIds: [peerId])
        }
    }

    public func wipeAll() {
        AyuStorage.sync {
            ensureLoaded()
            guard saveLocked(.empty) else { return }
            payload = .empty
            loaded = true
            AyuStorage.removeAllAttachments()
            try? FileManager.default.removeItem(at: AyuStorage.pendingCapturesPathURL)
        }
    }

    /// Discards the in-memory cache so the next read re-decodes `store.json`
    /// from disk. Call after replacing the store file externally (import).
    public func reload() {
        AyuStorage.sync {
            loaded = false
            payload = .empty
        }
    }

    /// Validates and installs an imported database without destroying the
    /// current store if decoding or replacement fails.
    public func replaceStore(with storeData: Data, attachmentsSourceURL: URL?) throws {
        guard Int64(storeData.count) <= AyuMessageStore.maxStoreBytes else { throw CocoaError(.fileReadTooLarge) }
        let imported = try JSONDecoder().decode(AyuStorePayload.self, from: storeData)
        guard validate(imported) else { throw CocoaError(.fileReadCorruptFile) }
        // Imports are an external trust boundary. PostboxDecoder is not used on
        // arbitrary imported blobs: retain text and attachment descriptions,
        // but strip all native object encodings. Fresh local captures keep them.
        let decoded = AyuStorePayload(
            deletedMessages: imported.deletedMessages.map { message in
                AyuSavedMessage(
                    accountId: message.accountId, peerId: message.peerId, messageId: message.messageId,
                    threadId: message.threadId, globallyUniqueId: message.globallyUniqueId,
                    authorId: message.authorId, date: message.date, editDate: message.editDate,
                    text: message.text,
                    media: message.media.map { media in
                        AyuSavedMedia(kind: media.kind, fileName: media.fileName, mimeType: media.mimeType,
                            size: media.size, width: media.width, height: media.height,
                            relativePath: media.relativePath, nativeMetadata: nil)
                    },
                    flags: message.flags, effectiveCopyProtected: message.effectiveCopyProtected,
                    textEntitiesAttribute: nil, authorPeer: nil,
                    associatedMedia: [], savedAt: message.savedAt
                )
            },
            editedRevisions: imported.editedRevisions
        )
        if let source = attachmentsSourceURL {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            let sourceValues = try source.resourceValues(forKeys: Set(keys))
            guard sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: keys) else {
                throw CocoaError(.fileReadUnknown)
            }
            for case let itemURL as URL in enumerator {
                let values = try itemURL.resourceValues(forKeys: Set(keys))
                guard values.isSymbolicLink != true,
                      values.isDirectory == true || values.isRegularFile == true else {
                    throw CocoaError(.fileReadInvalidFileName)
                }
            }
        }
        try AyuStorage.sync { [self] in
            let fileManager = FileManager.default
            let root = AyuStorage.rootPathURL
            let parent = root.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let staging = root.deletingLastPathComponent().appendingPathComponent("AyuGram-import-\(UUID().uuidString)", isDirectory: true)
            let backup = root.deletingLastPathComponent().appendingPathComponent("AyuGram-backup-\(UUID().uuidString)", isDirectory: true)
            var mayDeleteBackup = false
            defer {
                try? fileManager.removeItem(at: staging)
                if mayDeleteBackup {
                    try? fileManager.removeItem(at: backup)
                }
            }
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            let sanitizedStoreData = try JSONEncoder().encode(decoded)
            try sanitizedStoreData.write(to: staging.appendingPathComponent("store.json"), options: [.atomic])
            let stagedAttachments = staging.appendingPathComponent("attachments", isDirectory: true)
            if let source = attachmentsSourceURL, fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: stagedAttachments)
            } else {
                try fileManager.createDirectory(at: stagedAttachments, withIntermediateDirectories: true)
            }
            let hadRoot = fileManager.fileExists(atPath: root.path)
            if hadRoot {
                try fileManager.moveItem(at: root, to: backup)
            }
            do {
                try fileManager.moveItem(at: staging, to: root)
            } catch {
                if hadRoot {
                    do {
                        try fileManager.moveItem(at: backup, to: root)
                        mayDeleteBackup = true
                    } catch let restorationError {
                        SGLogger.shared.log("AyuGram", "Import rollback failed; backup retained at \(backup.path): \(restorationError)")
                    }
                }
                throw error
            }
            mayDeleteBackup = true
            // Normalize only after the staged attachment tree becomes the
            // active root. This drops missing/unsafe files and migrates legacy
            // unscoped paths before imported data is exposed in memory.
            self.payload = .empty
            self.loaded = false
            self.ensureLoaded()
        }
    }

    public func removeAccount(accountPeerId: Int64) {
        AyuStorage.async { [self] in
            ensureLoaded()
            let priorPayload = payload
            payload.deletedMessages.removeAll { $0.accountId == accountPeerId }
            payload.editedRevisions.removeAll { $0.accountId == accountPeerId }
            guard saveLocked() else {
                payload = priorPayload
                return
            }
            AyuStorage.removeAttachments(accountId: accountPeerId)
            var pending = loadPendingCapturesLocked()
            pending.removeAll { $0.message.accountId == accountPeerId }
            _ = savePendingCapturesLocked(pending)
        }
    }

    // MARK: Private

    private func pendingIdentity(_ capture: AyuPendingMediaCapture) -> String {
        return "\(capture.message.accountId):\(capture.message.peerId):\(capture.message.messageId):\(capture.mediaIndex)"
    }

    private func removePendingCaptureLocked(_ capture: AyuPendingMediaCapture) {
        var captures = loadPendingCapturesLocked()
        let identity = pendingIdentity(capture)
        let originalCount = captures.count
        captures.removeAll {
            pendingIdentity($0) == identity && $0.generationId == capture.generationId
        }
        if captures.count != originalCount {
            _ = savePendingCapturesLocked(captures)
        }
    }

    private func isCurrentPendingCaptureLocked(_ capture: AyuPendingMediaCapture) -> Bool {
        let identity = pendingIdentity(capture)
        return loadPendingCapturesLocked().contains {
            pendingIdentity($0) == identity && $0.generationId == capture.generationId
        }
    }

    private func prunePendingCaptures(_ captures: [AyuPendingMediaCapture]) -> [AyuPendingMediaCapture] {
        let cutoff = Int64(Date().timeIntervalSince1970) - AyuMessageStore.maxPendingAge
        return Array(captures.filter { $0.createdAt >= cutoff }.sorted(by: { $0.createdAt < $1.createdAt }).suffix(AyuMessageStore.maxPendingCaptures))
    }

    private func loadPendingCapturesLocked() -> [AyuPendingMediaCapture] {
        guard let values = try? AyuStorage.pendingCapturesPathURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, size <= 16 * 1024 * 1024,
              let data = try? Data(contentsOf: AyuStorage.pendingCapturesPathURL),
              let captures = try? JSONDecoder().decode([AyuPendingMediaCapture].self, from: data) else {
            return []
        }
        return captures.filter {
            $0.message.accountId != 0 && $0.message.peerId != 0 && $0.message.messageId > 0 &&
            $0.message.media.isEmpty && $0.mediaIndex >= 0 &&
            $0.fileMetadata.count <= AyuMessageStore.maxMetadataBytes &&
            ($0.expectedSize == nil || ($0.expectedSize! > 0 && $0.expectedSize! <= Int64.max / 2))
        }
    }

    private func savePendingCapturesLocked(_ captures: [AyuPendingMediaCapture]) -> Bool {
        do {
            let data = try JSONEncoder().encode(prunePendingCaptures(captures))
            guard data.count <= 16 * 1024 * 1024 else { return false }
            try data.write(to: AyuStorage.pendingCapturesURL, options: [.atomic])
            return true
        } catch {
            SGLogger.shared.log("AyuGram", "Pending capture write failed: \(error)")
            return false
        }
    }

    private func verifiedMediaQuality(_ media: AyuSavedMedia) -> (Int, Int64) {
        guard let url = AyuStorage.regularAttachmentFileURL(relativePath: media.relativePath),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let actualSize = values.fileSize, actualSize > 0 else {
            return (0, 0)
        }
        if let expectedSize = media.size, expectedSize != Int64(actualSize) {
            return (0, 0)
        }
        return (1, Int64(actualSize))
    }

    /// Merge corresponding media roles independently. This preserves an earlier
    /// complete role when a later expiry callback contains only a placeholder,
    /// while still accepting a newly completed role from a partial recapture.
    private func mergedCapture(new: AyuSavedMessage, old: AyuSavedMessage) -> AyuSavedMessage {
        var oldByRole: [String: [AyuSavedMedia]] = [:]
        var newRoleOffsets: [String: Int] = [:]
        for item in old.media { oldByRole[item.kind.rawValue, default: []].append(item) }
        var media: [AyuSavedMedia] = []
        for item in new.media {
            let role = item.kind.rawValue
            let offset = newRoleOffsets[role, default: 0]
            newRoleOffsets[role] = offset + 1
            if let prior = oldByRole[role], offset < prior.count,
               verifiedMediaQuality(prior[offset]) > verifiedMediaQuality(item) {
                media.append(prior[offset])
            } else {
                media.append(item)
            }
        }
        for (role, prior) in oldByRole {
            media.append(contentsOf: prior.dropFirst(newRoleOffsets[role, default: 0]).filter { verifiedMediaQuality($0).0 > 0 })
        }
        var associatedById: [String: AyuSavedAssociatedMedia] = [:]
        for item in old.associatedMedia {
            associatedById["\(item.namespace):\(item.id)"] = item
        }
        for item in new.associatedMedia {
            let key = "\(item.namespace):\(item.id)"
            if let prior = associatedById[key],
               verifiedAssociatedMediaQuality(prior) > verifiedAssociatedMediaQuality(item) {
                continue
            }
            associatedById[key] = item
        }
        return AyuSavedMessage(accountId: new.accountId, peerId: new.peerId, messageId: new.messageId,
            threadId: new.threadId, globallyUniqueId: new.globallyUniqueId, authorId: new.authorId,
            date: new.date, editDate: new.editDate, text: new.text, media: media, flags: new.flags,
            effectiveCopyProtected: new.effectiveCopyProtected == true || old.effectiveCopyProtected == true ? true : new.effectiveCopyProtected,
            textEntitiesAttribute: new.textEntitiesAttribute, authorPeer: new.authorPeer,
            associatedMedia: Array(associatedById.values), savedAt: new.savedAt)
    }

    private func verifiedAssociatedMediaQuality(_ media: AyuSavedAssociatedMedia) -> Int {
        guard let path = media.relativePath,
              AyuStorage.regularAttachmentFileURL(relativePath: path) != nil else {
            return 0
        }
        return 1
    }

    private func validate(_ payload: AyuStorePayload) -> Bool {
        guard payload.deletedMessages.count <= 500_000, payload.editedRevisions.count <= 500_000 else { return false }
        for message in payload.deletedMessages {
            guard message.messageId > 0, message.media.count <= 32, message.associatedMedia.count <= 64,
                  message.text.utf8.count <= 4 * 1024 * 1024,
                  message.textEntitiesAttribute?.count ?? 0 <= AyuMessageStore.maxMetadataBytes,
                  message.authorPeer?.count ?? 0 <= AyuMessageStore.maxMetadataBytes else { return false }
            for media in message.media {
                guard media.nativeMetadata?.count ?? 0 <= AyuMessageStore.maxMetadataBytes,
                       media.size == nil || (media.size! > 0 && media.size! <= Int64.max / 2) else { return false }
            }
            for media in message.associatedMedia {
                guard media.nativeMetadata.count <= AyuMessageStore.maxMetadataBytes else { return false }
            }
        }
        return true
    }

    /// Migrates safe legacy unscoped files when this record supplies ownership.
    /// Invalid/missing attachment paths affect only that attachment; message
    /// text and other metadata remain available.
    private func normalizeAttachmentPaths(_ input: AyuStorePayload) -> (payload: AyuStorePayload, changed: Bool) {
        var changed = false
        let messages = input.deletedMessages.map { message -> AyuSavedMessage in
            let media = message.media.compactMap { item -> AyuSavedMedia? in
                guard let path = normalizedAttachmentPath(item.relativePath, accountId: message.accountId, peerId: message.peerId, messageId: message.messageId) else {
                    changed = true
                    return nil
                }
                if path != item.relativePath { changed = true }
                return AyuSavedMedia(kind: item.kind, fileName: item.fileName, mimeType: item.mimeType, size: item.size, width: item.width, height: item.height, relativePath: path, nativeMetadata: item.nativeMetadata)
            }
            let associated = message.associatedMedia.map { item -> AyuSavedAssociatedMedia in
                guard let oldPath = item.relativePath else { return item }
                guard let path = normalizedAttachmentPath(oldPath, accountId: message.accountId, peerId: message.peerId, messageId: message.messageId) else {
                    changed = true
                    return AyuSavedAssociatedMedia(namespace: item.namespace, id: item.id, nativeMetadata: item.nativeMetadata, relativePath: nil)
                }
                if path != oldPath { changed = true }
                return AyuSavedAssociatedMedia(namespace: item.namespace, id: item.id, nativeMetadata: item.nativeMetadata, relativePath: path)
            }
            return AyuSavedMessage(accountId: message.accountId, peerId: message.peerId, messageId: message.messageId, threadId: message.threadId, globallyUniqueId: message.globallyUniqueId, authorId: message.authorId, date: message.date, editDate: message.editDate, text: message.text, media: media, flags: message.flags, effectiveCopyProtected: message.effectiveCopyProtected, textEntitiesAttribute: message.textEntitiesAttribute, authorPeer: message.authorPeer, associatedMedia: associated, savedAt: message.savedAt)
        }
        return (AyuStorePayload(deletedMessages: messages, editedRevisions: input.editedRevisions), changed)
    }

    private func normalizedAttachmentPath(_ path: String, accountId: Int64, peerId: Int64, messageId: Int32) -> String? {
        if AyuStorage.attachmentFileURL(relativePath: path, accountId: accountId, peerId: peerId) != nil {
            guard AyuStorage.regularAttachmentFileURL(relativePath: path) != nil else { return nil }
            return path
        }
        guard let legacyURL = AyuStorage.regularAttachmentFileURL(relativePath: path) else { return nil }
        let pathHash = path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { value, byte in
            (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let pathExtension = legacyURL.pathExtension
        let migratedName = "legacy-\(messageId)-\(String(pathHash, radix: 16))" + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
        let destination = AyuStorage.attachmentDestinationURL(accountId: accountId, peerId: peerId, fileName: migratedName)
        if FileManager.default.fileExists(atPath: destination.url.path) {
            guard AyuStorage.regularAttachmentFileURL(relativePath: destination.relativePath) != nil else { return nil }
        } else {
            do {
                try FileManager.default.copyItem(at: legacyURL, to: destination.url)
            } catch {
                SGLogger.shared.log("AyuGram", "Legacy attachment migration failed: \(error)")
                return nil
            }
        }
        return destination.relativePath
    }

    private func removeAttachmentFilesLocked(for message: AyuSavedMessage, excluding retainedPaths: Set<String> = []) {
        for media in message.media where !retainedPaths.contains(media.relativePath) {
            AyuStorage.removeAttachment(relativePath: media.relativePath)
        }
        for media in message.associatedMedia {
            if let path = media.relativePath, !retainedPaths.contains(path) {
                AyuStorage.removeAttachment(relativePath: path)
            }
        }
    }

    private func attachmentPaths(in payload: AyuStorePayload) -> Set<String> {
        return Set(payload.deletedMessages.flatMap { message in
            message.media.map(\.relativePath) + message.associatedMedia.compactMap(\.relativePath)
        })
    }

    private func pruneDeletedLocked() -> [AyuSavedMessage] {
        var grouped: [String: [AyuSavedMessage]] = [:]
        for message in payload.deletedMessages {
            grouped["\(message.accountId):\(message.peerId)", default: []].append(message)
        }
        var retained: [AyuSavedMessage] = []
        var droppedMessages: [AyuSavedMessage] = []
        for messages in grouped.values {
            let sorted = messages.sorted(by: { $0.savedAt < $1.savedAt })
            let kept = sorted.suffix(AyuMessageStore.maxMessagesPerPeer)
            droppedMessages.append(contentsOf: sorted.prefix(sorted.count - kept.count))
            retained.append(contentsOf: kept)
        }
        payload.deletedMessages = retained
        return droppedMessages
    }

    private func pruneRevisionsLocked() {
        var grouped: [String: [AyuMessageRevision]] = [:]
        for revision in payload.editedRevisions {
            grouped["\(revision.accountId):\(revision.peerId)", default: []].append(revision)
        }
        payload.editedRevisions = grouped.values.flatMap {
            $0.sorted(by: { $0.capturedAt < $1.capturedAt }).suffix(AyuMessageStore.maxMessagesPerPeer)
        }
    }
}
