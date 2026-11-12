import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import Postbox
import TelegramPresentationData
import PresentationDataUtils
import AccountContext
import ShareController
import SGStrings

/// How the current track is handed over to a chat — reSwaga's SEND_MODE_*.
public enum SGNowPlayingSendMode {
    case card
    case audioFile
    case text
}

/// The attach-menu "Now Playing" flow: an action sheet with the three send
/// modes for the current chat plus "Share to...", backed by the native
/// ShareController for multi-chat delivery (reSwaga's send_to_bottom_sheet
/// role). Shows "Nothing is playing" when the plugin has no active track.
public enum SGNowPlayingSendMenu {

    public static func present(
        context: AccountContext,
        sendToCurrentChat: @escaping ([EnqueueMessage]) -> Void,
        presentInWindow: @escaping (ViewController) -> Void
    ) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode

        guard let track = SGNowPlayingService.shared.currentTrack else {
            presentInWindow(textAlertController(
                context: context,
                title: i18n("ReqGram.Plugin.NowPlaying", lang),
                text: i18n("ReqGram.Plugin.NowPlaying.Menu.NothingPlaying", lang),
                actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]
            ))
            return
        }

        let sheet = ActionSheetController(presentationData: presentationData)
        let settings = SGNowPlayingService.shared.currentSettings()

        func perform(_ mode: SGNowPlayingSendMode, sheet: ActionSheetController?) {
            sheet?.dismissAnimated()
            Self.send(mode: mode, track: track, settings: settings, context: context, peerIds: nil, caption: nil, threadId: nil, completion: sendToCurrentChat)
        }

        let items: [ActionSheetItem] = [
            ActionSheetTextItem(title: "\(track.title)\n\(track.artistText)", parseMarkdown: false)
        ]
        let modeItems: [ActionSheetButtonItem] = [
            ActionSheetButtonItem(title: i18n("ReqGram.Plugin.NowPlaying.Menu.Card", lang), color: .accent, action: { perform(.card, sheet: sheet) }),
            ActionSheetButtonItem(title: i18n("ReqGram.Plugin.NowPlaying.Menu.AudioFile", lang), color: .accent, action: { perform(.audioFile, sheet: sheet) }),
            ActionSheetButtonItem(title: i18n("ReqGram.Plugin.NowPlaying.Menu.Text", lang), color: .accent, action: { perform(.text, sheet: sheet) })
        ]
        let shareItem = ActionSheetButtonItem(title: i18n("ReqGram.Plugin.NowPlaying.Menu.Share", lang), color: .accent, action: { [weak sheet] in
            sheet?.dismissAnimated()
            Self.presentSharePicker(track: track, settings: settings, context: context, presentInWindow: presentInWindow)
        })
        let cancelItem = ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, action: { [weak sheet] in
            sheet?.dismissAnimated()
        })
        sheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: modeItems),
            ActionSheetItemGroup(items: [shareItem]),
            ActionSheetItemGroup(items: [cancelItem])
        ])
        presentInWindow(sheet)
    }

    // MARK: - Share to many chats

    private static func presentSharePicker(
        track: SGNowPlayingTrack,
        settings: SGNowPlayingSettings,
        context: AccountContext,
        presentInWindow: @escaping (ViewController) -> Void
    ) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode

        // The native ShareController has no mode picker of its own, so the
        // mode is chosen first and the chat grid second (the original asks
        // inside its own bottom sheet — same outcome, different order).
        let sheet = ActionSheetController(presentationData: presentationData)
        func open(_ mode: SGNowPlayingSendMode) {
            let shareController = ShareController(
                context: context,
                subject: .fromExternal(1, { peerIds, topicIds, _, caption, _, _ in
                    Self.send(
                        mode: mode,
                        track: track,
                        settings: settings,
                        context: context,
                        peerIds: peerIds,
                        caption: caption,
                        threadId: nil,
                        topicIds: topicIds,
                        completion: nil
                    )
                    return .single(.done)
                }),
                externalShare: false
            )
            presentInWindow(shareController)
        }
        sheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: i18n("ReqGram.Plugin.NowPlaying.Menu.Card", lang), color: .accent, action: { [weak sheet] in sheet?.dismissAnimated(); open(.card) }),
                ActionSheetButtonItem(title: i18n("ReqGram.Plugin.NowPlaying.Menu.AudioFile", lang), color: .accent, action: { [weak sheet] in sheet?.dismissAnimated(); open(.audioFile) }),
                ActionSheetButtonItem(title: i18n("ReqGram.Plugin.NowPlaying.Menu.Text", lang), color: .accent, action: { [weak sheet] in sheet?.dismissAnimated(); open(.text) })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, action: { [weak sheet] in sheet?.dismissAnimated() })
            ])
        ])
        presentInWindow(sheet)
    }

    // MARK: - Message building

    /// Builds and delivers the mode's message(s). `peerIds == nil` means the
    /// current chat (delivered through `completion`); otherwise the messages
    /// are enqueued directly into each peer.
    private static func send(
        mode: SGNowPlayingSendMode,
        track: SGNowPlayingTrack,
        settings: SGNowPlayingSettings,
        context: AccountContext,
        peerIds: [PeerId]?,
        caption: String?,
        threadId: Int64?,
        topicIds: [EnginePeer.Id: Int64]? = nil,
        completion: (([EnqueueMessage]) -> Void)?
    ) {
        switch mode {
        case .text:
            var text = track.displayText
            if let caption, !caption.isEmpty {
                text = caption + "\n" + text
            }
            if let link = SGNowPlayingCard.trackLink(track: track, settings: settings) {
                text += "\n" + link
            }
            let message = EnqueueMessage.message(
                text: text,
                attributes: [],
                inlineStickers: [:],
                mediaReference: nil,
                threadId: threadId,
                replyToMessageId: nil,
                replyToStoryId: nil,
                localGroupingKey: nil,
                correlationId: nil,
                bubbleUpEmojiOrStickersets: []
            )
            deliver(message: message, peerIds: peerIds, topicIds: topicIds, context: context, completion: completion)
        case .audioFile:
            let duration = max(30, min(track.duration > 0 ? track.duration : 30, 600))
            sgNowPlayingLog("send audio: building wav, duration=\(duration)s")
            let wavData = SGNowPlayingStreamer.silenceWavData(durationSeconds: duration)
            sgNowPlayingLog("send audio: wav built, \(wavData.count) bytes")
            SGNowPlayingClient.shared.artworkData(from: track.artworkURL) { artworkData in
                sgNowPlayingLog("send audio: artwork fetched, \(artworkData?.count ?? 0) bytes")
                DispatchQueue.global(qos: .userInitiated).async {
                    let coverData = SGNowPlayingStreamer.prepareCoverData(artworkData)
                    sgNowPlayingLog("send audio: cover prepared, \(coverData?.count ?? 0) bytes")
                    let file = Self.audioFile(track: track, wavData: wavData, coverData: coverData, context: context)
                    sgNowPlayingLog("send audio: file built, id=\(file.fileId), size=\(file.size), previews=\(file.previewRepresentations.count)")
                    let message = EnqueueMessage.message(
                        text: "",
                        attributes: [],
                        inlineStickers: [:],
                        mediaReference: .standalone(media: file),
                        threadId: threadId,
                        replyToMessageId: nil,
                        replyToStoryId: nil,
                        localGroupingKey: nil,
                        correlationId: nil,
                        bubbleUpEmojiOrStickersets: []
                    )
                    DispatchQueue.main.async {
                        deliver(message: message, peerIds: peerIds, topicIds: topicIds, context: context, completion: completion)
                    }
                }
            }
        case .card:
            SGNowPlayingCard.render(track: track, settings: settings) { image in
                guard let image else {
                    sgNowPlayingLog("card render failed, nothing sent")
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let data = image.jpegData(compressionQuality: 0.95) else {
                        sgNowPlayingLog("card jpeg encode failed, nothing sent")
                        return
                    }
                    sgNowPlayingLog("send card: rendered \(Int(image.size.width))x\(Int(image.size.height)), jpeg \(data.count) bytes")
                    let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min...Int64.max), size: Int64(data.count), isSecretRelated: false)
                    context.account.postbox.mediaBox.storeResourceData(resource.id, data: data, synchronous: true)
                    let representation = TelegramMediaImageRepresentation(
                        dimensions: PixelDimensions(width: Int32(image.size.width), height: Int32(image.size.height)),
                        resource: resource,
                        progressiveSizes: [],
                        immediateThumbnailData: nil
                    )
                    // A <=100px thumbnail representation makes Swiftgram's outgoing media
                    // transform gate (smallest representation > 100px) evaluate to false, so
                    // the message media is never rewritten after the message becomes visible
                    // (no double transform, no post-display updateMedia/updateMessage churn —
                    // the churn is what caused visible artifacts on the card bubble).
                    var representations: [TelegramMediaImageRepresentation] = [representation]
                    let maxThumbnailSide: CGFloat = 100.0
                    let thumbnailScale = min(maxThumbnailSide / max(image.size.width, 1.0), maxThumbnailSide / max(image.size.height, 1.0), 1.0)
                    let thumbnailSize = CGSize(width: floor(image.size.width * thumbnailScale), height: floor(image.size.height * thumbnailScale))
                    if thumbnailSize.width >= 1.0 && thumbnailSize.height >= 1.0 {
                        let thumbnailImage = UIGraphicsImageRenderer(size: thumbnailSize).image { _ in
                            image.draw(in: CGRect(origin: .zero, size: thumbnailSize))
                        }
                        if let thumbnailData = thumbnailImage.jpegData(compressionQuality: 0.6) {
                            let thumbnailResource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min...Int64.max), size: Int64(thumbnailData.count), isSecretRelated: false)
                            context.account.postbox.mediaBox.storeResourceData(thumbnailResource.id, data: thumbnailData, synchronous: true)
                            representations.insert(TelegramMediaImageRepresentation(
                                dimensions: PixelDimensions(width: Int32(thumbnailSize.width), height: Int32(thumbnailSize.height)),
                                resource: thumbnailResource,
                                progressiveSizes: [],
                                immediateThumbnailData: nil
                            ), at: 0)
                            sgNowPlayingLog("send card: attached \(Int(thumbnailSize.width))x\(Int(thumbnailSize.height)) thumbnail rep to skip outgoing media transform")
                        }
                    }
                    let media = TelegramMediaImage(
                        imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: resource.fileId),
                        representations: representations,
                        immediateThumbnailData: nil,
                        reference: nil,
                        partialReference: nil,
                        flags: TelegramMediaImageFlags(rawValue: 0)
                    )
                    DispatchQueue.main.async {
                        let message = EnqueueMessage.message(
                            text: caption ?? "",
                            attributes: [],
                            inlineStickers: [:],
                            mediaReference: .standalone(media: media),
                            threadId: threadId,
                            replyToMessageId: nil,
                            replyToStoryId: nil,
                            localGroupingKey: nil,
                            correlationId: nil,
                            bubbleUpEmojiOrStickersets: []
                        )
                        deliver(message: message, peerIds: peerIds, topicIds: topicIds, context: context, completion: completion)
                    }
                }
            }
        }
    }

    /// Must be called off the main thread (synchronous mediaBox writes).
    private static func audioFile(track: SGNowPlayingTrack, wavData: Data, coverData: Data?, context: AccountContext) -> TelegramMediaFile {
        let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min...Int64.max), size: Int64(wavData.count), isSecretRelated: false)
        var previewRepresentations: [TelegramMediaImageRepresentation] = []
        if let coverData {
            let coverResource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min...Int64.max), size: Int64(coverData.count), isSecretRelated: false)
            context.account.postbox.mediaBox.storeResourceData(coverResource.id, data: coverData, synchronous: true)
            previewRepresentations.append(TelegramMediaImageRepresentation(
                dimensions: PixelDimensions(width: 320, height: 320),
                resource: coverResource,
                progressiveSizes: [],
                immediateThumbnailData: nil
            ))
        }
        context.account.postbox.mediaBox.storeResourceData(resource.id, data: wavData, synchronous: true)
        let fileName = SGNowPlayingStreamer.safeFileName(track.title).appending(".wav")
        let duration = max(30, min(track.duration > 0 ? track.duration : 30, 600))
        return TelegramMediaFile(
            fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: resource.fileId),
            partialReference: nil,
            resource: resource,
            previewRepresentations: previewRepresentations,
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
    }

    /// Central delivery: either forwards to the current chat (via the
    /// ChatController's send pipeline, which applies reply subjects /
    /// paid-message checks) or enqueues into every selected share peer
    /// directly. Must run on the main thread.
    private static func deliver(
        message: EnqueueMessage,
        peerIds: [PeerId]?,
        topicIds: [EnginePeer.Id: Int64]?,
        context: AccountContext,
        completion: (([EnqueueMessage]) -> Void)?
    ) {
        if let peerIds {
            sgNowPlayingLog("deliver: enqueueing to \(peerIds.count) share peers")
            for peerId in peerIds {
                var perPeerMessage = message
                if let topicIds, let topic = topicIds[peerId] {
                    perPeerMessage = withThreadId(message, topic)
                }
                let _ = enqueueMessages(account: context.account, peerId: peerId, messages: [perPeerMessage]).start()
            }
        } else {
            sgNowPlayingLog("deliver: handing to current chat pipeline")
            completion?([message])
        }
    }

    private static func withThreadId(_ message: EnqueueMessage, _ threadId: Int64) -> EnqueueMessage {
        guard case let .message(text, attributes, inlineStickers, mediaReference, _, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets) = message else {
            return message
        }
        return .message(
            text: text,
            attributes: attributes,
            inlineStickers: inlineStickers,
            mediaReference: mediaReference,
            threadId: threadId,
            replyToMessageId: replyToMessageId,
            replyToStoryId: replyToStoryId,
            localGroupingKey: localGroupingKey,
            correlationId: correlationId,
            bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets
        )
    }
}
