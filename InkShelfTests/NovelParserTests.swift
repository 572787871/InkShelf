import XCTest
import UIKit
import UniformTypeIdentifiers
import CoreFoundation
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

    func testGB18030TextImportKeepsChineseContent() throws {
        let source = "第一章 风起\n这是一段使用 GB18030 编码的中文小说正文。"
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let data = try XCTUnwrap(source.data(using: encoding))
        let imported = try NovelImporter.parse(data: data, fileName: "测试小说", pathExtension: "txt")

        XCTAssertEqual(imported.title, "测试小说")
        XCTAssertEqual(imported.content, source)
        XCTAssertEqual(imported.format, .txt)
    }

    func testUTF16BOMTextImport() throws {
        let source = "第一章\r\nUTF-16 小说正文"
        var data = Data([0xFF, 0xFE])
        data.append(try XCTUnwrap(source.data(using: .utf16LittleEndian)))
        let imported = try NovelImporter.parse(data: data, fileName: "UTF16", pathExtension: "txt")

        XCTAssertEqual(imported.content, "第一章\nUTF-16 小说正文")
    }

    func testFilePickerAcceptsGenericTextProviders() {
        XCTAssertTrue(NovelImporter.supportedTypes.contains(.data))
        XCTAssertTrue(NovelImporter.supportedTypes.contains(.text))
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

final class ReaderThemeTests: XCTestCase {
    func testEveryThemeHasAnOpaqueDistinctPaperBackColor() {
        for theme in ReaderTheme.allCases {
            let front = UIColor(theme.background)
            let back = UIColor(theme.pageBack)

            XCTAssertFalse(front.isEqual(back), "\(theme.rawValue) 的纸张背面必须能与正面区分")
            XCTAssertEqual(back.cgColor.alpha, 1, accuracy: 0.001)
            XCTAssertFalse(back.isEqual(UIColor.white), "\(theme.rawValue) 不应退回系统纯白背面")
        }
    }
}

final class ReaderRuntimeTests: XCTestCase {
    func testCurlReaderCanOpenItsFirstPage() async {
        await MainActor.run {
            let page = ReaderPage(
                location: ReaderPageLocation(chapterIndex: 0, pageIndex: 0),
                chapterTitle: "第一章",
                text: "用于验证阅读器能够安全打开的正文。",
                pageInChapter: 1,
                pageCountInChapter: 1,
                overallIndex: 0,
                overallCount: 1
            )
            let appearance = ReaderPageAppearance(
                themeID: ReaderTheme.paper.rawValue,
                backgroundColor: UIColor(ReaderTheme.paper.background),
                backsideColor: UIColor(ReaderTheme.paper.pageBack),
                textColor: UIColor(ReaderTheme.paper.foreground),
                fontName: nil,
                fontSize: 19,
                lineSpacing: 9,
                horizontalMargin: 22,
                highlightedLocation: nil,
                highlightedRange: nil
            )
            let host = ReaderPageTurnHostController()
            host.loadViewIfNeeded()
            host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

            host.configure(
                pages: [page],
                location: page.location,
                appearance: appearance,
                mode: .curl
            )
            host.view.layoutIfNeeded()

            XCTAssertEqual(host.children.count, 1)
            XCTAssertFalse(host.view.subviews.isEmpty)
            guard let curl = host.children.first as? UIPageViewController,
                  let displayed = curl.viewControllers else {
                return XCTFail("仿真翻页引擎没有正确安装")
            }
            XCTAssertEqual(displayed.count, 2)
            for controller in displayed {
                let before = curl.dataSource?.pageViewController(curl, viewControllerBefore: controller)
                let after = curl.dataSource?.pageViewController(curl, viewControllerAfter: controller)
                if let before {
                    XCTAssertFalse(displayed.contains(where: { $0 === before }), "数据源不能把当前控制器作为上一页返回")
                }
                if let after {
                    XCTAssertFalse(displayed.contains(where: { $0 === after }), "数据源不能把当前控制器作为下一页返回")
                }
            }
        }
    }
}
