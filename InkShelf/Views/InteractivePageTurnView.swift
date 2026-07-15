import SwiftUI
import UIKit

enum InteractivePageTurnMode: Equatable {
    case curl
    case cover
    case immediate
}

struct ReaderPageAppearance: Equatable {
    let themeID: String
    let bookTitle: String
    let backgroundColor: UIColor
    let backsideColor: UIColor
    let textColor: UIColor
    let fontName: String?
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let horizontalMargin: CGFloat
    let highlightedLocation: ReaderPageLocation?
    let highlightedRange: NSRange?

    static func == (lhs: ReaderPageAppearance, rhs: ReaderPageAppearance) -> Bool {
        lhs.themeID == rhs.themeID &&
        lhs.bookTitle == rhs.bookTitle &&
        lhs.backgroundColor.isEqual(rhs.backgroundColor) &&
        lhs.backsideColor.isEqual(rhs.backsideColor) &&
        lhs.textColor.isEqual(rhs.textColor) &&
        lhs.fontName == rhs.fontName &&
        lhs.fontSize == rhs.fontSize &&
        lhs.lineSpacing == rhs.lineSpacing &&
        lhs.horizontalMargin == rhs.horizontalMargin &&
        lhs.highlightedLocation == rhs.highlightedLocation &&
        lhs.highlightedRange == rhs.highlightedRange
    }

    func hasSameLayout(as other: ReaderPageAppearance) -> Bool {
        themeID == other.themeID &&
        bookTitle == other.bookTitle &&
        fontName == other.fontName &&
        fontSize == other.fontSize &&
        lineSpacing == other.lineSpacing &&
        horizontalMargin == other.horizontalMargin
    }
}

struct InteractivePageTurnView: UIViewControllerRepresentable {
    let pages: [ReaderPage]
    let location: ReaderPageLocation
    let appearance: ReaderPageAppearance
    let mode: InteractivePageTurnMode
    let isInteractionEnabled: Bool
    let onCommit: (ReaderPageLocation) -> Void
    let onCenterTap: () -> Void

    func makeUIViewController(context: Context) -> ReaderPageTurnHostController {
        let controller = ReaderPageTurnHostController()
        controller.onCommit = onCommit
        controller.onCenterTap = onCenterTap
        controller.configure(
            pages: pages,
            location: location,
            appearance: appearance,
            mode: mode,
            isInteractionEnabled: isInteractionEnabled
        )
        return controller
    }

    func updateUIViewController(_ controller: ReaderPageTurnHostController, context: Context) {
        controller.onCommit = onCommit
        controller.onCenterTap = onCenterTap
        controller.configure(
            pages: pages,
            location: location,
            appearance: appearance,
            mode: mode,
            isInteractionEnabled: isInteractionEnabled
        )
    }
}

private protocol PageTurnEngine: AnyObject {
    var onCommit: ((ReaderPageLocation) -> Void)? { get set }
    var isTransitioning: Bool { get }
    func configure(pages: [ReaderPage], index: Int, appearance: ReaderPageAppearance)
    func turn(_ direction: PageTurnDirection)
    func setInteractionEnabled(_ enabled: Bool)
}

final class ReaderPageTurnHostController: UIViewController {
    var onCommit: ((ReaderPageLocation) -> Void)?
    var onCenterTap: (() -> Void)?

