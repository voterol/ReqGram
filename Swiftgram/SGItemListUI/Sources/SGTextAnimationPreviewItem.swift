import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI

public struct SGTextAnimationPreviewConfiguration: Equatable {
    public let enabled: Bool
    public let duration: TimeInterval
    public let slideDistance: CGFloat
    public let blurEnabled: Bool
    public let blurDuration: TimeInterval
    public let blurRadius: CGFloat
    public let blurTextDelay: TimeInterval
    public let scaleEnabled: Bool
    public let scaleStart: CGFloat
    public let rotateEnabled: Bool
    public let rotateAngle: CGFloat
    public let ignoreSpaces: Bool

    public init(enabled: Bool, duration: TimeInterval, slideDistance: CGFloat, blurEnabled: Bool, blurDuration: TimeInterval, blurRadius: CGFloat, blurTextDelay: TimeInterval, scaleEnabled: Bool, scaleStart: CGFloat, rotateEnabled: Bool, rotateAngle: CGFloat, ignoreSpaces: Bool) {
        self.enabled = enabled
        self.duration = min(max(duration.isFinite ? duration : 0.3, 0.05), 0.6)
        self.slideDistance = min(max(slideDistance.isFinite ? slideDistance : 0.0, 0.0), 20.0)
        self.blurEnabled = blurEnabled
        self.blurDuration = min(max(blurDuration.isFinite ? blurDuration : 0.3, 0.05), 0.6)
        self.blurRadius = min(max(blurRadius.isFinite ? blurRadius : 0.0, 0.0), 30.0)
        self.blurTextDelay = min(max(blurTextDelay.isFinite ? blurTextDelay : 0.0, 0.0), 0.5)
        self.scaleEnabled = scaleEnabled
        self.scaleStart = min(max(scaleStart.isFinite ? scaleStart : 1.0, 0.0), 2.0)
        self.rotateEnabled = rotateEnabled
        self.rotateAngle = min(max(rotateAngle.isFinite ? rotateAngle : 0.0, -180.0), 180.0)
        self.ignoreSpaces = ignoreSpaces
    }
}

public final class SGTextAnimationPreviewItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let configuration: SGTextAnimationPreviewConfiguration
    let title: String
    let sampleText: String
    let accessibilityHint: String
    public let sectionId: ItemListSectionId

    public init(presentationData: ItemListPresentationData, configuration: SGTextAnimationPreviewConfiguration, title: String, sampleText: String, accessibilityHint: String, sectionId: ItemListSectionId) {
        self.presentationData = presentationData
        self.configuration = configuration
        self.title = title
        self.sampleText = sampleText
        self.accessibilityHint = accessibilityHint
        self.sectionId = sectionId
    }

    public func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = SGTextAnimationPreviewItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, { (nil, { _ in apply() }) })
            }
        }
    }

    public func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let node = node() as? SGTextAnimationPreviewItemNode else { return }
            let makeLayout = node.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
                Queue.mainQueue().async {
                    completion(layout, { _ in apply() })
                }
            }
        }
    }
}

private final class SGTextAnimationPreviewItemNode: ListViewItemNode {
    private let backgroundNode = ASDisplayNode()
    private let topStripeNode = ASDisplayNode()
    private let bottomStripeNode = ASDisplayNode()
    private let maskNode = ASImageNode()
    private let titleNode = ImmediateTextNode()
    private let previewNode = ASDisplayNode()
    private var replayWorkItem: DispatchWorkItem?
    private var item: SGTextAnimationPreviewItem?

