import SwiftUI
import UIKit

struct ReaderView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID

    @State private var chapterIndex = 0
    @State private var pageIndex = 0
    @State private var chromeVisible = false
    @State private var showingIndex = false
    @State private var showingAppearance = false
    @State private var showingNote = false
    @State private var showingVoiceInfo = false
    @State private var brightness = Double(UIScreen.main.brightness)
    @State private var originalBrightness = UIScreen.main.brightness

    @AppStorage("readerTheme") private var themeRaw = ReaderTheme.paper.rawValue
    @AppStorage("readerFont") private var fontRaw = ReaderFont.system.rawValue
    @AppStorage("pageTurnStyle") private var turnRaw = PageTurnStyle.curl.rawValue
    @AppStorage("readerFontSize") private var fontSize = 19.0
    @AppStorage("readerLineSpacing") private var lineSpacing = 9.0
    @AppStorage("readerMargin") private var margin = 22.0
    @AppStorage("keepScreenAwake") private var keepScreenAwake = true

    private var book: NovelBook? { library.book(id: bookID) }
    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .paper }
    private var turnStyle: PageTurnStyle { PageTurnStyle(rawValue: turnRaw) ?? .curl }
    private var readerFont: ReaderFont { ReaderFont(rawValue: fontRaw) ?? .system }

    var body: some View {
        Group {
            if let book {
                GeometryReader { proxy in
                    let chapter = safeChapter(in: book)
                    let pages = NovelParser.pages(for: chapter, charactersPerPage: charactersPerPage(in: proxy.size))
                    ZStack {
                        theme.background.ignoresSafeArea()
                        if turnStyle == .vertical {
                            verticalReader(book: book, chapter: chapter)
                        } else {
                            PagedReader(
                                chapterTitle: chapter.title,
                                pages: pages,
                                pageIndex: min(pageIndex, max(pages.count - 1, 0)),
                                bookTitle: book.title,
                                chapterProgress: chapterProgress(book: book, pageCount: pages.count),
                                theme: theme,
                                font: readerFont,
                                fontSize: fontSize,
                                lineSpacing: lineSpacing,
                                margin: margin,
                                style: turnStyle,
                                onPrevious: { previous(book: book, capacity: charactersPerPage(in: proxy.size)) },
                                onNext: { next(book: book, pages: pages) },
                                onCenterTap: { withAnimation(.easeOut(duration: 0.18)) { chromeVisible.toggle() } }
                            )
                        }
                        if chromeVisible { readerChrome(book: book, pages: pages) }
                    }
                    .animation(.easeInOut(duration: 0.2), value: chromeVisible)
                    .onChange(of: pages.count) { _, count in pageIndex = min(pageIndex, max(count - 1, 0)) }
                    .onChange(of: pageIndex) { _, newValue in persist(page: newValue) }
                    .onChange(of: chapterIndex) { _, _ in persist(page: pageIndex) }
                }
                .statusBarHidden(!chromeVisible)
            } else {
                ContentUnavailableView("书籍不存在", systemImage: "book.closed")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if let book { chapterIndex = min(book.currentChapter, max(book.chapters.count - 1, 0)); pageIndex = book.currentPage }
            originalBrightness = UIScreen.main.brightness
            UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            UIScreen.main.brightness = originalBrightness
        }
        .sheet(isPresented: $showingIndex) {
            if let book {
                ReaderIndexSheet(book: book) { chapter, page in
                    chapterIndex = chapter; pageIndex = page; showingIndex = false
                }
            }
        }
        .sheet(isPresented: $showingNote) {
            if let book { NoteEditor(bookID: book.id, chapter: chapterIndex, page: pageIndex, excerpt: currentExcerpt(book: book)) }
        }
        .alert("AI 朗读已预留", isPresented: $showingVoiceInfo) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("配音服务尚未接入。播放状态、章节预处理、句子定位和断点续播接口已准备好。")
        }
    }

    private func safeChapter(in book: NovelBook) -> NovelChapter {
        let chapters = book.chapters
        return chapters[min(max(chapterIndex, 0), max(chapters.count - 1, 0))]
    }

    private func charactersPerPage(in size: CGSize) -> Int {
        let usableWidth = max(180, size.width - margin * 2)
        let usableHeight = max(240, size.height - 112)
        let columns = usableWidth / max(fontSize * 1.04, 1)
        let rows = usableHeight / max(fontSize + lineSpacing, 1)
        return max(180, Int(columns * rows * 0.92))
    }

    private func chapterProgress(book: NovelBook, pageCount: Int) -> Double {
        let chapterPart = Double(chapterIndex) / Double(max(book.chapters.count, 1))
        let pagePart = Double(pageIndex) / Double(max(pageCount, 1)) / Double(max(book.chapters.count, 1))
        return min(1, chapterPart + pagePart)
    }

    private func persist(page: Int) { library.updateProgress(bookID: bookID, chapter: chapterIndex, page: page) }

    private func previous(book: NovelBook, capacity: Int) {
        if pageIndex > 0 { pageIndex -= 1 }
        else if chapterIndex > 0 {
            chapterIndex -= 1
            let chapter = book.chapters[chapterIndex]
            pageIndex = max(0, NovelParser.pages(for: chapter, charactersPerPage: capacity).count - 1)
        }
    }

    private func next(book: NovelBook, pages: [String]) {
        if pageIndex + 1 < pages.count { pageIndex += 1 }
        else if chapterIndex + 1 < book.chapters.count { chapterIndex += 1; pageIndex = 0 }
    }

    @ViewBuilder
    private func verticalReader(book: NovelBook, chapter: NovelChapter) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(chapter.title).font(readerSwiftUIFont(size: fontSize + 7).weight(.bold))
                Text(chapter.content)
                    .font(readerSwiftUIFont(size: fontSize))
                    .lineSpacing(lineSpacing)
                    .textSelection(.enabled)
                HStack {
                    Button("上一章") { if chapterIndex > 0 { chapterIndex -= 1 } }.disabled(chapterIndex == 0)
                    Spacer()
                    Button("下一章") { if chapterIndex + 1 < book.chapters.count { chapterIndex += 1 } }.disabled(chapterIndex + 1 >= book.chapters.count)
                }
                .buttonStyle(.bordered).tint(theme.foreground)
            }
            .foregroundStyle(theme.foreground)
            .padding(.horizontal, margin).padding(.top, 54).padding(.bottom, 80)
        }
        .simultaneousGesture(TapGesture().onEnded { withAnimation { chromeVisible.toggle() } })
    }

    private func readerChrome(book: NovelBook, pages: [String]) -> some View {
        VStack {
            HStack(spacing: 18) {
                Button { dismiss() } label: { Image(systemName: "chevron.left") }
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(safeChapter(in: book).title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { toggleBookmark(book: book) } label: { Image(systemName: isBookmarked(book) ? "bookmark.fill" : "bookmark") }
                Button { showingNote = true } label: { Image(systemName: "square.and.pencil") }
            }
            .font(.system(size: 18, weight: .medium)).padding(.horizontal, 18).frame(height: 58)
            .background(.ultraThinMaterial)
            Spacer()
            VStack(spacing: 14) {
                if turnStyle != .vertical {
                    HStack(spacing: 12) {
                        Text("\(pageIndex + 1)").font(.caption.monospacedDigit())
                        Slider(value: Binding(
                            get: { Double(min(pageIndex, max(pages.count - 1, 0))) },
                            set: { pageIndex = Int($0.rounded()) }
                        ), in: 0...Double(max(pages.count - 1, 1)), step: 1)
                        Text("\(pages.count)").font(.caption.monospacedDigit())
                    }
                }
                HStack {
                    ChromeAction(icon: "list.bullet", label: "目录") { showingIndex = true }
                    ChromeAction(icon: "textformat.size", label: "排版") { showingAppearance.toggle() }
                    ChromeAction(icon: "waveform", label: "朗读") { showingVoiceInfo = true }
                    ChromeAction(icon: "ellipsis", label: "更多") { showingIndex = true }
                }
                if showingAppearance { appearanceControls }
            }
            .padding(.horizontal, 18).padding(.top, 13).padding(.bottom, 18)
            .background(.ultraThinMaterial)
        }
        .foregroundStyle(Color.primary)
        .transition(.opacity)
    }

    private var appearanceControls: some View {
        VStack(spacing: 13) {
            HStack {
                Image(systemName: "sun.min")
                Slider(value: $brightness, in: 0.05...1) { _ in UIScreen.main.brightness = brightness }
                Image(systemName: "sun.max.fill")
            }
            HStack {
                Text("字号").font(.caption)
                Button("A−") { fontSize = max(14, fontSize - 1) }.buttonStyle(.bordered)
                Text("\(Int(fontSize))").font(.caption.monospacedDigit()).frame(width: 25)
                Button("A+") { fontSize = min(32, fontSize + 1) }.buttonStyle(.bordered)
                Spacer()
                Picker("字体", selection: $fontRaw) { ForEach(ReaderFont.allCases) { Text($0.rawValue).tag($0.rawValue) } }.labelsHidden()
            }
            HStack(spacing: 10) {
                Text("行距").frame(width: 28, alignment: .leading)
                Slider(value: $lineSpacing, in: 3...16, step: 1)
                Text("边距").frame(width: 28, alignment: .leading)
                Slider(value: $margin, in: 14...38, step: 2)
            }
            HStack {
                ForEach(ReaderTheme.allCases) { item in
                    Button { themeRaw = item.rawValue } label: {
                        Circle().fill(item.background).frame(width: 29, height: 29)
                            .overlay(Circle().stroke(themeRaw == item.rawValue ? Color.accentColor : .gray.opacity(0.35), lineWidth: 2))
                    }
                }
                Spacer()
                Picker("翻页", selection: $turnRaw) { ForEach(PageTurnStyle.allCases) { Text($0.rawValue).tag($0.rawValue) } }.labelsHidden()
            }
        }
        .font(.caption)
    }

    private func readerSwiftUIFont(size: Double) -> Font {
        if let name = readerFont.name { return .custom(name, size: size) }
        return .system(size: size, design: .serif)
    }

    private func currentExcerpt(book: NovelBook) -> String {
        let pages = NovelParser.pages(for: safeChapter(in: book), charactersPerPage: charactersPerPage(in: UIScreen.main.bounds.size))
        return String(pages[min(pageIndex, max(pages.count - 1, 0))].prefix(80))
    }

    private func isBookmarked(_ book: NovelBook) -> Bool { book.bookmarks.contains { $0.chapterIndex == chapterIndex && $0.pageIndex == pageIndex } }

    private func toggleBookmark(book: NovelBook) {
        library.toggleBookmark(bookID: book.id, chapter: chapterIndex, page: pageIndex, excerpt: currentExcerpt(book: book))
    }
}

