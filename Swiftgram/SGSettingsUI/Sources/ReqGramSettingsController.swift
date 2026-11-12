import Foundation
import UIKit
import Display
import ComponentFlow
import AlertComponent
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import TelegramCore
import PromptUI
import UndoUI
import SGItemListUI
import SGStrings
import SGSimpleSettings
import ZipArchive
import AyuGram
import SGScamRegistry
import SGNowPlaying
import ReqGramGiftScheduler
import ReqGramBuyGifts

private enum ReqGramSection: Int32, SGItemListSection {
    case presentation
    case messages
    case chatList
    case profiles
    case media
    case plugins
    case support
}

private enum ReqGramBoolSetting: Hashable {
    case fullChannelViewCounts
    case channelForwardCounts
    case compactDescriptions
    case stopAfterVoiceMessage
    case characterCounter
    case secondsInMessages
    case wideChannelPosts
    case compactChatList
    case showProfileId
    case showDC
}
private enum ReqGramSliderSetting: Hashable {
    case duration, blurDuration, blurRadius, blurTextDelay, slideDist, scaleStart, rotateAngle
    case particleCount, particleSpeed, particleSpread, particleSize, cursorSpeed, cursorWidth, liquidScale, selectionEffect, selectionStretch, selectionSide
}

private func reqGramAnimationValue(_ value: Int, minimum: Int, maximum: Int) -> Int32 {
    return Int32(min(max(value, minimum), maximum))
}

private enum ReqGramDisclosure: Hashable {
    case builtInPlugins
    case installedPlugins
    case other
}

private enum ReqGramPlugin: Hashable {
    case localEdictorAndZwyLib
    case textAnimationPrivateLet
    case scamBaseWriter
    case nowPlaying
}

/// Link type of the "Built-in plugins" screen. Gifts lives inside that screen
/// (not as a third standalone button on the main Plugins section), so the
/// main screen keeps exactly two entries: built-in and installed plugins.
private enum ReqGramBuiltInPluginLink: Hashable {
    case gifts
    case plugin(ReqGramPlugin)
}

private enum ReqGramUnused: Hashable {
    case value
}
private enum ReqGramTransferAction: Hashable { case export, `import`, reset }

private typealias ReqGramEntry = SGItemListUIEntry<ReqGramSection, ReqGramBoolSetting, ReqGramSliderSetting, ReqGramUnused, ReqGramDisclosure, ReqGramTransferAction>

private enum ReqGramPluginSection: Int32, SGItemListSection {
    case settings
    case information
}

private enum ReqGramPluginBoolSetting: Hashable {
    case enabled
    case blur, slide, scale, rotate, deleteAnimation, cursor, liquidCursor, ignoreSpaces, animateAllLines
    case nowPlayingUseSongLink
}
private enum ReqGramPluginSelector: Hashable { case scamInterval, nowPlayingPlace, nowPlayingSource, nowPlayingCardType, nowPlayingCardBackground, nowPlayingCardFont, nowPlayingCardLinkStyle }

/// Disclosure links of a plugin screen (token sub-screens).
private enum ReqGramPluginDisclosure: Hashable {
    case nowPlayingToken(SGNowPlayingPlatformId)
}

private enum ReqGramPluginUnused: Hashable {
    case value
}

// MARK: - Gifts screen (Task: consolidated "Gifts" tab)
//
// All gift-related settings/plugins (Gift ID, Send Gift by ID, Gift
// Scheduler, Buy Gifts) live together on one scrollable screen instead of
// being scattered across the flat "Built-in Plugins" list. Each plugin keeps
// its OWN section (header + rows), so this reads as "one Gifts screen with
// four grouped plugin blocks", not a single merged settings blob.
private enum ReqGramGiftsSection: Int32, SGItemListSection {
    case giftId
    case sendGiftById
    case giftScheduler
    case buyGifts
}

private enum ReqGramGiftsBoolSetting: Hashable {
    case giftIdEnabled
    case sendGiftByIdEnabled
    case giftSchedulerEnabled
    case buyGiftsEnabled
    case buyGiftsRememberQuantity
    case buyGiftsHaptic
}

private enum ReqGramGiftsSelector: Hashable {
    case giftSchedulerMaxLate
    case buyGiftsDelay
    case buyGiftsMaxRecipients
}

private enum ReqGramGiftsAction: Hashable {
    case sendGiftById
    case giftSchedulerShowTasks
    case giftSchedulerCancelPending
    case giftSchedulerClearFinished
}

private typealias ReqGramGiftsEntry = SGItemListUIEntry<ReqGramGiftsSection, ReqGramGiftsBoolSetting, ReqGramUnused, ReqGramGiftsSelector, ReqGramUnused, ReqGramGiftsAction>

/// Human label for a Buy Gifts send-delay value.
private func reqGramBuyGiftsDelayTitle(ms: Int, lang: String) -> String {
    if ms <= 0 {
        return i18n("ReqGram.Plugin.BuyGifts.Delay.Off", lang)
    }
    return String(format: i18n("ReqGram.Plugin.BuyGifts.Delay.Value", lang), ms)
}

private func reqGramGiftsController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?

    let arguments = SGItemListArguments<ReqGramGiftsBoolSetting, ReqGramUnused, ReqGramGiftsSelector, ReqGramUnused, ReqGramGiftsAction>(
        context: context,
        setBoolValue: { setting, value in
            let settings = SGSimpleSettings.shared
            switch setting {
            case .giftIdEnabled:
                settings.reqGramGiftIdEnabled = value
            case .sendGiftByIdEnabled:
                settings.reqGramSendGiftByIdEnabled = value
            case .giftSchedulerEnabled:
                settings.reqGramGiftSchedulerEnabled = value
                // Start or stop the foreground tick immediately so the toggle
                // has an observable effect without waiting for a relaunch.
                ReqGramGiftScheduler.shared.refreshRunState()
            case .buyGiftsEnabled:
                settings.reqGramBuyGiftsEnabled = value
            case .buyGiftsRememberQuantity:
                settings.reqGramBuyGiftsRememberQuantity = value
            case .buyGiftsHaptic:
                settings.reqGramBuyGiftsHapticFeedback = value
            }
        },
        setOneFromManyValue: { setting in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let lang = presentationData.strings.baseLanguageCode
            switch setting {
            case .giftSchedulerMaxLate:
                // Grace window. Offered as a bounded list rather than the
                // original's free-text minutes field, so the value is always
                // parseable and the "missed" behavior stays predictable.
                let sheet = ActionSheetController(presentationData: presentationData)
                let options: [Int] = [30, 60, 180, 360, 720, 1440]
                let items = options.map { minutes in
                    ActionSheetButtonItem(title: reqGramGiftSchedulerMaxLateTitle(minutes: minutes, lang: lang), color: .accent, action: { [weak sheet] in
                        SGSimpleSettings.shared.reqGramGiftSchedulerMaxLateMinutes = minutes
                        sheet?.dismissAnimated()
                    })
                }
                sheet.setItemGroups([ActionSheetItemGroup(items: items)])
                presentControllerImpl?(sheet, nil)
            case .buyGiftsDelay:
                let sheet = ActionSheetController(presentationData: presentationData)
                let items = ReqGramBuyGiftsLimits.delayStepsMs.map { ms in
                    ActionSheetButtonItem(title: reqGramBuyGiftsDelayTitle(ms: ms, lang: lang), color: .accent, action: { [weak sheet] in
                        SGSimpleSettings.shared.reqGramBuyGiftsSendDelayMs = ReqGramBuyGiftsLimits.normalizedDelayMs(ms)
                        sheet?.dismissAnimated()
                    })
                }
                sheet.setItemGroups([ActionSheetItemGroup(items: items)])
                presentControllerImpl?(sheet, nil)
            case .buyGiftsMaxRecipients:
                let sheet = ActionSheetController(presentationData: presentationData)
                let items = ReqGramBuyGiftsLimits.maxRecipientsSteps.map { count in
                    ActionSheetButtonItem(title: "\(count)", color: .accent, action: { [weak sheet] in
                        SGSimpleSettings.shared.reqGramBuyGiftsMaxRecipients = ReqGramBuyGiftsLimits.normalizedMaxRecipients(count)
                        sheet?.dismissAnimated()
                    })
                }
                sheet.setItemGroups([ActionSheetItemGroup(items: items)])
                presentControllerImpl?(sheet, nil)
            }
        },
        action: { action in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let lang = presentationData.strings.baseLanguageCode
            switch action {
            case .sendGiftById:
                guard SGSimpleSettings.shared.reqGramSendGiftByIdEnabled else { return }
                presentControllerImpl?(promptController(context: context, updatedPresentationData: nil,
                    text: i18n("ReqGram.Plugin.SendGiftById.IdTitle", lang), value: nil,
                    placeholder: i18n("ReqGram.Plugin.SendGiftById.IdPlaceholder", lang), apply: { value in
                        guard let value else { return }
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let id = Int64(trimmed), id > 0 else {
                            presentControllerImpl?(textAlertController(context: context, title: nil,
                                text: i18n("ReqGram.Plugin.SendGiftById.InvalidId", lang),
                                actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), nil)
                            return
                        }
                        guard let giftController = context.sharedContext.makeStarGiftByIdController(context: context, giftId: id, onError: {
                            presentControllerImpl?(textAlertController(context: context, title: nil,
                                text: i18n("ReqGram.Plugin.SendGiftById.NotFound", lang),
                                actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), nil)
                        }) else {
                            presentControllerImpl?(textAlertController(context: context, title: nil,
                                text: i18n("ReqGram.Plugin.SendGiftById.NotFound", lang),
                                actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), nil)
                            return
                        }
                        // ContactSelectionController owns the recipient flow's navigation stack.
                        // Push it from the plugin screen instead of presenting it through the
                        // root window; the latter leaves the controller without the navigation
                        // ownership required when it pushes GiftSetupScreen after selection.
                        pushControllerImpl?(giftController)
                    }), nil)
            case .giftSchedulerShowTasks, .giftSchedulerCancelPending, .giftSchedulerClearFinished:
                let uiAction: ReqGramGiftSchedulerUIAction
                switch action {
                case .giftSchedulerShowTasks: uiAction = .showTasks
                case .giftSchedulerCancelPending: uiAction = .cancelPending
                case .giftSchedulerClearFinished: uiAction = .clearFinished
                case .sendGiftById: fatalError("unreachable")
                }
                reqGramGiftSchedulerHandleAction(
                    uiAction,
                    context: context,
                    lang: lang,
                    present: { controller in presentControllerImpl?(controller, nil) }
                )
            }
        }
    )

    // Reactive: the toggles, the Gift Scheduler task counts, and the grace
    // window/delay/recipient labels all need to refresh live, exactly like
    // the previous per-plugin screens did.
    let giftsState = Signal<Void, NoError> { subscriber in
        subscriber.putNext(())
        let observers = [
            NotificationCenter.default.addObserver(forName: UserDefault<Bool>.didChangeNotification, object: nil, queue: .main) { _ in subscriber.putNext(()) },
            NotificationCenter.default.addObserver(forName: ReqGramGiftTaskStore.didChangeNotification, object: nil, queue: .main) { _ in subscriber.putNext(()) }
        ]
        return ActionDisposable { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }

    let signal = combineLatest(context.sharedContext.presentationData, giftsState)
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        let settings = SGSimpleSettings.shared
        let counter = SGItemListCounter()
        var entries: [ReqGramGiftsEntry] = []
        func appendNotice(_ key: String, section: ReqGramGiftsSection, kind: ReqGramPresentationPolicy.NoticeKind = .explanation) {
            sgAppendNotice(to: &entries, counter: counter, section: section, text: i18n(key, lang), kind: kind)
        }

        // MARK: Gift ID
        entries.append(.header(id: counter.count, section: .giftId, text: i18n("ReqGram.Plugin.GiftId", lang), badge: nil))
        entries.append(.toggle(id: counter.count, section: .giftId, settingName: .giftIdEnabled, value: settings.reqGramGiftIdEnabled, text: i18n("ReqGram.Plugin.Enable", lang), enabled: true))
        appendNotice("ReqGram.Plugin.GiftId.Description", section: .giftId)

        // MARK: Send Gift by ID
        entries.append(.header(id: counter.count, section: .sendGiftById, text: i18n("ReqGram.Plugin.SendGiftById", lang), badge: nil))
        entries.append(.toggle(id: counter.count, section: .sendGiftById, settingName: .sendGiftByIdEnabled, value: settings.reqGramSendGiftByIdEnabled, text: i18n("ReqGram.Plugin.Enable", lang), enabled: true))
        appendNotice("ReqGram.Plugin.SendGiftById.Description", section: .sendGiftById)
        entries.append(.action(id: counter.count, section: .sendGiftById, actionType: .sendGiftById, text: i18n("ReqGram.Plugin.SendGiftById.Action", lang), kind: settings.reqGramSendGiftByIdEnabled ? .generic : .disabled))

        // MARK: Gift Scheduler
        entries.append(.header(id: counter.count, section: .giftScheduler, text: i18n("ReqGram.Plugin.GiftScheduler", lang), badge: nil))
        entries.append(.toggle(id: counter.count, section: .giftScheduler, settingName: .giftSchedulerEnabled, value: settings.reqGramGiftSchedulerEnabled, text: i18n("ReqGram.Plugin.Enable", lang), enabled: true))
        appendNotice("ReqGram.Plugin.GiftScheduler.Description", section: .giftScheduler)
        // The grace window and the "missed" state are the central UX of this
        // plugin on iOS, not an edge case, so they are surfaced directly
        // under the enable switch, exactly as on the previous dedicated screen.
        entries.append(.oneFromManySelector(
            id: counter.count,
            section: .giftScheduler,
            settingName: .giftSchedulerMaxLate,
            text: i18n("ReqGram.Plugin.GiftScheduler.MaxLate", lang),
            value: reqGramGiftSchedulerMaxLateTitle(minutes: settings.reqGramGiftSchedulerMaxLateMinutes, lang: lang),
            enabled: settings.reqGramGiftSchedulerEnabled
        ))
        appendNotice("ReqGram.Plugin.GiftScheduler.MaxLate.Notice", section: .giftScheduler)

        let accountId = context.account.id.int64
        let tasks = ReqGramGiftTaskStore.shared.tasks(accountId: accountId)
        let pendingCount = tasks.filter { $0.status == .pending || $0.status == .sending }.count
        let finishedCount = tasks.count - pendingCount
        entries.append(.action(
            id: counter.count,
            section: .giftScheduler,
            actionType: .giftSchedulerShowTasks,
            text: i18n("ReqGram.Plugin.GiftScheduler.Tasks", lang) + " (\(tasks.count))",
            kind: .generic
        ))
        // Reserve these ids unconditionally, *before* the visibility checks,
        // same technique as `sgAppendNotice` and the previous dedicated
        // screen: these rows disappear the moment their count drops to zero,
        // and the counter is a plain running count, not a stable/content id.
        // See the detailed crash explanation this pattern was introduced for
        // (mid-list stableId collision → ItemListTextItemNode cast failure).
        let cancelPendingId = counter.count
        if pendingCount > 0 {
            entries.append(.action(
                id: cancelPendingId,
                section: .giftScheduler,
                actionType: .giftSchedulerCancelPending,
                text: i18n("ReqGram.Plugin.GiftScheduler.CancelAll", lang),
                kind: .destructive
            ))
        }
        let clearFinishedId = counter.count
        if finishedCount > 0 {
            entries.append(.action(
                id: clearFinishedId,
                section: .giftScheduler,
                actionType: .giftSchedulerClearFinished,
                text: i18n("ReqGram.Plugin.GiftScheduler.ClearFinished", lang),
                kind: .generic
            ))
        }
        appendNotice("ReqGram.Plugin.GiftScheduler.Delivery.Notice", section: .giftScheduler)

        // MARK: Buy Gifts
        entries.append(.header(id: counter.count, section: .buyGifts, text: i18n("ReqGram.Plugin.BuyGifts", lang), badge: nil))
        entries.append(.toggle(id: counter.count, section: .buyGifts, settingName: .buyGiftsEnabled, value: settings.reqGramBuyGiftsEnabled, text: i18n("ReqGram.Plugin.Enable", lang), enabled: true))
        appendNotice("ReqGram.Plugin.BuyGifts.Description", section: .buyGifts)
        entries.append(.toggle(id: counter.count, section: .buyGifts, settingName: .buyGiftsRememberQuantity, value: settings.reqGramBuyGiftsRememberQuantity, text: i18n("ReqGram.Plugin.BuyGifts.RememberQuantity", lang), enabled: settings.reqGramBuyGiftsEnabled))
        entries.append(.toggle(id: counter.count, section: .buyGifts, settingName: .buyGiftsHaptic, value: settings.reqGramBuyGiftsHapticFeedback, text: i18n("ReqGram.Plugin.BuyGifts.Haptic", lang), enabled: settings.reqGramBuyGiftsEnabled))
        entries.append(.oneFromManySelector(
            id: counter.count,
            section: .buyGifts,
            settingName: .buyGiftsDelay,
            text: i18n("ReqGram.Plugin.BuyGifts.Delay", lang),
            value: reqGramBuyGiftsDelayTitle(ms: settings.reqGramBuyGiftsSendDelayMs, lang: lang),
            enabled: settings.reqGramBuyGiftsEnabled
        ))
        appendNotice("ReqGram.Plugin.BuyGifts.Delay.Notice", section: .buyGifts)
        entries.append(.oneFromManySelector(
            id: counter.count,
            section: .buyGifts,
            settingName: .buyGiftsMaxRecipients,
            text: i18n("ReqGram.Plugin.BuyGifts.MaxRecipients", lang),
            value: "\(ReqGramBuyGiftsLimits.normalizedMaxRecipients(settings.reqGramBuyGiftsMaxRecipients))",
            enabled: settings.reqGramBuyGiftsEnabled
        ))
        appendNotice("ReqGram.Plugin.BuyGifts.Send.Info", section: .buyGifts)

        return (
            ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(i18n("ReqGram.Gifts.Title", lang)),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
            ),
            (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil), arguments as Any)
        )
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    return controller
}