    private var engine: (UIViewController & PageTurnEngine)?
    private var mode: InteractivePageTurnMode?
    private weak var tapGesture: UITapGestureRecognizer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        tapGesture = tap
    }

    func configure(
        pages: [ReaderPage],
        location: ReaderPageLocation,
        appearance: ReaderPageAppearance,
        mode: InteractivePageTurnMode,
        isInteractionEnabled: Bool = true
    ) {
        guard !pages.isEmpty else { return }
        let index = pages.firstIndex(where: { $0.location == location }) ?? 0
        if self.mode != mode || engine == nil { installEngine(for: mode) }
        view.backgroundColor = appearance.backgroundColor
        engine?.configure(pages: pages, index: index, appearance: appearance)
        engine?.setInteractionEnabled(isInteractionEnabled)
        tapGesture?.isEnabled = isInteractionEnabled
    }

    private func installEngine(for mode: InteractivePageTurnMode) {
        if let engine {
            engine.willMove(toParent: nil)
            engine.view.removeFromSuperview()
            engine.removeFromParent()
        }

        let newEngine: UIViewController & PageTurnEngine
        switch mode {
        case .curl:
            newEngine = CurlPageTurnController()
        case .cover:
            newEngine = CoverPageTurnController(animationDuration: 0.28)
        case .immediate:
            newEngine = CoverPageTurnController(animationDuration: 0.01)
        }
        newEngine.onCommit = { [weak self] location in self?.onCommit?(location) }
        addChild(newEngine)
        view.addSubview(newEngine.view)
        newEngine.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            newEngine.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            newEngine.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            newEngine.view.topAnchor.constraint(equalTo: view.topAnchor),
            newEngine.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        newEngine.didMove(toParent: self)
        engine = newEngine
        self.mode = mode
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let engine, !engine.isTransitioning else { return }
        let x = recognizer.location(in: view).x
        if x < view.bounds.width * 0.28 {
            engine.turn(.backward)
        } else if x > view.bounds.width * 0.72 {
            engine.turn(.forward)
        } else {
            onCenterTap?()
        }
    }
}

private final class ReaderPageContentController: UIViewController {
    let pageIndex: Int
    private let page: ReaderPage
    private var appearance: ReaderPageAppearance

    init(page: ReaderPage, pageIndex: Int, appearance: ReaderPageAppearance) {
        self.page = page
        self.pageIndex = pageIndex
        self.appearance = appearance
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = ReaderPageContentView(page: page, appearance: appearance)
    }

    func updateHighlight(using appearance: ReaderPageAppearance) {
        self.appearance = appearance
        (viewIfLoaded as? ReaderPageContentView)?.updateHighlight(using: appearance)
    }
}

private protocol CurlPageSide: AnyObject {
    var physicalPageIndex: Int { get }
}

extension ReaderPageContentController: CurlPageSide {
    var physicalPageIndex: Int { pageIndex * 2 }
}

private final class ReaderPageContentView: UIView {
    private let titleLabel = UILabel()
    private let brandLabel = UILabel()
    private let textView = UITextView()
    private let pageLabel = UILabel()
    private let clockLabel = UILabel()
    private let batteryImageView = UIImageView()
    private let page: ReaderPage
    private var appearance: ReaderPageAppearance

    init(page: ReaderPage, appearance: ReaderPageAppearance) {
        self.page = page
        self.appearance = appearance
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = appearance.backgroundColor
        layer.drawsAsynchronously = true

        titleLabel.text = page.chapterTitle
        titleLabel.font = .systemFont(ofSize: 10)
        titleLabel.textColor = appearance.textColor.withAlphaComponent(0.52)
        titleLabel.lineBreakMode = .byTruncatingTail

        brandLabel.text = appearance.bookTitle
        brandLabel.font = .systemFont(ofSize: 10)
        brandLabel.textColor = appearance.textColor.withAlphaComponent(0.52)
        brandLabel.textAlignment = .right

        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.attributedText = attributedBody(page.displayText)

        pageLabel.text = "\(page.overallIndex + 1) / \(page.overallCount)"
        clockLabel.text = ReaderPageStatus.clockFormatter.string(from: .now)
        for label in [pageLabel, clockLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = appearance.textColor.withAlphaComponent(0.5)
        }
        clockLabel.textAlignment = .right
        batteryImageView.image = UIImage(systemName: ReaderPageStatus.batterySymbolName())
        batteryImageView.tintColor = appearance.textColor.withAlphaComponent(0.5)
        batteryImageView.contentMode = .scaleAspectFit

        [titleLabel, brandLabel, textView, pageLabel, clockLabel, batteryImageView].forEach(addSubview)
        accessibilityLabel = "\(page.chapterTitle)，第 \(page.pageInChapter) 页"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let margin = appearance.horizontalMargin
        let width = max(0, bounds.width - margin * 2)
        let headerY = max(16, safeAreaInsets.top + 12)
        let footerY = bounds.height - max(28, safeAreaInsets.bottom + 18)
        titleLabel.frame = CGRect(x: margin, y: headerY, width: width * 0.62, height: 16)
        brandLabel.frame = CGRect(x: margin + width * 0.64, y: headerY, width: width * 0.36, height: 16)
        textView.frame = CGRect(x: margin, y: headerY + 38, width: width, height: max(0, footerY - headerY - 58))
        pageLabel.frame = CGRect(x: margin, y: footerY, width: width * 0.5, height: 16)
        batteryImageView.frame = CGRect(x: margin + width - 18, y: footerY + 1, width: 18, height: 13)
        clockLabel.frame = CGRect(x: margin + width * 0.5, y: footerY, width: width * 0.5 - 24, height: 16)
        clockLabel.text = ReaderPageStatus.clockFormatter.string(from: .now)
        batteryImageView.image = UIImage(systemName: ReaderPageStatus.batterySymbolName())
    }

