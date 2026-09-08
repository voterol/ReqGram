import Foundation
import SGAppGroupIdentifier
import SGLogging

let APP_GROUP_IDENTIFIER = sgAppGroupIdentifier()

public class SGSimpleSettings {
    
    public static let shared = SGSimpleSettings()
    
    private init() {
        setDefaultValues()
        migrate()
        preCacheValues()
    }
    
    private func setDefaultValues() {
        UserDefaults.standard.register(defaults: SGSimpleSettings.defaultValues)
        // Just in case group defaults will be nil
        UserDefaults.standard.register(defaults: SGSimpleSettings.groupDefaultValues)
        if let groupUserDefaults = sgAppGroupUserDefaults() {
            groupUserDefaults.register(defaults: SGSimpleSettings.groupDefaultValues)
        }
    }
    
    private func migrate() {
        // Locks were an experimental UI-only exception to the ghost master
        // toggle. Clear persisted values so older installs cannot retain them.
        UserDefaults.standard.removeObject(forKey: Keys.ayuGhostLockReadReceipts.rawValue)
        UserDefaults.standard.removeObject(forKey: Keys.ayuGhostLockTyping.rawValue)
        UserDefaults.standard.removeObject(forKey: Keys.ayuGhostLockOnlinePresence.rawValue)
        UserDefaults.standard.removeObject(forKey: Keys.ayuGhostLockStoryViews.rawValue)

        let showRepostToStoryMigrationKey = "migrated_\(Keys.showRepostToStory.rawValue)"
        if let groupUserDefaults = sgAppGroupUserDefaults() {
            if !groupUserDefaults.bool(forKey: showRepostToStoryMigrationKey) {
                self.showRepostToStoryV2 = self.showRepostToStory
                groupUserDefaults.set(true, forKey: showRepostToStoryMigrationKey)
                SGLogger.shared.log("SGSimpleSettings", "Migrated showRepostToStory. \(self.showRepostToStory) -> \(self.showRepostToStoryV2)")
            }
        } else {
            SGLogger.shared.log("SGSimpleSettings", "Unable to migrate showRepostToStory. Shared UserDefaults suite is not available for '\(APP_GROUP_IDENTIFIER)'.")
        }

        let chatListLinesMigrationKey = "migrated_\(Keys.chatListLines.rawValue)"
        if !UserDefaults.standard.bool(forKey: chatListLinesMigrationKey) {
            let legacyCompactMessagePreviewKey = "compactMessagePreview"
            if UserDefaults.standard.object(forKey: legacyCompactMessagePreviewKey) != nil {
                if UserDefaults.standard.bool(forKey: legacyCompactMessagePreviewKey) {
                    self.chatListLines = ChatListLines.one.rawValue
                }
                UserDefaults.standard.removeObject(forKey: legacyCompactMessagePreviewKey)
                SGLogger.shared.log("SGSimpleSettings", "Migrated compactMessagePreview -> chatListLines. \(self.chatListLines)")
            }
            UserDefaults.standard.set(true, forKey: chatListLinesMigrationKey)
        }
    }
    
    private func preCacheValues() {
        // let dispatchGroup = DispatchGroup()

        let tasks = [
//            { let _ = self.allChatsFolderPositionOverride },
            { let _ = self.tabBarSearchEnabled },
            { let _ = self.allChatsHidden },
            { let _ = self.hideTabBar },
            { let _ = self.bottomTabStyle },
            { let _ = self.compactChatList },
            { let _ = self.chatListLines },
            { let _ = self.compactFolderNames },
            { let _ = self.disableSwipeToRecordStory },
            { let _ = self.rememberLastFolder },
            { let _ = self.quickTranslateButton },
            { let _ = self.stickerSize },
            { let _ = self.stickerTimestamp },
            { let _ = self.hideReactions },
            { let _ = self.disableGalleryCamera },
            { let _ = self.disableSendAsButton },
            { let _ = self.disableSnapDeletionEffect },
            { let _ = self.startTelescopeWithRearCam },
            { let _ = self.hideRecordingButton },
            { let _ = self.inputToolbar },
            { let _ = self.dismissedSGSuggestions },
            { let _ = self.customAppBadge }
        ]

        tasks.forEach { task in
            DispatchQueue.global(qos: .background).async(/*group: dispatchGroup*/) {
                task()
            }
        }

        // dispatchGroup.notify(queue: DispatchQueue.main) {}
    }
    
    public func synchronizeShared() {
        if let groupUserDefaults = sgAppGroupUserDefaults() {
            groupUserDefaults.synchronize()
        }
    }
    