private enum ReqGramPluginAction: Hashable {
    case scamRefresh
    case nowPlayingCheck
    case textAnimationRestoreDefaults
}

private typealias ReqGramPluginEntry = SGItemListUIEntry<ReqGramPluginSection, ReqGramPluginBoolSetting, ReqGramSliderSetting, ReqGramPluginSelector, ReqGramPluginDisclosure, ReqGramPluginAction>

public func reqGramSettingsController(context: AccountContext) -> ViewController {
    var presentSupport: (() -> Void)?
    var presentInstalledPlugins: (() -> Void)?
    var pushBuiltInPlugins: (() -> Void)?
    var askForRestart: (() -> Void)?
    var transferAction: ((ReqGramTransferAction) -> Void)?
    let arguments = SGItemListArguments<ReqGramBoolSetting, ReqGramSliderSetting, ReqGramUnused, ReqGramDisclosure, ReqGramTransferAction>(
        context: context,
        setBoolValue: { setting, value in
            let settings = SGSimpleSettings.shared
            switch setting {
            case .fullChannelViewCounts:
                settings.fullChannelViewCounts = value
            case .channelForwardCounts:
                settings.reqGramShowForwardCounts = value
            case .compactDescriptions:
                settings.reqGramCompactDescriptions = value
            case .stopAfterVoiceMessage:
                settings.stopAfterVoiceMessage = value
            case .characterCounter:
                settings.reqGramCharacterCounter = value
            case .secondsInMessages:
                settings.secondsInMessages = value
            case .wideChannelPosts:
                settings.wideChannelPosts = value
            case .compactChatList:
                settings.compactChatList = value
                // `compactChatList` is read directly inside `ChatListItemNode`'s
                // layout computation (ChatListItem.swift), not observed through
                // any reactive signal, so already-laid-out chat list rows do not
                // pick up the change until the list is rebuilt from scratch.
                // The sibling screen (SGSettingsController) already treats this
                // setting as restart-required in both directions; match that
                // here instead of only prompting on enable.
                askForRestart?()
            case .showProfileId:
                settings.showProfileId = value
            case .showDC:
                settings.showDC = value
             }
         },
         updateSliderValue: { setting, value in
             let s = SGSimpleSettings.shared
              switch setting {
             case .duration: s.reqGramTextAnimationPrivateLetDuration = Int(value)
             case .blurDuration: s.reqGramTextAnimationPrivateLetBlurDuration = Int(value)
             case .blurRadius: s.reqGramTextAnimationPrivateLetBlurRadius = Int(value)
             case .blurTextDelay: s.reqGramTextAnimationPrivateLetBlurTextDelay = Int(value)
             case .slideDist: s.reqGramTextAnimationPrivateLetSlideDist = Int(value)
              case .scaleStart: s.reqGramTextAnimationPrivateLetScaleStart = Double(value) / 100.0
              case .rotateAngle: s.reqGramTextAnimationPrivateLetRotateAngle = Int(value)
              case .particleCount: s.reqGramTextAnimationPrivateLetParticleCount = Int(value)
              case .particleSpeed: s.reqGramTextAnimationPrivateLetParticleSpeed = Int(value)
              case .particleSpread: s.reqGramTextAnimationPrivateLetParticleSpread = Int(value)
               case .particleSize: s.reqGramTextAnimationPrivateLetParticleSize = Int(value)
               case .cursorSpeed: s.reqGramTextAnimationPrivateLetCursorSpeed = Int(value)
               case .cursorWidth: s.reqGramTextAnimationPrivateLetCursorWidth = Int(value)
              case .liquidScale: s.reqGramTextAnimationPrivateLetLiquidScaleFactor = Int(value)
              case .selectionEffect: s.reqGramTextAnimationPrivateLetSelectionCursorEffect = Int(value)
              case .selectionStretch: s.reqGramTextAnimationPrivateLetSelectionLiquidStretch = Int(value)
              case .selectionSide: s.reqGramTextAnimationPrivateLetSelectionLiquidSide = Int(value)
              }
          },
         openDisclosureLink: { link in
             switch link {
              case .installedPlugins:
                  presentInstalledPlugins?()
              case .builtInPlugins:
                  pushBuiltInPlugins?()
              case .other:
                  presentSupport?()
              }
          }
      )
    let signal = combineLatest(context.sharedContext.presentationData, sgSimpleSettingsChangedSignal)
     |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        let counter = SGItemListCounter()
        let settings = SGSimpleSettings.shared
        var entries: [ReqGramEntry] = []
        // Thin wrapper over the shared helper so this screen can keep passing localization keys.
        func appendNotice(_ key: String, section: ReqGramSection, kind: ReqGramPresentationPolicy.NoticeKind) {
            sgAppendNotice(to: &entries, counter: counter, section: section, text: i18n(key, lang), kind: kind)
        }
        entries.append(.header(id: counter.count, section: .presentation, text: i18n("ReqGram.Presentation.Title", lang), badge: nil))
        entries.append(.toggle(id: counter.count, section: .presentation, settingName: .compactDescriptions, value: settings.reqGramCompactDescriptions, text: i18n("ReqGram.CompactDescriptions", lang), enabled: true))
        appendNotice("ReqGram.CompactDescriptions.Notice", section: .presentation, kind: .explanation)
        entries.append(.header(id: counter.count, section: .messages, text: i18n("ReqGram.Presentation.Messages", lang), badge: nil))
        entries.append(.toggle(id: counter.count, section: .messages, settingName: .fullChannelViewCounts, value: settings.fullChannelViewCounts, text: i18n("Settings.FullChannelViewCounts", lang), enabled: true))
        appendNotice("Settings.FullChannelViewCounts.Notice", section: .messages, kind: .explanation)
        entries.append(.toggle(id: counter.count, section: .messages, settingName: .channelForwardCounts, value: settings.reqGramShowForwardCounts, text: i18n("Settings.ChannelForwardCounts", lang), enabled: true))
         entries.append(.toggle(id: counter.count, section: .messages, settingName: .secondsInMessages, value: settings.secondsInMessages, text: i18n("Settings.secondsInMessages", lang), enabled: true))
        entries.append(.toggle(id: counter.count, section: .messages, settingName: .characterCounter, value: settings.reqGramCharacterCounter, text: i18n("ReqGram.CharacterCounter", lang), enabled: true))
        entries.append(.toggle(id: counter.count, section: .messages, settingName: .wideChannelPosts, value: settings.wideChannelPosts, text: i18n("Settings.wideChannelPosts", lang), enabled: true))
        entries.append(.header(id: counter.count, section: .chatList, text: i18n("ReqGram.Presentation.ChatList", lang), badge: nil))
        entries.append(.toggle(id: counter.count, section: .chatList, settingName: .compactChatList, value: settings.compactChatList, text: i18n("Settings.CompactChatList", lang), enabled: true))
        entries.append(.header(id: counter.count, section: .profiles, text: i18n("ReqGram.Presentation.Profiles", lang), badge: nil))
        entries.append(.toggle(id: counter.count, section: .profiles, settingName: .showProfileId, value: settings.showProfileId, text: i18n("Settings.ShowProfileID", lang), enabled: true))
        entries.append(.toggle(id: counter.count, section: .profiles, settingName: .showDC, value: settings.showDC, text: i18n("Settings.ShowDC", lang), enabled: true))
        entries += [
            .header(id: counter.count, section: .media, text: i18n("ReqGram.Media.Title", lang), badge: nil),
            .toggle(id: counter.count, section: .media, settingName: .stopAfterVoiceMessage, value: settings.stopAfterVoiceMessage, text: i18n("ReqGram.StopAfterVoiceMessage", lang), enabled: true)
        ]
        appendNotice("ReqGram.StopAfterVoiceMessage.Notice", section: .media, kind: .explanation)
        entries += [
            .header(id: counter.count, section: .plugins, text: i18n("ReqGram.Plugins.Title", lang), badge: nil),
            .disclosure(id: counter.count, section: .plugins, link: .builtInPlugins, text: i18n("ReqGram.BuiltIn.Title", lang)),
             .disclosure(id: counter.count, section: .plugins, link: .installedPlugins, text: i18n("ReqGram.Installed.Title", lang)),
             .header(id: counter.count, section: .support, text: i18n("ReqGram.Support.Section", lang), badge: nil),
             .disclosure(id: counter.count, section: .support, link: .other, text: i18n("ReqGram.Support.MenuTitle", lang)),
             .action(id: counter.count, section: .support, actionType: .export, text: "Export presentation settings", kind: .generic),
             .action(id: counter.count, section: .support, actionType: .import, text: "Import presentation settings", kind: .generic),
             .action(id: counter.count, section: .support, actionType: .reset, text: "Reset presentation settings", kind: .destructive)
        ]
        return (
            ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(ReqGramBadgeConfiguration.displayName),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
            ),
              // The list container style must match the style the individual rows
              // are built with. Every row produced by SGItemListUI is hardcoded to
              // `style: .blocks` (and `systemStyle: .glass`), so forcing the
              // container to `.plain` made rows paint grouped block backgrounds with
              // rounded corner masks on top of a plain background, and kept grouped
              // insets while the container hid its side overlay nodes. Keep `.blocks`
              // here; the legacy design preference is applied by its real consumers
              // (bubble geometry and chat list tab placement), not by this screen.
              (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil), arguments as Any)
        )
    }
    let controller = ReqGramSettingsController(context: context, state: signal)
    presentInstalledPlugins = { [weak controller] in
        let plugins = ReqGramInstalledPluginsViewController(context: context)
        controller?.present(UINavigationController(rootViewController: plugins), animated: true)
    }
    presentSupport = { [weak controller] in
        controller?.present(supportDevelopmentController(context: context, navigationController: controller?.navigationController as? NavigationController), in: .window(.root), with: nil)
    }
    pushBuiltInPlugins = { [weak controller] in
        (controller?.navigationController as? NavigationController)?.pushViewController(reqGramBuiltInPluginsController(context: context))
    }
    askForRestart = { [weak controller] in
        guard let controller = controller else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller.present(
            UndoOverlayController(
                presentationData: presentationData,
                content: .info(
                    title: nil,
                    text: i18n("Common.RestartRequired", presentationData.strings.baseLanguageCode),
                    timeout: nil,
                    customUndoText: i18n("Common.RestartNow", presentationData.strings.baseLanguageCode)
                ),
                elevatedLayout: false,
                action: { action in
                    if action == .undo {
                        exit(0)
                    }
                    return true
                }
            ),
            in: .window(.root),
            with: nil
        )
    }
    transferAction = { [weak controller] action in
        guard let controller = controller else { return }
        switch action {
        case .export:
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let url = directory.appendingPathComponent(ReqGramSettingsTransfer.fileName)
                try ReqGramSettingsTransfer.exportData().write(to: url, options: .atomic)
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: directory) }
                share.popoverPresentationController?.sourceView = controller.view
                controller.present(share, animated: true)
            } catch { reqGramShowTransferError(error, on: controller) }
        case .import:
            let picker = UIDocumentPickerViewController(documentTypes: ["public.json"], in: .import)
            picker.allowsMultipleSelection = false
            controller.importPicker = picker
            controller.present(picker, animated: true)
        case .reset:
            let alert = UIAlertController(title: "Reset presentation settings?", message: "Only ReqGram presentation settings will be reset.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { _ in ReqGramSettingsTransfer.reset(); reqGramShowTransferDone(on: controller) })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            controller.present(alert, animated: true)
        }
    }
    return controller
}

