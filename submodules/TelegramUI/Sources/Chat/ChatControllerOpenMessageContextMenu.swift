import Foundation
import UIKit
import Postbox
import SwiftSignalKit
import TelegramCore
import AsyncDisplayKit
import Display
import TelegramNotices
import ContextUI
import AccountContext
import ChatMessageItemView
import ChatMessageItemCommon
import ReactionSelectionNode
import EntityKeyboard
import TextNodeWithEntities
import PremiumUI
import TooltipUI
import TopMessageReactions
import TelegramNotices
import PresentationDataUtils
import ChatPresentationInterfaceState
import TextFormat
import SGStrings
import ChatMessagePaymentAlertController
import UndoUI

extension ChatControllerImpl {
    func openMessageContextMenu(message: EngineMessage, selectAll: Bool, node: ASDisplayNode, frame: CGRect, anyRecognizer: UIGestureRecognizer?, location: CGPoint?) -> Void {
        if self.presentationInterfaceState.interfaceState.selectionState != nil {
            return
        }
        let presentationData = self.presentationData

        // Synthetic preserved messages deliberately bypass the ordinary menu's
        // capability queries: those queries resolve MessageIds through Postbox.
        // Use a stable location presentation and expose only operations whose
        // inputs are the in-memory message itself.
        if message._asMessage().isAyuSyntheticDeletedMessage {
            self.openAyuSyntheticMessageContextMenu(message: message, node: node, anyRecognizer: anyRecognizer, location: location)
            return
        }
        
        self.dismissAllTooltips()
        
        let recognizer: TapLongTapOrDoubleTapGestureRecognizer? = anyRecognizer as? TapLongTapOrDoubleTapGestureRecognizer
        let gesture: ContextGesture? = anyRecognizer as? ContextGesture
        if let messages = self.chatDisplayNode.historyNode.messageGroupInCurrentHistoryView(message.id) {
            (self.view.window as? WindowHost)?.cancelInteractiveKeyboardGestures()
            self.chatDisplayNode.cancelInteractiveKeyboardGestures()
            var updatedMessages = messages
            for i in 0 ..< updatedMessages.count {
                if updatedMessages[i].id == message.id {
                    let message = updatedMessages.remove(at: i)
                    updatedMessages.insert(message, at: 0)
                    break
                }
            }
            
            guard let topMessage = messages.first else {
                return
            }

            let canBypassReactionRestrictions = canBypassRestrictions(chatPresentationInterfaceState: self.presentationInterfaceState)

            let _ = combineLatest(queue: .mainQueue(),
                self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.context.account.peerId)),
                contextMenuForChatPresentationInterfaceState(chatPresentationInterfaceState: self.presentationInterfaceState, context: self.context, messages: updatedMessages, controllerInteraction: self.controllerInteraction, selectAll: selectAll, interfaceInteraction: self.interfaceInteraction, messageNode: node as? ChatMessageItemView),
                peerMessageAllowedReactions(context: self.context, message: topMessage, ignoreDefault: canBypassReactionRestrictions),
                peerMessageSelectedReactions(context: self.context, message: EngineMessage(topMessage)),
                topMessageReactions(context: self.context, message: topMessage, subPeerId: self.chatLocation.threadId.flatMap(EnginePeer.Id.init), ignoreDefault: canBypassReactionRestrictions),
                ApplicationSpecificNotice.getChatTextSelectionTips(accountManager: self.context.sharedContext.accountManager)
            ).startStandalone(next: { [weak self] peer, actions, allowedReactionsAndStars, selectedReactions, topReactions, chatTextSelectionTips in
                guard let self else {
                    return
                }
                
                var (allowedReactions, _) = allowedReactionsAndStars
                
                var actions = actions
                switch actions.content {
                case let .list(itemList):
                    if itemList.isEmpty {
                        return
                    }
                case .custom, .twoLists:
                    break
                }
                
                if allowedReactions != nil, case let .customChatContents(customChatContents) = self.presentationInterfaceState.subject {
                    if case let .hashTagSearch(publicPosts) = customChatContents.kind, publicPosts {
                        allowedReactions = nil
                    }
                }

                var tip: ContextController.Tip?
                
                if tip == nil {
                    let isAd = message.adAttribute != nil
                        
                    var isAction = false
                    for media in message.media {
                        if media is TelegramMediaAction {
                            isAction = true
                            break
                        }
                    }
                    if self.presentationInterfaceState.myCopyProtectionEnabled && !isAction && !isAd {
                        tip = .messageCopyProtection(text: self.presentationData.strings.Conversation_CopyProtectionInfoPrivateYou)
                    } else if self.presentationInterfaceState.copyProtectionEnabled && !isAction && !isAd {
                        if case .scheduledMessages = self.subject {
                        } else {
                            if let peer = self.presentationInterfaceState.renderedPeer?.peer {
                                if peer is TelegramUser {
                                    tip = .messageCopyProtection(text: self.presentationData.strings.Conversation_CopyProtectionInfoPrivate(EnginePeer(peer).compactDisplayTitle).string)
                                } else {
                                    var isChannel = false
                                    if let channel = self.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, case .broadcast = channel.info {
                                        isChannel = true
                                    }
                                    tip = .messageCopyProtection(text: isChannel ? self.presentationData.strings.Conversation_CopyProtectionInfoChannel : self.presentationData.strings.Conversation_CopyProtectionInfoGroup)
                                }
                            }
                        }
                    } else {
                        let numberOfComponents = message.text.components(separatedBy: CharacterSet.whitespacesAndNewlines).count
                        let displayTextSelectionTip = numberOfComponents >= 3 && !message.text.isEmpty && chatTextSelectionTips < 3 && !isAd
                        if displayTextSelectionTip {
                            let _ = ApplicationSpecificNotice.incrementChatTextSelectionTips(accountManager: self.context.sharedContext.accountManager).startStandalone()
                            tip = .textSelection
                        }
                    }
                }
                
                if messages.contains(where: { $0.pendingProcessingAttribute != nil }) {
                    tip = .videoProcessing
                }

                if actions.tip == nil {
                    actions.tip = tip
                }
                
                actions.context = self.context
                actions.animationCache = self.controllerInteraction?.presentationContext.animationCache
                                                         
                if canAddMessageReactions(message: EngineMessage(topMessage)), let allowedReactions = allowedReactions, !topReactions.isEmpty {
                    actions.reactionItems = topReactions.map { ReactionContextItem.reaction(item: $0, icon: .none) }
                    actions.selectedReactionItems = selectedReactions.reactions
                    if message.areReactionsTags(accountPeerId: self.context.account.peerId) {
                        if self.presentationInterfaceState.isPremium {
                            actions.reactionsTitle = presentationData.strings.Chat_ContextMenuTagsTitle
                        } else {
                            actions.reactionsTitle = presentationData.strings.Chat_MessageContextMenu_NonPremiumTagsTitle
                            actions.reactionsLocked = true
                            actions.selectedReactionItems = Set()
                        }
                        actions.allPresetReactionsAreAvailable = true
                    }
                    
                    if let channel = self.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, case .broadcast = channel.info {
                        actions.alwaysAllowPremiumReactions = true
                    }
                    
                    if !actions.reactionItems.isEmpty {
                        let reactionItems: [EmojiComponentReactionItem] = actions.reactionItems.compactMap { item -> EmojiComponentReactionItem? in
                            switch item {
                            case let .reaction(reaction, _):
                                return EmojiComponentReactionItem(reaction: reaction.reaction.rawValue, file: reaction.stillAnimation)
                            default:
                                return nil
                            }
                        }
                        
                        var allReactionsAreAvailable = false
                        switch allowedReactions {
                        case .set:
                            allReactionsAreAvailable = false
                        case .all:
                            allReactionsAreAvailable = true
                        }
                        
                        if let channel = self.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramChannel, case .broadcast = channel.info {
                            allReactionsAreAvailable = false
                        }
                        
                        if allReactionsAreAvailable {
                            let premiumConfiguration = PremiumConfiguration.with(appConfiguration: context.currentAppConfiguration.with { $0 })
                            actions.getEmojiContent = { [weak self] animationCache, animationRenderer in
                                guard let self else {
                                    preconditionFailure()
                                }
                                
                                return EmojiPagerContentComponent.emojiInputData(
                                    context: self.context,
                                    animationCache: animationCache,
                                    animationRenderer: animationRenderer,
                                    isStandalone: false,
                                    subject: message.areReactionsTags(accountPeerId: self.context.account.peerId) ? .messageTag : .reaction(onlyTop: false),
                                    hasTrending: false,
                                    topReactionItems: reactionItems,
                                    areUnicodeEmojiEnabled: false,
                                    areCustomEmojiEnabled: !premiumConfiguration.isPremiumDisabled,
                                    chatPeerId: self.chatLocation.peerId,
                                    selectedItems: selectedReactions.files
                                )
                            }
                        } else if reactionItems.count > 16 {
                            actions.getEmojiContent = { [weak self] animationCache, animationRenderer in
                                guard let self else {
                                    preconditionFailure()
                                }
                                
                                return EmojiPagerContentComponent.emojiInputData(
                                    context: self.context,
                                    animationCache: animationCache,
                                    animationRenderer: animationRenderer,
                                    isStandalone: false,
                                    subject: .reaction(onlyTop: true),
                                    hasTrending: false,
                                    topReactionItems: reactionItems,
                                    areUnicodeEmojiEnabled: false,
                                    areCustomEmojiEnabled: false,
                                    chatPeerId: self.chatLocation.peerId,
                                    selectedItems: selectedReactions.files
                                )
                            }
                        }
                    }
                }
                
                self.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
                
                let presentationContext = self.controllerInteraction?.presentationContext
                
                var disableTransitionAnimations = false
                var actionsSignal: Signal<ContextController.Items, NoError> = .single(actions)
                if let entitiesAttribute = message.textEntitiesAttribute {
                    var emojiFileIds: [Int64] = []
                    for entity in entitiesAttribute.entities {
                        if case let .CustomEmoji(_, fileId) = entity.type {
                            emojiFileIds.append(fileId)
                        }
                    }
                    
                    let premiumConfiguration = PremiumConfiguration.with(appConfiguration: context.currentAppConfiguration.with { $0 })
                    
                    if !emojiFileIds.isEmpty && !premiumConfiguration.isPremiumDisabled {
                        tip = .animatedEmoji(text: nil, arguments: nil, file: nil, action: nil)
                        actions.tip = tip
                        disableTransitionAnimations = true
                        
                        let context = self.context
                        actionsSignal = .single(actions)
                        |> then(
                            context.engine.stickers.resolveInlineStickers(fileIds: emojiFileIds)
                            |> mapToSignal { files -> Signal<ContextController.Items, NoError> in
                                var packReferences: [StickerPackReference] = []
                                var existingIds = Set<Int64>()
                                for (_, file) in files {
                                    loop: for attribute in file.attributes {
                                        if case let .CustomEmoji(_, _, _, packReference) = attribute, let packReference = packReference {
                                            if case let .id(id, _) = packReference, !existingIds.contains(id) {
                                                packReferences.append(packReference)
                                                existingIds.insert(id)
                                            }
                                            break loop
                                        }
                                    }
                                }
                                
                                let action = { [weak self] in
                                    guard let self else {
                                        return
                                    }
                                    self.presentEmojiList(references: packReferences)
                                }
                                
                                if packReferences.count > 1 {
                                    actions.tip = .animatedEmoji(text: presentationData.strings.ChatContextMenu_EmojiSet(Int32(packReferences.count)), arguments: nil, file: nil, action: action)
                                    return .single(actions)
                                } else if let reference = packReferences.first {
                                    return context.engine.stickers.loadedStickerPack(reference: reference, forceActualized: false)
                                    |> filter { result in
                                        if case .result = result {
                                            return true
                                        } else {
                                            return false
                                        }
                                    }
                                    |> mapToSignal { result in
                                        if case let .result(info, items, _) = result, let presentationContext = presentationContext {
                                            actions.tip = .animatedEmoji(
                                                text: presentationData.strings.ChatContextMenu_EmojiSetSingle(info.title).string,
                                                arguments: TextNodeWithEntities.Arguments(
                                                    context: context,
                                                    cache: presentationContext.animationCache,
                                                    renderer: presentationContext.animationRenderer,
                                                    placeholderColor: .clear,
                                                    attemptSynchronous: true
                                                ),
                                                file: items.first?.file._parse(),
                                                action: action)
                                            return .single(actions)
                                        } else {
                                            return .complete()
                                        }
                                    }
                                } else {
                                    actions.tip = nil
                                    return .single(actions)
                                }
                            }
                        )
                    }
                }
                
                var keepDefaultContentTouches = false
                for media in message.media {
                    if media is TelegramMediaImage {
                        keepDefaultContentTouches = true
                    } else if let file = media as? TelegramMediaFile, file.isVideo {
                        keepDefaultContentTouches = true
                    }
                }
                
                let source: ContextContentSource
                if let location = location {
                    source = .location(ChatMessageContextLocationContentSource(controller: self, location: node.view.convert(node.bounds, to: nil).origin.offsetBy(dx: location.x, dy: location.y)))
                } else {
                    source = .extracted(ChatMessageContextExtractedContentSource(chatController: self, chatNode: self.chatDisplayNode, engine: self.context.engine, message: message, selectAll: selectAll, keepDefaultContentTouches: keepDefaultContentTouches))
                }
                
                self.canReadHistory.set(false)
                
                var hideReactionPanelTail = false
                for media in message.media {
                    if let action = media as? TelegramMediaAction {
                        switch action.action {
                        case .phoneCall:
                            break
                        case .conferenceCall:
                            break
                        default:
                            hideReactionPanelTail = true
                        }
                    }
                }
                
                let isSecret = self.presentationInterfaceState.copyProtectionEnabled || self.presentationInterfaceState.myCopyProtectionEnabled || self.chatLocation.peerId?.namespace == Namespaces.Peer.SecretChat
                let controller = makeContextController(presentationData: self.presentationData, source: source, items: actionsSignal, recognizer: recognizer, gesture: gesture, disableScreenshots: isSecret, hideReactionPanelTail: hideReactionPanelTail)
                controller.dismissed = { [weak self] in
                    self?.canReadHistory.set(true)
                }
                controller.immediateItemsTransitionAnimation = disableTransitionAnimations
                self.currentContextController = controller
                
                controller.premiumReactionsSelected = { [weak self, weak controller] in
                    guard let self else {
                        return
                    }
                    
                    controller?.dismissWithoutContent()
                    guard !self.presentAccountFrozenInfoIfNeeded(delay: true) else {
                        return
                    }
                    self.presentTagPremiumPaywall()
                }
                
                controller.reactionSelected = { [weak self, weak controller] chosenUpdatedReaction, isLarge in
                    guard let self else {
                        return
                    }
                    
                    guard !self.presentAccountFrozenInfoIfNeeded(delay: true) else {
                        controller?.dismiss(completion: {})
                        return
                    }
                    
                    guard let message = messages.first else {
                        return
                    }
                    
                    controller?.view.endEditing(true)
                    
                    if case .stars = chosenUpdatedReaction.reaction {
                        if !canSendReactionsToChat(self.presentationInterfaceState) {
                            if let controller {
                                controller.dismiss(completion: { [weak self] in
                                    self?.displaySendReactionRestrictedToast()
                                })
                            } else {
                                self.displaySendReactionRestrictedToast()
                            }
                            return
                        }

                        if isLarge {
                            if let controller {
                                controller.dismiss(completion: { [weak self] in
                                    guard let self else {
                                        return
                                    }
                                    self.openMessageSendStarsScreen(message: EngineMessage(message))
                                })
                            }
                            return
                        }
                        
                        let isFirst = !"".isEmpty
                        
                        self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                            if let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item {
                                if item.message.id == message.id {
                                    let chosenReaction: MessageReaction.Reaction = .stars
                                    itemNode.awaitingAppliedReaction = (chosenReaction, { [weak self, weak itemNode] in
                                        guard let self, let controller = controller else {
                                            return
                                        }
                                        if let itemNode = itemNode, let targetView = itemNode.targetReactionView(value: chosenReaction) {
                                            self.chatDisplayNode.messageTransitionNode.addMessageContextController(messageId: item.message.id, contextController: controller)
                                            
                                            var hideTargetButton: UIView?
                                            if isFirst {
                                                hideTargetButton = targetView.superview
                                            }
                                            
                                            controller.dismissWithReaction(value: chosenReaction, targetView: targetView, hideNode: true, animateTargetContainer: hideTargetButton, addStandaloneReactionAnimation: { [weak self] standaloneReactionAnimation in
                                                guard let self else {
                                                    return
                                                }
                                                self.chatDisplayNode.messageTransitionNode.addMessageStandaloneReactionAnimation(messageId: item.message.id, standaloneReactionAnimation: standaloneReactionAnimation)
                                                standaloneReactionAnimation.frame = self.chatDisplayNode.bounds
                                                self.chatDisplayNode.addSubnode(standaloneReactionAnimation)
                                            }, onHit: { [weak self, weak itemNode] in
                                                guard let self else {
                                                    return
                                                }
                                                if let itemNode = itemNode, let targetView = itemNode.targetReactionView(value: chosenReaction) {
                                                    if !"".isEmpty {
                                                        if self.context.sharedContext.energyUsageSettings.fullTranslucency {
                                                            self.chatDisplayNode.wrappingNode.triggerRipple(at: targetView.convert(targetView.bounds.center, to: self.chatDisplayNode.view))
                                                        }
                                                    }
                                                }
                                            }, completion: {})
                                        } else {
                                            controller.dismiss()
                                        }
                                    })
                                }
                            }
                        }
                        
                        guard let starsContext = self.context.starsContext else {
                            return
                        }
                        let _ = (combineLatest(
                            starsContext.state,
                            self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.ReactionSettings(id: message.id.peerId))
                        )
                        |> take(1)
                        |> deliverOnMainQueue).start(next: { [weak self] state, reactionSettings in
                            guard let strongSelf = self, let balance = state?.balance else {
                                return
                            }
                            
                            if case let .known(reactionSettings) = reactionSettings, let starsAllowed = reactionSettings.starsAllowed, !starsAllowed {
                                if let peer = strongSelf.presentationInterfaceState.renderedPeer?.chatMainPeer {
                                    let alertController = textAlertController(
                                        context: strongSelf.context,
                                        title: nil,
                                        text: strongSelf.presentationData.strings.Chat_ToastStarsReactionsDisabled(peer.debugDisplayTitle).string,
                                        actions: [
                                            TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_OK, action: {})
                                        ]
                                    )
                                    strongSelf.present(alertController, in: .window(.root))
                                }
                                return
                            }
                            
                            if balance < StarsAmount(value: 1, nanos: 0) {
                                controller?.dismiss(completion: {
                                    guard let strongSelf = self else {
                                        return
                                    }
                                    
                                    let _ = (strongSelf.context.engine.payments.starsTopUpOptions()
                                    |> take(1)
                                    |> deliverOnMainQueue).startStandalone(next: { [weak strongSelf] options in
                                        guard let strongSelf else {
                                            return
                                        }
                                        guard let starsContext = strongSelf.context.starsContext else {
                                            return
                                        }
                                        
                                        let purchaseScreen = strongSelf.context.sharedContext.makeStarsPurchaseScreen(context: strongSelf.context, starsContext: starsContext, options: options, purpose: .reactions(peerId: message.id.peerId, requiredStars: 1), targetPeerId: nil, customTheme: nil, completion: { result in
                                            let _ = result
                                        })
                                        strongSelf.push(purchaseScreen)
                                    })
                                })
                                
                                return
                            }
                            
                            let _ = (strongSelf.context.engine.messages.sendStarsReaction(id: message.id, count: 1, privacy: nil)
                            |> deliverOnMainQueue).startStandalone(next: { privacy in
                                guard let strongSelf = self else {
                                    return
                                }
                                strongSelf.displayOrUpdateSendStarsUndo(messageId: message.id, count: 1, privacy: privacy)
                            })
                        })
                    } else {
                        let chosenReaction: MessageReaction.Reaction = chosenUpdatedReaction.reaction
                        
                        let currentReactions = mergedMessageReactions(attributes: message.attributes, isTags: message.areReactionsTags(accountPeerId: self.context.account.peerId))?.reactions ?? []
                        var updatedReactions: [MessageReaction.Reaction] = currentReactions.filter(\.isSelected).map(\.value)
                        var removedReaction: MessageReaction.Reaction?
                        var isFirst = false
                        
                        if let index = updatedReactions.firstIndex(where: { $0 == chosenReaction }) {
                            removedReaction = chosenReaction
                            updatedReactions.remove(at: index)
                        } else {
                            updatedReactions.append(chosenReaction)
                            isFirst = !currentReactions.contains(where: { $0.value == chosenReaction })
                        }
                        
                        if removedReaction == nil && !canSendReactionsToChat(self.presentationInterfaceState) {
                            if let controller {
                                controller.dismiss(completion: { [weak self] in
                                    self?.displaySendReactionRestrictedToast()
                                })
                            } else {
                                self.displaySendReactionRestrictedToast()
                            }
                            return
                        }

                        if message.areReactionsTags(accountPeerId: self.context.account.peerId) {
                            if removedReaction == nil, !topReactions.contains(where: { $0.reaction.rawValue == chosenReaction }) {
                                if !self.presentationInterfaceState.isPremium {
                                    controller?.premiumReactionsSelected?()
                                    return
                                }
                            }
                        } else {
                            if removedReaction == nil, case .custom = chosenReaction {
                                if let peer = self.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, case .broadcast = peer.info {
                                } else {
                                    if !self.presentationInterfaceState.isPremium {
                                        controller?.premiumReactionsSelected?()
                                        return
                                    }
                                }
                            }
                        }
                        
                        self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                            if let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item {
                                if item.message.id == message.id {
                                    if removedReaction == nil && !updatedReactions.isEmpty {
                                        itemNode.awaitingAppliedReaction = (chosenReaction, { [weak self, weak itemNode] in
                                            guard let self, let controller = controller else {
                                                return
                                            }
                                            if let itemNode = itemNode, let targetView = itemNode.targetReactionView(value: chosenReaction) {
                                                self.chatDisplayNode.messageTransitionNode.addMessageContextController(messageId: item.message.id, contextController: controller)
                                                
                                                var hideTargetButton: UIView?
                                                if isFirst {
                                                    hideTargetButton = targetView.superview
                                                }
                                                
                                                controller.dismissWithReaction(value: chosenReaction, targetView: targetView, hideNode: true, animateTargetContainer: hideTargetButton, addStandaloneReactionAnimation: { [weak self] standaloneReactionAnimation in
                                                    guard let self else {
                                                        return
                                                    }
                                                    self.chatDisplayNode.messageTransitionNode.addMessageStandaloneReactionAnimation(messageId: item.message.id, standaloneReactionAnimation: standaloneReactionAnimation)
                                                    standaloneReactionAnimation.frame = self.chatDisplayNode.bounds
                                                    self.chatDisplayNode.addSubnode(standaloneReactionAnimation)
                                                }, onHit: nil, completion: { [weak self, weak itemNode, weak targetView] in
                                                    guard let self, let itemNode, let targetView else {
                                                        return
                                                    }
                                                    
                                                    if self.chatLocation.peerId == self.context.account.peerId {
                                                        let _ = (ApplicationSpecificNotice.getSavedMessageTagLabelSuggestion(accountManager: self.context.sharedContext.accountManager)
                                                                 |> take(1)
                                                                 |> deliverOnMainQueue).startStandalone(next: { [weak self, weak targetView, weak itemNode] value in
                                                            guard let self, let targetView, let itemNode else {
                                                                return
                                                            }
                                                            if value >= 3 {
                                                                return
                                                            }
                                                            
                                                            let _ = itemNode
                                                            
                                                            let rect = self.chatDisplayNode.view.convert(targetView.bounds, from: targetView).insetBy(dx: -8.0, dy: -8.0)
                                                            let tooltipScreen = TooltipScreen(account: self.context.account, sharedContext: self.context.sharedContext, text: .plain(text: self.presentationData.strings.Chat_TooltipAddTagLabel), location: .point(rect, .bottom), displayDuration: .manual, shouldDismissOnTouch: { _, _ in
                                                                return .dismiss(consume: false)
                                                            })
                                                            self.present(tooltipScreen, in: .current)
                                                            
                                                            let _ = ApplicationSpecificNotice.incrementSavedMessageTagLabelSuggestion(accountManager: self.context.sharedContext.accountManager).startStandalone()
                                                        })
                                                    }
                                                })
                                            } else {
                                                controller.dismiss()
                                            }
                                        })
                                    } else {
                                        itemNode.awaitingAppliedReaction = (nil, {
                                            controller?.dismiss()
                                        })
                                    }
                                }
                            }
                        }
                        