    public enum Keys: String, CaseIterable {
        case hidePhoneInSettings
        case showTabNames
        case startTelescopeWithRearCam
        case accountColorsSaturation
        case uploadSpeedBoost
        case downloadSpeedBoost
        case bottomTabStyle
        case rememberLastFolder
        case lastAccountFolders
        case localDNSForProxyHost
        case sendLargePhotos
        case outgoingPhotoQuality
        case storyStealthMode
        case canUseStealthMode
        case disableSwipeToRecordStory
        case quickTranslateButton
        case outgoingLanguageTranslation
        case hideReactions
        case showRepostToStory
        case showRepostToStoryV2
        case contextShowSelectFromUser
        case contextShowSaveToCloud
        case contextShowRestrict
        // case contextShowBan
        case contextShowHideForwardName
        case contextShowReport
        case contextShowReply
        case contextShowPin
        case contextShowSaveMedia
        case contextShowMessageReplies
        case contextShowJson
        case disableScrollToNextChannel
        case disableScrollToNextTopic
        case disableChatSwipeOptions
        case disableDeleteChatSwipeOption
        case disableGalleryCamera
        case disableGalleryCameraPreview
        case disableSendAsButton
        case disableSnapDeletionEffect
        case stickerSize
        case stickerTimestamp
        case hideRecordingButton
        case hideTabBar
        case showDC
        case showCreationDate
        case showRegDate
        case regDateCache
        case compactChatList
        case chatListLines
        case compactFolderNames
        case allChatsTitleLengthOverride
//        case allChatsFolderPositionOverride
        case allChatsHidden
        case defaultEmojisFirst
        case messageDoubleTapActionOutgoing
        case wideChannelPosts
        case forceEmojiTab
        case forceBuiltInMic
        case secondsInMessages
        case hideChannelBottomButton
        case forceSystemSharing
        case confirmCalls
        case videoPIPSwipeDirection
        case legacyNotificationsFix
        case messageFilterKeywords
        case inputToolbar
        case pinnedMessageNotifications
        case mentionsAndRepliesNotifications
        case primaryUserId
        case status
        case dismissedSGSuggestions
        case duckyAppIconAvailable
        case transcriptionBackend
        case translationBackend
        case customAppBadge
        case canUseNY
        case nyStyle
        case wideTabBar
        case tabBarSearchEnabled
        case hideStories
        case warnOnStoriesOpen
        case showProfileId
        case sendWithReturnKey
        // MARK: ReqGram plugins
         case reqGramGiftIdEnabled
         case reqGramSendGiftByIdEnabled
         case reqGramDeletedGiftSenderEnabled
        case reqGramZwyLibEnabled
         case reqGramLocalEdictorEnabled
         case reqGramZwyNoForwardLimitEnabled
         case reqGramTextAnimationPrivateLetEnabled
         case reqGramTextAnimationPrivateLetDuration
         case reqGramTextAnimationPrivateLetBlurEnabled
         case reqGramTextAnimationPrivateLetBlurDuration
         case reqGramTextAnimationPrivateLetBlurRadius
         case reqGramTextAnimationPrivateLetBlurTextDelay
         case reqGramTextAnimationPrivateLetSlideEnabled
         case reqGramTextAnimationPrivateLetSlideDist
         case reqGramTextAnimationPrivateLetScaleEnabled
         case reqGramTextAnimationPrivateLetScaleStart
         case reqGramTextAnimationPrivateLetRotateEnabled
         case reqGramTextAnimationPrivateLetRotateAngle
         case reqGramTextAnimationPrivateLetDeleteAnimEnabled
         case reqGramTextAnimationPrivateLetParticleStyle
         case reqGramTextAnimationPrivateLetParticleCount
         case reqGramTextAnimationPrivateLetParticleSpeed
         case reqGramTextAnimationPrivateLetParticleSpread
         case reqGramTextAnimationPrivateLetParticleSize
         case reqGramTextAnimationPrivateLetCursorEnabled
         case reqGramTextAnimationPrivateLetCursorSpeed
         case reqGramTextAnimationPrivateLetCursorWidth
         case reqGramTextAnimationPrivateLetLiquidCursorEnabled
         case reqGramTextAnimationPrivateLetLiquidScaleFactor
         case reqGramTextAnimationPrivateLetSelectionCursorEffect
         case reqGramTextAnimationPrivateLetSelectionLiquidStretch
         case reqGramTextAnimationPrivateLetSelectionLiquidSide
         case reqGramTextAnimationPrivateLetIgnoreSpaces
         case reqGramTextAnimationPrivateLetAnimateAllLines
         case reqGramTextAnimationPrivateLetDebugMode
        // MARK: AyuGram - settings keys
        case ayuGhostMode
        case ayuGhostBlockReadReceipts
        case ayuGhostBlockTyping
        case ayuGhostBlockOnlinePresence
        case ayuGhostBlockStoryViews
        case ayuSaveDeletedMessages
        case ayuSaveEditedMessages
        case ayuSaveMediaAttachments
        case ayuShowGhostModeInProfile
        case ayuMediaLimitBytes
        case ayuDeletedIconStyle
        case ayuDeletedIconColor
        case ayuDeletedOpacity
        case ayuShowDeletedInline
        // MARK: AyuGram - ghost mode (extended)
        case ayuGhostSendOfflineAfterOnline
        case ayuGhostMarkReadAfterAction
        case ayuGhostUseScheduledMessages
        case ayuGhostSendWithoutSound
        case ayuGhostSuggestBeforeStory
        case ayuGhostLockReadReceipts
        case ayuGhostLockTyping
        case ayuGhostLockOnlinePresence
        case ayuGhostLockStoryViews
        // MARK: AyuGram - message saving (extended)
        case ayuSaveForBots
        case ayuSaveMediaInPrivateChats
        case ayuSaveMediaInPublicChannels
        case ayuSaveMediaInPrivateChannels
        case ayuSaveMediaInPublicGroups
        case ayuSaveMediaInPrivateGroups
        case ayuSaveReactions
        // MARK: AyuGram - marks
        case ayuEditedMark
        case ayuSemiTransparentDeleted
        // MARK: AyuGram - regex filters
        case ayuFiltersEnabled
        case ayuFiltersInChats
        case ayuFiltersCaseInsensitive
        case ayuHideFromBlocked
        case ayuRegexFilters
        case ayuShadowBanIds
        // MARK: AyuGram - appearance / chats
        case ayuDisableAds
        case ayuDisableStories
        case ayuDisableCustomBackgrounds
        case ayuHidePremiumStatuses
        case ayuShowOnlyAddedEmojisAndStickers
        case ayuCollapseSimilarChannels
        case ayuHideSimilarChannels
        case ayuMessageBubbleRadius
        case ayuAvatarCorners
        case ayuDisableOpenLinkWarning
        case ayuRemoveMessageTail
        case ayuSimpleQuotesAndReplies
        case ayuHideFastShare
        case ayuLocalPremium
        case ayuShowChannelReactions
        case ayuShowGroupReactions
        case ayuShowPrivateChatReactions
        case ayuUnlimitedRecentStickers
        case ayuShowMessageSeconds
        case ayuShowPeerId
        case ayuFilterZalgo
        case ayuHideAllChatsFolder
        case ayuDisableGreetingSticker
        case ayuChannelBottomButton
        case ayuHideNotificationCounters
        case ayuHideNotificationBadge
        case ayuStickerConfirmation
        case ayuGifConfirmation
        case ayuVoiceConfirmation
        case ayuRoundConfirmation
        case ayuSpoofWebviewAsAndroid
        // MARK: AyuGram - context menu visibility
        case ayuShowMessageDetailsInContextMenu
        case ayuShowHideMessageInContextMenu
        case ayuShowUserMessagesInContextMenu
        case ayuShowRepeatMessageInContextMenu
        case ayuShowAddFilterInContextMenu
        case ayuShowSaveMessageInContextMenu
        // MARK: AyuGram - remote config (RCManager)
        case ayuRCEnabled
        case ayuRCLastFetch
        case ayuRCPayload
        // MARK: AyuGram - misc
        case ayuStreamerMode
        case ayuKeepDeletedOnOwnDelete
    }
    
    public enum DownloadSpeedBoostValues: String, CaseIterable {
        case none
        case medium
        case maximum
    }
    
    public enum BottomTabStyleValues: String, CaseIterable {
        case telegram
        case ios
    }
    
    public enum AllChatsTitleLengthOverride: String, CaseIterable {
        case none
        case short
        case long
    }
    
    public enum AllChatsFolderPositionOverride: String, CaseIterable {
        case none
        case last
        case hidden
    }

    public enum ChatListLines: String, CaseIterable {
        case three = "3"
        case two = "2"
        case one = "1"

        public static let defaultValue: ChatListLines = .three
    }
    
    public enum MessageDoubleTapAction: String, CaseIterable {
        case `default`
        case none
        case edit
    }
    
    public enum VideoPIPSwipeDirection: String, CaseIterable {
        case up
        case down
        case none
    }

    public enum TranscriptionBackend: String, CaseIterable {
        case `default`
        case apple
    }

    public enum TranslationBackend: String, CaseIterable {
        case `default`
        case gtranslate
        case system
        // Make sure to update TranslationConfiguration
    }
        
    public enum PinnedMessageNotificationsSettings: String, CaseIterable {
        case `default`
        case silenced
        case disabled
    }
    
    public enum MentionsAndRepliesNotificationsSettings: String, CaseIterable {
        case `default`
        case silenced
        case disabled
    }

    public enum NYStyle: String, CaseIterable {
        case `default`
        case snow
        case lightning
    }

    // MARK: AyuGram - typed setting enums

    /// When to force outgoing messages to be silent.
    public enum AyuSendWithoutSound: String, CaseIterable {
        case never
        /// Only while ghost mode is active.
        case ghost
        case always
    }

    /// How a peer id is rendered in profiles and message details.
    public enum AyuPeerIdDisplay: String, CaseIterable {
        case hidden
        /// Raw Telegram API id (e.g. `1234567890`).
        case telegram
        /// Bot API id (channels/groups negated and prefixed).
        case bot
    }

    /// Bottom button shown in broadcast channels.
    public enum AyuChannelBottomButton: String, CaseIterable {
        case hidden
        case mute
        /// Discussion group, falling back to mute/unmute when there is none.
        case discuss
    }

    /// Visibility of an optional context-menu entry.
    public enum AyuContextMenuVisibility: String, CaseIterable {
        case hidden
        case visible
    }
    
