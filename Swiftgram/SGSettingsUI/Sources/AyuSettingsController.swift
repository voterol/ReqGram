// MARK: AyuGram
import SGLogging
import SGSimpleSettings
import SGStrings
import AyuGram

import SGItemListUI
import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import OverlayStatusController
import AccountContext
import UndoUI
import UniformTypeIdentifiers

private enum AyuSettingsSection: Int32, SGItemListSection {
    case ghost
    case ghostAdvanced
    case save
    case saveMediaScope
    case marks
    case appearance
    case chats
    case database
    case integration
    case support
}

private enum AyuBoolSetting: String {
    case ayuGhostMode
    case ayuGhostBlockReadReceipts
    case ayuGhostBlockTyping
    case ayuGhostBlockOnlinePresence
    case ayuGhostBlockStoryViews
    case ayuGhostSendOfflineAfterOnline
    case ayuGhostMarkReadAfterAction
    case ayuGhostUseScheduledMessages
    case ayuGhostSuggestBeforeStory
    case ayuSaveDeletedMessages
    case ayuSaveEditedMessages
    case ayuSaveMediaAttachments
    case ayuSaveForBots
    case ayuSaveReactions
    case ayuSaveMediaInPrivateChats
    case ayuSaveMediaInPublicChannels
    case ayuSaveMediaInPrivateChannels
    case ayuSaveMediaInPublicGroups
    case ayuSaveMediaInPrivateGroups
    case ayuSemiTransparentDeleted
    case ayuFiltersEnabled
    case ayuFiltersInChats
    case ayuFiltersCaseInsensitive
    case ayuHideFromBlocked
    case ayuDisableAds
    case ayuHidePremiumStatuses
    case ayuShowOnlyAddedEmojisAndStickers
    case ayuCollapseSimilarChannels
    case ayuHideSimilarChannels
    case ayuRemoveMessageTail
    case ayuSimpleQuotesAndReplies
    case ayuHideFastShare
    case ayuShowMessageSeconds
    case ayuHideAllChatsFolder
    case ayuHideNotificationCounters
    case ayuHideNotificationBadge
    case ayuLocalPremium
    case ayuDisableOpenLinkWarning
    case ayuDisableGreetingSticker
    case ayuUnlimitedRecentStickers
    case ayuFilterZalgo
    case ayuSpoofWebviewAsAndroid
    case ayuShowChannelReactions
    case ayuShowGroupReactions
    case ayuShowPrivateChatReactions
    case ayuStickerConfirmation
    case ayuGifConfirmation
    case ayuVoiceConfirmation
    case ayuRoundConfirmation
    case ayuRCEnabled
    case ayuStreamerMode
    case ayuShowGhostModeInProfile
}

private enum AyuSliderSetting: String {
    case ayuDeletedOpacity
}

private enum AyuOneFromManySetting: String {
    case ayuMediaLimitBytes
    case ayuDeletedIconStyle
    case ayuDeletedIconColor
    case ayuGhostSendWithoutSound
    case ayuShowPeerId
    case ayuChannelBottomButton
    case ayuMessageBubbleRadius
    case ayuShowMessageDetailsInContextMenu
    case ayuShowHideMessageInContextMenu
    case ayuShowUserMessagesInContextMenu
    case ayuShowRepeatMessageInContextMenu
    case ayuShowAddFilterInContextMenu
    case ayuShowSaveMessageInContextMenu
}

private enum AyuAction: String {
    case exportDatabase
    case importDatabase
}

private enum AyuDisclosureLink: String {
    case manageFilters
    case support
    case exteraGramSupport
}

private typealias AyuSettingsEntry = SGItemListUIEntry<AyuSettingsSection, AyuBoolSetting, AyuSliderSetting, AyuOneFromManySetting, AyuDisclosureLink, AyuAction>

