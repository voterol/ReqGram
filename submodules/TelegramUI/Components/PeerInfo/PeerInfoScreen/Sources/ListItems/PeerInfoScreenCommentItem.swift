import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import TextFormat
import Markdown
import AccountContext
import TextNodeWithEntities
import TextFormat

final class PeerInfoScreenCommentItem: PeerInfoScreenItem {
    enum Icon {
        case managedBot
        case warning
    }
    
    enum LinkAction {
        case tap(String)
    }
    
    let id: AnyHashable
    let icon: Icon?
    let text: String
    let attributedPrefix: NSAttributedString?
    let useAccentLinkColor: Bool
    let isWarning: Bool
    let linkAction: ((LinkAction) -> Void)?
    
    init(id: AnyHashable, icon: Icon? = nil, text: String, attributedPrefix: NSAttributedString? = nil, useAccentLinkColor: Bool = true, isWarning: Bool = false, linkAction: ((LinkAction) -> Void)? = nil) {
        self.id = id
        self.icon = icon
        self.text = text
        self.attributedPrefix = attributedPrefix
        self.useAccentLinkColor = useAccentLinkColor
        self.isWarning = isWarning
        self.linkAction = linkAction
    }
    
    func node() -> PeerInfoScreenItemNode {
        return PeerInfoScreenCommentItemNode()
    }
}

private final class PeerInfoScreenCommentItemNode: PeerInfoScreenItemNode {
    private let warningBackgroundNode: ASDisplayNode
    private var iconView: UIImageView?
    private let textNode: ImmediateTextNodeWithEntities
    private var linkHighlightingNode: LinkHighlightingNode?
    private let activateArea: AccessibilityAreaNode
    
    private var item: PeerInfoScreenCommentItem?
    private var presentationData: PresentationData?
    
    private var chevronImage: UIImage?
    
    override init() {
        self.warningBackgroundNode = ASDisplayNode()
        self.textNode = ImmediateTextNodeWithEntities()
        self.textNode.displaysAsynchronously = false
        self.textNode.isUserInteractionEnabled = false
        
        self.activateArea = AccessibilityAreaNode()
        self.activateArea.accessibilityTraits = .staticText
        
        super.init()
        
        self.warningBackgroundNode.isLayerBacked = true
        self.warningBackgroundNode.clipsToBounds = true
        self.addSubnode(self.warningBackgroundNode)
        self.addSubnode(self.textNode)
        self.addSubnode(self.activateArea)
    }
    
