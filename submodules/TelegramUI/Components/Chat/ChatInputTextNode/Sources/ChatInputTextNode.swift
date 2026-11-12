import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import AsyncDisplayKit
import Display
import AppBundle
import ChatInputTextViewImpl
import MessageInlineBlockBackgroundView
import TextFormat
import AccountContext
import TextNodeWithEntities

/// Visual-only animation for newly inserted glyphs in the legacy input renderer.
/// This deliberately contains no settings or text-storage concerns.
public struct ChatInputTextAnimationConfiguration: Equatable {
    public var insertionEnabled: Bool
    public var duration: TimeInterval
    public var slideDistance: CGFloat
    public var blurEnabled: Bool
    public var blurDuration: TimeInterval
    public var blurRadius: CGFloat
    public var blurTextDelay: TimeInterval
    public var scaleEnabled: Bool
    public var scaleStart: CGFloat
    public var rotateEnabled: Bool
    public var rotateAngle: CGFloat
    public var ignoreSpaces: Bool
    public var animateAllLines: Bool
    public var deletionParticlesEnabled: Bool
    public var deletionParticleCount: Int
    public var deletionParticleStyle: Int
    public var deletionParticleSpeed: CGFloat
    public var deletionParticleSpread: CGFloat
    public var deletionParticleSize: CGFloat
    public var selectionEffect: Int
    public var selectionLiquidStretch: CGFloat
    public var selectionLiquidSide: CGFloat
    public var cursorEnabled: Bool
    public var cursorSpeed: CGFloat
    public var cursorWidth: CGFloat
    public var liquidCursorEnabled: Bool
    public var liquidCursorScale: CGFloat

    public init(insertionEnabled: Bool = false, duration: TimeInterval = 0.22, slideDistance: CGFloat = 4.0,
                blurEnabled: Bool = false, blurDuration: TimeInterval = 0.22, blurRadius: CGFloat = 10.0,
                blurTextDelay: TimeInterval = 0.0, scaleEnabled: Bool = false, scaleStart: CGFloat = 0.0,
                rotateEnabled: Bool = false, rotateAngle: CGFloat = 0.0, ignoreSpaces: Bool = true,
                 animateAllLines: Bool = false, deletionParticlesEnabled: Bool = false,
                 deletionParticleCount: Int = 5, deletionParticleStyle: Int = 0,
                 deletionParticleSpeed: CGFloat = 50.0, deletionParticleSpread: CGFloat = 50.0,
                  deletionParticleSize: CGFloat = 50.0,
                  selectionEffect: Int = 0, selectionLiquidStretch: CGFloat = 60.0,
                  selectionLiquidSide: CGFloat = 50.0, cursorEnabled: Bool = false,
                   cursorSpeed: CGFloat = 30.0, cursorWidth: CGFloat = 5.0,
                   liquidCursorEnabled: Bool = false, liquidCursorScale: CGFloat = 15.0) {
        self.insertionEnabled = insertionEnabled
        self.duration = duration.isFinite ? min(max(duration, 0.05), 0.6) : 0.22
        self.slideDistance = slideDistance.isFinite ? min(max(slideDistance, 0.0), 20.0) : 4.0
        self.blurEnabled = blurEnabled
        self.blurDuration = blurDuration.isFinite ? min(max(blurDuration, 0.05), 0.6) : 0.22
        self.blurRadius = blurRadius.isFinite ? min(max(blurRadius, 0.0), 30.0) : 10.0
        self.blurTextDelay = blurTextDelay.isFinite ? min(max(blurTextDelay, 0.0), 0.5) : 0.0
        self.scaleEnabled = scaleEnabled
        self.scaleStart = scaleStart.isFinite ? min(max(scaleStart, 0.0), 2.0) : 0.0
        self.rotateEnabled = rotateEnabled
        self.rotateAngle = rotateAngle.isFinite ? min(max(rotateAngle, -180.0), 180.0) : 0.0
        self.ignoreSpaces = ignoreSpaces
        self.animateAllLines = animateAllLines
        self.deletionParticlesEnabled = deletionParticlesEnabled
        self.deletionParticleCount = min(max(deletionParticleCount, 1), 16)
        self.deletionParticleStyle = min(max(deletionParticleStyle, 0), 2)
        self.deletionParticleSpeed = deletionParticleSpeed.isFinite ? min(max(deletionParticleSpeed, 0.0), 100.0) : 50.0
        self.deletionParticleSpread = deletionParticleSpread.isFinite ? min(max(deletionParticleSpread, 0.0), 100.0) : 50.0
        self.deletionParticleSize = deletionParticleSize.isFinite ? min(max(deletionParticleSize, 1.0), 100.0) : 50.0
        self.selectionEffect = min(max(selectionEffect, 0), 2)
        self.selectionLiquidStretch = selectionLiquidStretch.isFinite ? min(max(selectionLiquidStretch, 0.0), 100.0) : 60.0
        self.selectionLiquidSide = selectionLiquidSide.isFinite ? min(max(selectionLiquidSide, 0.0), 100.0) : 50.0
        self.cursorEnabled = cursorEnabled
        self.cursorSpeed = cursorSpeed.isFinite ? min(max(cursorSpeed, 1.0), 100.0) : 30.0
        self.cursorWidth = cursorWidth.isFinite ? min(max(cursorWidth, 1.0), 12.0) : 5.0
        self.liquidCursorEnabled = liquidCursorEnabled
        self.liquidCursorScale = liquidCursorScale.isFinite ? min(max(liquidCursorScale, 0.0), 80.0) : 15.0
    }
}

public protocol ChatInputTextNodeDelegate: AnyObject {
    func chatInputTextNodeDidUpdateText()
    func chatInputTextNodeShouldReturn(modifierFlags: UIKeyModifierFlags) -> Bool
    func chatInputTextNodeDidChangeSelection(dueToEditing: Bool)
    func chatInputTextNodeDidBeginEditing()
    func chatInputTextNodeDidFinishEditing()
    func chatInputTextNodeBackspaceWhileEmpty()
    
