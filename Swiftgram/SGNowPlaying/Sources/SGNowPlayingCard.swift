import Foundation
import UIKit
import CoreText
import QrCode

/// Renders the "send as card" image for the Now Playing send menu — a native
/// port of reSwaga's `utils/card_utils.py` (horizontal / vertical variants,
/// blurred-cover or accent-color background, YS Music / Onest fonts, optional
/// song.link line). The original's "СуперSwaG" variant is not ported.
public enum SGNowPlayingCard {

    /// Renders the card for `track` on a background queue and calls back on
    /// the main queue. `nil` only if rendering itself fails.
    public static func render(
        track: SGNowPlayingTrack,
        settings: SGNowPlayingSettings,
        completion: @escaping (UIImage?) -> Void
    ) {
        SGNowPlayingClient.shared.artworkData(from: track.artworkURL) { artworkData in
            DispatchQueue.global(qos: .userInitiated).async {
                let image = Self.renderSynchronously(track: track, settings: settings, artworkData: artworkData)
                DispatchQueue.main.async {
                    completion(image)
                }
            }
        }
    }

    /// The link appended to text sends and drawn on the card: the platform's
    /// own track URL when known, otherwise a song.link route (when enabled).
    public static func trackLink(track: SGNowPlayingTrack, settings: SGNowPlayingSettings) -> String? {
        if let link = track.link, !link.isEmpty {
            return link
        }
        if settings.useSongLink, let platform = track.platform, let code = platform.songLinkCode, !track.id.isEmpty {
            return "https://song.link/\(code)/\(track.id)"
        }
        return nil
    }

    // MARK: - Rendering

