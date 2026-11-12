import Foundation
import UIKit
import CoreImage
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
    public let animateAllLines: Bool
    public let deletionParticlesEnabled: Bool
    public let deletionParticleCount: Int
    public let deletionParticleStyle: Int
    public let deletionParticleSpeed: CGFloat
    public let deletionParticleSpread: CGFloat
    public let deletionParticleSize: CGFloat

    public init(enabled: Bool, duration: TimeInterval, slideDistance: CGFloat, blurEnabled: Bool, blurDuration: TimeInterval, blurRadius: CGFloat, blurTextDelay: TimeInterval, scaleEnabled: Bool, scaleStart: CGFloat, rotateEnabled: Bool, rotateAngle: CGFloat, ignoreSpaces: Bool, animateAllLines: Bool = false, deletionParticlesEnabled: Bool = false, deletionParticleCount: Int = 5, deletionParticleStyle: Int = 0, deletionParticleSpeed: CGFloat = 50.0, deletionParticleSpread: CGFloat = 50.0, deletionParticleSize: CGFloat = 50.0) {
        self.enabled = enabled
        self.duration = min(max(duration.isFinite ? duration : 0.3, 0.05), 0.6)
        self.slideDistance = min(max(slideDistance.isFinite ? slideDistance : 0.0, 0.0), 20.0)
        self.blurEnabled = blurEnabled
        self.blurDuration = min(max(blurDuration.isFinite ? blurDuration : 0.3, 0.05), 0.6)
        self.blurRadius = min(max(blurRadius.isFinite ? blurRadius : 0.0, 0.0), 30.0)
        self.blurTextDelay = min(max(blurTextDelay.isFinite ? blurTextDelay : 0.0, 0.0), 0.99)
        self.scaleEnabled = scaleEnabled
        self.scaleStart = min(max(scaleStart.isFinite ? scaleStart : 1.0, 0.0), 2.0)
        self.rotateEnabled = rotateEnabled
        self.rotateAngle = min(max(rotateAngle.isFinite ? rotateAngle : 0.0, -180.0), 180.0)
        self.ignoreSpaces = ignoreSpaces
        self.animateAllLines = animateAllLines
        self.deletionParticlesEnabled = deletionParticlesEnabled
        self.deletionParticleCount = min(max(deletionParticleCount, 1), 16)
        self.deletionParticleStyle = min(max(deletionParticleStyle, 0), 2)
        self.deletionParticleSpeed = deletionParticleSpeed.isFinite ? min(max(deletionParticleSpeed, 0.0), 100.0) : 50.0
        self.deletionParticleSpread = deletionParticleSpread.isFinite ? min(max(deletionParticleSpread, 0.0), 100.0) : 50.0
        self.deletionParticleSize = deletionParticleSize.isFinite ? min(max(deletionParticleSize, 1.0), 100.0) : 50.0
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

    public func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = SGTextAnimationPreviewItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, { (nil, { _ in apply() }) })
            }
        }
    }

    public func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let node = node() as? SGTextAnimationPreviewItemNode else { return }
            let makeLayout = node.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
                Queue.mainQueue().async {
                    completion(layout, { _ in apply() })
                }
            }
        }
    }
}

private final class SGTextAnimationPreviewItemNode: ListViewItemNode {
    /// One preview character: the sharp text layer plus, when blur is enabled, a
    /// pre-blurred copy that dissolves out.
    private struct CharacterLayer {
        let layer: CATextLayer
        let blurLayer: CALayer?
        let isSpace: Bool
        let line: Int
        var deleted: Bool = false
    }

    private let backgroundNode = ASDisplayNode()
    private let topStripeNode = ASDisplayNode()
    private let bottomStripeNode = ASDisplayNode()
    private let maskNode = ASImageNode()
    private let titleNode = ImmediateTextNode()
    private let previewNode = ASDisplayNode()
    private var characterLayers: [CharacterLayer] = []
    private var item: SGTextAnimationPreviewItem?
    /// Invalidates every scheduled script step when the preview is rebuilt.
    private var scriptGeneration = 0

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