private final class ReqGramSettingsController: ItemListController, UIDocumentPickerDelegate {
    fileprivate weak var importPicker: UIDocumentPickerViewController? {
        didSet { importPicker?.delegate = self }
    }

    fileprivate init(context: AccountContext, state: Signal<(ItemListControllerState, (ItemListNodeState, Any)), NoError>) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(
            presentationData: ItemListPresentationData(presentationData),
            updatedPresentationData: context.sharedContext.presentationData |> map(ItemListPresentationData.init(_:)),
            state: state,
            tabBarItem: nil
        )
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        importPicker = nil
        guard urls.count == 1, let url = urls.first else {
            reqGramShowTransferError(ReqGramSettingsTransfer.Error.invalidFormat, on: self)
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= 128 * 1024 else {
                throw ReqGramSettingsTransfer.Error.tooLarge
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 128 * 1024 else { throw ReqGramSettingsTransfer.Error.tooLarge }
            do { try ReqGramSettingsTransfer.importData(data); reqGramShowTransferDone(on: self) }
            catch { reqGramShowTransferError(error, on: self) }
        }
        catch { reqGramShowTransferError(error, on: controller) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        importPicker = nil
    }
}

private func reqGramShowTransferError(_ error: Error, on controller: UIViewController) {
    let alert = UIAlertController(title: "Settings transfer failed", message: error.localizedDescription, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default)); controller.present(alert, animated: true)
}
private func reqGramShowTransferDone(on controller: UIViewController) {
    let alert = UIAlertController(title: "Presentation settings updated", message: nil, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default)); controller.present(alert, animated: true)
}

private func reqGramBuiltInPluginsController(context: AccountContext) -> ViewController {
    typealias Entry = SGItemListUIEntry<ReqGramSection, ReqGramUnused, ReqGramUnused, ReqGramUnused, ReqGramBuiltInPluginLink, ReqGramUnused>
    var pushPluginController: ((ReqGramPlugin) -> Void)?
    var pushGifts: (() -> Void)?
    let arguments = SGItemListArguments<ReqGramUnused, ReqGramUnused, ReqGramUnused, ReqGramBuiltInPluginLink, ReqGramUnused>(
        context: context,
        openDisclosureLink: { link in
            switch link {
            case .gifts:
                pushGifts?()
            case let .plugin(plugin):
                pushPluginController?(plugin)
            }
        }
    )
     let signal = context.sharedContext.presentationData
     |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, SGItemListArguments<ReqGramUnused, ReqGramUnused, ReqGramUnused, ReqGramBuiltInPluginLink, ReqGramUnused>)) in
        let lang = presentationData.strings.baseLanguageCode
        let counter = SGItemListCounter()
        let entries: [Entry] = [
            .disclosure(id: counter.count, section: .plugins, link: .gifts, text: i18n("ReqGram.Gifts.Title", lang)),
            .disclosure(id: counter.count, section: .plugins, link: .plugin(.localEdictorAndZwyLib), text: i18n("ReqGram.Plugin.LocalEdictorZwyLib", lang)),
            .disclosure(id: counter.count, section: .plugins, link: .plugin(.textAnimationPrivateLet), text: i18n("ReqGram.Plugin.TextAnimationPrivateLet", lang)),
            .disclosure(id: counter.count, section: .plugins, link: .plugin(.scamBaseWriter), text: i18n("ReqGram.Plugin.ScamBaseWriter", lang)),
            .disclosure(id: counter.count, section: .plugins, link: .plugin(.nowPlaying), text: i18n("ReqGram.Plugin.NowPlaying", lang))
        ]
        return (
            ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(i18n("ReqGram.BuiltIn.Title", lang)),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
            ),
              (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil), arguments)
        )
    }
    let controller = ItemListController(context: context, state: signal)
    pushPluginController = { [weak controller] plugin in
        guard let pluginController = reqGramPluginController(context: context, plugin: plugin) else {
            return
        }
        (controller?.navigationController as? NavigationController)?.pushViewController(pluginController)
    }
    pushGifts = { [weak controller] in
        (controller?.navigationController as? NavigationController)?.pushViewController(reqGramGiftsController(context: context))
    }
    return controller
}

/// ZIP inspection reads only the manifest, never extracts executable content.
final class ReqGramPluginZIPInspector: ReqGramPluginArchiveInspector {
    func contents(in archive: URL) throws -> [String: Data] {
        guard let entries = SSZipArchive.reqGramPluginContents(atPath: archive.path),
              let manifest = entries["manifest.json"], manifest.count <= 256 * 1024 else { throw ReqGramPluginError.invalidPackage }
        return entries
    }
    func entryNames(in archive: URL) throws -> [String] {
        guard let entries = SSZipArchive.reqGramPluginContents(atPath: archive.path),
              let manifest = entries["manifest.json"], manifest.count <= 256 * 1024 else { throw ReqGramPluginError.invalidPackage }
        return Array(entries.keys)
    }
    func readEntry(named: String, from archive: URL) throws -> Data {
        guard let data = SSZipArchive.reqGramPluginContents(atPath: archive.path)?[named] else { throw ReqGramPluginError.invalidPackage }
        return data
    }
}

/// Plugin management and validated declarative settings.
private final class ReqGramInstalledPluginsViewController: UITableViewController, UIDocumentPickerDelegate {
    private let context: AccountContext
    private let manager = ReqGramPluginManager.shared
    private var records: [ReqGramPluginRecord] = []
    private var policy = (developerMode: false, trustedOnly: true, safeMode: false, retentionDays: 7)
    private var observer: NSObjectProtocol?
    private var timer: Foundation.Timer?
    private var ticket: ReqGramPluginImportTicket?
    private var storageError: String?
    private var reviewObservers: [NSObjectProtocol] = []
    private weak var reviewAlert: UIAlertController?
    private weak var reviewInstall: UIAlertAction?

