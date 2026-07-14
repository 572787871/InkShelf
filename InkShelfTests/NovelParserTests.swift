import XCTest
@testable import InkShelf

final class NovelParserTests: XCTestCase {
    func testChineseHeadingsBecomeChapters() {
        let text = "序言内容\n第一章 开始\n第一章正文\n第二章 继续\n第二章正文"
        let chapters = NovelParser.chapters(from: text)
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].title, "序章")
        XCTAssertEqual(chapters[1].title, "第一章 开始")
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
