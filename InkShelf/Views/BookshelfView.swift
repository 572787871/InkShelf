import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhotosUI
import ImageIO

struct BookshelfView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var readAloud: ReadAloudService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var searchText = ""
    @State private var selectedBookID: UUID?
    @State private var readerBlocksEdgeDismiss = false
    @State private var frozenBookOrder: [UUID]?
    @State private var showingCoverPicker = false
    @State private var coverPickerBookID: UUID?
    @State private var selectedCoverPhoto: PhotosPickerItem?
    @State private var readerContentVisible = false
    @State private var readerTransitionInFlight = false
    @State private var readerTransitionToken = UUID()
    @FocusState private var searchFieldFocused: Bool
    @AppStorage("librarySort") private var sortRaw = LibrarySort.recent.rawValue
    @AppStorage("libraryLayout") private var layoutRaw = LibraryLayout.grid.rawValue

    private var displayedBooks: [NovelBook] {
        let filtered = searchText.isEmpty ? library.books : library.books.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) || $0.author.localizedCaseInsensitiveContains(searchText)
        }
        let sort = LibrarySort(rawValue: sortRaw) ?? .recent
        let freshlySorted = filtered.sorted(by: sort.sorted)
        guard let frozenBookOrder else { return freshlySorted }
        let ranks = Dictionary(uniqueKeysWithValues: frozenBookOrder.enumerated().map { ($0.element, $0.offset) })
        return freshlySorted.sorted {
            (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max)
        }
    }

    private var libraryLayout: LibraryLayout {
        LibraryLayout(rawValue: layoutRaw) ?? .grid
    }

    var body: some View {
        NavigationStack {
            GeometryReader { rootProxy in
                ZStack {
                    Color(hex: "EEE9DF").ignoresSafeArea()
                    VStack(spacing: 0) {
                        header
                        shelfContent
                    }

                    if library.isImporting { importingOverlay }

                    if selectedBookID == nil,
                       !showingImporter,
                       !showingSettings,
                       !showingCoverPicker {
                        PersistentReadAloudOverlay(readAloud: readAloud)
                    }

                    if let selectedBookID,
                       library.book(id: selectedBookID) != nil {
                        Color.black
                            .opacity(readerContentVisible ? 0.08 : 0)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                        .zIndex(9)

                        ReaderView(
                            bookID: selectedBookID,
                            onRequestClose: { closeReader(bookID: selectedBookID) },
                            onBlockingStateChanged: { readerBlocksEdgeDismiss = $0 }
                        )
                        .ignoresSafeArea()
                        .offset(
                            y: readerContentVisible
                                ? 0
                                : rootProxy.size.height + rootProxy.safeAreaInsets.bottom + 32
                        )
                        .shadow(
                            color: .black.opacity(readerContentVisible ? 0 : 0.24),
                            radius: readerContentVisible ? 0 : 18,
                            y: -8
                        )
                        .allowsHitTesting(readerContentVisible)
                        .overlay(alignment: .leading) {
                            DirectReaderEdgeDismissGesture(
                                isEnabled: readerContentVisible
                                    && !readerTransitionInFlight
                                    && !readerBlocksEdgeDismiss,
                                onEnded: { translation, predictedTranslation, width in
                                    if ReaderDismissGestureDecision.shouldFinish(
                                        translation: translation,
                                        predictedTranslation: predictedTranslation,
                                        width: width
                                    ) {
                                        closeReader(bookID: selectedBookID)
                                    }
                                }
                            )
                            .frame(width: 28)
                        }
                        .zIndex(10)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingImporter) {
                NovelDocumentPicker(contentTypes: NovelImporter.supportedTypes) { urls in
                    showingImporter = false
                    guard let url = urls.first else {
                        library.reportEmptyFileSelection()
                        return
                    }
                    ImportLog.logger.info("原生文件选择器返回：\(url.lastPathComponent, privacy: .public)，扩展名：\(url.pathExtension, privacy: .public)")
                    library.importNovel(from: url)
                } onCancel: {
                    showingImporter = false
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .photosPicker(
                isPresented: $showingCoverPicker,
                selection: $selectedCoverPhoto,
                matching: .images
            )
            .alert("墨架", isPresented: Binding(get: { library.alertMessage != nil }, set: { if !$0 { library.alertMessage = nil } })) {
                Button("知道了", role: .cancel) { library.alertMessage = nil }
            } message: { Text(library.alertMessage ?? "") }
            .onChange(of: sortRaw) { _, _ in frozenBookOrder = nil }
            .onChange(of: searchText) { _, _ in
                if selectedBookID == nil { frozenBookOrder = nil }
            }
            .onChange(of: library.books.map(\.id)) { oldIDs, newIDs in
                if oldIDs != newIDs { frozenBookOrder = nil }
            }
            .onChange(of: selectedCoverPhoto) { _, item in
                importSelectedCover(item)
            }
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
                    Section("显示方式") {
                        Picker("显示方式", selection: $layoutRaw) {
                            ForEach(LibraryLayout.allCases) { layout in
                                Label(layout.rawValue, systemImage: layout.symbolName)
                                    .tag(layout.rawValue)
                            }
                        }
                    }
                    Section("排序") {
                        Picker("排序", selection: $sortRaw) {
                            ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                    }
                } label: {
                    HeaderButton(systemName: libraryLayout.symbolName)
                }
                .accessibilityLabel("书架显示和排序")
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
                    .focused($searchFieldFocused)
                if !searchText.isEmpty { Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) } }
            }
            .padding(.horizontal, 13).frame(height: 42)
            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 13))
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
    }

    @ViewBuilder
    private var shelfContent: some View {
        ScrollView {
            if displayedBooks.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "书架还是空的" : "没有找到这本书",
                    systemImage: "books.vertical",
                    description: Text(searchText.isEmpty ? "点击右上角 + 导入一本小说" : "换个关键词试试")
                )
                    .padding(.top, 80)
            } else if libraryLayout == .grid {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(minimum: 84, maximum: 120), spacing: 18, alignment: .top),
                        count: 3
                    ),
                    alignment: .leading,
                    spacing: 24
                ) {
                    ForEach(displayedBooks) { book in
                        BookGridItem(
                            book: book,
                            onOpen: openReader,
                            onChooseCover: beginCoverSelection
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 36)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(displayedBooks) { book in
                        BookListItem(
                            book: book,
                            onOpen: openReader,
                            onChooseCover: beginCoverSelection
                        )
                        if book.id != displayedBooks.last?.id {
                            Divider().padding(.leading, 96)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 36)
            }
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded { dismissSearchKeyboard() }
        )
    }

    private var importingOverlay: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            VStack(spacing: 12) { ProgressView(); Text("正在导入…").font(.subheadline) }
                .padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)).shadow(radius: 15)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openReader(_ book: NovelBook) {
        guard selectedBookID == nil else { return }
        dismissSearchKeyboard()
        frozenBookOrder = displayedBooks.map(\.id)
        readerBlocksEdgeDismiss = false
        readerTransitionInFlight = true
        readerContentVisible = false
        let transitionToken = UUID()
        readerTransitionToken = transitionToken
        selectedBookID = book.id

        if reduceMotion {
            readerContentVisible = true
            readerTransitionInFlight = false
            return
        }

        DispatchQueue.main.async {
            guard selectedBookID == book.id, readerTransitionToken == transitionToken else { return }
            withAnimation(.spring(response: 0.72, dampingFraction: 0.92)) {
                readerContentVisible = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) {
                guard selectedBookID == book.id, readerTransitionToken == transitionToken else { return }
                readerTransitionInFlight = false
            }
        }
    }

    private func dismissSearchKeyboard() {
        guard searchFieldFocused else { return }
        searchFieldFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func closeReader(bookID: UUID) {
        guard selectedBookID == bookID else { return }
        let transitionToken = UUID()
        readerTransitionToken = transitionToken
        if reduceMotion {
            selectedBookID = nil
            readerBlocksEdgeDismiss = false
            readerContentVisible = false
            readerTransitionInFlight = false
            return
        }
        readerTransitionInFlight = true
        withAnimation(.easeInOut(duration: 0.34)) {
            readerContentVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            guard selectedBookID == bookID, readerTransitionToken == transitionToken else { return }
            selectedBookID = nil
            readerBlocksEdgeDismiss = false
            readerTransitionInFlight = false
        }
    }

    private func beginCoverSelection(_ book: NovelBook) {
        guard selectedBookID == nil else { return }
        coverPickerBookID = book.id
        selectedCoverPhoto = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard coverPickerBookID == book.id, selectedBookID == nil else { return }
            showingCoverPicker = true
        }
    }

    private func importSelectedCover(_ item: PhotosPickerItem?) {
        guard let item, let bookID = coverPickerBookID else { return }
        Task {
            do {
                guard let sourceData = try await item.loadTransferable(type: Data.self) else {
                    throw CoverImageProcessingError.unreadableImage
                }
                let preparedData = try await Task.detached(priority: .userInitiated) {
                    try CoverImageProcessor.preparedData(from: sourceData)
                }.value
                guard coverPickerBookID == bookID else { return }
                library.updateCover(bookID: bookID, coverData: preparedData)
            } catch {
                library.reportCoverSelectionFailure(error)
            }
            if coverPickerBookID == bookID {
                coverPickerBookID = nil
                selectedCoverPhoto = nil
            }
        }
    }
}