    public static let defaultValues: [String: Any] = [
        Keys.hidePhoneInSettings.rawValue: true,
        Keys.showTabNames.rawValue: true,
        Keys.startTelescopeWithRearCam.rawValue: false,
        Keys.accountColorsSaturation.rawValue: 100,
        Keys.uploadSpeedBoost.rawValue: false,
        Keys.downloadSpeedBoost.rawValue: DownloadSpeedBoostValues.none.rawValue,
        Keys.rememberLastFolder.rawValue: false,
        Keys.bottomTabStyle.rawValue: BottomTabStyleValues.telegram.rawValue,
        Keys.lastAccountFolders.rawValue: [:],
        Keys.localDNSForProxyHost.rawValue: false,
        Keys.sendLargePhotos.rawValue: false,
        Keys.outgoingPhotoQuality.rawValue: 70,
        Keys.storyStealthMode.rawValue: false,
        Keys.canUseStealthMode.rawValue: true,
        Keys.disableSwipeToRecordStory.rawValue: false,
        Keys.quickTranslateButton.rawValue: false,
        Keys.outgoingLanguageTranslation.rawValue: [:],
        Keys.hideReactions.rawValue: false,
        Keys.showRepostToStory.rawValue: true,
        Keys.contextShowSelectFromUser.rawValue: true,
        Keys.contextShowSaveToCloud.rawValue: true,
        Keys.contextShowRestrict.rawValue: true,
        // Keys.contextShowBan.rawValue: true,
        Keys.contextShowHideForwardName.rawValue: true,
        Keys.contextShowReport.rawValue: true,
        Keys.contextShowReply.rawValue: true,
        Keys.contextShowPin.rawValue: true,
        Keys.contextShowSaveMedia.rawValue: true,
        Keys.contextShowMessageReplies.rawValue: true,
        Keys.contextShowJson.rawValue: false,
        Keys.disableScrollToNextChannel.rawValue: false,
        Keys.disableScrollToNextTopic.rawValue: false,
        Keys.disableChatSwipeOptions.rawValue: false,
        Keys.disableDeleteChatSwipeOption.rawValue: false,
        Keys.disableGalleryCamera.rawValue: false,
        Keys.disableGalleryCameraPreview.rawValue: false,
        Keys.disableSendAsButton.rawValue: false,
        Keys.disableSnapDeletionEffect.rawValue: false,
        Keys.stickerSize.rawValue: 100,
        Keys.stickerTimestamp.rawValue: true,
        Keys.hideRecordingButton.rawValue: false,
        Keys.hideTabBar.rawValue: false,
        Keys.showDC.rawValue: false,
        Keys.showCreationDate.rawValue: true,
        Keys.showRegDate.rawValue: true,
        Keys.regDateCache.rawValue: [:],
        Keys.compactChatList.rawValue: false,
        Keys.chatListLines.rawValue: ChatListLines.defaultValue.rawValue,
        Keys.compactFolderNames.rawValue: false,
        Keys.allChatsTitleLengthOverride.rawValue: AllChatsTitleLengthOverride.none.rawValue,
//        Keys.allChatsFolderPositionOverride.rawValue: AllChatsFolderPositionOverride.none.rawValue
        Keys.allChatsHidden.rawValue: false,
        Keys.defaultEmojisFirst.rawValue: false,
        Keys.messageDoubleTapActionOutgoing.rawValue: MessageDoubleTapAction.default.rawValue,
        Keys.wideChannelPosts.rawValue: false,
        Keys.forceEmojiTab.rawValue: false,
        Keys.hideChannelBottomButton.rawValue: false,
        Keys.secondsInMessages.rawValue: false,
        Keys.forceSystemSharing.rawValue: false,
        Keys.confirmCalls.rawValue: true,
        Keys.videoPIPSwipeDirection.rawValue: VideoPIPSwipeDirection.up.rawValue,
        Keys.messageFilterKeywords.rawValue: [],
        Keys.inputToolbar.rawValue: false,
        Keys.primaryUserId.rawValue: "",
        Keys.dismissedSGSuggestions.rawValue: [],
        Keys.duckyAppIconAvailable.rawValue: true,
        Keys.transcriptionBackend.rawValue: TranscriptionBackend.default.rawValue,
        Keys.translationBackend.rawValue: TranslationBackend.default.rawValue,
        Keys.customAppBadge.rawValue: "",
        Keys.canUseNY.rawValue: false,
        Keys.nyStyle.rawValue: NYStyle.default.rawValue,
        Keys.wideTabBar.rawValue: false,
        Keys.tabBarSearchEnabled.rawValue: true,
        Keys.hideStories.rawValue: false,
        Keys.warnOnStoriesOpen.rawValue: false,
        Keys.showProfileId.rawValue: true,
        Keys.sendWithReturnKey.rawValue: false,
         // MARK: ReqGram plugin defaults
          Keys.reqGramGiftIdEnabled.rawValue: false,
          Keys.reqGramSendGiftByIdEnabled.rawValue: false,
         // Native iOS forwarding/deletion already batches requests at Telegram's
         // supported limit. Keep the optional high-level feature disabled until
         // an explicit native entry point is added; never alter protected-content
         // checks or low-level request batching.
         Keys.reqGramZwyNoForwardLimitEnabled.rawValue: false,
          Keys.reqGramTextAnimationPrivateLetEnabled.rawValue: false,
          Keys.reqGramTextAnimationPrivateLetDuration.rawValue: 300,
          Keys.reqGramTextAnimationPrivateLetBlurEnabled.rawValue: true,
          Keys.reqGramTextAnimationPrivateLetBlurDuration.rawValue: 100,
          Keys.reqGramTextAnimationPrivateLetBlurRadius.rawValue: 10,
          Keys.reqGramTextAnimationPrivateLetBlurTextDelay.rawValue: 20,
          Keys.reqGramTextAnimationPrivateLetSlideEnabled.rawValue: true,
          Keys.reqGramTextAnimationPrivateLetSlideDist.rawValue: 20,
          Keys.reqGramTextAnimationPrivateLetScaleEnabled.rawValue: false,
          Keys.reqGramTextAnimationPrivateLetScaleStart.rawValue: 0.0,
          Keys.reqGramTextAnimationPrivateLetRotateEnabled.rawValue: false,
          Keys.reqGramTextAnimationPrivateLetRotateAngle.rawValue: -15,
          Keys.reqGramTextAnimationPrivateLetDeleteAnimEnabled.rawValue: true,
          Keys.reqGramTextAnimationPrivateLetParticleStyle.rawValue: 0,
          Keys.reqGramTextAnimationPrivateLetParticleCount.rawValue: 5,
          Keys.reqGramTextAnimationPrivateLetParticleSpeed.rawValue: 50,
          Keys.reqGramTextAnimationPrivateLetParticleSpread.rawValue: 50,
          Keys.reqGramTextAnimationPrivateLetParticleSize.rawValue: 50,
          Keys.reqGramTextAnimationPrivateLetCursorEnabled.rawValue: true,
           Keys.reqGramTextAnimationPrivateLetCursorSpeed.rawValue: 30,
          Keys.reqGramTextAnimationPrivateLetCursorWidth.rawValue: 5,
          Keys.reqGramTextAnimationPrivateLetLiquidCursorEnabled.rawValue: false,
          Keys.reqGramTextAnimationPrivateLetLiquidScaleFactor.rawValue: 15,
          Keys.reqGramTextAnimationPrivateLetSelectionCursorEffect.rawValue: 0,
          Keys.reqGramTextAnimationPrivateLetSelectionLiquidStretch.rawValue: 60,
          Keys.reqGramTextAnimationPrivateLetSelectionLiquidSide.rawValue: 50,
          Keys.reqGramTextAnimationPrivateLetIgnoreSpaces.rawValue: true,
          Keys.reqGramTextAnimationPrivateLetAnimateAllLines.rawValue: false,
          Keys.reqGramTextAnimationPrivateLetDebugMode.rawValue: false,
         // These Android plugins have no native iOS implementation; keep their
        // gates off rather than implying unsupported behavior is active.
        Keys.reqGramDeletedGiftSenderEnabled.rawValue: false,
        Keys.reqGramZwyLibEnabled.rawValue: false,
         Keys.reqGramLocalEdictorEnabled.rawValue: false,
        // MARK: AyuGram - default values
        Keys.ayuGhostMode.rawValue: false,
        Keys.ayuGhostBlockReadReceipts.rawValue: true,
        Keys.ayuGhostBlockTyping.rawValue: true,
        Keys.ayuGhostBlockOnlinePresence.rawValue: true,
        Keys.ayuGhostBlockStoryViews.rawValue: true,
        Keys.ayuSaveDeletedMessages.rawValue: false,
        Keys.ayuSaveEditedMessages.rawValue: false,
        Keys.ayuSaveMediaAttachments.rawValue: false,
        Keys.ayuShowGhostModeInProfile.rawValue: false,
        // 50 MB default per-file media limit (0 = unlimited)
        Keys.ayuMediaLimitBytes.rawValue: 50 * 1024 * 1024,
        Keys.ayuDeletedIconStyle.rawValue: "trash",
        Keys.ayuDeletedIconColor.rawValue: "theme",
        // Legacy value retained for preferences compatibility. Inline and saved
        // deleted-message presentation is controlled by ayuSemiTransparentDeleted.
        Keys.ayuDeletedOpacity.rawValue: 70,
        Keys.ayuShowDeletedInline.rawValue: true,
        // MARK: AyuGram - ghost mode (extended) defaults
        Keys.ayuGhostSendOfflineAfterOnline.rawValue: false,
        Keys.ayuGhostMarkReadAfterAction.rawValue: true,
        Keys.ayuGhostUseScheduledMessages.rawValue: false,
        // SendWithoutSound: "never" | "ghost" | "always"
        Keys.ayuGhostSendWithoutSound.rawValue: "never",
        Keys.ayuGhostSuggestBeforeStory.rawValue: true,
        Keys.ayuGhostLockReadReceipts.rawValue: false,
        Keys.ayuGhostLockTyping.rawValue: false,
        Keys.ayuGhostLockOnlinePresence.rawValue: false,
        Keys.ayuGhostLockStoryViews.rawValue: false,
        // MARK: AyuGram - message saving (extended) defaults
        Keys.ayuSaveForBots.rawValue: false,
        Keys.ayuSaveMediaInPrivateChats.rawValue: true,
        Keys.ayuSaveMediaInPublicChannels.rawValue: false,
        Keys.ayuSaveMediaInPrivateChannels.rawValue: true,
        Keys.ayuSaveMediaInPublicGroups.rawValue: false,
        Keys.ayuSaveMediaInPrivateGroups.rawValue: true,
        Keys.ayuSaveReactions.rawValue: true,
        // MARK: AyuGram - marks defaults
        // Empty means "use the app's own localized 'edited' label".
        Keys.ayuEditedMark.rawValue: "",
        Keys.ayuSemiTransparentDeleted.rawValue: true,
        // MARK: AyuGram - regex filters defaults
        Keys.ayuFiltersEnabled.rawValue: false,
        Keys.ayuFiltersInChats.rawValue: false,
        Keys.ayuFiltersCaseInsensitive.rawValue: true,
        Keys.ayuHideFromBlocked.rawValue: false,
        // JSON array of AyuRegexFilter objects.
        Keys.ayuRegexFilters.rawValue: "[]",
        // JSON array of Int64 peer ids.
        Keys.ayuShadowBanIds.rawValue: "[]",
        // MARK: AyuGram - appearance / chats defaults
        Keys.ayuDisableAds.rawValue: true,
        Keys.ayuDisableStories.rawValue: false,
        Keys.ayuDisableCustomBackgrounds.rawValue: false,
        Keys.ayuHidePremiumStatuses.rawValue: false,
        Keys.ayuShowOnlyAddedEmojisAndStickers.rawValue: false,
        Keys.ayuCollapseSimilarChannels.rawValue: true,
        Keys.ayuHideSimilarChannels.rawValue: false,
        // -1 means "use the app default radius".
        Keys.ayuMessageBubbleRadius.rawValue: -1,
        // Percentage of half-height; 50 = fully round, matches Telegram default.
        Keys.ayuAvatarCorners.rawValue: 50,
        Keys.ayuDisableOpenLinkWarning.rawValue: false,
        Keys.ayuRemoveMessageTail.rawValue: false,
        Keys.ayuSimpleQuotesAndReplies.rawValue: false,
        Keys.ayuHideFastShare.rawValue: false,
        Keys.ayuLocalPremium.rawValue: false,
        Keys.ayuShowChannelReactions.rawValue: true,
        Keys.ayuShowGroupReactions.rawValue: true,
        Keys.ayuShowPrivateChatReactions.rawValue: true,
        Keys.ayuUnlimitedRecentStickers.rawValue: false,
        Keys.ayuShowMessageSeconds.rawValue: false,
        // PeerIdDisplay: "hidden" | "telegram" | "bot"
        Keys.ayuShowPeerId.rawValue: "bot",
        Keys.ayuFilterZalgo.rawValue: false,
        Keys.ayuHideAllChatsFolder.rawValue: false,
        Keys.ayuDisableGreetingSticker.rawValue: false,
        // ChannelBottomButton: "hidden" | "mute" | "discuss"
        Keys.ayuChannelBottomButton.rawValue: "discuss",
        Keys.ayuHideNotificationCounters.rawValue: false,
        Keys.ayuHideNotificationBadge.rawValue: false,
        Keys.ayuStickerConfirmation.rawValue: false,
        Keys.ayuGifConfirmation.rawValue: false,
        Keys.ayuVoiceConfirmation.rawValue: false,
        Keys.ayuRoundConfirmation.rawValue: false,
        Keys.ayuSpoofWebviewAsAndroid.rawValue: false,
        // MARK: AyuGram - context menu visibility defaults
        // ContextMenuVisibility: "hidden" | "visible"
        Keys.ayuShowMessageDetailsInContextMenu.rawValue: "visible",
        Keys.ayuShowHideMessageInContextMenu.rawValue: "hidden",
        Keys.ayuShowUserMessagesInContextMenu.rawValue: "visible",
        Keys.ayuShowRepeatMessageInContextMenu.rawValue: "hidden",
        Keys.ayuShowAddFilterInContextMenu.rawValue: "visible",
        Keys.ayuShowSaveMessageInContextMenu.rawValue: "visible",
        // MARK: AyuGram - remote config defaults
        Keys.ayuRCEnabled.rawValue: false,
        Keys.ayuRCLastFetch.rawValue: 0,
        Keys.ayuRCPayload.rawValue: "",
        // MARK: AyuGram - misc defaults
        Keys.ayuStreamerMode.rawValue: false,
        Keys.ayuKeepDeletedOnOwnDelete.rawValue: false
    ]
    