    func updateHighlight(using appearance: ReaderPageAppearance) {
        self.appearance = appearance
        textView.attributedText = attributedBody(page.displayText)
    }

    private func attributedBody(_ text: String) -> NSAttributedString {
        let font = appearance.fontName.flatMap { UIFont(name: $0, size: appearance.fontSize) }
            ?? UIFont.systemFont(ofSize: appearance.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = appearance.lineSpacing
        paragraph.alignment = .natural
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: appearance.textColor,
                .paragraphStyle: paragraph
            ]
        )
        if appearance.highlightedLocation == page.location,
           let range = appearance.highlightedRange,
           range.location >= 0,
           NSMaxRange(range) <= page.text.utf16.count {
            let displayRange = NSRange(
                location: range.location + page.chapterHeadingPrefix.utf16.count,
                length: range.length
            )
            attributed.addAttributes([
                .backgroundColor: UIColor.systemYellow.withAlphaComponent(0.24),
                .foregroundColor: appearance.textColor
            ], range: displayRange)
        }
        styleChapterTitle(in: attributed)
        return attributed
    }

    private func styleChapterTitle(in attributed: NSMutableAttributedString) {
        guard !page.chapterHeadingPrefix.isEmpty,
              page.displayText.hasPrefix(page.chapterTitle) else { return }
        let titleRange = NSRange(location: 0, length: (page.chapterTitle as NSString).length)
        let titleFont = appearance.fontName.flatMap { UIFont(name: $0, size: appearance.fontSize + 6) }
            ?? UIFont.systemFont(ofSize: appearance.fontSize + 6, weight: .semibold)
        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.lineSpacing = appearance.lineSpacing
        titleParagraph.paragraphSpacing = appearance.lineSpacing + 8
        attributed.addAttributes([
            .font: titleFont,
            .paragraphStyle: titleParagraph
        ], range: titleRange)
    }

}

private final class ReaderPageBackContentController: UIViewController, CurlPageSide {
    let pageIndex: Int
    var physicalPageIndex: Int { pageIndex * 2 + 1 }

    private let page: ReaderPage?
    private var appearance: ReaderPageAppearance

    init(page: ReaderPage?, pageIndex: Int, appearance: ReaderPageAppearance) {
        self.page = page
        self.pageIndex = pageIndex
        self.appearance = appearance
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = ReaderPageBackContentView(page: page, appearance: appearance)
    }
}

/// Opaque content for the physical back of a curled sheet. UIKit adds the moving
/// fold, specular highlight and cast shadow over this view during `.pageCurl`.
private final class ReaderPageBackContentView: UIView {
    private let paperGradient = CAGradientLayer()
    private let ghostInkView = UIView()
    private let titleLabel = UILabel()
    private let brandLabel = UILabel()
    private let textView = UITextView()
    private let pageLabel = UILabel()
    private let clockLabel = UILabel()
    private let batteryImageView = UIImageView()
    private let page: ReaderPage?
    private let appearance: ReaderPageAppearance

