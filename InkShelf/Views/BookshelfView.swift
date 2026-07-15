import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhotosUI
import ImageIO

struct BookshelfView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var searchText = ""
    @State private var selectedBookID: UUID?
    @State private var readerBlocksEdgeDismiss = false
    @State private var frozenBookOrder: [UUID]?
    @State private var showingCoverPicker = false
    @State private var coverPickerBookID: UUID?
    @State private var selectedCoverPhoto: PhotosPickerItem?
    @FocusState private var searchFieldFocused: Bool
    @AppStorage("librarySort") private var sortRaw = LibrarySort.recent.rawValue

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

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "EEE9DF").ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    shelfContent
                }

                if library.isImporting { importingOverlay }

                if let selectedBookID,
                   library.book(id: selectedBookID) != nil {
                    ReaderView(
                        bookID: selectedBookID,
                        onRequestClose: { closeReader(bookID: selectedBookID) },
                        onBlockingStateChanged: { readerBlocksEdgeDismiss = $0 }
                    )
                    .ignoresSafeArea()
                    .overlay(alignment: .leading) {
                        DirectReaderEdgeDismissGesture(
                            isEnabled: !readerBlocksEdgeDismiss,
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
                    .focused($searchFieldFocused)
                if !searchText.isEmpty { Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) } }
            }
            .padding(.horizontal, 13).frame(height: 42)
            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 13))
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
    }

    private var shelfContent: some View {
        ScrollView {
            if displayedBooks.isEmpty, !searchText.isEmpty {
                ContentUnavailableView("没有找到这本书", systemImage: "books.vertical", description: Text("换个关键词试试"))
                    .padding(.top, 80)
            } else {
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

                    AddBookGridItem {
                        showingImporter = true
                    }
                    .disabled(library.isImporting)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
        }
        .scrollIndicators(.hidden)
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
        searchFieldFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        frozenBookOrder = displayedBooks.map(\.id)
        readerBlocksEdgeDismiss = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedBookID = book.id
        }
    }

    private func closeReader(bookID: UUID) {
        guard selectedBookID == bookID else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedBookID = nil
        }
        readerBlocksEdgeDismiss = false
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
                        .frame(maxWidth: .infinity, alignment: .center)

                    Text(book.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                Text(book.chapterProgressDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

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
                        .frame(width: 25, height: 24)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("《\(book.title)》更多操作")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AddBookGridItem: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "F7E9DE"), Color(hex: "E7C8B4")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                LinearGradient(
                    colors: [.white.opacity(0.28), .clear, .black.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [.black.opacity(0.2), .white.opacity(0.22), .black.opacity(0.08), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 11)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(.white.opacity(0.28)).frame(width: 0.7)
                    }
                    Spacer(minLength: 0)
                }

                VStack(spacing: 0) {
                    Spacer(minLength: 15)
                    Circle()
                        .fill(.white.opacity(0.94))
                        .frame(width: 40, height: 40)
                        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Color(hex: "825842"))
                        }
                    Spacer(minLength: 12)
                    Text("导入本地书")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "674638"))
                        .lineLimit(1)
                    Text("添加一本小说")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color(hex: "8E7465"))
                        .lineLimit(1)
                        .padding(.top, 3)
                    Spacer(minLength: 13)
                }
            }
            .frame(
                width: BookGridLayout.coverWidth,
                height: BookGridLayout.coverHeight
            )
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.5), Color(hex: "C9A68F").opacity(0.58), .black.opacity(0.22)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 0.6)
                    .padding(5)
            }
            .shadow(color: .black.opacity(0.28), radius: 5, x: 3, y: 5)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("导入本地书")
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