    @available(iOS 13.0, *)
    func chatInputTextNodeMenu(forTextRange textRange: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu
    
    func chatInputTextNode(shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool
    func chatInputTextNodeShouldCopy() -> Bool
    func chatInputTextNodeShouldPaste() -> Bool
    
    func chatInputTextNodeShouldRespondToAction(action: Selector) -> Bool
    func chatInputTextNodeTargetForAction(action: Selector) -> ChatInputTextNode.TargetForAction?
}

@available(iOS 15.0, *)
private final class ChatInputTextLayoutManager: NSTextLayoutManager {
    weak var contentStorage: ChatInputTextContentStorage?
    
    init(contentStorage: ChatInputTextContentStorage) {
        self.contentStorage = contentStorage
        
        super.init()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @discardableResult
    override func enumerateTextLayoutFragments(from location: NSTextLocation?, options: NSTextLayoutFragment.EnumerationOptions = [], using block: (NSTextLayoutFragment) -> Bool) -> NSTextLocation? {
        /*guard let contentStorage = self.contentStorage else {
            return nil
        }
        
        var layoutFragments: [NSTextLayoutFragment] = []
        contentStorage.enumerateTextElements(from: contentStorage.documentRange.location, options: [], using: { textElement in
            if let textElement = textElement as? NSTextParagraph {
                let layoutFragment = BubbleLayoutFragment(textElement: textElement, range: textElement.elementRange)
                layoutFragments.append(layoutFragment)
            } else {
                assertionFailure()
            }
            return true
        })
        
        /*super.enumerateTextLayoutFragments(from: self.documentRange.location, options: [.ensuresLayout, .ensuresExtraLineFragment], using: { fragment in
            layoutFragments.append(fragment)
            return true
        })*/
        
        let quoteId: (NSTextLayoutFragment) -> ObjectIdentifier? = { fragment in
            guard let contentStorage = self.contentStorage else {
                return nil
            }
            let lowerBound = contentStorage.offset(from: contentStorage.documentRange.location, to: fragment.rangeInElement.location)
            let upperBound = contentStorage.offset(from: contentStorage.documentRange.location, to: fragment.rangeInElement.endLocation)
            
            if let textStorage = contentStorage.textStorage, lowerBound != NSNotFound, upperBound != NSNotFound, lowerBound >= 0, upperBound <= textStorage.length {
                let fragmentString = textStorage.attributedSubstring(from: NSRange(location: lowerBound, length: upperBound - lowerBound))
                
                if fragmentString.length != 0, let attribute = fragmentString.attribute(NSAttributedString.Key(rawValue: "Attribute__Blockquote"), at: 0, effectiveRange: nil) as? ChatTextInputTextQuoteAttribute {
                    return ObjectIdentifier(attribute)
                }
            }
            
            return nil
        }
        
        return super.enumerateTextLayoutFragments(from: location, options: options, using: { fragment in
            var fragment = fragment
            if let index = layoutFragments.firstIndex(where: { $0.rangeInElement.isEqual(to: fragment.rangeInElement) }) {
                fragment = layoutFragments[index]
                
                if let fragment = fragment as? BubbleLayoutFragment {
                    if let fragmentQuoteId = quoteId(fragment) {
                        if index == 0 {
                            fragment.quoteIsFirst = false
                        } else if quoteId(layoutFragments[index - 1]) == fragmentQuoteId {
                            fragment.quoteIsFirst = false
                        } else {
                            fragment.quoteIsFirst = true
                        }
                        
                        if index == layoutFragments.count - 1 {
                            fragment.quoteIsLast = false
                        } else if quoteId(layoutFragments[index + 1]) == fragmentQuoteId {
                            fragment.quoteIsLast = false
                        } else {
                            fragment.quoteIsLast = true
                        }
                    } else {
                        fragment.quoteIsFirst = false
                        fragment.quoteIsLast = false
                    }
                }
            } else if layoutFragments.isEmpty {
            } else {
                assertionFailure()
            }
            
            return block(fragment)
        })*/
        return super.enumerateTextLayoutFragments(from: location, options: options, using: block)
    }
}

@available(iOS 15.0, *)
private class BubbleLayoutFragment: NSTextLayoutFragment {
    var quoteIsFirst: Bool = false
    var quoteIsLast: Bool = false
    
    override var leadingPadding: CGFloat {
        return 0.0
    }
    
    override var trailingPadding: CGFloat {
        return 0.0
    }
    
    override var topMargin: CGFloat {
        return self.quoteIsFirst ? 10.0 : 0.0
    }
    
    override var bottomMargin: CGFloat {
        return self.quoteIsLast ? 10.0 : 0.0
    }
    
    override var layoutFragmentFrame: CGRect {
        let result = super.layoutFragmentFrame
        return result
    }
    
    override var renderingSurfaceBounds: CGRect {
        return super.renderingSurfaceBounds
    }
    
    private var tightTextBounds: CGRect {
        var fragmentTextBounds = CGRect.null
        for lineFragment in textLineFragments {
            let lineFragmentBounds = lineFragment.typographicBounds
            if fragmentTextBounds.isNull {
                fragmentTextBounds = lineFragmentBounds
            } else {
                fragmentTextBounds = fragmentTextBounds.union(lineFragmentBounds)
            }
        }
        return fragmentTextBounds
    }
    
    // Return the bounding rect of the chat bubble, in the space of the first line fragment.
    private var bubbleRect: CGRect { return tightTextBounds.insetBy(dx: -3, dy: -3) }
    
    private var bubbleCornerRadius: CGFloat { return 20 }
    
    private var bubbleColor: UIColor { return .systemIndigo.withAlphaComponent(0.5) }

    private func createBubblePath(with ctx: CGContext) -> CGPath {
        let bubbleRect = self.bubbleRect
        let rect = min(bubbleCornerRadius, bubbleRect.size.height / 2, bubbleRect.size.width / 2)
        return CGPath(roundedRect: bubbleRect, cornerWidth: rect, cornerHeight: rect, transform: nil)
    }
    
    override func draw(at renderingOrigin: CGPoint, in ctx: CGContext) {
        // Draw the bubble and debug outline.
        ctx.saveGState()
        let bubblePath = createBubblePath(with: ctx)
        ctx.addPath(bubblePath)
        ctx.setFillColor(bubbleColor.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        
        var offset: CGFloat = 0.0
        for textLineFragment in self.textLineFragments {
            textLineFragment.draw(at: CGPoint(x: renderingOrigin.x, y: renderingOrigin.y + offset), in: ctx)
            offset += textLineFragment.typographicBounds.height
        }
    }
}

open class ChatInputTextNode: ASDisplayNode {
    public final class TargetForAction {
        public let target: Any?
        
        public init(target: Any?) {
            self.target = target
        }
    }
    
    public weak var delegate: ChatInputTextNodeDelegate? {
        didSet {
            self.textView.customDelegate = self.delegate
        }
    }
    
    public var textView: ChatInputTextView {
        return self.view as! ChatInputTextView
    }

    public var textAnimationConfiguration: ChatInputTextAnimationConfiguration {
        get {
            return self.textView.textAnimationConfiguration
        }
        set {
            self.textView.textAnimationConfiguration = newValue
        }
    }
    
    public var keyboardAppearance: UIKeyboardAppearance {
        get {
            return self.textView.keyboardAppearance
        }
        set {
            guard newValue != self.keyboardAppearance else {
                return
            }
            self.textView.keyboardAppearance = newValue
            self.textView.reloadInputViews()
        }
    }
    
    public var initialPrimaryLanguage: String? {
        get {
            return self.textView.initialPrimaryLanguage
        } set(value) {
            self.textView.initialPrimaryLanguage = value
        }
    }
    
    public func isCurrentlyEmoji() -> Bool {
        return false
    }
    
    public var textInputMode: UITextInputMode? {
        return self.textView.textInputMode
    }
    
    public var selectedRange: NSRange {
        get {
            return self.textView.selectedRange
        } set(value) {
            if self.textView.selectedRange != value {
                self.textView.selectedRange = value
            }
        }
    }
    
    public var attributedText: NSAttributedString? {
        get {
            return self.textView.attributedText
        } set(value) {
            self.textView.attributedText = value
        }
    }
    
    public var isRTL: Bool {
        return self.textView.isRTL
    }
    
    public var selectionRect: CGRect {
        guard let range = self.textView.selectedTextRange else {
            return self.textView.bounds
        }
        return self.textView.firstRect(for: range)
    }
    
    public var textContainerInset: UIEdgeInsets {
        get {
            return self.textView.defaultTextContainerInset
        } set(value) {
            let targetValue = UIEdgeInsets(top: value.top, left: value.left, bottom: value.bottom, right: value.right)
            if self.textView.defaultTextContainerInset != value {
                self.textView.defaultTextContainerInset = targetValue
            }
        }
    }

    public init(disableTiling: Bool = false) {
        super.init()

        self.setViewBlock({
            return ChatInputTextView(disableTiling: disableTiling)
        })
    }
    
    deinit {
    }
    
    public func resetInitialPrimaryLanguage() {
    }
    
    public func textHeightForWidth(_ width: CGFloat, rightInset: CGFloat) -> CGFloat {
        return self.textView.textHeightForWidth(width, rightInset: rightInset)
    }
    
    public func updateLayout(size: CGSize) {
        self.textView.updateLayout(size: size)
    }
}

private final class ChatInputTextContainer: NSTextContainer {
    var rightInset: CGFloat = 0.0
    
    override var isSimpleRectangularTextContainer: Bool {
        return false
    }
    
    override init(size: CGSize) {
        super.init(size: size)
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func lineFragmentRect(forProposedRect proposedRect: CGRect, at characterIndex: Int, writingDirection baseWritingDirection: NSWritingDirection, remaining remainingRect: UnsafeMutablePointer<CGRect>?) -> CGRect {
        var result = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex, writingDirection: baseWritingDirection, remaining: remainingRect)
        
        result.origin.x -= 5.0
        result.size.width -= 5.0
        result.size.width -= self.rightInset
        
        var attributedString: NSAttributedString?
        if #available(iOS 15.0, *), let textLayoutManager = self.textLayoutManager as? ChatInputTextLayoutManager {
            attributedString = textLayoutManager.contentStorage?.attributedString
        } else if let textStorage = self.layoutManager?.textStorage {
            attributedString = textStorage
        }
        
        if let textStorage = attributedString {
            let string: NSString = textStorage.string as NSString
            let index = Int(characterIndex)
            if index >= 0 && index < string.length {
                let attributes = textStorage.attributes(at: index, effectiveRange: nil)
                let blockQuote = attributes[NSAttributedString.Key(rawValue: "Attribute__Blockquote")] as? ChatTextInputTextQuoteAttribute
                if let blockQuote {
                    result.origin.x += 9.0
                    result.size.width -= 9.0
                    result.size.width -= 7.0
                    
                    var isFirstLine = false
                    if index == 0 {
                        isFirstLine = true
                    } else {
                        let previousAttributes = textStorage.attributes(at: index - 1, effectiveRange: nil)
                        let previousBlockQuote = previousAttributes[NSAttributedString.Key(rawValue: "Attribute__Blockquote")] as? NSObject
                        if let previousBlockQuote {
                            if !blockQuote.isEqual(previousBlockQuote) {
                                isFirstLine = true
                            }
                        } else {
                            isFirstLine = true
                        }
                    }
                    
                    if isFirstLine, case .quote = blockQuote.kind {
                        result.size.width -= 18.0
                    }
                }
            }
        }
        
        result.size.width = max(1.0, result.size.width)
        
        return result
    }
}

private final class ChatInputLegacyLayoutManager: NSLayoutManager {
    /// Per-animated-character state, resolved ONCE when the animation starts.
    /// Keeping this out of `drawGlyphs` is what removes the per-frame
    /// `NSString.substring` / `CharacterSet` / `lineFragmentRect` work.
    private struct AnimatedGlyph {
        let glyphRange: NSRange
        /// Character range this glyph came from, used to match non-glyph decorations
        /// (custom emoji subviews) to the same timeline.
        let characterRange: NSRange
        /// Staggered sequence position, so the easing does not depend on glyph indices.
        let ordinal: Int
        /// Rotation/scale pivot in container coordinates (origin is added at draw time).
        let center: CGPoint
        /// Untransformed ink box, used to size the offscreen blur tile.
        let bounds: CGRect
    }

    var animationConfiguration = ChatInputTextAnimationConfiguration() {
        didSet {
            if oldValue == animationConfiguration {
                return
            }
            if !animationConfiguration.insertionEnabled || UIAccessibility.isReduceMotionEnabled {
                self.clearInsertionAnimation()
            }
        }
    }

    private var insertionRange: NSRange?
    /// Recorded during didProcessEditing; geometry is resolved on the next tick so
    /// we never force layout inside a text-storage edit transaction.
    private var pendingInsertionRange: NSRange?
    /// Re-entrancy guard for geometry resolution (which can trigger layout).
    private var isResolvingInsertion = false
    /// Re-entrancy guard for the offscreen blur tile (nested drawGlyphs).
    private var isRenderingBlurTile = false

    /// Number of discrete blur steps the continuous radius is quantised to.
    private static let blurLevelCount = 6

    private struct BlurCacheKey: Hashable {
        let glyphLocation: Int
        let level: Int
    }
    private struct BlurCacheEntry {
        let image: CGImage
        let rect: CGRect
    }
    /// Memoised blur tiles for the current insertion only; dropped on clear.
    private var blurCache: [BlurCacheKey: BlurCacheEntry?] = [:]
    private var insertionStartTime: CFTimeInterval = 0.0
    /// Resolved animated glyphs for the current insertion, ordered by glyph index.
    private var animatedGlyphs: [AnimatedGlyph] = []
    /// Union of the animated ink boxes; the repaint damage rect we hand back.
    private var animatedDamageRect: CGRect = .null
    private var animatedCharacterRange: NSRange?
    private var currentLifetime: TimeInterval = 0.0
    /// Shared, vsync-aligned driver. Held only while an animation is in flight.
    private var animationLink: SharedDisplayLinkDriver.Link?

    /// Repaint request scoped to the animating characters instead of the whole document.
    var invalidateDisplay: ((NSRange, CGRect) -> Void)?

    /// True only while glyphs are actually mid-flight. `drawGlyphs` uses this to
    /// decide whether it may take the plain `super` fast path.
    private var isAnimating: Bool {
        return self.insertionRange != nil && !self.animatedGlyphs.isEmpty
    }

    override init() {
        super.init()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func beginInsertionAnimation(forCharacterRange range: NSRange) {
        guard animationConfiguration.insertionEnabled, !UIAccessibility.isReduceMotionEnabled, range.length > 0, range.length <= 64 else {
            self.clearInsertionAnimation()
            return
        }
        // This runs inside NSTextStorage's didProcessEditing. Forcing layout here
        // would be re-entrant layout during an edit transaction, so only the request
        // is recorded; glyph geometry is resolved on the next tick once TextKit has
        // finished its own layout pass.
        self.clearInsertionAnimation()
        self.pendingInsertionRange = range
        self.insertionStartTime = CACurrentMediaTime()
        self.startAnimationLink()
    }

    /// Resolves glyph geometry for a recorded insertion. Returns false when the
    /// insertion cannot be animated, in which case all animation state is cleared.
    @discardableResult
    private func resolvePendingInsertion() -> Bool {
        guard let range = self.pendingInsertionRange else {
            return false
        }
        // boundingRect/lineFragmentRect below can trigger layout. Guard against
        // re-entering this from a nested drawGlyphs caused by that layout.
        if self.isResolvingInsertion {
            return false
        }
        self.isResolvingInsertion = true
        defer { self.isResolvingInsertion = false }
        self.pendingInsertionRange = nil

        guard animationConfiguration.insertionEnabled, !UIAccessibility.isReduceMotionEnabled else {
            self.clearInsertionAnimation()
            return false
        }
        guard let textContainer = self.textContainers.first, let textStorage = self.textStorage else {
            self.clearInsertionAnimation()
            return false
        }

        let clampedRange = NSIntersectionRange(range, NSRange(location: 0, length: textStorage.length))
        guard clampedRange.length > 0 else {
            self.clearInsertionAnimation()
            return false
        }

        let insertedGlyphRange = self.glyphRange(forCharacterRange: clampedRange, actualCharacterRange: nil)
        guard insertedGlyphRange.length > 0, insertedGlyphRange.location != NSNotFound else {
            self.clearInsertionAnimation()
            return false
        }

        // Resolve the "first line only" gate once, against the first inserted glyph.
        let firstLineMinY = self.lineFragmentRect(forGlyphAt: insertedGlyphRange.location, effectiveRange: nil).minY

        // One NSString bridge for the whole insertion rather than one per glyph per frame.
        let nsString = textStorage.string as NSString
        let whitespace = CharacterSet.whitespacesAndNewlines

        var glyphs: [AnimatedGlyph] = []
        glyphs.reserveCapacity(insertedGlyphRange.length)
        var damage = CGRect.null
        var ordinal = 0

        for glyphIndex in insertedGlyphRange.lowerBound ..< insertedGlyphRange.upperBound {
            let characterRange = self.characterRange(forGlyphRange: NSRange(location: glyphIndex, length: 1), actualGlyphRange: nil)
            guard characterRange.location != NSNotFound,
                  NSMaxRange(characterRange) <= nsString.length,
                  NSIntersectionRange(characterRange, clampedRange).length > 0 else {
                continue
            }

            if animationConfiguration.ignoreSpaces {
                let substring = nsString.substring(with: characterRange)
                let isSpace = !substring.isEmpty && substring.unicodeScalars.allSatisfy { whitespace.contains($0) }
                if isSpace {
                    continue
                }
            }

            if !animationConfiguration.animateAllLines {
                if self.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil).minY != firstLineMinY {
                    continue
                }
            }

            let glyphRange = NSRange(location: glyphIndex, length: 1)
            let bounds = self.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            guard bounds.width.isFinite, bounds.height.isFinite, !bounds.isNull else {
                continue
            }

            glyphs.append(AnimatedGlyph(
                glyphRange: glyphRange,
                characterRange: characterRange,
                ordinal: ordinal,
                center: CGPoint(x: bounds.midX, y: bounds.midY),
                bounds: bounds
            ))
            ordinal += 1
            damage = damage.isNull ? bounds : damage.union(bounds)
        }

        guard !glyphs.isEmpty else {
            self.clearInsertionAnimation()
            return false
        }

        self.insertionRange = clampedRange
        self.animatedCharacterRange = clampedRange
        self.animatedGlyphs = glyphs
        self.currentLifetime = self.lifetime(forAnimatedCount: glyphs.count)

        // Slide/blur push ink outside the glyph box; grow the damage rect so the
        // in-flight pixels are actually inside the invalidated region.
        let bleed = max(animationConfiguration.slideDistance, animationConfiguration.blurEnabled ? animationConfiguration.blurRadius : 0.0) + 4.0
        self.animatedDamageRect = damage.isNull ? .null : damage.insetBy(dx: -bleed, dy: -bleed)

        self.startAnimationLink()
        return true
    }

    private func startAnimationLink() {
        if self.animationLink != nil {
            return
        }
        // `.max` lets the shared driver raise the CADisplayLink frame-rate range to
        // 120Hz on ProMotion; it falls back to the panel rate elsewhere.
        self.animationLink = SharedDisplayLinkDriver.shared.add(framesPerSecond: .max, { [weak self] _ in
            self?.animationTick()
        })
    }

    private func animationTick() {
        // First tick after an edit: TextKit has finished its layout pass by now, so
        // glyph geometry is safe to read.
        if self.pendingInsertionRange != nil {
            if !self.resolvePendingInsertion() {
                return
            }
        }
        guard self.isAnimating else {
            self.clearInsertionAnimation()
            return
        }
        if CACurrentMediaTime() - self.insertionStartTime >= self.currentLifetime {
            // Repaint once more unanimated so the final frame is the settled text.
            let range = self.animatedCharacterRange
            let rect = self.animatedDamageRect
            self.clearInsertionAnimation()
            if let range {
                self.invalidateDisplay?(range, rect)
            }
            return
        }
        if let range = self.animatedCharacterRange {
            self.invalidateDisplay?(range, self.animatedDamageRect)
        }
    }

    private func lifetime(forAnimatedCount count: Int) -> TimeInterval {
        let baseDuration = max(animationConfiguration.duration, 0.001)
        let stagger = min(0.045, baseDuration * 0.35)
        let sequenceDuration = stagger * Double(max(0, count - 1))
        guard animationConfiguration.blurEnabled else {
            return sequenceDuration + baseDuration
        }
        return sequenceDuration + max(baseDuration, max(animationConfiguration.blurTextDelay, 0.0) + max(animationConfiguration.blurDuration, 0.001))
    }

    func clearInsertionAnimation() {
        self.insertionRange = nil
        self.pendingInsertionRange = nil
        self.animatedCharacterRange = nil
        self.animatedGlyphs = []
        self.animatedDamageRect = .null
        self.currentLifetime = 0.0
        self.blurCache = [:]
        self.animationLink?.invalidate()
        self.animationLink = nil
    }

    /// Insertion-animation progress for a character range, so decorations that are
    /// NOT glyphs (custom emoji, which are real subviews) can ride the exact same
    /// stagger + easing as the drawn text instead of popping in instantly.
    /// Returns nil when the range is not animating.
    func insertionProgress(forCharacterRange range: NSRange) -> CGFloat? {
        guard self.isAnimating, animationConfiguration.insertionEnabled, !UIAccessibility.isReduceMotionEnabled else {
            return nil
        }
        guard let glyph = self.animatedGlyphs.first(where: { NSIntersectionRange($0.characterRange, range).length > 0 }) else {
            return nil
        }
        let duration = max(animationConfiguration.duration, 0.001)
        let stagger = min(0.045, duration * 0.35)
        let characterElapsed = (CACurrentMediaTime() - self.insertionStartTime) - stagger * Double(glyph.ordinal)
        if characterElapsed <= 0.0 {
            return 0.0
        }
        let linear = min(1.0, max(0.0, characterElapsed / duration))
        return CGFloat(1.0 - pow(1.0 - linear, 3.0))
    }

    /// Slide offset the drawn glyphs currently have, so emoji match exactly.
    var insertionSlideDistance: CGFloat {
        return animationConfiguration.slideDistance
    }

    var insertionScaleStart: CGFloat? {
        return animationConfiguration.scaleEnabled ? animationConfiguration.scaleStart : nil
    }

    deinit {
        self.animationLink?.invalidate()
    }
    
    override func notShownAttribute(forGlyphAt glyphIndex: Int) -> Bool {
        return true
    }
    
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        // If an insertion was recorded but not yet resolved, resolve it here. Draw is
        // outside the edit transaction and layout is settled, so this is safe and it
        // avoids a one-frame flash of fully-opaque text before the first tick.
        if self.pendingInsertionRange != nil, !self.isRenderingBlurTile {
            self.resolvePendingInsertion()
        }
        // Fast path: no animation in flight, the feature is off, or we are rendering
        // the offscreen blur tile (which calls back in here and must draw the glyph
        // plainly, with no transform or recursion). This must stay byte-for-byte
        // equivalent to the stock renderer — it is what every user with the feature
        // disabled (the default) hits on every keystroke.
        guard self.isAnimating, !self.isRenderingBlurTile,
              animationConfiguration.insertionEnabled, !UIAccessibility.isReduceMotionEnabled else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        guard let context = UIGraphicsGetCurrentContext() else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }

        let elapsed = CACurrentMediaTime() - self.insertionStartTime
        if elapsed >= self.currentLifetime {
            self.clearInsertionAnimation()
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }

        // Only the glyphs resolved at animation start are special-cased, and only
        // those that intersect the range the text system asked us to draw.
        var pending = self.animatedGlyphs.filter {
            NSIntersectionRange($0.glyphRange, glyphsToShow).length > 0
        }
        guard !pending.isEmpty else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        pending.sort { $0.glyphRange.location < $1.glyphRange.location }

        let duration = max(animationConfiguration.duration, 0.001)
        let stagger = min(0.045, duration * 0.35)

        // Draw every non-animating glyph in as few batched runs as possible, instead
        // of one save/restore + drawGlyphs call per glyph.
        var cursor = glyphsToShow.lowerBound
        for glyph in pending {
            if glyph.glyphRange.location > cursor {
                super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: glyph.glyphRange.location - cursor), at: origin)
            }

            let characterElapsed = elapsed - stagger * Double(glyph.ordinal)
            if characterElapsed <= 0.0 {
                // Not started yet: fully hidden. Skipping the draw is both correct
                // and cheaper than drawing at alpha 0.
                cursor = max(cursor, NSMaxRange(glyph.glyphRange))
                continue
            }

            let linear = min(1.0, max(0.0, characterElapsed / duration))
            // easeOutCubic — matches the preview item and CAMediaTimingFunction(.easeOut)
            // far better than the previous linear ramp, which is a large part of why
            // the effect read as "cheap".
            let progress = CGFloat(1.0 - pow(1.0 - linear, 3.0))

            self.drawAnimatingGlyph(glyph, progress: progress, characterElapsed: characterElapsed, origin: origin, context: context)
            cursor = max(cursor, NSMaxRange(glyph.glyphRange))
        }
        if cursor < glyphsToShow.upperBound {
            super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: glyphsToShow.upperBound - cursor), at: origin)
        }
    }

    private func drawAnimatingGlyph(_ glyph: AnimatedGlyph, progress: CGFloat, characterElapsed: TimeInterval, origin: CGPoint, context: CGContext) {
        let blurRadius: CGFloat
        if animationConfiguration.blurEnabled {
            let blurElapsed = characterElapsed - max(animationConfiguration.blurTextDelay, 0.0)
            let blurLinear = min(1.0, max(0.0, blurElapsed / max(animationConfiguration.blurDuration, 0.001)))
            let eased = CGFloat(1.0 - pow(1.0 - blurLinear, 3.0))
            blurRadius = animationConfiguration.blurRadius * (1.0 - eased)
        } else {
            blurRadius = 0.0
        }

        context.saveGState()
        defer { context.restoreGState() }

        let center = CGPoint(x: glyph.center.x + origin.x, y: glyph.center.y + origin.y)

        context.setAlpha(progress)
        context.translateBy(x: 0.0, y: animationConfiguration.slideDistance * (1.0 - progress))
        context.translateBy(x: center.x, y: center.y)
        if animationConfiguration.scaleEnabled {
            let start = animationConfiguration.scaleStart
            let scale = start + (1.0 - start) * progress
            if scale > 0.001 {
                context.scaleBy(x: scale, y: scale)
            }
        }
        if animationConfiguration.rotateEnabled {
            context.rotate(by: (animationConfiguration.rotateAngle * .pi / 180.0) * (1.0 - progress))
        }
        context.translateBy(x: -center.x, y: -center.y)

        // A real blur, not a drop shadow: rasterise the single glyph into a small
        // tile and run a true Gaussian over it. Below ~0.4pt the blur is visually
        // indistinguishable from sharp text, so draw directly and skip the tile.
        guard blurRadius > 0.4, let blurred = self.blurredGlyphImage(glyph, blurRadius: blurRadius) else {
            super.drawGlyphs(forGlyphRange: glyph.glyphRange, at: origin)
            return
        }
        context.draw(blurred.image, in: blurred.rect.offsetBy(dx: origin.x, dy: origin.y))
    }

    /// Renders one glyph into a small offscreen tile and Gaussian-blurs it.
    ///
    /// Blur radius is quantised to `blurLevelCount` steps and memoised per
    /// (glyph, step). A Core Image render is therefore done at most
    /// `glyphs x blurLevelCount` times for an ENTIRE insertion, instead of once per
    /// glyph per frame — which at 120Hz would be an order of magnitude more work and
    /// is what would actually make this lag. Quantisation is invisible because alpha
    /// and offset still animate continuously underneath.
    private func blurredGlyphImage(_ glyph: AnimatedGlyph, blurRadius: CGFloat) -> (image: CGImage, rect: CGRect)? {
        let maxRadius = max(animationConfiguration.blurRadius, 0.001)
        let step = max(1, min(Self.blurLevelCount, Int(ceil(blurRadius / maxRadius * CGFloat(Self.blurLevelCount)))))
        let quantisedRadius = maxRadius * CGFloat(step) / CGFloat(Self.blurLevelCount)

        let cacheKey = BlurCacheKey(glyphLocation: glyph.glyphRange.location, level: step)
        if let cached = self.blurCache[cacheKey] {
            return cached.flatMap { entry in (entry.image, entry.rect) }
        }

        let computed = self.renderBlurredGlyph(glyph, blurRadius: quantisedRadius)
        // Negative results are cached too, so a glyph that cannot be blurred does not
        // retry the whole pipeline every frame.
        self.blurCache[cacheKey] = computed.map { BlurCacheEntry(image: $0.image, rect: $0.rect) }
        return computed
    }

    private func renderBlurredGlyph(_ glyph: AnimatedGlyph, blurRadius: CGFloat) -> (image: CGImage, rect: CGRect)? {
        let pad = ceil(blurRadius * 3.0) + 2.0
        let tileRect = glyph.bounds.insetBy(dx: -pad, dy: -pad)
        guard tileRect.width > 0.0, tileRect.height > 0.0,
              tileRect.width < 512.0, tileRect.height < 512.0 else {
            return nil
        }

        let scale = min(UIScreen.main.scale, 2.0)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale
        format.opaque = false

        // Re-entrancy guard: drawing into the tile calls back into drawGlyphs.
        if self.isRenderingBlurTile {
            return nil
        }
        self.isRenderingBlurTile = true
        let renderer = UIGraphicsImageRenderer(size: tileRect.size, format: format)
        let tile = renderer.image { _ in
            // Shift the glyph so its blurred ink lands inside the tile.
            super.drawGlyphs(forGlyphRange: glyph.glyphRange, at: CGPoint(x: -tileRect.minX, y: -tileRect.minY))
        }
        self.isRenderingBlurTile = false

        guard let tileCG = tile.cgImage else {
            return nil
        }

        // Deterministic CPU blur (three box passes ≈ Gaussian). The tiles are
        // tiny (one glyph plus padding), so this costs microseconds — unlike
        // the shared GPU CIContext, which stutters on the simulator and was
        // the main source of dropped frames while blur was enabled.
        let pixelRadius = max(1, Int((blurRadius * scale).rounded()))
        guard let blurred = Self.boxBlurred(image: tileCG, radius: pixelRadius) else {
            return nil
        }
        return (blurred, tileRect)
    }

    /// Pure-CPU box blur of a small RGBA tile: three horizontal+vertical box
    /// passes approximate a Gaussian closely. Premultiplied alpha is blurred
    /// as-is, which is the correct compositing behavior.
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

