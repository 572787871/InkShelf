import XCTest
@testable import InkShelf

final class NovelParserTests: XCTestCase {
    func testChineseHeadingsBecomeChapters() {
        let text = "序言内容\n第一章 开始\n这是第一章的正文。\n第二章 继续\n这是第二章的正文。"
        let chapters = NovelParser.chapters(from: text)
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].title, "序章")
        XCTAssertEqual(chapters[1].title, "第一章 开始")
        XCTAssertTrue(chapters[2].content.contains("第二章的正文"))
    }

    func testChineseHeadingWithoutWhitespaceIsSupported() {
        let chapters = NovelParser.chapters(from: "第一章风雪夜\n故事从这里开始。\n第二章灯火\n故事继续。")
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "第一章风雪夜")
        XCTAssertEqual(chapters[1].title, "第二章灯火")
    }

    func testEnglishHeadingsBecomeChapters() {
        let chapters = NovelParser.chapters(from: "Chapter 1 Start\nHello\nChapter 2 End\nWorld")
        XCTAssertEqual(chapters.count, 2)
        XCTAssertTrue(chapters[1].content.contains("World"))
    }

    func testPaginationDoesNotLoseText() {
        let source = String(repeating: "这是一句话。", count: 200)
        let chapter = NovelChapter(index: 0, title: "正文", content: source)
        let pages = NovelParser.pages(for: chapter, charactersPerPage: 120)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.joined(), source)
    }
}

final class ReaderPaginationTests: XCTestCase {
    func testCatalogPreloadsAcrossChapterBoundary() {
        let book = NovelBook(
            title: "Test",
            content: "第一章 开始\n" + String(repeating: "甲", count: 24) + "\n第二章 继续\n" + String(repeating: "乙", count: 24)
        )
        let catalog = ReaderPageCatalog(book: book, charactersPerPage: 12)
        let lastOfFirst = catalog.pages.last { $0.location.chapterIndex == 0 }!
        let next = catalog.adjacent(to: lastOfFirst.location, direction: .forward)

        XCTAssertEqual(next?.location.chapterIndex, 1)
        XCTAssertEqual(next?.location.pageIndex, 0)
        XCTAssertEqual(catalog.adjacent(to: catalog.pages[0].location, direction: .backward), nil)
        XCTAssertEqual(catalog.adjacent(to: catalog.pages.last!.location, direction: .forward), nil)
    }

    func testTransactionDoesNotCommitBeforeAnimationFinishes() {
        var transaction = PageTurnTransaction(currentIndex: 1)
        XCTAssertEqual(transaction.begin(direction: .forward, pageCount: 4), 2)
        XCTAssertEqual(transaction.currentIndex, 1)
        XCTAssertTrue(transaction.isLocked)
        XCTAssertNil(transaction.begin(direction: .forward, pageCount: 4))

        XCTAssertEqual(transaction.finish(committed: true), 2)
        XCTAssertEqual(transaction.currentIndex, 2)
        XCTAssertFalse(transaction.isLocked)
    }

    func testCancelledAndBoundaryTurnsKeepCurrentPage() {
        var transaction = PageTurnTransaction(currentIndex: 1)
        XCTAssertEqual(transaction.begin(direction: .backward, pageCount: 3), 0)
        XCTAssertNil(transaction.finish(committed: false))
        XCTAssertEqual(transaction.currentIndex, 1)

        transaction = PageTurnTransaction(currentIndex: 0)
        XCTAssertNil(transaction.begin(direction: .backward, pageCount: 3))
        XCTAssertTrue(transaction.isLocked)
        XCTAssertNil(transaction.finish(committed: false))
        XCTAssertEqual(transaction.currentIndex, 0)
        XCTAssertFalse(transaction.isLocked)
    }
}