    override func didLoad() {
        super.didLoad()
        
        let recognizer = TapLongTapOrDoubleTapGestureRecognizer(target: self, action: #selector(self.tapLongTapOrDoubleTapGesture(_:)))
        recognizer.tapActionAtPoint = { _ in
            return .waitForSingleTap
        }
        recognizer.highlight = { [weak self] point in
            if let strongSelf = self {
                strongSelf.updateTouchesAtPoint(point)
            }
        }
        self.view.addGestureRecognizer(recognizer)
    }
    
    override func update(context: AccountContext, width: CGFloat, safeInsets: UIEdgeInsets, presentationData: PresentationData, item: PeerInfoScreenItem, topItem: PeerInfoScreenItem?, bottomItem: PeerInfoScreenItem?, hasCorners: Bool, transition: ContainedViewLayoutTransition) -> CGFloat {
        guard let item = item as? PeerInfoScreenCommentItem else {
            return 10.0
        }
        
        let themeUpdated = self.presentationData?.theme !== presentationData.theme
        self.item = item
        self.presentationData = presentationData
        self.backgroundColor = nil
        
        let cardInset: CGFloat = item.isWarning ? 12.0 : 0.0
        let cardVerticalInset: CGFloat = item.isWarning ? 6.0 : 0.0
        let sideInset: CGFloat = 16.0 + safeInsets.left + cardInset
        let verticalInset: CGFloat = 7.0 + cardVerticalInset
        
        self.textNode.maximumNumberOfLines = 0
        self.textNode.arguments = TextNodeWithEntities.Arguments(
            context: context,
            cache: context.animationCache,
            renderer: context.animationRenderer,
            placeholderColor: presentationData.theme.list.mediaPlaceholderColor,
            attemptSynchronous: false
        )
        
        let textFont = Font.regular(presentationData.listsFontSize.itemListBaseHeaderFontSize)
        let textColor = item.isWarning ? presentationData.theme.list.itemDestructiveColor : presentationData.theme.list.freeTextColor

        if item.isWarning {
            self.warningBackgroundNode.backgroundColor = presentationData.theme.list.itemDestructiveColor.withMultipliedAlpha(0.10)
            self.warningBackgroundNode.borderColor = presentationData.theme.list.itemDestructiveColor.withMultipliedAlpha(0.26).cgColor
            self.warningBackgroundNode.borderWidth = 1.0
            self.warningBackgroundNode.cornerRadius = 10.0
        } else {
            self.warningBackgroundNode.backgroundColor = nil
            self.warningBackgroundNode.borderWidth = 0.0
        }
        
        var text = item.text
        text = text.replacingOccurrences(of: " >]", with: "\u{00A0}>]")
        
        let attributedText = parseMarkdownIntoAttributedString(text, attributes: MarkdownAttributes(body: MarkdownAttributeSet(font: textFont, textColor: textColor), bold: MarkdownAttributeSet(font: textFont, textColor: textColor), link: MarkdownAttributeSet(font: textFont, textColor: item.useAccentLinkColor ? presentationData.theme.list.itemAccentColor : textColor, additionalAttributes: item.useAccentLinkColor ? [:] : [NSAttributedString.Key.underlineStyle.rawValue: NSUnderlineStyle.single.rawValue as NSNumber]), linkAttribute: { contents in
            return (TelegramTextAttributes.URL, contents)
        })).mutableCopy() as! NSMutableAttributedString
        
        if let attributedPrefix = item.attributedPrefix {
            attributedText.insert(attributedPrefix, at: 0)
            attributedText.addAttribute(NSAttributedString.Key.font, value: textFont, range: NSRange(location: 0, length: attributedPrefix.length))
            attributedText.addAttribute(NSAttributedString.Key.foregroundColor, value: textColor, range: NSRange(location: 0, length: attributedPrefix.length))
        }
        
        if let _ = item.text.range(of: ">]"), let range = attributedText.string.range(of: ">") {
            if themeUpdated || self.chevronImage == nil {
                self.chevronImage = generateTintedImage(image: UIImage(bundleImageName: "Contact List/SubtitleArrow"), color: presentationData.theme.list.itemAccentColor)
            }
            if let chevronImage = self.chevronImage {
                attributedText.addAttribute(.attachment, value: chevronImage, range: NSRange(range, in: attributedText.string))
            }
        }

        self.textNode.attributedText = attributedText
        self.textNode.visibility = true
        self.textNode.lineSpacing = 0.12
        self.activateArea.accessibilityLabel = attributedText.string
        
        var leftTextInset: CGFloat = 0.0
        if let icon = item.icon {
            leftTextInset += 18.0
            
            let iconView: UIImageView
            if let current = self.iconView {
                iconView = current
            } else {
                iconView = UIImageView()
                self.iconView = iconView
                self.view.addSubview(iconView)
            }
            
            if iconView.image == nil {
                switch icon {
                case .managedBot:
                    iconView.image = UIImage(bundleImageName: "Peer Info/ManagedBotInlineTextIcon")?.withRenderingMode(.alwaysTemplate)
                case .warning:
                    iconView.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withRenderingMode(.alwaysTemplate)
                }
            }
            iconView.tintColor = item.isWarning ? presentationData.theme.list.itemDestructiveColor : presentationData.theme.list.freeTextColor
            
            if let image = iconView.image {
                iconView.frame = CGRect(origin: CGPoint(x: sideInset, y: verticalInset + 1.0), size: image.size)
            }
        } else {
            if let iconView = self.iconView {
                self.iconView = nil
                iconView.removeFromSuperview()
            }
        }
        
        let textSize = self.textNode.updateLayout(CGSize(width: width - sideInset * 2.0 - leftTextInset, height: .greatestFiniteMagnitude))
        
        let textFrame = CGRect(origin: CGPoint(x: sideInset + leftTextInset, y: verticalInset), size: textSize)
        
        let height = textSize.height + verticalInset * 2.0
        if item.isWarning {
            transition.updateFrame(node: self.warningBackgroundNode, frame: CGRect(x: cardInset, y: cardVerticalInset, width: width - cardInset * 2.0, height: height - cardVerticalInset * 2.0))
        } else {
            self.warningBackgroundNode.frame = .zero
        }
        
        if self.textNode.frame.size != textFrame.size {
            self.textNode.frame = textFrame
        } else {
            transition.updateFrame(node: self.textNode, frame: textFrame)
        }
        
        self.activateArea.frame = CGRect(origin: CGPoint(x: safeInsets.left + cardInset, y: cardVerticalInset), size: CGSize(width: width - safeInsets.left - safeInsets.right - cardInset * 2.0, height: height - cardVerticalInset * 2.0))
        self.activateArea.accessibilityTraits = item.linkAction == nil ? .staticText : [.staticText, .link]
        self.activateArea.accessibilityHint = item.linkAction == nil ? nil : "Opens the external source"
        self.activateArea.activate = { [weak self] in
            guard let self, let item = self.item, let linkAction = item.linkAction else {
                return false
            }
            guard let start = item.text.range(of: "](http://") ?? item.text.range(of: "](https://") else {
                return false
            }
            let urlStart = item.text.index(start.lowerBound, offsetBy: 2)
            guard let urlEnd = item.text[urlStart...].firstIndex(of: ")") else {
                return false
            }
            linkAction(.tap(String(item.text[urlStart..<urlEnd])))
            return true
        }
        
        return height
    }
    
    @objc private func tapLongTapOrDoubleTapGesture(_ recognizer: TapLongTapOrDoubleTapGestureRecognizer) {
        switch recognizer.state {
            case .ended:
                if let (gesture, location) = recognizer.lastRecognizedGestureAndLocation {
                    switch gesture {
                        case .tap:
                            let titleFrame = self.textNode.frame
                            if let item = self.item, titleFrame.contains(location) {
                                if let (_, attributes) = self.textNode.attributesAtPoint(CGPoint(x: location.x - titleFrame.minX, y: location.y - titleFrame.minY)) {
                                    if let url = attributes[NSAttributedString.Key(rawValue: TelegramTextAttributes.URL)] as? String {
                                        item.linkAction?(.tap(url))
                                    }
                                }
                            }
                        default:
                            break
                    }
                }
            default:
                break
        }
    }
    
    private func updateTouchesAtPoint(_ point: CGPoint?) {
        if let item = self.item, let presentationData = self.presentationData {
            var rects: [CGRect]?
            if let point = point {
                let textNodeFrame = self.textNode.frame
                if let (index, attributes) = self.textNode.attributesAtPoint(CGPoint(x: point.x - textNodeFrame.minX, y: point.y - textNodeFrame.minY)) {
                    let possibleNames: [String] = [
                        TelegramTextAttributes.URL,
                        TelegramTextAttributes.PeerMention,
                        TelegramTextAttributes.PeerTextMention,
                        TelegramTextAttributes.BotCommand,
                        TelegramTextAttributes.Hashtag
                    ]
                    for name in possibleNames {
                        if let _ = attributes[NSAttributedString.Key(rawValue: name)] {
                            rects = self.textNode.attributeRects(name: name, at: index)
                            break
                        }
                    }
                }
            }
            
            if let rects = rects {
                let linkHighlightingNode: LinkHighlightingNode
                if let current = self.linkHighlightingNode {
                    linkHighlightingNode = current
                } else {
                    linkHighlightingNode = LinkHighlightingNode(color: item.useAccentLinkColor ? presentationData.theme.list.itemAccentColor.withAlphaComponent(0.2) : presentationData.theme.list.freeTextColor.withAlphaComponent(0.2))
                    self.linkHighlightingNode = linkHighlightingNode
                    self.insertSubnode(linkHighlightingNode, belowSubnode: self.textNode)
                }
                linkHighlightingNode.frame = self.textNode.frame
                linkHighlightingNode.updateRects(rects)
            } else if let linkHighlightingNode = self.linkHighlightingNode {
                self.linkHighlightingNode = nil
                linkHighlightingNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.18, removeOnCompletion: false, completion: { [weak linkHighlightingNode] _ in
                    linkHighlightingNode?.removeFromSupernode()
                })
            }
        }
    }
}
