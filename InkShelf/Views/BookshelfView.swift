import SwiftUI

struct BookshelfView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var searchText = ""
    @AppStorage("librarySort") private var sortRaw = LibrarySort.recent.rawValue

    private var displayedBooks: [NovelBook] {
        let filtered = searchText.isEmpty ? library.books : library.books.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) || $0.author.localizedCaseInsensitiveContains(searchText)
        }
        let sort = LibrarySort(rawValue: sortRaw) ?? .recent
        return filtered.sorted(by: sort.sorted)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "EEE9DF").ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    if library.books.isEmpty { emptyState } else { shelfContent }
                }
                if library.isImporting { importingOverlay }
            }
            .toolbar(.hidden, for: .navigationBar)
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: NovelImporter.supportedTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    ImportLog.logger.info("文件选择器返回成功：\(urls.count, privacy: .public) 个 URL")
                    guard let url = urls.first else {
                        library.reportEmptyFileSelection()
                        return
                    }
                    ImportLog.logger.info("文件 URL：\(url.path, privacy: .public)，扩展名：\(url.pathExtension, privacy: .public)")
                    library.importNovel(from: url)
                case let .failure(error):
                    library.reportFilePickerFailure(error)
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .alert("墨架", isPresented: Binding(get: { library.alertMessage != nil }, set: { if !$0 { library.alertMessage = nil } })) {
                Button("知道了", role: .cancel) { library.alertMessage = nil }
            } message: { Text(library.alertMessage ?? "") }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("墨架").font(.custom("Songti SC", size: 32).weight(.bold))
                    Text("把喜欢的故事，放在手边").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Picker("排序", selection: $sortRaw) {
                        ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                } label: { HeaderButton(systemName: "arrow.up.arrow.down") }
                Button { showingImporter = true } label: { HeaderButton(systemName: "plus") }
                    .accessibilityLabel("导入小说")
                    .disabled(library.isImporting)
                Button { showingSettings = true } label: { HeaderButton(systemName: "person.crop.circle") }
                    .accessibilityLabel("用户与设置")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索书名或作者", text: $searchText)
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty { Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) } }
            }
            .padding(.horizontal, 13).frame(height: 42)
            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 13))
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 15)
    }

    private var shelfContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(displayedBooks.chunked(into: 3).enumerated()), id: \.offset) { _, row in
                    ShelfRow(books: row)
                }
                if displayedBooks.isEmpty {
                    ContentUnavailableView("没有找到这本书", systemImage: "books.vertical", description: Text("换个关键词试试"))
                        .padding(.top, 80)
                }
            }
            .padding(.top, 8).padding(.bottom, 50)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("书架还是空的", systemImage: "books.vertical")
        } description: {
            Text("支持 TXT、Markdown 与 EPUB 文件")
        } actions: {
            Button("导入第一本书") { showingImporter = true }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "75533A"))
                .disabled(library.isImporting)
        }
        .frame(maxHeight: .infinity)
    }

    private var importingOverlay: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            VStack(spacing: 12) { ProgressView(); Text("正在导入…").font(.subheadline) }
                .padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)).shadow(radius: 15)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ShelfRow: View {
    @EnvironmentObject private var library: LibraryStore
    let books: [NovelBook]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 17) {
                ForEach(books) { book in
                    NavigationLink { ReaderView(bookID: book.id) } label: {
                        VStack(spacing: 9) {
                            BookCoverView(book: book, compact: true).frame(maxWidth: 92)
                            VStack(spacing: 2) {
                                Text(book.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                if let progress = progress(for: book) { Text(progress).font(.system(size: 9)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        NavigationLink { BookInfoView(bookID: book.id) } label: { Label("书籍信息", systemImage: "info.circle") }
                        Button(role: .destructive) { library.delete(bookID: book.id) } label: { Label("移出书架", systemImage: "trash") }
                    }
                    .frame(maxWidth: .infinity)
                }
                ForEach(0..<(3 - books.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity).aspectRatio(0.62, contentMode: .fit) }
            }
            .padding(.horizontal, 23).frame(height: 166, alignment: .bottom)
            WoodenShelf()
        }
    }

    private func progress(for book: NovelBook) -> String? {
        guard book.lastReadAt != nil else { return "未开始" }
        let chapters = max(book.chapters.count, 1)
        return "已读 \(min(100, Int(Double(book.currentChapter + 1) / Double(chapters) * 100)))%"
    }
}

private struct WoodenShelf: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Color(hex: "A97B50"), Color(hex: "6E482B")], startPoint: .top, endPoint: .bottom).frame(height: 13)
            LinearGradient(colors: [Color(hex: "5B3822"), Color(hex: "89603E")], startPoint: .top, endPoint: .bottom).frame(height: 8)
        }
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.24)).frame(height: 1) }
        .shadow(color: .black.opacity(0.25), radius: 5, y: 4)
    }
}

private struct HeaderButton: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(hex: "3D332B"))
            .frame(width: 39, height: 39).background(.white.opacity(0.75), in: Circle())
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent = "最近阅读"
    case imported = "导入时间"
    case title = "书名"
    var id: String { rawValue }
    func sorted(_ lhs: NovelBook, _ rhs: NovelBook) -> Bool {
        switch self {
        case .recent: return (lhs.lastReadAt ?? lhs.importedAt) > (rhs.lastReadAt ?? rhs.importedAt)
        case .imported: return lhs.importedAt > rhs.importedAt
        case .title: return lhs.title.localizedCompare(rhs.title) == .orderedAscending
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] { stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) } }
}
