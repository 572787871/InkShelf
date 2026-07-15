import SwiftUI
import UIKit

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
    @State private var showingVoiceInfo = false
    @State private var scrubbedWholeBookChapterIndex: Double?
    @State private var isScrubbingWholeBookProgress = false
    @State private var brightness = Double(UIScreen.main.brightness)
    @State private var originalBrightness = UIScreen.main.brightness

    @AppStorage("readerTheme") private var themeRaw = ReaderTheme.paper.rawValue
    @AppStorage("readerDayTheme") private var dayThemeRaw = ReaderTheme.paper.rawValue
    @AppStorage("readerBackground") private var backgroundRaw = ReaderBackgroundStyle.plain.rawValue
    @AppStorage("readerFont") private var fontRaw = ReaderFont.system.rawValue
    @AppStorage("pageTurnStyle") private var turnRaw = PageTurnStyle.curl.rawValue
    @AppStorage("readerFontSize") private var fontSize = 19.0
    @AppStorage("readerLineSpacing") private var lineSpacing = 9.0
    @AppStorage("readerMargin") private var margin = 22.0
    @AppStorage("keepScreenAwake") private var keepScreenAwake = true

    private var book: NovelBook? { library.book(id: bookID) }
    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .paper }
    private var backgroundStyle: ReaderBackgroundStyle {
        ReaderBackgroundStyle(rawValue: backgroundRaw) ?? .plain
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
                        ReaderBackgroundSurface(theme: theme, style: backgroundStyle)
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
                                onCommit: commit,
                                onCenterTap: { withAnimation(.easeOut(duration: 0.18)) { chromeVisible.toggle() } }
                            )
                            .ignoresSafeArea()
                        }
                        if chromeVisible { readerChrome(book: book) }
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
        }
        .onChange(of: showingAppearance) { _, _ in reportBlockingState() }
        .onChange(of: showingIndex) { _, _ in reportBlockingState() }
        .onChange(of: showingNote) { _, _ in reportBlockingState() }
        .onChange(of: showingVoiceInfo) { _, _ in reportBlockingState() }
        .onChange(of: isScrubbingWholeBookProgress) { _, _ in reportBlockingState() }
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
        .alert("AI 朗读已预留", isPresented: $showingVoiceInfo) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("配音服务尚未接入。播放状态、章节预处理、句子定位和断点续播接口已准备好。")
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
            themeID: "\(theme.rawValue)|\(backgroundStyle.rawValue)",
            bookTitle: bookTitle,
            backgroundColor: UIColor(theme.background),
            backsideColor: UIColor(theme.pageBack),
            textColor: UIColor(theme.foreground),
            backgroundStyle: backgroundStyle,
            fontName: readerFont.name,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            horizontalMargin: margin,
            highlightedLocation: nil,
            highlightedRange: nil
        )
    }

    private func paginationLayout(for book: NovelBook, size: CGSize) -> PaginationLayout {
        PaginationLayout(
            bookID: book.id,
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded()),
            fontSize: Int((fontSize * 10).rounded()),
            lineSpacing: Int((lineSpacing * 10).rounded()),
            margin: Int((margin * 10).rounded())
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
        location = settledLocation
        persist(settledLocation)
        // Audio playback and sentence highlighting remain owned by the reading
        // session. They are notified only after a visual page turn settles.
    }

    private func jump(to requestedLocation: ReaderPageLocation) {
        let settled = catalog.nearest(to: requestedLocation) ?? requestedLocation
        location = settled
        persist(settled)
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
                || showingVoiceInfo
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
                    ChromeAction(icon: "waveform", label: "朗读") { showingVoiceInfo = true }
                    ChromeAction(
                        icon: showingAppearance ? "chevron.down.circle.fill" : "paintpalette",
                        label: showingAppearance ? "收起" : "背景"
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

            HStack(spacing: 9) {
                Text("背景")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)
                ForEach(ReaderBackgroundStyle.allCases) { style in
                    Button { backgroundRaw = style.rawValue } label: {
                        ReaderBackgroundSurface(theme: theme, style: style)
                            .frame(width: 48, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(
                                        backgroundStyle == style ? theme.foreground.opacity(0.82) : .gray.opacity(0.24),
                                        lineWidth: backgroundStyle == style ? 2 : 1
                                    )
                            }
                            .overlay {
                                Image(systemName: style.symbolName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(theme.foreground.opacity(0.56))
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
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
                    ForEach(ReaderFont.allCases) { Text($0.rawValue).tag($0.rawValue) }
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
            if theme == .night {
                let restored = ReaderTheme(rawValue: dayThemeRaw) ?? .paper
                themeRaw = restored == .night ? ReaderTheme.paper.rawValue : restored.rawValue
            } else {
                dayThemeRaw = theme.rawValue
                themeRaw = ReaderTheme.night.rawValue
            }
        }
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

private struct PaginationLayout: Hashable {
    let bookID: UUID
    let width: Int
    let height: Int
    let fontSize: Int
    let lineSpacing: Int
    let margin: Int
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

    var body: some View {
        ZStack {
            theme.background
            switch style {
            case .plain:
                Color.clear
            case .warmGlow:
                RadialGradient(
                    colors: [Color(hex: "F5C879").opacity(theme == .night ? 0.08 : 0.2), .clear],
                    center: .topTrailing,
                    startRadius: 8,
                    endRadius: 310
                )
            case .ricePaper, .bamboo, .mist:
                ReaderBackgroundPattern(theme: theme, style: style)
            }
        }
        .clipped()
    }
}

private struct ReaderBackgroundPattern: View {
    let theme: ReaderTheme
    let style: ReaderBackgroundStyle

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let ink = theme.foreground
            switch style {
            case .ricePaper:
                for index in 0..<22 {
                    let y = size.height * CGFloat(index + 1) / 23
                    var fiber = Path()
                    fiber.move(to: CGPoint(x: 0, y: y))
                    for step in 1...12 {
                        let x = size.width * CGFloat(step) / 12
                        fiber.addLine(to: CGPoint(
                            x: x,
                            y: y + sin(CGFloat(step * 3 + index) * 0.61) * 0.8
                        ))
                    }
                    context.stroke(fiber, with: .color(ink.opacity(index.isMultiple(of: 4) ? 0.04 : 0.018)), lineWidth: 0.45)
                }
            case .bamboo:
                for stalk in 0..<3 {
                    let x = size.width * (0.72 + CGFloat(stalk) * 0.105)
                    var stem = Path()
                    stem.move(to: CGPoint(x: x, y: -8))
                    stem.addCurve(
                        to: CGPoint(x: x - size.width * 0.09, y: size.height * 0.52),
                        control1: CGPoint(x: x + 8, y: size.height * 0.16),
                        control2: CGPoint(x: x - 12, y: size.height * 0.34)
                    )
                    context.stroke(stem, with: .color(ink.opacity(0.07)), lineWidth: 2.2)
                    for leaf in 0..<4 {
                        let leafY = size.height * (0.1 + CGFloat(leaf) * 0.09 + CGFloat(stalk) * 0.025)
                        let leafRect = CGRect(x: x - 30 - CGFloat(leaf % 2) * 9, y: leafY, width: 38, height: 9)
                        context.fill(Path(ellipseIn: leafRect), with: .color(ink.opacity(0.045)))
                    }
                }
            case .mist:
                for ridge in 0..<4 {
                    let y = size.height * (0.73 + CGFloat(ridge) * 0.075)
                    var mountain = Path()
                    mountain.move(to: CGPoint(x: -20, y: y))
                    mountain.addCurve(
                        to: CGPoint(x: size.width + 20, y: y - 4),
                        control1: CGPoint(x: size.width * 0.23, y: y - 58 + CGFloat(ridge) * 7),
                        control2: CGPoint(x: size.width * 0.65, y: y + 24 - CGFloat(ridge) * 5)
                    )
                    context.stroke(mountain, with: .color(ink.opacity(0.025 + Double(ridge) * 0.012)), lineWidth: 1.1)
                }
            case .plain, .warmGlow:
                break
            }
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