    init(page: ReaderPage?, appearance: ReaderPageAppearance) {
        self.page = page
        self.appearance = appearance
        super.init(frame: .zero)

        isOpaque = true
        backgroundColor = appearance.backsideColor
        layer.backgroundColor = appearance.backsideColor.cgColor
        layer.drawsAsynchronously = true

        let highlight = appearance.backsideColor.mixed(with: appearance.backgroundColor, fraction: 0.38)
        let shade = appearance.backsideColor.mixed(with: .black, fraction: 0.055)
        paperGradient.colors = [highlight.cgColor, appearance.backsideColor.cgColor, shade.cgColor]
        paperGradient.locations = [0, 0.54, 1]
        paperGradient.startPoint = CGPoint(x: 0, y: 0.5)
        paperGradient.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(paperGradient)

        guard let page else { return }
        let ghostColor = appearance.textColor.withAlphaComponent(0.15)

        titleLabel.text = page.chapterTitle
        titleLabel.font = .systemFont(ofSize: 10)
        titleLabel.textColor = ghostColor
        titleLabel.lineBreakMode = .byTruncatingTail

        brandLabel.text = appearance.bookTitle
        brandLabel.font = .systemFont(ofSize: 10)
        brandLabel.textColor = ghostColor
        brandLabel.textAlignment = .right

        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.attributedText = attributedGhostText(page.displayText, color: ghostColor)

        pageLabel.text = "\(page.overallIndex + 1) / \(page.overallCount)"
        clockLabel.text = ReaderPageStatus.clockFormatter.string(from: .now)
        for label in [pageLabel, clockLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = ghostColor
        }
        clockLabel.textAlignment = .right
        batteryImageView.image = UIImage(systemName: ReaderPageStatus.batterySymbolName())
        batteryImageView.tintColor = ghostColor
        batteryImageView.contentMode = .scaleAspectFit

        [titleLabel, brandLabel, textView, pageLabel, clockLabel, batteryImageView].forEach(ghostInkView.addSubview)
        addSubview(ghostInkView)
        ghostInkView.isUserInteractionEnabled = false
        ghostInkView.transform = CGAffineTransform(scaleX: -1, y: 1)
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        paperGradient.frame = bounds
        guard page != nil else { return }

        ghostInkView.bounds = bounds
        ghostInkView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let margin = appearance.horizontalMargin
        let width = max(0, bounds.width - margin * 2)
        let headerY = max(16, safeAreaInsets.top + 12)
        let footerY = bounds.height - max(28, safeAreaInsets.bottom + 18)
        titleLabel.frame = CGRect(x: margin, y: headerY, width: width * 0.62, height: 16)
        brandLabel.frame = CGRect(x: margin + width * 0.64, y: headerY, width: width * 0.36, height: 16)
        textView.frame = CGRect(x: margin, y: headerY + 38, width: width, height: max(0, footerY - headerY - 58))
        pageLabel.frame = CGRect(x: margin, y: footerY, width: width * 0.5, height: 16)
        batteryImageView.frame = CGRect(x: margin + width - 18, y: footerY + 1, width: 18, height: 13)
        clockLabel.frame = CGRect(x: margin + width * 0.5, y: footerY, width: width * 0.5 - 24, height: 16)
    }

    private func attributedGhostText(_ text: String, color: UIColor) -> NSAttributedString {
        let font = appearance.fontName.flatMap { UIFont(name: $0, size: appearance.fontSize) }
            ?? UIFont.systemFont(ofSize: appearance.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = appearance.lineSpacing
        paragraph.alignment = .natural
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
        if let page,
           page.pageInChapter == 1,
           page.chapterTitle != "正文",
           text.hasPrefix(page.chapterTitle) {
            let titleFont = appearance.fontName.flatMap { UIFont(name: $0, size: appearance.fontSize + 6) }
                ?? UIFont.systemFont(ofSize: appearance.fontSize + 6, weight: .semibold)
            attributed.addAttribute(
                .font,
                value: titleFont,
                range: NSRange(location: 0, length: (page.chapterTitle as NSString).length)
            )
        }
        return attributed
    }
}

private enum ReaderPageStatus {
    static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter
    }()

