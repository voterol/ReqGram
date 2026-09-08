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

private enum AyuMessageEditHistorySection: Int32 {
    case revisions
}

private struct AyuMessageEditHistoryEntry: ItemListNodeEntry {
    let index: Int
    let revision: AyuMessageRevision
    let title: String

    var section: ItemListSectionId {
        return AyuMessageEditHistorySection.revisions.rawValue
    }

    var stableId: Int {
        return self.index
    }

    static func ==(lhs: AyuMessageEditHistoryEntry, rhs: AyuMessageEditHistoryEntry) -> Bool {
        return lhs.index == rhs.index && lhs.revision == rhs.revision && lhs.title == rhs.title
    }

    static func <(lhs: AyuMessageEditHistoryEntry, rhs: AyuMessageEditHistoryEntry) -> Bool {
        return lhs.index < rhs.index
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        return ItemListTextWithLabelItem(
            presentationData: presentationData,
            label: self.title,
            text: self.revision.text,
            style: .blocks,
            enabledEntityTypes: [],
            multiline: true,
            sectionId: self.section,
            action: nil
        )
    }
}

func ayuMessageEditHistoryController(context: AccountContext, messageId: MessageId, captureProtected: Bool) -> ViewController {
    let revisions = AyuMessageStore.shared.revisions(
        peerId: messageId.peerId.toInt64(),
        accountId: context.account.peerId.toInt64(),
        messageId: messageId.id
    ).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.reversed()

    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let languageCode = presentationData.strings.baseLanguageCode
        let entries: [AyuMessageEditHistoryEntry] = revisions.enumerated().map { index, revision in
            let title = stringForFullDate(timestamp: revision.editDate, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat)
            return AyuMessageEditHistoryEntry(index: index, revision: revision, title: title)
        }
        let emptyStateItem: ItemListControllerEmptyStateItem? = entries.isEmpty
            ? ItemListTextEmptyStateItem(text: "AyuGram.EditHistory.Empty".i18n(languageCode))
            : nil
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("AyuGram.EditHistory.Title".i18n(languageCode)),
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
