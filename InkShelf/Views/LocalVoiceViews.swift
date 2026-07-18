import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ImportedVoiceSource: Identifiable, Equatable {
    let id = UUID()
    let stagedURL: URL
    let originalFilename: String
}

struct LocalVoiceDocumentPicker: UIViewControllerRepresentable {
    let onCompletion: (Result<ImportedVoiceSource, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCompletion: onCompletion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types = ["wav", "m4a", "mp3", "aac", "caf"].compactMap(UTType.init(filenameExtension:))
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onCompletion: (Result<ImportedVoiceSource, Error>) -> Void

        init(onCompletion: @escaping (Result<ImportedVoiceSource, Error>) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let sourceURL = urls.first else {
                onCompletion(.failure(LocalVoiceError.inaccessibleAudio))
                return
            }
            let originalFilename = sourceURL.lastPathComponent
            Task.detached(priority: .userInitiated) { [onCompletion] in
                let didAccess = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
                }
                do {
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("InkShelfVoiceImports", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let pathExtension = sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension.lowercased()
                    let stagedURL = directory
                        .appendingPathComponent("\(UUID().uuidString.lowercased()).\(pathExtension)")
                    var coordinationError: NSError?
                    var copyResult: Result<Void, Error>?
                    NSFileCoordinator().coordinate(
                        readingItemAt: sourceURL,
                        options: [],
                        error: &coordinationError
                    ) { readableURL in
                        copyResult = Result {
                            try FileManager.default.copyItem(at: readableURL, to: stagedURL)
                        }
                    }
                    if let coordinationError { throw coordinationError }
                    if let copyResult { try copyResult.get() }
                    guard FileManager.default.fileExists(atPath: stagedURL.path) else {
                        throw LocalVoiceError.inaccessibleAudio
                    }
                    let result = ImportedVoiceSource(
                        stagedURL: stagedURL,
                        originalFilename: originalFilename
                    )
                    await MainActor.run { onCompletion(.success(result)) }
                } catch {
                    await MainActor.run { onCompletion(.failure(error)) }
                }
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { }
    }
}

struct LocalVoiceRecordingView: View {
    static let referenceText = "窗外的风轻轻吹过树梢，远处的灯光渐渐亮了起来。今天，我想讲一个安静而温暖的故事。"

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var readAloud: ReadAloudService
    @StateObject private var recorder = LocalVoiceRecorder()
    @StateObject private var audioPlayer = LocalVoiceAudioPlayer()
    @State private var name = "我的声音"
    @State private var category = ZipVoiceProfileGender.unspecified
    @State private var processedAudio: ProcessedVoiceAudio?
    @State private var previewURL: URL?
    @State private var isSaving = false
    @State private var errorMessage: String?
    let onSaved: () -> Void

    var body: some View {
        Form {
            Section("音色资料") {
                TextField("音色名称", text: $name)
                Picker("声音类型", selection: $category) {
                    ForEach(ZipVoiceProfileGender.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
            }

            Section("固定朗读文案") {
                Text(Self.referenceText)
                    .font(.body)
                    .textSelection(.enabled)
                Label("推荐录制 5～10 秒，保持自然语速和稳定距离。", systemImage: "waveform")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("录音") {
                LabeledContent("时长", value: durationText(recorder.duration))
                HStack(spacing: 12) {
                    Text("音量")
                    ProgressView(value: recorder.level)
                        .tint(recorder.level > 0.88 ? .red : .accentColor)
                }
                recordingControls
                if let recordingURL = recorder.recordingURL,
                   recorder.state == .stopped || recorder.state == .paused {
                    Button {
                        play(url: recordingURL)
                    } label: {
                        Label(audioPlayer.isPlaying ? "停止播放原始录音" : "播放原始录音", systemImage: audioPlayer.isPlaying ? "stop.fill" : "play.fill")
                    }
                    Button(role: .destructive) {
                        audioPlayer.stop()
                        recorder.reset()
                        processedAudio = nil
                        previewURL = nil
                    } label: {
                        Label("重新录制", systemImage: "arrow.counterclockwise")
                    }
                }
                if case let .failed(message) = recorder.state {
                    Text(message).font(.footnote).foregroundStyle(.red)
                } else if recorder.state == .interrupted {
                    Text("录音已因电话、音频设备变化或 App 进入后台而暂停，返回后可继续。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            voiceQualitySection(processedAudio)

            Section("ZipVoice 模拟试听") {
                Text("试听文案：夜色渐深，他终于推开了那扇尘封多年的门。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                generationStatus
                Button(action: generatePreview) {
                    Label("生成模拟试听", systemImage: "waveform.badge.magnifyingglass")
                }
                .disabled(recorder.duration < 3 || recorder.recordingURL == nil || readAloud.localVoiceGenerationState.isWorking)
                if readAloud.localVoiceGenerationState.isWorking {
                    Button(role: .destructive, action: readAloud.cancelLocalVoiceGeneration) {
                        Label("取消生成", systemImage: "xmark.circle")
                    }
                }
                if let previewURL {
                    Button { play(url: previewURL) } label: {
                        Label(audioPlayer.isPlaying ? "停止试听" : "播放模拟试听", systemImage: audioPlayer.isPlaying ? "stop.fill" : "play.circle.fill")
                    }
                }
            }
        }
        .navigationTitle("录制我的声音")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消", action: dismiss.callAsFunction) }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save)
                    .disabled(previewURL == nil || processedAudio == nil || isSaving)
            }
        }
        .interactiveDismissDisabled(recorder.state == .recording || isSaving)
        .alert("创建模拟音色失败", isPresented: errorBinding) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .onDisappear {
            audioPlayer.stop()
            readAloud.cancelLocalVoiceGeneration()
            recorder.reset()
        }
    }

    @ViewBuilder
    private var recordingControls: some View {
        HStack(spacing: 12) {
            switch recorder.state {
            case .idle, .stopped, .failed:
                Button(action: recorder.requestPermissionAndStart) {
                    Label("开始录音", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
            case .recording:
                Button(action: recorder.pause) { Label("暂停", systemImage: "pause.fill") }
                    .buttonStyle(.bordered)
                Button(action: recorder.stop) { Label("停止", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent)
            case .paused, .interrupted:
                Button(action: recorder.startOrResume) { Label("继续", systemImage: "record.circle") }
                    .buttonStyle(.borderedProminent)
                Button(action: recorder.stop) { Label("停止", systemImage: "stop.fill") }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var generationStatus: some View {
        Group {
            if let title = readAloud.localVoiceGenerationState.title {
                HStack {
                    if readAloud.localVoiceGenerationState.isWorking { ProgressView().controlSize(.small) }
                    Text(title)
                        .font(.footnote)
                        .foregroundStyle(statusColor)
                }
            }
        }
    }

    private var statusColor: Color {
        if case .failed = readAloud.localVoiceGenerationState { return .red }
        if readAloud.localVoiceGenerationState == .completed { return .green }
        return .secondary
    }

    private func generatePreview() {
        guard let sourceURL = recorder.recordingURL else { return }
        if recorder.state == .recording { recorder.stop() }
        audioPlayer.stop()
        Task {
            do {
                let processed = try await readAloud.prepareLocalVoiceAudio(from: sourceURL)
                let preview = try await readAloud.generateLocalVoicePreview(
                    referenceURL: processed.referenceURL,
                    referenceText: Self.referenceText
                )
                processedAudio = processed
                previewURL = preview
                try audioPlayer.toggle(url: preview)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let sourceURL = recorder.recordingURL,
              let processedAudio,
              let previewURL else { return }
        isSaving = true
        Task {
            do {
                _ = try await readAloud.saveLocalVoiceProfile(
                    name: name,
                    sourceType: .recorded,
                    voiceCategory: category,
                    originalURL: sourceURL,
                    processedAudio: processedAudio,
                    referenceText: Self.referenceText,
                    previewURL: previewURL,
                    originalFilename: "App内录音.m4a",
                    isAuthorized: true
                )
                onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func play(url: URL) {
        do { try audioPlayer.toggle(url: url) }
        catch { errorMessage = error.localizedDescription }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

struct ImportedVoiceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var readAloud: ReadAloudService
    @StateObject private var audioPlayer = LocalVoiceAudioPlayer()
    @State private var metadata: VoiceAudioMetadata?
    @State private var name: String
    @State private var category = ZipVoiceProfileGender.unspecified
    @State private var referenceText = ""
    @State private var trimStart: TimeInterval = 0
    @State private var trimEnd: TimeInterval = 0
    @State private var processedAudio: ProcessedVoiceAudio?
    @State private var previewURL: URL?
    @State private var isSaving = false
    @State private var errorMessage: String?
    let source: ImportedVoiceSource
    let onSaved: () -> Void

    init(source: ImportedVoiceSource, onSaved: @escaping () -> Void) {
        self.source = source
        self.onSaved = onSaved
        _name = State(initialValue: URL(fileURLWithPath: source.originalFilename).deletingPathExtension().lastPathComponent)
    }

    var body: some View {
        Form {
            Section("音色资料") {
                TextField("音色名称", text: $name)
                Picker("声音类型", selection: $category) {
                    ForEach(ZipVoiceProfileGender.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
            }

            Section("导入文件") {
                if let metadata {
                    LabeledContent("文件名", value: metadata.filename)
                    LabeledContent("时长", value: durationText(metadata.duration))
                    LabeledContent("原始采样率", value: "\(Int(metadata.sampleRate.rounded())) Hz")
                    LabeledContent("声道", value: "\(metadata.channelCount)")
                    LabeledContent("文件大小", value: ByteCountFormatter.string(fromByteCount: metadata.fileSize, countStyle: .file))
                } else {
                    ProgressView("正在读取音频资料")
                }
                Button { play(url: source.stagedURL) } label: {
                    Label(audioPlayer.isPlaying ? "停止播放原音" : "播放原音", systemImage: audioPlayer.isPlaying ? "stop.fill" : "play.fill")
                }
            }

            if let metadata {
                Section("裁剪") {
                    LabeledContent("保留片段", value: "\(durationText(trimStart)) – \(durationText(trimEnd))")
                    VStack(alignment: .leading) {
                        Text("开始").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $trimStart, in: 0...max(0.01, metadata.duration - 3), step: 0.1)
                    }
                    VStack(alignment: .leading) {
                        Text("结束").font(.caption).foregroundStyle(.secondary)
                        Slider(
                            value: $trimEnd,
                            in: min(metadata.duration, trimStart + 3)...max(min(metadata.duration, trimStart + 3), min(metadata.duration, trimStart + 30)),
                            step: 0.1
                        )
                    }
                    if metadata.duration > AudioPreprocessor.maximumDuration {
                        Label("原音超过 30 秒，请选择最长 30 秒的清晰人声片段。", systemImage: "scissors")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                .onChange(of: trimStart) { _, newValue in
                    trimEnd = min(metadata.duration, max(newValue + 3, min(trimEnd, newValue + 30)))
                }
            }

            Section("参考文字") {
                TextEditor(text: $referenceText)
                    .frame(minHeight: 120)
                Text("请使用只有单人说话、无背景音乐、无混响的清晰录音。参考文字必须与录音内容一致。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            voiceQualitySection(processedAudio)

            Section("ZipVoice 模拟试听") {
                generationStatus
                Button(action: generatePreview) {
                    Label("生成试听", systemImage: "waveform.badge.magnifyingglass")
                }
                .disabled(metadata == nil || referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || readAloud.localVoiceGenerationState.isWorking)
                if readAloud.localVoiceGenerationState.isWorking {
                    Button(role: .destructive, action: readAloud.cancelLocalVoiceGeneration) {
                        Label("取消生成", systemImage: "xmark.circle")
                    }
                }
                if let previewURL {
                    Button { play(url: previewURL) } label: {
                        Label(audioPlayer.isPlaying ? "停止试听" : "播放模拟试听", systemImage: audioPlayer.isPlaying ? "stop.fill" : "play.circle.fill")
                    }
                }
            }
        }
        .navigationTitle("导入音频文件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消", action: dismiss.callAsFunction) }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save)
                    .disabled(previewURL == nil || processedAudio == nil || isSaving)
            }
        }
        .interactiveDismissDisabled(isSaving || readAloud.localVoiceGenerationState.isWorking)
        .task { await loadMetadata() }
        .alert("创建模拟音色失败", isPresented: errorBinding) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .onDisappear {
            audioPlayer.stop()
            readAloud.cancelLocalVoiceGeneration()
            cleanupStagedSource()
        }
    }

    private var generationStatus: some View {
        Group {
            if let title = readAloud.localVoiceGenerationState.title {
                HStack {
                    if readAloud.localVoiceGenerationState.isWorking { ProgressView().controlSize(.small) }
                    Text(title)
                        .font(.footnote)
                        .foregroundStyle(readAloud.localVoiceGenerationState == .completed ? Color.green : Color.secondary)
                }
            }
        }
    }

    private func loadMetadata() async {
        do {
            let sourceURL = source.stagedURL
            let loaded = try await Task.detached(priority: .userInitiated) {
                try AudioPreprocessor().inspect(sourceURL)
            }.value
            metadata = loaded
            trimStart = 0
            trimEnd = min(loaded.duration, AudioPreprocessor.maximumDuration)
            if loaded.duration < AudioPreprocessor.minimumEffectiveVoiceDuration {
                errorMessage = LocalVoiceError.insufficientVoice(loaded.duration).localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generatePreview() {
        audioPlayer.stop()
        processedAudio = nil
        previewURL = nil
        Task {
            do {
                let processed = try await readAloud.prepareLocalVoiceAudio(
                    from: source.stagedURL,
                    trimRange: trimStart...trimEnd
                )
                let preview = try await readAloud.generateLocalVoicePreview(
                    referenceURL: processed.referenceURL,
                    referenceText: referenceText
                )
                processedAudio = processed
                previewURL = preview
                try audioPlayer.toggle(url: preview)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let processedAudio, let previewURL else { return }
        isSaving = true
        Task {
            do {
                _ = try await readAloud.saveLocalVoiceProfile(
                    name: name,
                    sourceType: .imported,
                    voiceCategory: category,
                    originalURL: source.stagedURL,
                    processedAudio: processedAudio,
                    referenceText: referenceText,
                    previewURL: previewURL,
                    originalFilename: source.originalFilename,
                    isAuthorized: true
                )
                onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func play(url: URL) {
        do { try audioPlayer.toggle(url: url) }
        catch { errorMessage = error.localizedDescription }
    }

    private func cleanupStagedSource() {
        guard FileManager.default.fileExists(atPath: source.stagedURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: source.stagedURL)
        } catch {
            NSLog("导入音频临时文件清理失败：%@", error.localizedDescription)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

struct MyVoiceProfilesView: View {
    @EnvironmentObject private var readAloud: ReadAloudService

    var body: some View {
        List {
            if profiles.isEmpty {
                ContentUnavailableView(
                    "还没有模拟音色",
                    systemImage: "waveform.and.person",
                    description: Text("可以用 App 录音或从“文件”App 导入清晰人声创建。")
                )
            } else {
                ForEach(profiles) { profile in
                    NavigationLink {
                        VoiceProfileDetailView(profileID: profile.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name)
                            Text("\(profile.sourceType.title) · \(profile.gender.title) · \(durationText(profile.duration))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("我的模拟音色")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var profiles: [VoiceProfile] {
        readAloud.zipVoiceProfiles.filter { $0.sourceType != .builtIn }
    }
}

struct VoiceProfileDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var readAloud: ReadAloudService
    @State private var showingRename = false
    @State private var showingDelete = false
    @State private var newName = ""
    @State private var errorMessage: String?

    let profileID: UUID

    var body: some View {
        Form {
            if let profile {
                Section("音色资料") {
                    LabeledContent("名称", value: profile.name)
                    LabeledContent("来源", value: profile.sourceType.title)
                    LabeledContent("类型", value: profile.gender.title)
                    LabeledContent("参考采样率", value: "\(Int(profile.sampleRate.rounded())) Hz")
                    LabeledContent("有效片段", value: durationText(profile.duration))
                    if let filename = profile.originalFilename {
                        LabeledContent("原文件", value: filename)
                    }
                    Button("重命名") {
                        newName = profile.name
                        showingRename = true
                    }
                }

                Section("试听") {
                    Button { playPreview(profile) } label: {
                        Label("播放试听", systemImage: "play.circle.fill")
                    }
                    Button { regenerate(profile) } label: {
                        Label("重新生成试听", systemImage: "arrow.clockwise")
                    }
                    .disabled(readAloud.localVoiceGenerationState.isWorking)
                    if readAloud.localVoiceGenerationState.isWorking {
                        Button(role: .destructive, action: readAloud.cancelLocalVoiceGeneration) {
                            Text("取消生成")
                        }
                    }
                }

                Section("参考文字") {
                    Text(profile.referenceText).textSelection(.enabled)
                }

                Section("音色分配") {
                    Button("设为第一人称旁白") { assign(profile, to: "第一人称旁白") }
                    Button("设为第三人称旁白") { assign(profile, to: "第三人称旁白") }
                    Button("设为未识别角色") { assign(profile, to: "未识别角色") }
                    Menu("绑定小说角色") {
                        if readAloud.detectedCharacterNames.isEmpty {
                            Text("请先建立整书角色档案")
                        } else {
                            ForEach(readAloud.detectedCharacterNames, id: \.self) { name in
                                Button(name) { assign(profile, to: name) }
                            }
                        }
                    }
                    if bindings.isEmpty {
                        Text("当前未绑定").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(bindings, id: \.self) { binding in
                            HStack {
                                Text(binding)
                                Spacer()
                                Button(role: .destructive) { unbind(profile, from: binding) } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section {
                    Button("删除模拟音色", role: .destructive) { showingDelete = true }
                }
            } else {
                ContentUnavailableView("音色已不存在", systemImage: "waveform.slash")
            }
        }
        .navigationTitle(profile?.name ?? "模拟音色")
        .navigationBarTitleDisplayMode(.inline)
        .alert("重命名音色", isPresented: $showingRename) {
            TextField("音色名称", text: $newName)
            Button("取消", role: .cancel) { }
            Button("保存") { rename() }
        }
        .confirmationDialog(
            bindings.isEmpty ? "确定删除这个模拟音色？" : "该音色正在用于\(bindings.joined(separator: "、"))。删除后这些角色会回退到自动音色。",
            isPresented: $showingDelete,
            titleVisibility: .visible
        ) {
            Button("删除并回退", role: .destructive, action: remove)
            Button("取消", role: .cancel) { }
        }
        .alert("音色操作失败", isPresented: errorBinding) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var profile: VoiceProfile? {
        readAloud.zipVoiceProfiles.first { $0.id == profileID }
    }

    private var bindings: [String] {
        guard let profile else { return [] }
        return readAloud.voiceProfileBindings(profile)
    }

    private func playPreview(_ profile: VoiceProfile) {
        do { try readAloud.playStoredVoicePreview(profile) }
        catch { errorMessage = error.localizedDescription }
    }

    private func regenerate(_ profile: VoiceProfile) {
        Task {
            do { try await readAloud.regenerateVoiceProfilePreview(profile) }
            catch is CancellationError { return }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func rename() {
        guard let profile else { return }
        do { try readAloud.renameVoiceProfile(profile, to: newName) }
        catch { errorMessage = error.localizedDescription }
    }

    private func remove() {
        guard let profile else { return }
        do {
            try readAloud.removeZipVoiceProfile(profile)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func assign(_ profile: VoiceProfile, to binding: String) {
        do { try readAloud.assignVoiceProfile(profile, to: binding) }
        catch { errorMessage = error.localizedDescription }
    }

    private func unbind(_ profile: VoiceProfile, from binding: String) {
        let rawBinding = binding.hasPrefix("角色 · ") ? String(binding.dropFirst("角色 · ".count)) : binding
        do { try readAloud.unbindVoiceProfile(profile, from: rawBinding) }
        catch { errorMessage = error.localizedDescription }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

@ViewBuilder
private func voiceQualitySection(_ processed: ProcessedVoiceAudio?) -> some View {
    if let processed {
        Section("参考音频质量") {
            LabeledContent("有效人声", value: durationText(processed.effectiveVoiceDuration))
            LabeledContent("模型采样率", value: "\(Int(processed.sampleRate.rounded())) Hz")
            if processed.issues.isEmpty {
                Label("未发现明显爆音、低音量或大量静音", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(processed.issues) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

private func durationText(_ duration: TimeInterval) -> String {
    let safe = max(0, duration)
    return safe >= 60
        ? String(format: "%d:%02d", Int(safe) / 60, Int(safe) % 60)
        : String(format: "%.1f 秒", safe)
}