private struct DisplayBlockQuote {
    var id: Int
    var boundingRect: CGRect
    var kind: ChatTextInputTextQuoteAttribute.Kind
    var isCollapsed: Bool
    var range: NSRange
    
    init(id: Int, boundingRect: CGRect, kind: ChatTextInputTextQuoteAttribute.Kind, isCollapsed: Bool, range: NSRange) {
        self.id = id
        self.boundingRect = boundingRect
        self.kind = kind
        self.isCollapsed = isCollapsed
        self.range = range
    }
}

private protocol ChatInputTextInternal: AnyObject {
    var textContainer: ChatInputTextContainer { get }
    
    var defaultTextContainerInset: UIEdgeInsets { get set }
    
    var updateDisplayElements: (() -> Void)? { get set }
    var invalidateAnimationRect: ((CGRect) -> Void)? { get set }
    var attributedString: NSAttributedString? { get }
    var animationConfiguration: ChatInputTextAnimationConfiguration { get set }
    func deletionRect(for characterRange: NSRange) -> CGRect
    /// Shared insertion timeline for non-glyph decorations. nil = not animating.
    func insertionAnimationState(forCharacterRange range: NSRange) -> (progress: CGFloat, slideDistance: CGFloat, scaleStart: CGFloat?)?
    
    func invalidateLayout()
    func setAttributedString(attributedString: NSAttributedString)
    func textSize() -> CGSize
    func currentTextBoundingRect() -> CGRect
    func currentTextLastLineBoundingRect() -> CGRect
    func displayBlockQuotes() -> [DisplayBlockQuote]
}

private extension ChatInputTextInternal {
    func deletionRect(for characterRange: NSRange) -> CGRect { return .null }
    func insertionAnimationState(forCharacterRange range: NSRange) -> (progress: CGFloat, slideDistance: CGFloat, scaleStart: CGFloat?)? { return nil }
}

private final class ChatInputTextLegacyInternal: NSObject, ChatInputTextInternal, NSLayoutManagerDelegate, NSTextStorageDelegate {
    let textContainer: ChatInputTextContainer
    let customTextStorage: NSTextStorage
    let customLayoutManager: ChatInputLegacyLayoutManager
    
    var defaultTextContainerInset: UIEdgeInsets = UIEdgeInsets()
    
    var updateDisplayElements: (() -> Void)?

    /// Set by the hosting view. Invoked per animation frame with the damage rect in
    /// container coordinates, so the view can repaint only the animating pixels and
    /// skip the full `updateTextElements()` + `setNeedsDisplay()` pass.
    var invalidateAnimationRect: ((CGRect) -> Void)?

    var animationConfiguration: ChatInputTextAnimationConfiguration {
        get { return self.customLayoutManager.animationConfiguration }
        set { self.customLayoutManager.animationConfiguration = newValue }
    }