    public static let groupDefaultValues: [String: Any] = [
        Keys.legacyNotificationsFix.rawValue: false,
        Keys.pinnedMessageNotifications.rawValue: PinnedMessageNotificationsSettings.default.rawValue,
        Keys.mentionsAndRepliesNotifications.rawValue: MentionsAndRepliesNotificationsSettings.default.rawValue,
        Keys.status.rawValue: 1,
        Keys.showRepostToStoryV2.rawValue: true,
    ]
    
    @UserDefault(key: Keys.hidePhoneInSettings.rawValue)
    public var hidePhoneInSettings: Bool
    
    @UserDefault(key: Keys.showTabNames.rawValue)
    public var showTabNames: Bool
    
    @UserDefault(key: Keys.startTelescopeWithRearCam.rawValue)
    public var startTelescopeWithRearCam: Bool
    
    @UserDefault(key: Keys.accountColorsSaturation.rawValue)
    public var accountColorsSaturation: Int32
    
    @UserDefault(key: Keys.uploadSpeedBoost.rawValue)
    public var uploadSpeedBoost: Bool
    
    @UserDefault(key: Keys.downloadSpeedBoost.rawValue)
    public var downloadSpeedBoost: String
    
    @UserDefault(key: Keys.rememberLastFolder.rawValue)
    public var rememberLastFolder: Bool
    
    // Disabled while Telegram is migrating to Glass
    // @UserDefault(key: Keys.bottomTabStyle.rawValue)
    public var bottomTabStyle: String {
        set {}
        get {
            return BottomTabStyleValues.ios.rawValue
        }
    }
    
    public var lastAccountFolders = UserDefaultsBackedDictionary<String, Int32>(userDefaultsKey: Keys.lastAccountFolders.rawValue, threadSafe: false)
    
    @UserDefault(key: Keys.localDNSForProxyHost.rawValue)
    public var localDNSForProxyHost: Bool
    
    @UserDefault(key: Keys.sendLargePhotos.rawValue)
    public var sendLargePhotos: Bool
    
    @UserDefault(key: Keys.outgoingPhotoQuality.rawValue)
    public var outgoingPhotoQuality: Int32

