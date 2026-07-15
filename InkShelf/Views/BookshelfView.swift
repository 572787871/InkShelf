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
    @State private var bookFrames: [UUID: CGRect] = [:]
    @State private var selectedBookID: UUID?
    @State private var selectedBookFrame: CGRect?
    @State private var selectedBookSourceHidden = false
    @State private var readerTransitionProgress: CGFloat = 1
    @State private var readerTransitionPhase = ReaderTransitionPhase.idle
    @State private var readerBlocksEdgeDismiss = false
    @State private var frozenBookOrder: [UUID]?
    @State private var showingCoverPicker = false
    @State private var coverPickerBookID: UUID?
    @State private var selectedCoverPhoto: PhotosPickerItem?
    @FocusState private var searchFieldFocused: Bool
    @AppStorage("librarySort") private var sortRaw = LibrarySort.recent.rawValue
    @AppStorage("readerTheme") private var readerThemeRaw = ReaderTheme.paper.rawValue

    private var readerTheme: ReaderTheme { ReaderTheme(rawValue: readerThemeRaw) ?? .paper }

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
            GeometryReader { proxy in
                ZStack {
                    Color(hex: "EEE9DF").ignoresSafeArea()
                    VStack(spacing: 0) {
                        header
                        shelfContent
                    }
                    if library.isImporting { importingOverlay }

                    if let selectedBookID,
                       let selectedBook = library.book(id: selectedBookID) {
                        readerTransitionLayer(
                            book: selectedBook,
                            targetFrame: selectedBookFrame ?? bookFrames[selectedBookID] ?? fallbackBookFrame(in: proxy.size),
                            containerSize: proxy.size,
                            safeAreaInsets: proxy.safeAreaInsets
                        )
                        .zIndex(10)
                    }
                }
                .coordinateSpace(name: "bookshelfRoot")
                .onPreferenceChange(BookFramePreferenceKey.self) { bookFrames = $0 }
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
                            isHidden: selectedBookSourceHidden && selectedBookID == book.id,
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

    @ViewBuilder
    private func readerTransitionLayer(
        book: NovelBook,
        targetFrame: CGRect,
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        let phase = readerTransitionPhase
        let fullSize = CGSize(
            width: containerSize.width + safeAreaInsets.leading + safeAreaInsets.trailing,
            height: containerSize.height + safeAreaInsets.top + safeAreaInsets.bottom
        )
        let fullTargetFrame = targetFrame.offsetBy(
            dx: safeAreaInsets.leading,
            dy: safeAreaInsets.top
        )
        ReaderTransitionLayer(
            book: book,
            targetFrame: fullTargetFrame,
            containerSize: fullSize,
            paperColor: UIColor(readerTheme.background),
            progress: readerTransitionProgress,
            interactionDisabled: phase != .open,
            edgeGestureEnabled: (phase == .open || phase == .edgeDragging) && !readerBlocksEdgeDismiss,
            onReady: { readerDidBecomeReady(bookID: book.id) },
            onRequestClose: { closeReader(bookID: book.id) },
            onBlockingStateChanged: { readerBlocksEdgeDismiss = $0 },
            onEdgeChanged: { edgeDragChanged($0, bookID: book.id, containerWidth: fullSize.width) },
            onEdgeEnded: { translation, predicted in
                edgeDragEnded(
                    translation: translation,
                    predictedTranslation: predicted,
                    bookID: book.id,
                    containerWidth: fullSize.width
                )
            }
        )
        .offset(x: -safeAreaInsets.leading, y: -safeAreaInsets.top)
    }

    private func openReader(_ book: NovelBook) {
        guard selectedBookID == nil, readerTransitionPhase == .idle else { return }
        searchFieldFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        frozenBookOrder = displayedBooks.map(\.id)
        readerBlocksEdgeDismiss = false
        readerTransitionProgress = 1
        readerTransitionPhase = .preparing
        selectedBookSourceHidden = false
        selectedBookFrame = bookFrames[book.id]
        selectedBookID = book.id
    }

    private func readerDidBecomeReady(bookID: UUID) {
        guard selectedBookID == bookID, readerTransitionPhase == .preparing else { return }
        // Keep the closed book on screen for several display frames so UIKit's
        // layer tree commits the physical cover before interpolation begins.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard selectedBookID == bookID, readerTransitionPhase == .preparing else { return }
            selectedBookSourceHidden = true
            readerTransitionPhase = .opening
            withAnimation(.easeInOut(duration: 0.56)) {
                readerTransitionProgress = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) {
                guard selectedBookID == bookID, readerTransitionPhase == .opening else { return }
                readerTransitionPhase = .open
            }
        }
    }

    private func closeReader(bookID: UUID) {
        guard selectedBookID == bookID,
              readerTransitionPhase == .open || readerTransitionPhase == .edgeDragging else { return }
        readerTransitionPhase = .closing
        withAnimation(.easeInOut(duration: 0.56)) {
            readerTransitionProgress = 1
        }
        completeReaderDismissal(bookID: bookID, after: 0.58)
    }

    private func edgeDragChanged(_ translation: CGFloat, bookID: UUID, containerWidth: CGFloat) {
        guard selectedBookID == bookID,
              !readerBlocksEdgeDismiss,
              readerTransitionPhase == .open || readerTransitionPhase == .edgeDragging else { return }
        readerTransitionPhase = .edgeDragging
        readerTransitionProgress = min(1, max(0, translation / max(containerWidth, 1)))
    }

    private func edgeDragEnded(
        translation: CGFloat,
        predictedTranslation: CGFloat,
        bookID: UUID,
        containerWidth: CGFloat
    ) {
        guard selectedBookID == bookID, readerTransitionPhase == .edgeDragging else { return }
        if ReaderDismissGestureDecision.shouldFinish(
            translation: translation,
            predictedTranslation: predictedTranslation,
            width: containerWidth
        ) {
            closeReader(bookID: bookID)
        } else {
            readerTransitionPhase = .opening
            withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.88, blendDuration: 0.04)) {
                readerTransitionProgress = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                guard selectedBookID == bookID, readerTransitionPhase == .opening else { return }
                readerTransitionPhase = .open
            }
        }
    }

    private func completeReaderDismissal(bookID: UUID, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard selectedBookID == bookID, readerTransitionPhase == .closing else { return }
            selectedBookID = nil
            selectedBookFrame = nil
            selectedBookSourceHidden = false
            readerTransitionProgress = 1
            readerTransitionPhase = .idle
            readerBlocksEdgeDismiss = false
        }
    }

    private func beginCoverSelection(_ book: NovelBook) {
        guard selectedBookID == nil, readerTransitionPhase == .idle else { return }
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

    private func fallbackBookFrame(in size: CGSize) -> CGRect {
        CGRect(x: (size.width - 92) / 2, y: 176, width: 92, height: 135)
    }
}