private struct PagedReader: View {
    let chapterTitle: String
    let pages: [String]
    let pageIndex: Int
    let bookTitle: String
    let chapterProgress: Double
    let theme: ReaderTheme
    let font: ReaderFont
    let fontSize: Double
    let lineSpacing: Double
    let margin: Double
    let style: PageTurnStyle
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onCenterTap: () -> Void
    @State private var dragX = 0.0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if dragX < 0, pageIndex + 1 < pages.count {
                    PageSurface(title: chapterTitle, text: pages[pageIndex + 1], page: pageIndex + 2, progress: chapterProgress, theme: theme, font: font, fontSize: fontSize, lineSpacing: lineSpacing, margin: margin)
                }
                PageSurface(title: chapterTitle, text: pages[min(pageIndex, max(pages.count - 1, 0))], page: pageIndex + 1, progress: chapterProgress, theme: theme, font: font, fontSize: fontSize, lineSpacing: lineSpacing, margin: margin)
                    .offset(x: style == .slide ? dragX : 0)
                    .rotation3DEffect(
                        style == .curl ? .degrees(max(-105, min(20, dragX / max(proxy.size.width, 1) * 105))) : .zero,
                        axis: (x: 0, y: 1, z: 0), anchor: dragX < 0 ? .leading : .trailing, perspective: 0.42
                    )
                    .shadow(color: .black.opacity(abs(dragX) / max(proxy.size.width, 1) * 0.28), radius: 16, x: -8)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragX = $0.translation.width }
                    .onEnded { value in
                        let threshold = proxy.size.width * 0.16
                        if abs(value.translation.width) < 8 {
                            let third = proxy.size.width / 3
                            if value.location.x < third { onPrevious() }
                            else if value.location.x > third * 2 { onNext() }
                            else { onCenterTap() }
                        } else if value.translation.width < -threshold || value.predictedEndTranslation.width < -proxy.size.width * 0.45 {
                            onNext()
                        } else if value.translation.width > threshold || value.predictedEndTranslation.width > proxy.size.width * 0.45 {
                            onPrevious()
                        }
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { dragX = 0 }
                    }
            )
        }
    }
}

