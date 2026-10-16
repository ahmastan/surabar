import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PageColors: Sendable {
    public var background: CGColor
    public var text: CGColor
    public var highlight: CGColor

    public init(background: CGColor, text: CGColor, highlight: CGColor) {
        self.background = background
        self.text = text
        self.highlight = highlight
    }

    public static let light = PageColors(background: CGColor(gray: 1, alpha: 1), text: CGColor(gray: 0, alpha: 1),
                                         highlight: CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 0.35))
}

public enum PageRenderer {
    /// Draws into a context whose origin is bottom-left (the Core Graphics default).
    public static func draw(_ layout: PageLayout, in context: CGContext, colors: PageColors = .light,
                            highlighted: [CGRect] = [], outlineItems: Bool = false) {
        let height = layout.size.height
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(colors.background)
        context.fill(CGRect(origin: .zero, size: layout.size))
        context.setFillColor(colors.highlight)
        for rect in highlighted {
            let box = flipped(rect).insetBy(dx: -2, dy: 0)
            context.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.fillPath()
        }
        if outlineItems {
            context.setLineWidth(0.5)
            for item in layout.items {
                context.setStrokeColor(CGColor(red: 0, green: 0.4, blue: 1, alpha: 0.5))
                context.stroke(flipped(item.typographicRect))
                context.setStrokeColor(CGColor(red: 1, green: 0, blue: 0.3, alpha: 0.5))
                context.stroke(flipped(item.inkRect))
            }
        }
        context.setFillColor(colors.text)
        context.textMatrix = .identity
        for item in layout.items {
            context.textPosition = CGPoint(x: item.baseline.x, y: height - item.baseline.y)
            CTLineDraw(item.line, context)
        }
    }

    public static func writePNG(_ layout: PageLayout, to url: URL, scale: Double = 2,
                                colors: PageColors = .light, highlighted: [CGRect] = [],
                                outlineItems: Bool = false) throws {
        let width = Int((layout.size.width * scale).rounded(.up))
        let height = Int((layout.size.height * scale).rounded(.up))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        context.scaleBy(x: scale, y: scale)
        draw(layout, in: context, colors: colors, highlighted: highlighted, outlineItems: outlineItems)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
