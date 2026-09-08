import Foundation
import UIKit
import ComponentFlow
import AccountContext
import SGStrings

/// A compact, independent row of project-issued peer badges.
///
/// Telegram credibility, verification, and emoji-status indicators are owned by
/// their surrounding surface. This component intentionally knows nothing about
/// those slots and only lays out the project descriptors it receives.
public final class ProjectBadgeStripComponent: Component {
    public typealias EnvironmentType = Empty

    public enum Density: Equatable {
        case compact
        case profile

        fileprivate var itemSize: CGSize {
            switch self {
            case .compact:
                return CGSize(width: 20.0, height: 20.0)
            case .profile:
                return CGSize(width: 24.0, height: 24.0)
            }
        }
    }

    public let context: AccountContext
    public let badges: [AyuBadgeContent]
    public let languageCode: String
    public let peerName: String
    public let placeholderColor: UIColor
    public let accentColor: UIColor
    public let foregroundColor: UIColor
    public let density: Density
    public let isVisibleForAnimations: Bool
    public let isInteractive: Bool
    public let badgeAction: ((AyuBadgeContent) -> Void)?
    public let overflowAction: (([AyuBadgeContent]) -> Void)?

    public init(
        context: AccountContext,
        badges: [AyuBadgeContent],
        languageCode: String,
        peerName: String,
        placeholderColor: UIColor,
        accentColor: UIColor,
        foregroundColor: UIColor,
        density: Density = .compact,
        isVisibleForAnimations: Bool,
        isInteractive: Bool,
        badgeAction: ((AyuBadgeContent) -> Void)?,
        overflowAction: (([AyuBadgeContent]) -> Void)?
    ) {
        self.context = context
        self.badges = badges
        self.languageCode = languageCode
        self.peerName = peerName
        self.placeholderColor = placeholderColor
        self.accentColor = accentColor
        self.foregroundColor = foregroundColor
        self.density = density
        self.isVisibleForAnimations = isVisibleForAnimations
        self.isInteractive = isInteractive
        self.badgeAction = badgeAction
        self.overflowAction = overflowAction
    }

    public static func == (lhs: ProjectBadgeStripComponent, rhs: ProjectBadgeStripComponent) -> Bool {
        return lhs.context === rhs.context
            && lhs.badges == rhs.badges
            && lhs.languageCode == rhs.languageCode
            && lhs.peerName == rhs.peerName
            && lhs.placeholderColor == rhs.placeholderColor
            && lhs.accentColor == rhs.accentColor
            && lhs.foregroundColor == rhs.foregroundColor
            && lhs.density == rhs.density
            && lhs.isVisibleForAnimations == rhs.isVisibleForAnimations
            && lhs.isInteractive == rhs.isInteractive
    }

    public final class View: UIView {
        private static let itemSpacing: CGFloat = 2.0

        private var iconViews: [AyuBadgeContent.Id: ComponentView<Empty>] = [:]
        private var actionButtons: [AyuBadgeContent.Id: UIButton] = [:]
        private let overflowButton: UIButton
        private var component: ProjectBadgeStripComponent?
        private var hiddenBadges: [AyuBadgeContent] = []

