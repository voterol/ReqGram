import Foundation
import UIKit
import Display
import ComponentFlow
import TelegramPresentationData
import ComponentDisplayAdapters
import SGStrings

public final class SGScamWarningBannerComponent: Component {
    public let theme: PresentationTheme
    public let languageCode: String

    public init(theme: PresentationTheme, languageCode: String) {
        self.theme = theme
        self.languageCode = languageCode
    }

    public static func == (lhs: SGScamWarningBannerComponent, rhs: SGScamWarningBannerComponent) -> Bool {
        return lhs.theme === rhs.theme && lhs.languageCode == rhs.languageCode
    }

    public final class View: UIView {
        private let titleLabel = UILabel()
        private let sourceLabel = UILabel()
        private let iconView = UIImageView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.layer.cornerRadius = 8.0
            self.clipsToBounds = true
            self.layer.borderWidth = 1.0

            self.titleLabel.font = Font.semibold(14.0)
            self.titleLabel.numberOfLines = 0
            self.sourceLabel.font = Font.regular(12.0)
            self.sourceLabel.numberOfLines = 0
            self.iconView.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withRenderingMode(.alwaysTemplate)
            self.iconView.contentMode = .scaleAspectFit

            self.addSubview(self.iconView)
            self.addSubview(self.titleLabel)
            self.addSubview(self.sourceLabel)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(component: SGScamWarningBannerComponent, availableSize: CGSize, state: EmptyComponentState, transition: ComponentTransition) -> CGSize {
            let warningColor = component.theme.list.itemDestructiveColor
            self.backgroundColor = warningColor.withMultipliedAlpha(0.12)
            self.layer.borderColor = warningColor.withMultipliedAlpha(0.28).cgColor
            self.iconView.tintColor = warningColor
            self.titleLabel.textColor = warningColor
            self.sourceLabel.textColor = component.theme.list.itemSecondaryTextColor
            self.titleLabel.text = "SG.ScamWarning.Title".i18n(component.languageCode)
            self.sourceLabel.text = "SG.ScamWarning.Source".i18n(component.languageCode)

            let inset: CGFloat = 12.0
            let textX = inset + 20.0 + 8.0
            let textWidth = max(0.0, availableSize.width - textX - inset)
            let titleSize = self.titleLabel.sizeThatFits(CGSize(width: textWidth, height: 1000.0))
            let sourceSize = self.sourceLabel.sizeThatFits(CGSize(width: textWidth, height: 1000.0))
            let height = inset + titleSize.height + 2.0 + sourceSize.height + inset
            let size = CGSize(width: availableSize.width, height: height)
            transition.setFrame(view: self.iconView, frame: CGRect(x: inset, y: inset + 1.0, width: 20.0, height: 20.0))
            transition.setFrame(view: self.titleLabel, frame: CGRect(x: textX, y: inset, width: textWidth, height: titleSize.height))
            transition.setFrame(view: self.sourceLabel, frame: CGRect(x: textX, y: inset + titleSize.height + 2.0, width: textWidth, height: sourceSize.height))
            return size
        }
    }

    public func makeView() -> View {
        return View(frame: CGRect())
    }

    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, transition: transition)
    }
}