    private let executor: ReqGramEmbeddedExecutor
    init(context: AccountContext) {
        self.context = context
        executor = ReqGramEmbeddedExecutor(accountProvider: ReqGramNativeAccountProvider(context: context))
        super.init(style: .grouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func text(_ key: String) -> String {
        return i18n(key, context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode)
    }
    private func statusText(_ status: String?) -> String {
        switch status ?? "Stopped" {
        case "Starting": return text("ReqGram.Installed.Starting")
        case "Running": return text("ReqGram.Installed.Running")
        case "Stopping": return text("ReqGram.Installed.Stopping")
        case "Stopped": return text("ReqGram.Installed.Stopped")
        default:
            if let status = status, status.hasPrefix("Failed: ") {
                return text("ReqGram.Installed.Failed") + ": " + String(status.dropFirst("Failed: ".count))
            }
            return status ?? ""
        }
    }
    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        for observer in reviewObservers { NotificationCenter.default.removeObserver(observer) }
        timer?.invalidate()
        if let ticket = ticket { manager.cancel(ticket) }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = text("ReqGram.Installed.Title")
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: text("ReqGram.Installed.Done"), style: .done, target: self, action: #selector(close))
        observer = NotificationCenter.default.addObserver(forName: ReqGramPluginManager.didChangeNotification, object: manager, queue: .main) { [weak self] _ in self?.reload() }
        for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
            reviewObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self = self, let ticket = self.ticket else { return }
                self.reviewInstall?.isEnabled = false
                let active = notification.name == UIApplication.didBecomeActiveNotification && self.reviewAlert?.viewIfLoaded?.window != nil
                self.manager.setReviewActive(ticket, active: active)
            })
        }
        reload()
    }
    @objc private func close() { dismiss(animated: true) }
    private func reload() {
        do { records = try manager.plugins(); policy = try manager.policy(); storageError = nil }
        catch { records = []; storageError = errorText(error) }
        tableView.reloadData()
    }
    private func errorText(_ error: Error) -> String {
        let message: String
        if let pluginError = error as? ReqGramPluginError {
            let key: String
            switch pluginError {
            case .invalidPackage: key = "InvalidPackage"
            case .unsafePath: key = "UnsafePath"
            case .corruptStorage: key = "CorruptStorage"
            case .developerModeRequired:
                return "ReqGram Developer Mode is required for plugin management."
            case .trustedOnly: key = "TrustedOnlyError"
            case .confirmationRequired: key = "ConfirmationRequired"
            case .expiredImport: key = "ExpiredImport"
            case .runtimeUnavailable: key = "RuntimeUnavailable"
            case .invalidSettingsTransfer: key = "InvalidSettingsTransfer"
            case .consentRequired: key = "ConsentRequired"
            case .invalidConsent: key = "InvalidConsent"
            }
            message = text("ReqGram.Installed.Error.\(key)")
        } else {
            message = error.localizedDescription
        }
        return message
    }
    private func showError(_ error: Error) {
        let alert = UIAlertController(title: text("ReqGram.Installed.Error.Title"), message: errorText(error), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: text("ReqGram.Installed.OK"), style: .default))
        present(alert, animated: true)
        reload()
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 5 : records.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? text("ReqGram.Installed.Section.Installation") : text("ReqGram.Installed.Title") }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if let error = storageError { return error }
        if section == 0 { return text("ReqGram.Installed.Footer.Recovery") }
        let accountId = context.account.peerId.id._internalGetInt64Value()
        let activeSessions = records.filter { $0.executionStatus == "Starting" || $0.executionStatus == "Running" || $0.executionStatus == "Stopping" }.count
        return "Developer Mode: \(policy.developerMode ? "On" : "Off") · Account: \(accountId) · Active sessions: \(activeSessions)\n\(text("ReqGram.Installed.Footer.Sandbox"))"
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        if indexPath.section == 0 {
            switch indexPath.row {
            case 0:
                cell.textLabel?.text = "Developer Mode"
                cell.detailTextLabel?.text = "Required to install, run, configure, or remove local plugins."
                let toggle = UISwitch(); toggle.tag = 0; toggle.isOn = policy.developerMode
                toggle.isEnabled = storageError == nil
                toggle.addTarget(self, action: #selector(policyChanged(_:)), for: .valueChanged)
                cell.accessoryView = toggle
            case 1:
                cell.textLabel?.text = text("ReqGram.Installed.Import")
                cell.textLabel?.isEnabled = policy.developerMode
                cell.accessoryType = policy.developerMode ? .disclosureIndicator : .none
                cell.selectionStyle = policy.developerMode ? .default : .none
            case 2, 3:
                cell.textLabel?.text = indexPath.row == 2 ? text("ReqGram.Installed.TrustedOnly") : text("ReqGram.Installed.SafeMode")
                let toggle = UISwitch(); toggle.tag = indexPath.row
                toggle.isOn = indexPath.row == 2 ? policy.trustedOnly : policy.safeMode
                toggle.isEnabled = storageError == nil && (indexPath.row == 3 || policy.developerMode)
                toggle.addTarget(self, action: #selector(policyChanged(_:)), for: .valueChanged)
                cell.accessoryView = toggle
            default:
                cell.textLabel?.text = "\(text("ReqGram.Installed.LogRetention")): \(policy.retentionDays) \(text("ReqGram.Installed.Days"))"
                cell.accessoryType = .disclosureIndicator
            }
        } else {
            let record = records[indexPath.row]
            cell.textLabel?.text = "\(record.manifest.name) · \(record.manifest.version)"
            cell.detailTextLabel?.text = "\(text("ReqGram.Installed.Unverified")) · \(statusText(record.executionStatus))\n\(record.quarantineReason ?? "")"
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }
    @objc private func policyChanged(_ sender: UISwitch) {
        do {
            if sender.tag == 0 { try manager.setPolicy(developerMode: sender.isOn) }
            else if sender.tag == 2 { try manager.setPolicy(trustedOnly: sender.isOn) }
            else { try manager.setPolicy(safeMode: sender.isOn) }
            reload()
        } catch { sender.setOn(!sender.isOn, animated: true); showError(error) }
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 { showRecord(records[indexPath.row].id); return }
        if indexPath.row == 1 {
            do {
                let policy = try manager.policy()
                guard policy.developerMode else { throw ReqGramPluginError.developerModeRequired }
                guard !policy.trustedOnly else { throw ReqGramPluginError.trustedOnly }
            }
            catch { showError(error); return }
            let picker = UIDocumentPickerViewController(documentTypes: ["com.reqgram.ixplugin"], in: .import)
            picker.delegate = self
            present(picker, animated: true)
        } else if indexPath.row == 4 {
            let alert = UIAlertController(title: text("ReqGram.Installed.LogRetention"), message: text("ReqGram.Installed.LogRetention.Message"), preferredStyle: .alert)
            for days in [1, 7, 30, 90] {
                alert.addAction(UIAlertAction(title: "\(days) \(self.text("ReqGram.Installed.Days"))", style: .default) { [weak self] _ in
                    do { try self?.manager.setPolicy(retentionDays: days) } catch { self?.showError(error) }
                })
            }
            alert.addAction(UIAlertAction(title: text("ReqGram.Installed.Cancel"), style: .cancel)); present(alert, animated: true)
        }
    }
    private var settingsImport: (picker: UIDocumentPickerViewController, id: String)?
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if settingsImport?.picker === controller { settingsImport = nil }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let request = settingsImport, request.picker === controller {
            settingsImport = nil
            guard let url = urls.first else { return }
            controller.dismiss(animated: true) { [weak self] in self?.reviewSettingsImport(request.id, url: url) }
            return
        }
        guard let url = urls.first else { return }
        // Picker dismissal finishes before presenting the warning.
        controller.dismiss(animated: true) { [weak self] in self?.prepare(url) }
    }
    private func prepare(_ url: URL) {
        do {
            let ticket = try manager.prepare(url, inspector: ReqGramPluginZIPInspector())
            self.ticket = ticket
            manager.setReviewActive(ticket, active: false)
            let m = ticket.manifest
            let permissionList = m.permissions.map { permission in
                permission == "full_access" ? "⚠️ \(permission) — \(text("ReqGram.Installed.FullAccessRisk"))" : "• \(permission)"
            }.joined(separator: "\n")
            let warning = "\(text("ReqGram.Installed.Warning.Title"))\n\n\(text("ReqGram.Installed.UnknownSourceWarning"))\n\n\(m.description)\n\(text("ReqGram.Installed.Author")): \(m.author)\n\(text("ReqGram.Installed.Version")): \(m.version)\n\(text("ReqGram.Installed.Permissions")):\n\(permissionList)\n\n\(text("ReqGram.Installed.Warning.Body"))"
            let alert = UIAlertController(title: m.name, message: warning, preferredStyle: .alert)
            let install = UIAlertAction(title: text("ReqGram.Installed.Install"), style: .destructive) { [weak self] _ in
                guard let self = self else { return }
                guard UIApplication.shared.applicationState == .active, self.manager.remainingSeconds(ticket) == 0 else {
                    self.manager.cancel(ticket); self.ticket = nil
                    self.showError(ReqGramPluginError.confirmationRequired); return
                }
                self.timer?.invalidate(); self.timer = nil
                do { try self.manager.install(ticket); self.ticket = nil; self.reload() }
                catch { self.manager.cancel(ticket); self.ticket = nil; self.showError(error) }
            }
            install.isEnabled = false
            alert.addAction(install)
            alert.addAction(UIAlertAction(title: text("ReqGram.Installed.Cancel"), style: .cancel) { [weak self] _ in
                self?.timer?.invalidate(); self?.timer = nil; self?.manager.cancel(ticket); self?.ticket = nil
            })
            reviewAlert = alert; reviewInstall = install
            present(alert, animated: true) { [weak self] in
                self?.manager.setReviewActive(ticket, active: UIApplication.shared.applicationState == .active)
            }
            timer = Foundation.Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak alert, weak install] timer in
                guard let self = self, let alert = alert else { timer.invalidate(); return }
                guard self.ticket != nil else { timer.invalidate(); return }
                guard UIApplication.shared.applicationState == .active, alert.viewIfLoaded?.window != nil else {
                    self.manager.setReviewActive(ticket, active: false); install?.isEnabled = false; return
                }
                let remaining = self.manager.remainingSeconds(ticket)
                alert.message = warning + "\n\n\(self.text("ReqGram.Installed.ReviewRemaining")): \(remaining) \(self.text("ReqGram.Installed.Seconds"))"
                install?.isEnabled = remaining == 0
            }
        } catch { showError(error) }
    }
    private func showRecord(_ id: String) {
        do {
            guard let record = try manager.plugins().first(where: { $0.id == id }) else { reload(); return }
            let m = record.manifest
            let settingsDescription = (m.settings_schema?.fields.isEmpty == false) ? text("ReqGram.Installed.Settings.Saved") : text("ReqGram.Installed.Settings.None")
            let alert = UIAlertController(title: m.name, message: "\(m.description)\n\n\(m.id) · \(m.version)\n\(text("ReqGram.Installed.Author")): \(m.author)\n\(text("ReqGram.Installed.Permissions")): \(m.permissions.joined(separator: ", "))\n\n\(statusText(record.executionStatus))\n\(record.quarantineReason ?? "")\n\(text("ReqGram.Installed.RuntimeLimits"))\n" + settingsDescription, preferredStyle: .alert)
            let toggle = UIAlertAction(title: record.enabled ? text("ReqGram.Installed.Disable") : text("ReqGram.Installed.Enable"), style: .destructive) { [weak self] _ in
                guard let self = self else { return }
                if !record.enabled {
                    do {
                        if try !self.manager.hasValidConsent(id) {
                            let consent = UIAlertController(title: self.text("ReqGram.Installed.Consent.Title"), message: self.text("ReqGram.Installed.Consent.Message") + "\n\n" + m.permissions.joined(separator: ", "), preferredStyle: .alert)
                            consent.addAction(UIAlertAction(title: self.text("ReqGram.Installed.Consent.Accept"), style: .destructive) { [weak self] _ in
                                do { try self?.manager.grantConsent(id); self?.startPlugin(id, record: record) } catch { self?.showError(error) }
                            })
                            consent.addAction(UIAlertAction(title: self.text("ReqGram.Installed.Cancel"), style: .cancel))
                            self.present(consent, animated: true)
                            return
                        }
                    } catch { self.showError(error); return }
                }
                self.startPlugin(id, record: record)
            }
            toggle.isEnabled = policy.developerMode && record.executionStatus != "Starting" && record.executionStatus != "Stopping"
            alert.addAction(toggle)
            if let schema = m.settings_schema, !schema.fields.isEmpty {
                let action = UIAlertAction(title: text("ReqGram.Installed.Settings"), style: .default) { [weak self] _ in self?.showSettings(id, schema: schema) }
                action.isEnabled = policy.developerMode; alert.addAction(action)
            }
            if m.settings_transfer == true, m.settings_schema?.fields.contains(where: { $0.transferable == true }) == true {
                let exportAction = UIAlertAction(title: text("ReqGram.Installed.ExportSettings"), style: .default) { [weak self] _ in self?.shareSettings(id) }
                exportAction.isEnabled = policy.developerMode; alert.addAction(exportAction)
                let importAction = UIAlertAction(title: text("ReqGram.Installed.ImportSettings"), style: .default) { [weak self] _ in
                    guard let self = self else { return }
                    let picker = UIDocumentPickerViewController(documentTypes: ["public.json"], in: .import)
                    self.settingsImport = (picker, id); picker.delegate = self
                    self.present(picker, animated: true)
                }
                importAction.isEnabled = policy.developerMode; alert.addAction(importAction)
            }
            let logsAction = UIAlertAction(title: text("ReqGram.Installed.ViewLogs"), style: .default) { [weak self] _ in
                guard let self = self else { return }
                do {
                    let logs = try self.manager.logs(for: id)
                    let view = UIAlertController(title: self.text("ReqGram.Installed.Logs"), message: logs.isEmpty ? self.text("ReqGram.Installed.Logs.Empty") : logs.joined(separator: "\n"), preferredStyle: .alert)
                    view.addAction(UIAlertAction(title: self.text("ReqGram.Installed.OK"), style: .default)); self.present(view, animated: true)
                } catch { self.showError(error) }
            }
            logsAction.isEnabled = policy.developerMode; alert.addAction(logsAction)
            let removeAction = UIAlertAction(title: text("ReqGram.Installed.Remove"), style: .destructive) { [weak self] _ in self?.confirmRemoval(id) }
            removeAction.isEnabled = policy.developerMode; alert.addAction(removeAction)
            alert.addAction(UIAlertAction(title: text("ReqGram.Installed.Close"), style: .cancel)); present(alert, animated: true)
        } catch { showError(error) }
    }
    private func startPlugin(_ id: String, record: ReqGramPluginRecord) {
        manager.setEnabled(id, enabled: !record.enabled, inspector: ReqGramPluginZIPInspector(), executor: executor) { [weak self] error in
            if let error = error { self?.showError(error) } else { self?.reload() }
        }
    }
    private func shareSettings(_ id: String) {
        do {
            let bytes = try manager.exportSettings(id)
            // Fixed filename in a fresh directory; neither plugin ID nor JSON controls a path.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let url = directory.appendingPathComponent("plugin-settings.json")
            do { try bytes.write(to: url, options: .atomic) }
            catch { try? FileManager.default.removeItem(at: directory); throw error }
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: directory) }
            share.popoverPresentationController?.sourceView = view
            share.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            present(share, animated: true)
        } catch { showError(error) }
    }
    private func reviewSettingsImport(_ id: String, url: URL) {
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { handle.closeFile() }
            let bytes = handle.readData(ofLength: 128 * 1024 + 1)
            guard bytes.count <= 128 * 1024 else { throw ReqGramPluginError.invalidSettingsTransfer }
            let alert = UIAlertController(title: text("ReqGram.Installed.ImportSettings.Confirm.Title"), message: text("ReqGram.Installed.ImportSettings.Confirm.Message"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: text("ReqGram.Installed.ImportAction"), style: .default) { [weak self] _ in
                guard let self = self else { return }
                do {
                    try self.manager.importSettings(id, data: bytes)
                    self.reload()
                    let done = UIAlertController(title: self.text("ReqGram.Installed.ImportSettings.Done.Title"), message: self.text("ReqGram.Installed.ImportSettings.Done.Message"), preferredStyle: .alert)
                    done.addAction(UIAlertAction(title: self.text("ReqGram.Installed.OK"), style: .default) { [weak self] _ in self?.showRecord(id) })
                    self.present(done, animated: true)
                } catch { self.showError(error) }
            })
            alert.addAction(UIAlertAction(title: text("ReqGram.Installed.Cancel"), style: .cancel)); present(alert, animated: true)
        } catch { showError(error) }
    }
    private func confirmRemoval(_ id: String) {
        let alert = UIAlertController(title: text("ReqGram.Installed.Remove.Confirm.Title"), message: text("ReqGram.Installed.Remove.Confirm.Message"), preferredStyle: .alert)
        for delete in [false, true] {
            alert.addAction(UIAlertAction(title: delete ? text("ReqGram.Installed.Remove.Delete") : text("ReqGram.Installed.Remove.Keep"), style: .destructive) { [weak self] _ in
                do { try self?.manager.remove(id, deleteData: delete); self?.reload() } catch { self?.showError(error) }
            })
        }
        alert.addAction(UIAlertAction(title: text("ReqGram.Installed.Cancel"), style: .cancel)); present(alert, animated: true)
    }
    private func showSettings(_ id: String, schema: ReqGramSettingsSchema) {
        do {
            let values = try manager.settings(id)
            let alert = UIAlertController(title: text("ReqGram.Installed.Settings"), message: text("ReqGram.Installed.Settings.Message"), preferredStyle: .alert)
            for field in schema.fields {
                alert.addAction(UIAlertAction(title: "\(field.label): \(values[field.key]?.display ?? "")", style: .default) { [weak self] _ in
                    guard let self = self else { return }
                    let edit = UIAlertController(title: field.label, message: field.type == "string" ? self.text("ReqGram.Installed.Settings.MaxBytes") : nil, preferredStyle: .alert)
                    let save: (ReqGramSettingValue) -> Void = { [weak self] value in
                        guard let self = self else { return }
                        do { try self.manager.setSetting(id, key: field.key, value: value); self.showSettings(id, schema: schema) }
                        catch { self.showError(error) }
                    }
                    if field.type == "boolean" {
                        edit.addAction(UIAlertAction(title: self.text("ReqGram.Installed.On"), style: .default) { _ in save(.boolean(true)) })
                        edit.addAction(UIAlertAction(title: self.text("ReqGram.Installed.Off"), style: .default) { _ in save(.boolean(false)) })
                    } else if field.type == "selection" {
                        for option in field.options ?? [] { edit.addAction(UIAlertAction(title: option, style: .default) { _ in save(.string(option)) }) }
                    } else {
                        edit.addTextField { $0.text = values[field.key]?.display; $0.autocorrectionType = .no }
                        edit.addAction(UIAlertAction(title: self.text("ReqGram.Installed.Save"), style: .default) { [weak edit] _ in save(.string(edit?.textFields?.first?.text ?? "")) })
                    }
                    edit.addAction(UIAlertAction(title: self.text("ReqGram.Installed.Cancel"), style: .cancel))
                    self.present(edit, animated: true)
                })
            }
            alert.addAction(UIAlertAction(title: text("ReqGram.Installed.Done"), style: .cancel))
            present(alert, animated: true)
        } catch { showError(error) }
    }
}

