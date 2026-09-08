import Foundation
import AyuGram
import Postbox
import SwiftSignalKit
import Display
import UIKitRuntimeUtils
import TelegramPresentationData
import TelegramStringFormatting
import AccountContext
import ItemListUI
import SGStrings

private enum AyuSavedDeletedMessagesSection: Int32 {
    case messages
}

private struct AyuSavedDeletedMessageEntry: ItemListNodeEntry {
    let index: Int
    let message: AyuSavedMessage
    let title: String
    let languageCode: String

    var section: ItemListSectionId {
        return AyuSavedDeletedMessagesSection.messages.rawValue
    }

    var stableId: Int64 {
        return Int64(self.message.messageId)
    }

    static func ==(lhs: AyuSavedDeletedMessageEntry, rhs: AyuSavedDeletedMessageEntry) -> Bool {
        return lhs.index == rhs.index && lhs.message == rhs.message && lhs.title == rhs.title && lhs.languageCode == rhs.languageCode
    }

    static func <(lhs: AyuSavedDeletedMessageEntry, rhs: AyuSavedDeletedMessageEntry) -> Bool {
        return lhs.index < rhs.index
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        if !self.message.media.isEmpty {
            return AyuSavedDeletedMessageItem(
                presentationData: presentationData,
                dateLabel: self.title,
                text: self.displayText,
                media: self.message.media,
                sectionId: self.section
            )
        }
        return ItemListTextWithLabelItem(
            presentationData: presentationData,
            label: self.title,
            text: self.message.text,
            style: .blocks,
            enabledEntityTypes: [],
            multiline: true,
            sectionId: self.section,
            action: nil
        )
    }

    private var displayText: String {
        let trimmedText = self.message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            return self.message.text
        }
        return self.message.media.map { media -> String in
            var description: String
            switch media.kind {
            case .photo:
                description = "AyuGram.Media.Photo".i18n(self.languageCode)
            case .video:
                description = "AyuGram.Media.Video".i18n(self.languageCode)
            case .voice:
                description = "AyuGram.Media.Voice".i18n(self.languageCode)
            case .file:
                description = media.fileName ?? "AyuGram.Media.File".i18n(self.languageCode)
            }
            if let size = media.size {
                description += ", " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
            return description
        }.joined(separator: "\n")
    }
}

func ayuSavedDeletedMessagesController(context: AccountContext, peerId: PeerId, captureProtected: Bool) -> ViewController {
    let messages = AyuMessageStore.shared.deletedMessages(
        peerId: peerId.toInt64(),
        accountId: context.account.peerId.toInt64()
    ).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.media.isEmpty }.reversed()

    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let languageCode = presentationData.strings.baseLanguageCode
        let entries: [AyuSavedDeletedMessageEntry] = messages.enumerated().map { index, message in
            let title = stringForFullDate(timestamp: message.date, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat)
            return AyuSavedDeletedMessageEntry(index: index, message: message, title: title, languageCode: languageCode)
        }
        let emptyStateItem: ItemListControllerEmptyStateItem? = entries.isEmpty
            ? ItemListTextEmptyStateItem(text: "AyuGram.SavedDeleted.Empty".i18n(languageCode))
            : nil
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("AyuGram.SavedDeleted.Title".i18n(languageCode)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            emptyStateItem: emptyStateItem,
            scrollEnabled: emptyStateItem == nil
        )
        return (controllerState, (listState, Void()))
    }

    let controller = ItemListController(context: context, state: signal)
    if captureProtected {
        setLayerDisableScreenshots(controller.displayNode.layer, true)
    }
    return controller
}
