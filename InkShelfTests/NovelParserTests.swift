import XCTest
import UIKit
import UniformTypeIdentifiers
import CoreFoundation
@testable import InkShelf

final class NovelParserTests: XCTestCase {
    func testReadAloudPlanKeepsSentenceAndParagraphRangesInUTF16Coordinates() throws {
        let text = "  第一段😀第一句。第二句！\n\n第二段内容。  "
        let plan = ReadAloudTextPlan(text: text)
        let nsText = text as NSString

        XCTAssertEqual(plan.sentences.map { nsText.substring(with: $0.range) }, [
            "第一段😀第一句。",
            "第二句！",
            "第二段内容。"
        ])
        XCTAssertEqual(plan.paragraphRanges.map { nsText.substring(with: $0) }, [
            "第一段😀第一句。第二句！",
            "第二段内容。"
        ])
    }

    func testParagraphStartResolvesToItsFirstSpokenSentence() throws {
        let text = "第一段第一句。第一段第二句。\n第二段第一句。"
        let plan = ReadAloudTextPlan(text: text)
        let secondParagraph = try XCTUnwrap(plan.paragraphRanges.last)
        let sentenceIndex = try XCTUnwrap(
            plan.sentenceIndex(atOrAfterUTF16Location: secondParagraph.location)
        )

        XCTAssertEqual(plan.sentences[sentenceIndex].text, "第二段第一句。")
        XCTAssertTrue(NSIntersectionRange(plan.sentences[sentenceIndex].range, secondParagraph).length > 0)
    }

    func testBookGridCoverSizeKeepsAStablePortraitRatio() {
        XCTAssertEqual(BookGridLayout.coverWidth, 96)
        XCTAssertEqual(
            BookGridLayout.coverWidth / BookGridLayout.coverHeight,
            0.68,
            accuracy: 0.001
        )
    }

