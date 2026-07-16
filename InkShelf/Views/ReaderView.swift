import SwiftUI
import UIKit
import PhotosUI
import CoreImage

struct ReaderView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let interactionDisabled: Bool
    let onRequestClose: (() -> Void)?
    let onReady: () -> Void
    let onBlockingStateChanged: (Bool) -> Void

    @State private var location = ReaderPageLocation(chapterIndex: 0, pageIndex: 0)
    @State private var catalog = ReaderPageCatalog.empty
    @State private var chromeVisible = false
    @State private var showingIndex = false
    @State private var showingAppearance = false
    @State private var showingNote = false
    @StateObject private var readAloud = ReadAloudService()
    @State private var readAloudPlayerVisible = false
    @State private var readAloudError: String?
    @State private var automatedTurnTarget: ReaderPageLocation?
    @State private var originalReadAloudLocation: ReaderPageLocation?
    @State private var scrubbedWholeBookChapterIndex: Double?
    @State private var isScrubbingWholeBookProgress = false
    @State private var brightness = Double(UIScreen.main.brightness)
    @State private var originalBrightness = UIScreen.main.brightness
    @State private var showingBackgroundPicker = false
    @State private var selectedBackgroundPhoto: PhotosPickerItem?
    @State private var customBackgroundImage = ReaderCustomBackgroundStore.load().flatMap(UIImage.init(data:))
    @State private var backgroundImportError: String?
    @State private var showingCustomBackgroundEditor = false
    @State private var draftCustomToneRaw = ReaderCustomBackgroundTone.light.rawValue
    @State private var draftCustomBlurRaw = ReaderCustomBackgroundBlur.none.rawValue
    @State private var draftCustomTransparency = 0.34

    @AppStorage("readerTheme") private var themeRaw = ReaderTheme.paper.rawValue
    @AppStorage("readerDayTheme") private var dayThemeRaw = ReaderTheme.paper.rawValue
    @AppStorage("readerBackground") private var backgroundRaw = ReaderBackgroundStyle.plain.rawValue
    @AppStorage("readerBackgroundRevision") private var backgroundRevision = 0
    @AppStorage("readerCustomBackgroundTone") private var customToneRaw = ReaderCustomBackgroundTone.light.rawValue
    @AppStorage("readerCustomBackgroundBlur") private var customBlurRaw = ReaderCustomBackgroundBlur.none.rawValue
    @AppStorage("readerCustomBackgroundTransparency") private var customTransparency = 0.34
    @AppStorage("readerFont") private var fontRaw = ReaderFont.system.rawValue
    @AppStorage("pageTurnStyle") private var turnRaw = PageTurnStyle.curl.rawValue
    @AppStorage("readerFontSize") private var fontSize = 19.0
    @AppStorage("readerLineSpacing") private var lineSpacing = 9.0
    @AppStorage("readerMargin") private var margin = 22.0
    @AppStorage("keepScreenAwake") private var keepScreenAwake = true

    private var book: NovelBook? { library.book(id: bookID) }
    private var backgroundStyle: ReaderBackgroundStyle {
        ReaderBackgroundStyle(rawValue: backgroundRaw) ?? .plain
    }
    private var customTone: ReaderCustomBackgroundTone {
        ReaderCustomBackgroundTone(rawValue: customToneRaw) ?? .light
    }
    private var customBlur: ReaderCustomBackgroundBlur {
        ReaderCustomBackgroundBlur(rawValue: customBlurRaw) ?? .none
    }
    private var theme: ReaderTheme {
        if backgroundStyle == .custom { return customTone.theme }
        return ReaderTheme(rawValue: themeRaw) ?? .paper
    }
    private var backgroundOverlayOpacity: CGFloat {
        if backgroundStyle == .custom {
            return CGFloat(min(0.85, max(0.25, 1 - customTransparency)))
        }
        return backgroundStyle.readabilityOverlayOpacity
    }
    private var activeBackgroundBlur: ReaderCustomBackgroundBlur {
        backgroundStyle == .custom ? customBlur : .none
    }
    private var turnStyle: PageTurnStyle { PageTurnStyle(rawValue: turnRaw) ?? .curl }
    private var readerFont: ReaderFont { ReaderFont(rawValue: fontRaw) ?? .system }

    init(
        bookID: UUID,
        interactionDisabled: Bool = false,
        onRequestClose: (() -> Void)? = nil,
        onReady: @escaping () -> Void = { },
        onBlockingStateChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.bookID = bookID
        self.interactionDisabled = interactionDisabled
        self.onRequestClose = onRequestClose
        self.onReady = onReady
        self.onBlockingStateChanged = onBlockingStateChanged
    }

    var body: some View {
        Group {
            if let book {
                GeometryReader { proxy in
                    let chapter = safeChapter(in: book)
                    let capacity = charactersPerPage(in: proxy.size)
                    let layout = paginationLayout(for: book, size: proxy.size)
                    ZStack {
                        ReaderBackgroundSurface(
                            theme: theme,
                            style: backgroundStyle,
                            customImage: customBackgroundImage,
                            overlayOpacity: backgroundOverlayOpacity,
                            blur: activeBackgroundBlur
                        )
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                        if turnStyle == .vertical {
                            verticalReader(book: book, chapter: chapter)
                        } else if catalog.isEmpty {
                            ProgressView().tint(theme.foreground)
                        } else {
                            InteractivePageTurnView(
                                pages: catalog.pages,
                                location: location,
                                appearance: pageAppearance(bookTitle: book.title),
                                mode: pageTurnMode,
                                isInteractionEnabled: !showingAppearance
                                    && !isScrubbingWholeBookProgress
                                    && !interactionDisabled,
                                automatedTurnTarget: automatedTurnTarget,
                                onCommit: commit,
                                onPlayParagraph: playParagraph,
                                onCenterTap: { withAnimation(.easeOut(duration: 0.18)) { chromeVisible.toggle() } }
                            )
                            .ignoresSafeArea()
                        }
                        if chromeVisible { readerChrome(book: book) }
                        if chromeVisible, readAloudPlayerVisible, readAloud.hasSession {
                            readAloudFloater(book: book)
                        } else if !chromeVisible, readAloud.hasSession {
                            immersiveReadAloudBar
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: chromeVisible)
                    .task(id: layout) { await rebuildCatalog(for: book, charactersPerPage: capacity) }
                    .allowsHitTesting(!interactionDisabled)
                }
                .statusBarHidden(!chromeVisible)
            } else {
                ContentUnavailableView("书籍不存在", systemImage: "book.closed")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if let book {
                location = ReaderPageLocation(
                    chapterIndex: min(book.currentChapter, max(book.chapters.count - 1, 0)),
                    pageIndex: max(0, book.currentPage)
                )
            }
            originalBrightness = UIScreen.main.brightness
            UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
            reportBlockingState()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            UIScreen.main.brightness = originalBrightness
            readAloud.onPageFinished = nil
            readAloud.stop()
        }
        .onChange(of: showingAppearance) { _, _ in reportBlockingState() }
        .onChange(of: showingIndex) { _, _ in reportBlockingState() }
        .onChange(of: showingNote) { _, _ in reportBlockingState() }
        .onChange(of: readAloud.state) { _, state in
            if case let .failed(message) = state { readAloudError = message }
        }
        .onChange(of: isScrubbingWholeBookProgress) { _, _ in reportBlockingState() }
        .onChange(of: showingCustomBackgroundEditor) { _, _ in reportBlockingState() }
        .onChange(of: selectedBackgroundPhoto) { _, item in
            importSelectedBackground(item)
        }
        .photosPicker(
            isPresented: $showingBackgroundPicker,
            selection: $selectedBackgroundPhoto,
            matching: .images
        )
        .fullScreenCover(isPresented: $showingCustomBackgroundEditor) {
            CustomBackgroundEditor(
                image: $customBackgroundImage,
                toneRaw: $draftCustomToneRaw,
                blurRaw: $draftCustomBlurRaw,
                transparency: $draftCustomTransparency,
                chapterTitle: book.map { safeChapter(in: $0).title } ?? "第一章",
                excerpt: book.map { currentExcerpt(book: $0) } ?? "预览正文",
                onImageChanged: { backgroundRevision += 1 },
                onCancel: { showingCustomBackgroundEditor = false },
                onConfirm: applyCustomBackground
            )
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingIndex) {
            if let book {
                ReaderIndexSheet(book: book) { chapter, page in
                    jump(to: ReaderPageLocation(chapterIndex: chapter, pageIndex: page))
                    showingIndex = false
                }
            }
        }
        .sheet(isPresented: $showingNote) {
            if let book {
                NoteEditor(
                    bookID: book.id,
                    chapter: location.chapterIndex,
                    page: location.pageIndex,
                    excerpt: currentExcerpt(book: book)
                )
            }
        }
        .alert(
            "朗读失败",
            isPresented: Binding(
                get: { readAloudError != nil },
                set: { if !$0 { readAloudError = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { readAloudError = nil }
        } message: {
            Text(readAloudError ?? "无法开始朗读")
        }
        .alert(
            "背景导入失败",
            isPresented: Binding(
                get: { backgroundImportError != nil },
                set: { if !$0 { backgroundImportError = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { backgroundImportError = nil }
        } message: {
            Text(backgroundImportError ?? "无法读取图片")
        }
    }

    private func safeChapter(in book: NovelBook) -> NovelChapter {
        let chapters = book.chapters
        guard !chapters.isEmpty else {
            return NovelChapter(index: 0, title: "正文", content: book.content)
        }
        return chapters[min(max(location.chapterIndex, 0), max(chapters.count - 1, 0))]
    }

    private func charactersPerPage(in size: CGSize) -> Int {
        let usableWidth = max(180, size.width - margin * 2)
        let usableHeight = max(240, size.height - 112)
        let columns = usableWidth / max(fontSize * 1.04, 1)
        let rows = usableHeight / max(fontSize + lineSpacing, 1)
        return max(180, Int(columns * rows * 0.92))
    }

    private var pageTurnMode: InteractivePageTurnMode {
        switch turnStyle {
        case .curl: return .curl
        case .slide: return .cover
        case .none: return .immediate
        case .vertical: return .cover
        }
    }

    private func pageAppearance(bookTitle: String) -> ReaderPageAppearance {
        ReaderPageAppearance(
            themeID: "\(theme.rawValue)|\(backgroundStyle.rawValue)|\(backgroundRevision)|\(customToneRaw)|\(customBlurRaw)|\(customTransparency)",
            bookTitle: bookTitle,
            backgroundColor: UIColor(theme.background),
            backsideColor: UIColor(theme.pageBack),
            textColor: UIColor(theme.foreground),
            backgroundStyle: backgroundStyle,
            backgroundImage: backgroundImage(for: backgroundStyle),
            backgroundOverlayOpacity: backgroundOverlayOpacity,
            backgroundBlur: activeBackgroundBlur,
            fontName: readerFont.name,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            horizontalMargin: margin,
            highlightedLocation: readAloud.currentPageLocation,
            highlightedRange: readAloud.currentSentenceRange,
            showsReadAloudControls: readAloud.hasSession,
            isReadAloudPlaying: readAloud.isPlaying
        )
    }

    private func paginationLayout(for book: NovelBook, size: CGSize) -> PaginationLayout {
        PaginationLayout(
            bookID: book.id,
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded()),
            fontSize: Int((fontSize * 10).rounded()),
            lineSpacing: Int((lineSpacing * 10).rounded()),
            margin: Int((margin * 10).rounded()),
            fontName: readerFont.name ?? "system"
        )
    }

    private func rebuildCatalog(for book: NovelBook, charactersPerPage: Int) async {
        let rebuilt = await Task.detached(priority: .userInitiated) {
            ReaderPageCatalog(book: book, charactersPerPage: charactersPerPage)
        }.value
        guard !Task.isCancelled else { return }
        guard let settledLocation = rebuilt.nearest(to: location) else { return }
        catalog = rebuilt
        onReady()
        if settledLocation != location {
            location = settledLocation
            persist(settledLocation)
        }
    }

    private func commit(_ settledLocation: ReaderPageLocation) {
        guard settledLocation != location else { return }
        let shouldContinuePlaying = readAloud.isPlaying || automatedTurnTarget == settledLocation
        let hadReadAloudSession = readAloud.hasSession
        automatedTurnTarget = nil
        location = settledLocation
        persist(settledLocation)
        guard hadReadAloudSession, let page = catalog.page(at: settledLocation) else { return }
        readAloud.setPage(text: page.text, location: page.location)
        if shouldContinuePlaying { readAloud.play() }
    }

    private func jump(to requestedLocation: ReaderPageLocation) {
        let settled = catalog.nearest(to: requestedLocation) ?? requestedLocation
        location = settled
        persist(settled)
    }

    private func startReadingCurrentPage() {
        guard let page = catalog.page(at: location) else {
            readAloudError = "当前页面尚未加载完成"
            return
        }
        beginReading(page: page, paragraphLocation: nil)
    }

    private func playParagraph(_ page: ReaderPage, range: NSRange) {
        if readAloud.currentPageLocation == page.location,
           let highlightedRange = readAloud.currentSentenceRange,
           NSIntersectionRange(highlightedRange, range).length > 0 {
            if readAloud.isPlaying {
                readAloud.pause()
            } else {
                readAloud.play()
            }
            return
        }
        if page.location != location { jump(to: page.location) }
        beginReading(page: page, paragraphLocation: range.location)
    }

    private func beginReading(page: ReaderPage, paragraphLocation: Int?) {
        if originalReadAloudLocation == nil { originalReadAloudLocation = location }
        readAloud.onPageFinished = { [weak readAloud] in
            guard readAloud != nil else { return }
            Task { @MainActor in autoAdvanceReadAloud() }
        }
        readAloud.setPage(
            text: page.text,
            location: page.location,
            startAtUTF16Location: paragraphLocation ?? 0
        )
        readAloud.play()
        readAloudPlayerVisible = true
    }

    private func autoAdvanceReadAloud() {
        guard readAloud.currentPageLocation == location else { return }
        guard let nextPage = catalog.adjacent(to: location, direction: .forward) else {
            readAloud.stop()
            readAloudPlayerVisible = false
            originalReadAloudLocation = nil
            return
        }
        automatedTurnTarget = nextPage.location
        if turnStyle == .vertical {
            commit(nextPage.location)
        }
    }

    private func returnToOriginalReadAloudProgress() {
        guard let originalReadAloudLocation else { return }
        readAloud.stop()
        readAloudPlayerVisible = false
        automatedTurnTarget = nil
        self.originalReadAloudLocation = nil
        jump(to: originalReadAloudLocation)
    }

    private func persist(_ settledLocation: ReaderPageLocation) {
        library.updateProgress(
            bookID: bookID,
            chapter: settledLocation.chapterIndex,
            page: settledLocation.pageIndex
        )
    }

    private func requestClose() {
        if let onRequestClose {
            onRequestClose()
        } else {
            dismiss()
        }
    }

    private func reportBlockingState() {
        onBlockingStateChanged(
            showingAppearance
                || showingIndex
                || showingNote
                || showingCustomBackgroundEditor
                || isScrubbingWholeBookProgress
        )
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
                    Button("上一章") {
                        if location.chapterIndex > 0 {
                            jump(to: ReaderPageLocation(chapterIndex: location.chapterIndex - 1, pageIndex: 0))
                        }
                    }
                    .disabled(location.chapterIndex == 0)
                    Spacer()
                    Button("下一章") {
                        if location.chapterIndex + 1 < book.chapters.count {
                            jump(to: ReaderPageLocation(chapterIndex: location.chapterIndex + 1, pageIndex: 0))
                        }
                    }
                    .disabled(location.chapterIndex + 1 >= book.chapters.count)
                }
                .buttonStyle(.bordered).tint(theme.foreground)
            }
            .foregroundStyle(theme.foreground)
            .padding(.horizontal, margin).padding(.top, 54).padding(.bottom, 80)
        }
        .simultaneousGesture(TapGesture().onEnded { withAnimation { chromeVisible.toggle() } })
    }

    private func readerChrome(book: NovelBook) -> some View {
        return VStack {
            HStack(spacing: 18) {
                Button { requestClose() } label: { Image(systemName: "chevron.left") }
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(safeChapter(in: book).title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { toggleBookmark(book: book) } label: { Image(systemName: isBookmarked(book) ? "bookmark.fill" : "bookmark") }
                Button { showingNote = true } label: { Image(systemName: "square.and.pencil") }
            }
            .font(.system(size: 18, weight: .medium))
            .padding(.horizontal, 18)
            .frame(height: 58)
            .padding(.top, statusBarTopInset)
            .background(.ultraThinMaterial)
            .allowsHitTesting(!showingAppearance)
            Spacer()
            VStack(spacing: 14) {
                if turnStyle != .vertical && !showingAppearance {
                    wholeBookProgressControl(book: book)
                }
                if showingAppearance { appearanceControls }
                HStack {
                    ChromeAction(icon: "list.bullet", label: "目录") { showingIndex = true }
                    ChromeAction(
                        icon: theme == .night ? "sun.max.fill" : "moon.fill",
                        label: theme == .night ? "日间" : "夜间"
                    ) {
                        toggleNightMode()
                    }
                    ChromeAction(icon: "waveform", label: "朗读") {
                        if readAloud.hasSession {
                            readAloudPlayerVisible.toggle()
                        } else {
                            startReadingCurrentPage()
                            readAloudPlayerVisible = true
                        }
                    }
                    ChromeAction(
                        icon: showingAppearance ? "chevron.down.circle.fill" : "paintpalette",
                        label: showingAppearance ? "收起" : "设置"
                    ) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showingAppearance.toggle()
                        }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.top, 13).padding(.bottom, 18)
            .background(.ultraThinMaterial)
            .contentShape(Rectangle())
            .onTapGesture { }
        }
        .background {
            if showingAppearance {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        showingAppearance = false
                        chromeVisible = false
                    }
            }
        }
        .foregroundStyle(Color.primary)
        .transition(.opacity)
    }

    private func readAloudFloater(book: NovelBook) -> some View {
        let defaultCoverName = BookPalette.defaultCoverAssetName(for: book.coverStyle)
        let customCoverImage = book.coverData.flatMap { UIImage(data: $0) }
        let coverImage = customCoverImage ?? UIImage(named: defaultCoverName)
        let coverSignature = book.coverData.map { "custom-\($0.hashValue)" } ?? "asset-\(defaultCoverName)"
        return ReaderReadAloudFloater(
            readAloud: readAloud,
            bookID: book.id,
            bookTitle: book.title,
            coverImage: coverImage,
            coverSignature: coverSignature,
            onPlayPause: {
                if readAloud.isPlaying { readAloud.pause() } else { readAloud.play() }
            },
            onClose: {
                readAloud.stop()
                readAloudPlayerVisible = false
                originalReadAloudLocation = nil
            }
        )
        .padding(.leading, 24)
        .padding(.bottom, 152)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .transition(.scale(scale: 0.92, anchor: .bottomLeading).combined(with: .opacity))
    }

    private var immersiveReadAloudBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 9) {
                Button(action: returnToOriginalReadAloudProgress) {
                    Label("原进度", systemImage: "arrow.uturn.backward")
                }
                .disabled(originalReadAloudLocation == nil)

                Rectangle()
                    .fill(Color.white.opacity(0.34))
                    .frame(width: 1, height: 15)

                Button(action: startReadingCurrentPage) {
                    Label("从本页听", systemImage: "headphones")
                }
            }
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .frame(height: 38)
            .background(Color(hex: "8A795D").opacity(0.9), in: Capsule())
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .padding(.bottom, 38)
        }
        .allowsHitTesting(true)
        .transition(.opacity)
    }

    private func wholeBookProgressControl(book: NovelBook) -> some View {
        let maximumChapterIndex = max(book.chapters.count - 1, 1)
        let previewChapterIndex = min(
            max(Int((scrubbedWholeBookChapterIndex ?? Double(location.chapterIndex)).rounded()), 0),
            max(book.chapters.count - 1, 0)
        )
        let previewChapter = book.chapters.indices.contains(previewChapterIndex)
            ? book.chapters[previewChapterIndex]
            : nil
        let previewPercentage = wholeBookProgressPercentage(
            chapterIndex: previewChapterIndex,
            chapterCount: book.chapters.count
        )

        return HStack(spacing: 12) {
            Button {
                moveToChapter(location.chapterIndex - 1, in: book)
            } label: {
                Text("上一章")
                    .frame(width: 52, alignment: .leading)
            }
            .disabled(location.chapterIndex == 0 || isScrubbingWholeBookProgress || showingAppearance)

            Slider(
                value: Binding(
                    get: { scrubbedWholeBookChapterIndex ?? Double(location.chapterIndex) },
                    set: { scrubbedWholeBookChapterIndex = $0 }
                ),
                in: 0...Double(maximumChapterIndex),
                step: 1,
                onEditingChanged: { editing in
                    handleWholeBookProgressEditing(editing, book: book)
                }
            )
            .disabled(book.chapters.count <= 1 || showingAppearance)
            .tint(theme.foreground.opacity(0.72))
            .accessibilityLabel("全书阅读进度")
            .accessibilityValue("\(previewPercentage) 百分比，\(previewChapter?.title ?? "未知章节")")

            Button {
                moveToChapter(location.chapterIndex + 1, in: book)
            } label: {
                Text("下一章")
                    .frame(width: 52, alignment: .trailing)
            }
            .disabled(
                location.chapterIndex + 1 >= book.chapters.count
                    || isScrubbingWholeBookProgress
                    || showingAppearance
            )
        }
        .font(.caption.weight(.medium))
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if isScrubbingWholeBookProgress, let previewChapter {
                VStack(spacing: 4) {
                    Text("\(previewPercentage)%")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Text(previewChapter.title)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(theme.background)
                .padding(.horizontal, 18)
                .frame(width: 246, height: 62)
                .background(theme.foreground.opacity(0.82), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
                .allowsHitTesting(false)
                .offset(y: -76)
                .transition(.scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.16), value: isScrubbingWholeBookProgress)
    }

    private func handleWholeBookProgressEditing(_ editing: Bool, book: NovelBook) {
        if editing {
            if scrubbedWholeBookChapterIndex == nil {
                scrubbedWholeBookChapterIndex = Double(location.chapterIndex)
            }
            isScrubbingWholeBookProgress = true
            return
        }

        let targetChapterIndex = min(
            max(Int((scrubbedWholeBookChapterIndex ?? Double(location.chapterIndex)).rounded()), 0),
            max(book.chapters.count - 1, 0)
        )
        scrubbedWholeBookChapterIndex = nil
        isScrubbingWholeBookProgress = false
        moveToChapter(targetChapterIndex, in: book)
    }

    private func wholeBookProgressPercentage(chapterIndex: Int, chapterCount: Int) -> Int {
        guard chapterCount > 1 else { return 100 }
        let progress = Double(chapterIndex) / Double(chapterCount - 1)
        return min(100, max(0, Int((progress * 100).rounded())))
    }

    private func moveToChapter(_ chapterIndex: Int, in book: NovelBook) {
        guard book.chapters.indices.contains(chapterIndex) else { return }
        scrubbedWholeBookChapterIndex = nil
        isScrubbingWholeBookProgress = false
        jump(to: ReaderPageLocation(chapterIndex: chapterIndex, pageIndex: 0))
    }

    private var statusBarTopInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        let windowInset = window?.safeAreaInsets.top ?? 0
        let statusBarHeight = scene?.statusBarManager?.statusBarFrame.height ?? 0
        return max(20, max(windowInset, statusBarHeight))
    }

    private var appearanceControls: some View {
        VStack(spacing: 15) {
            HStack(spacing: 13) {
                Text("颜色")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)
                ForEach(ReaderTheme.allCases) { item in
                    Button {
                        themeRaw = item.rawValue
                        if item != .night { dayThemeRaw = item.rawValue }
                    } label: {
                        Circle()
                            .fill(item.background)
                            .frame(width: 32, height: 32)
                            .overlay {
                                Circle().stroke(
                                    themeRaw == item.rawValue ? theme.foreground.opacity(0.82) : .gray.opacity(0.3),
                                    lineWidth: themeRaw == item.rawValue ? 2 : 1
                                )
                            }
                            .overlay {
                                if themeRaw == item.rawValue {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(item.foreground)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            HStack(alignment: .top, spacing: 9) {
                Text("背景")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)
                    .padding(.top, 10)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(ReaderBackgroundStyle.allCases) { style in
                            Button {
                                selectBackground(style)
                            } label: {
                                VStack(spacing: 5) {
                                    ReaderBackgroundSurface(
                                        theme: style.recommendedTheme ?? theme,
                                        style: style,
                                        customImage: customBackgroundImage,
                                        overlayOpacity: style == .custom
                                            ? CGFloat(1 - customTransparency)
                                            : style.readabilityOverlayOpacity,
                                        blur: style == .custom ? customBlur : .none
                                    )
                                    .frame(width: 50, height: 38)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(
                                                backgroundStyle == style
                                                    ? theme.foreground.opacity(0.82)
                                                    : .gray.opacity(0.24),
                                                lineWidth: backgroundStyle == style ? 2 : 1
                                            )
                                    }
                                    .overlay {
                                        if style == .custom {
                                            Image(systemName: style.symbolName)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(theme.foreground.opacity(0.7))
                                                .frame(width: 24, height: 24)
                                                .background(.ultraThinMaterial, in: Circle())
                                        }
                                    }
                                    Text(style.rawValue)
                                        .font(.system(size: 9))
                                        .lineLimit(1)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Image(systemName: "sun.min")
                Slider(value: $brightness, in: 0.05...1) { _ in UIScreen.main.brightness = brightness }
                Image(systemName: "sun.max.fill")
            }

            HStack(spacing: 10) {
                Button("A−") { fontSize = max(14, fontSize - 1) }.buttonStyle(.bordered)
                Text("\(Int(fontSize))").font(.caption.monospacedDigit()).frame(width: 25)
                Button("A+") { fontSize = min(32, fontSize + 1) }.buttonStyle(.bordered)
                Picker("字体", selection: $fontRaw) {
                    ForEach(ReaderFont.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .labelsHidden()
                Spacer()
                Picker("翻页", selection: $turnRaw) {
                    ForEach(PageTurnStyle.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden()
            }

            HStack(spacing: 9) {
                Text("行距")
                Slider(value: $lineSpacing, in: 3...16, step: 1)
                Text("边距")
                Slider(value: $margin, in: 14...38, step: 2)
            }
        }
        .font(.caption)
    }

    private func toggleNightMode() {
        withAnimation(.easeOut(duration: 0.2)) {
            if backgroundStyle == .custom {
                let nextTone: ReaderCustomBackgroundTone = customTone == .dark ? .light : .dark
                customToneRaw = nextTone.rawValue
                themeRaw = nextTone.theme.rawValue
                if nextTone == .light { dayThemeRaw = nextTone.theme.rawValue }
                backgroundRevision += 1
                return
            }
            if theme == .night {
                let restored = ReaderTheme(rawValue: dayThemeRaw) ?? .paper
                themeRaw = restored == .night ? ReaderTheme.paper.rawValue : restored.rawValue
            } else {
                dayThemeRaw = theme.rawValue
                themeRaw = ReaderTheme.night.rawValue
            }
        }
    }

    private func selectBackground(_ style: ReaderBackgroundStyle) {
        if style == .custom {
            if customBackgroundImage == nil {
                showingBackgroundPicker = true
            } else {
                prepareCustomBackgroundEditor()
            }
            return
        }
        backgroundRaw = style.rawValue
        if let recommendedTheme = style.recommendedTheme {
            themeRaw = recommendedTheme.rawValue
            if recommendedTheme != .night {
                dayThemeRaw = recommendedTheme.rawValue
            }
        }
    }

    private func backgroundImage(for style: ReaderBackgroundStyle) -> UIImage? {
        if style == .custom { return customBackgroundImage }
        return style.usesBundledArtwork ? UIImage(named: "ReaderInkWash") : nil
    }

    private func importSelectedBackground(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            do {
                guard let sourceData = try await item.loadTransferable(type: Data.self) else {
                    throw ReaderCustomBackgroundError.unreadableImage
                }
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try ReaderCustomBackgroundStore.save(sourceData: sourceData)
                }.value
                customBackgroundImage = UIImage(data: prepared)
                backgroundRevision += 1
                selectedBackgroundPhoto = nil
                try? await Task.sleep(nanoseconds: 180_000_000)
                prepareCustomBackgroundEditor()
            } catch {
                backgroundImportError = error.localizedDescription
                selectedBackgroundPhoto = nil
            }
        }
    }

    private func prepareCustomBackgroundEditor() {
        draftCustomToneRaw = customToneRaw
        draftCustomBlurRaw = customBlurRaw
        draftCustomTransparency = customTransparency
        showingCustomBackgroundEditor = true
    }

    private func applyCustomBackground() {
        let tone = ReaderCustomBackgroundTone(rawValue: draftCustomToneRaw) ?? .light
        customToneRaw = tone.rawValue
        customBlurRaw = ReaderCustomBackgroundBlur(rawValue: draftCustomBlurRaw)?.rawValue
            ?? ReaderCustomBackgroundBlur.none.rawValue
        customTransparency = min(0.75, max(0.15, draftCustomTransparency))
        themeRaw = tone.theme.rawValue
        if tone == .light { dayThemeRaw = tone.theme.rawValue }
        backgroundRaw = ReaderBackgroundStyle.custom.rawValue
        backgroundRevision += 1
        showingCustomBackgroundEditor = false
    }

    private func readerSwiftUIFont(size: Double) -> Font {
        if let name = readerFont.name { return .custom(name, size: size) }
        return .system(size: size, design: .serif)
    }

    private func currentExcerpt(book: NovelBook) -> String {
        if let text = catalog.page(at: location)?.text { return String(text.prefix(80)) }
        return String(safeChapter(in: book).content.prefix(80))
    }

    private func isBookmarked(_ book: NovelBook) -> Bool {
        book.bookmarks.contains { $0.chapterIndex == location.chapterIndex && $0.pageIndex == location.pageIndex }
    }

    private func toggleBookmark(book: NovelBook) {
        library.toggleBookmark(
            bookID: book.id,
            chapter: location.chapterIndex,
            page: location.pageIndex,
            excerpt: currentExcerpt(book: book)
        )
    }
}

private struct ReaderReadAloudFloater: View {
    @ObservedObject var readAloud: ReadAloudService
    let bookID: UUID
    let bookTitle: String
    let coverImage: UIImage?
    let coverSignature: String
    let onPlayPause: () -> Void
    let onClose: () -> Void

    @State private var settledOffset = CGSize.zero
    @GestureState private var dragOffset = CGSize.zero

    private var palette: ReaderFloaterPalette {
        ReaderFloaterPalette.cached(
            bookID: bookID,
            coverSignature: coverSignature,
            coverImage: coverImage
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let image = coverImage {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Text(String(bookTitle.prefix(1)))
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: palette.secondary))
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 0.7))

            Button(action: onPlayPause) {
                Image(systemName: readAloud.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
                .background(.white.opacity(0.18), in: Circle())
            .accessibilityLabel(readAloud.isPlaying ? "暂停朗读" : "继续朗读")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭朗读")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 58)
        .background(
            LinearGradient(
                colors: [Color(uiColor: palette.primary), Color(uiColor: palette.secondary)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: Capsule()
        )
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.24), radius: 12, y: 5)
        .offset(
            x: settledOffset.width + dragOffset.width,
            y: settledOffset.height + dragOffset.height
        )
        .highPriorityGesture(
            DragGesture(minimumDistance: 8)
                .updating($dragOffset) { value, state, _ in state = value.translation }
                .onEnded { value in
                    settledOffset.width += value.translation.width
                    settledOffset.height += value.translation.height
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("朗读悬浮控制")
    }
}

private struct ReaderFloaterPalette {
    let primary: UIColor
    let secondary: UIColor

    private static let cache = NSCache<NSString, ReaderFloaterPaletteBox>()
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func cached(
        bookID: UUID,
        coverSignature: String,
        coverImage: UIImage?
    ) -> ReaderFloaterPalette {
        let key = "\(bookID.uuidString)-\(coverSignature)" as NSString
        if let cached = cache.object(forKey: key) { return cached.palette }

        let palette = make(from: coverImage)
        cache.setObject(ReaderFloaterPaletteBox(palette), forKey: key)
        return palette
    }

    private static func make(from image: UIImage?) -> ReaderFloaterPalette {
        guard let image,
              let inputImage = CIImage(image: image),
              let filter = CIFilter(name: "CIAreaAverage") else {
            return fallback
        }
        filter.setValue(inputImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: inputImage.extent), forKey: kCIInputExtentKey)
        guard let outputImage = filter.outputImage else { return fallback }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            outputImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let average = UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return fallback
        }

        let adaptedSaturation = min(0.68, max(0.2, saturation * 0.92))
        let adaptedBrightness = min(0.5, max(0.32, brightness * 0.72))
        return ReaderFloaterPalette(
            primary: UIColor(
                hue: hue,
                saturation: adaptedSaturation,
                brightness: min(0.54, adaptedBrightness + 0.045),
                alpha: 0.96
            ),
            secondary: UIColor(
                hue: hue,
                saturation: min(0.72, adaptedSaturation + 0.05),
                brightness: max(0.27, adaptedBrightness - 0.055),
                alpha: 0.96
            )
        )
    }

    private static let fallback = ReaderFloaterPalette(
        primary: UIColor(red: 0.32, green: 0.36, blue: 0.39, alpha: 0.96),
        secondary: UIColor(red: 0.22, green: 0.25, blue: 0.28, alpha: 0.96)
    )
}

private final class ReaderFloaterPaletteBox: NSObject {
    let palette: ReaderFloaterPalette
    init(_ palette: ReaderFloaterPalette) { self.palette = palette }
}

private struct PaginationLayout: Hashable {
    let bookID: UUID
    let width: Int
    let height: Int
    let fontSize: Int
    let lineSpacing: Int
    let margin: Int
    let fontName: String
}

private struct ChromeAction: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ReaderBackgroundSurface: View {
    let theme: ReaderTheme
    let style: ReaderBackgroundStyle
    let customImage: UIImage?
    let overlayOpacity: CGFloat
    let blur: ReaderCustomBackgroundBlur

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                theme.background
                if let image = artworkImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(blur == .none ? 1 : 1.04)
                        .blur(radius: blur.previewRadius, opaque: true)
                    theme.background.opacity(overlayOpacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private var artworkImage: UIImage? {
        if style == .custom { return customImage }
        return style.usesBundledArtwork ? UIImage(named: "ReaderInkWash") : nil
    }
}

private struct CustomBackgroundEditor: View {
    @Binding var image: UIImage?
    @Binding var toneRaw: String
    @Binding var blurRaw: String
    @Binding var transparency: Double
    let chapterTitle: String
    let excerpt: String
    let onImageChanged: () -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @State private var replacementPhoto: PhotosPickerItem?
    @State private var importError: String?

    private var tone: ReaderCustomBackgroundTone {
        ReaderCustomBackgroundTone(rawValue: toneRaw) ?? .light
    }

    private var blur: ReaderCustomBackgroundBlur {
        ReaderCustomBackgroundBlur(rawValue: blurRaw) ?? .none
    }

    private var paperOpacity: Double {
        min(0.85, max(0.25, 1 - transparency))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                preview
                    .padding(.horizontal, 14)
                    .padding(.top, 58)
                    .padding(.bottom, 18)
                Color.clear.frame(height: 292)
            }

            controls
        }
        .onChange(of: replacementPhoto) { _, item in
            importReplacement(item)
        }
        .alert(
            "背景导入失败",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "无法读取图片")
        }
    }

    private var preview: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(blur == .none ? 1 : 1.05)
                        .blur(radius: blur.previewRadius, opaque: true)
                } else {
                    Color(hex: "2A2A2A")
                }

                tone.overlayColor
                    .opacity(paperOpacity)
                    .frame(width: min(316, proxy.size.width * 0.58))

                VStack(alignment: .leading, spacing: 16) {
                    Text(chapterTitle)
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                    Text(excerpt)
                        .font(.system(size: 15, design: .serif))
                        .lineSpacing(8)
                        .lineLimit(10)
                }
                .foregroundStyle(tone.previewTextColor)
                .frame(width: min(260, proxy.size.width * 0.47), alignment: .leading)
                .padding(.vertical, 28)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private var controls: some View {
        VStack(spacing: 15) {
            HStack {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 40, height: 40)
                }
                Spacer()
                Text("自定义背景")
                    .font(.headline)
                Spacer()
                Button("确定", action: onConfirm)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 40, height: 40)
            }

            editorRow(title: "颜色") {
                Picker("颜色", selection: $toneRaw) {
                    ForEach(ReaderCustomBackgroundTone.allCases) { item in
                        Text(item.rawValue).tag(item.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            editorRow(title: "模糊") {
                Picker("模糊", selection: $blurRaw) {
                    ForEach(ReaderCustomBackgroundBlur.allCases) { item in
                        Text(item.rawValue).tag(item.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            editorRow(title: "透明") {
                Slider(value: $transparency, in: 0.15...0.75)
                    .tint(Color(hex: "8A795D"))
            }

            PhotosPicker(selection: $replacementPhoto, matching: .images) {
                Label("更换图片", systemImage: "photo.on.rectangle")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Color.black.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color(hex: "1F1F1F"))
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(
            Color(hex: "F7F6F3"),
            in: UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
        )
        .environment(\.colorScheme, .light)
    }

    private func editorRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline)
                .frame(width: 45, alignment: .leading)
            content()
        }
    }

    private func importReplacement(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            do {
                guard let sourceData = try await item.loadTransferable(type: Data.self) else {
                    throw ReaderCustomBackgroundError.unreadableImage
                }
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try ReaderCustomBackgroundStore.save(sourceData: sourceData)
                }.value
                image = UIImage(data: prepared)
                onImageChanged()
            } catch {
                importError = error.localizedDescription
            }
            replacementPhoto = nil
        }
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
