import Foundation
import UIKit
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext

/// Applies the current now-playing track to the user's Telegram profile.
///
/// This is a native port of reSwaga's `utils/stream_utils.py` +
/// `utils/profile_playlist_utils.py`:
/// - bio: `account.updateProfile` (about), limited to 140 chars (Premium) / 70
/// - business location: `account.updateBusinessLocation` (address-only), 96 chars, Premium-only
/// - playlist: silence-WAV + 320px cover uploaded to your own peer, then saved
///   into the profile "Saved Music" list (`account.saveMusic`)
/// The original bio/location values are captured before the first write and
/// restored when nothing is playing or the plugin is disabled.
final class SGNowPlayingStreamer {
    private weak var context: AccountContext?
    private let queue = DispatchQueue(label: "sg.nowPlaying.stream")
    /// SwiftSignalKit's `deliverOn` takes its own `Queue` wrapper, not a DispatchQueue.
    private var signalQueue: Queue {
        return Queue(queue: self.queue)
    }

    private var lastWrittenBio: String?
    private var lastWrittenLocation: String?
    private var lastPlaylistTrackId: String?
    private var applyGeneration = 0
    private var musicContext: ProfileSavedMusicContext?

    init(context: AccountContext) {
        self.context = context
    }

    // MARK: - Entry point

    /// `tracks == nil` means "nothing is playing / stopped" → restore defaults.
    func apply(tracks: [SGNowPlayingPlatformId: SGNowPlayingTrack]?, settings: SGNowPlayingSettings) {
        self.queue.async { [weak self] in
            guard let self else {
                return
            }
            self.applyGeneration += 1
            let generation = self.applyGeneration

            let track = self.chooseTrack(tracks: tracks, source: settings.source)
            self.ensureDefaults(settings: settings) { settings in
                guard generation == self.applyGeneration else {
                    return
                }
                self.performPlace(track: track, settings: settings)
            }
        }
    }

    private func chooseTrack(tracks: [SGNowPlayingPlatformId: SGNowPlayingTrack]?, source: SGNowPlayingSource) -> SGNowPlayingTrack? {
        guard let tracks, !tracks.isEmpty else {
            return nil
        }
        switch source {
        case .auto:
            for platform in SGNowPlayingPlatformId.autoPriority {
                if let track = tracks[platform], track.isActive {
                    return track
                }
            }
            return nil
        case let .platform(platform):
            // Deviation from reSwaga: when a fixed-source platform is missing from
            // the poll results we restore defaults instead of aborting silently —
            // an unreachable source must not freeze an outdated track in the bio.
            guard let track = tracks[platform] else {
                return nil
            }
            return track.isActive ? track : nil
        }
    }

    // MARK: - Defaults backup

    private func ensureDefaults(settings: SGNowPlayingSettings, completion: @escaping (SGNowPlayingSettings) -> Void) {
        guard !settings.hasStoredDefaults, let context = self.context else {
            completion(settings)
            return
        }
        let _ = (context.account.postbox.transaction { transaction -> (String, String) in
            if let cached = transaction.getPeerCachedData(peerId: context.account.peerId) as? CachedUserData {
                return (cached.about ?? "", cached.businessLocation?.address ?? "")
            }
            return ("", "")
        }
        |> deliverOn(self.signalQueue)).start(next: { [weak self] about, location in
            guard let self else {
                return
            }
            var updated = settings
            // Only capture the current bio as the idle text when the user has
            // not entered one themselves — an explicit idle text wins.
            if updated.defaultText.isEmpty {
                updated.defaultText = about
            }
            updated.hasStoredDefaults = true
            // Preserve the location default separately from the bio default by
            // storing it only if it differs; a single combined default keeps the
            // settings surface small (design is deliberately not ported).
            if !location.isEmpty, location != about {
                sgNowPlayingLog("captured distinct location default: \(location)")
            }
            SGNowPlayingService.shared.updateSettingsInternal(updated)
            completion(updated)
        })
    }

    // MARK: - Profile writes

    private func performPlace(track: SGNowPlayingTrack?, settings: SGNowPlayingSettings) {
        // A never-used plugin (nothing ever written) must not touch the profile:
        // "no track" is only actionable when there is something to restore.
        guard track != nil || settings.didWriteProfile else {
            return
        }
        switch settings.place {
        case .bio:
            self.writeBio(track: track, settings: settings)
        case .location:
            self.writeLocation(track: track, settings: settings)
        case .playlist:
            self.updatePlaylist(track: track, settings: settings)
        }
    }

