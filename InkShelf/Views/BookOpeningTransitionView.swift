import SwiftUI
import UIKit

/// GPU-composited physical-book layer used above the already prepared reader.
/// `closedProgress` is the only source of animation state: 1 is the shelf book
/// and 0 is the fully opened reader. Driving both directions with the same value
/// makes opening and closing exact visual mirrors.
struct BookOpeningTransitionView: UIViewRepresentable, Animatable {
    let book: NovelBook
    let targetFrame: CGRect
    let containerSize: CGSize
    let paperColor: UIColor
    var closedProgress: CGFloat

    var animatableData: CGFloat {
        get { closedProgress }
        set { closedProgress = newValue }
    }

    func makeUIView(context: Context) -> BookTransitionCanvasView {
        let view = BookTransitionCanvasView()
        view.isUserInteractionEnabled = false
        view.configure(book: book, paperColor: paperColor)
        return view
    }

    func updateUIView(_ view: BookTransitionCanvasView, context: Context) {
        view.configure(book: book, paperColor: paperColor)
        view.update(
            closedProgress: closedProgress,
            targetFrame: targetFrame,
            containerSize: containerSize
        )
    }
}

/// A native Core Animation scene for the book body and hinged cover.
///
/// Layer tree:
/// perspectiveLayer (m34)
/// ├─ bookShadow
/// ├─ pageBlock (paper face + gutter + page edges)
/// ├─ coverShadow
/// ├─ fixedSpine
/// └─ cover (CATransformLayer, left-edge hinge)
///    ├─ coverFront
///    ├─ coverBack
///    ├─ outer/top/bottom thickness planes
///    └─ hingeHighlight
final class BookTransitionCanvasView: UIView {
    private let perspectiveLayer = CATransformLayer()

    private let bookShadow = CALayer()
    private let pageBlock = CAGradientLayer()
    private let gutterShade = CAGradientLayer()
    private let paperLines = CALayer()
    private let pageTopEdge = CAGradientLayer()
    private let pageRightEdge = CAGradientLayer()
    private let pageBottomEdge = CAGradientLayer()

    private let coverShadow = CALayer()
    private let fixedSpine = CAGradientLayer()
    private let cover = CATransformLayer()
    private let coverFront = CAGradientLayer()
    private let coverBack = CAGradientLayer()
    private let coverBackTexture = CAGradientLayer()
    private let coverHighlight = CAGradientLayer()
    private let coverOuterEdge = CAGradientLayer()
    private let coverTopEdge = CAGradientLayer()
    private let coverBottomEdge = CAGradientLayer()
    private let hingeHighlight = CAGradientLayer()

    private let titleLayer = CATextLayer()
    private let brandLayer = CATextLayer()
    private let authorLayer = CATextLayer()

    private var configuredBookID: UUID?
    private var configuredPaperColor: UIColor?

