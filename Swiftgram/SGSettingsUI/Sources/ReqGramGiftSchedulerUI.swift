import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import TelegramCore
import Postbox
import AccountContext
import PresentationDataUtils
import ItemListUI
import SGStrings
import SGSimpleSettings
import ReqGramGiftScheduler

/// UI support for the ReqGram "Gift Scheduler" plugin screen.
///
/// Kept in its own file so the plugin's list rows, confirmations and
/// task-management sheets do not further inflate ReqGramSettingsController.

/// Human label for a grace-window value.
func reqGramGiftSchedulerMaxLateTitle(minutes: Int, lang: String) -> String {
    if minutes % 60 == 0 {
        let hours = minutes / 60
        return "\(hours) " + i18n("ReqGram.Plugin.GiftScheduler.Unit.Hours", lang)
    }
    return "\(minutes) " + i18n("ReqGram.Plugin.GiftScheduler.Unit.Minutes", lang)
}

/// Localized label for a task status.
private func reqGramGiftSchedulerStatusTitle(_ status: ReqGramGiftTask.Status, lang: String) -> String {
    switch status {
    case .pending:
        return i18n("ReqGram.Plugin.GiftScheduler.Status.Pending", lang)
    case .sending:
        return i18n("ReqGram.Plugin.GiftScheduler.Status.Sending", lang)
    case .sent:
        return i18n("ReqGram.Plugin.GiftScheduler.Status.Sent", lang)
    case .failed:
        return i18n("ReqGram.Plugin.GiftScheduler.Status.Failed", lang)
    case .missed:
        return i18n("ReqGram.Plugin.GiftScheduler.Status.Missed", lang)
    }
}

/// Maps a persisted error token onto localized copy.
///
/// Tokens are stable across versions; the server-provided tail is appended
/// verbatim so the user can see the real cause (for example BALANCE_TOO_LOW).
private func reqGramGiftSchedulerErrorText(_ error: String, lang: String) -> String? {
    if error.isEmpty {
        return nil
    }
    switch error {
    case ReqGramGiftSchedulerError.missedWindow:
        return i18n("ReqGram.Plugin.GiftScheduler.Error.Missed", lang)
    case ReqGramGiftSchedulerError.interrupted:
        return i18n("ReqGram.Plugin.GiftScheduler.Error.Interrupted", lang)
    case ReqGramGiftSchedulerError.noPaymentForm:
        return i18n("ReqGram.Plugin.GiftScheduler.Error.NoForm", lang)
    case ReqGramGiftSchedulerError.peerUnavailable:
        return i18n("ReqGram.Plugin.GiftScheduler.Error.PeerUnavailable", lang)
    case ReqGramGiftSchedulerError.premiumRequired:
        return i18n("ReqGram.Plugin.GiftScheduler.Error.PremiumRequired", lang)
    default:
        if error.hasPrefix(ReqGramGiftSchedulerError.retryPrefix) {
            return i18n("ReqGram.Plugin.GiftScheduler.Error.WillRetry", lang)
                + ": " + String(error.dropFirst(ReqGramGiftSchedulerError.retryPrefix.count))
        }
        if error.hasPrefix(ReqGramGiftSchedulerError.serverPrefix) {
            return String(error.dropFirst(ReqGramGiftSchedulerError.serverPrefix.count))
        }
        return error
    }
}

/// One-line summary of a task for the list sheet.
private func reqGramGiftSchedulerSummary(
    _ task: ReqGramGiftTask,
    peerName: String?,
    dateTimeFormat: PresentationDateTimeFormat,
    lang: String
) -> String {
    let label = task.label.isEmpty ? i18n("ReqGram.Plugin.GiftScheduler.UnnamedGift", lang) : task.label
    let when = reqGramGiftSchedulerFormatWhen(timestamp: Int32(clamping: Int(task.when)), dateTimeFormat: dateTimeFormat)
    let recipient = peerName ?? i18n("ReqGram.Plugin.GiftScheduler.UnknownRecipient", lang)
    return "\(reqGramGiftSchedulerStatusTitle(task.status, lang: lang)) · \(label) → \(recipient) · \(when)"
}

/// Handles the plugin screen's action rows.
func reqGramGiftSchedulerHandleAction(
    _ action: ReqGramGiftSchedulerUIAction,
    context: AccountContext,
    lang: String,
    present: @escaping (ViewController) -> Void
) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let accountId = context.account.id.int64
    let store = ReqGramGiftTaskStore.shared

    switch action {
    case .showTasks:
        reqGramGiftSchedulerPresentTaskList(context: context, lang: lang, present: present)
    case .cancelPending:
        let pending = store.tasks(accountId: accountId).filter { $0.status == .pending }
        guard !pending.isEmpty else {
            return
        }
        present(textAlertController(
            context: context,
            title: i18n("ReqGram.Plugin.GiftScheduler.CancelAll.Title", lang),
            text: i18n("ReqGram.Plugin.GiftScheduler.CancelAll.Text", lang) + " (\(pending.count))",
            actions: [
                TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                TextAlertAction(type: .destructiveAction, title: i18n("ReqGram.Plugin.GiftScheduler.CancelAll.Confirm", lang), action: {
                    // Only `pending` tasks are removed. A task already in
                    // `sending` may have a payment in flight and is skipped.
                    let _ = store.cancelAllPending(accountId: accountId)
                })
            ]
        ))
    case .clearFinished:
        let _ = store.clearFinished(accountId: accountId)
    }
}

