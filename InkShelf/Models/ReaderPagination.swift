import Foundation
import UIKit

struct ReaderPageLocation: Hashable, Codable, Sendable {
    let chapterIndex: Int
    let pageIndex: Int
}

struct ReaderPage: Identifiable, Equatable, Sendable {
    let location: ReaderPageLocation
    let chapterTitle: String
    let text: String
    let pageInChapter: Int
    let pageCountInChapter: Int
    let overallIndex: Int
    let overallCount: Int

    var id: ReaderPageLocation { location }
    var overallProgress: Double {
        guard overallCount > 0 else { return 0 }
        return min(1, Double(overallIndex + 1) / Double(overallCount))
    }

    var chapterHeadingPrefix: String {
        pageInChapter == 1 && chapterTitle != "正文" ? "\(chapterTitle)\n\n" : ""
    }

    var displayText: String { chapterHeadingPrefix + text }
}

/// The same TextKit geometry used by the reader page. Pagination must be based
/// on laid-out glyphs instead of an estimated character count; otherwise a page
/// can contain text below the visible text view and narration appears to skip
/// that hidden text when it eventually advances.
struct ReaderPaginationLayout: Hashable, Sendable {
    let textWidth: CGFloat
    let textHeight: CGFloat
    let fontName: String?
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let paragraphFirstLineIndent: CGFloat

    func pages(
        for text: String,
        chapterTitle: String?
    ) -> [String] {
        guard !text.isEmpty else { return [text] }
        let source = text as NSString
        let textStorage = NSTextStorage(
            attributedString: attributedText(text, chapterTitle: chapterTitle)
        )
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        var result: [String] = []
        var cursor = 0

        while cursor < source.length {
            let textContainer = NSTextContainer(
                size: CGSize(width: max(1, textWidth), height: max(1, textHeight))
            )
            textContainer.lineFragmentPadding = 0
            textContainer.lineBreakMode = .byWordWrapping
            layoutManager.addTextContainer(textContainer)
            layoutManager.ensureLayout(for: textContainer)
            let glyphRange = layoutManager.glyphRange(for: textContainer)
            guard glyphRange.length > 0 else {
                let fallbackRange = source.rangeOfComposedCharacterSequence(
                    at: min(cursor, source.length - 1)
                )
                result.append(source.substring(with: fallbackRange))
                cursor = NSMaxRange(fallbackRange)
                continue
            }
            let characterRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            let pageEnd = min(source.length, max(cursor + 1, NSMaxRange(characterRange)))
            let pageRange = NSRange(location: cursor, length: pageEnd - cursor)
            result.append(source.substring(with: pageRange))
            cursor = pageEnd
        }
        return result
    }

    func fits(_ text: String, chapterTitle: String?) -> Bool {
        visibleUTF16Length(in: text, chapterTitle: chapterTitle) >= (text as NSString).length
    }

    private func visibleUTF16Length(in text: String, chapterTitle: String?) -> Int {
        let textStorage = NSTextStorage(
            attributedString: attributedText(text, chapterTitle: chapterTitle)
        )
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: CGSize(width: max(1, textWidth), height: max(1, textHeight))
        )
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byWordWrapping
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        guard glyphRange.length > 0 else { return 1 }
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )
        return max(1, NSMaxRange(characterRange))
    }

    private func attributedText(_ text: String, chapterTitle: String?) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: bodyAttributes
        )
        if let chapterTitle,
           text.hasPrefix(chapterTitle) {
            let titleLength = (chapterTitle as NSString).length
            attributed.addAttributes(
                titleAttributes,
                range: NSRange(location: 0, length: min(titleLength, attributed.length))
            )
        }
        return attributed
    }

    private var bodyAttributes: [NSAttributedString.Key: Any] {
        let font = fontName.flatMap { UIFont(name: $0, size: fontSize) }
            ?? UIFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = .natural
        // The paragraph play button occupies this leading space while a read
        // aloud session is attached. Reserving the same indent on every line
        // makes independently rendered continuation pages no taller than the
        // TextKit pagination pass.
        paragraph.firstLineHeadIndent = paragraphFirstLineIndent
        paragraph.headIndent = paragraphFirstLineIndent
        return [.font: font, .paragraphStyle: paragraph]
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        let font = fontName.flatMap { UIFont(name: $0, size: fontSize + 6) }
            ?? UIFont.systemFont(ofSize: fontSize + 6, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = lineSpacing + 8
        paragraph.firstLineHeadIndent = 0
        return [.font: font, .paragraphStyle: paragraph]
    }

}

struct ReaderPageCatalog: Equatable, Sendable {
    private(set) var pages: [ReaderPage]
    private let indices: [ReaderPageLocation: Int]

    static let empty = ReaderPageCatalog(pages: [])

