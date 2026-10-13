import Foundation
import UIKit
import ComponentFlow
import AccountContext
import AlertComponent
import SGStrings

/// One native card factory for profile, title and chat-list project badges.
public enum ProjectBadgeInfoController {
    public static func presentBadge(context: AccountContext, badge: AyuBadgeContent, peerName: String, languageCode: String) {
        let explanation = AyuBadges.explanation(for: badge, peerName: peerName, languageCode: languageCode)
        let content: [AnyComponentWithIdentity<AlertComponentEnvironment>] = [
            AnyComponentWithIdentity(id: "hero", component: AnyComponent(ProjectBadgeAlertHeroComponent(context: context, badge: badge, languageCode: languageCode))),
            AnyComponentWithIdentity(id: "title", component: AnyComponent(AlertTitleComponent(title: explanation.title))),
            AnyComponentWithIdentity(id: "issuer", component: AnyComponent(AlertTextComponent(content: .plain(badge.issuer.displayName(languageCode: languageCode))))),
            AnyComponentWithIdentity(id: "text", component: AnyComponent(AlertTextComponent(content: .plain(explanation.text))))
        ]
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        context.sharedContext.presentGlobalController(AlertScreen(context: context, content: content, actions: [
            .init(title: presentationData.strings.Common_OK)
        ]), nil)
    }

    /// Overflow deliberately lists the complete collection. Users retain the
    /// context of the visible prefix and can inspect all badge provenance.
    public static func presentAll(context: AccountContext, badges: [AyuBadgeContent], peerName: String, languageCode: String) {
        guard !badges.isEmpty else { return }
        var content: [AnyComponentWithIdentity<AlertComponentEnvironment>] = [
            AnyComponentWithIdentity(id: "title", component: AnyComponent(AlertTitleComponent(title: i18n("AyuGram.RemoteConfig.Badges.Title", languageCode))))
        ]
        for (index, badge) in badges.enumerated() {
            let explanation = AyuBadges.explanation(for: badge, peerName: peerName, languageCode: languageCode)
            content.append(AnyComponentWithIdentity(
                id: "badge-\(index)",
                component: AnyComponent(AlertTextComponent(content: .plain("\(badge.issuer.displayName(languageCode: languageCode)) — \(explanation.title)\n\(explanation.text)")))
            ))
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        context.sharedContext.presentGlobalController(AlertScreen(
            context: context,
            configuration: .init(actionAlignment: .vertical),
            content: content,
            actions: [.init(title: presentationData.strings.Common_Close)]
        ), nil)
    }
}

private final class ProjectBadgeAlertHeroComponent: Component {
    typealias EnvironmentType = AlertComponentEnvironment
    let context: AccountContext
    let badge: AyuBadgeContent
    let languageCode: String

    init(context: AccountContext, badge: AyuBadgeContent, languageCode: String) {
        self.context = context
        self.badge = badge
        self.languageCode = languageCode
    }

    static func == (lhs: ProjectBadgeAlertHeroComponent, rhs: ProjectBadgeAlertHeroComponent) -> Bool {
        return lhs.context === rhs.context && lhs.badge == rhs.badge && lhs.languageCode == rhs.languageCode
    }

    final class View: UIView {
        private let icon = ComponentView<Empty>()

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.clipsToBounds = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(component: ProjectBadgeAlertHeroComponent, availableSize: CGSize, transition: ComponentTransition) -> CGSize {
            let iconSize = CGSize(width: 72.0, height: 72.0)
            let content: EmojiStatusComponent.Content
            if let fileId = component.badge.customEmojiFileId {
                content = .animation(content: .customEmoji(fileId: fileId), size: iconSize, placeholderColor: UIColor(white: 0.5, alpha: 0.2), themeColor: nil, loopMode: .count(2))
            } else {
                content = .text(color: .systemBlue, string: component.badge.issuer.fallbackGlyph)
            }
            let size = self.icon.update(
                transition: transition,
                component: AnyComponent(EmojiStatusComponent(context: component.context, animationCache: component.context.animationCache, animationRenderer: component.context.animationRenderer, content: content, size: iconSize, isVisibleForAnimations: true, action: nil)),
                environment: {},
                containerSize: iconSize
            )
            if let view = self.icon.view {
                if view.superview == nil {
                    view.isUserInteractionEnabled = false
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(x: floor((availableSize.width - size.width) * 0.5), y: 4.0, width: size.width, height: size.height))
            }
            self.isAccessibilityElement = true
            self.accessibilityLabel = SGLocalizationManager.shared.localizedString("AyuGram.RemoteConfig.Badge.HeroAccessibility", component.languageCode, args: component.badge.issuer.displayName(languageCode: component.languageCode))
            return CGSize(width: availableSize.width, height: 80.0)
        }
    }

    func makeView() -> View { return View(frame: .zero) }
    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<AlertComponentEnvironment>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, transition: transition)
    }
}
