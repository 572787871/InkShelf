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

    func testUTF8BOMTextImport() throws {
        let source = "第一章 开始\nUTF-8 BOM 小说正文"
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(try XCTUnwrap(source.data(using: .utf8)))

        let imported = try NovelImporter.parse(data: data, fileName: "UTF8", pathExtension: "TXT")

        XCTAssertEqual(imported.content, source)
        XCTAssertEqual(imported.detectedEncoding, "UTF-8 BOM")
    }

    func testUTF16BigEndianBOMTextImport() throws {
        let source = "第一章 开始\nUTF-16 BE 小说正文"
        var data = Data([0xFE, 0xFF])
        data.append(try XCTUnwrap(source.data(using: .utf16BigEndian)))

        let imported = try NovelImporter.parse(data: data, fileName: "UTF16BE", pathExtension: "txt")

        XCTAssertEqual(imported.content, source)
        XCTAssertEqual(imported.detectedEncoding, "UTF-16 BE")
    }

    func testUTF16WithoutBOMDetectsBothEndiannesses() throws {
        let source = "Chapter 1\n没有 BOM 的 UTF-16 小说正文"
        let littleEndian = try XCTUnwrap(source.data(using: .utf16LittleEndian))
        let bigEndian = try XCTUnwrap(source.data(using: .utf16BigEndian))

        let littleImport = try NovelImporter.parse(data: littleEndian, fileName: "LE", pathExtension: "txt")
        let bigImport = try NovelImporter.parse(data: bigEndian, fileName: "BE", pathExtension: "txt")

        XCTAssertEqual(littleImport.content, source)
        XCTAssertEqual(littleImport.detectedEncoding, "UTF-16 LE")
        XCTAssertEqual(bigImport.content, source)
        XCTAssertEqual(bigImport.detectedEncoding, "UTF-16 BE")
    }

    func testGBKTextImportKeepsChineseContent() throws {
        let source = "第一章 风起\n这是 GBK 编码的中文小说正文。"
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GBK_95.rawValue)
        ))
        let data = try XCTUnwrap(source.data(using: encoding))

        let imported = try NovelImporter.parse(data: data, fileName: "中文 文件（校对版）", pathExtension: "TxT")

        XCTAssertEqual(imported.title, "中文 文件（校对版）")
        XCTAssertEqual(imported.content, source)
        XCTAssertEqual(imported.format, .txt)
    }

    func testEmptyAndUnsupportedFilesReturnSpecificErrors() throws {
        XCTAssertThrowsError(try NovelImporter.parse(data: Data(), fileName: "空文件", pathExtension: "txt")) {
            XCTAssertEqual($0 as? ImportError, .empty)
        }
        XCTAssertThrowsError(try NovelImporter.parse(data: Data("内容".utf8), fileName: "文档", pathExtension: "pdf")) {
            XCTAssertEqual($0 as? ImportError, .unsupported)
        }
        XCTAssertThrowsError(try NovelImporter.parse(data: Data([0x81]), fileName: "损坏文本", pathExtension: "txt")) {
            XCTAssertEqual($0 as? ImportError, .cannotDecode)
        }
    }

    func testChineseNamedFileIsCopiedIntoSandboxBeforeReading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("来源 文件", isDirectory: true)
        let stagingDirectory = root.appendingPathComponent("导入临时目录", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = sourceDirectory.appendingPathComponent("《白夜》 （校对版）.TXT")
        let sourceData = Data("第一章 开始\n这是正文。".utf8)
        try sourceData.write(to: sourceURL)

        let staged = try NovelImporter.copyToSandbox(from: sourceURL, stagingDirectory: stagingDirectory)
        defer { NovelImporter.removeStagedFile(staged) }

        XCTAssertNotEqual(staged.localURL, sourceURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.localURL.path))
        XCTAssertEqual(staged.originalFileName, "《白夜》 （校对版）")
        XCTAssertEqual(staged.pathExtension, "TXT")
        XCTAssertEqual(staged.fileSize, sourceData.count)
        XCTAssertEqual(try NovelImporter.readFile(at: staged.localURL), sourceData)
    }

    func testFilePickerAcceptsGenericTextProviders() {
        XCTAssertTrue(NovelImporter.supportedTypes.contains(.data))
        XCTAssertTrue(NovelImporter.supportedTypes.contains(.text))
        XCTAssertTrue(NovelImporter.supportedTypes.contains(.plainText))
        XCTAssertTrue(NovelImporter.supportedTypes.contains(.utf8PlainText))
        XCTAssertTrue(NovelImporter.supportedTypes.contains(UTType(filenameExtension: "txt")!))
    }

    @MainActor
    func testSuccessfulImportRefreshesAndPersistsBookshelf() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = root.appendingPathComponent("书架 数据", isDirectory: true)
        let sourceURL = root.appendingPathComponent("中文小说 （完整版）.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("第一章 开始\n导入后应该立即出现在书架。".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LibraryStore(storageDirectory: storage, seedSampleBook: false)
        let task = try XCTUnwrap(store.importNovel(from: sourceURL))
        await task.value

        XCTAssertFalse(store.isImporting)
        XCTAssertEqual(store.books.count, 1)
        XCTAssertEqual(store.books.first?.title, "中文小说 （完整版）")
        XCTAssertEqual(store.books.first?.chapters.count, 1)
        XCTAssertTrue(store.alertMessage?.contains("成功导入") == true)

        let reloadedStore = LibraryStore(storageDirectory: storage, seedSampleBook: false)
        XCTAssertEqual(reloadedStore.books.count, 1)
        XCTAssertEqual(reloadedStore.books.first?.content, "第一章 开始\n导入后应该立即出现在书架。")
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
        let firstOfSecond = catalog.pages.first { $0.location.chapterIndex == 1 }!
        let next = catalog.adjacent(to: lastOfFirst.location, direction: .forward)
        let previous = catalog.adjacent(to: firstOfSecond.location, direction: .backward)

        XCTAssertEqual(next?.location.chapterIndex, 1)
        XCTAssertEqual(next?.location.pageIndex, 0)
        XCTAssertEqual(previous?.location, lastOfFirst.location)
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

    func testRepeatedBackwardTurnsCommitExactlyOnePageEach() {
        var transaction = PageTurnTransaction(currentIndex: 3)
        XCTAssertEqual(transaction.begin(direction: .backward, pageCount: 5), 2)
        XCTAssertNil(transaction.begin(direction: .backward, pageCount: 5))
        XCTAssertEqual(transaction.finish(committed: true), 2)
        XCTAssertEqual(transaction.begin(direction: .backward, pageCount: 5), 1)
        XCTAssertEqual(transaction.finish(committed: true), 1)
    }

    func testGestureCompletionMathIsDirectionallySymmetric() {
        XCTAssertEqual(
            PageTurnGestureDecision.progress(translation: -120, width: 400, direction: .forward),
            PageTurnGestureDecision.progress(translation: 120, width: 400, direction: .backward),
            accuracy: 0.001
        )
        XCTAssertFalse(PageTurnGestureDecision.shouldCommit(
            translation: 60, velocity: 0, width: 400, direction: .backward, gestureEnded: true
        ))
        XCTAssertTrue(PageTurnGestureDecision.shouldCommit(
            translation: 60, velocity: 900, width: 400, direction: .backward, gestureEnded: true
        ))
        XCTAssertFalse(PageTurnGestureDecision.shouldCommit(
            translation: 180, velocity: 900, width: 400, direction: .backward, gestureEnded: false
        ))
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
    func testCurlReaderCanOpenItsFirstPage() {
        XCTAssertTrue(Thread.isMainThread)
        autoreleasepool {
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
            XCTAssertEqual(curl.spineLocation, .min)
            XCTAssertTrue(curl.isDoubleSided)
            XCTAssertEqual(displayed.count, 1)
            XCTAssertEqual(host.children[0].view.bounds.width, host.view.bounds.width, accuracy: 0.5)
        }
    }
}