    static func batterySymbolName() -> String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        switch UIDevice.current.batteryLevel {
        case 0.88...: return "battery.100percent"
        case 0.63...: return "battery.75percent"
        case 0.38...: return "battery.50percent"
        case 0.13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

private extension UIColor {
    func mixed(with color: UIColor, fraction: CGFloat) -> UIColor {
        let amount = min(max(fraction, 0), 1)
        var red1: CGFloat = 0
        var green1: CGFloat = 0
        var blue1: CGFloat = 0
        var alpha1: CGFloat = 0
        var red2: CGFloat = 0
        var green2: CGFloat = 0
        var blue2: CGFloat = 0
        var alpha2: CGFloat = 0
        guard getRed(&red1, green: &green1, blue: &blue1, alpha: &alpha1),
              color.getRed(&red2, green: &green2, blue: &blue2, alpha: &alpha2) else {
            return self
        }
        return UIColor(
            red: red1 + (red2 - red1) * amount,
            green: green1 + (green2 - green1) * amount,
            blue: blue1 + (blue2 - blue1) * amount,
            alpha: alpha1 + (alpha2 - alpha1) * amount
        )
    }
}

private struct EngineConfiguration {
    let pages: [ReaderPage]
    let index: Int
    let appearance: ReaderPageAppearance
}

private final class CurlPageTurnController: UIPageViewController, PageTurnEngine, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    var onCommit: ((ReaderPageLocation) -> Void)?
    var isTransitioning: Bool { transaction.isLocked }

    private var pages: [ReaderPage] = []
    private var appearance: ReaderPageAppearance?
    private var transaction = PageTurnTransaction(currentIndex: 0)
    private var pendingConfiguration: EngineConfiguration?
    private var frontCache: [Int: ReaderPageContentController] = [:]
    private var backCache: [Int: ReaderPageBackContentController] = [:]

    init() {
        super.init(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [.spineLocation: NSNumber(value: SpineLocation.min.rawValue)]
        )
        // Edge-spine mode keeps the entire interactive sheet inside the reader.
        // `isDoubleSided` then asks the data source for the physical reverse of
        // that sheet, so UIKit retains its native curl mesh in both directions.
        isDoubleSided = true
        dataSource = self
        delegate = self
        view.clipsToBounds = true
        view.isOpaque = true
        for gesture in gestureRecognizers where gesture is UITapGestureRecognizer {
            gesture.isEnabled = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(pages: [ReaderPage], index: Int, appearance: ReaderPageAppearance) {
        let configuration = EngineConfiguration(pages: pages, index: index, appearance: appearance)
        guard !transaction.isLocked else { pendingConfiguration = configuration; return }
        let contentChanged = self.pages.map(\.id) != pages.map(\.id)
        let appearanceChanged = self.appearance != appearance
        let layoutChanged = self.appearance.map { !$0.hasSameLayout(as: appearance) } ?? true
        if contentChanged || layoutChanged {
            frontCache.removeAll(keepingCapacity: true)
            backCache.removeAll(keepingCapacity: true)
        }
        self.pages = pages
        self.appearance = appearance
        let safeIndex = min(max(index, 0), max(pages.count - 1, 0))
        transaction.rebase(to: safeIndex)
        if contentChanged || layoutChanged || visibleIndex != safeIndex {
            setViewControllers(visibleControllers(index: safeIndex), direction: .forward, animated: false)
        } else if appearanceChanged {
            frontCache.values.forEach { $0.updateHighlight(using: appearance) }
        }
        view.backgroundColor = appearance.backgroundColor
        view.layer.backgroundColor = appearance.backgroundColor.cgColor
        preloadPages(around: safeIndex)
    }

    func turn(_ direction: PageTurnDirection) {
        guard let target = transaction.begin(direction: direction, pageCount: pages.count) else {
            bounceAtBoundary(direction)
            return
        }
        let navigation: NavigationDirection = direction == .forward ? .forward : .reverse
        setViewControllers(visibleControllers(index: target), direction: navigation, animated: true) { [weak self] finished in
            guard let self else { return }
            let committed = self.transaction.finish(committed: finished)
            if let committed {
                self.preloadPages(around: committed)
                self.onCommit?(self.pages[committed].location)
            }
            self.applyPendingConfigurationIfNeeded()
        }
    }

    func setInteractionEnabled(_ enabled: Bool) {
        for gesture in gestureRecognizers where !(gesture is UITapGestureRecognizer) {
            gesture.isEnabled = enabled
        }
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let side = viewController as? CurlPageSide, side.physicalPageIndex > 0 else { return nil }
        return controller(physicalIndex: side.physicalPageIndex - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let side = viewController as? CurlPageSide else { return nil }
        let lastFront = max(0, (pages.count - 1) * 2)
        guard side.physicalPageIndex < lastFront else { return nil }
        return controller(physicalIndex: side.physicalPageIndex + 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        guard let pending = pendingViewControllers.compactMap({ $0 as? CurlPageSide }).first else { return }
        let current = transaction.currentIndex
        let target: Int
        if let front = pending as? ReaderPageContentController {
            target = front.pageIndex
        } else {
            let backIndex = (pending as? ReaderPageBackContentController)?.pageIndex ?? current
            // Forward reveals the back of the current sheet; backward reveals
            // the back of the previous sheet. Resolve both to the final front.
            target = backIndex == current ? current + 1 : backIndex
        }
        _ = transaction.begin(targetIndex: target, pageCount: pages.count)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        let committed = transaction.finish(committed: completed)
        if let committed {
            preloadPages(around: committed)
            onCommit?(pages[committed].location)
        }
        applyPendingConfigurationIfNeeded()
    }

    private var visibleIndex: Int? {
        viewControllers?.compactMap { ($0 as? ReaderPageContentController)?.pageIndex }.first
    }

    private func visibleControllers(index: Int) -> [UIViewController] {
        [makeFrontController(index: index)]
    }

    private func controller(physicalIndex: Int) -> UIViewController? {
        guard physicalIndex >= 0 else { return nil }
        if physicalIndex.isMultiple(of: 2) {
            let pageIndex = physicalIndex / 2
            return pages.indices.contains(pageIndex) ? makeFrontController(index: pageIndex) : nil
        }
        let pageIndex = (physicalIndex - 1) / 2
        return pages.indices.contains(pageIndex) ? makeBackController(index: pageIndex) : nil
    }

    private func makeFrontController(index: Int) -> ReaderPageContentController {
        if let cached = frontCache[index] { return cached }
        let controller = ReaderPageContentController(page: pages[index], pageIndex: index, appearance: appearance!)
        controller.loadViewIfNeeded()
        frontCache[index] = controller
        return controller
    }

    private func makeBackController(index: Int) -> ReaderPageBackContentController {
        if let cached = backCache[index] { return cached }
        let page = pages.indices.contains(index) ? pages[index] : nil
        let controller = ReaderPageBackContentController(page: page, pageIndex: index, appearance: appearance!)
        controller.loadViewIfNeeded()
        backCache[index] = controller
        return controller
    }

    private func preloadPages(around index: Int) {
        let retainedFronts = Set([index - 1, index, index + 1].filter { pages.indices.contains($0) })
        let retainedBacks = Set([index - 1, index].filter { pages.indices.contains($0) })
        retainedFronts.forEach { _ = makeFrontController(index: $0) }
        retainedBacks.forEach { _ = makeBackController(index: $0) }
        frontCache = frontCache.filter { retainedFronts.contains($0.key) }
        backCache = backCache.filter { retainedBacks.contains($0.key) }
    }

    private func bounceAtBoundary(_ direction: PageTurnDirection) {
        let distance: CGFloat = direction == .forward ? -13 : 13
        UIView.animateKeyframes(withDuration: 0.24, delay: 0, options: [.allowUserInteraction, .calculationModeCubic]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.45) { self.view.transform = CGAffineTransform(translationX: distance, y: 0) }
            UIView.addKeyframe(withRelativeStartTime: 0.45, relativeDuration: 0.55) { self.view.transform = .identity }
        } completion: { [weak self] _ in
            _ = self?.transaction.finish(committed: false)
            self?.applyPendingConfigurationIfNeeded()
        }
    }

    private func applyPendingConfigurationIfNeeded() {
        guard let pendingConfiguration else { return }
        self.pendingConfiguration = nil
        configure(pages: pendingConfiguration.pages, index: pendingConfiguration.index, appearance: pendingConfiguration.appearance)
    }
}

private final class CoverPageTurnController: UIViewController, PageTurnEngine, UIGestureRecognizerDelegate {
    var onCommit: ((ReaderPageLocation) -> Void)?
    var isTransitioning: Bool { transaction.isLocked }

    private let animationDuration: TimeInterval
    private var pages: [ReaderPage] = []
    private var appearance: ReaderPageAppearance?
    private var transaction = PageTurnTransaction(currentIndex: 0)
    private var currentController: ReaderPageContentController?
    private var adjacentController: ReaderPageContentController?
    private var controllerCache: [Int: ReaderPageContentController] = [:]
    private var interactionDirection: PageTurnDirection?
    private var pendingConfiguration: EngineConfiguration?
    private weak var panGesture: UIPanGestureRecognizer?

    init(animationDuration: TimeInterval) {
        self.animationDuration = animationDuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        view.addGestureRecognizer(pan)
        panGesture = pan
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !transaction.isLocked else { return }
        currentController?.view.frame = view.bounds
    }

    func configure(pages: [ReaderPage], index: Int, appearance: ReaderPageAppearance) {
        let configuration = EngineConfiguration(pages: pages, index: index, appearance: appearance)
        guard !transaction.isLocked else { pendingConfiguration = configuration; return }
        let contentChanged = self.pages.map(\.id) != pages.map(\.id)
        let appearanceChanged = self.appearance != appearance
        let layoutChanged = self.appearance.map { !$0.hasSameLayout(as: appearance) } ?? true
        let safeIndex = min(max(index, 0), max(pages.count - 1, 0))
        if contentChanged || layoutChanged { controllerCache.removeAll(keepingCapacity: true) }
        self.pages = pages
        self.appearance = appearance
        view.backgroundColor = appearance.backgroundColor
        if contentChanged || layoutChanged || currentController?.pageIndex != safeIndex {
            transaction.rebase(to: safeIndex)
            replaceCurrent(with: makeController(index: safeIndex))
        } else if appearanceChanged {
            controllerCache.values.forEach { $0.updateHighlight(using: appearance) }
        }
        preloadNeighbors(around: safeIndex)
    }

    func turn(_ direction: PageTurnDirection) {
        guard let target = transaction.begin(direction: direction, pageCount: pages.count) else {
            boundaryBounce(direction)
            return
        }
        prepareAdjacent(index: target, direction: direction)
        settle(commit: true, direction: direction)
    }

    func setInteractionEnabled(_ enabled: Bool) {
        panGesture?.isEnabled = enabled
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !transaction.isLocked, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: view)
        return abs(velocity.x) > abs(velocity.y)
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view).x
        switch pan.state {
        case .began:
            let velocity = pan.velocity(in: view).x
            let direction: PageTurnDirection = velocity < 0 ? .forward : .backward
            interactionDirection = direction
            if let target = transaction.begin(direction: direction, pageCount: pages.count) {
                // The adjacent controller is attached before the first changed
                // frame, including the last page of the previous chapter.
                prepareAdjacent(index: target, direction: direction)
            }
        case .changed:
            updateInteractivePosition(translation: translation)
        case .ended, .cancelled, .failed:
            guard let direction = interactionDirection else { return }
            let velocity = pan.velocity(in: view).x
            let commit = transaction.targetIndex != nil && PageTurnGestureDecision.shouldCommit(
                translation: translation,
                velocity: velocity,
                width: view.bounds.width,
                direction: direction,
                gestureEnded: pan.state == .ended
            )
            settle(commit: commit, direction: direction)
        default:
            break
        }
    }

    private func updateInteractivePosition(translation: CGFloat) {
        guard let direction = interactionDirection else { return }
        let width = max(view.bounds.width, 1)
        guard transaction.targetIndex != nil else {
            let resisted = max(-24, min(24, translation * 0.09))
            currentController?.view.transform = CGAffineTransform(translationX: resisted, y: 0)
            return
        }
        switch direction {
        case .forward:
            let distance = min(width, max(0, -translation))
            currentController?.view.frame.origin.x = -distance
        case .backward:
            let distance = min(width, max(0, translation))
            adjacentController?.view.frame.origin.x = -width + distance
            currentController?.view.frame.origin.x = distance
        }
    }

    private func prepareAdjacent(index: Int, direction: PageTurnDirection) {
        guard adjacentController == nil else { return }
        let controller = makeController(index: index)
        adjacentController = controller
        addChild(controller)
        if direction == .forward {
            view.insertSubview(controller.view, belowSubview: currentController!.view)
            controller.view.frame = view.bounds
            applyPageShadow(to: currentController!.view, leading: false)
        } else {
            view.insertSubview(controller.view, belowSubview: currentController!.view)
            controller.view.frame = view.bounds.offsetBy(dx: -view.bounds.width, dy: 0)
            applyPageShadow(to: currentController!.view, leading: false)
        }
        controller.didMove(toParent: self)
    }

    private func settle(commit: Bool, direction: PageTurnDirection) {
        let width = max(view.bounds.width, 1)
        let currentProgress: CGFloat
        switch direction {
        case .forward: currentProgress = abs(currentController?.view.frame.minX ?? 0) / width
        case .backward: currentProgress = max(0, min(1, (currentController?.view.frame.minX ?? 0) / width))
        }
        let duration = max(0.01, animationDuration * Double(commit ? 1 - currentProgress : currentProgress + 0.25))

        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: commit ? 0.96 : 0.78,
            initialSpringVelocity: 0.12,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
            self.currentController?.view.transform = .identity
            if direction == .forward {
                self.currentController?.view.frame.origin.x = commit ? -width : 0
            } else {
                self.adjacentController?.view.frame.origin.x = commit ? 0 : -width
                self.currentController?.view.frame.origin.x = commit ? width : 0
            }
        } completion: { [weak self] _ in
            self?.finishSettlement(committed: commit, direction: direction)
        }
    }

    private func finishSettlement(committed: Bool, direction: PageTurnDirection) {
        if committed, let adjacentController {
            removeController(currentController)
            currentController = adjacentController
            currentController?.view.frame = view.bounds
            currentController?.view.layer.shadowOpacity = 0
        } else {
            currentController?.view.frame = view.bounds
            currentController?.view.transform = .identity
            currentController?.view.layer.shadowOpacity = 0
            removeController(adjacentController)
        }
        adjacentController = nil
        interactionDirection = nil
        let committedIndex = transaction.finish(committed: committed)
        if let committedIndex {
            preloadNeighbors(around: committedIndex)
            onCommit?(pages[committedIndex].location)
        }
        applyPendingConfigurationIfNeeded()
    }

    private func boundaryBounce(_ direction: PageTurnDirection) {
        let distance: CGFloat = direction == .forward ? -15 : 15
        UIView.animate(withDuration: 0.11, animations: {
            self.currentController?.view.transform = CGAffineTransform(translationX: distance, y: 0)
        }) { _ in
            UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) {
                self.currentController?.view.transform = .identity
            } completion: { [weak self] _ in
                _ = self?.transaction.finish(committed: false)
                self?.applyPendingConfigurationIfNeeded()
            }
        }
    }