private struct PageSurface: View {
    let title: String
    let text: String
    let page: Int
    let progress: Double
    let theme: ReaderTheme
    let font: ReaderFont
    let fontSize: Double
    let lineSpacing: Double
    let margin: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(title).lineLimit(1); Spacer(); Text("墨架") }
                .font(.system(size: 10)).foregroundStyle(theme.foreground.opacity(0.52)).padding(.top, 13)
            Text(text)
                .font(contentFont)
                .lineSpacing(lineSpacing)
                .foregroundStyle(theme.foreground)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 24)
            HStack { Text("\(page)"); Spacer(); Text("\(Int(progress * 100))%") }
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(theme.foreground.opacity(0.5)).padding(.bottom, 10)
        }
        .padding(.horizontal, margin)
        .background(theme.background)
    }

    private var contentFont: Font {
        if let name = font.name { return .custom(name, size: fontSize) }
        return .system(size: fontSize, design: .serif)
    }
}

private struct ChromeAction: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { VStack(spacing: 5) { Image(systemName: icon).font(.system(size: 18)); Text(label).font(.caption2) }.frame(maxWidth: .infinity) }
    }
}

private struct ReaderIndexSheet: View {
    @Environment(\.dismiss) private var dismiss
    let book: NovelBook
    let onSelect: (Int, Int) -> Void
    @State private var tab = ReaderTab.directory
    @State private var query = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("内容", selection: $tab) { ForEach(ReaderTab.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).padding()
                List {
                    switch tab {
                    case .directory:
                        ForEach(book.chapters) { chapter in
                            Button { onSelect(chapter.index, 0) } label: {
                                HStack { Text(chapter.title).foregroundStyle(.primary); Spacer(); if chapter.index == book.currentChapter { Image(systemName: "book.fill").foregroundStyle(.tint) } }
                            }
                        }
                    case .bookmarks:
                        if book.bookmarks.isEmpty { ContentUnavailableView("还没有书签", systemImage: "bookmark") }
                        ForEach(book.bookmarks.sorted(by: { $0.createdAt > $1.createdAt })) { mark in
                            Button { onSelect(mark.chapterIndex, mark.pageIndex) } label: { resultRow(title: chapterTitle(mark.chapterIndex), excerpt: mark.excerpt) }
                        }
                    case .notes:
                        if book.notes.isEmpty { ContentUnavailableView("还没有笔记", systemImage: "note.text") }
                        ForEach(book.notes.sorted(by: { $0.createdAt > $1.createdAt })) { note in
                            Button { onSelect(note.chapterIndex, note.pageIndex) } label: { resultRow(title: note.text, excerpt: note.excerpt) }
                        }
                    case .search:
                        ForEach(Array(searchResults.enumerated()), id: \.offset) { _, result in
                            Button { onSelect(result.chapter.index, 0) } label: { resultRow(title: result.chapter.title, excerpt: result.excerpt) }
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $query, prompt: "搜索全书正文")
            }
            .navigationTitle(book.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }

    private var searchResults: [(chapter: NovelChapter, excerpt: String)] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return book.chapters.compactMap { chapter in
            guard let range = chapter.content.range(of: query, options: .caseInsensitive) else { return nil }
            let start = chapter.content.index(range.lowerBound, offsetBy: -28, limitedBy: chapter.content.startIndex) ?? chapter.content.startIndex
            let end = chapter.content.index(range.upperBound, offsetBy: 55, limitedBy: chapter.content.endIndex) ?? chapter.content.endIndex
            return (chapter, "…" + String(chapter.content[start..<end]) + "…")
        }
    }

    private func chapterTitle(_ index: Int) -> String { book.chapters.indices.contains(index) ? book.chapters[index].title : "未知章节" }
    private func resultRow(title: String, excerpt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1); Text(excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3) }.padding(.vertical, 4)
    }
}

private enum ReaderTab: String, CaseIterable, Identifiable { case directory = "目录"; case bookmarks = "书签"; case notes = "笔记"; case search = "搜索"; var id: String { rawValue } }

private struct NoteEditor: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let chapter: Int
    let page: Int
    let excerpt: String
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("原文") { Text(excerpt).font(.footnote).foregroundStyle(.secondary) }
                Section("我的笔记") { TextEditor(text: $note).frame(minHeight: 150) }
            }
            .navigationTitle("添加笔记").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { library.addNote(bookID: bookID, chapter: chapter, page: page, excerpt: excerpt, text: note); dismiss() }.disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
    }
}
