import Foundation
import UIKit
import AVFoundation
import AsyncDisplayKit
import SwiftSignalKit
import Display
import ItemListUI
import TelegramPresentationData
import SGSimpleSettings
import AyuGram

/// A static ItemList row for a preserved deleted message with attachments:
/// thumbnail (or placeholder) on the left, date label and text on the right.
/// Non-interactive: no selection, actions, entities, or copy affordances.
final class AyuSavedDeletedMessageItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let dateLabel: String
    let text: String
    let media: [AyuSavedMedia]
    let sectionId: ItemListSectionId

    init(presentationData: ItemListPresentationData, dateLabel: String, text: String, media: [AyuSavedMedia], sectionId: ItemListSectionId) {
        self.presentationData = presentationData
        self.dateLabel = dateLabel
        self.text = text
        self.media = media
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = AyuSavedDeletedMessageItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))

            node.contentSize = layout.contentSize
            node.insets = layout.insets

            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply(.None) })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? AyuSavedDeletedMessageItemNode {
                let makeLayout = nodeValue.asyncLayout()

                async {
                    let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
                    Queue.mainQueue().async {
                        completion(layout, { _ in
                            apply(animation)
                        })
                    }
                }
            }
        }
    }
}

private let ayuDeletedMessageThumbnailSize = CGSize(width: 60.0, height: 60.0)
private let ayuDeletedMessageThumbnailCornerRadius: CGFloat = 8.0

/// SF Symbol for the deleted-overlay marker, per SGSimpleSettings.ayuDeletedIconStyle.
func ayuDeletedOverlaySymbolName() -> String {
    switch SGSimpleSettings.shared.ayuDeletedIconStyle {
    case "none": return ""
    case "cross": return "xmark"
    case "crossed-eye", "eyeoff": return "eye.slash"
    default: return "trash"
    }
}

/// Content opacity (0.0–1.0) for deleted-message items.
func ayuDeletedContentAlpha() -> CGFloat {
    return CGFloat(AyuUtils.deletedMessageAlpha)
}

/// Mirrors the inline date/status marker's persisted color policy.
private func ayuDeletedOverlayColor(setting: String, themeColor: UIColor) -> UIColor {
    switch setting {
    case "red": return UIColor(rgb: 0xff453a)
    case "orange": return UIColor(rgb: 0xff9f0a)
    case "green": return UIColor(rgb: 0x30d158)
    case "blue": return UIColor(rgb: 0x0a84ff)
    case "purple": return UIColor(rgb: 0xbf5af2)
    default: return themeColor
    }
}

private final class AyuSavedDeletedMessageItemNode: ListViewItemNode {
    private let backgroundNode: ASDisplayNode
    private let topStripeNode: ASDisplayNode
    private let bottomStripeNode: ASDisplayNode
    private let maskNode: ASImageNode
    private let placeholderNode: ASDisplayNode
    private let thumbnailNode: ASImageNode
    private let labelNode: TextNode
    private let textNode: TextNode
    private let deletedIconNode: ASImageNode

    private var item: AyuSavedDeletedMessageItem?

    override var canBeLongTapped: Bool {
        return false
    }

    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true

        self.topStripeNode = ASDisplayNode()
        self.topStripeNode.isLayerBacked = true

        self.bottomStripeNode = ASDisplayNode()
        self.bottomStripeNode.isLayerBacked = true

        self.maskNode = ASImageNode()
        self.maskNode.isUserInteractionEnabled = false

        self.placeholderNode = ASDisplayNode()
        self.placeholderNode.isLayerBacked = true
        self.placeholderNode.cornerRadius = ayuDeletedMessageThumbnailCornerRadius
        self.placeholderNode.clipsToBounds = true

        self.thumbnailNode = ASImageNode()
        self.thumbnailNode.isUserInteractionEnabled = false
        self.thumbnailNode.contentMode = .scaleAspectFill
        self.thumbnailNode.cornerRadius = ayuDeletedMessageThumbnailCornerRadius
        self.thumbnailNode.clipsToBounds = true

        self.labelNode = TextNode()
        self.labelNode.isUserInteractionEnabled = false
        self.labelNode.contentMode = .left
        self.labelNode.contentsScale = UIScreen.main.scale

        self.textNode = TextNode()
        self.textNode.isUserInteractionEnabled = false
        self.textNode.contentMode = .left
        self.textNode.contentsScale = UIScreen.main.scale