    func testSelectedCoverIsDownsampledBeforeItIsStored() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(
            size: CGSize(width: 2600, height: 1200),
            format: format
        ).pngData { context in
            UIColor.systemIndigo.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2600, height: 1200))
        }

        let processed = try CoverImageProcessor.preparedData(from: source)
        let decoded = try XCTUnwrap(UIImage(data: processed))

        XCTAssertLessThanOrEqual(
            max(decoded.size.width, decoded.size.height),
            CGFloat(CoverImageProcessor.maximumPixelSize)
        )
    }

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

    func testReaderCatalogStartsEveryChapterWithItsTitle() {
        let book = NovelBook(
            title: "章节标题测试",
            content: "第一章 开始\n这是开篇正文。\n第二章 继续\n这是后续正文。"
        )
        let catalog = ReaderPageCatalog(book: book, charactersPerPage: 5)
        let firstChapterPage = catalog.pages.first { $0.location.chapterIndex == 0 }
        let secondChapterPage = catalog.pages.first { $0.location.chapterIndex == 1 }

        XCTAssertTrue(firstChapterPage?.displayText.hasPrefix("第一章 开始\n\n") == true)
        XCTAssertTrue(secondChapterPage?.displayText.hasPrefix("第二章 继续\n\n") == true)
        XCTAssertFalse(firstChapterPage?.text.contains("第一章 开始") == true)
        XCTAssertFalse(secondChapterPage?.text.contains("第二章 继续") == true)
        XCTAssertEqual(
            catalog.pages
                .filter { $0.location.chapterIndex == 0 }
                .map(\.text)
                .joined(),
            book.chapters[0].content
        )
        XCTAssertEqual(
            catalog.pages
                .filter { $0.location.chapterIndex == 1 }
                .map(\.text)
                .joined(),
            book.chapters[1].content
        )
    }

    func testLayoutPaginationKeepsEveryPageVisibleAndTextContinuous() {
        let body = String(repeating: "杨飞见识了许多风景，故事仍在继续。\n", count: 30)
        let book = NovelBook(
            title: "排版分页测试",
            content: "第2063章 我要生男孩啊！\n\(body)"
        )
        let layout = ReaderPaginationLayout(
            textWidth: 320,
            textHeight: 520,
            fontName: nil,
            fontSize: 26,
            lineSpacing: 9,
            paragraphFirstLineIndent: 26
        )
        let catalog = ReaderPageCatalog(book: book, paginationLayout: layout)
        let chapterPages = catalog.pages.filter { $0.location.chapterIndex == 0 }

        XCTAssertGreaterThan(chapterPages.count, 1)
        XCTAssertEqual(chapterPages.map(\.text).joined(), book.chapters[0].content)
        for page in chapterPages {
            XCTAssertTrue(
                layout.fits(
                    page.displayText,
                    chapterTitle: page.pageInChapter == 1 ? page.chapterTitle : nil
                ),
                "第 \(page.pageInChapter) 页存在屏幕下方不可见正文"
            )
        }
    }

    func testLayoutPaginationRemainsFastForVeryLongBooks() {
        let body = String(repeating: "这是用于验证长篇小说快速分页且上下文连续的一段正文。\n", count: 20_000)
        let book = NovelBook(title: "长篇分页测试", content: "第一章 开始\n\(body)")
        let layout = ReaderPaginationLayout(
            textWidth: 320,
            textHeight: 520,
            fontName: nil,
            fontSize: 26,
            lineSpacing: 9,
            paragraphFirstLineIndent: 26
        )

        let catalog = ReaderPageCatalog(book: book, paginationLayout: layout)

        XCTAssertGreaterThan(catalog.pages.count, 1_000)
        XCTAssertEqual(catalog.pages.map(\.text).joined(), book.chapters[0].content)
    }

    func testLayoutPaginationContinuesAParagraphOnTheNextPage() throws {
        let uninterruptedParagraph = String(repeating: "这一段正文必须逐字跨页继续", count: 120)
        let book = NovelBook(
            title: "跨页续段测试",
            content: "第一章 开始\n\(uninterruptedParagraph)"
        )
        let layout = ReaderPaginationLayout(
            textWidth: 320,
            textHeight: 520,
            fontName: nil,
            fontSize: 26,
            lineSpacing: 9,
            paragraphFirstLineIndent: 26
        )
        let catalog = ReaderPageCatalog(book: book, paginationLayout: layout)
        let pages = catalog.pages.filter { $0.location.chapterIndex == 0 }

        XCTAssertGreaterThan(pages.count, 2)
        XCTAssertTrue(pages.dropLast().contains { page in
            guard let last = page.text.last else { return false }
            return !"。！？；\n".contains(last)
        })
        XCTAssertEqual(pages.map(\.text).joined(), uninterruptedParagraph)
        for page in pages {
            XCTAssertTrue(
                layout.fits(
                    page.displayText,
                    chapterTitle: page.pageInChapter == 1 ? page.chapterTitle : nil
                )
            )
        }
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
        let data = try XCTUnwrap(Data(base64Encoded: "tdrSu9XCILfnxvAK1eLKxyBHQksgseDC67XE1tDOxNChy7XV/c7EoaM="))

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
        let source = "第一章 开始\n导入后应该立即出现在书架。\n第二章 继续\n跨章后书架进度应该立即刷新。"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(source.utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LibraryStore(storageDirectory: storage, seedSampleBook: false)
        let task = try XCTUnwrap(store.importNovel(from: sourceURL))
        await task.value

        XCTAssertFalse(store.isImporting)
        XCTAssertEqual(store.books.count, 1)
        XCTAssertEqual(store.books.first?.title, "中文小说 （完整版）")
        XCTAssertEqual(store.books.first?.chapters.count, 2)
        XCTAssertTrue(store.alertMessage?.contains("成功导入") == true)

        let importedBookID = try XCTUnwrap(store.books.first?.id)
        store.updateProgress(bookID: importedBookID, chapter: 1, page: 0)
        XCTAssertEqual(store.books.first?.chapterProgressDescription, "2章 / 2章")

        let reloadedStore = LibraryStore(storageDirectory: storage, seedSampleBook: false)
        XCTAssertEqual(reloadedStore.books.count, 1)
        XCTAssertEqual(reloadedStore.books.first?.content, source)
        XCTAssertEqual(reloadedStore.books.first?.currentChapter, 1)
        XCTAssertEqual(reloadedStore.books.first?.chapterProgressDescription, "2章 / 2章")
    }
}