    // Internal diagnostics used by endpoint tests. They also make it easy to
    // verify that repeated open/close cycles do not accumulate transforms.
    private(set) var renderedClosedProgress: CGFloat = 1
    private(set) var renderedBookFrame: CGRect = .zero
    private(set) var renderedCoverAngle: CGFloat = 0
    var coverHingeAnchorPoint: CGPoint { cover.anchorPoint }
    var perspectiveM34: CGFloat { perspectiveLayer.sublayerTransform.m34 }
    var physicalLayerCount: Int { recursiveLayerCount(in: perspectiveLayer) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        layer.masksToBounds = false

        perspectiveLayer.masksToBounds = false
        layer.addSublayer(perspectiveLayer)

        bookShadow.backgroundColor = UIColor.black.withAlphaComponent(0.01).cgColor
        bookShadow.shadowColor = UIColor.black.cgColor
        bookShadow.shadowOffset = CGSize(width: 5, height: 9)
        bookShadow.shadowRadius = 18
        perspectiveLayer.addSublayer(bookShadow)

        pageBlock.startPoint = CGPoint(x: 0, y: 0.5)
        pageBlock.endPoint = CGPoint(x: 1, y: 0.5)
        pageBlock.locations = [0, 0.065, 0.88, 1]
        perspectiveLayer.addSublayer(pageBlock)

        gutterShade.startPoint = CGPoint(x: 0, y: 0.5)
        gutterShade.endPoint = CGPoint(x: 1, y: 0.5)
        gutterShade.colors = [
            UIColor.black.withAlphaComponent(0.24).cgColor,
            UIColor.black.withAlphaComponent(0.08).cgColor,
            UIColor.clear.cgColor
        ]
        gutterShade.locations = [0, 0.32, 1]
        pageBlock.addSublayer(gutterShade)

        paperLines.backgroundColor = UIColor.black.withAlphaComponent(0.075).cgColor
        pageBlock.addSublayer(paperLines)

        for edge in [pageTopEdge, pageRightEdge, pageBottomEdge] {
            pageBlock.addSublayer(edge)
        }
        pageTopEdge.startPoint = CGPoint(x: 0.5, y: 0)
        pageTopEdge.endPoint = CGPoint(x: 0.5, y: 1)
        pageRightEdge.startPoint = CGPoint(x: 0, y: 0.5)
        pageRightEdge.endPoint = CGPoint(x: 1, y: 0.5)
        pageBottomEdge.startPoint = CGPoint(x: 0.5, y: 0)
        pageBottomEdge.endPoint = CGPoint(x: 0.5, y: 1)

        coverShadow.anchorPoint = CGPoint(x: 0, y: 0.5)
        coverShadow.backgroundColor = UIColor.black.withAlphaComponent(0.012).cgColor
        coverShadow.shadowColor = UIColor.black.cgColor
        coverShadow.shadowRadius = 16
        coverShadow.shadowOffset = CGSize(width: 9, height: 5)
        perspectiveLayer.addSublayer(coverShadow)

        // The spine belongs to the book body. It does not rotate with the cover.
        fixedSpine.startPoint = CGPoint(x: 0, y: 0.5)
        fixedSpine.endPoint = CGPoint(x: 1, y: 0.5)
        fixedSpine.locations = [0, 0.34, 0.64, 1]
        perspectiveLayer.addSublayer(fixedSpine)

        // The cover's anchor and position are both on its left edge, forming a
        // true hinge rather than the center-axis "swinging door" effect.
        cover.anchorPoint = CGPoint(x: 0, y: 0.5)
        cover.masksToBounds = false
        perspectiveLayer.addSublayer(cover)

        coverFront.startPoint = CGPoint(x: 0, y: 0)
        coverFront.endPoint = CGPoint(x: 1, y: 1)
        coverFront.isDoubleSided = false
        coverFront.masksToBounds = true
        cover.addSublayer(coverFront)

        coverBack.startPoint = CGPoint(x: 0, y: 0.5)
        coverBack.endPoint = CGPoint(x: 1, y: 0.5)
        coverBack.isDoubleSided = false
        coverBack.masksToBounds = true
        cover.addSublayer(coverBack)

        coverBackTexture.startPoint = CGPoint(x: 0, y: 0)
        coverBackTexture.endPoint = CGPoint(x: 1, y: 1)
        coverBackTexture.colors = [
            UIColor.white.withAlphaComponent(0.12).cgColor,
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.12).cgColor
        ]
        coverBackTexture.locations = [0, 0.46, 1]
        coverBack.addSublayer(coverBackTexture)

        coverHighlight.startPoint = CGPoint(x: 0, y: 0.5)
        coverHighlight.endPoint = CGPoint(x: 1, y: 0.5)
        coverHighlight.locations = [0, 0.18, 0.7, 1]
        coverFront.addSublayer(coverHighlight)

        for edge in [coverOuterEdge, coverTopEdge, coverBottomEdge] {
            edge.isDoubleSided = true
            cover.addSublayer(edge)
        }

        hingeHighlight.startPoint = CGPoint(x: 0, y: 0.5)
        hingeHighlight.endPoint = CGPoint(x: 1, y: 0.5)
        hingeHighlight.colors = [
            UIColor.black.withAlphaComponent(0.42).cgColor,
            UIColor.white.withAlphaComponent(0.2).cgColor,
            UIColor.clear.cgColor
        ]
        hingeHighlight.locations = [0, 0.42, 1]
        coverFront.addSublayer(hingeHighlight)