private struct BookGridItem: View {
    @EnvironmentObject private var library: LibraryStore
    let book: NovelBook
    let isHidden: Bool
    let onOpen: (NovelBook) -> Void
    let onChooseCover: (NovelBook) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { onOpen(book) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    BookCoverView(book: book, compact: true)
                        .frame(maxWidth: 108)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: BookFramePreferenceKey.self,
                                    value: [book.id: proxy.frame(in: .named("bookshelfRoot"))]
                                )
                            }
                        }
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
        .opacity(isHidden ? 0 : 1)
    }
}

private struct AddBookGridItem: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "F9EDE3"), Color(hex: "EACFBC")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    HStack(spacing: 0) {
                        LinearGradient(
                            colors: [.black.opacity(0.16), .white.opacity(0.28), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 12)
                        Spacer(minLength: 0)
                    }
                    Circle()
                        .fill(.white.opacity(0.94))
                        .frame(width: 43, height: 43)
                        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Color(hex: "8A6048"))
                }
                .aspectRatio(0.68, contentMode: .fit)
                .frame(maxWidth: 108)
                .frame(maxWidth: .infinity, alignment: .center)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.42), Color(hex: "CFAF99").opacity(0.5), .black.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                }
                .shadow(color: .black.opacity(0.28), radius: 5, x: 3, y: 5)

                Text("导入本地书")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(hex: "674B3B"))
                    .lineLimit(1)

                Text("TXT / EPUB")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("导入本地书")
    }
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