final class ReaderPaginationTests: XCTestCase {
    func testPageCacheDetectsChangedTextAtTheSameLocation() {
        let location = ReaderPageLocation(chapterIndex: 0, pageIndex: 0)
        let oldPage = ReaderPage(
            location: location,
            chapterTitle: "第一章",
            text: "旧分页正文。",
            pageInChapter: 1,
            pageCountInChapter: 1,
            overallIndex: 0,
            overallCount: 1
        )
        let newPage = ReaderPage(
            location: location,
            chapterTitle: "第一章",
            text: "重新分页后的连续正文。",
            pageInChapter: 1,
            pageCountInChapter: 1,
            overallIndex: 0,
            overallCount: 1
        )

        XCTAssertTrue(
            readerPageContentChanged(
                from: [oldPage],
                to: [newPage],
                retainedIndices: [0]
            )
        )
    }

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

    func testReaderEdgeDismissUsesDistanceAndProjectedVelocity() {
        XCTAssertFalse(ReaderDismissGestureDecision.shouldFinish(
            translation: 80,
            predictedTranslation: 110,
            width: 400
        ))
        XCTAssertTrue(ReaderDismissGestureDecision.shouldFinish(
            translation: 125,
            predictedTranslation: 125,
            width: 400
        ))
        XCTAssertTrue(ReaderDismissGestureDecision.shouldFinish(
            translation: 65,
            predictedTranslation: 230,
            width: 400
        ))
    }
}

final class BookProgressTests: XCTestCase {
    func testChapterProgressUsesRealChapterCounts() {
        let content = """
        第一章 开始
        正文
        第二章 继续
        正文
        第三章 结束
        正文
        """
        let unread = NovelBook(title: "未读", content: content)
        let reading = NovelBook(
            title: "阅读中",
            content: content,
            lastReadAt: Date(),
            currentChapter: 1
        )
        let finished = NovelBook(
            title: "读完",
            content: content,
            lastReadAt: Date(),
            currentChapter: 99
        )

        XCTAssertEqual(unread.chapterProgressDescription, "0章 / 3章")
        XCTAssertEqual(reading.chapterProgressDescription, "2章 / 3章")
        XCTAssertEqual(finished.chapterProgressDescription, "3章 / 3章")
    }

    func testBookshelfUsesEveryCurrentChapterTitleInsteadOfArrayOffsets() {
        let ordinaryChapters = (1...34).map { "第\($0)章 正文\n这是第\($0)章的内容。" }
        let content = (ordinaryChapters + [
            "第43章 继续\n当前阅读内容。",
            "第468章 结局\n最后的内容。"
        ]).joined(separator: "\n")
        let parsedBook = NovelBook(title: "非连续章号", content: content)

        XCTAssertEqual(parsedBook.chapters.count, 36)
        XCTAssertEqual(parsedBook.displayChapterCount, 468)
        for (arrayIndex, expectedChapter) in [(0, 1), (11, 12), (33, 34), (34, 43), (35, 468)] {
            let reading = NovelBook(
                title: "非连续章号",
                content: content,
                lastReadAt: Date(),
                currentChapter: arrayIndex
            )
            XCTAssertEqual(reading.readChapterCount, expectedChapter)
            XCTAssertEqual(reading.chapterProgressDescription, "\(expectedChapter)章 / 468章")
        }
    }