    func deletionRect(for characterRange: NSRange) -> CGRect {
        let glyphRange = self.customLayoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return .null }
        return self.customLayoutManager.boundingRect(forGlyphRange: glyphRange, in: self.textContainer)
    }

    func insertionAnimationState(forCharacterRange range: NSRange) -> (progress: CGFloat, slideDistance: CGFloat, scaleStart: CGFloat?)? {
        guard let progress = self.customLayoutManager.insertionProgress(forCharacterRange: range) else {
            return nil
        }
        return (progress, self.customLayoutManager.insertionSlideDistance, self.customLayoutManager.insertionScaleStart)
    }
    
    var attributedString: NSAttributedString? {
        return self.customTextStorage
    }
    
    override init() {
        self.textContainer = ChatInputTextContainer(size: CGSize(width: 100.0, height: 100000.0))
        self.customTextStorage = NSTextStorage()
        self.customLayoutManager = ChatInputLegacyLayoutManager()
        self.customTextStorage.addLayoutManager(self.customLayoutManager)
        self.customLayoutManager.addTextContainer(self.textContainer)
        
        super.init()
        
        self.textContainer.widthTracksTextView = false
        self.textContainer.heightTracksTextView = false
        
        self.customLayoutManager.delegate = self
        self.customTextStorage.delegate = self
        self.customLayoutManager.invalidateDisplay = { [weak self] characterRange, damageRect in
            guard let self else { return }
            // Scope the repaint to the animating characters instead of the whole
            // document. `damageRect` is passed to the view so it can invalidate just
            // the affected pixels rather than its full bounds.
            let clamped = NSIntersectionRange(characterRange, NSRange(location: 0, length: self.customTextStorage.length))
            if clamped.length > 0 {
                self.customLayoutManager.invalidateDisplay(forCharacterRange: clamped)
            }
            self.invalidateAnimationRect?(damageRect)
        }
    }
    
    @objc func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingBeforeGlyphAt glyphIndex: Int, withProposedLineFragmentRect rect: CGRect) -> CGFloat {
        guard let textStorage = layoutManager.textStorage else {
            return 0.0
        }
        let characterIndex = Int(layoutManager.characterIndexForGlyph(at: glyphIndex))
        if characterIndex < 0 || characterIndex >= textStorage.length {
            return 0.0
        }
        
        let attributes = textStorage.attributes(at: characterIndex, effectiveRange: nil)
        guard let blockQuote = attributes[NSAttributedString.Key("Attribute__Blockquote")] as? NSObject else {
            return 0.0
        }
        
        if characterIndex != 0 {
            let previousAttributes = textStorage.attributes(at: characterIndex - 1, effectiveRange: nil)
            let previousBlockQuote = previousAttributes[NSAttributedString.Key("Attribute__Blockquote")] as? NSObject
            if let previousBlockQuote, blockQuote.isEqual(previousBlockQuote) {
                return 0.0
            }
        }
        
        return 8.0
    }
    
    @objc func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingAfterGlyphAt glyphIndex: Int, withProposedLineFragmentRect rect: CGRect) -> CGFloat {
        guard let textStorage = layoutManager.textStorage else {
            return 0.0
        }
        var characterIndex = Int(layoutManager.characterIndexForGlyph(at: glyphIndex))
        characterIndex -= 1
        if characterIndex < 0 {
            characterIndex = 0
        }
        if characterIndex < 0 || characterIndex >= textStorage.length {
            return 0.0
        }
        
        let attributes = textStorage.attributes(at: characterIndex, effectiveRange: nil)
        guard let blockQuote = attributes[NSAttributedString.Key("Attribute__Blockquote")] as? NSObject else {
            return 0.0
        }
        
        if characterIndex + 1 < textStorage.length {
            let nextAttributes = textStorage.attributes(at: characterIndex + 1, effectiveRange: nil)
            let nextBlockQuote = nextAttributes[NSAttributedString.Key("Attribute__Blockquote")] as? NSObject
            if let nextBlockQuote, blockQuote.isEqual(nextBlockQuote) {
                return 0.0
            }
        }
        
        return 8.0
    }
    
    @objc func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        if textContainer !== self.textContainer {
            return
        }
        self.updateDisplayElements?()
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        if delta > 0 {
            self.customLayoutManager.beginInsertionAnimation(forCharacterRange: editedRange)
        } else {
            self.customLayoutManager.clearInsertionAnimation()
        }
    }
    
    func invalidateLayout() {
        self.customLayoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: self.customTextStorage.length), actualCharacterRange: nil)
        self.customLayoutManager.ensureLayout(for: self.textContainer)
    }
    
    func setAttributedString(attributedString: NSAttributedString) {
        self.customTextStorage.setAttributedString(attributedString)
    }
    
    func textSize() -> CGSize {
        return self.customLayoutManager.usedRect(for: self.textContainer).size
    }
    
    func currentTextBoundingRect() -> CGRect {
        let glyphRange = self.customLayoutManager.glyphRange(forCharacterRange: NSRange(location: 0, length: self.customTextStorage.length), actualCharacterRange: nil)
        
        var boundingRect = CGRect()
        var startIndex = glyphRange.lowerBound
        while startIndex < glyphRange.upperBound {
            var effectiveRange = NSRange(location: NSNotFound, length: 0)
            var rect = self.customLayoutManager.lineFragmentUsedRect(forGlyphAt: startIndex, effectiveRange: &effectiveRange)
            
            let characterRange = self.customLayoutManager.characterRange(forGlyphRange: NSRange(location: startIndex, length: 1), actualGlyphRange: nil)
            if characterRange.location != NSNotFound {
                if let attribute = self.customTextStorage.attribute(NSAttributedString.Key("Attribute__Blockquote"), at: characterRange.location, effectiveRange: nil) {
                    let _ = attribute
                    rect.size.width += 13.0
                } else if let attribute = self.customTextStorage.attribute(.attachment, at: characterRange.location, effectiveRange: nil) as? ChatInputTextCollapsedQuoteAttachment {
                    let _ = attribute
                    rect.size.width += 8.0
                }
            }
            
            if boundingRect.isEmpty {
                boundingRect = rect
            } else {
                boundingRect = boundingRect.union(rect)
            }
            if effectiveRange.location != NSNotFound {
                startIndex = max(startIndex + 1, effectiveRange.upperBound)
            } else {
                break
            }
        }
        
        return boundingRect
    }
    
    func currentTextLastLineBoundingRect() -> CGRect {
        let glyphRange = self.customLayoutManager.glyphRange(forCharacterRange: NSRange(location: 0, length: self.customTextStorage.length), actualCharacterRange: nil)
        var boundingRect = CGRect()
        var startIndex = glyphRange.lowerBound
        while startIndex < glyphRange.upperBound {
            var effectiveRange = NSRange(location: NSNotFound, length: 0)
            let rect = self.customLayoutManager.lineFragmentUsedRect(forGlyphAt: startIndex, effectiveRange: &effectiveRange)
            boundingRect = rect
            if effectiveRange.location != NSNotFound {
                startIndex = max(startIndex + 1, effectiveRange.upperBound)
            } else {
                break
            }
        }
        return boundingRect
    }
    
    func displayBlockQuotes() -> [DisplayBlockQuote] {
        var result: [DisplayBlockQuote] = []
        var blockQuoteIndex = 0
        self.customTextStorage.enumerateAttribute(NSAttributedString.Key(rawValue: "Attribute__Blockquote"), in: NSRange(location: 0, length: self.customTextStorage.length), using: { value, range, _ in
            if let value = value as? ChatTextInputTextQuoteAttribute {
                let glyphRange = self.customLayoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                if self.customLayoutManager.isValidGlyphIndex(glyphRange.location) && self.customLayoutManager.isValidGlyphIndex(glyphRange.location + glyphRange.length - 1) {
                } else {
                    return
                }
                
                let id = blockQuoteIndex
                
                var boundingRect = CGRect()
                var startIndex = glyphRange.lowerBound
                while startIndex < glyphRange.upperBound {
                    var effectiveRange = NSRange(location: NSNotFound, length: 0)
                    let rect = self.customLayoutManager.lineFragmentUsedRect(forGlyphAt: startIndex, effectiveRange: &effectiveRange)
                    if boundingRect.isEmpty {
                        boundingRect = rect
                    } else {
                        boundingRect = boundingRect.union(rect)
                    }
                    if effectiveRange.location != NSNotFound {
                        startIndex = max(startIndex + 1, effectiveRange.upperBound)
                    } else {
                        break
                    }
                }
                
                boundingRect.origin.y += self.defaultTextContainerInset.top
                
                boundingRect.origin.x -= 4.0
                boundingRect.size.width += 4.0
                if case .quote = value.kind {
                    boundingRect.size.width += 18.0
                    boundingRect.size.width = min(boundingRect.size.width, self.textContainer.size.width - 18.0)
                }
                boundingRect.size.width = min(boundingRect.size.width, self.textContainer.size.width)
                
                boundingRect.origin.y -= 4.0
                boundingRect.size.height += 8.0
                
                result.append(DisplayBlockQuote(id: id, boundingRect: boundingRect, kind: value.kind, isCollapsed: value.isCollapsed, range: range))
                
                blockQuoteIndex += 1
            }
        })
        self.customTextStorage.enumerateAttribute(NSAttributedString.Key.attachment, in: NSRange(location: 0, length: self.customTextStorage.length), using: { value, range, _ in
            if let _ = value as? ChatInputTextCollapsedQuoteAttachment {
                let glyphRange = self.customLayoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                if self.customLayoutManager.isValidGlyphIndex(glyphRange.location) && self.customLayoutManager.isValidGlyphIndex(glyphRange.location + glyphRange.length - 1) {
                } else {
                    return
                }
                
                let id = blockQuoteIndex
                
                var boundingRect = CGRect()
                var startIndex = glyphRange.lowerBound
                while startIndex < glyphRange.upperBound {
                    var effectiveRange = NSRange(location: NSNotFound, length: 0)
                    let rect = self.customLayoutManager.lineFragmentUsedRect(forGlyphAt: startIndex, effectiveRange: &effectiveRange)
                    if boundingRect.isEmpty {
                        boundingRect = rect
                    } else {
                        boundingRect = boundingRect.union(rect)
                    }
                    if effectiveRange.location != NSNotFound {
                        startIndex = max(startIndex + 1, effectiveRange.upperBound)
                    } else {
                        break
                    }
                }
                
                boundingRect.origin.y += self.defaultTextContainerInset.top
                
                boundingRect.origin.x += 5.0
                boundingRect.size.width += 4.0
                boundingRect.size.width += 18.0
                boundingRect.size.width = min(boundingRect.size.width, self.textContainer.size.width - 18.0)
                boundingRect.size.width = min(boundingRect.size.width, self.textContainer.size.width)
                
                boundingRect.origin.y += 4.0
                boundingRect.size.height -= 8.0
                
                result.append(DisplayBlockQuote(id: id, boundingRect: boundingRect, kind: .quote, isCollapsed: true, range: range))
                
                blockQuoteIndex += 1
            }
        })
        return result
    }
}

@available(iOS 15.0, *)
private final class ChatInputTextContentStorage: NSTextContentStorage {
    
}

@available(iOS 15.0, *)
private final class ChatInputTextNewInternal: NSObject, ChatInputTextInternal, NSTextContentStorageDelegate, NSTextLayoutManagerDelegate {
    let textContainer: ChatInputTextContainer
    let contentStorage: ChatInputTextContentStorage
    let customLayoutManager: ChatInputTextLayoutManager
    
    var defaultTextContainerInset: UIEdgeInsets = UIEdgeInsets()
    
    var updateDisplayElements: (() -> Void)?
    /// The TextKit 2 path does not run the legacy insertion animation.
    var invalidateAnimationRect: ((CGRect) -> Void)?
    
    var attributedString: NSAttributedString? {
        return self.contentStorage.attributedString
    }

    var animationConfiguration: ChatInputTextAnimationConfiguration = ChatInputTextAnimationConfiguration()
    
    override init() {
        self.textContainer = ChatInputTextContainer(size: CGSize(width: 100.0, height: 100000.0))
        self.contentStorage = ChatInputTextContentStorage()
        self.customLayoutManager = ChatInputTextLayoutManager(contentStorage: self.contentStorage)
        self.contentStorage.addTextLayoutManager(self.customLayoutManager)
        self.customLayoutManager.textContainer = self.textContainer
        
        super.init()
        
        self.contentStorage.delegate = self
        self.customLayoutManager.delegate = self
    }
    
    func invalidateLayout() {
        self.customLayoutManager.invalidateLayout(for: self.contentStorage.documentRange)
        self.customLayoutManager.ensureLayout(for: self.contentStorage.documentRange)
    }
    
    func setAttributedString(attributedString: NSAttributedString) {
        self.contentStorage.attributedString = attributedString
    }
    
    func textSize() -> CGSize {
        return self.currentTextBoundingRect().size
    }
    
    func currentTextBoundingRect() -> CGRect {
        var boundingRect = CGRect()
        self.customLayoutManager.enumerateTextLayoutFragments(from: self.contentStorage.documentRange.location, options: [.ensuresLayout, .ensuresExtraLineFragment], using: { fragment in
            let fragmentFrame = fragment.layoutFragmentFrame
            if boundingRect.isEmpty {
                boundingRect = fragmentFrame
            } else {
                boundingRect = boundingRect.union(fragmentFrame)
            }
            return true
        })
        
        return boundingRect
    }
    