    @UserDefault(key: Keys.hideStories.rawValue)
    public var hideStories: Bool

    @UserDefault(key: Keys.warnOnStoriesOpen.rawValue)
    public var warnOnStoriesOpen: Bool
    
    @UserDefault(key: Keys.storyStealthMode.rawValue)
    public var storyStealthMode: Bool
    
    @UserDefault(key: Keys.canUseStealthMode.rawValue)
    public var canUseStealthMode: Bool    
    
    @UserDefault(key: Keys.disableSwipeToRecordStory.rawValue)
    public var disableSwipeToRecordStory: Bool   
    
    @UserDefault(key: Keys.quickTranslateButton.rawValue)
    public var quickTranslateButton: Bool
    
    public var outgoingLanguageTranslation = UserDefaultsBackedDictionary<String, String>(userDefaultsKey: Keys.outgoingLanguageTranslation.rawValue, threadSafe: false)
    
    @UserDefault(key: Keys.hideReactions.rawValue)
    public var hideReactions: Bool

    // @available(*, deprecated, message: "Use showRepostToStoryV2 instead")
    @UserDefault(key: Keys.showRepostToStory.rawValue)
    public var showRepostToStory: Bool

    @UserDefault(key: Keys.showRepostToStoryV2.rawValue, userDefaults: sgAppGroupUserDefaults() ?? .standard)
    public var showRepostToStoryV2: Bool

    @UserDefault(key: Keys.contextShowRestrict.rawValue)
    public var contextShowRestrict: Bool

    /*@UserDefault(key: Keys.contextShowBan.rawValue)
    public var contextShowBan: Bool*/

    @UserDefault(key: Keys.contextShowSelectFromUser.rawValue)
    public var contextShowSelectFromUser: Bool

    @UserDefault(key: Keys.contextShowSaveToCloud.rawValue)
    public var contextShowSaveToCloud: Bool

    @UserDefault(key: Keys.contextShowHideForwardName.rawValue)
    public var contextShowHideForwardName: Bool

    @UserDefault(key: Keys.contextShowReport.rawValue)
    public var contextShowReport: Bool

    @UserDefault(key: Keys.contextShowReply.rawValue)
    public var contextShowReply: Bool

    @UserDefault(key: Keys.contextShowPin.rawValue)
    public var contextShowPin: Bool

    @UserDefault(key: Keys.contextShowSaveMedia.rawValue)
    public var contextShowSaveMedia: Bool

    @UserDefault(key: Keys.contextShowMessageReplies.rawValue)
    public var contextShowMessageReplies: Bool
    
    @UserDefault(key: Keys.contextShowJson.rawValue)
    public var contextShowJson: Bool
    
    @UserDefault(key: Keys.disableScrollToNextChannel.rawValue)
    public var disableScrollToNextChannel: Bool

    @UserDefault(key: Keys.disableScrollToNextTopic.rawValue)
    public var disableScrollToNextTopic: Bool

    @UserDefault(key: Keys.disableChatSwipeOptions.rawValue)
    public var disableChatSwipeOptions: Bool

    @UserDefault(key: Keys.disableDeleteChatSwipeOption.rawValue)
    public var disableDeleteChatSwipeOption: Bool

    @UserDefault(key: Keys.disableGalleryCamera.rawValue)
    public var disableGalleryCamera: Bool

    @UserDefault(key: Keys.disableGalleryCameraPreview.rawValue)
    public var disableGalleryCameraPreview: Bool

    @UserDefault(key: Keys.disableSendAsButton.rawValue)
    public var disableSendAsButton: Bool

    @UserDefault(key: Keys.disableSnapDeletionEffect.rawValue)
    public var disableSnapDeletionEffect: Bool
    
    @UserDefault(key: Keys.stickerSize.rawValue)
    public var stickerSize: Int32
    
    @UserDefault(key: Keys.stickerTimestamp.rawValue)
    public var stickerTimestamp: Bool    

    @UserDefault(key: Keys.hideRecordingButton.rawValue)
    public var hideRecordingButton: Bool
    
    @UserDefault(key: Keys.hideTabBar.rawValue)
    public var hideTabBar: Bool

    @UserDefault(key: Keys.showProfileId.rawValue)
    public var showProfileId: Bool
    
    @UserDefault(key: Keys.showDC.rawValue)
    public var showDC: Bool
    
    @UserDefault(key: Keys.showCreationDate.rawValue)
    public var showCreationDate: Bool

    @UserDefault(key: Keys.showRegDate.rawValue)
    public var showRegDate: Bool

    public var regDateCache = UserDefaultsBackedDictionary<String, Data>(userDefaultsKey: Keys.regDateCache.rawValue, threadSafe: false)
    
    @UserDefault(key: Keys.compactChatList.rawValue)
    public var compactChatList: Bool

    @UserDefault(key: Keys.chatListLines.rawValue)
    public var chatListLines: String

    @UserDefault(key: Keys.compactFolderNames.rawValue)
    public var compactFolderNames: Bool
    
    @UserDefault(key: Keys.allChatsTitleLengthOverride.rawValue)
    public var allChatsTitleLengthOverride: String
//    
//    @UserDefault(key: Keys.allChatsFolderPositionOverride.rawValue)
//    public var allChatsFolderPositionOverride: String
    @UserDefault(key: Keys.allChatsHidden.rawValue)
    public var allChatsHidden: Bool

    @UserDefault(key: Keys.defaultEmojisFirst.rawValue)
    public var defaultEmojisFirst: Bool
    
    @UserDefault(key: Keys.messageDoubleTapActionOutgoing.rawValue)
    public var messageDoubleTapActionOutgoing: String
    
    @UserDefault(key: Keys.wideChannelPosts.rawValue)
    public var wideChannelPosts: Bool

    @UserDefault(key: Keys.forceEmojiTab.rawValue)
    public var forceEmojiTab: Bool
    
    @UserDefault(key: Keys.forceBuiltInMic.rawValue)
    public var forceBuiltInMic: Bool
    
    @UserDefault(key: Keys.secondsInMessages.rawValue)
    public var secondsInMessages: Bool
    
    @UserDefault(key: Keys.hideChannelBottomButton.rawValue)
    public var hideChannelBottomButton: Bool

    @UserDefault(key: Keys.forceSystemSharing.rawValue)
    public var forceSystemSharing: Bool

    @UserDefault(key: Keys.confirmCalls.rawValue)
    public var confirmCalls: Bool
    
    @UserDefault(key: Keys.videoPIPSwipeDirection.rawValue)
    public var videoPIPSwipeDirection: String

    @UserDefault(key: Keys.legacyNotificationsFix.rawValue, userDefaults: sgAppGroupUserDefaults() ?? .standard)
    public var legacyNotificationsFix: Bool
    
    @UserDefault(key: Keys.status.rawValue, userDefaults: sgAppGroupUserDefaults() ?? .standard)
    public var status: Int64

    public var ephemeralStatus: Int64 = 1
    
    @UserDefault(key: Keys.messageFilterKeywords.rawValue)
    public var messageFilterKeywords: [String]
    
    @UserDefault(key: Keys.inputToolbar.rawValue)
    public var inputToolbar: Bool

    @UserDefault(key: Keys.sendWithReturnKey.rawValue)
    public var sendWithReturnKey: Bool
    
    @UserDefault(key: Keys.pinnedMessageNotifications.rawValue, userDefaults: sgAppGroupUserDefaults() ?? .standard)
    public var pinnedMessageNotifications: String
    
    @UserDefault(key: Keys.mentionsAndRepliesNotifications.rawValue, userDefaults: sgAppGroupUserDefaults() ?? .standard)
    public var mentionsAndRepliesNotifications: String
    
    @UserDefault(key: Keys.primaryUserId.rawValue)
    public var primaryUserId: String

    @UserDefault(key: Keys.dismissedSGSuggestions.rawValue)
    public var dismissedSGSuggestions: [String]

    @UserDefault(key: Keys.duckyAppIconAvailable.rawValue)
    public var duckyAppIconAvailable: Bool