    func testChineseAndFullwidthChapterNumbersAreParsed() {
        XCTAssertEqual(NovelParser.chapterNumber(from: "第四十三章 夜归"), 43)
        XCTAssertEqual(NovelParser.chapterNumber(from: "第４６８回 终章"), 468)
        XCTAssertEqual(NovelParser.chapterNumber(from: "Chapter 120 Finale"), 120)
        XCTAssertNil(NovelParser.chapterNumber(from: "序章"))
    }
}

final class ReaderThemeTests: XCTestCase {
    func testLibraryLayoutsHaveStableStoredValuesAndSymbols() {
        XCTAssertEqual(LibraryLayout.allCases.map(\.rawValue), ["网格", "列表"])
        XCTAssertEqual(LibraryLayout.grid.symbolName, "square.grid.2x2")
        XCTAssertEqual(LibraryLayout.list.symbolName, "list.bullet")
    }

    func testEmailLoginInputValidationAndNormalization() {
        let valid = EmailLoginInput(email: "  Reader@Example.COM ", password: "123456")
        XCTAssertNil(valid.validationMessage)
        XCTAssertEqual(valid.normalizedEmail, "reader@example.com")
        XCTAssertNotNil(EmailLoginInput(email: "reader.example.com", password: "123456").validationMessage)
        XCTAssertNotNil(EmailLoginInput(email: "reader@example.com", password: "123").validationMessage)
    }

    func testEmailRegistrationInputValidationAndNormalization() {
        let valid = EmailRegistrationInput(
            displayName: "  墨架读者  ",
            email: "  NewReader@Example.COM ",
            password: "reader2026",
            passwordConfirmation: "reader2026",
            acceptedTerms: true
        )
        XCTAssertNil(valid.validationMessage)
        XCTAssertEqual(valid.normalizedDisplayName, "墨架读者")
        XCTAssertEqual(valid.normalizedEmail, "newreader@example.com")

        XCTAssertNotNil(EmailRegistrationInput(
            displayName: "读者",
            email: "reader@example.com",
            password: "onlyletters",
            passwordConfirmation: "onlyletters",
            acceptedTerms: true
        ).validationMessage)
        XCTAssertNotNil(EmailRegistrationInput(
            displayName: "读者",
            email: "reader@example.com",
            password: "reader2026",
            passwordConfirmation: "reader2025",
            acceptedTerms: true
        ).validationMessage)
        XCTAssertNotNil(EmailRegistrationInput(
            displayName: "读者",
            email: "reader@example.com",
            password: "reader2026",
            passwordConfirmation: "reader2026",
            acceptedTerms: false
        ).validationMessage)
    }

    func testEveryThemeHasAnOpaqueDistinctPaperBackColor() {
        for theme in ReaderTheme.allCases {
            let front = UIColor(theme.background)
            let back = UIColor(theme.pageBack)

            XCTAssertFalse(front.isEqual(back), "\(theme.rawValue) 的纸张背面必须能与正面区分")
            XCTAssertEqual(back.cgColor.alpha, 1, accuracy: 0.001)
            XCTAssertFalse(back.isEqual(UIColor.white), "\(theme.rawValue) 不应退回系统纯白背面")
        }
    }

    func testReaderBackgroundChoicesHaveStableUniqueKeys() {
        let styles = ReaderBackgroundStyle.allCases
        XCTAssertEqual(styles.count, 7)
        XCTAssertEqual(Set(styles.map(\.rawValue)).count, styles.count)
        XCTAssertTrue(styles.contains(.plain))
        XCTAssertTrue(styles.contains(.bambooWhite))
        XCTAssertTrue(styles.contains(.bambooRice))
        XCTAssertTrue(styles.contains(.bambooGreen))
        XCTAssertTrue(styles.contains(.bambooTea))
        XCTAssertTrue(styles.contains(.bambooNight))
        XCTAssertTrue(styles.contains(.custom))
    }