private struct ReaderTransitionLayer: View {
    let book: NovelBook
    let targetFrame: CGRect
    let containerSize: CGSize
    let paperColor: UIColor
    let progress: CGFloat
    let interactionDisabled: Bool
    let edgeGestureEnabled: Bool
    let onReady: () -> Void
    let onRequestClose: () -> Void
    let onBlockingStateChanged: (Bool) -> Void
    let onEdgeChanged: (CGFloat) -> Void
    let onEdgeEnded: (CGFloat, CGFloat) -> Void

    var body: some View {
        let boundedProgress = min(1, max(0, progress))
        let width = max(containerSize.width, 1)
        let height = max(containerSize.height, 1)
        let opening = 1 - boundedProgress
        // Keep the reader's geometry locked to the UIKit book body. The live
        // reader is prepared once at full size, then only composited by the GPU;
        // its layout and pagination never change during the transition.
        let expansion = smoothstep(0.02, 0.9, opening)
        let closedGeometry = 1 - expansion
        let scaleX = 1 + (targetFrame.width / width - 1) * closedGeometry
        let scaleY = 1 + (targetFrame.height / height - 1) * closedGeometry
        let readerOpacity = smoothstep(0.06, 0.38, opening)

        ZStack(alignment: .topLeading) {
            ReaderView(
                bookID: book.id,
                interactionDisabled: interactionDisabled,
                onRequestClose: onRequestClose,
                onReady: onReady,
                onBlockingStateChanged: onBlockingStateChanged
            )
            .frame(width: width, height: height)
            .opacity(readerOpacity)
            .clipShape(RoundedRectangle(cornerRadius: 7 * closedGeometry, style: .continuous))
            .scaleEffect(x: scaleX, y: scaleY, anchor: .topLeading)
            .offset(x: targetFrame.minX * closedGeometry, y: targetFrame.minY * closedGeometry)
            .shadow(color: .black.opacity(0.22 * closedGeometry), radius: 14, x: 3, y: 7)

            BookOpeningTransitionView(
                book: book,
                targetFrame: targetFrame,
                containerSize: containerSize,
                paperColor: paperColor,
                closedProgress: boundedProgress
            )
            .frame(width: width, height: height)
                .allowsHitTesting(false)

            ScreenEdgeDismissGesture(
                isEnabled: edgeGestureEnabled,
                onChanged: onEdgeChanged,
                onEnded: onEdgeEnded
            )
            .frame(width: width, height: height)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(Color.clear.contentShape(Rectangle()))
    }

    private func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        let x = min(1, max(0, (value - edge0) / max(edge1 - edge0, 0.001)))
        return x * x * (3 - 2 * x)
    }
}

private struct BookFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// A native screen-edge recognizer owns only the system's left-edge hit region.
/// The page-turn controllers below it therefore never receive the same touch.
private struct ScreenEdgeDismissGesture: UIViewRepresentable {
    let isEnabled: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> EdgeGestureHitView {
        let view = EdgeGestureHitView()
        view.backgroundColor = .clear
        let gesture = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        gesture.edges = .left
        gesture.maximumNumberOfTouches = 1
        gesture.delegate = context.coordinator
        gesture.isEnabled = isEnabled
        view.addGestureRecognizer(gesture)
        context.coordinator.gesture = gesture
        return view
    }

