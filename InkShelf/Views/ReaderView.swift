import SwiftUI
import UIKit
import PhotosUI
import CoreImage

struct ReaderView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var readAloud: ReadAloudService
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let preferredInitialLocation: ReaderPageLocation?
    let interactionDisabled: Bool
    let onRequestClose: (() -> Void)?
    let onReady: () -> Void
    let onBlockingStateChanged: (Bool) -> Void

    @State private var location = ReaderPageLocation(chapterIndex: 0, pageIndex: 0)
    @State private var catalog = ReaderPageCatalog.empty
    @State private var chromeVisible = false
    @State private var showingIndex = false
    @State private var showingAppearance = false
    @State private var showingReadAloudSettings = false
    @State private var showingNote = false
    @State private var readAloudError: String?
    @State private var automatedTurnTarget: ReaderPageLocation?
    @State private var isBrowsingAwayFromReadAloud = false
    @State private var hasResolvedInitialLocation = false
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
    private var isCurrentReadAloudSession: Bool { readAloud.isSession(for: bookID) }
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
        preferredInitialLocation: ReaderPageLocation? = nil,
        interactionDisabled: Bool = false,
        onRequestClose: (() -> Void)? = nil,
        onReady: @escaping () -> Void = { },
        onBlockingStateChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.bookID = bookID
        self.preferredInitialLocation = preferredInitialLocation
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
                    let layout = paginationLayout(
                        for: book,
                        size: proxy.size,
                        safeAreaInsets: proxy.safeAreaInsets
                    )
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
                        if chromeVisible,
                           !showingAppearance,
                           isCurrentReadAloudSession {
                            readAloudFloater(book: book)
                        } else if !chromeVisible, isCurrentReadAloudSession {
                            immersiveReadAloudBar
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: chromeVisible)
                    .task(id: layout) {
                        await rebuildCatalog(for: book, paginationLayout: layout.readerLayout)
                    }
                    .allowsHitTesting(!interactionDisabled)
                }
                .statusBarHidden(!chromeVisible)
            } else {
                ContentUnavailableView("书籍不存在", systemImage: "book.closed")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            readAloud.readerDidAppear(bookID: bookID)
            if let book {
                if !hasResolvedInitialLocation,
                   let playingLocation = openingReadAloudLocation {
                    location = playingLocation
                    isBrowsingAwayFromReadAloud = false
                    attachPageFinishHandler()
                } else if !hasResolvedInitialLocation {
                    location = ReaderPageLocation(
                        chapterIndex: min(book.currentChapter, max(book.chapters.count - 1, 0)),
                        pageIndex: max(0, book.currentPage)
                    )
                }
            }
            originalBrightness = UIScreen.main.brightness
            UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
            reportBlockingState()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            UIScreen.main.brightness = originalBrightness
            readAloud.readerDidDisappear(bookID: bookID)
        }
        .onChange(of: showingAppearance) { _, _ in reportBlockingState() }
        .onChange(of: showingReadAloudSettings) { _, _ in reportBlockingState() }
        .onChange(of: keepScreenAwake) { _, enabled in
            UIApplication.shared.isIdleTimerDisabled = enabled
        }
        .onChange(of: showingIndex) { _, _ in reportBlockingState() }
        .onChange(of: showingNote) { _, _ in reportBlockingState() }
        .onChange(of: readAloud.state) { _, state in
            if case let .failed(message) = state { readAloudError = message }
            if !readAloud.hasSession { isBrowsingAwayFromReadAloud = false }
        }
        .onChange(of: readAloud.currentPageLocation) { _, playingLocation in
            guard isCurrentReadAloudSession,
                  let playingLocation else { return }
            if isBrowsingAwayFromReadAloud {
                if playingLocation == location { isBrowsingAwayFromReadAloud = false }
                return
            }
            guard playingLocation != location, automatedTurnTarget == nil else { return }
            location = catalog.nearest(to: playingLocation) ?? playingLocation
            persist(location)
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
        .sheet(isPresented: $showingReadAloudSettings) {
            ReadAloudSettingsSheet(onStart: startReadingFromSettings)
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

    private var pageTurnMode: InteractivePageTurnMode {
        switch turnStyle {
        case .curl: return .curl
        case .slide: return .cover
        case .none: return .immediate
        case .vertical: return .cover
        }
    }

    private func pageAppearance(bookTitle: String) -> ReaderPageAppearance {
        let ownsReadAloudSession = isCurrentReadAloudSession
        return ReaderPageAppearance(
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
            highlightedLocation: ownsReadAloudSession ? readAloud.currentPageLocation : nil,
            highlightedRange: ownsReadAloudSession ? readAloud.currentSentenceRange : nil,
            showsReadAloudControls: ownsReadAloudSession,
            isReadAloudPlaying: ownsReadAloudSession && readAloud.isPlaying
        )
    }

    private func paginationLayout(
        for book: NovelBook,
        size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> PaginationLayout {
        let headerY = max(16, safeAreaInsets.top + 12)
        let footerY = size.height - max(28, safeAreaInsets.bottom + 18)
        let textSize = CGSize(
            width: max(1, size.width - margin * 2),
            height: max(1, footerY - headerY - 64)
        )
        return PaginationLayout(
            bookID: book.id,
            readerLayout: ReaderPaginationLayout(
                textWidth: textSize.width,
                textHeight: textSize.height,
                fontName: readerFont.name,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                paragraphFirstLineIndent: 26
            )
        )
    }

    private func rebuildCatalog(
        for book: NovelBook,
        paginationLayout: ReaderPaginationLayout
    ) async {
        let rebuilt = await Task.detached(priority: .userInitiated) {
            ReaderPageCatalog(book: book, paginationLayout: paginationLayout)
        }.value
        guard !Task.isCancelled else { return }
        let openingNarrationLocation: ReaderPageLocation?
        if !hasResolvedInitialLocation {
            openingNarrationLocation = openingReadAloudLocation
        } else {
            openingNarrationLocation = nil
        }
        let requestedLocation = openingNarrationLocation ?? location
        guard let settledLocation = rebuilt.nearest(to: requestedLocation) else { return }
        if settledLocation != location {
            location = settledLocation
            persist(settledLocation)
        }
        if openingNarrationLocation != nil {
            isBrowsingAwayFromReadAloud = false
            attachPageFinishHandler()
        }
        hasResolvedInitialLocation = true
        catalog = rebuilt
        readAloud.refreshSessionPages(rebuilt.pages, for: book.id)
        onReady()
    }

    private var openingReadAloudLocation: ReaderPageLocation? {
        guard isCurrentReadAloudSession else { return nil }
        return readAloud.currentPageLocation ?? preferredInitialLocation
    }

    private func commit(_ settledLocation: ReaderPageLocation) {
        let isAutomatedTurn = automatedTurnTarget == settledLocation
        let shouldContinuePlaying = readAloud.isPlaying || isAutomatedTurn
        let hadReadAloudSession = isCurrentReadAloudSession
        automatedTurnTarget = nil
        if settledLocation != location {
            location = settledLocation
            persist(settledLocation)
        }
        guard hadReadAloudSession else { return }
        if isAutomatedTurn {
            isBrowsingAwayFromReadAloud = false
            if readAloud.currentPageLocation != settledLocation {
                readAloud.moveSession(to: settledLocation, continuePlaying: shouldContinuePlaying)
            }
        } else {
            isBrowsingAwayFromReadAloud = readAloud.currentPageLocation != settledLocation
        }
    }

    private func jump(to requestedLocation: ReaderPageLocation) {
        let settled = catalog.nearest(to: requestedLocation) ?? requestedLocation
        if settled != location {
            location = settled
            persist(settled)
        }
        if isCurrentReadAloudSession {
            isBrowsingAwayFromReadAloud = readAloud.currentPageLocation != settled
        }
    }

    private func startReadingCurrentPage() {
        guard let book, let page = catalog.page(at: location) else {
            readAloudError = "当前页面尚未加载完成"
            return
        }
        beginReading(book: book, page: page, paragraphLocation: nil)
    }

    private func startReadingFromSettings() {
        showingReadAloudSettings = false
        showingAppearance = false
        chromeVisible = false
        startReadingCurrentPage()
    }

    private func playParagraph(_ page: ReaderPage, range: NSRange) {
        if isCurrentReadAloudSession,
           readAloud.currentPageLocation == page.location,
           let highlightedRange = readAloud.currentSentenceRange,
           NSIntersectionRange(highlightedRange, range).length > 0 {
            readAloud.togglePlayback()
            return
        }
        if page.location != location { jump(to: page.location) }
        guard let book else { return }
        beginReading(book: book, page: page, paragraphLocation: range.location)
    }

    private func beginReading(book: NovelBook, page: ReaderPage, paragraphLocation: Int?) {
        isBrowsingAwayFromReadAloud = false
        attachPageFinishHandler()
        readAloud.startSession(
            book: book,
            pages: catalog.pages,
            location: page.location,
            startAtUTF16Location: paragraphLocation ?? 0
        )
    }

    private func attachPageFinishHandler() {
        readAloud.onPageFinished = { [weak readAloud] in
            guard readAloud != nil else { return }
            Task { @MainActor in autoAdvanceReadAloud() }
        }
    }

    private func autoAdvanceReadAloud() {
        guard readAloud.currentPageLocation == location else {
            readAloud.continueAfterPageFinishedWithoutTurningReader()
            return
        }
        guard let nextPage = catalog.adjacent(to: location, direction: .forward) else {
            readAloud.finishAtEndOfBook()
            return
        }
        let shouldContinuePlaying = readAloud.isPlaying
        automatedTurnTarget = nextPage.location
        // Speech owns its own page progression. Do not make the next
        // utterance wait for UIKit's visual page-turn completion callback.
        readAloud.advanceSession(
            to: nextPage.location,
            continuePlaying: shouldContinuePlaying
        )
        if turnStyle == .vertical {
            commit(nextPage.location)
        } else {
            scheduleAutomatedTurnFallback(to: nextPage.location)
        }
    }

    private func scheduleAutomatedTurnFallback(to target: ReaderPageLocation) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            guard automatedTurnTarget == target else { return }
            // Programmatic UIPageViewController animations can occasionally
            // finish without a completion callback. Commit only after the
            // normal animation window has elapsed so narration never stalls.
            commit(target)
        }
    }

    private func returnToCurrentReadAloudProgress() {
        guard let playingLocation = readAloud.currentPageLocation else { return }
        automatedTurnTarget = nil
        isBrowsingAwayFromReadAloud = false
        let settledLocation = catalog.nearest(to: playingLocation) ?? playingLocation
        if settledLocation != location {
            location = settledLocation
            persist(settledLocation)
        }
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
                || showingReadAloudSettings
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
            HStack(spacing: 0) {
                Button { requestClose() } label: {
                    ZStack(alignment: .leading) {
                        Color.clear
                        Image(systemName: "chevron.left")
                            .padding(.leading, 8)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(safeChapter(in: book).title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.leading, 4)
                Spacer()
                HStack(spacing: 18) {
                    Button { toggleBookmark(book: book) } label: { Image(systemName: isBookmarked(book) ? "bookmark.fill" : "bookmark") }
                    Button { showingNote = true } label: { Image(systemName: "square.and.pencil") }
                }
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
                        showingReadAloudSettings = true
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
            onCoverTap: nil,
            onPlayPause: readAloud.togglePlayback,
            onClose: {
                readAloud.stop()
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
                Button(action: returnToCurrentReadAloudProgress) {
                    Label("原进度", systemImage: "arrow.uturn.backward")
                }

                Rectangle()
                    .fill(immersiveBarForeground.opacity(0.32))
                    .frame(width: 1, height: 15)

                Button(action: startReadingCurrentPage) {
                    Label("从本页听", systemImage: "headphones")
                }
            }
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .buttonStyle(.plain)
            .foregroundStyle(immersiveBarForeground)
            .padding(.horizontal, 15)
            .frame(height: 38)
            .background(immersiveBarBackground, in: Capsule())
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .padding(.bottom, 38)
        }
        .allowsHitTesting(true)
        .transition(.opacity)
    }

    private var immersiveBarBackground: Color {
        theme.foreground.opacity(theme == .night ? 0.16 : 0.58)
    }

    private var immersiveBarForeground: Color {
        theme == .night ? theme.foreground : theme.background
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
        VStack(spacing: 12) {
            HStack {
                Label("阅读外观", systemImage: "textformat")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("排版复位") {
                    fontRaw = ReaderFont.system.rawValue
                    fontSize = 19
                    lineSpacing = 9
                    margin = 22
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            appearanceCard {
                VStack(spacing: 12) {
                    HStack(spacing: 13) {
                        appearanceRowLabel("颜色", icon: "circle.lefthalf.filled")
                        ForEach(ReaderTheme.allCases) { item in
                            Button {
                                themeRaw = item.rawValue
                                if item != .night { dayThemeRaw = item.rawValue }
                            } label: {
                                Circle()
                                    .fill(item.background)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Circle().stroke(
                                            themeRaw == item.rawValue
                                                ? theme.foreground.opacity(0.86)
                                                : .gray.opacity(0.24),
                                            lineWidth: themeRaw == item.rawValue ? 2.5 : 1
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
                        Spacer(minLength: 0)
                    }

                    HStack(alignment: .top, spacing: 10) {
                        appearanceRowLabel("背景", icon: "photo.on.rectangle")
                            .padding(.top, 8)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 9) {
                                ForEach(ReaderBackgroundStyle.allCases) { style in
                                    Button {
                                        selectBackground(style)
                                    } label: {
                                        VStack(spacing: 4) {
                                            ReaderBackgroundSurface(
                                                theme: style.recommendedTheme ?? theme,
                                                style: style,
                                                customImage: customBackgroundImage,
                                                overlayOpacity: style == .custom
                                                    ? CGFloat(1 - customTransparency)
                                                    : style.readabilityOverlayOpacity,
                                                blur: style == .custom ? customBlur : .none
                                            )
                                            .frame(width: 48, height: 34)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(
                                                        backgroundStyle == style
                                                            ? theme.foreground.opacity(0.86)
                                                            : .gray.opacity(0.2),
                                                        lineWidth: backgroundStyle == style ? 2.5 : 1
                                                    )
                                            }
                                            .overlay {
                                                if style == .custom {
                                                    Image(systemName: style.symbolName)
                                                        .font(.system(size: 11, weight: .semibold))
                                                        .foregroundStyle(theme.foreground.opacity(0.72))
                                                        .frame(width: 22, height: 22)
                                                        .background(.ultraThinMaterial, in: Circle())
                                                }
                                            }
                                            Text(style.rawValue)
                                                .font(.system(size: 9, weight: backgroundStyle == style ? .semibold : .regular))
                                                .lineLimit(1)
                                                .foregroundStyle(backgroundStyle == style ? .primary : .secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }

            appearanceCard {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "sun.min")
                            .foregroundStyle(.secondary)
                        Slider(value: $brightness, in: 0.05...1) { _ in
                            UIScreen.main.brightness = brightness
                        }
                        .tint(theme.foreground.opacity(0.72))
                        Image(systemName: "sun.max.fill")
                            .foregroundStyle(.secondary)
                    }

                    Divider().opacity(0.35)

                    HStack(spacing: 10) {
                        appearanceRowLabel("字号", icon: "textformat.size")
                        HStack(spacing: 0) {
                            Button { fontSize = max(14, fontSize - 1) } label: {
                                Image(systemName: "minus")
                                    .frame(width: 32, height: 30)
                            }
                            Text("\(Int(fontSize))")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .frame(width: 38)
                            Button { fontSize = min(32, fontSize + 1) } label: {
                                Image(systemName: "plus")
                                    .frame(width: 32, height: 30)
                            }
                        }
                        .buttonStyle(.plain)
                        .background(Color.primary.opacity(0.06), in: Capsule())

                        Spacer()

                        Menu {
                            Picker("字体", selection: $fontRaw) {
                                ForEach(ReaderFont.allCases) {
                                    Text($0.displayName).tag($0.rawValue)
                                }
                            }
                        } label: {
                            Label(readerFont.displayName, systemImage: "character.cursor.ibeam")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 11)
                                .frame(height: 30)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }

                    appearanceSliderRow(
                        title: "行距",
                        value: lineSpacingDescription,
                        icon: "line.3.horizontal",
                        valueBinding: $lineSpacing,
                        range: 4...20,
                        step: 1
                    )

                    HStack(spacing: 6) {
                        ForEach(lineSpacingPresets, id: \.value) { preset in
                            Button {
                                withAnimation(.easeOut(duration: 0.16)) {
                                    lineSpacing = preset.value
                                }
                            } label: {
                                Text(preset.label)
                                    .font(.caption2.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 26)
                                    .foregroundStyle(
                                        abs(lineSpacing - preset.value) < 0.5
                                            ? theme.background
                                            : Color.secondary
                                    )
                                    .background(
                                        abs(lineSpacing - preset.value) < 0.5
                                            ? theme.foreground.opacity(0.78)
                                            : Color.primary.opacity(0.045),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    appearanceSliderRow(
                        title: "页边距",
                        value: "\(Int(margin)) pt",
                        icon: "arrow.left.and.right",
                        valueBinding: $margin,
                        range: 14...40,
                        step: 2
                    )
                }
            }

            HStack(spacing: 9) {
                Menu {
                    Picker("翻页方式", selection: $turnRaw) {
                        ForEach(PageTurnStyle.allCases) {
                            Text($0.rawValue).tag($0.rawValue)
                        }
                    }
                } label: {
                    Label("\(turnStyle.rawValue)翻页", systemImage: "book.pages")
                        .readerSettingChip()
                }

                Button {
                    keepScreenAwake.toggle()
                } label: {
                    Label(
                        keepScreenAwake ? "屏幕常亮" : "自动息屏",
                        systemImage: keepScreenAwake ? "sun.max.fill" : "sun.max"
                    )
                    .readerSettingChip(isSelected: keepScreenAwake)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("阅读时屏幕常亮")
                .accessibilityValue(keepScreenAwake ? "已开启" : "已关闭")

                Spacer(minLength: 0)
            }
        }
        .font(.caption)
    }

    private var lineSpacingPresets: [(label: String, value: Double)] {
        [("紧凑", 5), ("标准", 9), ("舒适", 13), ("宽松", 17)]
    }

    private var lineSpacingDescription: String {
        let nearest = lineSpacingPresets.min { abs($0.value - lineSpacing) < abs($1.value - lineSpacing) }
        let label = nearest.map { abs($0.value - lineSpacing) < 0.5 ? $0.label : "自定" } ?? "自定"
        return "\(label) · \(Int(lineSpacing)) pt"
    }

    private func appearanceRowLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 58, alignment: .leading)
    }

    private func appearanceCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
    }

    private func appearanceSliderRow(
        title: String,
        value: String,
        icon: String,
        valueBinding: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(spacing: 5) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(value)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: valueBinding, in: range, step: step)
                .tint(theme.foreground.opacity(0.72))
        }
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

struct ReaderReadAloudFloater: View {
    @ObservedObject var readAloud: ReadAloudService
    let bookID: UUID
    let bookTitle: String
    let coverImage: UIImage?
    let coverSignature: String
    let onCoverTap: (() -> Void)?
    let onPlayPause: () -> Void
    let onClose: () -> Void

    @State private var settledOffset = CGSize.zero
    @State private var settledCoverRotation = 0.0
    @State private var coverRotationStartedAt: Date?
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
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !readAloud.isPlaying)) { timeline in
                Group {
                    if let onCoverTap {
                        Button(action: onCoverTap) {
                            rotatingCover(at: timeline.date)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .accessibilityLabel("打开正在朗读的《\(bookTitle)》")
                    } else {
                        rotatingCover(at: timeline.date)
                    }
                }
            }
            .frame(width: 44, height: 44)

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
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
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
            DragGesture(minimumDistance: 12)
                .updating($dragOffset) { value, state, _ in state = value.translation }
                .onEnded { value in
                    settledOffset.width += value.translation.width
                    settledOffset.height += value.translation.height
                }
        )
        .onAppear { updateCoverRotation(isPlaying: readAloud.isPlaying) }
        .onChange(of: readAloud.isPlaying) { _, isPlaying in
            updateCoverRotation(isPlaying: isPlaying)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("朗读悬浮控制")
    }

    private func rotatingCover(at date: Date) -> some View {
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
        .rotationEffect(.degrees(coverRotation(at: date)))
    }

    private func coverRotation(at date: Date) -> Double {
        guard let coverRotationStartedAt else { return settledCoverRotation }
        return settledCoverRotation + date.timeIntervalSince(coverRotationStartedAt) * 45
    }

    private func updateCoverRotation(isPlaying: Bool) {
        if isPlaying {
            if coverRotationStartedAt == nil { coverRotationStartedAt = .now }
        } else if let coverRotationStartedAt {
            settledCoverRotation = coverRotation(at: .now).truncatingRemainder(dividingBy: 360)
            self.coverRotationStartedAt = nil
        }
    }
}

struct PersistentReadAloudOverlay: View {
    @ObservedObject var readAloud: ReadAloudService
    var onOpenBook: ((UUID) -> Void)?
    var bottomPadding: CGFloat = 22
    var forceVisible = false

    @ViewBuilder
    var body: some View {
        if (forceVisible || readAloud.shouldShowPersistentFloater),
           readAloud.hasSession,
           let context = readAloud.bookContext {
            let defaultCoverName = BookPalette.defaultCoverAssetName(for: context.coverStyle)
            let customCoverImage = context.coverData.flatMap { UIImage(data: $0) }
            let coverImage = customCoverImage ?? UIImage(named: defaultCoverName)
            let coverSignature = context.coverData.map { "custom-\($0.hashValue)" }
                ?? "asset-\(defaultCoverName)"
            let coverAction: (() -> Void)? = onOpenBook.map { action in
                { action(context.id) }
            }
            ReaderReadAloudFloater(
                readAloud: readAloud,
                bookID: context.id,
                bookTitle: context.title,
                coverImage: coverImage,
                coverSignature: coverSignature,
                onCoverTap: coverAction,
                onPlayPause: readAloud.togglePlayback,
                onClose: { readAloud.stop() }
            )
            .padding(.leading, 18)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .transition(.scale(scale: 0.92, anchor: .bottomLeading).combined(with: .opacity))
            .zIndex(100)
        }
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
    let readerLayout: ReaderPaginationLayout
}

private extension View {
    func readerSettingChip(isSelected: Bool = false) -> some View {
        self
            .font(.caption.weight(.medium))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                Color.primary.opacity(isSelected ? 0.11 : 0.05),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(Color.primary.opacity(isSelected ? 0.12 : 0.06), lineWidth: 0.5)
            }
    }
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