/// Action identifiers, decoupled from the controller's private enum.
enum ReqGramGiftSchedulerUIAction {
    case showTasks
    case cancelPending
    case clearFinished
}

/// Presents the scheduled-task list.
///
/// Recipient names are resolved from the engine so the list shows a real name
/// rather than the original plugin's bare numeric id.
private func reqGramGiftSchedulerPresentTaskList(
    context: AccountContext,
    lang: String,
    present: @escaping (ViewController) -> Void
) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let store = ReqGramGiftTaskStore.shared
    let accountId = context.account.id.int64
    let tasks = store.tasks(accountId: accountId).sorted { $0.when > $1.when }

    guard !tasks.isEmpty else {
        present(textAlertController(
            context: context,
            title: nil,
            text: i18n("ReqGram.Plugin.GiftScheduler.Tasks.Empty", lang),
            actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]
        ))
        return
    }

    let peerIds = Array(Set(tasks.map { $0.recipientPeerId }))
    let _ = (context.engine.data.get(
        EngineDataMap(peerIds.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) })
    )
    |> take(1)
    |> deliverOnMainQueue).start(next: { peerMap in
        let sheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []
        for task in tasks.prefix(40) {
            let peerName = peerMap[task.recipientPeerId].flatMap { $0?.compactDisplayTitle }
            let title = reqGramGiftSchedulerSummary(
                task,
                peerName: peerName,
                dateTimeFormat: presentationData.dateTimeFormat,
                lang: lang
            )
            items.append(ActionSheetButtonItem(title: title, color: .accent, action: { [weak sheet] in
                sheet?.dismissAnimated()
                reqGramGiftSchedulerPresentTaskDetail(
                    task: task,
                    peerName: peerName,
                    context: context,
                    lang: lang,
                    present: present
                )
            }))
        }
        sheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak sheet] in
                    sheet?.dismissAnimated()
                })
            ])
        ])
        present(sheet)
    })
}

/// Detail + cancel/remove for one task.
private func reqGramGiftSchedulerPresentTaskDetail(
    task: ReqGramGiftTask,
    peerName: String?,
    context: AccountContext,
    lang: String,
    present: @escaping (ViewController) -> Void
) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let store = ReqGramGiftTaskStore.shared

    var lines: [String] = []
    lines.append(i18n("ReqGram.Plugin.GiftScheduler.Confirm.Recipient", lang) + ": "
        + (peerName ?? i18n("ReqGram.Plugin.GiftScheduler.UnknownRecipient", lang)))
    lines.append(i18n("ReqGram.Plugin.GiftScheduler.Confirm.When", lang) + ": "
        + reqGramGiftSchedulerFormatWhen(timestamp: Int32(clamping: Int(task.when)), dateTimeFormat: presentationData.dateTimeFormat))
    lines.append(i18n("ReqGram.Plugin.GiftScheduler.Confirm.Stars", lang) + ": \(task.stars)")
    lines.append(i18n("ReqGram.Plugin.GiftScheduler.Detail.Status", lang) + ": "
        + reqGramGiftSchedulerStatusTitle(task.status, lang: lang))
    if !task.text.isEmpty {
        lines.append(i18n("ReqGram.Plugin.GiftScheduler.Detail.Caption", lang) + ": " + task.text)
    }
    if task.hasCustomEmoji {
        lines.append(i18n("ReqGram.Plugin.GiftScheduler.Confirm.CustomEmoji", lang) + ": \(task.customEmojiFileIds.count)")
    }
    if let errorText = reqGramGiftSchedulerErrorText(task.error, lang: lang) {
        lines.append(errorText)
    }
    let detail = lines.joined(separator: "\n")

    // A task in `sending` cannot be cancelled: a payment request may already
    // be in flight, exactly as in the original plugin.
    if task.status == .sending {
        present(textAlertController(
            context: context,
            title: nil,
            text: detail + "\n\n" + i18n("ReqGram.Plugin.GiftScheduler.Detail.SendingNotice", lang),
            actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]
        ))
        return
    }

    let isPending = task.status == .pending
    let destructiveTitle = isPending
        ? i18n("ReqGram.Plugin.GiftScheduler.Detail.Cancel", lang)
        : i18n("ReqGram.Plugin.GiftScheduler.Detail.Remove", lang)

    present(textAlertController(
        context: context,
        title: nil,
        text: detail,
        actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: destructiveTitle, action: {
                let _ = store.remove(id: task.id)
            })
        ]
    ))
}
