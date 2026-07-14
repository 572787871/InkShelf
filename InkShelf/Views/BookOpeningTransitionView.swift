import SwiftUI
import UIKit

/// GPU-composited physical-book layer used above the live reader during its
/// shared transition. `closedProgress` is interactive: 1 is on the shelf and
/// 0 is a fully opened reader.
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

final class BookTransitionCanvasView: UIView {
    private let paperBlock = CAGradientLayer()
    private let paperLines = CALayer()
    private let pageRightEdge = CAGradientLayer()
    private let pageBottomEdge = CAGradientLayer()
    private let coverShadow = CALayer()
    private let cover = CATransformLayer()
    private let coverFront = CAGradientLayer()
    private let coverBack = CAGradientLayer()
    private let coverHighlight = CAGradientLayer()
    private let coverOuterEdge = CAGradientLayer()
    private let spine = CAGradientLayer()
    private let titleLayer = CATextLayer()
    private let brandLayer = CATextLayer()
    private let authorLayer = CATextLayer()

    private var configuredBookID: UUID?
    private var configuredPaperColor: UIColor?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        layer.masksToBounds = false

        paperBlock.startPoint = CGPoint(x: 0, y: 0.5)
        paperBlock.endPoint = CGPoint(x: 1, y: 0.5)
        paperBlock.locations = [0, 0.08, 0.88, 1]
        paperBlock.shadowColor = UIColor.black.cgColor
        paperBlock.shadowOffset = CGSize(width: 5, height: 8)
        paperBlock.shadowRadius = 16
        layer.addSublayer(paperBlock)

        paperLines.backgroundColor = UIColor.black.withAlphaComponent(0.08).cgColor
        paperBlock.addSublayer(paperLines)

        pageRightEdge.startPoint = CGPoint(x: 0, y: 0.5)
        pageRightEdge.endPoint = CGPoint(x: 1, y: 0.5)
        paperBlock.addSublayer(pageRightEdge)

        pageBottomEdge.startPoint = CGPoint(x: 0.5, y: 0)
        pageBottomEdge.endPoint = CGPoint(x: 0.5, y: 1)
        paperBlock.addSublayer(pageBottomEdge)

        coverShadow.anchorPoint = CGPoint(x: 0, y: 0.5)
        coverShadow.shadowColor = UIColor.black.cgColor
        coverShadow.shadowRadius = 13
        coverShadow.shadowOffset = CGSize(width: 7, height: 5)
        layer.addSublayer(coverShadow)

        cover.anchorPoint = CGPoint(x: 0, y: 0.5)
        cover.masksToBounds = false
        layer.addSublayer(cover)

        coverFront.startPoint = CGPoint(x: 0, y: 0)
        coverFront.endPoint = CGPoint(x: 1, y: 1)
        coverFront.isDoubleSided = false
        coverFront.masksToBounds = true
        cover.addSublayer(coverFront)

        coverBack.startPoint = CGPoint(x: 0, y: 0.5)
        coverBack.endPoint = CGPoint(x: 1, y: 0.5)
        coverBack.isDoubleSided = false
        coverBack.masksToBounds = true
        var backTransform = CATransform3DMakeRotation(.pi, 0, 1, 0)
        backTransform = CATransform3DTranslate(backTransform, 0, 0, -1.2)
        coverBack.transform = backTransform
        cover.addSublayer(coverBack)

