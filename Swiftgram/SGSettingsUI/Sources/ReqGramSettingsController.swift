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
import SGItemListUI
import SGStrings
import SGSimpleSettings
import AyuGram

private enum ReqGramSection: Int32, SGItemListSection {
    case plugins
    case support
}

private enum ReqGramBoolSetting: Hashable {
    case giftIdEnabled
    case deletedGiftSenderEnabled
    case zwyLibEnabled
    case localEdictorEnabled
    case zwyNoForwardLimitEnabled
    case textAnimationPrivateLetEnabled
}
private enum ReqGramSliderSetting: Hashable {
    case duration, blurDuration, blurRadius, blurTextDelay, slideDist, scaleStart, rotateAngle
    case particleCount, particleSpeed, particleSpread, particleSize, cursorSpeed, cursorWidth, liquidScale, selectionEffect, selectionStretch, selectionSide
}

private func reqGramAnimationValue(_ value: Int, minimum: Int, maximum: Int) -> Int32 {
    return Int32(min(max(value, minimum), maximum))
}

private enum ReqGramDisclosure: Hashable {
    case plugin(ReqGramPlugin)
    case other
}

private enum ReqGramPlugin: Hashable {
    case giftId
    case sendGiftById
    case deletedGiftSender
    case localEdictorAndZwyLib
    case zwyNoForwardLimit
    case textAnimationPrivateLet
}

private enum ReqGramUnused: Hashable {
    case value
}

private typealias ReqGramEntry = SGItemListUIEntry<ReqGramSection, ReqGramBoolSetting, ReqGramSliderSetting, ReqGramUnused, ReqGramDisclosure, ReqGramUnused>

private enum ReqGramPluginSection: Int32, SGItemListSection {
    case settings
    case information
}

private enum ReqGramPluginBoolSetting: Hashable {
    case enabled
    case blur, slide, scale, rotate, deleteAnimation, cursor, liquidCursor, ignoreSpaces, animateAllLines
}

private enum ReqGramPluginUnused: Hashable {
    case value
}

private enum ReqGramPluginAction: Hashable {
    case sendGiftById
    case author(String)
}

private typealias ReqGramPluginEntry = SGItemListUIEntry<ReqGramPluginSection, ReqGramPluginBoolSetting, ReqGramSliderSetting, ReqGramPluginUnused, ReqGramPluginUnused, ReqGramPluginAction>