        override init(frame: CGRect) {
            self.overflowButton = UIButton(type: .system)
            super.init(frame: frame)

            self.clipsToBounds = true
            self.overflowButton.accessibilityTraits = .button
            self.overflowButton.addTarget(self, action: #selector(self.overflowPressed), for: .touchUpInside)
            self.addSubview(self.overflowButton)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func badgePressed(_ sender: UIButton) {
            guard let component = self.component, sender.tag >= 0, sender.tag < component.badges.count else {
                return
            }
            component.badgeAction?(component.badges[sender.tag])
        }

        @objc private func overflowPressed() {
            guard !self.hiddenBadges.isEmpty else { return }
            // Keep the destination stable as the title's available width
            // changes: overflow always opens the complete badge collection.
            self.component?.overflowAction?(self.component?.badges ?? [])
        }

        fileprivate func update(
            component: ProjectBadgeStripComponent,
            availableSize: CGSize,
            state: EmptyComponentState,
            transition: ComponentTransition
        ) -> CGSize {
            self.component = component
            // A display-only strip must not become the hit-test result; taps
            // should continue to the enclosing title or chat-list row.
            self.isUserInteractionEnabled = component.isInteractive

            let badges = component.badges
            let itemSize = component.density.itemSize
            let overflowWidth = itemSize.width + 8.0
            let fullItemWidth = itemSize.width + View.itemSpacing
            let fullWidth = badges.isEmpty ? 0.0 : CGFloat(badges.count) * fullItemWidth - View.itemSpacing
            let visibleCount: Int
            if fullWidth <= availableSize.width {
                visibleCount = badges.count
            } else if !component.isInteractive {
                // Display-only surfaces must not imply that hidden badges can be
                // opened. Render only the bounded prefix that actually fits.
                visibleCount = max(0, min(badges.count, Int((availableSize.width + View.itemSpacing) / fullItemWidth)))
            } else if availableSize.width < itemSize.width + overflowWidth + View.itemSpacing {
                visibleCount = 0
            } else {
                visibleCount = max(0, min(badges.count - 1, Int((availableSize.width - overflowWidth + View.itemSpacing) / fullItemWidth)))
            }
            self.hiddenBadges = Array(badges.dropFirst(visibleCount))

            var validIds = Set<AyuBadgeContent.Id>()
            var x: CGFloat = 0.0
            for index in 0 ..< visibleCount {
                let badge = badges[index]
                validIds.insert(badge.id)

                if index != 0 {
                    x += View.itemSpacing
                }

                let iconView: ComponentView<Empty>
                if let current = self.iconViews[badge.id] {
                    iconView = current
                } else {
                    iconView = ComponentView()
                    iconView.parentState = state
                    self.iconViews[badge.id] = iconView
                }

                let content: EmojiStatusComponent.Content
                if let fileId = badge.customEmojiFileId {
                    // EmojiStatusComponent only applies themeColor to template
                    // emoji (and its known template packs). A nil value
                    // therefore preserves the source animation's original
                    // fixed white/color rendering.
                    //
                    // Issuer-assigned ReqGram roles are template artwork, so
                    // they are rendered white to match the surrounding white
                    // project marks. `itemCheckColors.foregroundColor` cannot
                    // be reused here: it is a checkbox contrast color that is
                    // black in the default dark theme. Custom badges are
                    // peer-chosen artwork and must keep their own colors.
                    var themeColor: UIColor?
                    if badge.issuer == .reqGram {
                        if case .custom = badge.kind {
                            themeColor = nil
                        } else {
                            themeColor = .white
                        }
                    }
                    content = .animation(
                        content: .customEmoji(fileId: fileId),
                        size: itemSize,
                        placeholderColor: component.placeholderColor,
                        themeColor: themeColor,
                        loopMode: .count(2)
                    )
                } else {
                    // Project assertions must never borrow Telegram's verified
                    // or Premium glyphs. Preserve issuer identity on fallback.
                    content = .text(color: component.accentColor, string: badge.issuer.fallbackGlyph)
                }

                let iconSize = iconView.update(
                    transition: transition,
                    component: AnyComponent(EmojiStatusComponent(
                        context: component.context,
                        animationCache: component.context.animationCache,
                        animationRenderer: component.context.animationRenderer,
                        content: content,
                        size: itemSize,
                        isVisibleForAnimations: component.isVisibleForAnimations,
                        action: nil
                    )),
                    environment: {},
                    containerSize: itemSize
                )
                if let view = iconView.view {
                    if view.superview == nil {
                        view.isUserInteractionEnabled = false
                        self.addSubview(view)
                    }
                    transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: x, y: 0.0), size: iconSize))
                }

                if component.isInteractive {
                    let button: UIButton
                    if let current = self.actionButtons[badge.id] {
                        button = current
                    } else {
                        button = UIButton(type: .custom)
                        button.addTarget(self, action: #selector(self.badgePressed(_:)), for: .touchUpInside)
                        self.actionButtons[badge.id] = button
                        self.addSubview(button)
                    }
                    button.tag = index
                    button.isUserInteractionEnabled = true
                    button.isAccessibilityElement = true
                    let explanation = AyuBadges.explanation(for: badge, peerName: component.peerName, languageCode: component.languageCode)
                    button.accessibilityTraits = .button
                    button.accessibilityLabel = "\(badge.issuer.displayName(languageCode: component.languageCode)), \(explanation.title)"
                    button.accessibilityHint = explanation.text
                    transition.setFrame(view: button, frame: CGRect(x: x, y: 0.0, width: itemSize.width, height: itemSize.height))
                }
                x += itemSize.width
            }

            let removedIconIds = self.iconViews.keys.filter { !validIds.contains($0) }
            for id in removedIconIds {
                self.iconViews[id]?.view?.removeFromSuperview()
                self.iconViews.removeValue(forKey: id)
            }
            let removedButtonIds = self.actionButtons.keys.filter { !validIds.contains($0) }
            for id in removedButtonIds {
                self.actionButtons[id]?.removeFromSuperview()
                self.actionButtons.removeValue(forKey: id)
            }

            if component.isInteractive && !self.hiddenBadges.isEmpty {
                if x > 0.0 {
                    x += View.itemSpacing
                }
                self.overflowButton.isHidden = false
                self.overflowButton.isUserInteractionEnabled = component.isInteractive
                self.overflowButton.isAccessibilityElement = component.isInteractive
                let overflowButtonWidth = min(overflowWidth, max(0.0, availableSize.width - x))
                self.overflowButton.titleLabel?.font = UIFont.systemFont(ofSize: component.density == .profile ? 12.0 : 11.0, weight: .semibold)
                self.overflowButton.layer.cornerRadius = itemSize.height / 2.0
                self.overflowButton.setTitle(overflowButtonWidth >= overflowWidth ? "+\(self.hiddenBadges.count)" : "…", for: .normal)
                self.overflowButton.setTitleColor(component.accentColor, for: .normal)
                self.overflowButton.backgroundColor = component.accentColor.withAlphaComponent(0.12)
                self.overflowButton.accessibilityLabel = String(format: i18n("AyuGram.RemoteConfig.Badges.ShowAll", component.languageCode), badges.count)
                self.overflowButton.accessibilityValue = String(format: i18n("AyuGram.RemoteConfig.Badges.More", component.languageCode), self.hiddenBadges.count)
                transition.setFrame(view: self.overflowButton, frame: CGRect(x: x, y: 0.0, width: overflowButtonWidth, height: itemSize.height))
                x += overflowButtonWidth
            } else {
                self.overflowButton.isHidden = true
            }

            return CGSize(width: min(availableSize.width, x), height: badges.isEmpty ? 0.0 : itemSize.height)
        }

    }

    public func makeView() -> View {
        return View(frame: CGRect())
    }

    public func update(
        view: View,
        availableSize: CGSize,
        state: EmptyComponentState,
        environment: Environment<Empty>,
        transition: ComponentTransition
    ) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, transition: transition)
    }
}