        coverHighlight.colors = [
            UIColor.white.withAlphaComponent(0.22).cgColor,
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.24).cgColor
        ]
        coverHighlight.locations = [0, 0.42, 1]
        coverHighlight.startPoint = CGPoint(x: 0, y: 0.5)
        coverHighlight.endPoint = CGPoint(x: 1, y: 0.5)
        coverFront.addSublayer(coverHighlight)

        coverOuterEdge.startPoint = CGPoint(x: 0, y: 0.5)
        coverOuterEdge.endPoint = CGPoint(x: 1, y: 0.5)
        coverOuterEdge.colors = [
            UIColor.white.withAlphaComponent(0.32).cgColor,
            UIColor.black.withAlphaComponent(0.38).cgColor
        ]
        cover.addSublayer(coverOuterEdge)

        spine.startPoint = CGPoint(x: 0, y: 0.5)
        spine.endPoint = CGPoint(x: 1, y: 0.5)
        spine.colors = [
            UIColor.black.withAlphaComponent(0.42).cgColor,
            UIColor.white.withAlphaComponent(0.22).cgColor,
            UIColor.black.withAlphaComponent(0.18).cgColor
        ]
        spine.locations = [0, 0.55, 1]
        cover.addSublayer(spine)

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
        coverFront.colors = palette.map(\.cgColor)
        coverBack.colors = [
            palette.first?.mixed(with: .black, amount: 0.22).cgColor ?? UIColor.darkGray.cgColor,
            palette.last?.mixed(with: .black, amount: 0.34).cgColor ?? UIColor.black.cgColor
        ]

        if let coverData = book.coverData, let image = UIImage(data: coverData) {
            coverFront.contents = image.cgImage
            coverFront.contentsGravity = .resizeAspectFill
            [titleLayer, brandLayer, authorLayer].forEach { $0.isHidden = true }
        } else {
            coverFront.contents = nil
            [titleLayer, brandLayer, authorLayer].forEach { $0.isHidden = false }
            brandLayer.string = "墨 架"
            titleLayer.string = book.title
            authorLayer.string = book.author
        }

        let paperHighlight = paperColor.mixed(with: .white, amount: 0.13)
        let paperShade = paperColor.mixed(with: .black, amount: 0.11)
        paperBlock.colors = [
            paperShade.cgColor,
            paperHighlight.cgColor,
            paperColor.cgColor,
            paperShade.cgColor
        ]
        pageRightEdge.colors = [paperColor.cgColor, paperShade.cgColor]
        pageBottomEdge.colors = [paperColor.cgColor, paperShade.cgColor]
    }

    func update(closedProgress: CGFloat, targetFrame: CGRect, containerSize: CGSize) {
        let closed = min(1, max(0, closedProgress))
        let opening = 1 - closed
        let expansion = smoothstep(0.02, 0.88, opening)
        let coverOpening = smoothstep(0.04, 0.72, opening)
        let fade = 1 - smoothstep(0.82, 1, opening)
        let fullFrame = CGRect(origin: .zero, size: containerSize)
        let bookFrame = interpolate(from: targetFrame, to: fullFrame, amount: expansion)
        let thickness = max(2, 7 - expansion * 4)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        frame = fullFrame
        paperBlock.frame = bookFrame
        paperBlock.cornerRadius = max(0, 6 * (1 - expansion))
        paperBlock.shadowOpacity = Float(0.28 * fade)
        paperBlock.shadowPath = UIBezierPath(roundedRect: paperBlock.bounds, cornerRadius: paperBlock.cornerRadius).cgPath
        paperBlock.opacity = Float(fade)

        paperLines.frame = CGRect(x: bookFrame.width * 0.035, y: 0, width: max(0.5, bookFrame.width * 0.008), height: bookFrame.height)
        pageRightEdge.frame = CGRect(x: max(0, bookFrame.width - thickness), y: 2, width: thickness, height: max(0, bookFrame.height - thickness))
        pageBottomEdge.frame = CGRect(x: 2, y: max(0, bookFrame.height - thickness), width: max(0, bookFrame.width - 2), height: thickness)

        cover.bounds = CGRect(origin: .zero, size: bookFrame.size)
        cover.position = CGPoint(x: bookFrame.minX, y: bookFrame.midY)
        cover.opacity = Float(fade)

        coverShadow.bounds = cover.bounds
        coverShadow.position = cover.position
        coverShadow.opacity = Float(fade)
        coverShadow.shadowOpacity = Float(sin(coverOpening * .pi) * 0.38 * fade)
        coverShadow.shadowPath = UIBezierPath(roundedRect: cover.bounds, cornerRadius: paperBlock.cornerRadius).cgPath

        var transform = CATransform3DIdentity
        transform.m34 = -1 / max(650, containerSize.width * 2.1)
        transform = CATransform3DTranslate(transform, 0, 0, 4)
        transform = CATransform3DRotate(transform, -coverOpening * (.pi * 0.61), 0, 1, 0)
        cover.transform = transform
        coverShadow.transform = transform

        let coverBounds = cover.bounds
        coverFront.frame = coverBounds
        coverBack.frame = coverBounds
        coverFront.cornerRadius = paperBlock.cornerRadius
        coverBack.cornerRadius = paperBlock.cornerRadius
        coverHighlight.frame = coverBounds
        coverOuterEdge.frame = CGRect(x: max(0, coverBounds.width - thickness), y: 1, width: thickness, height: max(0, coverBounds.height - 2))
        spine.frame = CGRect(x: 0, y: 0, width: max(2, coverBounds.width * 0.075), height: coverBounds.height)

        let compactness = min(1, max(0, targetFrame.width / max(bookFrame.width, 1)))
        brandLayer.font = UIFont.systemFont(ofSize: max(7, bookFrame.width * 0.065), weight: .semibold)
        brandLayer.fontSize = max(7, bookFrame.width * 0.065)
        brandLayer.frame = CGRect(x: bookFrame.width * 0.12, y: bookFrame.height * 0.09, width: bookFrame.width * 0.76, height: bookFrame.height * 0.09)
        titleLayer.font = UIFont(name: "Songti SC", size: max(14, bookFrame.width * 0.15)) ?? UIFont.systemFont(ofSize: max(14, bookFrame.width * 0.15), weight: .semibold)
        titleLayer.fontSize = max(14, bookFrame.width * 0.15)
        titleLayer.isWrapped = true
        titleLayer.frame = CGRect(x: bookFrame.width * 0.1, y: bookFrame.height * 0.28, width: bookFrame.width * 0.8, height: bookFrame.height * 0.36)
        authorLayer.font = UIFont.systemFont(ofSize: max(8, bookFrame.width * 0.075), weight: .regular)
        authorLayer.fontSize = max(8, bookFrame.width * 0.075)
        authorLayer.frame = CGRect(x: bookFrame.width * 0.12, y: bookFrame.height * 0.79, width: bookFrame.width * 0.76, height: bookFrame.height * 0.08)
        [brandLayer, titleLayer, authorLayer].forEach { $0.opacity = Float(0.55 + compactness * 0.45) }

        CATransaction.commit()
    }

    private func interpolate(from: CGRect, to: CGRect, amount: CGFloat) -> CGRect {
        CGRect(
            x: from.minX + (to.minX - from.minX) * amount,
            y: from.minY + (to.minY - from.minY) * amount,
            width: from.width + (to.width - from.width) * amount,
            height: from.height + (to.height - from.height) * amount
        )
    }

    private func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        let x = min(1, max(0, (value - edge0) / max(edge1 - edge0, 0.001)))
        return x * x * (3 - 2 * x)
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