private func reqGramPluginController(context: AccountContext, plugin: ReqGramPlugin) -> ViewController? {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode
    let title: String
    let description: String
    switch plugin {
    case .localEdictorAndZwyLib:
        title = i18n("ReqGram.Plugin.LocalEdictorZwyLib", lang)
        description = i18n("ReqGram.Plugin.LocalEdictorZwyLib.Description", lang)
    case .textAnimationPrivateLet:
        title = i18n("ReqGram.Plugin.TextAnimationPrivateLet", lang)
        description = i18n("ReqGram.Plugin.TextAnimationPrivateLet.Description", lang)
    case .scamBaseWriter:
        title = i18n("ReqGram.Plugin.ScamBaseWriter", lang)
        description = i18n("ReqGram.Plugin.ScamBaseWriter.Description", lang)
    case .nowPlaying:
        title = i18n("ReqGram.Plugin.NowPlaying", lang)
        description = i18n("ReqGram.Plugin.NowPlaying.Description", lang)
    }

    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?
    let arguments = SGItemListArguments<ReqGramPluginBoolSetting, ReqGramSliderSetting, ReqGramPluginSelector, ReqGramPluginDisclosure, ReqGramPluginAction>(
        context: context,
        setBoolValue: { setting, value in
             let settings = SGSimpleSettings.shared
             switch plugin {
            case .localEdictorAndZwyLib:
                // `reqGramLocalEdictorEnabled` is the only gate with real runtime
                // consumers (ChatInterfaceStateContextMenus / ChatHistoryEntriesForView).
                // `reqGramZwyLibEnabled` has no consumer anywhere, so it is not written
                // here: keeping it in the AND below made the switch read back OFF while
                // local editing was actually active.
                settings.reqGramLocalEdictorEnabled = value
             case .textAnimationPrivateLet:
                 switch setting {
                 case .enabled: settings.reqGramTextAnimationPrivateLetEnabled = value
                 case .blur: settings.reqGramTextAnimationPrivateLetBlurEnabled = value
                 case .slide: settings.reqGramTextAnimationPrivateLetSlideEnabled = value
                 case .scale: settings.reqGramTextAnimationPrivateLetScaleEnabled = value
                  case .rotate: settings.reqGramTextAnimationPrivateLetRotateEnabled = value
                  case .deleteAnimation: settings.reqGramTextAnimationPrivateLetDeleteAnimEnabled = value
                  case .cursor: settings.reqGramTextAnimationPrivateLetCursorEnabled = value
                  case .liquidCursor: settings.reqGramTextAnimationPrivateLetLiquidCursorEnabled = value
                  case .ignoreSpaces: settings.reqGramTextAnimationPrivateLetIgnoreSpaces = value
                   case .animateAllLines: settings.reqGramTextAnimationPrivateLetAnimateAllLines = value
                  default: break
                   }
             case .scamBaseWriter:
                 var settings = SGScamRegistryService.shared.currentSettings()
                 settings.enabled = value
                 SGScamRegistryService.shared.updateSettings(settings)
              case .nowPlaying:
                  switch setting {
                  case .enabled:
                      SGNowPlayingService.shared.updateSettings { settings in
                          settings.isEnabled = value
                      }
                  case .nowPlayingUseSongLink:
                      SGNowPlayingService.shared.updateSettings { settings in
                          settings.useSongLink = value
                      }
                  default:
                      break
                  }
              }
        },
          updateSliderValue: { setting, value in
             let s = SGSimpleSettings.shared
             switch setting {
             case .duration: s.reqGramTextAnimationPrivateLetDuration = Int(value)
             case .blurDuration: s.reqGramTextAnimationPrivateLetBlurDuration = Int(value)
             case .blurRadius: s.reqGramTextAnimationPrivateLetBlurRadius = Int(value)
             case .blurTextDelay: s.reqGramTextAnimationPrivateLetBlurTextDelay = Int(value)
             case .slideDist: s.reqGramTextAnimationPrivateLetSlideDist = Int(value)
              case .scaleStart: s.reqGramTextAnimationPrivateLetScaleStart = Double(value) / 100.0
              case .rotateAngle: s.reqGramTextAnimationPrivateLetRotateAngle = Int(value)
              case .particleCount: s.reqGramTextAnimationPrivateLetParticleCount = Int(value)
              case .particleSpeed: s.reqGramTextAnimationPrivateLetParticleSpeed = Int(value)
              case .particleSpread: s.reqGramTextAnimationPrivateLetParticleSpread = Int(value)
               case .particleSize: s.reqGramTextAnimationPrivateLetParticleSize = Int(value)
               case .cursorSpeed: s.reqGramTextAnimationPrivateLetCursorSpeed = Int(value)
               case .cursorWidth: s.reqGramTextAnimationPrivateLetCursorWidth = Int(value)
              case .liquidScale: s.reqGramTextAnimationPrivateLetLiquidScaleFactor = Int(value)
              case .selectionEffect: s.reqGramTextAnimationPrivateLetSelectionCursorEffect = Int(value)
              case .selectionStretch: s.reqGramTextAnimationPrivateLetSelectionLiquidStretch = Int(value)
              case .selectionSide: s.reqGramTextAnimationPrivateLetSelectionLiquidSide = Int(value)
             }
         },
           setOneFromManyValue: { setting in
               let presentationData = context.sharedContext.currentPresentationData.with { $0 }
               let lang = presentationData.strings.baseLanguageCode
               switch setting {
               case .scamInterval:
                   let sheet = ActionSheetController(presentationData: presentationData)
                   let items = SGScamRegistryRefreshInterval.allCases.map { interval in
                       ActionSheetButtonItem(title: interval.title, color: .accent, action: { [weak sheet] in
                           var settings = SGScamRegistryService.shared.currentSettings()
                           settings.interval = interval
                           SGScamRegistryService.shared.updateSettings(settings)
                           sheet?.dismissAnimated()
                       })
                   }
                   sheet.setItemGroups([ActionSheetItemGroup(items: items)])
                   presentControllerImpl?(sheet, nil)
               case .nowPlayingPlace:
                   let sheet = ActionSheetController(presentationData: presentationData)
                   let items = SGNowPlayingPlace.allCases.map { place in
                       let title: String
                       switch place {
                       case .bio: title = i18n("ReqGram.Plugin.NowPlaying.Place.Bio", lang)
                       case .playlist: title = i18n("ReqGram.Plugin.NowPlaying.Place.Playlist", lang)
                       case .location: title = i18n("ReqGram.Plugin.NowPlaying.Place.Location", lang)
                       }
                       return ActionSheetButtonItem(title: title, color: .accent, action: { [weak sheet] in
                           SGNowPlayingService.shared.updateSettings { settings in
                               settings.place = place
                           }
                           sheet?.dismissAnimated()
                       })
                   }
                   sheet.setItemGroups([ActionSheetItemGroup(items: items)])
                   presentControllerImpl?(sheet, nil)
               case .nowPlayingSource:
                   let sheet = ActionSheetController(presentationData: presentationData)
                   var items: [ActionSheetButtonItem] = [
                       ActionSheetButtonItem(title: i18n("ReqGram.Plugin.NowPlaying.Source.Auto", lang), color: .accent, action: { [weak sheet] in
                           SGNowPlayingService.shared.updateSettings { settings in
                               settings.source = .auto
                           }
                           sheet?.dismissAnimated()
                       })
                   ]
                    items += SGNowPlayingPlatformId.allCases.map { platform in
                        ActionSheetButtonItem(title: i18n(platform.displayKey, lang), color: .accent, action: { [weak sheet] in
                            SGNowPlayingService.shared.updateSettings { settings in
                                settings.source = .platform(platform)
                            }
                            sheet?.dismissAnimated()
                        })
                    }
                    sheet.setItemGroups([ActionSheetItemGroup(items: items)])
                    presentControllerImpl?(sheet, nil)
                case .nowPlayingCardType:
                    let sheet = ActionSheetController(presentationData: presentationData)
                    let items = SGNowPlayingCardType.allCases.map { cardType in
                        ActionSheetButtonItem(title: i18n(cardType.displayKey, lang), color: .accent, action: { [weak sheet] in
                            SGNowPlayingService.shared.updateSettings { settings in
                                settings.cardType = cardType
                            }
                            sheet?.dismissAnimated()
                        })
                    }
                    sheet.setItemGroups([ActionSheetItemGroup(items: items)])
                    presentControllerImpl?(sheet, nil)
                case .nowPlayingCardBackground:
                    let sheet = ActionSheetController(presentationData: presentationData)
                    let items = SGNowPlayingCardBackground.allCases.map { background in
                        ActionSheetButtonItem(title: i18n(background.displayKey, lang), color: .accent, action: { [weak sheet] in
                            SGNowPlayingService.shared.updateSettings { settings in
                                settings.cardBackground = background
                            }
                            sheet?.dismissAnimated()
                        })
                    }
                    sheet.setItemGroups([ActionSheetItemGroup(items: items)])
                    presentControllerImpl?(sheet, nil)
                case .nowPlayingCardFont:
                    let sheet = ActionSheetController(presentationData: presentationData)
                    let items = SGNowPlayingCardFont.allCases.map { font in
                        ActionSheetButtonItem(title: i18n(font.displayKey, lang), color: .accent, action: { [weak sheet] in
                            SGNowPlayingService.shared.updateSettings { settings in
                                settings.cardFont = font
                            }
                            sheet?.dismissAnimated()
                        })
                    }
                    sheet.setItemGroups([ActionSheetItemGroup(items: items)])
                    presentControllerImpl?(sheet, nil)
                case .nowPlayingCardLinkStyle:
                    let sheet = ActionSheetController(presentationData: presentationData)
                    let items = SGNowPlayingCardLinkStyle.allCases.map { style in
                        ActionSheetButtonItem(title: i18n(style.displayKey, lang), color: .accent, action: { [weak sheet] in
                            SGNowPlayingService.shared.updateSettings { settings in
                                settings.cardLinkStyle = style
                            }
                            sheet?.dismissAnimated()
                        })
                    }
                    sheet.setItemGroups([ActionSheetItemGroup(items: items)])
                    presentControllerImpl?(sheet, nil)
                 }
             },
           openDisclosureLink: { link in
               if case let .nowPlayingToken(platform) = link {
                   pushControllerImpl?(reqGramNowPlayingTokenController(context: context, platform: platform))
               }
           },
           action: { action in
               if case .scamRefresh = action, plugin == .scamBaseWriter {
                  // The service's own `refreshing` flag is the source of truth for
                  // re-entrancy; this check only turns a silently swallowed
                  // duplicate tap into a visible message instead of changing the
                  // actual guarding behavior (which happens again, safely, inside
                  // `refresh` regardless of this check).
                  if SGScamRegistryService.shared.isRefreshing() {
                      presentControllerImpl?(textAlertController(
                          context: context,
                          title: nil,
                          text: i18n("ReqGram.Plugin.ScamBaseWriter.Refresh.AlreadyInProgress", lang),
                          actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
                          ]), nil)
                      return
                  }
                  // `SGScamRegistryService.refresh` hops onto its own private
                  // serial queue immediately (see `refresh(completion:)` in
                  // SGScamRegistryService.swift) and performs the entire fetch —
                  // including the paginated network requests and the regex
                  // parsing pass — off the main thread. This call returns
                  // immediately; the row's "Scanning…" label (driven by
                  // `pluginSettingsState` observing `.sgScamRegistryRefreshDidStart`)
                  // is the only synchronous-looking feedback, and the rest of the
                  // app remains fully interactive while this runs.
                   SGScamRegistryService.shared.refresh { result in
                       DispatchQueue.main.async {
                           let message: String
                            switch result {
                            case let .updated(count, _):
                                message = "\(i18n("ReqGram.Plugin.ScamBaseWriter.Refresh.Done", lang)) (\(count))"
                            case .alreadyInProgress:
                                message = i18n("ReqGram.Plugin.ScamBaseWriter.Refresh.AlreadyInProgress", lang)
                            case .failed:
                                message = i18n("ReqGram.Plugin.ScamBaseWriter.Refresh.Failed", lang)
                            }
                           presentControllerImpl?(textAlertController(
                               context: context,
                               title: nil,
                               text: message,
                               actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
                               ]), nil)
                       }
                   }
                   return
               }
               if case .nowPlayingCheck = action, plugin == .nowPlaying {
                   // `checkNow` hops onto the service's private serial queue and
                   // polls every configured platform concurrently; the row's
                   // "Checking…" label (driven by `pluginSettingsState` observing
                   // the poll notifications) is the immediate feedback.
                   SGNowPlayingService.shared.checkNow { status in
                       DispatchQueue.main.async {
                           let text = status.isEmpty ? i18n("ReqGram.Plugin.NowPlaying.Status.Idle", lang) : status
                           presentControllerImpl?(textAlertController(
                               context: context,
                               title: nil,
                               text: text,
                               actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
                               ]), nil)
                       }
                   }
                    return
                }
                if case .textAnimationRestoreDefaults = action, plugin == .textAnimationPrivateLet {
                    // Assignments post the shared didChange notification, so
                    // the list rebuilds itself with restored values instantly.
                    SGSimpleSettings.shared.resetReqGramTextAnimationPrivateLet()
                    return
                }
           },
           searchInput: { text in
               if plugin == .nowPlaying {
                   SGNowPlayingService.shared.setDefaultText(text)
               }
           }
      )
       let pluginSettingsState = Signal<Void, NoError> { subscriber in
          subscriber.putNext(())
          let observers = [
              NotificationCenter.default.addObserver(forName: UserDefault<Bool>.didChangeNotification, object: nil, queue: .main) { _ in subscriber.putNext(()) },
              NotificationCenter.default.addObserver(forName: .sgScamRegistryDidChange, object: nil, queue: .main) { _ in subscriber.putNext(()) },
              NotificationCenter.default.addObserver(forName: .sgScamRegistrySettingsDidChange, object: nil, queue: .main) { _ in subscriber.putNext(()) },
               NotificationCenter.default.addObserver(forName: .sgScamRegistryRefreshDidStart, object: nil, queue: .main) { _ in subscriber.putNext(()) },
               NotificationCenter.default.addObserver(forName: .sgScamRegistryRefreshDidFinish, object: nil, queue: .main) { _ in subscriber.putNext(()) },
               NotificationCenter.default.addObserver(forName: .sgNowPlayingSettingsDidChange, object: nil, queue: .main) { _ in subscriber.putNext(()) },
               NotificationCenter.default.addObserver(forName: .sgNowPlayingPollDidStart, object: nil, queue: .main) { _ in subscriber.putNext(()) },
               NotificationCenter.default.addObserver(forName: .sgNowPlayingPollDidFinish, object: nil, queue: .main) { _ in subscriber.putNext(()) }
           ]
          return ActionDisposable { observers.forEach { NotificationCenter.default.removeObserver($0) } }
      }
     let signal = combineLatest(context.sharedContext.presentationData, pluginSettingsState)
     |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
         let lang = presentationData.strings.baseLanguageCode
         let currentSettings = SGSimpleSettings.shared
         let currentEnabled: Bool
         switch plugin {
         case .localEdictorAndZwyLib:
             currentEnabled = currentSettings.reqGramLocalEdictorEnabled
         case .textAnimationPrivateLet:
             currentEnabled = currentSettings.reqGramTextAnimationPrivateLetEnabled
          case .scamBaseWriter:
               currentEnabled = SGScamRegistryService.shared.currentSettings().enabled
          case .nowPlaying:
              currentEnabled = SGNowPlayingService.shared.currentSettings().isEnabled
           }
         let counter = SGItemListCounter()
          var entries: [ReqGramPluginEntry] = []
          if case .textAnimationPrivateLet = plugin {
              entries.append(.textAnimationPreview(
                  id: counter.count,
                  section: .settings,
                  configuration: SGTextAnimationPreviewConfiguration(
                      enabled: currentEnabled,
                      duration: Double(currentSettings.reqGramTextAnimationPrivateLetDuration) / 1000.0,
                      slideDistance: currentSettings.reqGramTextAnimationPrivateLetSlideEnabled ? CGFloat(currentSettings.reqGramTextAnimationPrivateLetSlideDist) : 0.0,
                      blurEnabled: currentSettings.reqGramTextAnimationPrivateLetBlurEnabled,
                       blurDuration: Double(currentSettings.reqGramTextAnimationPrivateLetBlurDuration) / 1000.0,
                      blurRadius: CGFloat(currentSettings.reqGramTextAnimationPrivateLetBlurRadius),
                       blurTextDelay: Double(currentSettings.reqGramTextAnimationPrivateLetBlurTextDelay) / 100.0 * (Double(currentSettings.reqGramTextAnimationPrivateLetBlurDuration) / 1000.0),
                      scaleEnabled: currentSettings.reqGramTextAnimationPrivateLetScaleEnabled,
                      scaleStart: CGFloat(currentSettings.reqGramTextAnimationPrivateLetScaleStart),
                      rotateEnabled: currentSettings.reqGramTextAnimationPrivateLetRotateEnabled,
                      rotateAngle: CGFloat(currentSettings.reqGramTextAnimationPrivateLetRotateAngle),
                      ignoreSpaces: currentSettings.reqGramTextAnimationPrivateLetIgnoreSpaces
                  ),
                  title: i18n("ReqGram.Animation.Preview.Title", lang),
                  sampleText: i18n("ReqGram.Animation.Preview.Sample", lang),
                  accessibilityHint: i18n("ReqGram.Animation.Preview.AccessibilityHint", lang)
               ))
          }
            entries.append(.toggle(id: counter.count, section: .settings, settingName: .enabled, value: currentEnabled, text: i18n("ReqGram.Plugin.Enable", lang), enabled: true))
           if plugin == .scamBaseWriter {
               let scamSettings = SGScamRegistryService.shared.currentSettings()
               let isScanning = SGScamRegistryService.shared.isRefreshing()
               entries.append(.oneFromManySelector(id: counter.count, section: .settings, settingName: .scamInterval, text: i18n("ReqGram.Plugin.ScamBaseWriter.Interval", lang), value: scamSettings.interval.title, enabled: true))
               // While a scan is in flight the row is relabeled and disabled
               // (not removed) so the user gets immediate, visible, non-blocking
               // feedback instead of being able to fire overlapping scans that
               // the `refreshing` guard would otherwise silently swallow.
               entries.append(.action(
                   id: counter.count,
                   section: .settings,
                   actionType: .scamRefresh,
                   text: isScanning ? i18n("ReqGram.Plugin.ScamBaseWriter.Refresh.InProgress", lang) : i18n("ReqGram.Plugin.ScamBaseWriter.Refresh", lang),
                   kind: isScanning ? .disabled : .generic
               ))
                entries.append(.notice(id: counter.count, section: .settings, text: i18n("ReqGram.Plugin.ScamBaseWriter.Status", lang) + ": " + String(SGScamRegistryService.shared.snapshot().count)))
            }
             if plugin == .nowPlaying {
                 let nowPlayingSettings = SGNowPlayingService.shared.currentSettings()
                 let placeTitle: String
                 switch nowPlayingSettings.place {
                 case .bio: placeTitle = i18n("ReqGram.Plugin.NowPlaying.Place.Bio", lang)
                 case .playlist: placeTitle = i18n("ReqGram.Plugin.NowPlaying.Place.Playlist", lang)
                 case .location: placeTitle = i18n("ReqGram.Plugin.NowPlaying.Place.Location", lang)
                 }
                 entries.append(.oneFromManySelector(id: counter.count, section: .settings, settingName: .nowPlayingPlace, text: i18n("ReqGram.Plugin.NowPlaying.StreamPlace", lang), value: placeTitle, enabled: true))
                 entries.append(.searchInput(
                     id: counter.count,
                     section: .settings,
                     title: NSAttributedString(string: i18n("ReqGram.Plugin.NowPlaying.DefaultText", lang)),
                     text: nowPlayingSettings.defaultText,
                     placeholder: i18n("ReqGram.Plugin.NowPlaying.DefaultText.Placeholder", lang)
                 ))
                 entries.append(.header(id: counter.count, section: .settings, text: i18n("ReqGram.Plugin.NowPlaying.Section.Platforms", lang), badge: nil))
                 let sourceTitle: String
                 switch nowPlayingSettings.source {
                 case .auto:
                     sourceTitle = i18n("ReqGram.Plugin.NowPlaying.Source.Auto", lang)
                 case let .platform(platform):
                     sourceTitle = i18n(platform.displayKey, lang)
                 }
                 entries.append(.oneFromManySelector(id: counter.count, section: .settings, settingName: .nowPlayingSource, text: i18n("ReqGram.Plugin.NowPlaying.Source", lang), value: sourceTitle, enabled: true))
                 for platform in SGNowPlayingPlatformId.allCases {
                     entries.append(.disclosure(id: counter.count, section: .settings, link: .nowPlayingToken(platform), text: i18n(platform.displayKey, lang)))
                 }
                 entries.append(.header(id: counter.count, section: .settings, text: i18n("ReqGram.Plugin.NowPlaying.Section.Sending", lang), badge: nil))
                 entries.append(.oneFromManySelector(id: counter.count, section: .settings, settingName: .nowPlayingCardType, text: i18n("ReqGram.Plugin.NowPlaying.Card.Type", lang), value: i18n(nowPlayingSettings.cardType.displayKey, lang), enabled: true))
                 entries.append(.oneFromManySelector(id: counter.count, section: .settings, settingName: .nowPlayingCardBackground, text: i18n("ReqGram.Plugin.NowPlaying.Card.Background", lang), value: i18n(nowPlayingSettings.cardBackground.displayKey, lang), enabled: true))
                  entries.append(.oneFromManySelector(id: counter.count, section: .settings, settingName: .nowPlayingCardFont, text: i18n("ReqGram.Plugin.NowPlaying.Card.Font", lang), value: i18n(nowPlayingSettings.cardFont.displayKey, lang), enabled: true))
                  entries.append(.oneFromManySelector(id: counter.count, section: .settings, settingName: .nowPlayingCardLinkStyle, text: i18n("ReqGram.Plugin.NowPlaying.Card.LinkStyle", lang), value: i18n(nowPlayingSettings.cardLinkStyle.displayKey, lang), enabled: true))
                  entries.append(.toggle(id: counter.count, section: .settings, settingName: .nowPlayingUseSongLink, value: nowPlayingSettings.useSongLink, text: i18n("ReqGram.Plugin.NowPlaying.Card.SongLink", lang), enabled: true))
                 entries.append(.notice(id: counter.count, section: .settings, text: i18n("ReqGram.Plugin.NowPlaying.Card.SongLink.Hint", lang)))
                 entries.append(.header(id: counter.count, section: .settings, text: i18n("ReqGram.Plugin.NowPlaying.Section.Diagnostics", lang), badge: nil))
                 let isChecking = SGNowPlayingService.shared.isPollingNow
                 entries.append(.action(
                     id: counter.count,
                     section: .settings,
                     actionType: .nowPlayingCheck,
                     text: isChecking ? i18n("ReqGram.Plugin.NowPlaying.Check.InProgress", lang) : i18n("ReqGram.Plugin.NowPlaying.Check", lang),
                     kind: isChecking ? .disabled : .generic
                 ))
                 let status = SGNowPlayingService.shared.lastStatus
                 entries.append(.notice(id: counter.count, section: .settings, text: i18n("ReqGram.Plugin.NowPlaying.Status", lang) + ": " + (status.isEmpty ? i18n("ReqGram.Plugin.NowPlaying.Status.Idle", lang) : status)))
             }
          if case .textAnimationPrivateLet = plugin {

             let animationEntries: [ReqGramPluginEntry] = [
                 .toggle(id: counter.count, section: .settings, settingName: .blur, value: currentSettings.reqGramTextAnimationPrivateLetBlurEnabled, text: i18n("ReqGram.Animation.Blur", lang), enabled: true),
                 .toggle(id: counter.count, section: .settings, settingName: .slide, value: currentSettings.reqGramTextAnimationPrivateLetSlideEnabled, text: i18n("ReqGram.Animation.Slide", lang), enabled: true),
                 .toggle(id: counter.count, section: .settings, settingName: .scale, value: currentSettings.reqGramTextAnimationPrivateLetScaleEnabled, text: i18n("ReqGram.Animation.Scale", lang), enabled: true),
                  .toggle(id: counter.count, section: .settings, settingName: .rotate, value: currentSettings.reqGramTextAnimationPrivateLetRotateEnabled, text: i18n("ReqGram.Animation.Rotate", lang), enabled: true),
                  .toggle(id: counter.count, section: .settings, settingName: .deleteAnimation, value: currentSettings.reqGramTextAnimationPrivateLetDeleteAnimEnabled, text: i18n("ReqGram.Animation.DeleteParticles", lang), enabled: true),
                   .toggle(id: counter.count, section: .settings, settingName: .cursor, value: currentSettings.reqGramTextAnimationPrivateLetCursorEnabled, text: i18n("ReqGram.Animation.Cursor", lang), enabled: true),
                   .toggle(id: counter.count, section: .settings, settingName: .liquidCursor, value: currentSettings.reqGramTextAnimationPrivateLetLiquidCursorEnabled, text: i18n("ReqGram.Animation.LiquidCursor", lang), enabled: true),
                 .toggle(id: counter.count, section: .settings, settingName: .ignoreSpaces, value: currentSettings.reqGramTextAnimationPrivateLetIgnoreSpaces, text: i18n("ReqGram.Animation.IgnoreSpaces", lang), enabled: true),
                   .toggle(id: counter.count, section: .settings, settingName: .animateAllLines, value: currentSettings.reqGramTextAnimationPrivateLetAnimateAllLines, text: i18n("ReqGram.Animation.AllLines", lang), enabled: true),
             ]
             for entry in animationEntries {
                 entries.append(entry)
             }

             let animationSliderEntries: [ReqGramPluginEntry] = [
                 .percentageSlider(id: counter.count, section: .settings, settingName: .duration, value: reqGramAnimationValue(currentSettings.reqGramTextAnimationPrivateLetDuration, minimum: 50, maximum: 600), title: i18n("ReqGram.Animation.Duration", lang), unit: " ms", minimum: 50, maximum: 600),
                 .percentageSlider(id: counter.count, section: .settings, settingName: .blurDuration, value: reqGramAnimationValue(currentSettings.reqGramTextAnimationPrivateLetBlurDuration, minimum: 50, maximum: 600), title: i18n("ReqGram.Animation.BlurDuration", lang), unit: " ms", minimum: 50, maximum: 600),
                  .percentageSlider(id: counter.count, section: .settings, settingName: .blurRadius, value: reqGramAnimationValue(currentSettings.reqGramTextAnimationPrivateLetBlurRadius, minimum: 0, maximum: 30), title: i18n("ReqGram.Animation.BlurRadius", lang), unit: " pt", minimum: 0, maximum: 30),
                   .percentageSlider(id: counter.count, section: .settings, settingName: .blurTextDelay, value: reqGramAnimationValue(currentSettings.reqGramTextAnimationPrivateLetBlurTextDelay, minimum: 0, maximum: 99), title: i18n("ReqGram.Animation.BlurDelay", lang), unit: "%", minimum: 0, maximum: 99),
                  .percentageSlider(id: counter.count, section: .settings, settingName: .slideDist, value: reqGramAnimationValue(currentSettings.reqGramTextAnimationPrivateLetSlideDist, minimum: 0, maximum: 20), title: i18n("ReqGram.Animation.SlideDistance", lang), unit: " pt", minimum: 0, maximum: 20),
                  .percentageSlider(id: counter.count, section: .settings, settingName: .scaleStart, value: Int32(min(max(currentSettings.reqGramTextAnimationPrivateLetScaleStart * 100.0, 0.0), 200.0)), title: i18n("ReqGram.Animation.ScaleStart", lang), unit: "%", minimum: 0, maximum: 200),
                   .percentageSlider(id: counter.count, section: .settings, settingName: .rotateAngle, value: reqGramAnimationValue(currentSettings.reqGramTextAnimationPrivateLetRotateAngle, minimum: -180, maximum: 180), title: i18n("ReqGram.Animation.Rotation", lang), unit: "°", minimum: -180, maximum: 180),
                  .percentageSlider(id: counter.count, section: .settings, settingName: .particleCount, value: reqGramAnimationValue(currentSettings.reqGramTextAnimationPrivateLetParticleCount, minimum: 1, maximum: 16), title: i18n("ReqGram.Animation.ParticleCount", lang), unit: "", minimum: 1, maximum: 16),
                  .percentageSlider(id: counter.count, section: .settings, settingName: .particleSpeed, value: reqGramAnimationValue(currentSettings.reqGramTextAnimationPrivateLetParticleSpeed, minimum: 0, maximum: 100), title: i18n("ReqGram.Animation.ParticleSpeed", lang), unit: "%", minimum: 0, maximum: 100),
                  .percentageSlider(id: counter.count, section: .settings, settingName: .particleSpread, value: reqGramAnimationValue(currentSettings.reqGramTextAnimationPrivateLetParticleSpread, minimum: 0, maximum: 100), title: i18n("ReqGram.Animation.ParticleSpread", lang), unit: "%", minimum: 0, maximum: 100),
                  .percentageSlider(id: counter.count, section: .settings, settingName: .particleSize, value: reqGramAnimationValue(currentSettings.reqGramTextAnimationPrivateLetParticleSize, minimum: 1, maximum: 100), title: i18n("ReqGram.Animation.ParticleSize", lang), unit: "%", minimum: 1, maximum: 100),
                   .percentageSlider(id: counter.count, section: .settings, settingName: .cursorSpeed, value: reqGramAnimationValue(currentSettings.reqGramTextAnimationPrivateLetCursorSpeed, minimum: 1, maximum: 100), title: i18n("ReqGram.Animation.CursorSpeed", lang), unit: "%", minimum: 1, maximum: 100),
                   .percentageSlider(id: counter.count, section: .settings, settingName: .cursorWidth, value: reqGramAnimationValue(currentSettings.reqGramTextAnimationPrivateLetCursorWidth, minimum: 1, maximum: 12), title: i18n("ReqGram.Animation.CursorWidth", lang), unit: " pt", minimum: 1, maximum: 12),
                  .percentageSlider(id: counter.count, section: .settings, settingName: .liquidScale, value: reqGramAnimationValue(currentSettings.reqGramTextAnimationPrivateLetLiquidScaleFactor, minimum: 0, maximum: 100), title: i18n("ReqGram.Animation.LiquidScale", lang), unit: "%", minimum: 0, maximum: 100),
                  .percentageSlider(id: counter.count, section: .settings, settingName: .selectionEffect, value: reqGramAnimationValue(currentSettings.reqGramTextAnimationPrivateLetSelectionCursorEffect, minimum: 0, maximum: 2), title: i18n("ReqGram.Animation.SelectionEffect", lang), unit: "", minimum: 0, maximum: 2),
                  .percentageSlider(id: counter.count, section: .settings, settingName: .selectionStretch, value: reqGramAnimationValue(currentSettings.reqGramTextAnimationPrivateLetSelectionLiquidStretch, minimum: 0, maximum: 100), title: i18n("ReqGram.Animation.SelectionStretch", lang), unit: "%", minimum: 0, maximum: 100),
                  .percentageSlider(id: counter.count, section: .settings, settingName: .selectionSide, value: reqGramAnimationValue(currentSettings.reqGramTextAnimationPrivateLetSelectionLiquidSide, minimum: 0, maximum: 100), title: i18n("ReqGram.Animation.SelectionSide", lang), unit: "%", minimum: 0, maximum: 100)
               ]
              for entry in animationSliderEntries {
                  entries.append(entry)
              }

              entries.append(.action(
                  id: counter.count,
                  section: .settings,
                  actionType: .textAnimationRestoreDefaults,
                  text: i18n("ReqGram.Animation.RestoreDefaults", lang),
                  kind: .generic
              ))
          }
         entries.append(.header(id: counter.count, section: .information, text: i18n("ReqGram.Plugin.Information", lang), badge: nil))
          sgAppendNotice(to: &entries, counter: counter, section: .information, text: description)
         return (
            ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(title),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
            ),
            (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil), arguments)
         )
    }
    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    return controller
}

