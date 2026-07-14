import Foundation

struct NovelBook: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var author: String
    var content: String
    var format: BookFormat
    var coverData: Data?
    var coverStyle: Int
    var importedAt: Date
    var lastReadAt: Date?
    var currentChapter: Int
    var currentPage: Int
    var bookmarks: [ReaderBookmark]
    var notes: [ReaderNote]
    let chapters: [NovelChapter]

    init(
        id: UUID = UUID(),
        title: String,
        author: String = "佚名",
        content: String,
        format: BookFormat = .txt,
        coverData: Data? = nil,
        coverStyle: Int = Int.random(in: 0..<BookPalette.styles.count),
        importedAt: Date = .now,
        lastReadAt: Date? = nil,
        currentChapter: Int = 0,
        currentPage: Int = 0,
        bookmarks: [ReaderBookmark] = [],
        notes: [ReaderNote] = []
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.content = content
        self.format = format
        self.coverData = coverData
        self.coverStyle = coverStyle
        self.importedAt = importedAt
        self.lastReadAt = lastReadAt
        self.currentChapter = currentChapter
        self.currentPage = currentPage
        self.bookmarks = bookmarks
        self.notes = notes
        self.chapters = NovelParser.chapters(from: content)
    }

    var readChapterCount: Int {
        guard lastReadAt != nil else { return 0 }
        return min(chapters.count, max(1, currentChapter + 1))
    }

    var chapterProgressDescription: String {
        "\(readChapterCount)章 / \(chapters.count)章"
    }
}

enum BookFormat: String, Codable, CaseIterable, Sendable {
    case txt = "TXT"
    case markdown = "Markdown"
    case epub = "EPUB"
}

struct NovelChapter: Identifiable, Equatable, Sendable {
    let index: Int
    let title: String
    let content: String

    var id: Int { index }
}

struct ReaderBookmark: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let chapterIndex: Int
    let pageIndex: Int
    let excerpt: String
    let createdAt: Date
}

struct ReaderNote: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let chapterIndex: Int
    let pageIndex: Int
    let excerpt: String
    var text: String
    let createdAt: Date
}

enum NovelParser {
    private static let headingPattern = #"(?m)^\s*((?:第[0-9０-９一二三四五六七八九十百千万零〇两]+[章回卷节部篇]|Chapter\s+\d+)[^\n]*)$"#

    static func chapters(from text: String) -> [NovelChapter] {
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let expression = try? NSRegularExpression(pattern: headingPattern, options: [.caseInsensitive]) else {
            return [NovelChapter(index: 0, title: "正文", content: clean)]
        }
        let range = NSRange(clean.startIndex..., in: clean)
        let matches = expression.matches(in: clean, range: range)
        guard !matches.isEmpty else {
            return [NovelChapter(index: 0, title: "正文", content: clean)]
        }

        var chapters: [NovelChapter] = []
        let prefaceEnd = matches[0].range.location
        if prefaceEnd > 0,
           let prefaceRange = Range(NSRange(location: 0, length: prefaceEnd), in: clean) {
            let preface = clean[prefaceRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !preface.isEmpty {
                chapters.append(NovelChapter(index: chapters.count, title: "序章", content: preface))
            }
        }

        for (offset, match) in matches.enumerated() {
            guard let titleRange = Range(match.range(at: 1), in: clean) else { continue }
            let title = String(clean[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let contentStart = match.range.location + match.range.length
            let contentEnd = offset + 1 < matches.count ? matches[offset + 1].range.location : (clean as NSString).length
            let bodyRange = NSRange(location: contentStart, length: max(0, contentEnd - contentStart))
            guard let swiftRange = Range(bodyRange, in: clean) else { continue }
            let body = clean[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(NovelChapter(index: chapters.count, title: title, content: body))
        }
        return chapters.isEmpty ? [NovelChapter(index: 0, title: "正文", content: clean)] : chapters
    }

    static func pages(for chapter: NovelChapter, charactersPerPage: Int) -> [String] {
        let text = chapter.content.isEmpty ? "本章暂无正文" : chapter.content
        var pages: [String] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let proposed = text.index(cursor, offsetBy: charactersPerPage, limitedBy: text.endIndex) ?? text.endIndex
            var end = proposed
            if proposed < text.endIndex {
                let slice = text[cursor..<proposed]
                if let boundary = slice.lastIndex(where: { "。！？；\n".contains($0) }),
                   text.distance(from: boundary, to: proposed) < 80 {
                    end = text.index(after: boundary)
                }
            }
            pages.append(String(text[cursor..<end]))
            cursor = end
        }
        return pages.isEmpty ? [text] : pages
    }
}