    @UserDefault(key: Keys.transcriptionBackend.rawValue)
    public var transcriptionBackend: String

    @UserDefault(key: Keys.translationBackend.rawValue)
    public var translationBackend: String

    @UserDefault(key: Keys.customAppBadge.rawValue)
    public var customAppBadge: String

    @UserDefault(key: Keys.canUseNY.rawValue)
    public var canUseNY: Bool

    @UserDefault(key: Keys.nyStyle.rawValue)
    public var nyStyle: String

    @UserDefault(key: Keys.wideTabBar.rawValue)
    public var wideTabBar: Bool
    
    @UserDefault(key: Keys.tabBarSearchEnabled.rawValue)
    public var tabBarSearchEnabled: Bool

    // MARK: ReqGram plugin settings
    @UserDefault(key: Keys.reqGramGiftIdEnabled.rawValue)
    public var reqGramGiftIdEnabled: Bool

    @UserDefault(key: Keys.reqGramSendGiftByIdEnabled.rawValue)
    public var reqGramSendGiftByIdEnabled: Bool

    @UserDefault(key: Keys.reqGramDeletedGiftSenderEnabled.rawValue)
    public var reqGramDeletedGiftSenderEnabled: Bool

    @UserDefault(key: Keys.reqGramZwyLibEnabled.rawValue)
    public var reqGramZwyLibEnabled: Bool

    @UserDefault(key: Keys.reqGramLocalEdictorEnabled.rawValue)
    public var reqGramLocalEdictorEnabled: Bool

    @UserDefault(key: Keys.reqGramZwyNoForwardLimitEnabled.rawValue)
    public var reqGramZwyNoForwardLimitEnabled: Bool