    func testBundledReaderFontsCanBeRegisteredByPostScriptName() {
        for font in ReaderFont.allCases where font != .system {
            guard let name = font.name else {
                return XCTFail("\(font.rawValue) 缺少 PostScript 名称")
            }
            XCTAssertNotNil(UIFont(name: name, size: 19), "\(font.rawValue) 没有正确注册")
        }
    }

    func testCustomBackgroundControlsHaveStableChoices() {
        XCTAssertEqual(ReaderCustomBackgroundTone.allCases.map(\.rawValue), ["白", "黑"])
        XCTAssertEqual(ReaderCustomBackgroundBlur.allCases.map(\.rawValue), ["无", "低", "中", "高"])
        XCTAssertNil(ReaderCustomBackgroundBlur.none.effectStyle(isDark: false))
        XCTAssertNotNil(ReaderCustomBackgroundBlur.high.effectStyle(isDark: true))
        XCTAssertLessThan(ReaderCustomBackgroundBlur.low.previewRadius, 1)
        XCTAssertLessThan(ReaderCustomBackgroundBlur.low.effectIntensity, ReaderCustomBackgroundBlur.medium.effectIntensity)
        XCTAssertLessThan(ReaderCustomBackgroundBlur.medium.effectIntensity, ReaderCustomBackgroundBlur.high.effectIntensity)
    }
}

final class ReadAloudRoleAnalyzerTests: XCTestCase {
    func testExplicitCharacterNamesReceiveStableSpeakerAssignments() {
        let pages = [
            page(index: 0, text: "张三说：“我们出发。”"),
            page(index: 1, text: "李四问：“现在吗？”")
        ]

        let plan = ReadAloudRoleAnalyzer.plan(for: pages)

        XCTAssertEqual(plan.speakers(for: pages[0].location), [.character("张三")])
        XCTAssertEqual(plan.speakers(for: pages[1].location), [.character("李四")])
    }

    func testNarrationKeepsNarratorVoice() {
        let page = page(index: 0, text: "天色渐渐亮了。远处传来钟声。")

        let speakers = ReadAloudRoleAnalyzer.plan(for: [page]).speakers(for: page.location)

        XCTAssertEqual(speakers, [.narrator, .narrator])
    }

    func testUnknownDialogueAlternatesAcrossPages() {
        let pages = [
            page(index: 0, text: "“你是谁？”"),
            page(index: 1, text: "“先别问，跟我走。”")
        ]

        let plan = ReadAloudRoleAnalyzer.plan(for: pages)

        XCTAssertEqual(plan.speakers(for: pages[0].location), [.unknownDialogue(turn: 0)])
        XCTAssertEqual(plan.speakers(for: pages[1].location), [.unknownDialogue(turn: 1)])
    }

    func testSpeakingVerbsInsideDialogueDoNotCreateCharacterNames() {
        let page = page(index: 0, text: "“先别问，跟我走。”")

        let speakers = ReadAloudRoleAnalyzer.plan(for: [page]).speakers(for: page.location)

        XCTAssertEqual(speakers, [.unknownDialogue(turn: 0)])
    }

    func testUnknownDialogueDoesNotAlternateWhenDisabled() {
        let pages = [
            page(index: 0, text: "“第一句。”"),
            page(index: 1, text: "“第二句。”")
        ]

        let plan = ReadAloudRoleAnalyzer.plan(
            for: pages,
            alternatesUnattributedDialogue: false
        )

        XCTAssertEqual(plan.speakers(for: pages[0].location), [.unknownDialogue(turn: 0)])
        XCTAssertEqual(plan.speakers(for: pages[1].location), [.unknownDialogue(turn: 0)])
    }

    func testSettingsNormalizationClampsRateAndVoiceSlots() {
        var settings = ReadAloudSettings()
        settings.rateMultiplier = 3
        settings.roleVoiceIdentifiers = ["one"]

        let normalized = settings.normalized

        XCTAssertEqual(normalized.rateMultiplier, 1.2)
        XCTAssertEqual(normalized.roleVoiceIdentifiers, ["one", "", ""])
    }