public func reqGramSettingsController(context: AccountContext) -> ViewController {
    var presentSupport: (() -> Void)?
    var pushPluginController: ((ReqGramPlugin) -> Void)?
    let arguments = SGItemListArguments<ReqGramBoolSetting, ReqGramSliderSetting, ReqGramUnused, ReqGramDisclosure, ReqGramUnused>(
        context: context,
        setBoolValue: { setting, value in
            let settings = SGSimpleSettings.shared
            switch setting {
            case .giftIdEnabled:
                settings.reqGramGiftIdEnabled = value
            case .deletedGiftSenderEnabled:
                settings.reqGramDeletedGiftSenderEnabled = value
            case .zwyLibEnabled:
                settings.reqGramZwyLibEnabled = value
            case .localEdictorEnabled:
                settings.reqGramLocalEdictorEnabled = value
            case .zwyNoForwardLimitEnabled:
                settings.reqGramZwyNoForwardLimitEnabled = value
            case .textAnimationPrivateLetEnabled:
                settings.reqGramTextAnimationPrivateLetEnabled = value
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
            case let .plugin(plugin):
                pushPluginController?(plugin)
            case .other:
                presentSupport?()
            }
        }
    )
    let settingsChanges = Signal<Void, NoError> { subscriber in
        let observer = NotificationCenter.default.addObserver(forName: UserDefault<Bool>.didChangeNotification, object: nil, queue: .main) { _ in
            subscriber.putNext(())
        }
        return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
    }
    let settingsState = Signal<Void, NoError>.single(()) |> then(settingsChanges)
    let signal = combineLatest(context.sharedContext.presentationData, settingsState)
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        let counter = SGItemListCounter()
        let entries: [ReqGramEntry] = [
            .header(id: counter.count, section: .plugins, text: i18n("ReqGram.Plugins.Title", lang), badge: nil),
            .disclosure(id: counter.count, section: .plugins, link: .plugin(.giftId), text: i18n("ReqGram.Plugin.GiftId", lang)),
            .disclosure(id: counter.count, section: .plugins, link: .plugin(.sendGiftById), text: i18n("ReqGram.Plugin.SendGiftById", lang)),
            .disclosure(id: counter.count, section: .plugins, link: .plugin(.deletedGiftSender), text: i18n("ReqGram.Plugin.DeletedGiftSender", lang)),
            .disclosure(id: counter.count, section: .plugins, link: .plugin(.localEdictorAndZwyLib), text: i18n("ReqGram.Plugin.LocalEdictorZwyLib", lang)),
            .disclosure(id: counter.count, section: .plugins, link: .plugin(.zwyNoForwardLimit), text: i18n("ReqGram.Plugin.ZwyNoForwardLimit", lang)),
            .disclosure(id: counter.count, section: .plugins, link: .plugin(.textAnimationPrivateLet), text: i18n("ReqGram.Plugin.TextAnimationPrivateLet", lang)),
            .header(id: counter.count, section: .support, text: i18n("ReqGram.Support.Section", lang), badge: nil),
            .disclosure(id: counter.count, section: .support, link: .other, text: i18n("ReqGram.Support.MenuTitle", lang))
        ]
        return (
            ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(ReqGramBadgeConfiguration.displayName),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
            ),
            (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil), arguments)
        )
    }
    let controller = ItemListController(context: context, state: signal)
    presentSupport = { [weak controller] in
        controller?.present(supportDevelopmentController(context: context, navigationController: controller?.navigationController as? NavigationController), in: .window(.root), with: nil)
    }
    pushPluginController = { [weak controller] plugin in
        guard let pluginController = reqGramPluginController(context: context, plugin: plugin) else {
            return
        }
        (controller?.navigationController as? NavigationController)?.pushViewController(pluginController)
    }
    return controller
}