    @UserDefault(key: Keys.reqGramTextAnimationPrivateLetEnabled.rawValue)
     public var reqGramTextAnimationPrivateLetEnabled: Bool
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetDuration.rawValue) public var reqGramTextAnimationPrivateLetDuration: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetBlurEnabled.rawValue) public var reqGramTextAnimationPrivateLetBlurEnabled: Bool
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetBlurDuration.rawValue) public var reqGramTextAnimationPrivateLetBlurDuration: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetBlurRadius.rawValue) public var reqGramTextAnimationPrivateLetBlurRadius: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetBlurTextDelay.rawValue) public var reqGramTextAnimationPrivateLetBlurTextDelay: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetSlideEnabled.rawValue) public var reqGramTextAnimationPrivateLetSlideEnabled: Bool
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetSlideDist.rawValue) public var reqGramTextAnimationPrivateLetSlideDist: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetScaleEnabled.rawValue) public var reqGramTextAnimationPrivateLetScaleEnabled: Bool
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetScaleStart.rawValue) public var reqGramTextAnimationPrivateLetScaleStart: Double
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetRotateEnabled.rawValue) public var reqGramTextAnimationPrivateLetRotateEnabled: Bool
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetRotateAngle.rawValue) public var reqGramTextAnimationPrivateLetRotateAngle: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetDeleteAnimEnabled.rawValue) public var reqGramTextAnimationPrivateLetDeleteAnimEnabled: Bool
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetParticleStyle.rawValue) public var reqGramTextAnimationPrivateLetParticleStyle: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetParticleCount.rawValue) public var reqGramTextAnimationPrivateLetParticleCount: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetParticleSpeed.rawValue) public var reqGramTextAnimationPrivateLetParticleSpeed: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetParticleSpread.rawValue) public var reqGramTextAnimationPrivateLetParticleSpread: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetParticleSize.rawValue) public var reqGramTextAnimationPrivateLetParticleSize: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetCursorEnabled.rawValue) public var reqGramTextAnimationPrivateLetCursorEnabled: Bool
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetCursorSpeed.rawValue) public var reqGramTextAnimationPrivateLetCursorSpeed: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetCursorWidth.rawValue) public var reqGramTextAnimationPrivateLetCursorWidth: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetLiquidCursorEnabled.rawValue) public var reqGramTextAnimationPrivateLetLiquidCursorEnabled: Bool
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetLiquidScaleFactor.rawValue) public var reqGramTextAnimationPrivateLetLiquidScaleFactor: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetSelectionCursorEffect.rawValue) public var reqGramTextAnimationPrivateLetSelectionCursorEffect: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetSelectionLiquidStretch.rawValue) public var reqGramTextAnimationPrivateLetSelectionLiquidStretch: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetSelectionLiquidSide.rawValue) public var reqGramTextAnimationPrivateLetSelectionLiquidSide: Int
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetIgnoreSpaces.rawValue) public var reqGramTextAnimationPrivateLetIgnoreSpaces: Bool
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetAnimateAllLines.rawValue) public var reqGramTextAnimationPrivateLetAnimateAllLines: Bool
     @UserDefault(key: Keys.reqGramTextAnimationPrivateLetDebugMode.rawValue) public var reqGramTextAnimationPrivateLetDebugMode: Bool


    // MARK: AyuGram - settings properties
    /// Master ghost-mode toggle. Sub-toggles only take effect when this is true.
    @UserDefault(key: Keys.ayuGhostMode.rawValue)
    public var ayuGhostMode: Bool

    @UserDefault(key: Keys.ayuGhostBlockReadReceipts.rawValue)
    public var ayuGhostBlockReadReceipts: Bool

    @UserDefault(key: Keys.ayuGhostBlockTyping.rawValue)
    public var ayuGhostBlockTyping: Bool

    @UserDefault(key: Keys.ayuGhostBlockOnlinePresence.rawValue)
    public var ayuGhostBlockOnlinePresence: Bool

    @UserDefault(key: Keys.ayuGhostBlockStoryViews.rawValue)
    public var ayuGhostBlockStoryViews: Bool

    @UserDefault(key: Keys.ayuSaveDeletedMessages.rawValue)
    public var ayuSaveDeletedMessages: Bool

    @UserDefault(key: Keys.ayuSaveEditedMessages.rawValue)
    public var ayuSaveEditedMessages: Bool

    @UserDefault(key: Keys.ayuSaveMediaAttachments.rawValue)
    public var ayuSaveMediaAttachments: Bool

    /// Show the Ghost Mode quick toggle in profiles (own settings screen and peer info).
    @UserDefault(key: Keys.ayuShowGhostModeInProfile.rawValue)
    public var ayuShowGhostModeInProfile: Bool

    /// Maximum size of a single preserved media attachment, in bytes. 0 = unlimited.
    @UserDefault(key: Keys.ayuMediaLimitBytes.rawValue)
    public var ayuMediaLimitBytes: Int64

    /// Native marker style: "none" | "trash" | "cross" | "crossed-eye".
    @UserDefault(key: Keys.ayuDeletedIconStyle.rawValue)
    public var ayuDeletedIconStyle: String

    /// Marker tint: "theme" or one of the fixed AyuGram palette names.
    @UserDefault(key: Keys.ayuDeletedIconColor.rawValue)
    public var ayuDeletedIconColor: String

    /// Opacity of deleted-message content in the viewer, percent 0–100.
    @UserDefault(key: Keys.ayuDeletedOpacity.rawValue)
    public var ayuDeletedOpacity: Int

    /// Show preserved deleted messages inline in the chat history.
    @UserDefault(key: Keys.ayuShowDeletedInline.rawValue)
    public var ayuShowDeletedInline: Bool

    // MARK: AyuGram - ghost mode (extended)

    /// Periodically force an `offline` status update after the client goes online.
    /// Note the inverted polarity: enabling this *adds* traffic rather than blocking it.
    @UserDefault(key: Keys.ayuGhostSendOfflineAfterOnline.rawValue)
    public var ayuGhostSendOfflineAfterOnline: Bool

    /// When read receipts are blocked, still mark a chat read once the user acts in it.
    @UserDefault(key: Keys.ayuGhostMarkReadAfterAction.rawValue)
    public var ayuGhostMarkReadAfterAction: Bool

    /// Send via the scheduled-message path so sending does not flip presence to online.
    @UserDefault(key: Keys.ayuGhostUseScheduledMessages.rawValue)
    public var ayuGhostUseScheduledMessages: Bool

    /// `SendWithoutSound` raw value: "never" | "ghost" | "always".
    @UserDefault(key: Keys.ayuGhostSendWithoutSound.rawValue)
    public var ayuGhostSendWithoutSound: String

    /// Offer to enable ghost mode before opening a story.
    @UserDefault(key: Keys.ayuGhostSuggestBeforeStory.rawValue)
    public var ayuGhostSuggestBeforeStory: Bool

    /// Per-toggle locks: a locked sub-toggle is not flipped by the master switch.
    @UserDefault(key: Keys.ayuGhostLockReadReceipts.rawValue)
    public var ayuGhostLockReadReceipts: Bool

    @UserDefault(key: Keys.ayuGhostLockTyping.rawValue)
    public var ayuGhostLockTyping: Bool

    @UserDefault(key: Keys.ayuGhostLockOnlinePresence.rawValue)
    public var ayuGhostLockOnlinePresence: Bool

    @UserDefault(key: Keys.ayuGhostLockStoryViews.rawValue)
    public var ayuGhostLockStoryViews: Bool

    // MARK: AyuGram - message saving (extended)

    /// Preserve messages in bot dialogs too.
    @UserDefault(key: Keys.ayuSaveForBots.rawValue)
    public var ayuSaveForBots: Bool

    @UserDefault(key: Keys.ayuSaveMediaInPrivateChats.rawValue)
    public var ayuSaveMediaInPrivateChats: Bool

    @UserDefault(key: Keys.ayuSaveMediaInPublicChannels.rawValue)
    public var ayuSaveMediaInPublicChannels: Bool

    @UserDefault(key: Keys.ayuSaveMediaInPrivateChannels.rawValue)
    public var ayuSaveMediaInPrivateChannels: Bool

    @UserDefault(key: Keys.ayuSaveMediaInPublicGroups.rawValue)
    public var ayuSaveMediaInPublicGroups: Bool

    @UserDefault(key: Keys.ayuSaveMediaInPrivateGroups.rawValue)
    public var ayuSaveMediaInPrivateGroups: Bool

    /// Preserve reactions alongside a deleted message.
    @UserDefault(key: Keys.ayuSaveReactions.rawValue)
    public var ayuSaveReactions: Bool

    // MARK: AyuGram - marks

    /// Replacement for the "edited" label. Empty = use the app's localized label.
    @UserDefault(key: Keys.ayuEditedMark.rawValue)
    public var ayuEditedMark: String

    /// Render preserved deleted messages semi-transparent inline.
    @UserDefault(key: Keys.ayuSemiTransparentDeleted.rawValue)
    public var ayuSemiTransparentDeleted: Bool

    // MARK: AyuGram - regex filters

    @UserDefault(key: Keys.ayuFiltersEnabled.rawValue)
    public var ayuFiltersEnabled: Bool

    /// Apply filters outside broadcast channels as well.
    @UserDefault(key: Keys.ayuFiltersInChats.rawValue)
    public var ayuFiltersInChats: Bool

    @UserDefault(key: Keys.ayuFiltersCaseInsensitive.rawValue)
    public var ayuFiltersCaseInsensitive: Bool

    /// Hide messages authored by blocked users.
    @UserDefault(key: Keys.ayuHideFromBlocked.rawValue)
    public var ayuHideFromBlocked: Bool

    /// JSON-encoded `[AyuRegexFilter]`.
    @UserDefault(key: Keys.ayuRegexFilters.rawValue)
    public var ayuRegexFilters: String

    /// JSON-encoded `[Int64]` of shadow-banned peer ids.
    @UserDefault(key: Keys.ayuShadowBanIds.rawValue)
    public var ayuShadowBanIds: String

    // MARK: AyuGram - appearance / chats

    @UserDefault(key: Keys.ayuDisableAds.rawValue)
    public var ayuDisableAds: Bool

    @UserDefault(key: Keys.ayuDisableStories.rawValue)
    public var ayuDisableStories: Bool

    @UserDefault(key: Keys.ayuDisableCustomBackgrounds.rawValue)
    public var ayuDisableCustomBackgrounds: Bool

    @UserDefault(key: Keys.ayuHidePremiumStatuses.rawValue)
    public var ayuHidePremiumStatuses: Bool

    @UserDefault(key: Keys.ayuShowOnlyAddedEmojisAndStickers.rawValue)
    public var ayuShowOnlyAddedEmojisAndStickers: Bool

    @UserDefault(key: Keys.ayuCollapseSimilarChannels.rawValue)
    public var ayuCollapseSimilarChannels: Bool

    @UserDefault(key: Keys.ayuHideSimilarChannels.rawValue)
    public var ayuHideSimilarChannels: Bool

    /// Message bubble corner radius in points; -1 = app default.
    @UserDefault(key: Keys.ayuMessageBubbleRadius.rawValue)
    public var ayuMessageBubbleRadius: Int

    /// Avatar corner rounding as a percentage of half the avatar height; 50 = circle.
    @UserDefault(key: Keys.ayuAvatarCorners.rawValue)
    public var ayuAvatarCorners: Int

    @UserDefault(key: Keys.ayuDisableOpenLinkWarning.rawValue)
    public var ayuDisableOpenLinkWarning: Bool

    @UserDefault(key: Keys.ayuRemoveMessageTail.rawValue)
    public var ayuRemoveMessageTail: Bool

    @UserDefault(key: Keys.ayuSimpleQuotesAndReplies.rawValue)
    public var ayuSimpleQuotesAndReplies: Bool

    @UserDefault(key: Keys.ayuHideFastShare.rawValue)
    public var ayuHideFastShare: Bool

    /// Client-side Premium emulation. Does not unlock server-side features.
    @UserDefault(key: Keys.ayuLocalPremium.rawValue)
    public var ayuLocalPremium: Bool

    @UserDefault(key: Keys.ayuShowChannelReactions.rawValue)
    public var ayuShowChannelReactions: Bool

    @UserDefault(key: Keys.ayuShowGroupReactions.rawValue)
    public var ayuShowGroupReactions: Bool

    @UserDefault(key: Keys.ayuShowPrivateChatReactions.rawValue)
    public var ayuShowPrivateChatReactions: Bool

    @UserDefault(key: Keys.ayuUnlimitedRecentStickers.rawValue)
    public var ayuUnlimitedRecentStickers: Bool

    @UserDefault(key: Keys.ayuShowMessageSeconds.rawValue)
    public var ayuShowMessageSeconds: Bool

    /// `PeerIdDisplay` raw value: "hidden" | "telegram" | "bot".
    @UserDefault(key: Keys.ayuShowPeerId.rawValue)
    public var ayuShowPeerId: String

    /// Strip Zalgo combining marks from incoming text.
    @UserDefault(key: Keys.ayuFilterZalgo.rawValue)
    public var ayuFilterZalgo: Bool

    @UserDefault(key: Keys.ayuHideAllChatsFolder.rawValue)
    public var ayuHideAllChatsFolder: Bool

    @UserDefault(key: Keys.ayuDisableGreetingSticker.rawValue)
    public var ayuDisableGreetingSticker: Bool

    /// `ChannelBottomButton` raw value: "hidden" | "mute" | "discuss".
    @UserDefault(key: Keys.ayuChannelBottomButton.rawValue)
    public var ayuChannelBottomButton: String

    @UserDefault(key: Keys.ayuHideNotificationCounters.rawValue)
    public var ayuHideNotificationCounters: Bool

    @UserDefault(key: Keys.ayuHideNotificationBadge.rawValue)
    public var ayuHideNotificationBadge: Bool

    @UserDefault(key: Keys.ayuStickerConfirmation.rawValue)
    public var ayuStickerConfirmation: Bool

    @UserDefault(key: Keys.ayuGifConfirmation.rawValue)
    public var ayuGifConfirmation: Bool

    @UserDefault(key: Keys.ayuVoiceConfirmation.rawValue)
    public var ayuVoiceConfirmation: Bool

    @UserDefault(key: Keys.ayuRoundConfirmation.rawValue)
    public var ayuRoundConfirmation: Bool

    @UserDefault(key: Keys.ayuSpoofWebviewAsAndroid.rawValue)
    public var ayuSpoofWebviewAsAndroid: Bool

    // MARK: AyuGram - context menu visibility ("hidden" | "visible")

    @UserDefault(key: Keys.ayuShowMessageDetailsInContextMenu.rawValue)
    public var ayuShowMessageDetailsInContextMenu: String

    @UserDefault(key: Keys.ayuShowHideMessageInContextMenu.rawValue)
    public var ayuShowHideMessageInContextMenu: String

    @UserDefault(key: Keys.ayuShowUserMessagesInContextMenu.rawValue)
    public var ayuShowUserMessagesInContextMenu: String

    @UserDefault(key: Keys.ayuShowRepeatMessageInContextMenu.rawValue)
    public var ayuShowRepeatMessageInContextMenu: String

    @UserDefault(key: Keys.ayuShowAddFilterInContextMenu.rawValue)
    public var ayuShowAddFilterInContextMenu: String

    @UserDefault(key: Keys.ayuShowSaveMessageInContextMenu.rawValue)
    public var ayuShowSaveMessageInContextMenu: String

    // MARK: AyuGram - remote config

    /// Fetch the AyuGram/exteraGram badge remote config.
    @UserDefault(key: Keys.ayuRCEnabled.rawValue)
    public var ayuRCEnabled: Bool

    /// Unix timestamp of the last successful remote-config fetch.
    @UserDefault(key: Keys.ayuRCLastFetch.rawValue)
    public var ayuRCLastFetch: Int

    /// Cached remote-config JSON payload (already validated before storing).
    @UserDefault(key: Keys.ayuRCPayload.rawValue)
    public var ayuRCPayload: String

    // MARK: AyuGram - misc

    /// Hide sensitive content when the screen is being captured or recorded.
    @UserDefault(key: Keys.ayuStreamerMode.rawValue)
    public var ayuStreamerMode: Bool

    /// Default state of the "keep locally" checkbox in the delete confirmation sheet.
    @UserDefault(key: Keys.ayuKeepDeletedOnOwnDelete.rawValue)
    public var ayuKeepDeletedOnOwnDelete: Bool
}