    static func renderSynchronously(track: SGNowPlayingTrack, settings: SGNowPlayingSettings, artworkData: Data?) -> UIImage? {
        let artwork = artworkData.flatMap { UIImage(data: $0) }
        let accentColor = artwork.flatMap(Self.accentColor(from:))

        let size: CGSize
        switch settings.cardType {
        case .horizontal:
            size = CGSize(width: 1024.0, height: 512.0)
        case .vertical:
            size = CGSize(width: 768.0, height: 1024.0)
        }

        let titleFont = Self.font(for: settings.cardFont, bold: true, size: settings.cardType == .horizontal ? 54.0 : 62.0)
        let artistFont = Self.font(for: settings.cardFont, bold: false, size: settings.cardType == .horizontal ? 42.0 : 48.0)
        let metaFont = Self.font(for: settings.cardFont, bold: false, size: 28.0)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor(white: 0.11, alpha: 1.0).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))

            // Background.
            switch settings.cardBackground {
            case .trackCover:
                if let blurred = Self.blurredBackground(artwork: artwork, size: size) {
                    cg.saveGState()
                    cg.clip(to: CGRect(origin: .zero, size: size))
                    cg.draw(blurred, in: CGRect(origin: .zero, size: size))
                    cg.restoreGState()
                    cg.setFillColor(UIColor(white: 0.0, alpha: 0.42).cgColor)
                    cg.fill(CGRect(origin: .zero, size: size))
                } else {
                    cg.setFillColor((accentColor ?? UIColor(white: 0.16, alpha: 1.0)).cgColor)
                    cg.fill(CGRect(origin: .zero, size: size))
                }
            case .accentColor:
                cg.setFillColor((accentColor ?? UIColor(white: 0.16, alpha: 1.0)).cgColor)
                cg.fill(CGRect(origin: .zero, size: size))
                // A subtle darkening keeps white text readable on bright covers.
                cg.setFillColor(UIColor(white: 0.0, alpha: 0.18).cgColor)
                cg.fill(CGRect(origin: .zero, size: size))
            }

            let title = track.title
            let artist = track.artistText
            let link = Self.trackLink(track: track, settings: settings)

            func drawText(_ text: String, font: UIFont, color: UIColor = .white, alignment: NSTextAlignment, in rect: CGRect, maxLines: Int) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = alignment
                paragraph.lineBreakMode = .byTruncatingTail
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraph,
                    .shadow: NSShadow()
                ]
                if let shadow = attributes[.shadow] as? NSShadow {
                    shadow.shadowColor = UIColor(white: 0.0, alpha: 0.45)
                    shadow.shadowOffset = CGSize(width: 0.0, height: 2.0)
                    shadow.shadowBlurRadius = 6.0
                }
                let attributed = NSAttributedString(string: text, attributes: attributes)
                let bounds = attributed.boundingRect(
                    with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
                let lineHeight = font.lineHeight
                let clampedHeight = min(bounds.height, lineHeight * CGFloat(maxLines) + 1.0)
                let drawRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: clampedHeight)
                attributed.draw(in: drawRect)
            }

            /// The card's text under the cover mirrors the text send mode
            /// exactly — "Title — Artist" as one flowing paragraph — with the
            /// title bold and the dash + artist slightly dimmed.
            func drawTrackText(_ text: String, artistText: String, titleFont: UIFont, artistFont: UIFont, artistColor: UIColor, alignment: NSTextAlignment, in rect: CGRect, maxLines: Int) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = alignment
                paragraph.lineBreakMode = .byTruncatingTail
                let shadow = NSShadow()
                shadow.shadowColor = UIColor(white: 0.0, alpha: 0.45)
                shadow.shadowOffset = CGSize(width: 0.0, height: 2.0)
                shadow.shadowBlurRadius = 6.0
                let attributed = NSMutableAttributedString(string: text, attributes: [
                    .font: titleFont,
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph,
                    .shadow: shadow
                ])
                attributed.append(NSAttributedString(string: " — \(artistText)", attributes: [
                    .font: artistFont,
                    .foregroundColor: artistColor,
                    .paragraphStyle: paragraph,
                    .shadow: shadow
                ]))
                let bounds = attributed.boundingRect(
                    with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
                let lineHeight = titleFont.lineHeight
                let clampedHeight = min(bounds.height, lineHeight * CGFloat(maxLines) + 1.0)
                attributed.draw(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: clampedHeight))
            }

            switch settings.cardType {
            case .horizontal:
                let artSide: CGFloat = 360.0
                let artRect = CGRect(x: 64.0, y: (size.height - artSide) / 2.0, width: artSide, height: artSide)
                Self.drawCover(artwork: artwork, accentColor: accentColor, in: artRect, radius: 36.0, cg: cg)
                let textX = artRect.maxX + 52.0
                let textWidth = size.width - textX - 56.0
                drawTrackText(title, artistText: artist, titleFont: titleFont, artistFont: artistFont, artistColor: UIColor(white: 1.0, alpha: 0.82), alignment: .left, in: CGRect(x: textX, y: 116.0, width: textWidth, height: 0.0), maxLines: 3)
                if let link {
                    if settings.cardLinkStyle == .qrCode {
                        Self.drawQR(link: link, in: CGRect(x: size.width - 56.0 - 132.0, y: 332.0, width: 132.0, height: 132.0), cg: cg)
                    } else {
                        drawText(link, font: metaFont, color: UIColor(white: 1.0, alpha: 0.62), alignment: .left, in: CGRect(x: textX, y: size.height - 96.0, width: textWidth, height: 0.0), maxLines: 1)
                    }
                }
            case .vertical:
                let artSide: CGFloat = 512.0
                let artRect = CGRect(x: (size.width - artSide) / 2.0, y: 80.0, width: artSide, height: artSide)
                Self.drawCover(artwork: artwork, accentColor: accentColor, in: artRect, radius: 44.0, cg: cg)
                let inset: CGFloat = 64.0
                let textWidth = size.width - inset * 2.0
                drawTrackText(title, artistText: artist, titleFont: titleFont, artistFont: artistFont, artistColor: UIColor(white: 1.0, alpha: 0.82), alignment: .center, in: CGRect(x: inset, y: artRect.maxY + 64.0, width: textWidth, height: 0.0), maxLines: 2)
                if let link {
                    if settings.cardLinkStyle == .qrCode {
                        Self.drawQR(link: link, in: CGRect(x: (size.width - 108.0) / 2.0, y: 856.0, width: 108.0, height: 108.0), cg: cg)
                    } else {
                        drawText(link, font: metaFont, color: UIColor(white: 1.0, alpha: 0.62), alignment: .center, in: CGRect(x: inset, y: size.height - 88.0, width: textWidth, height: 0.0), maxLines: 1)
                    }
                }
            }
        }
    }

    /// Small in-theme QR tile that replaces the textual link line: a rounded
    /// white plate with the card's text shadow and dark modules, with a
    /// built-in quiet zone. Generation goes through the shared QrCode module's
    /// software path (no GPU involvement).
    private static func drawQR(link: String, in rect: CGRect, cg: CGContext) {
        guard let matrix = qrCodeMatrix(string: link, ecl: "M") else {
            return
        }
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0.0, height: 2.0), blur: 6.0, color: UIColor(white: 0.0, alpha: 0.45).cgColor)
        let plate = UIBezierPath(roundedRect: rect, cornerRadius: rect.width * 0.16)
        cg.setFillColor(UIColor(white: 1.0, alpha: 0.94).cgColor)
        cg.addPath(plate.cgPath)
        cg.fillPath()
        cg.restoreGState()
        let quiet = 2
        let moduleSide = min(rect.width, rect.height) / (CGFloat(matrix.size) + CGFloat(quiet * 2))
        let codeSide = CGFloat(matrix.size) * moduleSide
        let origin = CGPoint(x: rect.midX - codeSide / 2.0, y: rect.midY - codeSide / 2.0)
        cg.setFillColor(UIColor(white: 0.11, alpha: 1.0).cgColor)
        for y in 0 ..< matrix.size {
            for x in 0 ..< matrix.size where matrix[x, y] {
                cg.fill(CGRect(
                    x: origin.x + CGFloat(x) * moduleSide,
                    y: origin.y + CGFloat(y) * moduleSide,
                    width: moduleSide + 0.5,
                    height: moduleSide + 0.5
                ))
            }
        }
    }

    private static func drawCover(artwork: UIImage?, accentColor: UIColor?, in rect: CGRect, radius: CGFloat, cg: CGContext) {
        cg.saveGState()
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        cg.addPath(path.cgPath)
        cg.clip()
        if let artwork {
            let imageSize = artwork.size
            if imageSize.width > 0, imageSize.height > 0 {
                let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
                let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                let origin = CGPoint(x: rect.midX - drawSize.width / 2.0, y: rect.midY - drawSize.height / 2.0)
                artwork.draw(in: CGRect(origin: origin, size: drawSize))
            }
        } else {
            cg.setFillColor((accentColor ?? UIColor(white: 0.2, alpha: 1.0)).cgColor)
            cg.fill(rect)
            // Music-note placeholder, mirroring the streamer's blank-cover path.
            let note = "♪"
            let font = UIFont.systemFont(ofSize: rect.width * 0.4)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(white: 1.0, alpha: 0.5)]
            let noteSize = (note as NSString).size(withAttributes: attributes)
            (note as NSString).draw(at: CGPoint(x: rect.midX - noteSize.width / 2.0, y: rect.midY - noteSize.height / 2.0), withAttributes: attributes)
        }
        cg.restoreGState()
    }

    /// Aspect-fill + blurred background, over-scaled ~12% so edges never bleed
    /// into the crop. The blur is a downscale→upscale pass instead of
    /// CoreImage's GPU blur, which produced artifacts ("gray mush") on the
    /// simulator; this path is pure CPU drawing and looks identical.
    private static func blurredBackground(artwork: UIImage?, size: CGSize) -> CGImage? {
        guard let artwork else {
            return nil
        }
        let overscan = 1.14
        let scaledSize = CGSize(width: size.width * overscan, height: size.height * overscan)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        // Pass 1: draw the artwork aspect-filled into a tiny buffer (~1/24 of
        // the card width — visually equivalent to a radius-42 Gaussian).
        let tinyWidth = max(8.0, (scaledSize.width / 24.0).rounded())
        let tinySize = CGSize(width: tinyWidth, height: (tinyWidth * scaledSize.height / scaledSize.width).rounded())
        let tinyRenderer = UIGraphicsImageRenderer(size: tinySize, format: format)
        let tiny = tinyRenderer.image { _ in
            let imageSize = artwork.size
            guard imageSize.width > 0, imageSize.height > 0 else {
                return
            }
            let scale = max(tinySize.width / imageSize.width, tinySize.height / imageSize.height)
            let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            artwork.draw(in: CGRect(origin: CGPoint(x: (tinySize.width - drawSize.width) / 2.0, y: (tinySize.height - drawSize.height) / 2.0), size: drawSize))
        }
        guard let tinyImage = tiny.cgImage else {
            return nil
        }
        // Pass 2: upscale back to full size — interpolation turns the tiny
        // buffer into a smooth blur.
        let fullRenderer = UIGraphicsImageRenderer(size: scaledSize, format: format)
        let blurred = fullRenderer.image { context in
            context.cgContext.interpolationQuality = .medium
            context.cgContext.draw(tinyImage, in: CGRect(origin: .zero, size: scaledSize))
        }
        guard let full = blurred.cgImage else {
            return nil
        }
        // Crop to the card size (the overscan only existed for blur bleed).
        return full.cropping(to: CGRect(origin: .zero, size: size)) ?? full
    }

    // MARK: - Accent color (reSwaga's get_cover_accent_color + readability clamp)

    static func accentColor(from image: UIImage) -> UIColor? {
        let side = 40
        guard let cgImage = image.cgImage else {
            return nil
        }
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else {
            return nil
        }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let bytesPerPixel = 4
        var totalR = 0.0, totalG = 0.0, totalB = 0.0
        var count = 0.0
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * bytesPerPixel
                totalR += Double(bytes[offset])
                totalG += Double(bytes[offset + 1])
                totalB += Double(bytes[offset + 2])
                count += 1.0
            }
        }
        guard count > 0 else {
            return nil
        }
        var hue: CGFloat = 0.0
        var saturation: CGFloat = 0.0
        var brightness: CGFloat = 0.0
        var alpha: CGFloat = 0.0
        UIColor(
            red: CGFloat(totalR / count / 255.0),
            green: CGFloat(totalG / count / 255.0),
            blue: CGFloat(totalB / count / 255.0),
            alpha: 1.0
        ).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // adjust_color_for_readability: keep the hue, lift weak saturation so
        // grayscale covers still get a colored background, and clamp brightness
        // into a band where white card text stays readable.
        saturation = max(0.30, min(saturation, 0.75))
        brightness = max(0.24, min(brightness, 0.42))
        return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1.0)
    }

    // MARK: - Fonts

    private static let fontLock = NSLock()
    private static var loadedFontNames: [String: String] = [:]
    private static var fontsRegistered = false

    static func font(for family: SGNowPlayingCardFont, bold: Bool, size: CGFloat) -> UIFont {
        let name = Self.registeredFontName(for: family, bold: bold)
        if let name, let font = UIFont(name: name, size: size) {
            return font
        }
        return bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
    }

    /// Resolves (and lazily registers) the PostScript name of a bundled font.
    /// YS Music ships a single file, so bold falls back to the same name.
    private static func registeredFontName(for family: SGNowPlayingCardFont, bold: Bool) -> String? {
        let fileName: String
        switch family {
        case .ysMusic:
            fileName = "YSMusic-Regular"
        case .onest:
            fileName = bold ? "Onest-Bold" : "Onest-Regular"
        }
        Self.fontLock.lock()
        defer { Self.fontLock.unlock() }
        if !Self.fontsRegistered {
            Self.fontsRegistered = true
            if let bundleURL = Bundle(for: BundleMarker.self).url(forResource: "SGNowPlayingResources", withExtension: "bundle") ?? Bundle.main.url(forResource: "SGNowPlayingResources", withExtension: "bundle"), let bundle = Bundle(url: bundleURL) {
                for file in ["YSMusic-Regular", "Onest-Regular", "Onest-Bold"] {
                    guard let url = bundle.url(forResource: file, withExtension: "ttf") else {
                        continue
                    }
                    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
                        continue
                    }
                    for descriptor in descriptors {
                        if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String {
                            Self.loadedFontNames[file] = name
                        }
                    }
                }
            }
        }
        return Self.loadedFontNames[fileName]
    }

    private final class BundleMarker {}
}
