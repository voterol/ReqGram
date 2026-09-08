// MARK: AyuGram - regex filter management
import SGLogging
import SGSimpleSettings
import SGStrings
import AyuGram

import SGItemListUI
import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import UndoUI
import PromptUI

private enum AyuFiltersSection: Int32, SGItemListSection {
    case list
    case add
}

private enum AyuFiltersAction: Hashable {
    case add
    case edit(String)
    case toggle(String)
    case delete(String)
}

private typealias AyuFiltersEntry = SGItemListUIEntry<AyuFiltersSection, AnyHashable, AnyHashable, AnyHashable, AnyHashable, AyuFiltersAction>

private func ayuFiltersEntries(presentationData: PresentationData, filters: [AyuRegexFilter]) -> [AyuFiltersEntry] {
    var entries: [AyuFiltersEntry] = []
    let lang = presentationData.strings.baseLanguageCode
    let id = SGItemListCounter()

    entries.append(.header(id: id.count, section: .list, text: i18n("AyuGram.Filters.Header", lang), badge: nil))
    if filters.isEmpty {
        entries.append(.notice(id: id.count, section: .list, text: i18n("AyuGram.Filters.Empty", lang)))
    } else {
        for filter in filters {
            // A disabled filter is shown dimmed by prefixing the raw pattern,
            // since the list row type has no dedicated disabled style.
            let title = filter.enabled ? filter.text : "◦ \(filter.text)"
            entries.append(.action(id: id.count, section: .list, actionType: .edit(filter.id), text: title, kind: .generic))
        }
    }

    entries.append(.action(id: id.count, section: .add, actionType: .add, text: i18n("AyuGram.Filters.Add", lang), kind: .generic))
    entries.append(.notice(id: id.count, section: .add, text: i18n("AyuGram.Filters.Notice", lang)))

    return entries
}

/// Prompts for a regex pattern and validates it before saving.
private func ayuPresentFilterEditor(
    context: AccountContext,
    existing: AyuRegexFilter?,
    present: @escaping (ViewController, ViewControllerPresentationArguments?) -> Void,
    completion: @escaping () -> Void
) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode

    let promptController = promptController(
        context: context,
        updatedPresentationData: nil,
        text: i18n("AyuGram.Filters.Edit.Pattern", lang),
        value: existing?.text ?? "",
        placeholder: i18n("AyuGram.Filters.Edit.PatternPlaceholder", lang),
        apply: { value in
            guard let value = value else { return }
            let pattern = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { return }

            let caseInsensitive = existing?.caseInsensitive ?? true
            guard AyuFilters.isValidPattern(pattern, caseInsensitive: caseInsensitive) else {
                present(
                    textAlertController(
                        context: context,
                        title: nil,
                        text: i18n("AyuGram.Filters.Edit.Invalid", lang),
                        actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]
                    ),
                    nil
                )
                return
            }

            if var updated = existing {
                updated.text = pattern
                AyuFilters.shared.updateFilter(updated)
            } else {
                AyuFilters.shared.addFilter(AyuRegexFilter(text: pattern))
            }
            completion()
        }
    )
    present(promptController, nil)
}

public func ayuFiltersController(context: AccountContext) -> ViewController {
    let simplePromise = ValuePromise(true, ignoreRepeated: false)
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?

    let arguments = SGItemListArguments<AnyHashable, AnyHashable, AnyHashable, AnyHashable, AyuFiltersAction>(
        context: context,
        action: { action in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let lang = presentationData.strings.baseLanguageCode

            switch action {
            case .add:
                ayuPresentFilterEditor(context: context, existing: nil, present: { c, a in
                    presentControllerImpl?(c, a)
                }, completion: {
                    simplePromise.set(true)
                })
            case let .edit(filterId):
                guard let filter = AyuFilters.shared.filters.first(where: { $0.id == filterId }) else {
                    return
                }
                let actionSheet = ActionSheetController(presentationData: presentationData)
                var items: [ActionSheetItem] = []
                items.append(ActionSheetTextItem(title: filter.text))
                items.append(ActionSheetButtonItem(
                    title: filter.enabled ? i18n("AyuGram.Filters.Edit.Enabled", lang) : i18n("AyuGram.Filters.Edit.Enabled", lang),
                    color: .accent,
                    action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        var updated = filter
                        updated.enabled.toggle()
                        AyuFilters.shared.updateFilter(updated)
                        simplePromise.set(true)
                    }
                ))
                items.append(ActionSheetButtonItem(
                    title: i18n("AyuGram.Filters.Edit.Reversed", lang),
                    color: .accent,
                    action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        var updated = filter
                        updated.reversed.toggle()
                        AyuFilters.shared.updateFilter(updated)
                        simplePromise.set(true)
                    }
                ))
                items.append(ActionSheetButtonItem(
                    title: i18n("AyuGram.Filters.Edit.CaseInsensitive", lang),
                    color: .accent,
                    action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        var updated = filter
                        updated.caseInsensitive.toggle()
                        AyuFilters.shared.updateFilter(updated)
                        simplePromise.set(true)
                    }
                ))
                items.append(ActionSheetButtonItem(
                    title: i18n("AyuGram.Filters.Edit.Pattern", lang),
                    color: .accent,
                    action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        ayuPresentFilterEditor(context: context, existing: filter, present: { c, a in
                            presentControllerImpl?(c, a)
                        }, completion: {
                            simplePromise.set(true)
                        })
                    }
                ))
                items.append(ActionSheetButtonItem(
                    title: i18n("AyuGram.Filters.Edit.Delete", lang),
                    color: .destructive,
                    action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        AyuFilters.shared.removeFilter(id: filter.id)
                        simplePromise.set(true)
                    }
                ))

                actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                    })
                ])])
                presentControllerImpl?(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
            case let .toggle(filterId):
                guard var filter = AyuFilters.shared.filters.first(where: { $0.id == filterId }) else {
                    return
                }
                filter.enabled.toggle()
                AyuFilters.shared.updateFilter(filter)
                simplePromise.set(true)
            case let .delete(filterId):
                AyuFilters.shared.removeFilter(id: filterId)
                simplePromise.set(true)
            }
        }
    )

    let signal = combineLatest(context.sharedContext.presentationData, simplePromise.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries = ayuFiltersEntries(presentationData: presentationData, filters: AyuFilters.shared.filters)

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(i18n("AyuGram.Filters.Manage", presentationData.strings.baseLanguageCode)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            ensureVisibleItemTag: nil,
            initialScrollToItem: nil
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    return controller
}