    private func replaceCurrent(with controller: ReaderPageContentController) {
        removeController(currentController)
        addChild(controller)
        view.addSubview(controller.view)
        controller.view.frame = view.bounds
        controller.didMove(toParent: self)
        currentController = controller
    }

    private func makeController(index: Int) -> ReaderPageContentController {
        if let cached = controllerCache[index] { return cached }
        let controller = ReaderPageContentController(page: pages[index], pageIndex: index, appearance: appearance!)
        controller.loadViewIfNeeded()
        controllerCache[index] = controller
        return controller
    }

    private func preloadNeighbors(around index: Int) {
        let retained = Set([index - 1, index, index + 1].filter { pages.indices.contains($0) })
        for candidate in retained { _ = makeController(index: candidate) }
        controllerCache = controllerCache.filter { retained.contains($0.key) }
    }

    private func applyPageShadow(to pageView: UIView, leading: Bool) {
        pageView.layer.shadowColor = UIColor.black.cgColor
        pageView.layer.shadowOpacity = 0.28
        pageView.layer.shadowRadius = 12
        pageView.layer.shadowOffset = CGSize(width: leading ? 6 : -6, height: 0)
        pageView.layer.shadowPath = UIBezierPath(rect: pageView.bounds).cgPath
    }

    private func removeController(_ controller: UIViewController?) {
        guard let controller else { return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    private func applyPendingConfigurationIfNeeded() {
        guard let pendingConfiguration else { return }
        self.pendingConfiguration = nil
        configure(pages: pendingConfiguration.pages, index: pendingConfiguration.index, appearance: pendingConfiguration.appearance)
    }
}