    func asyncLayout() -> (_ item: SGTextAnimationPreviewItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        return { [self] item, params, neighbors in
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
                self.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(theme, top: hasTopCorners, bottom: hasBottomCorners, glass: sgResolvedSystemStyle == .glass) : nil
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

    /// The scripted demo text: the localized sample, forced onto two lines so
    /// the loop always demonstrates typing, a line break, and deletion.
    private var scriptText: String {
        guard let item = self.item else { return "" }
        let sample = item.sampleText
        if sample.contains("\n") {
            return sample
        }
        let words = sample.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count > 2 else {
            return sample + "\n" + sample
        }
        var split = max(1, words.count / 2)
        while split < words.count - 1, words[..<split].joined(separator: " ").count < sample.count / 2 {
            split += 1
        }
        return words[..<split].joined(separator: " ") + "\n" + words[split...].joined(separator: " ")
    }

    private func rebuildPreview() {
        self.scriptGeneration += 1
        self.previewNode.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        self.characterLayers = []
        guard let item = self.item else { return }
        let font = Font.regular(20.0)
        let color = item.presentationData.theme.list.itemPrimaryTextColor
        let characters = self.scriptText.map(String.init)
        let lineHeight: CGFloat = 27.0
        // Measure each distinct character once instead of twice per character.
        var widthCache: [String: CGFloat] = [:]
        let widthFor: (String) -> CGFloat = { character in
            if let cached = widthCache[character] { return cached }
            let width = (character as NSString).size(withAttributes: [.font: font]).width
            widthCache[character] = width
            return width
        }
        var lineWidths: [CGFloat] = [0.0]
        for character in characters {
            if character == "\n" {
                lineWidths.append(0.0)
            } else {
                lineWidths[lineWidths.count - 1] += widthFor(character)
            }
        }
        let whitespace = CharacterSet.whitespacesAndNewlines
        // Per-rebuild blur cache, keyed by character.
        var blurImageCache: [String: CGImage?] = [:]
        var x = max(0.0, floor((self.previewNode.bounds.width - lineWidths[0]) * 0.5))
        var line = 0
        for character in characters {
            if character == "\n" {
                line += 1
                x = max(0.0, floor((self.previewNode.bounds.width - lineWidths[line]) * 0.5))
                continue
            }
            let width = widthFor(character)
            let textLayer = CATextLayer()
            textLayer.contentsScale = UIScreen.main.scale
            textLayer.string = NSAttributedString(string: character, attributes: [.font: font, .foregroundColor: color])
            textLayer.alignmentMode = .center
            let frame = CGRect(x: x, y: 7.0 + CGFloat(line) * lineHeight, width: ceil(width) + 1.0, height: 30.0)
            textLayer.frame = frame
            textLayer.opacity = 0.0
            let isSpace = character.unicodeScalars.allSatisfy { whitespace.contains($0) }

            // Pre-blurred twin, only when it will actually be used. Cached per
            // character so repeated letters share one render.
            var blurLayer: CALayer?
            if item.configuration.enabled, item.configuration.blurEnabled, !isSpace,
               !UIAccessibility.isReduceMotionEnabled {
                let cacheKey = character
                let blurImage: CGImage?
                if let cached = blurImageCache[cacheKey] {
                    blurImage = cached
                } else {
                    blurImage = Self.blurredCharacterImage(
                        character, font: font, color: color,
                        radius: item.configuration.blurRadius,
                        size: CGSize(width: ceil(width) + 1.0, height: 30.0)
                    )
                    blurImageCache[cacheKey] = blurImage
                }
                if let blurImage {
                    let pad = ceil(item.configuration.blurRadius * 3.0) + 2.0
                    let candidate = CALayer()
                    candidate.contents = blurImage
                    candidate.contentsScale = min(UIScreen.main.scale, 2.0)
                    candidate.frame = frame.insetBy(dx: -pad, dy: -pad)
                    candidate.opacity = 0.0
                    self.previewNode.layer.addSublayer(candidate)
                    blurLayer = candidate
                }
            }

            self.previewNode.layer.addSublayer(textLayer)
            self.characterLayers.append(CharacterLayer(layer: textLayer, blurLayer: blurLayer, isSpace: isSpace, line: line))
            x += width
        }
        self.playScript()
    }

    // MARK: - Scripted demo loop

    /// Plays the full demo: types line 1, breaks the line, types line 2,
    /// backspaces a few characters (with the deletion particle burst), then
    /// restarts. Every phase adapts to the current settings.
    private func playScript() {
        guard let item = self.item, !self.characterLayers.isEmpty else { return }
        let configuration = item.configuration
        let generation = self.scriptGeneration
        let shouldAnimate = configuration.enabled && !UIAccessibility.isReduceMotionEnabled

        func step(after delay: TimeInterval, _ action: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard generation == self.scriptGeneration else { return }
                action()
            }
        }

        // Feature disabled: show the settled two-line sample statically.
        guard shouldAnimate else {
            for entry in self.characterLayers {
                entry.layer.opacity = 1.0
            }
            return
        }

        let stagger = max(0.05, min(0.045, configuration.duration * 0.35))
        var t: TimeInterval = 0.25

        // 1) Typing, character by character, on every line.
        for entry in self.characterLayers {
            let entryCopy = entry
            step(after: t) { [weak self] in
                self?.reveal(entryCopy, animated: true)
            }
            t += (configuration.ignoreSpaces && entry.isSpace) ? stagger * 0.4 : stagger
        }

        // 2) Settle, then hold-backspace demo: trailing characters vanish
        // right-to-left (last character first), exactly like a real backspace.
        t += 0.55
        let deletable = self.characterLayers.filter { !$0.isSpace }.suffix(5).reversed()
        for entry in deletable {
            let entryCopy = entry
            step(after: t) { [weak self] in
                self?.delete(entryCopy)
            }
            t += 0.13
        }

        // 3) Pause on the result, then replay from scratch.
        t += 1.1
        step(after: t) { [weak self] in
            self?.rebuildPreview()
        }
    }

    /// Reveals one character with the insertion animation configured right now
    /// (opacity + slide + optional scale/rotate + the blur twin dissolve).
    private func reveal(_ entry: CharacterLayer, animated: Bool) {
        guard let configuration = self.item?.configuration else { return }
        let layer = entry.layer
        layer.removeAllAnimations()

        // Characters that never animate in the real composer (spaces with
        // ignoreSpaces, non-first lines without animateAllLines) appear
        // instantly here too, so the preview matches the real behavior.
        let instant = (configuration.ignoreSpaces && entry.isSpace)
            || (entry.line > 0 && !configuration.animateAllLines)
        guard animated, !instant else {
            layer.opacity = 1.0
            entry.blurLayer?.opacity = 0.0
            return
        }

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
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = max(configuration.duration, configuration.blurEnabled ? configuration.blurTextDelay + configuration.blurDuration : 0.0)
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        layer.opacity = 1.0
        layer.add(group, forKey: "sgTextPreview")

        if configuration.blurEnabled, let blurLayer = entry.blurLayer {
            blurLayer.removeAllAnimations()
            let blurOut = CABasicAnimation(keyPath: "opacity")
            blurOut.fromValue = 1.0
            blurOut.toValue = 0.0
            blurOut.beginTime = configuration.blurTextDelay
            blurOut.duration = configuration.blurDuration
            let blurSlide = CABasicAnimation(keyPath: "transform.translation.y")
            blurSlide.fromValue = configuration.slideDistance
            blurSlide.toValue = 0.0
            blurSlide.duration = configuration.duration
            let blurGroup = CAAnimationGroup()
            blurGroup.animations = [blurOut, blurSlide]
            blurGroup.duration = max(configuration.duration, configuration.blurTextDelay + configuration.blurDuration)
            blurGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
            blurGroup.fillMode = .both
            blurGroup.isRemovedOnCompletion = false
            blurLayer.add(blurGroup, forKey: "sgTextPreviewBlur")
        }
    }

    /// Backspaces one character: quick fade-out plus the same (subtle) particle
    /// burst the real composer emits, driven by the particle settings.
    private func delete(_ entry: CharacterLayer) {
        let layer = entry.layer
        layer.removeAllAnimations()
        entry.blurLayer?.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak layer] in
            layer?.removeFromSuperlayer()
            entry.blurLayer?.removeFromSuperlayer()
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1.0
        fade.toValue = 0.0
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "sgTextPreviewDelete")
        layer.opacity = 0.0
        CATransaction.commit()

