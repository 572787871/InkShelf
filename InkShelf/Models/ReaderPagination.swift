import Foundation

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

struct ReaderPageCatalog: Equatable, Sendable {
    private(set) var pages: [ReaderPage]
    private let indices: [ReaderPageLocation: Int]

    static let empty = ReaderPageCatalog(pages: [])

    init(pages: [ReaderPage]) {
        self.pages = pages
        indices = Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($0.element.location, $0.offset) })
    }

    init(book: NovelBook, charactersPerPage: Int) {
        self.init(chapters: book.chapters[...], charactersPerPage: charactersPerPage)
    }

    /// Builds only the focused chapter and its immediate neighbors. Opening a
    /// long novel must not allocate every rendered page before the reader can
    /// appear; adjacent chapters still guarantee seamless cross-chapter turns.
    init(
        book: NovelBook,
        charactersPerPage: Int,
        focusedChapter: Int,
        preloadRadius: Int = 1
    ) {
        guard !book.chapters.isEmpty else {
            self.init(pages: [])
            return
        }
        let safeFocus = min(max(focusedChapter, 0), book.chapters.count - 1)
        let radius = max(preloadRadius, 0)
        let lowerBound = max(0, safeFocus - radius)
        let upperBound = min(book.chapters.count, safeFocus + radius + 1)
        self.init(
            chapters: book.chapters[lowerBound..<upperBound],
            charactersPerPage: charactersPerPage
        )
    }

    private init(chapters: ArraySlice<NovelChapter>, charactersPerPage: Int) {
        var drafts: [(ReaderPageLocation, String, String, Int, Int)] = []
        for chapter in chapters {
            let chapterPages = NovelParser.pages(
                for: chapter,
                charactersPerPage: charactersPerPage,
                includesChapterTitle: true
            )
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