    private func page(index: Int, text: String) -> ReaderPage {
        ReaderPage(
            location: ReaderPageLocation(chapterIndex: 0, pageIndex: index),
            chapterTitle: "第一章",
            text: text,
            pageInChapter: index + 1,
            pageCountInChapter: 2,
            overallIndex: index,
            overallCount: 2
        )
    }
}

final class ReadAloudTimelineTests: XCTestCase {
    private func pages(chapterIndices: [Int]) -> [ReaderPage] {
        chapterIndices.enumerated().map { overallIndex, chapterIndex in
            let pageInChapter = chapterIndices[..<overallIndex].filter { $0 == chapterIndex }.count + 1
            let pageCount = chapterIndices.filter { $0 == chapterIndex }.count
            return ReaderPage(
                location: ReaderPageLocation(chapterIndex: chapterIndex, pageIndex: pageInChapter - 1),
                chapterTitle: "第\(chapterIndex + 1)章",
                text: "第\(chapterIndex + 1)章第\(pageInChapter)页。",
                pageInChapter: pageInChapter,
                pageCountInChapter: pageCount,
                overallIndex: overallIndex,
                overallCount: chapterIndices.count
            )
        }
    }

    func testElapsedTimeMapsBackToTheSamePageAndUTF16Location() {
        let texts = ["第一章正文。", "第二页包含 emoji 📖。", "第三页结束。"]
        let pages = texts.enumerated().map { index, text in
            ReaderPage(
                location: ReaderPageLocation(chapterIndex: index == 2 ? 1 : 0, pageIndex: index == 2 ? 0 : index),
                chapterTitle: index == 2 ? "第二章" : "第一章",
                text: text,
                pageInChapter: index == 2 ? 1 : index + 1,
                pageCountInChapter: index == 2 ? 1 : 2,
                overallIndex: index,
                overallCount: texts.count
            )
        }
        let timeline = ReadAloudTimeline(pages: pages)
        let utf16Location = 5
        let elapsed = timeline.elapsedTime(pageIndex: 1, utf16Location: utf16Location)

        XCTAssertEqual(
            timeline.position(at: elapsed),
            ReadAloudTimeline.Position(pageIndex: 1, utf16Location: utf16Location)
        )
        XCTAssertGreaterThan(timeline.duration, elapsed)
    }

    func testTimelineClampsScrubbingAtBookBoundaries() {
        let page = ReaderPage(
            location: ReaderPageLocation(chapterIndex: 0, pageIndex: 0),
            chapterTitle: "正文",
            text: "用于测试时间轴边界。",
            pageInChapter: 1,
            pageCountInChapter: 1,
            overallIndex: 0,
            overallCount: 1
        )
        let timeline = ReadAloudTimeline(pages: [page])

        XCTAssertEqual(timeline.position(at: -10)?.utf16Location, 0)
        XCTAssertEqual(
            timeline.position(at: timeline.duration + 100)?.utf16Location,
            (page.text as NSString).length - 1
        )
    }

    func testChapterNavigationAlwaysTargetsTheAdjacentChapterFirstPage() {
        let pages = pages(chapterIndices: [0, 0, 1, 1, 1, 2])

        XCTAssertEqual(
            ReadAloudChapterNavigator.currentChapterPageIndices(in: pages, from: 3),
            [2, 3, 4]
        )
        XCTAssertEqual(ReadAloudChapterNavigator.nextChapterPageIndex(in: pages, from: 1), 2)
        XCTAssertEqual(ReadAloudChapterNavigator.nextChapterPageIndex(in: pages, from: 3), 5)
        XCTAssertEqual(ReadAloudChapterNavigator.previousChapterPageIndex(in: pages, from: 4), 0)
        XCTAssertEqual(ReadAloudChapterNavigator.previousChapterPageIndex(in: pages, from: 5), 2)
        XCTAssertNil(ReadAloudChapterNavigator.previousChapterPageIndex(in: pages, from: 0))
        XCTAssertNil(ReadAloudChapterNavigator.nextChapterPageIndex(in: pages, from: 5))
    }
}