        if let configuration = self.item?.configuration, configuration.deletionParticlesEnabled,
           !UIAccessibility.isReduceMotionEnabled {
            self.emitDeletionParticles(at: layer.frame, configuration: configuration)
        }
    }

    // MARK: - Deletion particles (mirrors the composer emitter, incl. the ~10x
    // subtler density, so the preview shows the effect users actually get).

    private func emitDeletionParticles(at rect: CGRect, configuration: SGTextAnimationPreviewConfiguration) {
        let margin: CGFloat = 6.0
        let maskFrame = rect.insetBy(dx: -margin, dy: -margin).intersection(self.previewNode.bounds)
        guard !maskFrame.isEmpty else { return }

        let emitter = CAEmitterLayer()
        emitter.emitterShape = .rectangle
        emitter.emitterMode = .surface
        emitter.renderMode = .oldestLast
        emitter.masksToBounds = true
        emitter.frame = maskFrame
        let localRect = rect.offsetBy(dx: -maskFrame.origin.x, dy: -maskFrame.origin.y)
        emitter.emitterPosition = CGPoint(x: localRect.midX, y: localRect.midY)
        emitter.emitterSize = CGSize(width: max(4.0, localRect.width), height: max(4.0, localRect.height))
        emitter.seed = UInt32.random(in: 0 ... UInt32.max)

        let cell = CAEmitterCell()
        cell.contents = Self.deletionParticleImage(style: configuration.deletionParticleStyle).cgImage
        cell.birthRate = Float(max(1, configuration.deletionParticleCount / 10)) / 0.08
        cell.lifetime = 0.3
        cell.lifetimeRange = 0.08
        cell.velocity = 8.0 + 0.3 * configuration.deletionParticleSpeed
        cell.velocityRange = 3.0 + 0.25 * configuration.deletionParticleSpread
        cell.emissionLongitude = -.pi / 2.0
        cell.emissionRange = .pi * 2.0 * configuration.deletionParticleSpread / 100.0
        let particleScale = 0.07 + 0.0045 * configuration.deletionParticleSize
        cell.scale = particleScale
        cell.scaleRange = particleScale * 0.35
        cell.scaleSpeed = -particleScale / CGFloat(cell.lifetime)
        cell.alphaSpeed = -2.4
        cell.spinRange = 0.8
        cell.yAcceleration = 6.0
        emitter.emitterCells = [cell]
        emitter.birthRate = 1.0
        self.previewNode.layer.addSublayer(emitter)

        let generation = self.scriptGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard generation == self.scriptGeneration else { return }
            emitter.birthRate = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            emitter.removeFromSuperlayer()
        }
    }

    private static func deletionParticleImage(style: Int) -> UIImage {
        switch style {
        case 1:
            return Self.deletionParticleSquareImage
        case 2:
            return Self.deletionParticleStarImage
        default:
            return Self.deletionParticleDotImage
        }
    }

    private static let deletionParticleDotImage: UIImage = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 6.0, height: 6.0))
        return renderer.image { context in
            UIColor.white.setFill()
            context.cgContext.addEllipse(in: CGRect(x: 0.8, y: 1.2, width: 3.0, height: 2.4))
            context.cgContext.addEllipse(in: CGRect(x: 2.8, y: 2.0, width: 2.2, height: 2.8))
            context.cgContext.fillPath()
        }
    }()

    private static let deletionParticleSquareImage: UIImage = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 6.0, height: 6.0))
        return renderer.image { _ in UIColor.white.setFill(); UIBezierPath(rect: CGRect(x: 1, y: 1, width: 4, height: 4)).fill() }
    }()

    private static let deletionParticleStarImage: UIImage = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8.0, height: 8.0))
        return renderer.image { context in
            UIColor.white.setStroke(); context.cgContext.setLineWidth(1.2)
            context.cgContext.move(to: CGPoint(x: 4, y: 0)); context.cgContext.addLine(to: CGPoint(x: 4, y: 8))
            context.cgContext.move(to: CGPoint(x: 0, y: 4)); context.cgContext.addLine(to: CGPoint(x: 8, y: 4))
            context.cgContext.strokePath()
        }
    }()

    /// Renders one character and Gaussian-blurs it into a small image. Cached per
    /// (character, radius, color) for the lifetime of a rebuild so a settings row
    /// never does more than a handful of these.
    private static func blurredCharacterImage(_ character: String, font: UIFont, color: UIColor, radius: CGFloat, size: CGSize) -> CGImage? {
        guard radius > 0.4, size.width > 0.0, size.height > 0.0,
              size.width < 256.0, size.height < 256.0 else {
            return nil
        }
        let pad = ceil(radius * 3.0) + 2.0
        let tileSize = CGSize(width: size.width + pad * 2.0, height: size.height + pad * 2.0)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = min(UIScreen.main.scale, 2.0)
        format.opaque = false
        let tile = UIGraphicsImageRenderer(size: tileSize, format: format).image { _ in
            (character as NSString).draw(
                in: CGRect(origin: CGPoint(x: pad, y: pad), size: size),
                withAttributes: [.font: font, .foregroundColor: color]
            )
        }
        guard let tileCG = tile.cgImage else { return nil }
        // CPU box blur (three passes ≈ Gaussian) — same rationale as the
        // composer renderer: deterministic, and no GPU CIContext hitches.
        let pixelRadius = max(1, Int((radius * format.scale).rounded()))
        return Self.boxBlurred(image: tileCG, radius: pixelRadius)
    }

    /// Pure-CPU box blur of a small RGBA tile: three horizontal+vertical box
    /// passes approximate a Gaussian closely.
    private static func boxBlurred(image: CGImage, radius: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width * height <= 512 * 512 else {
            return image
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: bitmapInfo) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            return nil
        }

        var src = bytes
        var dst = [UInt8](repeating: 0, count: bytes.count)
        for _ in 0 ..< 3 {
            Self.boxPass(&src, &dst, width: width, height: height, radius: radius, horizontal: true)
            swap(&src, &dst)
            Self.boxPass(&src, &dst, width: width, height: height, radius: radius, horizontal: false)
            swap(&src, &dst)
        }

        let result = src.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: bitmapInfo) else {
                return nil
            }
            return context.makeImage()
        }
        return result
    }

    /// One horizontal or vertical box pass with clamped edges, using a
    /// running sum per channel so the cost is linear in pixels.
    private static func boxPass(_ src: inout [UInt8], _ dst: inout [UInt8], width: Int, height: Int, radius: Int, horizontal: Bool) {
        let outer = horizontal ? height : width
        let inner = horizontal ? width : height
        let div = radius * 2 + 1
        func offset(_ o: Int, _ i: Int) -> Int {
            if horizontal {
                return (o * inner + i) * 4
            }
            return (i * outer + o) * 4
        }
        for o in 0 ..< outer {
            var sums = [Int](repeating: 0, count: 4)
            for i in -radius ... radius {
                let ci = min(max(i, 0), inner - 1)
                let base = offset(o, ci)
                sums[0] += Int(src[base])
                sums[1] += Int(src[base + 1])
                sums[2] += Int(src[base + 2])
                sums[3] += Int(src[base + 3])
            }
            for i in 0 ..< inner {
                let base = offset(o, i)
                dst[base] = UInt8(sums[0] / div)
                dst[base + 1] = UInt8(sums[1] / div)
                dst[base + 2] = UInt8(sums[2] / div)
                dst[base + 3] = UInt8(sums[3] / div)
                let add = min(i + radius + 1, inner - 1)
                let sub = max(i - radius, 0)
                let addBase = offset(o, add)
                let subBase = offset(o, sub)
                sums[0] += Int(src[addBase]) - Int(src[subBase])
                sums[1] += Int(src[addBase + 1]) - Int(src[subBase + 1])
                sums[2] += Int(src[addBase + 2]) - Int(src[subBase + 2])
                sums[3] += Int(src[addBase + 3]) - Int(src[subBase + 3])
            }
        }
    }
}