    func currentTextLastLineBoundingRect() -> CGRect {
        var boundingRect = CGRect()
        self.customLayoutManager.enumerateTextLayoutFragments(from: self.contentStorage.documentRange.location, options: [.ensuresLayout, .ensuresExtraLineFragment], using: { fragment in
            let fragmentFrame = fragment.layoutFragmentFrame
            for textLineFragment in fragment.textLineFragments {
                boundingRect = textLineFragment.typographicBounds.offsetBy(dx: fragmentFrame.minX, dy: fragmentFrame.minY)
            }
            return true
        })
        
        return boundingRect
    }
    
    @objc func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        let layoutFragment = BubbleLayoutFragment(textElement: textElement, range: textElement.elementRange)
        return layoutFragment
    }
    
    func displayBlockQuotes() -> [DisplayBlockQuote] {
        var nextId = 0
        var result: [ObjectIdentifier: DisplayBlockQuote] = [:]
        
        self.customLayoutManager.enumerateTextLayoutFragments(from: self.contentStorage.documentRange.location, options: [.ensuresLayout, .ensuresExtraLineFragment], using: { fragment in
            let lowerBound = self.contentStorage.offset(from: self.contentStorage.documentRange.location, to: fragment.rangeInElement.location)
            let upperBound = self.contentStorage.offset(from: self.contentStorage.documentRange.location, to: fragment.rangeInElement.endLocation)
            if let textStorage = self.contentStorage.textStorage, lowerBound != NSNotFound, upperBound != NSNotFound, lowerBound >= 0, upperBound <= textStorage.length {
                let fragmentRange = NSRange(location: lowerBound, length: upperBound - lowerBound)
                let fragmentString = textStorage.attributedSubstring(from: fragmentRange)
                
                var fragmentFrame = fragment.layoutFragmentFrame
                
                if fragmentString.length != 0, let attribute = fragmentString.attribute(NSAttributedString.Key(rawValue: "Attribute__Blockquote"), at: 0, effectiveRange: nil) as? ChatTextInputTextQuoteAttribute {
                    fragmentFrame.origin.y += self.defaultTextContainerInset.top
                    
                    fragmentFrame.origin.x -= 4.0
                    fragmentFrame.size.width += 4.0
                    if case .quote = attribute.kind {
                        fragmentFrame.size.width += 18.0
                        fragmentFrame.size.width = min(fragmentFrame.size.width, self.textContainer.size.width - 18.0)
                    }
                    fragmentFrame.size.width = min(fragmentFrame.size.width, self.textContainer.size.width)
                    
                    let quoteId = ObjectIdentifier(attribute)
                    if var current = result[quoteId] {
                        current.boundingRect = current.boundingRect.union(fragmentFrame)
                        
                        let newLowerBound = min(current.range.lowerBound, fragmentRange.lowerBound)
                        let newUpperBound = max(current.range.upperBound, fragmentRange.upperBound)
                        
                        current.range = NSRange(location: newLowerBound, length: newUpperBound - newLowerBound)
                        result[quoteId] = current
                    } else {
                        let id = nextId
                        nextId += 1
                        result[quoteId] = DisplayBlockQuote(id: id, boundingRect: fragmentFrame, kind: attribute.kind, isCollapsed: attribute.isCollapsed, range: fragmentRange)
                    }
                }
            }
            
            return true
        })
        
        return Array(result.values).sorted(by: { lhs, rhs in
            return lhs.boundingRect.minY < rhs.boundingRect.minY
        })
    }
}

private let registeredViewProvider: Void = {
    if #available(iOS 15.0, *) {
        NSTextAttachment.registerViewProviderClass(ChatInputTextCollapsedQuoteAttachmentImpl.ViewProvider.self, forFileType: "public.data")
    }
}()

public final class ChatInputTextCollapsedQuoteAttachmentImpl: NSTextAttachment, ChatInputTextCollapsedQuoteAttachment {
    final class View: UIView {
        let attachment: ChatInputTextCollapsedQuoteAttachmentImpl
        let textNode: ImmediateTextNodeWithEntities
        
        init(attachment: ChatInputTextCollapsedQuoteAttachmentImpl) {
            self.attachment = attachment
            self.textNode = ImmediateTextNodeWithEntities()
            self.textNode.displaysAsynchronously = false
            self.textNode.maximumNumberOfLines = 3
            
            super.init(frame: CGRect())
            
            self.addSubview(self.textNode.view)
        }
        
        required init(coder: NSCoder) {
            preconditionFailure()
        }
        
        static func calculateSize(attachment: ChatInputTextCollapsedQuoteAttachmentImpl, constrainedSize: CGSize) -> CGSize {
            guard let context = attachment.attributes.context as? AccountContext else {
                return CGSize(width: 10.0, height: 10.0)
            }
            
            let renderingText = textAttributedStringForStateText(
                context: context,
                stateText: attachment.text,
                fontSize: attachment.attributes.fontSize,
                textColor: attachment.attributes.textColor,
                accentTextColor: attachment.attributes.accentTextColor,
                writingDirection: nil,
                spoilersRevealed: false,
                availableEmojis: Set(context.animatedEmojiStickersValue.keys),
                emojiViewProvider: nil,
                makeCollapsedQuoteAttachment: nil
            )
            
            let textNode = ImmediateTextNode()
            textNode.maximumNumberOfLines = 3
            
            textNode.attributedText = renderingText
            textNode.cutout = TextNodeCutout(topRight: CGSize(width: 30.0, height: 10.0))
            
            let layoutSize = textNode.updateLayout(CGSize(width: constrainedSize.width - 9.0, height: constrainedSize.height))
            
            return CGSize(width: constrainedSize.width, height: 8.0 + layoutSize.height + 8.0)
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            
            guard let context = self.attachment.attributes.context as? AccountContext else {
                return
            }
            
            let renderingText = textAttributedStringForStateText(
                context: context, stateText: self.attachment.text,
                fontSize: self.attachment.attributes.fontSize,
                textColor: self.attachment.attributes.textColor,
                accentTextColor: self.attachment.attributes.accentTextColor,
                writingDirection: nil,
                spoilersRevealed: false,
                availableEmojis: Set(context.animatedEmojiStickersValue.keys),
                emojiViewProvider: nil,
                makeCollapsedQuoteAttachment: nil
            )
            
            /*let renderingText = NSMutableAttributedString(attributedString: attachment.text)
            renderingText.addAttribute(.font, value: attachment.attributes.font, range: NSRange(location: 0, length: renderingText.length))
            renderingText.addAttribute(.foregroundColor, value: attachment.attributes.textColor, range: NSRange(location: 0, length: renderingText.length))*/
            
            self.textNode.arguments = TextNodeWithEntities.Arguments(
                context: context,
                cache: context.animationCache,
                renderer: context.animationRenderer,
                placeholderColor: .gray,
                attemptSynchronous: true
            )
            
            self.textNode.attributedText = renderingText
            self.textNode.cutout = TextNodeCutout(topRight: CGSize(width: 30.0, height: 10.0))
            
            self.textNode.displaySpoilerEffect = true
            self.textNode.visibility = true
            
            let maxTextSize = CGSize(width: self.bounds.size.width - 9.0, height: self.bounds.size.height)
            let layoutSize = self.textNode.updateLayout(maxTextSize)
            
            self.textNode.frame = CGRect(origin: CGPoint(x: 9.0, y: 8.0), size: layoutSize)
        }
    }
    
    @available(iOS 15.0, *)
    final class ViewProvider: NSTextAttachmentViewProvider {
        override init(
            textAttachment: NSTextAttachment,
            parentView: UIView?,
            textLayoutManager: NSTextLayoutManager?,
            location: NSTextLocation
        ) {
            super.init(textAttachment: textAttachment, parentView: parentView, textLayoutManager: textLayoutManager, location: location)
        }
        
        override public func loadView() {
            if let textAttachment = self.textAttachment as? ChatInputTextCollapsedQuoteAttachmentImpl {
                self.view = View(attachment: textAttachment)
            } else {
                self.view = UIView()
            }
        }
    }
    
    public let text: NSAttributedString
    public let attributes: ChatInputTextCollapsedQuoteAttributes
    
    public init(text: NSAttributedString, attributes: ChatInputTextCollapsedQuoteAttributes) {
        let _ = registeredViewProvider
        
        self.text = text
        self.attributes = attributes
        
        super.init(data: nil, ofType: "public.data")
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        return CGRect(origin: CGPoint(), size: View.calculateSize(attachment: self, constrainedSize: CGSize(width: lineFrag.width, height: 10000.0)))
    }
    
    override public func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        return nil
    }
}

private final class ChatInputSelectionOverlayView: UIView {
    private let selectionLayer = CAShapeLayer()
    private let cursorLayer = CAShapeLayer()
    // Driven by the shared 120Hz-capable driver (same one the glyph-insertion
    // animation uses) instead of a standalone CADisplayLink, so the caret never
    // falls back to a lower, inconsistent refresh rate on ProMotion devices.
    private var animationLink: SharedDisplayLinkDriver.Link?
    private var displayedCaret = CGPoint.zero
    private var targetCaret = CGPoint.zero
    // Points-per-second, constant-velocity travel speed. Deliberately NOT an
    // exponential-decay factor: decay makes the caret sprint at the start of a
    // move and crawl at the end, which reads as stutter. A constant speed makes
    // every jump - short or long - look like the same smooth, even motion.
    private var cursorVelocity: CGFloat = 640.0
    private var liquidEnabled = false
    private var liquidScale: CGFloat = 15.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = false
        self.backgroundColor = nil
        self.clipsToBounds = true
        self.layer.addSublayer(self.selectionLayer)
        self.layer.addSublayer(self.cursorLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { self.animationLink?.invalidate() }

    private func startAnimationLink() {
        guard self.animationLink == nil else { return }
        self.animationLink = SharedDisplayLinkDriver.shared.add(framesPerSecond: .max) { [weak self] dt in
            self?.tick(dt)
        }
    }

    private func stopAnimationLink() {
        self.animationLink?.invalidate()
        self.animationLink = nil
    }

    private func tick(_ frameDuration: CGFloat) {
        // Clamp against large gaps (e.g. after the run loop was briefly starved)
        // so a single resumed frame cannot make the caret jump far past its target.
        let delta = min(max(frameDuration, 0.0), 1.0 / 20.0)
        let dx = targetCaret.x - displayedCaret.x
        let dy = targetCaret.y - displayedCaret.y
        let distance = hypot(dx, dy)
        if distance <= 0.5 || delta <= 0.0 {
            displayedCaret = targetCaret
            cursorLayer.position = displayedCaret
            cursorLayer.transform = CATransform3DIdentity
            self.stopAnimationLink()
            return
        }
        let travel = min(distance, cursorVelocity * delta)
        let fraction = travel / distance
        displayedCaret.x += dx * fraction
        displayedCaret.y += dy * fraction
        cursorLayer.position = displayedCaret
        if liquidEnabled {
            let remaining = hypot(targetCaret.x - displayedCaret.x, targetCaret.y - displayedCaret.y)
            cursorLayer.transform = CATransform3DMakeScale(1.0, 1.0 + liquidScale / 100.0 * min(1.0, remaining / 40.0), 1.0)
        }
        if hypot(targetCaret.x - displayedCaret.x, targetCaret.y - displayedCaret.y) <= 0.5 {
            displayedCaret = targetCaret
            cursorLayer.position = displayedCaret
            cursorLayer.transform = CATransform3DIdentity
            self.stopAnimationLink()
        }
    }

    private func validRect(_ rect: CGRect) -> CGRect? {
        guard !rect.isNull, !rect.isInfinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite else {
            return nil
        }
        let clipped = rect.intersection(self.bounds)
        return clipped.isNull || clipped.width <= 0.0 || clipped.height <= 0.0 ? nil : clipped
    }

    func update(selectionRects: [CGRect], color: UIColor, configuration: ChatInputTextAnimationConfiguration, animated: Bool) {
        cursorLayer.removeAllAnimations()
        if configuration.cursorEnabled, selectionRects.isEmpty {
            // The caller supplies the native caret rect separately through updateCaret.
            cursorLayer.isHidden = false
            cursorLayer.backgroundColor = color.cgColor
            cursorLayer.bounds.size.width = configuration.cursorWidth
        } else {
            cursorLayer.isHidden = true
        }
        // Selection effects are deliberately additive: UIKit keeps ownership of
        // the native selection highlight while this layer only draws the
        // configured outline/liquid accent. Keep the accent translucent so it
        // cannot obscure selected text or duplicate the native fill opaquely.
        guard configuration.selectionEffect != 0, !selectionRects.isEmpty else {
            self.selectionLayer.path = nil
            self.selectionLayer.removeAllAnimations()
            return
        }
        let path = UIBezierPath()
        let sideInset = configuration.selectionLiquidSide / 50.0
        let verticalInset = configuration.selectionLiquidStretch / 200.0 * 3.0
        for rect in selectionRects {
            guard let effectRect = self.validRect(rect.insetBy(dx: -sideInset, dy: -verticalInset)) else { continue }
            path.append(UIBezierPath(roundedRect: effectRect, cornerRadius: min(5.0, effectRect.height * 0.25)))
        }
        self.selectionLayer.path = path.cgPath
        self.selectionLayer.fillColor = configuration.selectionEffect == 2 ? color.withAlphaComponent(0.12).cgColor : UIColor.clear.cgColor
        self.selectionLayer.strokeColor = color.withAlphaComponent(configuration.selectionEffect == 2 ? 0.3 : 0.55).cgColor
        self.selectionLayer.lineWidth = configuration.selectionEffect == 2 ? 1.0 : 1.5
        if animated {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.25
            pulse.toValue = 1.0
            pulse.duration = 0.16
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.selectionLayer.add(pulse, forKey: "appear")
        }
    }

    func updateCaret(_ rect: CGRect, color: UIColor, configuration: ChatInputTextAnimationConfiguration, animated: Bool) {
        guard configuration.cursorEnabled, !rect.isNull else {
            cursorLayer.isHidden = true
            self.stopAnimationLink()
            return
        }
        cursorLayer.isHidden = false
        cursorLayer.backgroundColor = color.cgColor
        // Map the 1...100 "speed" setting to a constant points-per-second velocity.
        // This keeps the caret's motion rate uniform for a given setting value,
        // regardless of how far a single jump is - unlike the previous exponential
        // decay, where the same setting produced a fast start and a slow, draggy tail.
        cursorVelocity = 200.0 + configuration.cursorSpeed * 20.0
        liquidEnabled = configuration.liquidCursorEnabled
        liquidScale = configuration.liquidCursorScale
        cursorLayer.cornerRadius = configuration.cursorWidth * 0.5
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: configuration.cursorWidth, height: max(12.0, rect.height))
        targetCaret = CGPoint(x: rect.midX, y: rect.midY)
        if liquidEnabled {
            let travel = hypot(targetCaret.x - displayedCaret.x, targetCaret.y - displayedCaret.y)
            cursorLayer.transform = CATransform3DMakeScale(1.0, 1.0 + liquidScale / 100.0 * min(1.0, travel / 40.0), 1.0)
        } else {
            cursorLayer.transform = CATransform3DIdentity
        }
        if displayedCaret == .zero || !animated { displayedCaret = targetCaret; cursorLayer.position = displayedCaret }
        else if self.animationLink == nil {
            self.startAnimationLink()
        }
    }
}