private func reqGramPluginController(context: AccountContext, plugin: ReqGramPlugin) -> ViewController? {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode
    let title: String
    let description: String
    switch plugin {
    case .giftId:
        title = i18n("ReqGram.Plugin.GiftId", lang)
        description = i18n("ReqGram.Plugin.GiftId.Description", lang)
    case .sendGiftById:
        title = i18n("ReqGram.Plugin.SendGiftById", lang)
        description = i18n("ReqGram.Plugin.SendGiftById.Description", lang)
    case .deletedGiftSender:
        title = i18n("ReqGram.Plugin.DeletedGiftSender", lang)
        description = i18n("ReqGram.Plugin.DeletedGiftSender.Description", lang)
    case .localEdictorAndZwyLib:
        title = i18n("ReqGram.Plugin.LocalEdictorZwyLib", lang)
        description = i18n("ReqGram.Plugin.LocalEdictorZwyLib.Description", lang)
    case .zwyNoForwardLimit:
        title = i18n("ReqGram.Plugin.ZwyNoForwardLimit", lang)
        description = i18n("ReqGram.Plugin.ZwyNoForwardLimit.Description", lang)
    case .textAnimationPrivateLet:
        title = i18n("ReqGram.Plugin.TextAnimationPrivateLet", lang)
        description = i18n("ReqGram.Plugin.TextAnimationPrivateLet.Description", lang)
    }

    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?
    let arguments = SGItemListArguments<ReqGramPluginBoolSetting, ReqGramSliderSetting, ReqGramPluginUnused, ReqGramPluginUnused, ReqGramPluginAction>(
        context: context,
        setBoolValue: { setting, value in
             let settings = SGSimpleSettings.shared
             switch plugin {
            case .giftId:
                settings.reqGramGiftIdEnabled = value
            case .sendGiftById:
                settings.reqGramSendGiftByIdEnabled = value
            case .deletedGiftSender:
                settings.reqGramDeletedGiftSenderEnabled = value
            case .localEdictorAndZwyLib:
                // These two gates are deliberately one plugin switch.
                settings.reqGramLocalEdictorEnabled = value
                settings.reqGramZwyLibEnabled = value
            case .zwyNoForwardLimit:
                settings.reqGramZwyNoForwardLimitEnabled = value
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
         action: { action in
            if case .sendGiftById = action, plugin == .sendGiftById {
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
                return
            }
            if case let .author(handle) = action {
                context.sharedContext.openExternalUrl(context: context, urlContext: .generic, url: "tg://resolve?domain=\(handle)", forceExternal: false, presentationData: context.sharedContext.currentPresentationData.with { $0 }, navigationController: nil, dismissInput: {})
            }
        }
    )
    let pluginSettingsChanges = Signal<Void, NoError> { subscriber in
        let observer = NotificationCenter.default.addObserver(forName: UserDefault<Bool>.didChangeNotification, object: nil, queue: .main) { _ in
            subscriber.putNext(())
        }
        return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
    }
    let pluginSettingsState = Signal<Void, NoError>.single(()) |> then(pluginSettingsChanges)
    let signal = combineLatest(context.sharedContext.presentationData, pluginSettingsState)
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        let currentSettings = SGSimpleSettings.shared
        let currentEnabled: Bool
        switch plugin {
        case .giftId:
            currentEnabled = currentSettings.reqGramGiftIdEnabled
        case .sendGiftById:
            currentEnabled = currentSettings.reqGramSendGiftByIdEnabled
        case .deletedGiftSender:
            currentEnabled = currentSettings.reqGramDeletedGiftSenderEnabled
        case .localEdictorAndZwyLib:
            currentEnabled = currentSettings.reqGramLocalEdictorEnabled && currentSettings.reqGramZwyLibEnabled
        case .zwyNoForwardLimit:
            currentEnabled = currentSettings.reqGramZwyNoForwardLimitEnabled
        case .textAnimationPrivateLet:
            currentEnabled = currentSettings.reqGramTextAnimationPrivateLetEnabled
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
         }
        if case .deletedGiftSender = plugin {
            entries.append(.notice(
                id: counter.count,
                section: .settings,
                text: "# ⚠️ ВНИМАНИЕ\n\n**Отображение подарков может быть НЕВЕРНЫМ. Всегда сравнивайте подарок по ID.**"
            ))
        }
        if case .sendGiftById = plugin {
            entries.append(.action(id: counter.count, section: .information, actionType: .sendGiftById, text: i18n("ReqGram.Plugin.SendGiftById.Action", lang), kind: .generic))
        }
        let authors: [(labelKey: String, handle: String)]
        switch plugin {
        case .giftId: authors = [("ReqGram.Plugin.Author", "PESSDES_Plugins")]
        case .sendGiftById: authors = [("ReqGram.Plugin.Author", "voterol")]
        case .deletedGiftSender: authors = [("ReqGram.Plugin.Author", "binbash_0")]
        case .localEdictorAndZwyLib: authors = [("ReqGram.Plugin.Author", "Nikita218000"), ("ReqGram.Plugin.Author", "zwylair")]
        case .zwyNoForwardLimit: authors = [("ReqGram.Plugin.Author", "zwylair")]
        case .textAnimationPrivateLet: authors = [("ReqGram.Plugin.Author", "private_let"), ("ReqGram.Plugin.TextAnimationAuthor", "mihailkotovski"), ("ReqGram.Plugin.TextAnimationAuthor", "mishabotov")]
        }
        for author in authors {
            entries.append(.action(id: counter.count, section: .information, actionType: .author(author.handle), text: "\(i18n(author.labelKey, lang)): @\(author.handle)", kind: .generic))
        }
        entries.append(.header(id: counter.count, section: .information, text: i18n("ReqGram.Plugin.Information", lang), badge: nil))
        entries.append(.notice(id: counter.count, section: .information, text: description))
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

        func update(component: ReqGramSupportHeroComponent, availableSize: CGSize) -> CGSize {
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
        return view.update(component: self, availableSize: availableSize)
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