        for textLayer in [titleLayer, brandLayer, authorLayer] {
            textLayer.alignmentMode = .center
            textLayer.contentsScale = UIScreen.main.scale
            textLayer.truncationMode = .end
            textLayer.foregroundColor = UIColor.white.withAlphaComponent(0.94).cgColor
            coverFront.addSublayer(textLayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(book: NovelBook, paperColor: UIColor) {
        guard configuredBookID != book.id || configuredPaperColor?.isEqual(paperColor) != true else { return }
        configuredBookID = book.id
        configuredPaperColor = paperColor

        let palette = BookPalette.colors(for: book.coverStyle).map { UIColor($0) }
        let coverLight = palette.first ?? UIColor.darkGray
        let coverDark = palette.last ?? UIColor.black
        coverFront.colors = palette.map(\.cgColor)
        coverBack.colors = [
            coverLight.mixed(with: .black, amount: 0.26).cgColor,
            coverDark.mixed(with: .black, amount: 0.18).cgColor
        ]
        fixedSpine.colors = [
            coverDark.mixed(with: .black, amount: 0.42).cgColor,
            coverLight.mixed(with: .white, amount: 0.16).cgColor,
            coverDark.cgColor,
            coverDark.mixed(with: .black, amount: 0.34).cgColor
        ]

        let edgeLight = coverLight.mixed(with: .white, amount: 0.2)
        let edgeDark = coverDark.mixed(with: .black, amount: 0.38)
        let edgeColors = [edgeLight.cgColor, coverDark.cgColor, edgeDark.cgColor]
        coverOuterEdge.colors = edgeColors
        coverTopEdge.colors = edgeColors
        coverBottomEdge.colors = [edgeDark.cgColor, coverDark.cgColor, edgeLight.cgColor]

        if let coverData = book.coverData, let image = UIImage(data: coverData) {
            coverFront.contents = image.cgImage
            coverFront.contentsGravity = .resizeAspectFill
            [titleLayer, brandLayer, authorLayer].forEach { $0.isHidden = true }
        } else {
            coverFront.contents = UIImage(
                named: BookPalette.defaultCoverAssetName(for: book.coverStyle)
            )?.cgImage
            coverFront.contentsGravity = .resizeAspectFill
            [titleLayer, brandLayer, authorLayer].forEach { $0.isHidden = false }
            brandLayer.string = "墨 架 典 藏"
            titleLayer.string = book.title
            authorLayer.string = book.author
        }

        coverHighlight.colors = [
            UIColor.white.withAlphaComponent(0.23).cgColor,
            UIColor.clear.cgColor,
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.3).cgColor
        ]

        let paperHighlight = paperColor.mixed(with: .white, amount: 0.13)
        let paperShade = paperColor.mixed(with: .black, amount: 0.11)
        pageBlock.colors = [
            paperShade.cgColor,
            paperHighlight.cgColor,
            paperColor.cgColor,
            paperShade.cgColor
        ]
        pageTopEdge.colors = [paperShade.cgColor, paperHighlight.cgColor]
        pageRightEdge.colors = [paperHighlight.cgColor, paperShade.cgColor]
        pageBottomEdge.colors = [paperHighlight.cgColor, paperShade.cgColor]
    }

    func update(closedProgress: CGFloat, targetFrame: CGRect, containerSize: CGSize) {
        let closed = clamp(closedProgress)
        let opening = 1 - closed
        let expansion = smoothstep(0.02, 0.9, opening)
        let coverOpening = smoothstep(0.025, 0.88, opening)
        let physicalFade = 1 - smoothstep(0.88, 1, opening)
        let paperFaceFade = 1 - smoothstep(0.08, 0.46, opening)
        let fullFrame = CGRect(origin: .zero, size: containerSize)
        let bookFrame = interpolate(from: targetFrame, to: fullFrame, amount: expansion)
        let cornerRadius = max(0, 6 * (1 - expansion))
        let pageDepth = max(2, 7 - expansion * 3.5)
        let coverDepth = max(1.5, 3.2 - expansion * 1.2)
        let coverAngle = -coverOpening * (.pi * 0.86)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        frame = fullFrame
        perspectiveLayer.frame = fullFrame
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / max(780, containerSize.width * 2.35)
        perspectiveLayer.sublayerTransform = perspective

        renderedClosedProgress = closed
        renderedBookFrame = bookFrame
        renderedCoverAngle = coverAngle

        bookShadow.frame = bookFrame
        bookShadow.cornerRadius = cornerRadius
        bookShadow.shadowPath = UIBezierPath(roundedRect: bookShadow.bounds, cornerRadius: cornerRadius).cgPath
        bookShadow.shadowOpacity = Float(0.3 * physicalFade)
        bookShadow.opacity = Float(physicalFade)

        pageBlock.frame = bookFrame
        pageBlock.cornerRadius = cornerRadius
        pageBlock.opacity = Float(paperFaceFade)
        layoutPageLayers(in: pageBlock.bounds, depth: pageDepth)

        let spineWidth = max(2.5, min(12, bookFrame.width * 0.055))
        fixedSpine.frame = CGRect(
            x: bookFrame.minX - spineWidth * 0.18,
            y: bookFrame.minY,
            width: spineWidth,
            height: bookFrame.height
        )
        fixedSpine.cornerRadius = min(cornerRadius, spineWidth / 2)
        fixedSpine.opacity = Float(physicalFade * (0.58 + 0.42 * sin(coverOpening * .pi)))

        cover.bounds = CGRect(origin: .zero, size: bookFrame.size)
        cover.position = CGPoint(x: bookFrame.minX, y: bookFrame.midY)
        cover.opacity = Float(physicalFade)
        var coverTransform = CATransform3DIdentity
        coverTransform = CATransform3DTranslate(coverTransform, 0, 0, pageDepth * 0.55 + 1)
        coverTransform = CATransform3DRotate(coverTransform, coverAngle, 0, 1, 0)
        cover.transform = coverTransform

        coverShadow.bounds = cover.bounds
        coverShadow.position = cover.position
        coverShadow.cornerRadius = cornerRadius
        coverShadow.opacity = Float(physicalFade)
        coverShadow.shadowOpacity = Float(sin(coverOpening * .pi) * 0.46 * physicalFade)
        coverShadow.shadowRadius = 12 + 12 * sin(coverOpening * .pi)
        coverShadow.shadowOffset = CGSize(width: 5 + 16 * sin(coverOpening * .pi), height: 5)
        coverShadow.shadowPath = UIBezierPath(roundedRect: cover.bounds, cornerRadius: cornerRadius).cgPath
        coverShadow.transform = coverTransform

        layoutCoverLayers(
            in: cover.bounds,
            cornerRadius: cornerRadius,
            depth: coverDepth,
            opening: coverOpening,
            targetWidth: targetFrame.width,
            currentWidth: bookFrame.width
        )

        CATransaction.commit()
    }

    private func layoutPageLayers(in bounds: CGRect, depth: CGFloat) {
        let width = bounds.width
        let height = bounds.height
        gutterShade.frame = CGRect(x: 0, y: 0, width: max(9, width * 0.1), height: height)
        paperLines.frame = CGRect(x: width * 0.035, y: 0, width: max(0.5, width * 0.007), height: height)
        pageTopEdge.frame = CGRect(x: 2, y: 0, width: max(0, width - depth), height: depth * 0.58)
        pageRightEdge.frame = CGRect(x: max(0, width - depth), y: depth * 0.4, width: depth, height: max(0, height - depth))
        pageBottomEdge.frame = CGRect(x: 2, y: max(0, height - depth), width: max(0, width - 2), height: depth)
    }

    private func layoutCoverLayers(
        in bounds: CGRect,
        cornerRadius: CGFloat,
        depth: CGFloat,
        opening: CGFloat,
        targetWidth: CGFloat,
        currentWidth: CGFloat
    ) {
        coverFront.frame = bounds
        coverFront.cornerRadius = cornerRadius
        coverFront.zPosition = depth / 2

        coverBack.bounds = bounds
        coverBack.position = CGPoint(x: bounds.midX, y: bounds.midY)
        coverBack.cornerRadius = cornerRadius
        var backTransform = CATransform3DMakeRotation(.pi, 0, 1, 0)
        backTransform = CATransform3DTranslate(backTransform, 0, 0, depth / 2)
        coverBack.transform = backTransform
        coverBackTexture.frame = coverBack.bounds

        // Side planes give the cover actual geometric depth while it crosses
        // the 90-degree position; a flat border cannot create this silhouette.
        coverOuterEdge.bounds = CGRect(x: 0, y: 0, width: depth, height: max(0, bounds.height - 2 * cornerRadius))
        coverOuterEdge.position = CGPoint(x: bounds.width, y: bounds.midY)
        coverOuterEdge.transform = CATransform3DMakeRotation(.pi / 2, 0, 1, 0)

        coverTopEdge.bounds = CGRect(x: 0, y: 0, width: max(0, bounds.width - cornerRadius), height: depth)
        coverTopEdge.position = CGPoint(x: bounds.midX, y: 0)
        coverTopEdge.transform = CATransform3DMakeRotation(-.pi / 2, 1, 0, 0)

        coverBottomEdge.bounds = coverTopEdge.bounds
        coverBottomEdge.position = CGPoint(x: bounds.midX, y: bounds.height)
        coverBottomEdge.transform = CATransform3DMakeRotation(.pi / 2, 1, 0, 0)

        coverHighlight.frame = bounds
        coverHighlight.opacity = Float(0.72 + 0.28 * cos(opening * .pi))
        hingeHighlight.frame = CGRect(x: 0, y: 0, width: max(3, bounds.width * 0.075), height: bounds.height)

        let compactness = clamp(targetWidth / max(currentWidth, 1))
        brandLayer.font = UIFont.systemFont(ofSize: max(7, currentWidth * 0.065), weight: .semibold)
        brandLayer.fontSize = max(7, currentWidth * 0.065)
        brandLayer.frame = CGRect(x: bounds.width * 0.12, y: bounds.height * 0.09, width: bounds.width * 0.76, height: bounds.height * 0.09)
        titleLayer.font = UIFont(name: "Songti SC", size: max(14, currentWidth * 0.15))
            ?? UIFont.systemFont(ofSize: max(14, currentWidth * 0.15), weight: .semibold)
        titleLayer.fontSize = max(14, currentWidth * 0.15)
        titleLayer.isWrapped = true
        titleLayer.frame = CGRect(x: bounds.width * 0.1, y: bounds.height * 0.28, width: bounds.width * 0.8, height: bounds.height * 0.36)
        authorLayer.font = UIFont.systemFont(ofSize: max(8, currentWidth * 0.075), weight: .regular)
        authorLayer.fontSize = max(8, currentWidth * 0.075)
        authorLayer.frame = CGRect(x: bounds.width * 0.12, y: bounds.height * 0.79, width: bounds.width * 0.76, height: bounds.height * 0.08)
        [brandLayer, titleLayer, authorLayer].forEach {
            $0.opacity = Float((0.55 + compactness * 0.45) * (1 - smoothstep(0.7, 0.96, opening)))
        }
    }

    private func interpolate(from: CGRect, to: CGRect, amount: CGFloat) -> CGRect {
        CGRect(
            x: from.minX + (to.minX - from.minX) * amount,
            y: from.minY + (to.minY - from.minY) * amount,
            width: from.width + (to.width - from.width) * amount,
            height: from.height + (to.height - from.height) * amount
        )
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }

    private func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        let x = clamp((value - edge0) / max(edge1 - edge0, 0.001))
        return x * x * (3 - 2 * x)
    }

    private func recursiveLayerCount(in root: CALayer) -> Int {
        1 + (root.sublayers ?? []).reduce(0) { $0 + recursiveLayerCount(in: $1) }
    }
}

private extension UIColor {
    func mixed(with color: UIColor, amount: CGFloat) -> UIColor {
        let fraction = min(1, max(0, amount))
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              color.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return self }
        return UIColor(
            red: r1 + (r2 - r1) * fraction,
            green: g1 + (g2 - g1) * fraction,
            blue: b1 + (b2 - b1) * fraction,
            alpha: a1 + (a2 - a1) * fraction
        )
    }
}