                        let mappedUpdatedReactions = updatedReactions.map { reaction -> UpdateMessageReaction in
                            switch reaction {
                            case let .builtin(value):
                                return .builtin(value)
                            case let .custom(fileId):
                                var customFile: TelegramMediaFile?
                                if case let .custom(customFileId, file) = chosenUpdatedReaction, fileId == customFileId {
                                    customFile = file
                                }
                                return .custom(fileId: fileId, file: customFile)
                            case .stars:
                                return .stars
                            }
                        }
                        
                        let _ = updateMessageReactionsInteractively(account: self.context.account, messageIds: [message.id], reactions: mappedUpdatedReactions, isLarge: isLarge, storeAsRecentlyUsed: true).startStandalone()
                    }
                }

                self.forEachController({ controller in
                    if let controller = controller as? TooltipScreen {
                        controller.dismiss()
                    }
                    return true
                })
                self.window?.presentInGlobalOverlay(controller)
            })
        }
    }

    private func openAyuSyntheticMessageContextMenu(message: EngineMessage, node: ASDisplayNode, anyRecognizer: UIGestureRecognizer?, location: CGPoint?) {
        guard let interfaceInteraction = self.interfaceInteraction else {
            return
        }
        let rawMessage = message._asMessage()
        var items: [ContextMenuItem] = []
        let canCopyContent = !rawMessage.isCopyProtected() && !self.presentationInterfaceState.copyProtectionEnabled && !self.presentationInterfaceState.myCopyProtectionEnabled
        if !rawMessage.text.isEmpty && canCopyContent {
            items.append(.action(ContextMenuActionItem(text: self.presentationData.strings.Conversation_ContextMenuCopy, icon: { theme in
                generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] controller, _ in
                UIPasteboard.general.string = rawMessage.text
                controller?.dismiss()
                self?.controllerInteraction?.displayUndo(.copy(text: self?.presentationData.strings.Conversation_TextCopied ?? ""))
            })))
        }
        if !rawMessage.text.isEmpty && canCopyContent && self.presentationInterfaceState.interfaceState.editMessage == nil {
            items.append(.action(ContextMenuActionItem(text: self.presentationData.strings.Conversation_ContextMenuReply, icon: { theme in
                generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Reply"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] controller, _ in
                controller?.dismiss()
                self?.ayuInsertSyntheticMessageAsQuote(rawMessage, editable: false)
            })))
            items.append(.action(ContextMenuActionItem(text: "AyuGram.Deleted.ReplyAsQuote".i18n(self.presentationData.strings.baseLanguageCode), icon: { theme in
                generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Reply"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] controller, _ in
                controller?.dismiss()
                self?.ayuInsertSyntheticMessageAsQuote(rawMessage, editable: true)
            })))
        }
        if canCopyContent && (!rawMessage.text.isEmpty || rawMessage.media.contains(where: { $0 is TelegramMediaImage || $0 is TelegramMediaFile })) {
            items.append(.action(ContextMenuActionItem(text: "AyuGram.Deleted.ForwardContent".i18n(self.presentationData.strings.baseLanguageCode), icon: { theme in
                generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Forward"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] controller, _ in
                controller?.dismiss()
                self?.ayuForwardSyntheticMessageContent(rawMessage)
            })))
        }
        items.append(.action(ContextMenuActionItem(text: self.presentationData.strings.Conversation_ContextMenuSelect, icon: { theme in
            generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Select"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            interfaceInteraction.beginMessageSelection([rawMessage.id], { transition in
                f(.custom(transition))
            })
        })))
        items.append(.separator)
        items.append(.action(ContextMenuActionItem(text: self.presentationData.strings.Conversation_ContextMenuDelete, textColor: .destructive, icon: { theme in
            generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.actionSheet.destructiveActionTextColor)
        }, action: { controller, f in
            interfaceInteraction.deleteMessages([rawMessage], controller, f)
        })))

        // An extracted source observes its MessageId through Postbox and would
        // immediately dismiss for this in-memory-only message. Anchor the menu
        // to the gesture (or the bubble center) without extracting the bubble.
        let anchor = location ?? CGPoint(x: node.bounds.midX, y: node.bounds.midY)
        let source: ContextContentSource = .location(ChatMessageContextLocationContentSource(controller: self, location: node.view.convert(anchor, to: nil)))
        self.canReadHistory.set(false)
        let controller = makeContextController(presentationData: self.presentationData, source: source, items: .single(ContextController.Items(content: .list(items))), recognizer: anyRecognizer as? TapLongTapOrDoubleTapGestureRecognizer, gesture: anyRecognizer as? ContextGesture, disableScreenshots: self.presentationInterfaceState.copyProtectionEnabled || self.presentationInterfaceState.myCopyProtectionEnabled || self.chatLocation.peerId?.namespace == Namespaces.Peer.SecretChat, hideReactionPanelTail: true)
        controller.dismissed = { [weak self] in self?.canReadHistory.set(true) }
        self.currentContextController = controller
        self.window?.presentInGlobalOverlay(controller)
    }

    private func ayuInsertSyntheticMessageAsQuote(_ message: EngineRawMessage, editable: Bool) {
        guard self.presentationInterfaceState.interfaceState.editMessage == nil,
              !message.isCopyProtected(),
              !self.presentationInterfaceState.copyProtectionEnabled,
              !self.presentationInterfaceState.myCopyProtectionEnabled else {
            return
        }
        let entities = editable ? ayuSafeSyntheticTextEntities(message) : []
        let appliedText = chatInputStateStringWithAppliedEntities(message.text, entities: entities)
        guard appliedText.length != 0 else {
            return
        }
        let quotedText = NSMutableAttributedString(attributedString: appliedText)
        quotedText.addAttribute(ChatTextInputAttributes.block, value: ChatTextInputTextQuoteAttribute(kind: .quote, isCollapsed: false), range: NSRange(location: 0, length: quotedText.length))

        self.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
            let existingText = state.interfaceState.composeInputState.inputText
            let result = NSMutableAttributedString(attributedString: quotedText)
            if result.length != 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            result.append(existingText)
            return state.updatedInputMode({ _ in .text }).updatedInterfaceState({ interfaceState in
                interfaceState
                    .withUpdatedReplyMessageSubject(nil)
                    .withUpdatedForwardMessageIds(nil)
                    .withUpdatedForwardOptionsState(nil)
                    .withUpdatedComposeInputState(ChatTextInputState(inputText: result, selectionRange: result.length ..< result.length))
            })
        })
        if !self.chatDisplayNode.ensureInputViewFocused() {
            DispatchQueue.main.async { [weak self] in
                let _ = self?.chatDisplayNode.ensureInputViewFocused()
            }
        }
    }

    private func ayuForwardSyntheticMessageContent(_ message: EngineRawMessage) {
        guard !message.isCopyProtected(),
              !self.presentationInterfaceState.copyProtectionEnabled,
              !self.presentationInterfaceState.myCopyProtectionEnabled else {
            return
        }
        let supportedMedia = message.media.compactMap { media -> Media? in
            if media is TelegramMediaImage || media is TelegramMediaFile {
                return media
            }
            return nil
        }
        let omittedCount = message.media.count - supportedMedia.count
        guard !message.text.isEmpty || !supportedMedia.isEmpty else {
            self.present(textAlertController(context: self.context, title: nil, text: "AyuGram.Deleted.ContentUnavailable".i18n(self.presentationData.strings.baseLanguageCode), actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
            return
        }

        let openPicker: () -> Void = { [weak self] in
            guard let self else {
                return
            }
            let filter: ChatListNodePeersFilter = [.onlyWriteable, .excludeDisabled, .doNotSearchMessages]
            let controller = self.context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: self.context, updatedPresentationData: self.updatedPresentationData, filter: filter, hasFilters: true, title: "AyuGram.Deleted.ForwardContentPicker".i18n(self.presentationData.strings.baseLanguageCode), multipleSelection: false, selectForumThreads: true))
            var didSelectDestination = false
            controller.peerSelected = { [weak self, weak controller] peer, threadId in
                guard let self, !didSelectDestination else {
                    return
                }
                didSelectDestination = true
                var outgoing: [EnqueueMessage] = []
                if !message.text.isEmpty {
                    let entities = ayuSafeSyntheticTextEntities(message)
                    let inputText = chatInputStateStringWithAppliedEntities(message.text, entities: entities)
                    for textPart in breakChatInputText(inputText) where textPart.length != 0 {
                        let partEntities = generateChatInputTextEntities(textPart)
                        let attributes: [EngineMessage.Attribute] = partEntities.isEmpty ? [] : [TextEntitiesMessageAttribute(entities: partEntities)]
                        outgoing.append(.message(text: textPart.string, attributes: attributes, inlineStickers: [:], mediaReference: nil, threadId: threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
                    }
                }
                for media in supportedMedia {
                    outgoing.append(.message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: media), threadId: threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
                }
                guard !outgoing.isEmpty else {
                    return
                }
                let _ = (self.context.engine.data.get(
                    TelegramEngine.EngineData.Item.Peer.SendPaidMessageStars(id: peer.id),
                    TelegramEngine.EngineData.Item.Peer.RenderedPeer(id: peer.id)
                )
                |> deliverOnMainQueue).startStandalone(next: { [weak self, weak controller] sendPaidMessageStars, renderedPeer in
                    guard let self else {
                        return
                    }
                    let proceed: (StarsAmount?) -> Void = { [weak self, weak controller] paidAmount in
                        guard let self else {
                            return
                        }
                        var outgoing = outgoing
                        if let paidAmount {
                            outgoing = outgoing.map { message in
                                message.withUpdatedAttributes { attributes in
                                    var attributes = attributes
                                    attributes.removeAll(where: { $0 is PaidStarsMessageAttribute })
                                    attributes.append(PaidStarsMessageAttribute(stars: paidAmount, postponeSending: false))
                                    return attributes
                                }
                            }
                        }
                        controller?.dismiss()
                        let expectedCount = outgoing.count
                        let _ = (enqueueMessages(account: self.context.account, peerId: peer.id, messages: outgoing)
                        |> deliverOnMainQueue).startStandalone(next: { [weak self] messageIds in
                            guard let self else {
                                return
                            }
                            guard messageIds.count == expectedCount, messageIds.allSatisfy({ $0 != nil }) else {
                                self.present(textAlertController(context: self.context, title: nil, text: self.presentationData.strings.Login_UnknownError, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                                return
                            }
                            self.present(UndoOverlayController(presentationData: self.presentationData, content: .succeed(text: "AyuGram.Deleted.ContentSent".i18n(self.presentationData.strings.baseLanguageCode), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in false }), in: .current)
                        })
                    }
                    if let sendPaidMessageStars, let renderedPeer {
                        let paymentController = chatMessagePaymentAlertController(
                            context: nil,
                            presentationData: self.presentationData,
                            updatedPresentationData: nil,
                            peers: [renderedPeer],
                            count: Int32(outgoing.count),
                            amount: sendPaidMessageStars,
                            totalAmount: nil,
                            hasCheck: false,
                            navigationController: self.navigationController as? NavigationController,
                            completion: { _ in
                                proceed(sendPaidMessageStars)
                            }
                        )
                        self.present(paymentController, in: .window(.root))
                    } else {
                        proceed(nil)
                    }
                })
            }
            self.push(controller)
        }

        if omittedCount != 0 {
            self.present(textAlertController(context: self.context, title: nil, text: "AyuGram.Deleted.UnsupportedMediaOmitted".i18n(self.presentationData.strings.baseLanguageCode), actions: [
                TextAlertAction(type: .genericAction, title: self.presentationData.strings.Common_Cancel, action: {}),
                TextAlertAction(type: .defaultAction, title: "AyuGram.Deleted.ContinueContentCopy".i18n(self.presentationData.strings.baseLanguageCode), action: openPicker)
            ]), in: .window(.root))
        } else {
            openPicker()
        }
    }
}

private func ayuSafeSyntheticTextEntities(_ message: EngineRawMessage) -> [MessageTextEntity] {
    let textLength = (message.text as NSString).length
    let source = (message.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
    return source.compactMap { entity in
        guard entity.range.lowerBound >= 0, entity.range.upperBound <= textLength, !entity.range.isEmpty else {
            return nil
        }
        switch entity.type {
        case .Bold, .Italic, .Code, .Pre, .Strikethrough, .BlockQuote, .Underline, .Spoiler, .FormattedDate:
            return entity
        case .Url:
            let range = NSRange(location: entity.range.lowerBound, length: entity.range.count)
            guard ayuIsSafeSyntheticUrl((message.text as NSString).substring(with: range)) else {
                return nil
            }
            return entity
        case let .TextUrl(url):
            guard ayuIsSafeSyntheticUrl(url) else {
                return nil
            }
            return entity
        case .Unknown, .Mention, .Hashtag, .BotCommand, .Email, .PhoneNumber, .BankCard, .TextMention, .CustomEmoji, .Custom:
            return nil
        }
    }
}

private func ayuIsSafeSyntheticUrl(_ value: String) -> Bool {
    guard !value.isEmpty,
          value.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
          let components = URLComponents(string: value),
          let scheme = components.scheme?.lowercased() else {
        return false
    }
    switch scheme {
    case "http", "https":
        return components.host?.isEmpty == false
    case "tg":
        return components.host?.isEmpty == false || !components.path.isEmpty
    default:
        return false
    }
}

final class ChatContextControllerContentSourceImpl: ContextControllerContentSource {
    let controller: ViewController
    weak var sourceNode: ASDisplayNode?
    weak var sourceView: UIView?
    let sourceRect: CGRect?
    
    let navigationController: NavigationController? = nil

    let passthroughTouches: Bool
    
    init(controller: ViewController, sourceNode: ASDisplayNode?, sourceRect: CGRect? = nil, passthroughTouches: Bool) {
        self.controller = controller
        self.sourceNode = sourceNode
        self.sourceRect = sourceRect
        self.passthroughTouches = passthroughTouches
    }
    
    init(controller: ViewController, sourceView: UIView?, sourceRect: CGRect? = nil, passthroughTouches: Bool) {
        self.controller = controller
        self.sourceView = sourceView
        self.sourceRect = sourceRect
        self.passthroughTouches = passthroughTouches
    }
    
    func transitionInfo() -> ContextControllerTakeControllerInfo? {
        let sourceView = self.sourceView
        let sourceNode = self.sourceNode
        let sourceRect = self.sourceRect
        return ContextControllerTakeControllerInfo(contentAreaInScreenSpace: CGRect(origin: CGPoint(), size: CGSize(width: 10.0, height: 10.0)), sourceNode: { [weak sourceNode] in
            if let sourceView = sourceView {
                return (sourceView, sourceRect ?? sourceView.bounds)
            } else if let sourceNode = sourceNode {
                return (sourceNode.view, sourceRect ?? sourceNode.bounds)
            } else {
                return nil
            }
        })
    }
    
    func animatedIn() {
    }
}

final class ChatControllerContextReferenceContentSource: ContextReferenceContentSource {
    let controller: ViewController
    let sourceView: UIView
    let insets: UIEdgeInsets
    let contentInsets: UIEdgeInsets
    let actionsOnTop: Bool
    
    init(controller: ViewController, sourceView: UIView, insets: UIEdgeInsets, contentInsets: UIEdgeInsets = UIEdgeInsets(), actionsOnTop: Bool = false) {
        self.controller = controller
        self.sourceView = sourceView
        self.insets = insets
        self.contentInsets = contentInsets
        self.actionsOnTop = actionsOnTop
    }
    
    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView, contentAreaInScreenSpace: UIScreen.main.bounds.inset(by: self.insets), insets: self.contentInsets, actionsPosition: self.actionsOnTop ? .top : .bottom)
    }
}
