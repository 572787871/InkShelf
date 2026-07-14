import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [NovelBook] = []
    @Published var alertMessage: String?
    @Published private(set) var isImporting = false

    private let fileURL: URL
    private let booksFolder: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = documents.appendingPathComponent("InkShelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("library.json")
        booksFolder = folder.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: booksFolder, withIntermediateDirectories: true)
        load()
    }

    func importNovel(from url: URL) {
        guard !isImporting else {
            alertMessage = "已有一本小说正在导入，请稍候"
            return
        }
        isImporting = true
        alertMessage = nil
        let hasAccess = url.startAccessingSecurityScopedResource()
        let fileName = url.deletingPathExtension().lastPathComponent
        let pathExtension = url.pathExtension

        Task { [weak self] in
            guard let self else {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
                return
            }
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
                isImporting = false
            }
            do {
                let book = try await Task.detached(priority: .userInitiated) {
                    let data = try NovelImporter.readFile(at: url)
                    let imported = try NovelImporter.parse(
                        data: data,
                        fileName: fileName,
                        pathExtension: pathExtension
                    )
                    return NovelBook(
                        title: imported.title,
                        author: imported.author,
                        content: imported.content,
                        format: imported.format,
                        coverData: imported.coverData
                    )
                }.value
                try addImportedBook(book)
                alertMessage = "《\(book.title)》已成功导入"
            } catch {
                alertMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    func book(id: UUID) -> NovelBook? { books.first(where: { $0.id == id }) }

    func updateProgress(bookID: UUID, chapter: Int, page: Int) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].currentChapter = chapter
        books[index].currentPage = page
        books[index].lastReadAt = .now
        save()
    }

    func toggleBookmark(bookID: UUID, chapter: Int, page: Int, excerpt: String) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        if let bookmark = books[index].bookmarks.firstIndex(where: { $0.chapterIndex == chapter && $0.pageIndex == page }) {
            books[index].bookmarks.remove(at: bookmark)
        } else {
            books[index].bookmarks.append(
                ReaderBookmark(chapterIndex: chapter, pageIndex: page, excerpt: excerpt, createdAt: .now)
            )
        }
        save()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            removeFiles(for: books[index].id)
            books.remove(at: index)
        }
        save()
    }

    func delete(bookID: UUID) {
        books.removeAll(where: { $0.id == bookID })
        removeFiles(for: bookID)
        save()
    }

    func updateMetadata(bookID: UUID, title: String, author: String) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        books[index].author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func addNote(bookID: UUID, chapter: Int, page: Int, excerpt: String, text: String) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].notes.append(ReaderNote(chapterIndex: chapter, pageIndex: page, excerpt: excerpt, text: text, createdAt: .now))
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([BookMetadata].self, from: data) else {
            books = [Self.sampleBook]
            persistFiles(for: Self.sampleBook)
            save()
            return
        }
        books = decoded.compactMap { metadata in
            guard let content = try? String(contentsOf: contentURL(for: metadata.id), encoding: .utf8) else { return nil }
            let cover = try? Data(contentsOf: coverURL(for: metadata.id))
            return metadata.book(content: content, coverData: cover)
        }
    }

    private func save() {
        try? saveThrowing()
    }

    private func saveThrowing() throws {
        let data = try JSONEncoder().encode(books.map(BookMetadata.init))
        try data.write(to: fileURL, options: .atomic)
    }

    private func addImportedBook(_ book: NovelBook) throws {
        try book.content.write(to: contentURL(for: book.id), atomically: true, encoding: .utf8)
        if let cover = book.coverData { try cover.write(to: coverURL(for: book.id), options: .atomic) }
        books.insert(book, at: 0)
        do {
            try saveThrowing()
        } catch {
            books.removeAll(where: { $0.id == book.id })
            removeFiles(for: book.id)
            throw error
        }
    }

    private func persistFiles(for book: NovelBook) {
        try? book.content.write(to: contentURL(for: book.id), atomically: true, encoding: .utf8)
        if let cover = book.coverData { try? cover.write(to: coverURL(for: book.id), options: .atomic) }
    }

    private func removeFiles(for id: UUID) {
        try? FileManager.default.removeItem(at: contentURL(for: id))
        try? FileManager.default.removeItem(at: coverURL(for: id))
    }

    private func contentURL(for id: UUID) -> URL { booksFolder.appendingPathComponent("\(id.uuidString).txt") }
    private func coverURL(for id: UUID) -> URL { booksFolder.appendingPathComponent("\(id.uuidString).cover") }

    private static let sampleBook = NovelBook(
        title: "雾港来信",
        author: "墨架示例",
        content: """
        第一章 潮声里的灯

        港口入夜后，雾像一封没有署名的信，慢慢越过堤岸。林舟把旧书店最后一盏灯点亮，木窗上便有了温暖的方格。

        他在今日收到的旧书里发现一只深蓝色信封。纸边被海风磨得发白，信上只写着一句：请在钟楼敲响十二下之前，替我找到那本没有结局的书。

        林舟抬头望向书架。成千上万页纸在寂静里微微起伏，像一座正在呼吸的森林。远处传来第一声钟响，他知道，这会是一个很长的夜晚。

        第二章 没有名字的书

        梯子最上层积着薄灰。林舟在那里找到一册素白封面的书，没有书名，也没有作者。翻开第一页，墨迹竟像刚写下一般清晰。

        纸上描绘的正是这间书店，只是窗边多坐着一个穿红雨衣的女孩。林舟下意识望向窗外，雾里果然亮起一点红色。

        门铃轻响。女孩收起雨伞，说她已经等这封信等了七年。她的声音很轻，却让满架旧书同时翻过了一页。

        第三章 雾散以前

        两人沿着书页留下的线索走向钟楼。每登一级台阶，城里的灯便熄灭一盏，而书中的空白处也多出一行新的文字。

        当第十一声钟响落下，他们终于明白：没有结局的从来不是那本书，而是一个不敢告别的人留下的故事。

        林舟把蓝色信封放进最后一页。海风穿过钟楼，吹散了盘踞多年的雾。清晨的第一束光照在港口，也照亮书上缓缓浮现的两个字：再见。
        """
    )
}

private struct BookMetadata: Codable {
    let id: UUID
    let title: String
    let author: String
    let format: BookFormat
    let coverStyle: Int
    let importedAt: Date
    let lastReadAt: Date?
    let currentChapter: Int
    let currentPage: Int
    let bookmarks: [ReaderBookmark]
    let notes: [ReaderNote]

    init(_ book: NovelBook) {
        id = book.id; title = book.title; author = book.author; format = book.format
        coverStyle = book.coverStyle; importedAt = book.importedAt; lastReadAt = book.lastReadAt
        currentChapter = book.currentChapter; currentPage = book.currentPage
        bookmarks = book.bookmarks; notes = book.notes
    }

    func book(content: String, coverData: Data?) -> NovelBook {
        NovelBook(
            id: id, title: title, author: author, content: content, format: format,
            coverData: coverData, coverStyle: coverStyle, importedAt: importedAt,
            lastReadAt: lastReadAt, currentChapter: currentChapter, currentPage: currentPage,
            bookmarks: bookmarks, notes: notes
        )
    }
}