    func updateUIView(_ view: EdgeGestureHitView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.gesture?.isEnabled = isEnabled
        view.edgeInteractionEnabled = isEnabled
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void
        weak var gesture: UIScreenEdgePanGestureRecognizer?

        init(onChanged: @escaping (CGFloat) -> Void, onEnded: @escaping (CGFloat, CGFloat) -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func handle(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            let translation = max(0, recognizer.translation(in: recognizer.view).x)
            switch recognizer.state {
            case .changed:
                onChanged(translation)
            case .ended:
                let velocity = recognizer.velocity(in: recognizer.view).x
                onEnded(translation, max(0, translation + velocity * 0.18))
            case .cancelled, .failed:
                onEnded(translation, 0)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let edge = gestureRecognizer as? UIScreenEdgePanGestureRecognizer else { return false }
            let velocity = edge.velocity(in: edge.view)
            return velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
        }
    }
}

private final class EdgeGestureHitView: UIView {
    var edgeInteractionEnabled = true

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        edgeInteractionEnabled && point.x <= max(24, safeAreaInsets.left + 18)
    }
}

private enum ReaderTransitionPhase: Equatable {
    case idle
    case preparing
    case opening
    case open
    case edgeDragging
    case closing
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

enum BookcaseLayoutMetrics {
    static let topInset: CGFloat = 27
    static let bottomInset: CGFloat = 23
    static let shelfHeight: CGFloat = 26
    static let minimumRowContentHeight: CGFloat = 158

    static func resolvedViewportHeight(
        current: CGFloat,
        cached: CGFloat?,
        readerPresented: Bool
    ) -> CGFloat {
        guard readerPresented, let cached, cached > 0 else { return current }
        return cached
    }

    static func rowContentHeight(viewportHeight: CGFloat, rowCount: Int) -> CGFloat {
        let rows = max(rowCount, 1)
        let fixedHeight = topInset + bottomInset + shelfHeight * CGFloat(rows)
        return max(minimumRowContentHeight, (viewportHeight - fixedHeight) / CGFloat(rows))
    }

    static func totalHeight(rowContentHeight: CGFloat, rowCount: Int) -> CGFloat {
        let rows = max(rowCount, 1)
        return topInset
            + bottomInset
            + CGFloat(rows) * (rowContentHeight + shelfHeight)
    }
}

private struct WoodenBookcase<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            // Recessed cabinet back: dark at the edges and warmer in the
            // center, with narrow vertical boards rather than one flat panel.
            WoodSurface(axis: .vertical, colors: [Color(hex: "21130E"), Color(hex: "3A2117"), Color(hex: "170D09")])
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.52), .clear, .black.opacity(0.38)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .overlay {
                    HStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { index in
                            Color.clear
                                .overlay(alignment: .trailing) {
                                    Rectangle()
                                        .fill(index.isMultiple(of: 2) ? .black.opacity(0.18) : .white.opacity(0.025))
                                        .frame(width: 1)
                                }
                        }
                    }
                }
            content
                .padding(.horizontal, 17)
                .padding(.top, BookcaseLayoutMetrics.topInset)
                .padding(.bottom, BookcaseLayoutMetrics.bottomInset)
        }
        .background(Color(hex: "170D09"))
        .overlay {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.2), .black.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3
                )
                .padding(2)
        }
        .overlay(alignment: .leading) {
            CabinetPost(isLeading: true)
        }
        .overlay(alignment: .trailing) {
            CabinetPost(isLeading: false)
        }
        .overlay(alignment: .top) {
            WoodSurface(axis: .horizontal, colors: [Color(hex: "A0714B"), Color(hex: "684128"), Color(hex: "2E190F")])
                .frame(height: 27)
                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.25)).frame(height: 1) }
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.black.opacity(0.08), .black.opacity(0.68)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 7)
                }
        }
        .overlay(alignment: .bottom) {
            WoodSurface(axis: .horizontal, colors: [Color(hex: "2A160E"), Color(hex: "71472C"), Color(hex: "9A6B47"), Color(hex: "3B2115")])
                .frame(height: 23)
                .overlay(alignment: .top) { Rectangle().fill(.black.opacity(0.58)).frame(height: 3) }
                .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.14)).frame(height: 1) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
        .shadow(color: .black.opacity(0.34), radius: 14, x: 0, y: 9)
    }
}

private struct CabinetPost: View {
    let isLeading: Bool