extension SGSimpleSettings {
    public var isStealthModeEnabled: Bool {
        return storyStealthMode && canUseStealthMode
    }

    // MARK: AyuGram - computed helpers
    /// True when ghost mode is on AND at least one of the read-receipt / typing / story blocking sub-toggles is active.
    public var isAyuGhostActive: Bool {
        guard ayuGhostMode else { return false }
        return ayuGhostBlockReadReceipts || ayuGhostBlockTyping || ayuGhostBlockStoryViews || ayuGhostBlockOnlinePresence
    }

    public var isAyuBlockReadReceipts: Bool {
        return ayuGhostMode && ayuGhostBlockReadReceipts
    }

    public var isAyuBlockTyping: Bool {
        return ayuGhostMode && ayuGhostBlockTyping
    }

    public var isAyuBlockOnlinePresence: Bool {
        return ayuGhostMode && ayuGhostBlockOnlinePresence
    }

    public var isAyuBlockStoryViews: Bool {
        return ayuGhostMode && ayuGhostBlockStoryViews
    }

    // MARK: AyuGram - typed accessors

    public var ayuSendWithoutSoundEnum: SGSimpleSettings.AyuSendWithoutSound {
        return AyuSendWithoutSound(rawValue: ayuGhostSendWithoutSound) ?? .never
    }

    public var ayuPeerIdDisplayEnum: SGSimpleSettings.AyuPeerIdDisplay {
        return AyuPeerIdDisplay(rawValue: ayuShowPeerId) ?? .bot
    }

    public var ayuChannelBottomButtonEnum: SGSimpleSettings.AyuChannelBottomButton {
        return AyuChannelBottomButton(rawValue: ayuChannelBottomButton) ?? .discuss
    }

    /// Resolves whether an outgoing message should be sent silently right now.
    public var ayuShouldSendWithoutSound: Bool {
        switch ayuSendWithoutSoundEnum {
        case .never:
            return false
        case .ghost:
            return isAyuGhostActive
        case .always:
            return true
        }
    }

    /// True when at least one ghost sub-toggle is enabled but the master switch is off,
    /// i.e. the user has configured ghost mode but is not currently hidden.
    public var isAyuGhostConfiguredButInactive: Bool {
        guard !ayuGhostMode else { return false }
        return ayuGhostBlockReadReceipts || ayuGhostBlockTyping || ayuGhostBlockStoryViews || ayuGhostBlockOnlinePresence
    }

    /// Whether media should be preserved for a peer of the given kind.
    /// Mirrors AyuGram for Android's per-peer-type media matrix.
    public func ayuShouldSaveMedia(isPrivateChat: Bool, isChannel: Bool, isGroup: Bool, isPublic: Bool) -> Bool {
        guard ayuSaveMediaAttachments else { return false }
        if isPrivateChat {
            return ayuSaveMediaInPrivateChats
        }
        if isChannel {
            return isPublic ? ayuSaveMediaInPublicChannels : ayuSaveMediaInPrivateChannels
        }
        if isGroup {
            return isPublic ? ayuSaveMediaInPublicGroups : ayuSaveMediaInPrivateGroups
        }
        return true
    }

    public func ayuContextMenuVisible(_ rawValue: String) -> Bool {
        return (AyuContextMenuVisibility(rawValue: rawValue) ?? .visible) == .visible
    }

    public static func makeOutgoingLanguageTranslationKey(accountId: Int64, peerId: Int64) -> String {
        return "\(accountId):\(peerId)"
    }
}

extension SGSimpleSettings {
    public var translationBackendEnum: SGSimpleSettings.TranslationBackend {
        return TranslationBackend(rawValue: translationBackend) ?? .default
    }
    
    public var transcriptionBackendEnum: SGSimpleSettings.TranscriptionBackend {
        return TranscriptionBackend(rawValue: transcriptionBackend) ?? .default
    }
}

extension SGSimpleSettings {
    public var isNYEnabled: Bool {
        return canUseNY && NYStyle(rawValue: nyStyle) != .default
    }
}

public func getSGDownloadPartSize(_ default: Int64, fileSize: Int64?) -> Int64 {
    let currentDownloadSetting = SGSimpleSettings.shared.downloadSpeedBoost
    // Increasing chunk size for small files make it worse in terms of overall download performance
    let smallFileSizeThreshold = 1 * 1024 * 1024 // 1 MB
    switch (currentDownloadSetting) {
        case SGSimpleSettings.DownloadSpeedBoostValues.medium.rawValue:
            if let fileSize, fileSize <= smallFileSizeThreshold {
                return `default`
            }
            return 512 * 1024
        case SGSimpleSettings.DownloadSpeedBoostValues.maximum.rawValue:
            if let fileSize, fileSize <= smallFileSizeThreshold {
                return `default`
            }
            return 1024 * 1024
        default:
            return `default`
    }
}

public func getSGMaxPendingParts(_ default: Int) -> Int {
    let currentDownloadSetting = SGSimpleSettings.shared.downloadSpeedBoost
    switch (currentDownloadSetting) {
        case SGSimpleSettings.DownloadSpeedBoostValues.medium.rawValue:
            return 8
        case SGSimpleSettings.DownloadSpeedBoostValues.maximum.rawValue:
            return 12
        default:
            return `default`
    }
}

public func sgUseShortAllChatsTitle(_ default: Bool) -> Bool {
    let currentOverride = SGSimpleSettings.shared.allChatsTitleLengthOverride
    switch (currentOverride) {
        case SGSimpleSettings.AllChatsTitleLengthOverride.short.rawValue:
            return true
        case SGSimpleSettings.AllChatsTitleLengthOverride.long.rawValue:
            return false
        default:
            return `default`
    }
}