/// Discrete per-file media limit options: bytes (0 = unlimited) + i18n key.
private let ayuMediaLimitOptions: [(bytes: Int64, key: String)] = [
    (2 * 1024 * 1024, "AyuGram.Save.MediaLimit.2MB"),
    (5 * 1024 * 1024, "AyuGram.Save.MediaLimit.5MB"),
    (10 * 1024 * 1024, "AyuGram.Save.MediaLimit.10MB"),
    (50 * 1024 * 1024, "AyuGram.Save.MediaLimit.50MB"),
    (500 * 1024 * 1024, "AyuGram.Save.MediaLimit.500MB"),
    (1024 * 1024 * 1024, "AyuGram.Save.MediaLimit.1GB"),
    (2 * 1024 * 1024 * 1024, "AyuGram.Save.MediaLimit.2GB"),
    (0, "AyuGram.Save.MediaLimit.Unlimited")
]

private func ayuMediaLimitLabel(_ bytes: Int64, lang: String) -> String {
    for option in ayuMediaLimitOptions where option.bytes == bytes {
        return i18n(option.key, lang)
    }
    // Custom (imported/manually set) value: format the raw byte amount
    // instead of silently claiming the 50 MB default.
    if bytes > 0 {
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    return i18n("AyuGram.Save.MediaLimit.Unlimited", lang)
}

private let ayuDeletedIconOptions: [(value: String, key: String)] = [
    ("none", "AyuGram.Icon.Style.none"),
    ("trash", "AyuGram.Icon.Style.trash"),
    ("cross", "AyuGram.Icon.Style.cross"),
    ("crossed-eye", "AyuGram.Icon.Style.crossed-eye")
]

private func ayuDeletedIconLabel(_ value: String, lang: String) -> String {
    for option in ayuDeletedIconOptions where option.value == value {
        return i18n(option.key, lang)
    }
    return i18n("AyuGram.Icon.Style.trash", lang)
}

private let ayuDeletedIconColorOptions: [(value: String, key: String)] = [
    ("theme", "AyuGram.Icon.Color.theme"),
    ("red", "AyuGram.Icon.Color.red"),
    ("orange", "AyuGram.Icon.Color.orange"),
    ("green", "AyuGram.Icon.Color.green"),
    ("blue", "AyuGram.Icon.Color.blue"),
    ("purple", "AyuGram.Icon.Color.purple")
]

private func ayuDeletedIconColorLabel(_ value: String, lang: String) -> String {
    return i18n(ayuDeletedIconColorOptions.first(where: { $0.value == value })?.key ?? "AyuGram.Icon.Color.theme", lang)
}

private func ayuSettingsEntries(presentationData: PresentationData) -> [AyuSettingsEntry] {
    var entries: [AyuSettingsEntry] = []
    let lang = presentationData.strings.baseLanguageCode
    let settings = SGSimpleSettings.shared

    let id = SGItemListCounter()

    // MARK: Ghost Mode
    let ghostEnabled = settings.ayuGhostMode
    entries.append(.header(id: id.count, section: .ghost, text: i18n("AyuGram.GhostMode", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .ghost, settingName: .ayuGhostMode, value: ghostEnabled, text: i18n("AyuGram.GhostMode", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .ghost, settingName: .ayuGhostBlockReadReceipts, value: settings.ayuGhostBlockReadReceipts, text: i18n("AyuGram.Ghost.ReadReceipts", lang), enabled: ghostEnabled))
    entries.append(.toggle(id: id.count, section: .ghost, settingName: .ayuGhostBlockTyping, value: settings.ayuGhostBlockTyping, text: i18n("AyuGram.Ghost.Typing", lang), enabled: ghostEnabled))
    entries.append(.toggle(id: id.count, section: .ghost, settingName: .ayuGhostBlockOnlinePresence, value: settings.ayuGhostBlockOnlinePresence, text: i18n("AyuGram.Ghost.Online", lang), enabled: ghostEnabled))
    entries.append(.toggle(id: id.count, section: .ghost, settingName: .ayuGhostBlockStoryViews, value: settings.ayuGhostBlockStoryViews, text: i18n("AyuGram.Ghost.Stories", lang), enabled: ghostEnabled))
    entries.append(.notice(id: id.count, section: .ghost, text: i18n("AyuGram.Ghost.Notice", lang)))

    // MARK: Ghost Mode - advanced
    entries.append(.toggle(id: id.count, section: .ghostAdvanced, settingName: .ayuGhostMarkReadAfterAction, value: settings.ayuGhostMarkReadAfterAction, text: i18n("AyuGram.Ghost.MarkReadAfterAction", lang), enabled: ghostEnabled))
    entries.append(.notice(id: id.count, section: .ghostAdvanced, text: i18n("AyuGram.Ghost.MarkReadAfterAction.Notice", lang)))
    entries.append(.oneFromManySelector(id: id.count, section: .ghostAdvanced, settingName: .ayuGhostSendWithoutSound, text: i18n("AyuGram.Ghost.SendWithoutSound", lang), value: i18n("AyuGram.Ghost.SendWithoutSound.\(settings.ayuSendWithoutSoundEnum.rawValue)", lang), enabled: true))

    // MARK: Message preservation
    let saveDeleted = settings.ayuSaveDeletedMessages
    entries.append(.header(id: id.count, section: .save, text: i18n("AyuGram.Save.Header", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .save, settingName: .ayuSaveDeletedMessages, value: saveDeleted, text: i18n("AyuGram.SaveDeleted", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .save, settingName: .ayuSaveEditedMessages, value: settings.ayuSaveEditedMessages, text: i18n("AyuGram.SaveEdits", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .save, settingName: .ayuSaveForBots, value: settings.ayuSaveForBots, text: i18n("AyuGram.Save.ForBots", lang), enabled: saveDeleted || settings.ayuSaveEditedMessages))
    entries.append(.toggle(id: id.count, section: .save, settingName: .ayuSaveMediaAttachments, value: settings.ayuSaveMediaAttachments, text: i18n("AyuGram.SaveMedia", lang), enabled: saveDeleted))
    entries.append(.oneFromManySelector(id: id.count, section: .save, settingName: .ayuMediaLimitBytes, text: i18n("AyuGram.Save.MediaLimit", lang), value: ayuMediaLimitLabel(settings.ayuMediaLimitBytes, lang: lang), enabled: settings.ayuSaveMediaAttachments))
    entries.append(.notice(id: id.count, section: .save, text: i18n("AyuGram.Save.Notice", lang)))

    // MARK: Media scope
    let mediaScopeEnabled = saveDeleted && settings.ayuSaveMediaAttachments
    entries.append(.header(id: id.count, section: .saveMediaScope, text: i18n("AyuGram.Save.MediaScope.Header", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .saveMediaScope, settingName: .ayuSaveMediaInPrivateChats, value: settings.ayuSaveMediaInPrivateChats, text: i18n("AyuGram.Save.MediaScope.PrivateChats", lang), enabled: mediaScopeEnabled))
    entries.append(.toggle(id: id.count, section: .saveMediaScope, settingName: .ayuSaveMediaInPrivateChannels, value: settings.ayuSaveMediaInPrivateChannels, text: i18n("AyuGram.Save.MediaScope.PrivateChannels", lang), enabled: mediaScopeEnabled))
    entries.append(.toggle(id: id.count, section: .saveMediaScope, settingName: .ayuSaveMediaInPublicChannels, value: settings.ayuSaveMediaInPublicChannels, text: i18n("AyuGram.Save.MediaScope.PublicChannels", lang), enabled: mediaScopeEnabled))
    entries.append(.toggle(id: id.count, section: .saveMediaScope, settingName: .ayuSaveMediaInPrivateGroups, value: settings.ayuSaveMediaInPrivateGroups, text: i18n("AyuGram.Save.MediaScope.PrivateGroups", lang), enabled: mediaScopeEnabled))
    entries.append(.toggle(id: id.count, section: .saveMediaScope, settingName: .ayuSaveMediaInPublicGroups, value: settings.ayuSaveMediaInPublicGroups, text: i18n("AyuGram.Save.MediaScope.PublicGroups", lang), enabled: mediaScopeEnabled))
    entries.append(.notice(id: id.count, section: .saveMediaScope, text: i18n("AyuGram.Save.MediaScope.Notice", lang)))

    // MARK: Deleted message appearance
    entries.append(.header(id: id.count, section: .marks, text: i18n("AyuGram.Icon.Header", lang), badge: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .marks, settingName: .ayuDeletedIconStyle, text: i18n("AyuGram.Icon.Style", lang), value: ayuDeletedIconLabel(settings.ayuDeletedIconStyle, lang: lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .marks, settingName: .ayuDeletedIconColor, text: i18n("AyuGram.Icon.Color", lang), value: ayuDeletedIconColorLabel(settings.ayuDeletedIconColor, lang: lang), enabled: settings.ayuDeletedIconStyle != "none"))
    entries.append(.toggle(id: id.count, section: .marks, settingName: .ayuSemiTransparentDeleted, value: settings.ayuSemiTransparentDeleted, text: i18n("AyuGram.Marks.SemiTransparent", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .marks, text: i18n("AyuGram.Marks.Notice", lang)))

    // MARK: Appearance
    entries.append(.header(id: id.count, section: .appearance, text: i18n("AyuGram.Appearance.Header", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .appearance, settingName: .ayuDisableAds, value: settings.ayuDisableAds, text: i18n("AyuGram.Appearance.DisableAds", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .appearance, settingName: .ayuHidePremiumStatuses, value: settings.ayuHidePremiumStatuses, text: i18n("AyuGram.Appearance.HidePremiumStatuses", lang), enabled: true))

    // MARK: Chats
    entries.append(.header(id: id.count, section: .chats, text: i18n("AyuGram.Chats.Header", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .ayuLocalPremium, value: settings.ayuLocalPremium, text: i18n("AyuGram.Chats.LocalPremium", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .chats, text: i18n("AyuGram.Chats.LocalPremium.Notice", lang)))

    // MARK: Database
    entries.append(.header(id: id.count, section: .database, text: i18n("AyuGram.Database.Header", lang), badge: nil))
    entries.append(.action(id: id.count, section: .database, actionType: .exportDatabase, text: i18n("AyuGram.Export", lang), kind: .generic))
    entries.append(.action(id: id.count, section: .database, actionType: .importDatabase, text: i18n("AyuGram.Import", lang), kind: .destructive))
    entries.append(.notice(id: id.count, section: .database, text: i18n("AyuGram.Export.Import.Notice", lang)))

    entries.append(.toggle(id: id.count, section: .integration, settingName: .ayuShowGhostModeInProfile, value: settings.ayuShowGhostModeInProfile, text: i18n("AyuGram.Ghost.ProfileToggle", lang), enabled: true))

    entries.append(.header(id: id.count, section: .support, text: i18n("ProjectSupport.Section", lang), badge: nil))
    entries.append(.disclosure(id: id.count, section: .support, link: .support, text: i18n("ProjectSupport.Title", lang, "AyuGram")))
    entries.append(.disclosure(id: id.count, section: .support, link: .exteraGramSupport, text: i18n("ProjectSupport.Title", lang, "exteraGram")))

    return entries
}

/// Label for the bubble radius selector; -1 means "app default".
private func ayuBubbleRadiusLabel(_ value: Int, lang: String) -> String {
    if value < 0 {
        return i18n("AyuGram.Appearance.BubbleRadius.Default", lang)
    }
    return "\(value)"
}

private let ayuBubbleRadiusOptions: [Int] = [-1, 0, 4, 8, 12, 16, 20]

private func ayuVisibilityLabel(_ rawValue: String, lang: String) -> String {
    let resolved = SGSimpleSettings.AyuContextMenuVisibility(rawValue: rawValue) ?? .visible
    return i18n("AyuGram.ContextMenu.Visibility.\(resolved.rawValue)", lang)
}

/// MARK: Export / Import helpers

private func ayuTimestampedName() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
}

/// Copies store.json + attachments/ into a temp folder package
/// `AyuGram-Export-<date>.ayugramdb` and returns its URL.
private func ayuExportDatabase() -> URL? {
    let fileManager = FileManager.default
    let packageURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("AyuGram-Export-\(ayuTimestampedName()).ayugramdb", isDirectory: true)
    do {
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: AyuStorage.storeURL.path) {
            try fileManager.copyItem(at: AyuStorage.storeURL, to: packageURL.appendingPathComponent("store.json"))
        }
        let attachmentsURL = AyuStorage.attachmentsURL
        if fileManager.fileExists(atPath: attachmentsURL.path) {
            try fileManager.copyItem(at: attachmentsURL, to: packageURL.appendingPathComponent("attachments"))
        }
        return packageURL
    } catch {
        SGLogger.shared.log("AyuGram", "Export failed: \(error)")
        try? fileManager.removeItem(at: packageURL)
        return nil
    }
}

/// Validates a picked URL (a `.ayugramdb` folder or a `store.json` file),
/// wipes the current store, copies the imported data in place and reloads.
private func ayuImportDatabase(from url: URL) -> Bool {
    let fileManager = FileManager.default
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
        if scoped {
            url.stopAccessingSecurityScopedResource()
        }
    }

    let storeURL: URL
    let attachmentsURL: URL
    let isDirectory = ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
    if isDirectory {
        storeURL = url.appendingPathComponent("store.json")
        attachmentsURL = url.appendingPathComponent("attachments")
    } else if url.lastPathComponent == "store.json" {
        storeURL = url
        attachmentsURL = url.deletingLastPathComponent().appendingPathComponent("attachments")
    } else {
        return false
    }
    guard fileManager.fileExists(atPath: storeURL.path) else {
        return false
    }

    do {
        let storeData = try Data(contentsOf: storeURL, options: [.mappedIfSafe])
        let attachmentsSource = fileManager.fileExists(atPath: attachmentsURL.path) ? attachmentsURL : nil
        try AyuMessageStore.shared.replaceStore(with: storeData, attachmentsSourceURL: attachmentsSource)
        return true
    } catch {
        SGLogger.shared.log("AyuGram", "Import failed: \(error)")
        return false
    }
}

private final class AyuDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let completion: (URL) -> Void

    init(completion: @escaping (URL) -> Void) {
        self.completion = completion
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first {
            self.completion(url)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
}

public func ayuSettingsController(context: AccountContext) -> ViewController {
    let simplePromise = ValuePromise(true, ignoreRepeated: false)
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?
    weak var settingsController: ItemListController?
    // Presented UIKit controllers (share sheet / document picker) need a host;
    // walk up from the settings controller's window to the topmost VC.
    let ayuTopmostViewController: () -> UIViewController? = {
        var candidate: UIViewController? = settingsController ?? (settingsController?.view.window?.rootViewController)
        if candidate == nil {
            candidate = UIApplication.shared.connectedScenes
                .compactMap { scene -> UIViewController? in
                    guard let windowScene = scene as? UIWindowScene else { return nil }
                    return (windowScene.windows.first { $0.isKeyWindow })?.rootViewController
                }
                .first
        }
        while let presented = candidate?.presentedViewController {
            candidate = presented
        }
        return candidate
    }
    let documentPickerDelegate = AyuDocumentPickerDelegate { url in
        DispatchQueue.global(qos: .userInitiated).async {
            let success = ayuImportDatabase(from: url)
            DispatchQueue.main.async {
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                presentControllerImpl?(
                    UndoOverlayController(
                        presentationData: presentationData,
                        content: success ? .info(title: nil, text: i18n("AyuGram.Import.Confirmed", presentationData.strings.baseLanguageCode), timeout: nil, customUndoText: nil) : .info(title: nil, text: i18n("AyuGram.Import.Failed", presentationData.strings.baseLanguageCode), timeout: nil, customUndoText: nil),
                        elevatedLayout: false,
                        action: { _ in return true }
                    ),
                    nil
                )
                simplePromise.set(true)
            }
        }
    }

    let arguments = SGItemListArguments<AyuBoolSetting, AyuSliderSetting, AyuOneFromManySetting, AyuDisclosureLink, AyuAction>(
        context: context,
        setBoolValue: { setting, value in
            let settings = SGSimpleSettings.shared
            switch setting {
            case .ayuGhostMode:
                settings.ayuGhostMode = value
                if value {
                    settings.ayuGhostBlockReadReceipts = true
                    settings.ayuGhostBlockTyping = true
                    settings.ayuGhostBlockOnlinePresence = true
                    settings.ayuGhostBlockStoryViews = true
                }
            case .ayuGhostBlockReadReceipts:
                settings.ayuGhostBlockReadReceipts = value
            case .ayuGhostBlockTyping:
                settings.ayuGhostBlockTyping = value
            case .ayuGhostBlockOnlinePresence:
                settings.ayuGhostBlockOnlinePresence = value
            case .ayuGhostBlockStoryViews:
                settings.ayuGhostBlockStoryViews = value
            case .ayuGhostSendOfflineAfterOnline:
                settings.ayuGhostSendOfflineAfterOnline = value
            case .ayuGhostMarkReadAfterAction:
                settings.ayuGhostMarkReadAfterAction = value
            case .ayuGhostUseScheduledMessages:
                settings.ayuGhostUseScheduledMessages = value
            case .ayuGhostSuggestBeforeStory:
                settings.ayuGhostSuggestBeforeStory = value
            case .ayuSaveDeletedMessages:
                settings.ayuSaveDeletedMessages = value
            case .ayuSaveEditedMessages:
                settings.ayuSaveEditedMessages = value
            case .ayuSaveMediaAttachments:
                settings.ayuSaveMediaAttachments = value
            case .ayuSaveForBots:
                settings.ayuSaveForBots = value
            case .ayuSaveReactions:
                settings.ayuSaveReactions = value
            case .ayuSaveMediaInPrivateChats:
                settings.ayuSaveMediaInPrivateChats = value
            case .ayuSaveMediaInPublicChannels:
                settings.ayuSaveMediaInPublicChannels = value
            case .ayuSaveMediaInPrivateChannels:
                settings.ayuSaveMediaInPrivateChannels = value
            case .ayuSaveMediaInPublicGroups:
                settings.ayuSaveMediaInPublicGroups = value
            case .ayuSaveMediaInPrivateGroups:
                settings.ayuSaveMediaInPrivateGroups = value
            case .ayuSemiTransparentDeleted:
                settings.ayuSemiTransparentDeleted = value
            case .ayuFiltersEnabled:
                settings.ayuFiltersEnabled = value
                AyuFilters.shared.invalidate()
            case .ayuFiltersInChats:
                settings.ayuFiltersInChats = value
                AyuFilters.shared.invalidate()
            case .ayuFiltersCaseInsensitive:
                settings.ayuFiltersCaseInsensitive = value
                AyuFilters.shared.invalidate()
            case .ayuHideFromBlocked:
                settings.ayuHideFromBlocked = value
                AyuFilters.shared.invalidate()
            case .ayuDisableAds:
                settings.ayuDisableAds = value
            case .ayuHidePremiumStatuses:
                settings.ayuHidePremiumStatuses = value
            case .ayuShowOnlyAddedEmojisAndStickers:
                settings.ayuShowOnlyAddedEmojisAndStickers = value
            case .ayuCollapseSimilarChannels:
                settings.ayuCollapseSimilarChannels = value
            case .ayuHideSimilarChannels:
                settings.ayuHideSimilarChannels = value
            case .ayuRemoveMessageTail:
                settings.ayuRemoveMessageTail = value
            case .ayuSimpleQuotesAndReplies:
                settings.ayuSimpleQuotesAndReplies = value
            case .ayuHideFastShare:
                settings.ayuHideFastShare = value
            case .ayuShowMessageSeconds:
                settings.ayuShowMessageSeconds = value
            case .ayuHideAllChatsFolder:
                settings.ayuHideAllChatsFolder = value
            case .ayuHideNotificationCounters:
                settings.ayuHideNotificationCounters = value
            case .ayuHideNotificationBadge:
                settings.ayuHideNotificationBadge = value
            case .ayuLocalPremium:
                settings.ayuLocalPremium = value
            case .ayuDisableOpenLinkWarning:
                settings.ayuDisableOpenLinkWarning = value
            case .ayuDisableGreetingSticker:
                settings.ayuDisableGreetingSticker = value
            case .ayuUnlimitedRecentStickers:
                settings.ayuUnlimitedRecentStickers = value
            case .ayuFilterZalgo:
                settings.ayuFilterZalgo = value
            case .ayuSpoofWebviewAsAndroid:
                settings.ayuSpoofWebviewAsAndroid = value
            case .ayuShowChannelReactions:
                settings.ayuShowChannelReactions = value
            case .ayuShowGroupReactions:
                settings.ayuShowGroupReactions = value
            case .ayuShowPrivateChatReactions:
                settings.ayuShowPrivateChatReactions = value
            case .ayuStickerConfirmation:
                settings.ayuStickerConfirmation = value
            case .ayuGifConfirmation:
                settings.ayuGifConfirmation = value
            case .ayuVoiceConfirmation:
                settings.ayuVoiceConfirmation = value
            case .ayuRoundConfirmation:
                settings.ayuRoundConfirmation = value
            case .ayuRCEnabled:
                settings.ayuRCEnabled = value
                AyuRemoteConfig.shared.enabledStateDidChange()
            case .ayuStreamerMode:
                settings.ayuStreamerMode = value
                AyuStreamerMode.shared.start()
                AyuStreamerMode.shared.notifyStateChanged()
            case .ayuShowGhostModeInProfile:
                settings.ayuShowGhostModeInProfile = value
            }
            // Several rows gate the `enabled` state of others, so refresh the
            // whole list rather than tracking each dependency individually.
            simplePromise.set(true)
        }, updateSliderValue: { setting, value in
            switch setting {
            case .ayuDeletedOpacity:
                // Slider is continuous 0-100; quantize to steps of 5.
                let quantized = Int(max(0, min(100, value)) / 5 * 5)
                if SGSimpleSettings.shared.ayuDeletedOpacity != quantized {
                    SGSimpleSettings.shared.ayuDeletedOpacity = quantized
                    simplePromise.set(true)
                }
            }
        }, setOneFromManyValue: { setting in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let actionSheet = ActionSheetController(presentationData: presentationData)
            var items: [ActionSheetItem] = []

            switch setting {
            case .ayuMediaLimitBytes:
                let setAction: (Int64) -> Void = { value in
                    SGSimpleSettings.shared.ayuMediaLimitBytes = value
                    simplePromise.set(true)
                }
                for option in ayuMediaLimitOptions {
                    items.append(ActionSheetButtonItem(title: i18n(option.key, presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        setAction(option.bytes)
                    }))
                }
            case .ayuDeletedIconStyle:
                let setAction: (String) -> Void = { value in
                    SGSimpleSettings.shared.ayuDeletedIconStyle = value
                    simplePromise.set(true)
                }
                for option in ayuDeletedIconOptions {
                    items.append(ActionSheetButtonItem(title: i18n(option.key, presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        setAction(option.value)
                    }))
                }
            case .ayuDeletedIconColor:
                for option in ayuDeletedIconColorOptions {
                    items.append(ActionSheetButtonItem(title: i18n(option.key, presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        SGSimpleSettings.shared.ayuDeletedIconColor = option.value
                        simplePromise.set(true)
                    }))
                }
            case .ayuGhostSendWithoutSound:
                for option in SGSimpleSettings.AyuSendWithoutSound.allCases {
                    items.append(ActionSheetButtonItem(title: i18n("AyuGram.Ghost.SendWithoutSound.\(option.rawValue)", presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        SGSimpleSettings.shared.ayuGhostSendWithoutSound = option.rawValue
                        simplePromise.set(true)
                    }))
                }
            case .ayuShowPeerId:
                for option in SGSimpleSettings.AyuPeerIdDisplay.allCases {
                    items.append(ActionSheetButtonItem(title: i18n("AyuGram.Appearance.PeerId.\(option.rawValue)", presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        SGSimpleSettings.shared.ayuShowPeerId = option.rawValue
                        simplePromise.set(true)
                    }))
                }
            case .ayuChannelBottomButton:
                for option in SGSimpleSettings.AyuChannelBottomButton.allCases {
                    items.append(ActionSheetButtonItem(title: i18n("AyuGram.Chats.BottomButton.\(option.rawValue)", presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        SGSimpleSettings.shared.ayuChannelBottomButton = option.rawValue
                        simplePromise.set(true)
                    }))
                }
            case .ayuMessageBubbleRadius:
                for option in ayuBubbleRadiusOptions {
                    items.append(ActionSheetButtonItem(title: ayuBubbleRadiusLabel(option, lang: presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        SGSimpleSettings.shared.ayuMessageBubbleRadius = option
                        simplePromise.set(true)
                    }))
                }
            case .ayuShowMessageDetailsInContextMenu, .ayuShowHideMessageInContextMenu, .ayuShowUserMessagesInContextMenu, .ayuShowRepeatMessageInContextMenu, .ayuShowAddFilterInContextMenu, .ayuShowSaveMessageInContextMenu:
                let apply: (String) -> Void = { value in
                    switch setting {
                    case .ayuShowMessageDetailsInContextMenu:
                        SGSimpleSettings.shared.ayuShowMessageDetailsInContextMenu = value
                    case .ayuShowHideMessageInContextMenu:
                        SGSimpleSettings.shared.ayuShowHideMessageInContextMenu = value
                    case .ayuShowUserMessagesInContextMenu:
                        SGSimpleSettings.shared.ayuShowUserMessagesInContextMenu = value
                    case .ayuShowRepeatMessageInContextMenu:
                        SGSimpleSettings.shared.ayuShowRepeatMessageInContextMenu = value
                    case .ayuShowAddFilterInContextMenu:
                        SGSimpleSettings.shared.ayuShowAddFilterInContextMenu = value
                    case .ayuShowSaveMessageInContextMenu:
                        SGSimpleSettings.shared.ayuShowSaveMessageInContextMenu = value
                    default:
                        break
                    }
                    simplePromise.set(true)
                }
                for option in SGSimpleSettings.AyuContextMenuVisibility.allCases {
                    items.append(ActionSheetButtonItem(title: i18n("AyuGram.ContextMenu.Visibility.\(option.rawValue)", presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        apply(option.rawValue)
                    }))
                }
            }

            actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])])
            presentControllerImpl?(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
        }, openDisclosureLink: { link in
            switch link {
            case .manageFilters:
                pushControllerImpl?(ayuFiltersController(context: context))
            case .support:
                pushControllerImpl?(projectSupportController(context: context, kind: .ayuGram))
            case .exteraGramSupport:
                pushControllerImpl?(projectSupportController(context: context, kind: .exteraGram))
            }
        }, action: { action in
            switch action {
            case .exportDatabase:
                DispatchQueue.global(qos: .userInitiated).async {
                    let packageURL = ayuExportDatabase()
                    DispatchQueue.main.async {
                        if let packageURL = packageURL {
                            let activityController = UIActivityViewController(activityItems: [packageURL], applicationActivities: nil)
                            if let popover = activityController.popoverPresentationController, let view = ayuTopmostViewController()?.view {
                                popover.sourceView = view
                                popover.sourceRect = CGRect(origin: CGPoint(x: view.bounds.midX, y: view.bounds.midY), size: CGSize(width: 1.0, height: 1.0))
                            }
                            ayuTopmostViewController()?.present(activityController, animated: true)
                        } else {
                            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                            presentControllerImpl?(
                                UndoOverlayController(
                                    presentationData: presentationData,
                                    content: .info(title: nil, text: i18n("AyuGram.Export.Failed", presentationData.strings.baseLanguageCode), timeout: nil, customUndoText: nil),
                                    elevatedLayout: false,
                                    action: { _ in return true }
                                ),
                                nil
                            )
                        }
                    }
                }
            case .importDatabase:
                // Pick a `.ayugramdb` folder or a `store.json` file.
                // MARK: AyuGram - the legacy `documentTypes:` initializer is
                // deprecated (fatal under -warnings-as-errors), so importing is
                // offered only on iOS 14+, where the UTType-based API exists.
                if #available(iOS 14.0, *) {
                    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .json], asCopy: true)
                    picker.delegate = documentPickerDelegate
                    picker.allowsMultipleSelection = false
                    ayuTopmostViewController()?.present(picker, animated: true)
                }
            }
        })

    let signal = combineLatest(context.sharedContext.presentationData, simplePromise.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries = ayuSettingsEntries(presentationData: presentationData)

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("AyuGram"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))

        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    settingsController = controller
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }

    return controller
}