    var body: some View {
        WoodSurface(
            axis: .vertical,
            colors: isLeading
                ? [Color(hex: "A27551"), Color(hex: "634027"), Color(hex: "321C12")]
                : [Color(hex: "321C12"), Color(hex: "68442A"), Color(hex: "9A6D4B")]
        )
        .frame(width: 21)
        .overlay(alignment: isLeading ? .trailing : .leading) {
            LinearGradient(
                colors: [.black.opacity(0.12), .black.opacity(0.62)],
                startPoint: isLeading ? .leading : .trailing,
                endPoint: isLeading ? .trailing : .leading
            )
            .frame(width: 5)
        }
        .overlay(alignment: isLeading ? .leading : .trailing) {
            Rectangle().fill(.white.opacity(0.16)).frame(width: 1).padding(.horizontal, 3)
        }
    }
}

private enum WoodGrainAxis: Equatable {
    case horizontal
    case vertical
}

private struct WoodSurface: View {
    let axis: WoodGrainAxis
    let colors: [Color]

    var body: some View {
        LinearGradient(
            colors: colors,
            startPoint: axis == .horizontal ? .top : .leading,
            endPoint: axis == .horizontal ? .bottom : .trailing
        )
        .overlay {
            Canvas(rendersAsynchronously: true) { context, size in
                let lineCount = axis == .horizontal ? 15 : 9
                for index in 0..<lineCount {
                    var path = Path()
                    if axis == .horizontal {
                        let baseY = size.height * CGFloat(index + 1) / CGFloat(lineCount + 1)
                        path.move(to: CGPoint(x: 0, y: baseY))
                        for step in 1...18 {
                            let x = size.width * CGFloat(step) / 18
                            let wave = sin(CGFloat(step + index * 3) * 0.72) * 1.25
                            path.addLine(to: CGPoint(x: x, y: baseY + wave))
                        }
                    } else {
                        let baseX = size.width * CGFloat(index + 1) / CGFloat(lineCount + 1)
                        path.move(to: CGPoint(x: baseX, y: 0))
                        for step in 1...22 {
                            let y = size.height * CGFloat(step) / 22
                            let wave = sin(CGFloat(step + index * 4) * 0.61) * 1.15
                            path.addLine(to: CGPoint(x: baseX + wave, y: y))
                        }
                    }
                    context.stroke(path, with: .color(.black.opacity(index.isMultiple(of: 3) ? 0.18 : 0.09)), lineWidth: 0.7)
                }

                // A few deterministic growth rings make the surface read as
                // timber without introducing a large raster texture asset.
                let knotCount = axis == .horizontal ? 3 : 2
                for index in 0..<knotCount {
                    let center = CGPoint(
                        x: size.width * CGFloat(index * 3 + 2) / CGFloat(knotCount * 3 + 1),
                        y: size.height * CGFloat(index + 1) / CGFloat(knotCount + 1)
                    )
                    for ring in 0..<3 {
                        let radius = CGFloat(3 + ring * 3)
                        let rect = CGRect(
                            x: center.x - radius * 1.8,
                            y: center.y - radius * 0.48,
                            width: radius * 3.6,
                            height: radius * 0.96
                        )
                        context.stroke(
                            Path(ellipseIn: rect),
                            with: .color(.black.opacity(0.08 + Double(ring) * 0.025)),
                            lineWidth: 0.65
                        )
                    }
                }
            }
        }
    }
}

private struct WoodenShelf: View {
    var body: some View {
        VStack(spacing: 0) {
            WoodSurface(axis: .horizontal, colors: [Color(hex: "A97B55"), Color(hex: "684129"), Color(hex: "351C11")])
                .frame(height: 15)
            WoodSurface(axis: .horizontal, colors: [Color(hex: "2B160D"), Color(hex: "70452A"), Color(hex: "9A6A48")])
                .frame(height: 11)
        }
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.24)).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.38)).frame(height: 2) }
        .shadow(color: .black.opacity(0.46), radius: 6, y: 5)
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
