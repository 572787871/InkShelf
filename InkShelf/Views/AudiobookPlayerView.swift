import SwiftUI

struct AudiobookPlayerView: View {
    @EnvironmentObject private var readAloud: ReadAloudService
    @Environment(\.dismiss) private var dismiss

    let book: NovelBook

    @State private var isScrubbing = false
    @State private var scrubbedTime = 0.0
    @State private var isManuallyScrolling = false
    @State private var manualScrollToken = UUID()
    @State private var showingDirectory = false
    @State private var showingOptions = false

    private let speedOptions = [0.75, 1.0, 1.2, 1.5, 2.0]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "507D86"), Color(hex: "31565F")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                bookHeader
                transcript
                controls
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .sheet(isPresented: $showingDirectory) {
            AudiobookDirectorySheet(book: book)
                .environmentObject(readAloud)
        }
        .sheet(isPresented: $showingOptions) {
            AudiobookOptionsSheet()
                .environmentObject(readAloud)
        }
    }

    private var header: some View {
        HStack {
            Button(action: dismiss.callAsFunction) {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(InkShelfPressFeedbackStyle())
            Spacer()
            Text("听书")
                .font(.headline)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var bookHeader: some View {
        HStack(spacing: 14) {
            BookCoverView(book: book, compact: true)
                .frame(width: 54, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(readAloud.currentChapterTitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                if case let .failed(message) = readAloud.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Color.orange.opacity(0.95))
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(readAloud.currentChapterTranscript) { segment in
                        Text(segment.text)
                            .font(.system(size: 21, weight: segment.id == readAloud.currentTranscriptSegmentID ? .semibold : .regular))
                            .foregroundStyle(
                                segment.id == readAloud.currentTranscriptSegmentID
                                    ? Color.white
                                    : Color.white.opacity(0.62)
                            )
                            .lineSpacing(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(segment.id)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 30)
            }
            .scrollIndicators(.hidden)
            .contentMargins(.bottom, 42, for: .scrollContent)
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in isManuallyScrolling = true }
                    .onEnded { _ in resumeAutomaticScrollingLater(using: proxy) }
            )
            .onAppear { scrollToCurrent(using: proxy, animated: false) }
            .onChange(of: readAloud.currentTranscriptSegmentID) { _, _ in
                guard !isManuallyScrolling else { return }
                scrollToCurrent(using: proxy, animated: true)
            }
        }
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.06))
    }

    private var controls: some View {
        VStack(spacing: 20) {
            HStack {
                Menu {
                    ForEach(speedOptions, id: \.self) { speed in
                        Button(speedTitle(speed)) { readAloud.setPlaybackRate(speed) }
                    }
                } label: {
                    Label(speedTitle(readAloud.settings.rateMultiplier), systemImage: "gauge.with.dots.needle.33percent")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text(readAloud.isPlaying ? "正在播放" : "已暂停")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }

            HStack(spacing: 12) {
                Button { showingDirectory = true } label: {
                    Label("小说目录", systemImage: "list.bullet")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(InkShelfPressFeedbackStyle())
                Button { showingOptions = true } label: {
                    Label("朗读选项", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(InkShelfPressFeedbackStyle())
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.82))

            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let elapsed = isScrubbing ? scrubbedTime : readAloud.currentChapterElapsedTime
                VStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { isScrubbing ? scrubbedTime : elapsed },
                            set: { scrubbedTime = $0 }
                        ),
                        in: 0...max(1, readAloud.currentChapterDuration),
                        onEditingChanged: handleScrubbing
                    )
                    .tint(.white)
                    HStack {
                        Text(timeText(elapsed))
                        Spacer()
                        Text("-" + timeText(max(0, readAloud.currentChapterDuration - elapsed)))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.68))
                }
            }

            HStack {
                chapterButton(
                    title: "上一章",
                    systemImage: "backward.end.fill",
                    enabled: readAloud.canSkipToPreviousChapter,
                    action: readAloud.skipToPreviousChapter
                )
                Spacer()
                Button(action: readAloud.togglePlayback) {
                    Image(systemName: readAloud.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .offset(x: readAloud.isPlaying ? 0 : 2)
                        .frame(width: 76, height: 76)
                        .foregroundStyle(Color(hex: "31565F"))
                        .background(.white, in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
                }
                .accessibilityLabel(readAloud.isPlaying ? "暂停" : "播放")
                .buttonStyle(InkShelfPressFeedbackStyle())
                Spacer()
                chapterButton(
                    title: "下一章",
                    systemImage: "forward.end.fill",
                    enabled: readAloud.canSkipToNextChapter,
                    action: readAloud.skipToNextChapter
                )
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
        .padding(.bottom, 24)
        .background(.ultraThinMaterial.opacity(0.42))
    }

    private func chapterButton(
        title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.title2)
                Text(title).font(.caption)
            }
            .frame(width: 68)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.32)
        .buttonStyle(InkShelfPressFeedbackStyle())
    }

    private func handleScrubbing(_ editing: Bool) {
        if editing {
            if !isScrubbing { scrubbedTime = readAloud.currentChapterElapsedTime }
            isScrubbing = true
        } else {
            isScrubbing = false
            readAloud.seekToChapterTime(scrubbedTime)
        }
    }

    private func scrollToCurrent(using proxy: ScrollViewProxy, animated: Bool) {
        guard let id = readAloud.currentTranscriptSegmentID else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func resumeAutomaticScrollingLater(using proxy: ScrollViewProxy) {
        let token = UUID()
        manualScrollToken = token
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard manualScrollToken == token else { return }
            isManuallyScrolling = false
            scrollToCurrent(using: proxy, animated: true)
        }
    }

    private func speedTitle(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))x" : "\(speed.formatted(.number.precision(.fractionLength(1))))x"
    }

    private func timeText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct AudiobookDirectorySheet: View {
    @EnvironmentObject private var readAloud: ReadAloudService
    @Environment(\.dismiss) private var dismiss
    let book: NovelBook

    var body: some View {
        NavigationStack {
            List(book.chapters) { chapter in
                Button {
                    readAloud.playChapter(at: chapter.index)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chapter.title)
                                .foregroundStyle(.primary)
                            if chapter.index == readAloud.currentPageLocation?.chapterIndex {
                                Text("正在收听")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                            }
                        }
                        Spacer()
                        if chapter.index == readAloud.currentPageLocation?.chapterIndex {
                            Image(systemName: "waveform")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle("小说目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct AudiobookOptionsSheet: View {
    @EnvironmentObject private var readAloud: ReadAloudService
    @Environment(\.dismiss) private var dismiss

    private let speeds = [0.75, 1.0, 1.2, 1.5, 2.0]

    var body: some View {
        NavigationStack {
            Form {
                Section("播放速度") {
                    Picker("倍速", selection: Binding(
                        get: { readAloud.settings.rateMultiplier },
                        set: readAloud.setPlaybackRate
                    )) {
                        ForEach(speeds, id: \.self) { speed in
                            Text(speed == speed.rounded() ? "\(Int(speed))x" : "\(speed)x")
                                .tag(speed)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("连续播放") {
                    Label("已启用滚动预生成和后台连续音频", systemImage: "waveform.path.ecg")
                    Text("App 会提前生成后续语音块并写入本地缓存；首次遇到尚未缓存的内容时，生成速度仍取决于 iPhone 性能。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("朗读选项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