public final class ChatInputTextView: ChatInputTextViewImpl, UITextViewDelegate, NSLayoutManagerDelegate, NSTextStorageDelegate {
    public final class Theme: Equatable {
        public final class Quote: Equatable {
            public enum LineStyle: Equatable {
                case solid(color: UIColor)
                case doubleDashed(mainColor: UIColor, secondaryColor: UIColor)
                case tripleDashed(mainColor: UIColor, secondaryColor: UIColor, tertiaryColor: UIColor)
            }
            public let background: UIColor
            public let foreground: UIColor
            public let lineStyle: LineStyle
            public let codeBackground: UIColor
            public let codeForeground: UIColor
            
            public init(
                background: UIColor,
                foreground: UIColor,
                lineStyle: LineStyle,
                codeBackground: UIColor,
                codeForeground: UIColor
            ) {
                self.background = background
                self.foreground = foreground
                self.lineStyle = lineStyle
                self.codeBackground = codeBackground
                self.codeForeground = codeForeground
            }
            
            public static func ==(lhs: Quote, rhs: Quote) -> Bool {
                if !lhs.background.isEqual(rhs.background) {
                    return false
                }
                if !lhs.foreground.isEqual(rhs.foreground) {
                    return false
                }
                if lhs.lineStyle != rhs.lineStyle {
                    return false
                }
                if !lhs.codeBackground.isEqual(rhs.codeBackground) {
                    return false
                }
                if !lhs.codeForeground.isEqual(rhs.codeForeground) {
                    return false
                }
                return true
            }
        }
        
        public let quote: Quote
        
        public init(quote: Quote) {
            self.quote = quote
        }
        
        public static func ==(lhs: Theme, rhs: Theme) -> Bool {
            if lhs.quote != rhs.quote {
                return false
            }
            return true
        }
    }
    
    override public var attributedText: NSAttributedString? {
        get {
            return super.attributedText
        } set(value) {
            if self.attributedText != value {
                let selectedRange = self.selectedRange
                let preserveSelectedRange = selectedRange.location != self.textStorage.length
                
                // UTF-16 code units, which is what the in-place write below walks. Swift's `==`
                // compares canonical equivalence, so precomposed "é" equalled "e" + U+0301 and the
                // attribute walk ran past (or short of) the storage (`HarnessLegacyNormalizationSetTests`).
                let sameCharacters = (self.textStorage.string as NSString).isEqual(to: value?.string ?? "")
                if self.appliesTextInPlace || sameCharacters {
                    // A programmatic `attributedText` set clears UITextView's undo stack
                    // (`-[UITextInputController _textStorageDidProcessEditing:]` calls
                    // `removeAllActions` for it), so write through the text storage instead: always
                    // inside `performUndoableTextChange`, and for ANY write that leaves the characters
                    // alone. The second half is what keeps the history across the host's echoes: the
                    // chat pushes its input state back on every selection change, the node decorates
                    // the storage after each set (`refreshDecorationFromStoredConfig`), so the next
                    // echo's freshly built string differs in attributes alone — and it used to be a full
                    // set that wiped every step, a Quote/Code command's included, on the first caret
                    // move after it (composer harness, 2026-09-23,
                    // `HarnessLegacyBlockFormatUndoAfterTypingTests`).
                    let value = value ?? NSAttributedString()
                    self.textStorage.beginEditing()
                    if sameCharacters {
                        // Attributes only, so the edit is reported as one (a character edit from
                        // outside the input controller drops UIKit's typing steps).
                        value.enumerateAttributes(in: NSRange(location: 0, length: value.length), options: [], using: { attributes, range, _ in
                            self.textStorage.setAttributes(attributes, range: range)
                        })
                    } else {
                        // A character change still drops UIKit's earlier typing steps (measured:
                        // replacing only the differing span does too); the step itself is kept.
                        self.textStorage.setAttributedString(value)
                    }
                    self.textStorage.endEditing()
                } else {
                    super.attributedText = value ?? NSAttributedString()
                }
                
                if preserveSelectedRange {
                    self.isPreservingSelection = true
                    self.selectedRange = selectedRange
                    self.isPreservingSelection = false
                }
                
                self.updateTextContainerInset()
            }
        }
    }
    
    fileprivate var isPreservingSelection: Bool = false
    fileprivate var isPreservingText: Bool = false
    
    /// While set, `attributedText` writes go through the text storage in place (see the setter).
    private var appliesTextInPlace: Bool = false
    
    /// Runs `body` — a programmatic change of this view's text, typically a host command whose new
    /// state comes back through `attributedText` (a Format command, pushed back by the chat's
    /// `updateInputTextState`) — as ONE step on the view's own undo manager, keeping the steps
    /// already on it. Undo restores the text and selection from before `body`, redo the ones after;
    /// each restore is reported as a user edit (`textViewDidChange`) so the host re-reads the state,
    /// and the host's echo of it is applied in place too. A `body` that changes nothing registers
    /// nothing.
    ///
    /// Why not simply `attributedText =`: a programmatic set clears UITextView's undo stack, which
    /// made every legacy Format command both un-undoable and a wipe of the typing history before it.
    /// Writing through the text storage leaves the stack alone, and restoring the exact pre-command
    /// text on undo keeps every older step consistent with the text it expects.
    ///
    /// Re-entrant: a call inside another one runs `body` and leaves the registering to the outer
    /// call, so a command wrapped at two levels (the Format menu around the chat's own
    /// `performUndoableInputChange`) is still ONE step.
    public func performUndoableTextChange(_ body: () -> Void) {
        if self.appliesTextInPlace {
            body()
            return
        }
        let before = NSAttributedString(attributedString: self.attributedText ?? NSAttributedString())
        let beforeSelection = self.selectedRange
        let previous = self.appliesTextInPlace
        self.appliesTextInPlace = true
        body()
        self.appliesTextInPlace = previous
        let after = self.attributedText ?? NSAttributedString()
        if before.isEqual(to: after) {
            return
        }
        self.registerTextRestore(text: before, selection: beforeSelection)
    }
    
    private func registerTextRestore(text: NSAttributedString, selection: NSRange) {
        guard let undoManager = self.undoManager else {
            return
        }
        undoManager.registerUndo(withTarget: self, handler: { target in
            target.restoreText(text, selection: selection)
        })
    }
    
    private func restoreText(_ text: NSAttributedString, selection: NSRange) {
        let current = NSAttributedString(attributedString: self.attributedText ?? NSAttributedString())
        let currentSelection = self.selectedRange
        let previous = self.appliesTextInPlace
        self.appliesTextInPlace = true
        self.attributedText = text
        let length = self.textStorage.length
        let location = min(selection.location, length)
        self.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
        self.textViewDidChange(self)
        self.appliesTextInPlace = previous
        // Registered while the undo manager is undoing (redoing), this lands on the redo (undo) stack.
        self.registerTextRestore(text: current, selection: currentSelection)
    }
    
    public weak var customDelegate: ChatInputTextNodeDelegate?
    
    public var theme: Theme? {
        didSet {
            if self.theme != oldValue {
                self.updateTextElements()
            }
        }
    }
    
    public var toggleQuoteCollapse: ((NSRange) -> Void)?
    public var onUpdateLayout: (() -> Void)?
    /// Fired once per insertion-animation frame. Intended ONLY for cheap per-frame
    /// work on decorations that are subviews rather than glyphs (custom emoji).
    /// Must not trigger layout or rect recomputation.
    public var onInsertionAnimationFrame: (() -> Void)?
        
    private let displayInternal: ChatInputTextInternal
    private let measureInternal: ChatInputTextInternal

    /// Configures the legacy renderer's optional insertion animation. The rich editor path ignores this.
    private var textAnimationConfigurationValue = ChatInputTextAnimationConfiguration()
    public var textAnimationConfiguration: ChatInputTextAnimationConfiguration {
        get {
            return self.textAnimationConfigurationValue
        }
        set {
            // The settings observer fires on EVERY app-wide UserDefaults write, so an
            // unchanged config must cost nothing: no relayout, no repaint, no overlay
            // recompute.
            if self.textAnimationConfigurationValue == newValue {
                return
            }
            self.textAnimationConfigurationValue = newValue
            self.displayInternal.animationConfiguration = newValue
            // measureInternal is deliberately NOT given the animation config: height
            // measurement must never animate or it jitters the panel height.
            self.displayInternal.invalidateLayout()
            self.setNeedsDisplay()
            self.updateSelectionOverlay(animated: false)
        }
    }

    // Kept above the text renderer and outside UIKit's selection/caret machinery.
    // This is intentionally a one-shot, small CAEmitterLayer rather than a custom
    // text view animation so deletion cannot interfere with input or selection.
    //
    // The emitter's own `frame` is clipped to the deleted-text rect (plus a
    // small margin) with `masksToBounds = true` so particles can never
    // visually paint over the caret, the selection highlight, or unrelated
    // text - the emitter used to be sized to the entire overlay view, which
    // let fast-moving particles travel across the whole input.
    private var deletionParticleLayer: CAEmitterLayer?
    /// Timestamp of the previous deletion, used to distinguish a held backspace
    /// (rapid repeats) from isolated presses for the particle effect.
    private var lastDeletionTimestamp: TimeInterval = 0.0
    // The cell is created once and its properties are mutated in place on every
    // subsequent burst. Reassigning `emitter.emitterCells` forces Core Animation's
    // render server to tear down and rebuild the whole particle system; during a
    // held/fast backspace this function runs once per deleted character, so doing
    // that unconditionally on every call was the dominant cause of the jank/lag.
    private var deletionParticleCell: CAEmitterCell?
    private var deletionParticleStopWorkItem: DispatchWorkItem?
    private var deletionParticleRemoveWorkItem: DispatchWorkItem?
    private let selectionOverlayView = ChatInputSelectionOverlayView()
    private var nativeTintColor: UIColor?

    /// Inputs that fully determine the overlay. `updateSelectionOverlay` is called
    /// from layoutSubviews AND setContentOffset (i.e. during every scroll frame), so
    /// it must not call the expensive UIKit geometry APIs unless something changed.
    private struct SelectionOverlayState: Equatable {
        var bounds: CGRect
        var contentOffset: CGPoint
        var contentSize: CGSize
        var selectedRange: NSRange
        /// Guards the case where the text changes but the selection does not
        /// (programmatic replacement), which still moves the caret.
        var textLength: Int
        var isFirstResponder: Bool
        var hasMarkedText: Bool
        var configuration: ChatInputTextAnimationConfiguration
    }
    private var lastSelectionOverlayState: SelectionOverlayState?

    /// Repaints only the pixels an in-flight insertion animation touches.
    /// `rect` is in text-container coordinates.
    private func setNeedsDisplayInAnimationRect(_ rect: CGRect) {
        guard !rect.isNull, !rect.isInfinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite else {
            self.setNeedsDisplay()
            return
        }
        let viewRect = rect.offsetBy(dx: self.textContainerInset.left, dy: self.textContainerInset.top)
        let clipped = viewRect.intersection(CGRect(origin: .zero, size: self.contentSize))
        if clipped.isNull || clipped.isEmpty {
            return
        }
        self.setNeedsDisplay(clipped)
    }