// MARK: - Now Playing token screen

private enum ReqGramTokenAction: Hashable {
    case clear
}

/// One platform's token / username / cookie input of the Now Playing plugin.
/// Saves per keystroke (the service debounces the poll restart).
private func reqGramNowPlayingTokenController(context: AccountContext, platform: SGNowPlayingPlatformId) -> ViewController {
    typealias Entry = SGItemListUIEntry<ReqGramPluginSection, ReqGramPluginUnused, ReqGramPluginUnused, ReqGramPluginUnused, ReqGramPluginUnused, ReqGramTokenAction>
    let arguments = SGItemListArguments<ReqGramPluginUnused, ReqGramPluginUnused, ReqGramPluginUnused, ReqGramPluginUnused, ReqGramTokenAction>(
        context: context,
        action: { action in
            if case .clear = action {
                SGNowPlayingService.shared.setToken(platform: platform, value: nil)
            }
        },
        searchInput: { text in
            SGNowPlayingService.shared.setToken(platform: platform, value: text)
        }
    )
    let tokenState = Signal<Void, NoError> { subscriber in
        subscriber.putNext(())
        let observers = [
            NotificationCenter.default.addObserver(forName: .sgNowPlayingSettingsDidChange, object: nil, queue: .main) { _ in subscriber.putNext(()) }
        ]
        return ActionDisposable { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
    let signal = combineLatest(context.sharedContext.presentationData, tokenState)
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        let counter = SGItemListCounter()
        let token = SGNowPlayingService.shared.currentSettings().token(for: platform) ?? ""
        let entries: [Entry] = [
            .searchInput(
                id: counter.count,
                section: .settings,
                title: NSAttributedString(string: i18n(platform.displayKey, lang)),
                text: token,
                placeholder: i18n("ReqGram.Plugin.NowPlaying.Token.Placeholder", lang)
            ),
            .action(id: counter.count, section: .settings, actionType: .clear, text: i18n("ReqGram.Plugin.NowPlaying.Token.Clear", lang), kind: token.isEmpty ? .disabled : .destructive),
            .header(id: counter.count, section: .information, text: i18n("ReqGram.Plugin.Information", lang), badge: nil),
            .notice(id: counter.count, section: .information, text: i18n("ReqGram.Plugin.NowPlaying.Token.Hint.\(platform.rawValue)", lang))
        ]
        return (
            ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(i18n(platform.displayKey, lang)),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
            ),
            (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil), arguments as Any)
        )
    }
    return ItemListController(context: context, state: signal)
}