    init(pages: [ReaderPage]) {
        self.pages = pages
        indices = Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($0.element.location, $0.offset) })
    }

    init(book: NovelBook, charactersPerPage: Int) {
        self.init(book: book) { chapter in
            NovelParser.pages(
                for: chapter,
                charactersPerPage: charactersPerPage,
                includesChapterTitle: true
            )
        }
    }

    init(book: NovelBook, paginationLayout: ReaderPaginationLayout) {
        self.init(book: book) { chapter in
            let headingPrefix = chapter.title == "正文" ? "" : "\(chapter.title)\n\n"
            let body = chapter.content.isEmpty ? "本章暂无正文" : chapter.content
            return paginationLayout.pages(
                for: headingPrefix + body,
                chapterTitle: headingPrefix.isEmpty ? nil : chapter.title
            )
        }
    }

    private init(
        book: NovelBook,
        pageBuilder: (NovelChapter) -> [String]
    ) {
        var drafts: [(ReaderPageLocation, String, String, Int, Int)] = []
        for chapter in book.chapters {
            let chapterPages = pageBuilder(chapter)
            for (pageIndex, text) in chapterPages.enumerated() {
                let headingPrefix = chapter.title == "正文" ? "" : "\(chapter.title)\n\n"
                let bodyText: String
                if pageIndex == 0, !headingPrefix.isEmpty, text.hasPrefix(headingPrefix) {
                    bodyText = String(text.dropFirst(headingPrefix.count))
                } else {
                    bodyText = text
                }
                drafts.append((
                    ReaderPageLocation(chapterIndex: chapter.index, pageIndex: pageIndex),
                    chapter.title,
                    bodyText,
                    pageIndex + 1,
                    chapterPages.count
                ))
            }
        }

        let total = drafts.count
        let completePages = drafts.enumerated().map { offset, draft in
            ReaderPage(
                location: draft.0,
                chapterTitle: draft.1,
                text: draft.2,
                pageInChapter: draft.3,
                pageCountInChapter: draft.4,
                overallIndex: offset,
                overallCount: total
            )
        }
        self.init(pages: completePages)
    }

    var isEmpty: Bool { pages.isEmpty }
    var count: Int { pages.count }

    func index(of location: ReaderPageLocation) -> Int? { indices[location] }

    func page(at location: ReaderPageLocation) -> ReaderPage? {
        index(of: location).map { pages[$0] }
    }

    func page(at index: Int) -> ReaderPage? {
        pages.indices.contains(index) ? pages[index] : nil
    }

    func adjacent(to location: ReaderPageLocation, direction: PageTurnDirection) -> ReaderPage? {
        guard let current = index(of: location) else { return nil }
        return page(at: current + direction.offset)
    }

    func nearest(to location: ReaderPageLocation) -> ReaderPageLocation? {
        if indices[location] != nil { return location }
        let sameChapter = pages.filter { $0.location.chapterIndex == location.chapterIndex }
        if let page = sameChapter.last(where: { $0.location.pageIndex <= location.pageIndex }) ?? sameChapter.first {
            return page.location
        }
        return pages.first?.location
    }
}

enum PageTurnDirection: Equatable {
    case forward
    case backward

    var offset: Int { self == .forward ? 1 : -1 }
}

/// Direction-aware completion math shared by interactive renderers. Projecting
/// the release velocity makes a short, intentional flick complete without making
/// a slow, short drag accidentally turn the page.
struct PageTurnGestureDecision {
    static func progress(translation: CGFloat, width: CGFloat, direction: PageTurnDirection) -> CGFloat {
        let directedDistance = direction == .forward ? -translation : translation
        return max(0, min(1, directedDistance / max(width, 1)))
    }

    static func shouldCommit(
        translation: CGFloat,
        velocity: CGFloat,
        width: CGFloat,
        direction: PageTurnDirection,
        gestureEnded: Bool
    ) -> Bool {
        guard gestureEnded else { return false }
        let current = progress(translation: translation, width: width, direction: direction)
        let projected = progress(
            translation: translation + velocity * 0.18,
            width: width,
            direction: direction
        )
        return current >= 0.32 || projected >= 0.5
    }
}

struct ReaderDismissGestureDecision {
    static func shouldFinish(
        translation: CGFloat,
        predictedTranslation: CGFloat,
        width: CGFloat
    ) -> Bool {
        let safeWidth = max(width, 1)
        let progress = max(0, translation) / safeWidth
        let projectedProgress = max(0, predictedTranslation) / safeWidth
        return progress >= 0.3 || projectedProgress >= 0.5
    }
}

/// A small transaction gate shared by both rendering engines. The committed
/// index never changes until the visual transition reports completion.
struct PageTurnTransaction: Equatable {
    private(set) var currentIndex: Int
    private(set) var targetIndex: Int?
    private(set) var direction: PageTurnDirection?
    private(set) var isLocked = false

    init(currentIndex: Int) { self.currentIndex = currentIndex }

    mutating func begin(direction: PageTurnDirection, pageCount: Int) -> Int? {
        guard !isLocked else { return nil }
        isLocked = true
        self.direction = direction
        let candidate = currentIndex + direction.offset
        guard (0..<pageCount).contains(candidate) else {
            targetIndex = nil
            return nil
        }
        targetIndex = candidate
        return candidate
    }

    mutating func begin(targetIndex: Int, pageCount: Int) -> Bool {
        guard !isLocked, (0..<pageCount).contains(targetIndex), targetIndex != currentIndex else { return false }
        isLocked = true
        self.targetIndex = targetIndex
        direction = targetIndex > currentIndex ? .forward : .backward
        return true
    }

    mutating func finish(committed: Bool) -> Int? {
        let committedIndex = committed ? targetIndex : nil
        if let committedIndex { currentIndex = committedIndex }
        targetIndex = nil
        direction = nil
        isLocked = false
        return committedIndex
    }

    mutating func rebase(to index: Int) {
        guard !isLocked else { return }
        currentIndex = index
    }
}