    private func updateSelectionOverlay(animated: Bool) {
        let configuration = self.textAnimationConfigurationValue
        let hasMarkedText = self.markedTextRange != nil

        let state = SelectionOverlayState(
            bounds: self.bounds,
            contentOffset: self.contentOffset,
            contentSize: self.contentSize,
            selectedRange: self.selectedRange,
            textLength: self.displayInternal.attributedString?.length ?? 0,
            isFirstResponder: self.isFirstResponder,
            hasMarkedText: hasMarkedText,
            configuration: configuration
        )
        // An animated call is an explicit request for a visible transition, so it is
        // never skipped; the idempotent layout/scroll-driven calls are.
        if !animated, self.lastSelectionOverlayState == state {
            return
        }
        self.lastSelectionOverlayState = state

        // The overlay is a subview of the scroll view. Its frame is therefore in
        // the text view's content coordinate space; converting the UIKit rects is
        // important when textContainerInset, zooming, or scrolling are involved.
        self.selectionOverlayView.frame = self.bounds
        let hasSelection = self.selectedRange.length != 0
        var selectionRects: [CGRect] = []
        if self.isFirstResponder, !hasMarkedText, hasSelection, let range = self.selectedTextRange {
            selectionRects = super.selectionRects(for: range).map { self.selectionOverlayView.convert($0.rect, from: self) }
        }
        let overlayColor = self.nativeTintColor ?? self.tintColor ?? .systemBlue
        self.selectionOverlayView.update(selectionRects: selectionRects, color: overlayColor, configuration: configuration, animated: animated && !UIAccessibility.isReduceMotionEnabled)
        let caretRect: CGRect
        if self.isFirstResponder, !hasMarkedText, !hasSelection {
            caretRect = self.selectionOverlayView.convert(self.caretRect(for: self.selectedTextRange?.end ?? self.beginningOfDocument), from: self)
        } else {
            caretRect = .null
        }
        self.selectionOverlayView.updateCaret(caretRect, color: overlayColor, configuration: configuration, animated: animated && !UIAccessibility.isReduceMotionEnabled)
        // Tint is the supported UIKit switch for the insertion caret. Only make it
        // transparent while our caret is actually visible; selection handles and
        // marked-text/IME rendering immediately regain UIKit's native tint.
        let customCaretActive = configuration.cursorEnabled && self.isFirstResponder && !hasMarkedText && !hasSelection && !caretRect.isNull
        if customCaretActive {
            if self.nativeTintColor == nil { self.nativeTintColor = self.tintColor }
            if self.tintColor != .clear { self.tintColor = .clear }
        } else if let nativeTintColor = self.nativeTintColor {
            self.nativeTintColor = nil
            self.tintColor = nativeTintColor
        }
    }

    private func beginDeletionParticleAnimation(for range: NSRange) {
        guard self.textAnimationConfigurationValue.deletionParticlesEnabled,
              !UIAccessibility.isReduceMotionEnabled,
              range.length > 0, range.length <= 64,
              self.displayInternal.textContainer.layoutManager != nil else {
            return
        }

        var rect = self.displayInternal.deletionRect(for: range)
        rect = rect.offsetBy(dx: self.textContainerInset.left, dy: self.textContainerInset.top)
        rect = self.selectionOverlayView.convert(rect, from: self)
        guard rect.isNull == false, rect.intersects(self.selectionOverlayView.bounds) else { return }
        // Clip to what is actually on-screen before using it as the mask rect below.
        rect = rect.intersection(self.selectionOverlayView.bounds)
        guard !rect.isEmpty else { return }

        // Clip the whole effect to the deleted-text rect (plus a small margin)
        // instead of the entire overlay view. The overlay also hosts the live
        // caret and selection-highlight layers, so a full-view-sized emitter
        // let particles visually travel across the caret and unrelated text;
        // only the birth location was constrained before, not where the
        // layer was actually allowed to paint.
        let margin: CGFloat = 6.0
        let maskFrame = rect.insetBy(dx: -margin, dy: -margin).intersection(self.selectionOverlayView.bounds)
        guard !maskFrame.isEmpty else { return }

        // Reuse one emitter layer AND one cell across bursts. Reassigning
        // `emitterCells` on an already-running emitter forces Core Animation's
        // render server to tear down and rebuild the whole particle system;
        // fast/held backspacing invokes this once per deleted character, so
        // doing that unconditionally on every call (as before) was the
        // dominant cause of the visible stutter. From here on, only geometry
        // is re-set each call - the cell's own parameters are mutated in
        // place instead of being replaced.
        let emitter: CAEmitterLayer
        let cell: CAEmitterCell
        if let currentEmitter = self.deletionParticleLayer, let currentCell = self.deletionParticleCell {
            emitter = currentEmitter
            cell = currentCell
        } else {
            emitter = CAEmitterLayer()
            emitter.emitterShape = .rectangle
            emitter.emitterMode = .surface
            emitter.renderMode = .oldestLast
            // Hard-clip the layer's own painted region to its frame so the
            // mask below is not just advisory.
            emitter.masksToBounds = true
            cell = CAEmitterCell()
            cell.contents = Self.deletionParticleImage.cgImage
            emitter.emitterCells = [cell]
            self.selectionOverlayView.layer.addSublayer(emitter)
            self.deletionParticleLayer = emitter
            self.deletionParticleCell = cell
        }

        // This is a bare CALayer sublayer, not a UIView's own `.layer`, so it has
        // no delegate to answer Core Animation's implicit-action lookup the way
        // UIKit wires up for view-backed layers. Without this, every property
        // write below (frame/emitterPosition/emitterSize/birthRate) implicitly
        // animates with CA's default ~0.25s curve; during fast/held backspacing
        // a new burst's geometry/birthRate change would still be interpolating
        // from the previous call when the next one landed, stacking overlapping
        // transitions - the actual mechanism behind both the reported stutter
        // and the mask rect appearing to drift/smear instead of snapping.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        emitter.frame = maskFrame
        // emitterPosition/emitterSize are expressed in the emitter layer's own
        // coordinate space. That space now starts at maskFrame.origin instead
        // of (0, 0) in the overlay view, so the deletion rect has to be
        // re-expressed relative to the (now much smaller) frame.
        let localRect = rect.offsetBy(dx: -maskFrame.origin.x, dy: -maskFrame.origin.y)
        emitter.emitterPosition = CGPoint(x: localRect.midX, y: localRect.midY)
        emitter.emitterSize = CGSize(width: max(4.0, localRect.width), height: max(4.0, localRect.height))
        emitter.seed = UInt32.random(in: 0 ... UInt32.max)

        let configuration = self.textAnimationConfigurationValue
        // Deliberately ~10x subtler than the original burst: at most one or two
        // small, short-lived motes per deleted character instead of a spray.
        cell.birthRate = Float(max(1, configuration.deletionParticleCount / 10)) / 0.08
        cell.lifetime = 0.3
        cell.lifetimeRange = 0.08
        cell.velocity = 8.0 + 0.3 * CGFloat(configuration.deletionParticleSpeed)
        cell.velocityRange = 3.0 + 0.25 * CGFloat(configuration.deletionParticleSpread)
        cell.emissionLongitude = -.pi / 2.0
        cell.emissionRange = .pi * 2.0 * CGFloat(configuration.deletionParticleSpread) / 100.0
        let particleScale = 0.07 + 0.0045 * CGFloat(configuration.deletionParticleSize)
        cell.scale = particleScale
        cell.scaleRange = particleScale * 0.35
        // Shrinking the particle in step with its fade reads as a soft
        // dissolve instead of a flat shape blinking out; same total
        // lifetime as before, just a less cheap-looking exit.
        cell.scaleSpeed = -particleScale / CGFloat(cell.lifetime)
        // The cell is reused across calls, so every branch (including the
        // default) must set contents explicitly - otherwise switching the
        // style setting back to "dot" after a burst already rendered
        // "square"/"star" would silently keep showing the old shape.
        switch configuration.deletionParticleStyle {
        case 1:
            cell.contents = Self.deletionParticleSquareImage.cgImage
        case 2:
            cell.contents = Self.deletionParticleStarImage.cgImage
        default:
            cell.contents = Self.deletionParticleImage.cgImage
        }
        cell.alphaSpeed = -2.4
        cell.spinRange = 0.8
        cell.yAcceleration = 6.0
        emitter.birthRate = 1.0
        CATransaction.commit()

        // Both teardown steps are tracked so a new burst cancels the pending ones
        // instead of having them fight over a shared layer.
        self.deletionParticleStopWorkItem?.cancel()
        self.deletionParticleRemoveWorkItem?.cancel()

        // A zero birth rate after the initial burst prevents a repeating effect.
        let stopItem = DispatchWorkItem { [weak self] in
            guard let self, self.deletionParticleLayer === emitter else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            emitter.birthRate = 0.0
            CATransaction.commit()
        }
        self.deletionParticleStopWorkItem = stopItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: stopItem)