public func supportDevelopmentController(context: AccountContext, navigationController: NavigationController? = nil) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode
    let content: [AnyComponentWithIdentity<AlertComponentEnvironment>] = [
        AnyComponentWithIdentity(id: "hero", component: AnyComponent(ReqGramSupportHeroComponent(accessibilityLabel: i18n("ReqGram.Support.HeroAccessibility", lang)))),
        AnyComponentWithIdentity(id: "title", component: AnyComponent(AlertTitleComponent(title: i18n("ReqGram.Support.Title", lang), alignment: .center))),
        AnyComponentWithIdentity(id: "explanation", component: AnyComponent(AlertTextComponent(content: .plain(i18n("ReqGram.Support.Explanation", lang)), alignment: .center))),
        AnyComponentWithIdentity(id: "steps", component: AnyComponent(ReqGramSupportStepsComponent(steps: [
            .init(iconName: "creditcard.fill", title: i18n("ReqGram.Support.DonationStep.Title", lang), body: i18n("ReqGram.Support.DonationStep.Body", lang)),
            .init(iconName: "doc.text.fill", title: i18n("ReqGram.Support.ProofStep.Title", lang), body: i18n("ReqGram.Support.ProofStep.Body", lang)),
            .init(iconName: "checkmark.seal.fill", title: i18n("ReqGram.Support.BadgeStep.Title", lang), body: i18n("ReqGram.Support.BadgeStep.Body", lang))
        ])))
    ]
    var actions: [AlertScreen.Action] = []
    func appendAction(_ action: ReqGramBadgeConfiguration.Action, titleKey: String) {
        guard let url = ReqGramBadgeConfiguration.validatedActionURL(action) else {
            return
        }
        actions.append(.init(title: i18n(titleKey, lang), type: .generic, action: {
            context.sharedContext.openExternalUrl(
                context: context,
                urlContext: .generic,
                url: url.absoluteString,
                forceExternal: false,
                presentationData: context.sharedContext.currentPresentationData.with { $0 },
                navigationController: navigationController,
                dismissInput: {}
            )
        }))
    }
    appendAction(.donate, titleKey: "ReqGram.Support.Action.Donate")
    appendAction(.proofOfPayment, titleKey: "ReqGram.Support.Action.SendProof")
    appendAction(.learnMore, titleKey: "ReqGram.Support.Action.LearnMore")
    appendAction(.officialResource, titleKey: "ReqGram.Support.Action.OfficialResource")
    actions.append(.init(title: presentationData.strings.Common_Close))
    return AlertScreen(
        context: context,
        configuration: .init(actionAlignment: .vertical),
        content: content,
        actions: actions
    )
}