final class ReaderRuntimeTests: XCTestCase {
    func testNowPlayingArtworkIsSquareForPortraitBookCover() {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 300)).image { context in
            context.cgContext.setFillColor(UIColor.systemBrown.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 180, height: 300))
        }
        let artwork = NowPlayingArtworkRenderer.squareImage(from: source, dimension: 320)

        XCTAssertEqual(artwork.size.width, 320)
        XCTAssertEqual(artwork.size.height, 320)
        XCTAssertEqual(artwork.size.width, artwork.size.height)
    }

    func testDefaultBookCoverAssetsAreBundled() {
        for style in 0..<BookPalette.styles.count {
            let assetName = BookPalette.defaultCoverAssetName(for: style)
            XCTAssertNotNil(UIImage(named: assetName), "缺少默认小说封面资源：\(assetName)")
        }
    }

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
                bookTitle: "测试书名",
                backgroundColor: UIColor(ReaderTheme.paper.background),
                backsideColor: UIColor(ReaderTheme.paper.pageBack),
                textColor: UIColor(ReaderTheme.paper.foreground),
                backgroundStyle: .plain,
                backgroundImage: nil,
                backgroundOverlayOpacity: 0,
                backgroundBlur: .none,
                fontName: nil,
                fontSize: 19,
                lineSpacing: 9,
                horizontalMargin: 22,
                highlightedLocation: nil,
                highlightedRange: nil,
                showsReadAloudControls: false,
                isReadAloudPlaying: false
            )
            let host = ReaderPageTurnHostController()
            var bodyTapCount = 0
            host.onCenterTap = { bodyTapCount += 1 }
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

            host.performBodyTap()
            XCTAssertEqual(bodyTapCount, 1, "点击正文只能切换工具栏，不能启动另一条程序化翻页事务")
            XCTAssertEqual(curl.viewControllers?.count, 1)
        }
    }

    func testAutomatedCurlTurnCommitsTheNextPage() {
        let pages = (0..<2).map { index in
            ReaderPage(
                location: ReaderPageLocation(chapterIndex: 0, pageIndex: index),
                chapterTitle: "第一章",
                text: "自动朗读第\(index + 1)页。",
                pageInChapter: index + 1,
                pageCountInChapter: 2,
                overallIndex: index,
                overallCount: 2
            )
        }
        let appearance = ReaderPageAppearance(
            themeID: ReaderTheme.paper.rawValue,
            bookTitle: "自动翻页测试",
            backgroundColor: UIColor(ReaderTheme.paper.background),
            backsideColor: UIColor(ReaderTheme.paper.pageBack),
            textColor: UIColor(ReaderTheme.paper.foreground),
            backgroundStyle: .plain,
            backgroundImage: nil,
            backgroundOverlayOpacity: 0,
            backgroundBlur: .none,
            fontName: nil,
            fontSize: 19,
            lineSpacing: 9,
            horizontalMargin: 22,
            highlightedLocation: pages[0].location,
            highlightedRange: NSRange(location: 0, length: 2),
            showsReadAloudControls: true,
            isReadAloudPlaying: true
        )
        let host = ReaderPageTurnHostController()
        let committed = expectation(description: "自动翻页提交下一页")
        var committedLocation: ReaderPageLocation?
        host.onCommit = { location in
            committedLocation = location
            committed.fulfill()
        }
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

        host.configure(
            pages: pages,
            location: pages[0].location,
            appearance: appearance,
            mode: .curl,
            automatedTurnTarget: pages[1].location
        )
        host.view.layoutIfNeeded()

        wait(for: [committed], timeout: 2)
        XCTAssertEqual(committedLocation, pages[1].location)
    }
}