        let removeItem = DispatchWorkItem { [weak self] in
            guard let self, self.deletionParticleLayer === emitter else { return }
            emitter.removeFromSuperlayer()
            self.deletionParticleLayer = nil
            self.deletionParticleCell = nil
            self.deletionParticleStopWorkItem = nil
            self.deletionParticleRemoveWorkItem = nil
        }
        self.deletionParticleRemoveWorkItem = removeItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: removeItem)
    }

    private static let deletionParticleImage: UIImage = {
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
            context.cgContext.move(to: CGPoint(x: 0, y: 4)); context.cgContext.addLine(to: CGPoint(x: 8, y: 4)); context.cgContext.strokePath()
        }
    }()
    
    private var validLayoutSize: CGSize?
    private var isUpdatingLayout: Bool = false
    
    private var blockQuotes: [Int: QuoteBackgroundView] = [:]
    
    public var defaultTextContainerInset: UIEdgeInsets = UIEdgeInsets() {
        didSet {
            if self.defaultTextContainerInset != oldValue {
                self.updateTextContainerInset()
            }
        }
    }
    
    public var currentRightInset: CGFloat {
        return self.displayInternal.textContainer.rightInset
    }
    
    private var didInitializePrimaryInputLanguage: Bool = false
    public var initialPrimaryLanguage: String?
    
    private var selectionChangedForEditedText: Bool = false
    
    override public var textInputMode: UITextInputMode? {
        if !self.didInitializePrimaryInputLanguage {
            self.didInitializePrimaryInputLanguage = true
            if let initialPrimaryLanguage = self.initialPrimaryLanguage {
                for inputMode in UITextInputMode.activeInputModes {
                    if let primaryLanguage = inputMode.primaryLanguage, primaryLanguage == initialPrimaryLanguage {
                        return inputMode
                    }
                }
            }
        }
        return super.textInputMode
    }
    
    override public var bounds: CGRect {
        didSet {
            assert(true)
        }
    }
    
    public init(disableTiling: Bool) {
        self.displayInternal = ChatInputTextLegacyInternal()
        self.measureInternal = ChatInputTextLegacyInternal()
        
        super.init(frame: CGRect(), textContainer: self.displayInternal.textContainer, disableTiling: disableTiling)
        
        self.delegate = self
        self.scrollsToTop = false
        
        if #available(iOS 18.0, *) {
            self.supportsAdaptiveImageGlyph = false
        }
        
        self.displayInternal.updateDisplayElements = { [weak self] in
            guard let self else {
                return
            }
            self.updateTextElements()
            self.setNeedsDisplay()
        }

        // Per-frame animation repaint. Deliberately does NOT call
        // updateTextElements(): blockquote frames and custom-emoji rects cannot
        // change mid-insertion-animation, and recomputing them every frame was the
        // dominant cost of the old implementation.
        self.displayInternal.invalidateAnimationRect = { [weak self] damageRect in
            guard let self else {
                return
            }
            self.setNeedsDisplayInAnimationRect(damageRect)
            self.onInsertionAnimationFrame?()
        }
        
        self.shouldRespondToAction = { [weak self] action in
            guard let self, let action else {
                return false
            }
            if let delegate = self.customDelegate {
                return delegate.chatInputTextNodeShouldRespondToAction(action: action)
            } else {
                return true
            }
        }
        self.targetForAction = { [weak self] action in
            guard let self, let action else {
                return nil
            }
            if let delegate = self.customDelegate {
                return delegate.chatInputTextNodeTargetForAction(action: action).flatMap { value in
                    return ChatInputTextViewImplTargetForAction(target: value.target)
                }
            } else {
                return nil
            }
        }
        
        self.textContainerInset = UIEdgeInsets()
        self.backgroundColor = nil
        self.isOpaque = false
        self.addSubview(self.selectionOverlayView)
        
        self.dropAutocorrectioniOS16 = { [weak self] in
            guard let self else {
                return
            }
            
            self.isPreservingSelection = true
            self.isPreservingText = true
            
            let rangeCopy = self.selectedRange
            var fakeRange = rangeCopy
            if fakeRange.location != 0 {
                fakeRange.location -= 1
            }
            self.unmarkText()
            self.selectedRange = fakeRange
            self.selectedRange = rangeCopy
            
            self.isPreservingSelection = false
            self.isPreservingText = false
        }
        
        self.shouldCopy = { [weak self] in
            guard let self else {
                return true
            }
            return self.customDelegate?.chatInputTextNodeShouldCopy() ?? true
        }
        self.shouldPaste = { [weak self] in
            guard let self else {
                return true
            }
            return self.customDelegate?.chatInputTextNodeShouldPaste() ?? true
        }
        self.shouldReturn = { [weak self] modifierFlags in
            guard let self else {
                return true
            }
            return self.customDelegate?.chatInputTextNodeShouldReturn(modifierFlags: modifierFlags) ?? true
        }
        self.backspaceWhileEmpty = { [weak self] in
            guard let self else {
                return
            }
            self.customDelegate?.chatInputTextNodeBackspaceWhileEmpty()
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.deletionParticleStopWorkItem?.cancel()
        self.deletionParticleRemoveWorkItem?.cancel()
    }
    
    override public func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        var rect = rect
        if rect.maxY > self.contentSize.height - 8.0 {
            rect = CGRect(origin: CGPoint(x: rect.minX, y: self.contentSize.height - 1.0), size: CGSize(width: rect.width, height: 1.0))
        }
        
        var animated = animated
        if self.isUpdatingLayout {
            animated = false
        }
        
        super.scrollRectToVisible(rect, animated: animated)
    }
    
    @objc public func textViewDidBeginEditing(_ textView: UITextView) {
        self.updateSelectionOverlay(animated: false)
        self.customDelegate?.chatInputTextNodeDidBeginEditing()
    }

    @objc public func textViewDidEndEditing(_ textView: UITextView) {
            self.updateSelectionOverlay(animated: false)
        self.customDelegate?.chatInputTextNodeDidFinishEditing()
    }

    @objc public func textViewDidChange(_ textView: UITextView) {
        self.selectionChangedForEditedText = true
                
        self.updateTextContainerInset()
        self.updateSelectionOverlay(animated: true)
        
        self.customDelegate?.chatInputTextNodeDidUpdateText()
        
        self.updateTextContainerInset()
    }

    @objc public func textViewDidChangeSelection(_ textView: UITextView) {
        if self.isPreservingSelection {
            return
        }
        
        self.selectionChangedForEditedText = false
        self.updateSelectionOverlay(animated: true)
        
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.customDelegate?.chatInputTextNodeDidChangeSelection(dueToEditing: self.selectionChangedForEditedText)
        }
    }

    @available(iOS 16.0, *)
    @objc public func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        return self.customDelegate?.chatInputTextNodeMenu(forTextRange: range, suggestedActions: suggestedActions)
    }
    
    @objc public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // Capture the pre-edit geometry. UIKit applies the deletion after this
        // callback, so the overlay never participates in text storage or caret
        // placement.
        guard let customDelegate = self.customDelegate else {
            if text.isEmpty, range.length > 0 {
                self.registerDeletion(for: range)
            }
            return true
        }
        if self.isPreservingText {
            return false
        }
        let shouldChange = customDelegate.chatInputTextNode(shouldChangeTextIn: range, replacementText: text)
        if shouldChange, text.isEmpty, range.length > 0 {
            self.registerDeletion(for: range)
        }
        return shouldChange
    }

    /// Particles only fire for a HELD backspace (iOS key repeat emits a
    /// deletion roughly every 33ms after the initial delay). A single, isolated
    /// press deletes cleanly with no effect.
    private func registerDeletion(for range: NSRange) {
        let now = CACurrentMediaTime()
        let isHeldRepeat = now - self.lastDeletionTimestamp < 0.3
        self.lastDeletionTimestamp = now
        if isHeldRepeat {
            self.beginDeletionParticleAnimation(for: range)
        }
    }
    
    public func updateTextContainerInset() {
        self.displayInternal.defaultTextContainerInset = self.defaultTextContainerInset
        self.measureInternal.defaultTextContainerInset = self.defaultTextContainerInset
        
        var result = self.defaultTextContainerInset
        
        var horizontalInsetsUpdated = false
        if self.displayInternal.textContainer.rightInset != result.right {
            horizontalInsetsUpdated = true
            self.displayInternal.textContainer.rightInset = result.right
        }
        
        result.left = 0.0
        result.right = 0.0
        
        if let string = self.displayInternal.attributedString, string.length != 0 {
            let topAttributes = string.attributes(at: 0, effectiveRange: nil)
            let bottomAttributes = string.attributes(at: string.length - 1, effectiveRange: nil)
            
            if topAttributes[NSAttributedString.Key("Attribute__Blockquote")] != nil {
                result.top += 7.0
            }
            if bottomAttributes[NSAttributedString.Key("Attribute__Blockquote")] != nil {
                result.bottom += 8.0
            }
        }
        
        if self.textContainerInset != result {
            self.textContainerInset = result
        }
        if horizontalInsetsUpdated {
            self.displayInternal.invalidateLayout()
        }
        
        self.updateTextElements()
    }
    
    public func textHeightForWidth(_ width: CGFloat, rightInset: CGFloat) -> CGFloat {
        let measureSize = CGSize(width: width, height: 1000000.0)
        
        let measureText: NSAttributedString
        if let attributedText = self.attributedText, attributedText.length != 0 {
            measureText = attributedText
        } else {
            measureText = NSAttributedString(string: "A", attributes: self.typingAttributes)
        }
        
        if self.measureInternal.attributedString != measureText || self.measureInternal.textContainer.size != measureSize || self.measureInternal.textContainer.rightInset != rightInset {
            self.measureInternal.textContainer.rightInset = rightInset
            self.measureInternal.setAttributedString(attributedString: measureText)
            self.measureInternal.textContainer.size = measureSize
            self.measureInternal.invalidateLayout()
        }
        
        let textSize = self.measureInternal.textSize()
        
        return ceil(textSize.height + self.textContainerInset.top + self.textContainerInset.bottom)
    }
    
    public func updateLayout(size: CGSize) {
        let measureSize = CGSize(width: size.width, height: 1000000.0)
        
        if self.textContainer.size != measureSize {
            self.textContainer.size = measureSize
            self.displayInternal.invalidateLayout()
        }
    }
    
    override public func setNeedsLayout() {
        super.setNeedsLayout()
    }
    
    override public func layoutSubviews() {
        let isLayoutUpdated = self.validLayoutSize != self.bounds.size
        self.validLayoutSize = self.bounds.size
        
        self.isUpdatingLayout = isLayoutUpdated
        
        super.layoutSubviews()
        self.bringSubviewToFront(self.selectionOverlayView)
        self.updateSelectionOverlay(animated: false)
        
        self.isUpdatingLayout = false
    }

    override public func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        super.setContentOffset(contentOffset, animated: animated)
        self.updateSelectionOverlay(animated: false)
    }
    
    public func currentTextBoundingRect() -> CGRect {
        return self.displayInternal.currentTextBoundingRect()
    }
    
    public func lastLineBoundingRect() -> CGRect {
        return self.displayInternal.currentTextLastLineBoundingRect()
    }

    /// Current insertion-animation state for a character range, so decorations that
    /// are real subviews rather than glyphs (custom emoji) can match the text
    /// timeline exactly instead of popping in while the text around them fades.
    /// Returns nil when nothing is animating at that range.
    public func insertionAnimationState(forCharacterRange range: NSRange) -> (progress: CGFloat, slideDistance: CGFloat, scaleStart: CGFloat?)? {
        return self.displayInternal.insertionAnimationState(forCharacterRange: range)
    }
    
    public func updateTextElements() {
        var validBlockQuotes: [Int] = []
        for displayBlockQuote in self.displayInternal.displayBlockQuotes() {
            let blockQuote: QuoteBackgroundView
            if let current = self.blockQuotes[displayBlockQuote.id] {
                blockQuote = current
            } else {
                blockQuote = QuoteBackgroundView(toggleCollapse: { [weak self] range in
                    guard let self else {
                        return
                    }
                    self.toggleQuoteCollapse?(range)
                })
                self.blockQuotes[displayBlockQuote.id] = blockQuote
                self.insertSubview(blockQuote, at: 0)
            }
            
            blockQuote.frame = displayBlockQuote.boundingRect
            if let theme = self.theme {
                blockQuote.update(kind: displayBlockQuote.kind, isCollapsed: displayBlockQuote.isCollapsed, range: displayBlockQuote.range, size: displayBlockQuote.boundingRect.size, theme: theme.quote)
            }
            
            validBlockQuotes.append(displayBlockQuote.id)
        }
        
        var removedBlockQuotes: [Int] = []
        for (id, blockQuote) in self.blockQuotes {
            if !validBlockQuotes.contains(id) {
                removedBlockQuotes.append(id)
                blockQuote.removeFromSuperview()
            }
        }
        for id in removedBlockQuotes {
            self.blockQuotes.removeValue(forKey: id)
        }
        
        self.onUpdateLayout?()
    }
    
    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.bounds.contains(point) {
            for (_, blockQuote) in self.blockQuotes {
                if let result = blockQuote.collapseButton.hitTest(self.convert(point, to: blockQuote.collapseButton), with: event) {
                    return result
                }
            }
        }
        
        let result = super.hitTest(point, with: event)
        return result
    }
}

private let quoteIcon: UIImage = {
    return UIImage(bundleImageName: "Chat/Message/ReplyQuoteIcon")!.precomposed().withRenderingMode(.alwaysTemplate)
}()

private let quoteCollapseImage: UIImage = {
    return UIImage(bundleImageName: "Media Gallery/Minimize")!.precomposed().withRenderingMode(.alwaysTemplate)
}()

private let quoteExpandImage: UIImage = {
    return UIImage(bundleImageName: "Media Gallery/Fullscreen")!.precomposed().withRenderingMode(.alwaysTemplate)
}()

private final class QuoteBackgroundView: UIView {
    private let toggleCollapse: (NSRange) -> Void
    
    private let backgroundView: MessageInlineBlockBackgroundView
    private let iconView: UIImageView
    let collapseButton: UIView
    let collapseButtonIconView: UIImageView
    
    private var range: NSRange?
    private var theme: ChatInputTextView.Theme.Quote?
    
    init(toggleCollapse: @escaping (NSRange) -> Void) {
        self.toggleCollapse = toggleCollapse
        
        self.backgroundView = MessageInlineBlockBackgroundView()
        self.iconView = UIImageView(image: quoteIcon)
        
        self.collapseButton = UIView()
        self.collapseButtonIconView = UIImageView()
        self.collapseButton.addSubview(self.collapseButtonIconView)
        
        super.init(frame: CGRect())
        
        self.addSubview(self.backgroundView)
        self.addSubview(self.iconView)
        self.addSubview(self.collapseButton)
        
        self.collapseButton.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.toggleCollapsedTapped(_:))))
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc private func toggleCollapsedTapped(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            if let range = self.range {
                self.toggleCollapse(range)
            }
        }
    }
    
    func update(kind: ChatTextInputTextQuoteAttribute.Kind, isCollapsed: Bool, range: NSRange, size: CGSize, theme: ChatInputTextView.Theme.Quote) {
        self.range = range
        
        if self.theme != theme {
            self.theme = theme
            
            self.iconView.tintColor = theme.foreground
            self.collapseButtonIconView.tintColor = theme.foreground
        }
        
        self.iconView.frame = CGRect(origin: CGPoint(x: size.width - 4.0 - quoteIcon.size.width, y: 4.0), size: quoteIcon.size)
        
        let collapseButtonSize = CGSize(width: 18.0, height: 18.0)
        
        if isCollapsed {
            self.collapseButtonIconView.image = quoteExpandImage
            self.collapseButton.frame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: size)
        } else {
            self.collapseButtonIconView.image = quoteCollapseImage
            self.collapseButton.frame = CGRect(origin: CGPoint(x: size.width - 2.0 - collapseButtonSize.width, y: 2.0), size: collapseButtonSize)
        }
        if let image = self.collapseButtonIconView.image {
            let iconSize = image.size.aspectFitted(collapseButtonSize)
            self.collapseButtonIconView.frame = CGRect(origin: CGPoint(x: self.collapseButton.bounds.width - 4.0 - collapseButtonSize.width + floorToScreenPixels((collapseButtonSize.width - iconSize.width) * 0.5), y: 4.0 + floorToScreenPixels((collapseButtonSize.height - iconSize.height) * 0.5)), size: iconSize)
        }
        
        var primaryColor: UIColor
        var secondaryColor: UIColor?
        var tertiaryColor: UIColor?
        let backgroundColor: UIColor?
        
        switch kind {
        case .quote:
            if size.height >= 60.0 || isCollapsed {
                self.iconView.isHidden = true
                self.collapseButton.isHidden = false
            } else {
                self.iconView.isHidden = false
                self.collapseButton.isHidden = true
            }
            
            switch theme.lineStyle {
            case let .solid(color):
                primaryColor = color
            case let .doubleDashed(mainColor, secondaryColorValue):
                primaryColor = mainColor
                secondaryColor = secondaryColorValue
            case let .tripleDashed(mainColor, secondaryColorValue, tertiaryColorValue):
                primaryColor = mainColor
                secondaryColor = secondaryColorValue
                tertiaryColor = tertiaryColorValue
            }
            
            backgroundColor = nil
        case .code:
            self.iconView.isHidden = true
            self.collapseButton.isHidden = true
            
            primaryColor = theme.codeForeground
            backgroundColor = theme.codeBackground
        }
        
        self.backgroundView.update(
            size: size,
            isTransparent: false,
            primaryColor: primaryColor,
            secondaryColor: secondaryColor,
            thirdColor: tertiaryColor,
            backgroundColor: backgroundColor,
            pattern: nil,
            animation: .None
        )
        self.backgroundView.frame = CGRect(origin: CGPoint(), size: size)
    }
}