private final class ReqGramSupportHeroComponent: Component {
    typealias EnvironmentType = AlertComponentEnvironment

    let accessibilityLabel: String

    init(accessibilityLabel: String) {
        self.accessibilityLabel = accessibilityLabel
    }

    static func == (lhs: ReqGramSupportHeroComponent, rhs: ReqGramSupportHeroComponent) -> Bool {
        return lhs.accessibilityLabel == rhs.accessibilityLabel
    }

    final class View: UIView {
        private let circleView = UIView()
        private let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.circleView.backgroundColor = .systemBlue
            self.circleView.layer.cornerRadius = 32.0
            self.label.text = ReqGramBadgeConfiguration.heroMonogram
            self.label.textColor = .white
            self.label.font = .systemFont(ofSize: 36.0, weight: .semibold)
            self.label.textAlignment = .center
            self.circleView.addSubview(self.label)
            self.addSubview(self.circleView)
            self.isAccessibilityElement = true
        }

        required init?(coder: NSCoder) {
            preconditionFailure()
        }

        func update(component: ReqGramSupportHeroComponent, availableSize: CGSize, environment: Environment<AlertComponentEnvironment>) -> CGSize {
            let theme = environment[AlertComponentEnvironment.self].theme
            self.circleView.backgroundColor = theme.actionSheet.controlAccentColor
            self.label.textColor = theme.actionSheet.primaryTextColor
            let size = CGSize(width: 64.0, height: 68.0)
            self.circleView.frame = CGRect(x: floor((availableSize.width - 64.0) * 0.5), y: 2.0, width: 64.0, height: 64.0)
            self.label.frame = self.circleView.bounds
            self.accessibilityLabel = component.accessibilityLabel
            self.accessibilityTraits = .image
            return CGSize(width: availableSize.width, height: size.height)
        }
    }

    func makeView() -> View {
        return View(frame: .zero)
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<AlertComponentEnvironment>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, environment: environment)
    }
}

private final class ReqGramSupportStepsComponent: Component {
    typealias EnvironmentType = AlertComponentEnvironment

    struct Step: Equatable {
        let iconName: String
        let title: String
        let body: String
    }

    let steps: [Step]

    init(steps: [Step]) {
        self.steps = steps
    }

    static func == (lhs: ReqGramSupportStepsComponent, rhs: ReqGramSupportStepsComponent) -> Bool {
        return lhs.steps == rhs.steps
    }

    final class View: UIView {
        private final class StepView: UIView {
            let iconBackgroundView = UIView()
            let iconView = UIImageView()
            let titleLabel = UILabel()
            let bodyLabel = UILabel()

            override init(frame: CGRect) {
                super.init(frame: frame)
                self.layer.cornerRadius = 12.0
                self.iconBackgroundView.layer.cornerRadius = 15.0
                self.iconView.contentMode = .center
                self.titleLabel.font = .systemFont(ofSize: 14.0, weight: .semibold)
                self.titleLabel.numberOfLines = 0
                self.bodyLabel.font = .systemFont(ofSize: 13.0, weight: .regular)
                self.bodyLabel.numberOfLines = 0
                self.addSubview(self.iconBackgroundView)
                self.iconBackgroundView.addSubview(self.iconView)
                self.addSubview(self.titleLabel)
                self.addSubview(self.bodyLabel)
                self.isAccessibilityElement = true
            }

            required init?(coder: NSCoder) {
                preconditionFailure()
            }
        }

        private var stepViews: [StepView] = []

        func update(component: ReqGramSupportStepsComponent, availableSize: CGSize, environment: Environment<AlertComponentEnvironment>) -> CGSize {
            let environment = environment[AlertComponentEnvironment.self]
            while self.stepViews.count < component.steps.count {
                let stepView = StepView()
                self.stepViews.append(stepView)
                self.addSubview(stepView)
            }
            while self.stepViews.count > component.steps.count {
                self.stepViews.removeLast().removeFromSuperview()
            }

        let iconColor = environment.theme.actionSheet.controlAccentColor
        let primaryColor = environment.theme.actionSheet.primaryTextColor
        let secondaryColor = environment.theme.actionSheet.secondaryTextColor
        let cardColor = primaryColor.withAlphaComponent(0.07)
            let textOriginX: CGFloat = 48.0
            let textWidth = max(1.0, availableSize.width - textOriginX - 10.0)
            let cardSpacing: CGFloat = 7.0
            var originY: CGFloat = 0.0

            for (index, step) in component.steps.enumerated() {
                let stepView = self.stepViews[index]
                stepView.backgroundColor = cardColor
                stepView.iconBackgroundView.backgroundColor = iconColor.withAlphaComponent(0.14)
                stepView.iconView.image = UIImage(systemName: step.iconName)?.withRenderingMode(.alwaysTemplate)
                stepView.iconView.tintColor = iconColor
                stepView.titleLabel.text = step.title
                stepView.titleLabel.textColor = primaryColor
                stepView.bodyLabel.text = step.body
                stepView.bodyLabel.textColor = secondaryColor

                let titleSize = stepView.titleLabel.sizeThatFits(CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))
                let bodySize = stepView.bodyLabel.sizeThatFits(CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))
                let cardHeight = max(58.0, 9.0 + titleSize.height + 2.0 + bodySize.height + 9.0)
                stepView.frame = CGRect(x: 0.0, y: originY, width: availableSize.width, height: cardHeight)
                stepView.iconBackgroundView.frame = CGRect(x: 10.0, y: floor((cardHeight - 30.0) * 0.5), width: 30.0, height: 30.0)
                stepView.iconView.frame = stepView.iconBackgroundView.bounds
                stepView.titleLabel.frame = CGRect(x: textOriginX, y: 9.0, width: textWidth, height: titleSize.height)
                stepView.bodyLabel.frame = CGRect(x: textOriginX, y: 11.0 + titleSize.height, width: textWidth, height: bodySize.height)
                stepView.accessibilityLabel = "\(step.title). \(step.body)"
                stepView.accessibilityTraits = .staticText
                originY += cardHeight + cardSpacing
            }
            if !component.steps.isEmpty {
                originY -= cardSpacing
            }
            return CGSize(width: availableSize.width, height: originY)
        }
    }

    func makeView() -> View {
        return View(frame: .zero)
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<AlertComponentEnvironment>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, environment: environment)
    }
}