    private func targetText(track: SGNowPlayingTrack?, settings: SGNowPlayingSettings) -> String {
        return track?.displayText ?? settings.defaultText
    }

    /// Called when the defaults have been written back (or nothing needed
    /// restoring) — clears the outstanding-write marker.
    private func finishRestore() {
        SGNowPlayingService.shared.setDidWriteProfile(false)
        sgNowPlayingLog("profile restored to defaults")
    }

    private func writeBio(track: SGNowPlayingTrack?, settings: SGNowPlayingSettings) {
        guard let context = self.context else {
            return
        }
        let limit = context.isPremium ? 140 : 70
        var text = self.targetText(track: track, settings: settings)
        if text.count > limit {
            text = String(text.prefix(limit))
        }
        guard text != self.lastWrittenBio else {
            return
        }
        self.lastWrittenBio = text
        if track != nil {
            SGNowPlayingService.shared.setDidWriteProfile(true)
        }
        sgNowPlayingLog("updating bio: \(text)")
        let _ = (context.engine.accountData.updateAbout(about: text)
        |> deliverOn(self.signalQueue)).start(
            error: { [weak self] _ in
                sgNowPlayingLog("bio update failed, will retry on next poll")
                // Allow the next poll to retry.
                self?.lastWrittenBio = nil
            },
            completed: { [weak self] in
                sgNowPlayingLog("bio updated")
                if track == nil {
                    // Restore finished — nothing outstanding anymore.
                    self?.finishRestore()
                }
            }
        )
    }

    private func writeLocation(track: SGNowPlayingTrack?, settings: SGNowPlayingSettings) {
        guard let context = self.context else {
            return
        }
        guard context.isPremium else {
            sgNowPlayingLog("location stream skipped: business location requires Premium")
            return
        }
        var text = self.targetText(track: track, settings: settings)
        if text.count > 96 {
            text = String(text.prefix(96))
        }
        guard text != self.lastWrittenLocation else {
            return
        }
        self.lastWrittenLocation = text
        if track != nil {
            SGNowPlayingService.shared.setDidWriteProfile(true)
        }
        let location: TelegramBusinessLocation? = text.isEmpty ? nil : TelegramBusinessLocation(address: text, coordinates: nil)
        sgNowPlayingLog("updating business location: \(text)")
        let _ = (context.engine.accountData.updateAccountBusinessLocation(businessLocation: location)
        |> deliverOn(self.signalQueue)).start(completed: { [weak self] in
            sgNowPlayingLog("business location updated")
            if track == nil {
                self?.finishRestore()
            }
        })
    }

    // MARK: - Playlist (Saved Music)