        self.deletedIconNode = ASImageNode()
        self.deletedIconNode.isUserInteractionEnabled = false
        self.deletedIconNode.isLayerBacked = true

        super.init(layerBacked: false)

        self.isAccessibilityElement = true

        self.addSubnode(self.placeholderNode)
        self.addSubnode(self.thumbnailNode)
        self.addSubnode(self.labelNode)
        self.addSubnode(self.textNode)
        self.addSubnode(self.deletedIconNode)
    }

    private static func loadThumbnail(media: AyuSavedMedia) -> UIImage? {
        guard let path = AyuStorage.attachmentFileURL(relativePath: media.relativePath)?.path else {
            return nil
        }
        switch media.kind {
        case .photo:
            return UIImage(contentsOfFile: path)
        case .video:
            let asset = AVAsset(url: URL(fileURLWithPath: path))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240.0, height: 240.0)
            guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        case .file, .voice:
            return nil
        }
    }

    func asyncLayout() -> (_ item: AyuSavedDeletedMessageItem, _ params: ListViewItemLayoutParams, _ insets: ItemListNeighbors) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation) -> Void) {
        let makeLabelLayout = TextNode.asyncLayout(self.labelNode)
        let makeTextLayout = TextNode.asyncLayout(self.textNode)

        let currentItem = self.item

        return { item, params, neighbors in
            var updatedTheme: PresentationTheme?
            if currentItem?.presentationData.theme !== item.presentationData.theme {
                updatedTheme = item.presentationData.theme
            }

            let insets = itemListNeighborsPlainInsets(neighbors)
            let leftInset: CGFloat = 16.0 + params.leftInset
            let rightInset: CGFloat = 16.0 + params.rightInset
            let separatorHeight = UIScreenPixel

            let hasThumbnail = !item.media.isEmpty
            let thumbnailImage = hasThumbnail ? item.media.compactMap({ AyuSavedDeletedMessageItemNode.loadThumbnail(media: $0) }).first : nil

            let textLeftInset = hasThumbnail ? leftInset + ayuDeletedMessageThumbnailSize.width + 12.0 : leftInset
            let textWidth = max(1.0, params.width - textLeftInset - rightInset)

            let labelFont = Font.regular(item.presentationData.fontSize.itemListBaseLabelFontSize)
            let textFont = Font.regular(item.presentationData.fontSize.itemListBaseFontSize)

            let iconSize = CGSize(width: 20.0, height: 20.0)
            let markerSpacing: CGFloat = 6.0
            let deletedIconImage: UIImage?
            if !ayuDeletedOverlaySymbolName().isEmpty, let symbolImage = UIImage(systemName: ayuDeletedOverlaySymbolName()) {
                let markerColor = ayuDeletedOverlayColor(
                    setting: SGSimpleSettings.shared.ayuDeletedIconColor,
                    themeColor: item.presentationData.theme.list.itemSecondaryTextColor
                )
                deletedIconImage = generateTintedImage(image: symbolImage, color: markerColor)
            } else {
                deletedIconImage = nil
            }
            let markerWidth = deletedIconImage == nil ? 0.0 : iconSize.width + markerSpacing
            let dateTextWidth = max(1.0, textWidth - markerWidth)

            let (labelLayout, labelApply) = makeLabelLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.dateLabel, font: labelFont, textColor: item.presentationData.theme.list.itemSecondaryTextColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: dateTextWidth, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))

            let (textLayout, textApply) = makeTextLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.text, font: textFont, textColor: item.presentationData.theme.list.itemPrimaryTextColor), backgroundColor: nil, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))

            let textContentHeight = 11.0 + labelLayout.size.height + 3.0 + textLayout.size.height + 11.0
            let mediaContentHeight: CGFloat = hasThumbnail ? 11.0 + ayuDeletedMessageThumbnailSize.height + 11.0 : 0.0
            let contentSize = CGSize(width: params.width, height: max(textContentHeight, mediaContentHeight))
            let nodeLayout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)

            // Content opacity for preserved deleted items.
            let contentAlpha = ayuDeletedContentAlpha()

            return (nodeLayout, { [weak self] _ in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item

                strongSelf.accessibilityLabel = item.dateLabel
                strongSelf.accessibilityValue = item.text

                if updatedTheme != nil {
                    strongSelf.topStripeNode.backgroundColor = item.presentationData.theme.list.itemBlocksSeparatorColor
                    strongSelf.bottomStripeNode.backgroundColor = item.presentationData.theme.list.itemBlocksSeparatorColor
                    strongSelf.backgroundNode.backgroundColor = item.presentationData.theme.list.itemBlocksBackgroundColor
                    strongSelf.placeholderNode.backgroundColor = item.presentationData.theme.list.itemSecondaryTextColor.withAlphaComponent(0.12)
                }

                let _ = labelApply()
                let _ = textApply()

                let labelFrame = CGRect(origin: CGPoint(x: textLeftInset, y: 11.0), size: labelLayout.size)
                strongSelf.labelNode.frame = labelFrame
                strongSelf.textNode.frame = CGRect(origin: CGPoint(x: textLeftInset, y: labelFrame.maxY + 3.0), size: textLayout.size)

                if hasThumbnail {
                    let thumbnailFrame = CGRect(origin: CGPoint(x: leftInset, y: floor((contentSize.height - ayuDeletedMessageThumbnailSize.height) / 2.0)), size: ayuDeletedMessageThumbnailSize)
                    strongSelf.placeholderNode.frame = thumbnailFrame
                    strongSelf.thumbnailNode.frame = thumbnailFrame
                    strongSelf.thumbnailNode.image = thumbnailImage
                    strongSelf.placeholderNode.isHidden = false
                    strongSelf.thumbnailNode.isHidden = false
                } else {
                    strongSelf.placeholderNode.isHidden = true
                    strongSelf.thumbnailNode.isHidden = true
                    strongSelf.thumbnailNode.image = nil
                }

                // Deleted-marker overlay next to the date label.
                if let deletedIconImage = deletedIconImage {
                    strongSelf.deletedIconNode.image = deletedIconImage
                    strongSelf.deletedIconNode.frame = CGRect(
                        origin: CGPoint(
                            x: textLeftInset,
                            y: 11.0 + floor((labelLayout.size.height - iconSize.height) / 2.0)
                        ),
                        size: iconSize
                    )
                    strongSelf.deletedIconNode.isHidden = false
                    // Shift the date label right to make room for the icon.
                    strongSelf.labelNode.frame = labelFrame.offsetBy(dx: markerWidth, dy: 0.0)
                } else {
                    strongSelf.deletedIconNode.isHidden = true
                    strongSelf.deletedIconNode.image = nil
                    strongSelf.labelNode.frame = labelFrame
                }

                // Apply content opacity to everything except the block background.
                strongSelf.placeholderNode.alpha = contentAlpha
                strongSelf.thumbnailNode.alpha = contentAlpha
                strongSelf.labelNode.alpha = contentAlpha
                strongSelf.textNode.alpha = contentAlpha
                strongSelf.deletedIconNode.alpha = contentAlpha

                if strongSelf.backgroundNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.backgroundNode, at: 0)
                }
                if strongSelf.topStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.topStripeNode, at: 1)
                }
                if strongSelf.bottomStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.bottomStripeNode, at: 2)
                }
                if strongSelf.maskNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.maskNode, at: 3)
                }

                let hasCorners = itemListHasRoundedBlockLayout(params)
                var hasTopCorners = false
                var hasBottomCorners = false
                switch neighbors.top {
                    case .sameSection(false):
                        strongSelf.topStripeNode.isHidden = true
                    default:
                        hasTopCorners = true
                        strongSelf.topStripeNode.isHidden = hasCorners
                }
                let bottomStripeInset: CGFloat
                let bottomStripeOffset: CGFloat
                switch neighbors.bottom {
                    case .sameSection(false):
                        bottomStripeInset = 16.0 + params.leftInset
                        bottomStripeOffset = -separatorHeight
                        strongSelf.bottomStripeNode.isHidden = false
                    default:
                        bottomStripeInset = 0.0
                        bottomStripeOffset = 0.0
                        hasBottomCorners = true
                        strongSelf.bottomStripeNode.isHidden = hasCorners
                }

                strongSelf.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(item.presentationData.theme, top: hasTopCorners, bottom: hasBottomCorners) : nil

                strongSelf.backgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: contentSize.height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight)))
                strongSelf.maskNode.frame = strongSelf.backgroundNode.frame.insetBy(dx: params.leftInset, dy: 0.0)
                strongSelf.topStripeNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: separatorHeight))
                strongSelf.bottomStripeNode.frame = CGRect(origin: CGPoint(x: bottomStripeInset, y: contentSize.height + bottomStripeOffset), size: CGSize(width: params.width - bottomStripeInset, height: separatorHeight))
            })
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
