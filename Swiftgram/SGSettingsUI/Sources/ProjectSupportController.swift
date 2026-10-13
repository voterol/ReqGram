import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import SGItemListUI
import SGStrings
import UndoUI

public enum ProjectSupportKind {
    case ayuGram
    case exteraGram
}

private enum ProjectSupportSection: Int32, SGItemListSection {
    case project
    case payment
}

private enum ProjectSupportAction: Hashable {
    case boosty
    case contact
}

private struct ProjectSupportPayment: Hashable {
    let value: String
}

private enum ProjectSupportUnused: Hashable {
    case value
}

private struct ProjectSupportConfiguration {
    let title: String
    let boostyURL: String
    let contactURL: String
    let contactUsername: String
    let payments: [(String, String)]

    init(kind: ProjectSupportKind) {
        switch kind {
        case .ayuGram:
            self.title = "AyuGram"
            self.boostyURL = "https://boosty.to/alexeyzavar"
            self.contactURL = "https://t.me/ayugramOwner"
            self.contactUsername = "@ayugramOwner"
            self.payments = [
                ("TON", "UQA4i8U8vP3mYUZSV3KqDQEHPwmhninEqCkkKc7BITQ652de"),
                ("Bitcoin", "bc1qdk6qq4mzq5yap3fpy0qau3246w3m3uwac9f0xd"),
                ("Ethereum", "0x405589857C8DFAb45B2027c68ad1e58877FDa347"),
                ("Solana", "8ZHQpPxpsdRjsWoBcF1dmvRM5dB6zEhJ3jMBFZjYfyHs"),
                ("Tron", "TRpbajq38qU8joThgAfKJLyEPbNjzsdPJ1")
            ]
        case .exteraGram:
            self.title = "exteraGram"
            self.boostyURL = "https://boosty.to/exteragram/about"
            self.contactURL = "https://t.me/exteraOwner"
            self.contactUsername = "@exteraOwner"
            self.payments = [
                ("TON Keeper", "UQBkAm37aUkCfGx4L00LXo-pIeKvgTHDfqCglYbyry1_AbIE"),
                ("TON Space", "UQCugGJ4pzpTFxSdqKn00YYuse3JAfCdbF0I-YszLbVeHRZa"),
                ("Mastercard", "5536913971457292")
            ]
        }
    }
}

private typealias ProjectSupportEntry = SGItemListUIEntry<ProjectSupportSection, ProjectSupportUnused, ProjectSupportUnused, ProjectSupportPayment, ProjectSupportUnused, ProjectSupportAction>

public func projectSupportController(context: AccountContext, kind: ProjectSupportKind) -> ViewController {
    var controller: ItemListController?
    let configuration = ProjectSupportConfiguration(kind: kind)

    let arguments = SGItemListArguments<ProjectSupportUnused, ProjectSupportUnused, ProjectSupportPayment, ProjectSupportUnused, ProjectSupportAction>(
        context: context,
        setOneFromManyValue: { payment in
            UIPasteboard.general.setItems(
                [[UIPasteboard.typeAutomatic: payment.value]],
                options: [
                    .localOnly: true,
                    .expirationDate: Date().addingTimeInterval(2.0 * 60.0)
                ]
            )
            let currentPresentationData = context.sharedContext.currentPresentationData.with { $0 }
            controller?.present(
                UndoOverlayController(
                    presentationData: currentPresentationData,
                    content: .info(title: nil, text: i18n("ProjectSupport.Copied", currentPresentationData.strings.baseLanguageCode), timeout: nil, customUndoText: nil),
                    elevatedLayout: false,
                    action: { _ in true }
                ),
                in: .window(.root),
                with: nil
            )
        },
        action: { action in
            switch action {
            case .boosty:
                context.sharedContext.openExternalUrl(
                    context: context,
                    urlContext: .generic,
                    url: configuration.boostyURL,
                    forceExternal: true,
                    presentationData: context.sharedContext.currentPresentationData.with { $0 },
                    navigationController: controller?.navigationController as? NavigationController,
                    dismissInput: {}
                )
            case .contact:
                context.sharedContext.openExternalUrl(
                    context: context,
                    urlContext: .generic,
                    url: configuration.contactURL,
                    forceExternal: false,
                    presentationData: context.sharedContext.currentPresentationData.with { $0 },
                    navigationController: controller?.navigationController as? NavigationController,
                    dismissInput: {}
                )
            }
        }
    )

    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        var entries: [ProjectSupportEntry] = [
            .header(id: 0, section: .project, text: configuration.title.uppercased(), badge: nil),
            .notice(id: 1, section: .project, text: i18n("ProjectSupport.Description", lang, configuration.title)),
            .action(id: 2, section: .project, actionType: .boosty, text: i18n("ProjectSupport.Boosty", lang), kind: .generic),
            .action(id: 3, section: .project, actionType: .contact, text: i18n("ProjectSupport.Contact", lang, configuration.contactUsername), kind: .generic),
            .header(id: 4, section: .payment, text: i18n("ProjectSupport.PaymentDetails", lang), badge: nil)
        ]
        for (index, payment) in configuration.payments.enumerated() {
            entries.append(.oneFromManySelector(id: 5 + index, section: .payment, settingName: ProjectSupportPayment(value: payment.1), text: payment.0, value: payment.1, enabled: true))
        }
        entries.append(.notice(id: 5 + configuration.payments.count, section: .payment, text: i18n("ProjectSupport.CopyHint", lang)))
        return (
            ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(i18n("ProjectSupport.Title", lang, configuration.title)),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
            ),
            (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil), arguments)
        )
    }
    let result = ItemListController(context: context, state: signal)
    controller = result
    return result
}