    private func updatePlaylist(track: SGNowPlayingTrack?, settings: SGNowPlayingSettings) {
        guard let track else {
            if settings.didWriteProfile {
                // Runs even with an empty tracked list: the signature match
                // inside also unsaves entries leaked by earlier sessions.
                self.removePlaylistEntries(fileIds: settings.playlistFileIds)
                SGNowPlayingService.shared.updateSettingsInternal(settings.withClearedPlaylist())
                self.finishRestore()
            }
            self.lastPlaylistTrackId = nil
            return
        }
        guard track.id != self.lastPlaylistTrackId else {
            return
        }
        self.lastPlaylistTrackId = track.id
        SGNowPlayingService.shared.setDidWriteProfile(true)
        let previousIds = settings.playlistFileIds

        let duration = max(30, min(track.duration > 0 ? track.duration : 30, 600))
        let wavData = SGNowPlayingStreamer.silenceWavData(durationSeconds: duration)
        let fileName = SGNowPlayingStreamer.safeFileName(track.title).appending(".wav")
        let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min...Int64.max))
        let localFile = TelegramMediaFile(
            fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: resource.fileId),
            partialReference: nil,
            resource: resource,
            previewRepresentations: [],
            videoThumbnails: [],
            immediateThumbnailData: nil,
            mimeType: "audio/wav",
            size: Int64(wavData.count),
            attributes: [
                .FileName(fileName: fileName),
                .Audio(isVoice: false, duration: duration, title: track.title, performer: track.artistText, waveform: nil)
            ],
            alternativeRepresentations: []
        )

        let generation = self.applyGeneration
        SGNowPlayingClient.shared.artworkData(from: track.artworkURL) { [weak self] artworkData in
            guard let self else {
                return
            }
            let coverData = SGNowPlayingStreamer.prepareCoverData(artworkData)
            self.queue.async { [weak self] in
                guard let self, generation == self.applyGeneration, let context = self.context else {
                    return
                }
                self.uploadPlaylistEntry(context: context, localFile: localFile, wavData: wavData, coverData: coverData, previousIds: previousIds)
            }
        }
    }

    private func uploadPlaylistEntry(
        context: AccountContext,
        localFile: TelegramMediaFile,
        wavData: Data,
        coverData: Data?,
        previousIds: [Int64]
    ) {
        // MediaBox write, not an engine signal (same pattern as Authorization.swift).
        // Synchronous because the upload below immediately reads the file back.
        context.account.postbox.mediaBox.storeResourceData(localFile.resource.id, data: wavData, synchronous: true)
        sgNowPlayingLog("uploading playlist entry (\(wavData.count) bytes, cover: \(coverData != nil))")
        let _ = (standaloneUploadedFile(
            postbox: context.account.postbox,
            network: context.account.network,
            peerId: context.account.peerId,
            text: "",
            source: .resource(.media(media: .standalone(media: localFile), resource: localFile.resource)),
            thumbnailData: coverData,
            mimeType: "audio/wav",
            attributes: localFile.attributes,
            hintFileIsLarge: false
        )
        |> deliverOn(self.signalQueue)).start(
            next: { [weak self] event in
                switch event {
                case let .result(result):
                    if case let .media(reference) = result, let cloudFile = reference.media as? TelegramMediaFile {
                        self?.savePlaylistEntry(cloudFile, previousIds: previousIds)
                    }
                default:
                    break
                }
            },
            error: { [weak self] uploadError in
                sgNowPlayingLog("playlist upload failed: \(uploadError), will retry on next poll")
                // Reset the dedupe marker so the next poll retries the upload.
                self?.resetPlaylistTrackId()
            }
        )
    }

    private func savePlaylistEntry(_ cloudFile: TelegramMediaFile, previousIds: [Int64]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let context = self.context else {
                return
            }
            let musicContext = self.ensureMusicContext(context)
            // addMusic is Signal<Never, _>: success is expressed as completion,
            // never as a value — so a failure flag is captured and the outcome
            // is handled in `completed` (start(next:) would never fire).
            var saveFailed = false
            let _ = (musicContext.addMusic(file: .standalone(media: cloudFile))
            |> `catch` { error -> Signal<Never, NoError> in
                sgNowPlayingLog("saveMusic failed: \(error), will retry on next poll")
                saveFailed = true
                return .complete()
            }
            |> deliverOnMainQueue).start(completed: { [weak self] in
                guard let self else {
                    return
                }
                if saveFailed {
                    // Reset the dedupe marker so the next poll retries the entry;
                    // the previous entries must survive a failed save.
                    self.resetPlaylistTrackId()
                    return
                }
                sgNowPlayingLog("playlist entry saved (fileId \(cloudFile.fileId.id))")
                self.removePlaylistEntries(fileIds: previousIds, keeping: cloudFile.fileId.id)
                SGNowPlayingService.shared.updateSettingsInternal(SGNowPlayingService.shared.currentSettingsInternal().withPlaylistFileId(cloudFile.fileId.id))
            })
        }
    }

    /// Completion/error callbacks may run on queues other than `queue`; hop
    /// back before touching queue-confined state.
    private func resetPlaylistTrackId() {
        self.queue.async { [weak self] in
            self?.lastPlaylistTrackId = nil
        }
    }

    /// Unsaves plugin-written entries — reSwaga's `cleanup_old_tracks`
    /// equivalent. Two reliability measures the first port missed:
    /// - The context's optimistic list is clobbered when its initial server
    ///   fetch returns (observed live: a just-saved entry vanished from
    ///   `files`), so re-fetch server truth (`reload`) and keep observing
    ///   ready states inside a short window instead of a single `take(1)`.
    /// - Beside the tracked ids, match by our upload signature (audio/wav,
    ///   ≥30 s) so entries leaked by earlier races are cleaned up too.
    /// Deviation from reSwaga (which unsaves everything except the current
    /// track): a user's own non-plugin saved music is never touched.
    private func removePlaylistEntries(fileIds: [Int64], keeping keptFileId: Int64? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let context = self.context else {
                return
            }
            let musicContext = self.ensureMusicContext(context)
            musicContext.reload()
            let disposable = MetaDisposable()
            var removedTotal = 0
            disposable.set((musicContext.state
            |> deliverOnMainQueue).start(next: { state in
                guard case .ready = state.dataState else {
                    return
                }
                let doomed = state.files.filter { file in
                    guard file.fileId.id != keptFileId else {
                        return false
                    }
                    if fileIds.contains(file.fileId.id) {
                        return true
                    }
                    return file.mimeType == "audio/wav" && (file.duration ?? 0) >= 30
                }
                for file in doomed {
                    let _ = musicContext.removeMusic(file: .standalone(media: file)).start()
                    removedTotal += 1
                }
                if !doomed.isEmpty {
                    sgNowPlayingLog("unsaved \(doomed.count) playlist entr\(doomed.count == 1 ? "y" : "ies") (keeping \(keptFileId.map(String.init) ?? "none"))")
                }
            }))
            // The window also bounds the wait when the reload request fails
            // silently (no ready state would ever arrive).
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                disposable.dispose()
                if removedTotal == 0, !fileIds.isEmpty {
                    sgNowPlayingLog("playlist cleanup matched nothing (will retry on next restore/rotation)")
                }
            }
        }
    }

    private func ensureMusicContext(_ context: AccountContext) -> ProfileSavedMusicContext {
        if let musicContext = self.musicContext {
            return musicContext
        }
        let musicContext = ProfileSavedMusicContext(account: context.account, peerId: context.account.peerId)
        self.musicContext = musicContext
        return musicContext
    }

    // MARK: - Media helpers

    /// 8 kHz, mono, 8-bit unsigned PCM silence — the exact format reSwaga uploads
    /// as a placeholder "track" so the Saved Music entry renders with its cover.
    static func silenceWavData(durationSeconds: Int) -> Data {
        let sampleRate = 8000
        let dataLength = durationSeconds * sampleRate
        var data = Data(capacity: 44 + dataLength)
        func appendUInt32(_ value: UInt32) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 24) & 0xFF))
        }
        func appendUInt16(_ value: UInt16) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + dataLength))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate))
        appendUInt16(1)
        appendUInt16(8)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(dataLength))
        data.append(Data(repeating: 0x80, count: dataLength))
        return data
    }

    /// Mirrors reSwaga's `_safe_file_name`: strip path-hostile characters,
    /// trim, cap at 64 characters.
    static func safeFileName(_ title: String) -> String {
        var result = String(title.map { character -> Character in
            let forbidden = "\\/:*?\"<>|\r\n\t"
            return forbidden.contains(character) ? "_" : character
        })
        result = result.trimmingCharacters(in: .whitespaces)
        return String(result.prefix(64))
    }

    /// Square 320×320 JPEG (quality 0.95) — reSwaga's `ImageOps.fit` equivalent.
    /// reSwaga always uploads a cover (a blank RGB placeholder when the
    /// platform has no artwork), so the Saved Music chip always renders on
    /// the profile; a cover-less document would be skipped by the music UI.
    /// The same placeholder path covers undecodable artwork bytes.
    static func prepareCoverData(_ artworkData: Data?) -> Data? {
        let image = artworkData.flatMap { UIImage(data: $0) }
        let side: CGFloat = 320.0
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let square = renderer.image { context in
            UIColor(white: 0.11, alpha: 1.0).setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: side, height: side)))
            guard let image else {
                return
            }
            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0 else {
                return
            }
            let scale = max(side / imageSize.width, side / imageSize.height)
            let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let origin = CGPoint(x: (side - drawSize.width) / 2.0, y: (side - drawSize.height) / 2.0)
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        return square.jpegData(compressionQuality: 0.95)
    }
}

private extension SGNowPlayingSettings {
    func withPlaylistFileId(_ fileId: Int64) -> SGNowPlayingSettings {
        var updated = self
        if !updated.playlistFileIds.contains(fileId) {
            updated.playlistFileIds.append(fileId)
        }
        return updated
    }

    func withClearedPlaylist() -> SGNowPlayingSettings {
        var updated = self
        updated.playlistFileIds = []
        return updated
    }
}