private struct BookGridItem: View {
    @EnvironmentObject private var library: LibraryStore
    let book: NovelBook
    let onOpen: (NovelBook) -> Void
    let onChooseCover: (NovelBook) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { onOpen(book) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    BookCoverView(book: book, compact: true)
                        .frame(
                            width: BookGridLayout.coverWidth,
                            height: BookGridLayout.coverHeight
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                    Text(book.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .frame(width: BookGridLayout.coverWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 1) {
                Text("\(book.readChapterCount)章/\(book.displayChapterCount)章")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .allowsTightening(true)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                Menu {
                    Button { onChooseCover(book) } label: {
                        Label("从相册设置封面", systemImage: "photo.on.rectangle")
                    }
                    if book.coverData != nil {
                        Button { library.updateCover(bookID: book.id, coverData: nil) } label: {
                            Label("恢复默认封面", systemImage: "arrow.uturn.backward")
                        }
                    }
                    NavigationLink { BookInfoView(bookID: book.id) } label: {
                        Label("书籍信息", systemImage: "info.circle")
                    }
                    Divider()
                    Button(role: .destructive) { library.delete(bookID: book.id) } label: {
                        Label("移出书架", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 24)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("《\(book.title)》更多操作")
            }
            .frame(width: BookGridLayout.coverWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BookListItem: View {
    @EnvironmentObject private var library: LibraryStore
    let book: NovelBook
    let onOpen: (NovelBook) -> Void
    let onChooseCover: (NovelBook) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            Button { onOpen(book) } label: {
                HStack(alignment: .top, spacing: 15) {
                    BookCoverView(book: book, compact: true)
                        .frame(width: 68, height: 100)

                    VStack(alignment: .leading, spacing: 7) {
                        Text(book.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(book.author)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(book.chapterProgressDescription)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "806A59"))
                        Text(currentChapterTitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button { onChooseCover(book) } label: {
                    Label("从相册设置封面", systemImage: "photo.on.rectangle")
                }
                if book.coverData != nil {
                    Button { library.updateCover(bookID: book.id, coverData: nil) } label: {
                        Label("恢复默认封面", systemImage: "arrow.uturn.backward")
                    }
                }
                NavigationLink { BookInfoView(bookID: book.id) } label: {
                    Label("书籍信息", systemImage: "info.circle")
                }
                Divider()
                Button(role: .destructive) { library.delete(bookID: book.id) } label: {
                    Label("移出书架", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 34)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("《\(book.title)》更多操作")
        }
        .padding(.vertical, 12)
    }

    private var currentChapterTitle: String {
        guard book.chapters.indices.contains(book.currentChapter) else { return "尚未开始阅读" }
        return book.lastReadAt == nil ? "尚未开始阅读" : book.chapters[book.currentChapter].title
    }
}

enum BookGridLayout {
    static let coverWidth: CGFloat = 96
    static let coverHeight: CGFloat = coverWidth / 0.68
}

private struct NovelDocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: NovelDocumentPicker
        private var hasCompleted = false

        init(parent: NovelDocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !hasCompleted else { return }
            hasCompleted = true
            parent.onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !hasCompleted else { return }
            hasCompleted = true
            parent.onCancel()
        }
    }
}

private struct DirectReaderEdgeDismissGesture: UIViewRepresentable {
    let isEnabled: Bool
    let onEnded: (CGFloat, CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEnded: onEnded)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let gesture = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        gesture.edges = .left
        gesture.maximumNumberOfTouches = 1
        gesture.isEnabled = isEnabled
        view.addGestureRecognizer(gesture)
        context.coordinator.gesture = gesture
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onEnded = onEnded
        context.coordinator.gesture?.isEnabled = isEnabled
    }

    final class Coordinator: NSObject {
        var onEnded: (CGFloat, CGFloat, CGFloat) -> Void
        weak var gesture: UIScreenEdgePanGestureRecognizer?

        init(onEnded: @escaping (CGFloat, CGFloat, CGFloat) -> Void) {
            self.onEnded = onEnded
        }

        @objc func handle(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            let translation = max(0, recognizer.translation(in: recognizer.view).x)
            let velocity = max(0, recognizer.velocity(in: recognizer.view).x)
            let projected = translation + velocity * 0.18
            let width = recognizer.view?.window?.bounds.width ?? UIScreen.main.bounds.width
            onEnded(translation, projected, width)
        }
    }
}

enum CoverImageProcessingError: LocalizedError {
    case unreadableImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "无法读取所选图片"
        case .encodingFailed: return "无法生成封面图片"
        }
    }
}

enum CoverImageProcessor {
    static let maximumPixelSize = 2048

    static func preparedData(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CoverImageProcessingError.unreadableImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let encoded = UIImage(cgImage: image).jpegData(compressionQuality: 0.88) else {
            throw CoverImageProcessingError.encodingFailed
        }
        return encoded
    }
}

private struct HeaderButton: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(hex: "3D332B"))
            .frame(width: 39, height: 39).background(.white.opacity(0.75), in: Circle())
    }
}

enum LibraryLayout: String, CaseIterable, Identifiable {
    case grid = "网格"
    case list = "列表"

    var id: String { rawValue }
    var symbolName: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
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
