import Foundation
import Wrap
import SGLogging
import SGStrings
import ChatControllerInteraction
import ChatPresentationInterfaceState
import Postbox
import TelegramCore
import AccountContext

private func formatPeerIdForDetails(_ peerId: PeerId) -> String {
    let int64 = peerId.id._internalGetInt64Value()
    if peerId.namespace == Namespaces.Peer.CloudUser {
        return "\(int64)"
    } else if peerId.namespace == Namespaces.Peer.CloudGroup {
        return "-\(int64)"
    } else {
        return "-100\(int64)"
    }
}

private func formatDetailsDuration(_ duration: Double) -> String {
    let totalSeconds = Int(duration.rounded())
    if totalSeconds >= 3600 {
        return String(format: "%d:%02d:%02d", totalSeconds / 3600, (totalSeconds % 3600) / 60, totalSeconds % 60)
    } else {
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

public func showMessageDetails(controllerInteraction: ChatControllerInteraction, chatPresentationInterfaceState: ChatPresentationInterfaceState, message: Message, context: AccountContext) {
    if let navigationController = controllerInteraction.navigationController(), let rootController = navigationController.view.window?.rootViewController {
        let locale = chatPresentationInterfaceState.strings.baseLanguageCode
        
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: locale)
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        
        var lines: [String] = []
        lines.append("AyuGram.MessageDetails.Title".i18n(locale))
        lines.append("")
        lines.append("AyuGram.MessageDetails.MessageId".i18n(locale) + ": \(message.id.id)")
        lines.append("AyuGram.MessageDetails.PeerId".i18n(locale) + ": " + formatPeerIdForDetails(message.id.peerId))
        
        if let author = message.author {
            lines.append("AyuGram.MessageDetails.SenderId".i18n(locale) + ": " + formatPeerIdForDetails(author.id))
        }
        
        lines.append("AyuGram.MessageDetails.Date".i18n(locale) + ": " + dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(message.timestamp))))
        
        if let editedTime = message.editedTime {
            lines.append("AyuGram.MessageDetails.EditDate".i18n(locale) + ": " + dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(editedTime))))
        }
        
        for media in message.media {
            if let file = media as? TelegramMediaFile {
                if let fileSize = file.size {
                    lines.append("AyuGram.MessageDetails.FileSize".i18n(locale) + ": " + ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
                }
                lines.append("AyuGram.MessageDetails.MimeType".i18n(locale) + ": " + file.mimeType)
                for attribute in file.attributes {
                    switch attribute {
                    case let .FileName(fileName):
                        lines.append("AyuGram.MessageDetails.FileName".i18n(locale) + ": " + fileName)
                    case let .Video(duration, size, _, _, _, _):
                        lines.append("AyuGram.MessageDetails.Resolution".i18n(locale) + ": \(size.width)×\(size.height)")
                        lines.append("AyuGram.MessageDetails.Duration".i18n(locale) + ": " + formatDetailsDuration(duration))
                    case let .Audio(_, duration, _, _, _):
                        lines.append("AyuGram.MessageDetails.Duration".i18n(locale) + ": " + formatDetailsDuration(Double(duration)))
                    default:
                        break
                    }
                }
            } else if let image = media as? TelegramMediaImage {
                if let representation = image.representations.max(by: { $0.dimensions.width * $0.dimensions.height < $1.dimensions.width * $1.dimensions.height }) {
                    lines.append("AyuGram.MessageDetails.Resolution".i18n(locale) + ": \(representation.dimensions.width)×\(representation.dimensions.height)")
                }
            }
        }
        
        guard let detailsData = lines.joined(separator: "\n").data(using: .utf8) else { return }
        
        let id = Int64.random(in: Int64.min ... Int64.max)
        let fileResource = LocalFileMediaResource(fileId: id, size: Int64(detailsData.count), isSecretRelated: false)
        context.account.postbox.mediaBox.storeResourceData(fileResource.id, data: detailsData, synchronous: true)
        
        let file = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: id), partialReference: nil, resource: fileResource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "text/plain", size: Int64(detailsData.count), attributes: [.FileName(fileName: "message-details.txt")], alternativeRepresentations: [])
        
        presentDocumentPreviewController(rootController: rootController, theme: chatPresentationInterfaceState.theme, strings: chatPresentationInterfaceState.strings, postbox: context.account.postbox, file: file, canShare: !message.isCopyProtected())
    }
}

public func showMessageJson(controllerInteraction: ChatControllerInteraction, chatPresentationInterfaceState: ChatPresentationInterfaceState, message: Message, context: AccountContext) {
    if let navigationController = controllerInteraction.navigationController(), let rootController = navigationController.view.window?.rootViewController {
        var writingOptions: JSONSerialization.WritingOptions = [
            .prettyPrinted,
            //.sortedKeys,
        ]
        if #available(iOS 13.0, *) {
            writingOptions.insert(.withoutEscapingSlashes)
        }
        
        var messageData: Data? = nil
        do {
            messageData = try wrap(
                message,
                writingOptions: writingOptions
            )
        } catch {
            SGLogger.shared.log("ShowMessageJSON", "Error parsing data: \(error)")
            messageData = nil
        }
        
        guard let messageData = messageData else { return }
        
        let id = Int64.random(in: Int64.min ... Int64.max)
        let fileResource = LocalFileMediaResource(fileId: id, size: Int64(messageData.count), isSecretRelated: false)
        context.account.postbox.mediaBox.storeResourceData(fileResource.id, data: messageData, synchronous: true)
        
        let file = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: id), partialReference: nil, resource: fileResource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "application/json; charset=utf-8", size: Int64(messageData.count), attributes: [.FileName(fileName: "message.json")], alternativeRepresentations: [])
        
        presentDocumentPreviewController(rootController: rootController, theme: chatPresentationInterfaceState.theme, strings: chatPresentationInterfaceState.strings, postbox: context.account.postbox, file: file, canShare: !message.isCopyProtected())
        
    }
}

extension MemoryBuffer: @retroactive WrapCustomizable {
    
    public func wrap(context: Any?, dateFormatter: DateFormatter?) -> Any? {
        let hexString = self.description
        return ["string": hexStringToString(hexString) ?? hexString]
    }
}

// There's a chacne we will need it for each empty/weird type, or it will be a runtime crash.
extension ContentRequiresValidationMessageAttribute: @retroactive WrapCustomizable {
    
    public func wrap(context: Any?, dateFormatter: DateFormatter?) -> Any? {
        return ["@type": "ContentRequiresValidationMessageAttribute"]
    }
}

func hexStringToString(_ hexString: String) -> String? {
    var chars = Array(hexString)
    var result = ""

    while chars.count > 0 {
        let c = String(chars[0...1])
        chars = Array(chars.dropFirst(2))
        if let byte = UInt8(c, radix: 16) {
            let scalar = UnicodeScalar(byte)
            result.append(String(scalar))
        } else {
            return nil
        }
    }

    return result
}
