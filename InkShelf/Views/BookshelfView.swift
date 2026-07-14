import SwiftUI
import UIKit

struct BookshelfView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var searchText = ""
    @State private var bookFrames: [UUID: CGRect] = [:]
    @State private var selectedBookID: UUID?
    @State private var selectedBookFrame: CGRect?
    @State private var readerTransitionProgress: CGFloat = 1
    @State private var readerTransitionPhase = ReaderTransitionPhase.idle
    @State private var readerBlocksEdgeDismiss = false
    @State private var frozenBookOrder: [UUID]?
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
            GeometryReader { proxy in
                ZStack {
                    Color(hex: "EEE9DF").ignoresSafeArea()
                    VStack(spacing: 0) {
                        header
                        if library.books.isEmpty { emptyState } else { shelfContent }
                    }
                    if library.isImporting { importingOverlay }

                    if let selectedBookID,
                       let selectedBook = library.book(id: selectedBookID) {
                        readerTransitionLayer(
                            book: selectedBook,
                            targetFrame: selectedBookFrame ?? bookFrames[selectedBookID] ?? fallbackBookFrame(in: proxy.size),
                            containerSize: proxy.size
                        )
                        .zIndex(10)
                    }
                }
                .coordinateSpace(name: "bookshelfRoot")
                .onPreferenceChange(BookFramePreferenceKey.self) { bookFrames = $0 }
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
            .onChange(of: sortRaw) { _, _ in frozenBookOrder = nil }
            .onChange(of: searchText) { _, _ in
                if selectedBookID == nil { frozenBookOrder = nil }
            }
            .onChange(of: library.books.map(\.id)) { oldIDs, newIDs in
                if oldIDs != newIDs { frozenBookOrder = nil }
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
                    ShelfRow(books: row, onOpen: openReader)
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

    @ViewBuilder
    private func readerTransitionLayer(book: NovelBook, targetFrame: CGRect, containerSize: CGSize) -> some View {
        let phase = readerTransitionPhase
        ReaderTransitionLayer(
            book: book,
            targetFrame: targetFrame,
            containerSize: containerSize,
            progress: readerTransitionProgress,
            interactionDisabled: phase != .open,
            edgeGestureEnabled: (phase == .open || phase == .edgeDragging) && !readerBlocksEdgeDismiss,
            onReady: { readerDidBecomeReady(bookID: book.id) },
            onRequestClose: { closeReader(bookID: book.id) },
            onBlockingStateChanged: { readerBlocksEdgeDismiss = $0 },
            onEdgeChanged: { edgeDragChanged($0, bookID: book.id, containerWidth: containerSize.width) },
            onEdgeEnded: { translation, predicted in
                edgeDragEnded(
                    translation: translation,
                    predictedTranslation: predicted,
                    bookID: book.id,
                    containerWidth: containerSize.width
                )
            }
        )
        .ignoresSafeArea()
    }

    private func openReader(_ book: NovelBook) {
        guard selectedBookID == nil, readerTransitionPhase == .idle else { return }
        frozenBookOrder = displayedBooks.map(\.id)
        readerBlocksEdgeDismiss = false
        readerTransitionProgress = 1
        readerTransitionPhase = .preparing
        selectedBookFrame = bookFrames[book.id]
        selectedBookID = book.id
    }

    private func readerDidBecomeReady(bookID: UUID) {
        guard selectedBookID == bookID, readerTransitionPhase == .preparing else { return }
        readerTransitionPhase = .opening
        withAnimation(.spring(response: 0.46, dampingFraction: 0.88, blendDuration: 0.08)) {
            readerTransitionProgress = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard selectedBookID == bookID, readerTransitionPhase == .opening else { return }
            readerTransitionPhase = .open
        }
    }

    private func closeReader(bookID: UUID) {
        guard selectedBookID == bookID,
              readerTransitionPhase == .open || readerTransitionPhase == .edgeDragging else { return }
        readerTransitionPhase = .closing
        withAnimation(.spring(response: 0.42, dampingFraction: 0.9, blendDuration: 0.06)) {
            readerTransitionProgress = 1
        }
        completeReaderDismissal(bookID: bookID, after: 0.46)
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
            readerTransitionProgress = 1
            readerTransitionPhase = .idle
            readerBlocksEdgeDismiss = false
        }
    }

    private func fallbackBookFrame(in size: CGSize) -> CGRect {
        CGRect(x: (size.width - 92) / 2, y: 176, width: 92, height: 135)
    }
}

private struct ShelfRow: View {
    @EnvironmentObject private var library: LibraryStore
    let books: [NovelBook]
    let onOpen: (NovelBook) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 17) {
                ForEach(books) { book in
                    Button { onOpen(book) } label: {
                        VStack(spacing: 9) {
                            BookCoverView(book: book, compact: true)
                                .frame(maxWidth: 92)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: BookFramePreferenceKey.self,
                                            value: [book.id: proxy.frame(in: .named("bookshelfRoot"))]
                                        )
                                    }
                                }
                            VStack(spacing: 2) {
                                Text(book.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(book.chapterProgressDescription).font(.system(size: 9)).foregroundStyle(.secondary)
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

}

private struct ReaderTransitionLayer: View {
    let book: NovelBook
    let targetFrame: CGRect
    let containerSize: CGSize
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
        let scaleX = 1 + (targetFrame.width / width - 1) * boundedProgress
        let scaleY = 1 + (targetFrame.height / height - 1) * boundedProgress
        let coverWidth = targetFrame.width + (width - targetFrame.width) * (1 - boundedProgress)
        let coverHeight = coverWidth / 0.68
        let coverCenter = CGPoint(
            x: targetFrame.midX + (width / 2 - targetFrame.midX) * (1 - boundedProgress),
            y: targetFrame.midY + (height / 2 - targetFrame.midY) * (1 - boundedProgress)
        )
        let coverOpacity = min(1, max(0, (boundedProgress - 0.58) / 0.42))
        let readerOpacity = min(1, max(0, (1 - boundedProgress) / 0.3))

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
            .clipShape(RoundedRectangle(cornerRadius: 7 * boundedProgress, style: .continuous))
            .scaleEffect(x: scaleX, y: scaleY, anchor: .topLeading)
            .offset(x: targetFrame.minX * boundedProgress, y: targetFrame.minY * boundedProgress)
            .shadow(color: .black.opacity(0.22 * boundedProgress), radius: 14, x: 3, y: 7)

            BookCoverView(book: book, compact: true)
                .frame(width: coverWidth, height: coverHeight)
                .position(coverCenter)
                .opacity(coverOpacity)
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