    init() {
        super.init(layerBacked: false)
        self.backgroundNode.isLayerBacked = true
        self.topStripeNode.isLayerBacked = true
        self.bottomStripeNode.isLayerBacked = true
        self.previewNode.clipsToBounds = true
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.topStripeNode)
        self.addSubnode(self.bottomStripeNode)
        self.addSubnode(self.maskNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.previewNode)
        self.isAccessibilityElement = true
        self.accessibilityTraits = .staticText
    }

    deinit {
        self.replayWorkItem?.cancel()
    }

    func asyncLayout() -> (_ item: SGTextAnimationPreviewItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        return { item, params, neighbors in
            let contentSize = CGSize(width: params.width, height: 124.0)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)
            return (layout, { [weak self] in
                guard let self else { return }
                self.item = item
                let theme = item.presentationData.theme
                let separatorHeight = UIScreenPixel
                let hasCorners = itemListHasRoundedBlockLayout(params)
                var hasTopCorners = false
                var hasBottomCorners = false
                switch neighbors.top {
                case .sameSection(false):
                    self.topStripeNode.isHidden = true
                default:
                    hasTopCorners = true
                    self.topStripeNode.isHidden = hasCorners
                }
                let bottomStripeInset: CGFloat
                let bottomStripeOffset: CGFloat
                switch neighbors.bottom {
                case .sameSection(false):
                    bottomStripeInset = params.leftInset + 16.0
                    bottomStripeOffset = -separatorHeight
                    self.bottomStripeNode.isHidden = false
                default:
                    bottomStripeInset = 0.0
                    bottomStripeOffset = 0.0
                    hasBottomCorners = true
                    self.bottomStripeNode.isHidden = hasCorners
                }
                self.backgroundNode.backgroundColor = theme.list.itemBlocksBackgroundColor
                self.topStripeNode.backgroundColor = theme.list.itemBlocksSeparatorColor
                self.bottomStripeNode.backgroundColor = theme.list.itemBlocksSeparatorColor
                self.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(theme, top: hasTopCorners, bottom: hasBottomCorners, glass: true) : nil
                self.backgroundNode.frame = CGRect(x: 0.0, y: -min(insets.top, separatorHeight), width: params.width, height: contentSize.height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight))
                self.maskNode.frame = self.backgroundNode.frame.insetBy(dx: params.leftInset, dy: 0.0)
                self.topStripeNode.frame = CGRect(x: 0.0, y: -min(insets.top, separatorHeight), width: layout.size.width, height: separatorHeight)
                self.bottomStripeNode.frame = CGRect(x: bottomStripeInset, y: contentSize.height + bottomStripeOffset, width: layout.size.width - bottomStripeInset, height: separatorHeight)

                self.titleNode.attributedText = NSAttributedString(string: item.title, font: Font.regular(13.0), textColor: theme.list.itemSecondaryTextColor)
                let titleSize = self.titleNode.updateLayout(CGSize(width: max(1.0, params.width - params.leftInset - params.rightInset - 32.0), height: 30.0))
                self.titleNode.frame = CGRect(origin: CGPoint(x: params.leftInset + 16.0, y: 13.0), size: titleSize)
                self.previewNode.frame = CGRect(x: params.leftInset + 16.0, y: 39.0, width: max(1.0, params.width - params.leftInset - params.rightInset - 32.0), height: 68.0)
                self.accessibilityLabel = "\(item.title). \(item.sampleText)"
                self.accessibilityHint = item.accessibilityHint
                self.rebuildPreview()
            })
        }
    }

    private func rebuildPreview() {
        self.replayWorkItem?.cancel()
        self.previewNode.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let item = self.item else { return }
        let font = Font.regular(20.0)
        let color = item.presentationData.theme.list.itemPrimaryTextColor
        let characters = item.sampleText.map(String.init)
        let widths = characters.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        let totalWidth = widths.reduce(0.0, +)
        var x = max(0.0, floor((self.previewNode.bounds.width - totalWidth) * 0.5))
        for (index, character) in characters.enumerated() {
            let textLayer = CATextLayer()
            textLayer.contentsScale = UIScreen.main.scale
            textLayer.string = NSAttributedString(string: character, attributes: [.font: font, .foregroundColor: color])
            textLayer.alignmentMode = .center
            textLayer.frame = CGRect(x: x, y: 20.0, width: ceil(widths[index]) + 1.0, height: 30.0)
            textLayer.name = character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) } ? "space" : nil
            self.previewNode.layer.addSublayer(textLayer)
            x += widths[index]
        }
        self.playAnimation()
    }

    private func playAnimation() {
        guard let item = self.item else { return }
        let configuration = item.configuration
        let color = item.presentationData.theme.list.itemPrimaryTextColor
        let shouldAnimate = configuration.enabled && !UIAccessibility.isReduceMotionEnabled
        let layers = self.previewNode.layer.sublayers ?? []
        for layer in layers {
            layer.removeAllAnimations()
            layer.opacity = 1.0
            layer.shadowOpacity = 0.0
            guard shouldAnimate else { continue }
            let isSpace = layer.name == "space"
            if configuration.ignoreSpaces && isSpace { continue }

            var animations: [CAAnimation] = []
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0.0
            opacity.toValue = 1.0
            opacity.duration = configuration.duration
            animations.append(opacity)

            let position = CABasicAnimation(keyPath: "transform.translation.y")
            position.fromValue = configuration.slideDistance
            position.toValue = 0.0
            position.duration = configuration.duration
            animations.append(position)

            if configuration.scaleEnabled || configuration.rotateEnabled {
                var start = CATransform3DIdentity
                if configuration.scaleEnabled {
                    start = CATransform3DScale(start, configuration.scaleStart, configuration.scaleStart, 1.0)
                }
                if configuration.rotateEnabled {
                    start = CATransform3DRotate(start, configuration.rotateAngle * .pi / 180.0, 0.0, 0.0, 1.0)
                }
                let transform = CABasicAnimation(keyPath: "transform")
                transform.fromValue = NSValue(caTransform3D: start)
                transform.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                transform.duration = configuration.duration
                animations.append(transform)
            }
            if configuration.blurEnabled {
                layer.shadowColor = color.cgColor
                layer.shadowOffset = .zero
                let radius = CABasicAnimation(keyPath: "shadowRadius")
                radius.fromValue = configuration.blurRadius
                radius.toValue = 0.0
                radius.beginTime = configuration.blurTextDelay
                radius.duration = configuration.blurDuration
                animations.append(radius)
                let shadowOpacity = CABasicAnimation(keyPath: "shadowOpacity")
                shadowOpacity.fromValue = 0.35
                shadowOpacity.toValue = 0.0
                shadowOpacity.beginTime = configuration.blurTextDelay
                shadowOpacity.duration = configuration.blurDuration
                animations.append(shadowOpacity)
            }
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = max(configuration.duration, configuration.blurEnabled ? configuration.blurTextDelay + configuration.blurDuration : 0.0)
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(group, forKey: "sgTextPreview")
        }
        guard shouldAnimate else { return }
        let lifetime = max(configuration.duration, configuration.blurEnabled ? configuration.blurTextDelay + configuration.blurDuration : 0.0)
        let workItem = DispatchWorkItem { [weak self] in self?.playAnimation() }
        self.replayWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime + 1.0, execute: workItem)
    }
}
