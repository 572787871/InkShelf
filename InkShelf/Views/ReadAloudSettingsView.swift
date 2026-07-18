import SwiftUI
import UniformTypeIdentifiers

struct ReadAloudSettingsView: View {
    @EnvironmentObject private var readAloud: ReadAloudService
    @EnvironmentObject private var library: LibraryStore
    @State private var showingVoiceImporter = false
    @State private var showingVoiceEditor = false
    @State private var pendingVoiceURL: URL?
    @State private var draftVoiceName = ""
    @State private var draftVoiceGender = ZipVoiceProfileGender.unspecified
    @State private var draftReferenceText = ""
    @State private var isSavingVoice = false
    @State private var isStagingVoice = false
    @State private var selectedRoleBookID: UUID?
    @State private var selectedRoleChapterIndex = 0
    @State private var localError: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.and.person.filled")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 44, height: 44)
                            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("小说有声书")
                                .font(.headline)
                            Text("本地大模型识别角色 · 跨页续句无缝朗读")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("同一句即使被分页切开，也会合并为一条语音并在朗读过程中翻页。阅读页只负责开始、暂停和继续，所有配置集中在这里。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("语音生成") {
                Picker("引擎", selection: providerBinding) {
                    ForEach(ReadAloudProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }

                if readAloud.settings.provider == .localZipVoice {
                    localModelRows
                } else {
                    TextField("服务地址", text: settingBinding(\.baseURL))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("语音模型", text: settingBinding(\.model))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("MiMo 使用 chat/completions 音频协议；其他服务需兼容 /audio/speech。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Divider()
                voiceAssignmentRows
            }

            Section("角色识别") {
                Picker("检测方式", selection: settingBinding(\.roleDetectionMode)) {
                    ForEach(ReadAloudRoleDetectionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if readAloud.settings.roleDetectionMode == .ai {
                    Picker("AI 服务", selection: analysisProviderBinding) {
                        ForEach(ReadAloudAIProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    TextField("AI 服务地址", text: settingBinding(\.analysisBaseURL))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("角色分析模型", text: settingBinding(\.analysisModel))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("AI 会按章节判断每句话属于旁白还是具体人物；接口失败时保留基础解析结果，不中断朗读。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if readAloud.settings.roleDetectionMode == .localModel {
                    Picker("本地模型", selection: settingBinding(\.localRoleModel)) {
                        ForEach(LocalRoleModelVariant.allCases) { model in
                            Text(model.title).tag(model)
                        }
                    }
                    localRoleModelRow
                    Picker("本地图书", selection: $selectedRoleBookID) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(library.books) { book in
                            Text(book.title).tag(Optional(book.id))
                        }
                    }
                    if let selectedRoleBook {
                        Picker("章节", selection: $selectedRoleChapterIndex) {
                            ForEach(selectedRoleBook.chapters) { chapter in
                                Text(chapter.title).tag(chapter.index)
                            }
                        }
                    }
                    Button(action: analyzeSelectedLocalChapter) {
                        HStack {
                            Label("识别所选章节角色", systemImage: "person.2.wave.2")
                            Spacer()
                            if readAloud.localRoleModelState == .analyzing {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(
                        selectedRoleBook == nil
                            || readAloud.localRoleModelState != .installed
                    )
                    if let message = readAloud.localRoleAnalysisMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(message.hasPrefix("识别失败") ? .red : .secondary)
                    }
                    Text("模型下载后完全在 iPhone 上理解章节上下文，不上传小说；会区分第一人称旁白、第三人称旁白和具体角色。分析失败时会使用基础解析结果继续朗读。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("播放") {
                Slider(value: settingBinding(\.rateMultiplier), in: 0.7...1.2, step: 0.05)
                LabeledContent("语速", value: String(format: "%.2f×", readAloud.settings.rateMultiplier))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("凭据、隐私与试听") {
                if requiresNetwork {
                    SecureField("API Key", text: $readAloud.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("允许发送角色分析或朗读片段", isOn: settingBinding(\.allowsTextUpload))
                } else {
                    Label("当前为完全离线模式，不上传小说文本", systemImage: "iphone.and.arrow.forward")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button(action: readAloud.testConnection) {
                    HStack {
                        Label(readAloud.settings.provider == .localZipVoice ? "测试本地生成" : "测试连接并试听", systemImage: "play.circle")
                        Spacer()
                        connectionIndicator
                    }
                }
                .disabled(!readAloud.canPreviewVoice || readAloud.connectionState == .testing)

                if case let .failed(message) = readAloud.connectionState {
                    Text(message).font(.footnote).foregroundStyle(.red)
                } else if readAloud.connectionState == .connected {
                    Text("测试成功，已播放旁白试听。")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }

                if requiresNetwork {
                    Text("API Key 只保存在 iPhone 钥匙串。AI 角色检测会发送当前章节的句子，云端语音只发送正在预生成的短句；本地 ZipVoice 不上传声音样本。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("朗读服务")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: selectDefaultRoleChapter)
        .onChange(of: selectedRoleBookID) { _, _ in selectDefaultChapterInBook() }
        .onDisappear { readAloud.stopVoicePreview() }
        .fileImporter(
            isPresented: $showingVoiceImporter,
            allowedContentTypes: [.audio, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                stageImportedAudio(url)
            case let .failure(error):
                localError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingVoiceEditor, onDismiss: discardStagedAudio) {
            voiceEditor
        }
        .alert("本地朗读设置失败", isPresented: Binding(
            get: { localError != nil },
            set: { if !$0 { localError = nil } }
        )) {
            Button("知道了", role: .cancel) { localError = nil }
        } message: {
            Text(localError ?? "未知错误")
        }
    }

    @ViewBuilder
    private var voiceAssignmentRows: some View {
        Picker("音色分配", selection: settingBinding(\.voiceSelectionMode)) {
            ForEach(ReadAloudVoiceSelectionMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }

        if readAloud.settings.voiceSelectionMode == .roleBased {
            voicePicker("第一人称旁白", selection: settingBinding(\.narratorVoiceIdentifier))
            voicePicker("第三人称旁白", selection: settingBinding(\.thirdPersonVoiceIdentifier))
            voicePicker("未识别角色", selection: settingBinding(\.characterVoiceIdentifier))
            ForEach(readAloud.detectedCharacterNames, id: \.self) { name in
                voicePicker("角色 · \(name)", selection: characterVoiceBinding(name))
            }
            if readAloud.detectedCharacterNames.isEmpty {
                Text("识别章节后，每个明确人物都会显示独立音色选项；本地与云端语音引擎都支持。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Text(voiceSelectionHelp)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var localModelRows: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("ZipVoice 中英 INT8")
                Text("sherpa-onnx + ONNX Runtime · 约 156 MB 下载")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            modelAction
        }

        Button { showingVoiceImporter = true } label: {
            HStack {
                Label("导入参考音频", systemImage: "waveform.badge.plus")
                Spacer()
                if isStagingVoice { ProgressView().controlSize(.small) }
            }
        }
        .disabled(isStagingVoice)

        ForEach(readAloud.zipVoiceProfiles) { profile in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                    Text("\(ZipVoiceBuiltInProfiles.contains(profile) ? "内置高清参考" : profile.gender.title) · \(profile.referenceText.prefix(24))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    readAloud.previewVoice(profile.voiceIdentifier)
                } label: {
                    Image(systemName: "play.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(readAloud.connectionState == .testing)
                .accessibilityLabel("试听\(profile.name)")
                if !ZipVoiceBuiltInProfiles.contains(profile) {
                    Button(role: .destructive) {
                        do { try readAloud.removeZipVoiceProfile(profile) }
                        catch { localError = error.localizedDescription }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }

        Text("支持 WAV、M4A、MP3、AAC 等系统可读取的音频，导入后统一转为 24kHz 单声道 WAV。参考文字必须与音频逐字一致；请只导入你有权使用的声音。")
            .font(.footnote)
            .foregroundStyle(.secondary)

        if case let .failed(message) = readAloud.zipVoiceInstallState {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var modelAction: some View {
        switch readAloud.zipVoiceInstallState {
        case .notInstalled, .failed(_):
            Button("下载") { readAloud.downloadZipVoiceModel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case let .downloading(progress):
            VStack(spacing: 4) {
                if progress > 0 {
                    ProgressView(value: progress).frame(width: 64)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("取消") { readAloud.cancelZipVoiceDownload() }
                    .font(.caption)
            }
        case .installing:
            ProgressView().controlSize(.small)
        case .installed:
            Label("已安装", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private var voiceEditor: some View {
        NavigationStack {
            Form {
                Section("音色资料") {
                    TextField("名称", text: $draftVoiceName)
                    Picker("声音类型", selection: $draftVoiceGender) {
                        ForEach(ZipVoiceProfileGender.allCases) { gender in
                            Text(gender.title).tag(gender)
                        }
                    }
                }
                Section("参考音频逐字稿") {
                    TextEditor(text: $draftReferenceText)
                        .frame(minHeight: 130)
                    Text("必须逐字对应音频中的语音，标点可以不同，但不要漏字或添加说明。App 会自动转换音频格式。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("导入本地音色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingVoiceEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveVoiceProfile() }
                        .disabled(draftReferenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingVoice)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var requiresNetwork: Bool {
        readAloud.settings.provider != .localZipVoice
            || readAloud.settings.roleDetectionMode == .ai
    }

    @ViewBuilder
    private var localRoleModelRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(readAloud.settings.localRoleModel.approximateDownload)
                Text("MLX · Qwen3 4-bit · 仅用于章节角色理解")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch readAloud.localRoleModelState {
            case .notInstalled, .failed(_):
                Button("下载") { readAloud.downloadLocalRoleModel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            case let .downloading(progress):
                VStack(spacing: 4) {
                    ProgressView(value: progress).frame(width: 64)
                    Button("取消") { readAloud.cancelLocalRoleModelDownload() }
                        .font(.caption)
                }
            case .installed:
                Menu {
                    Button("删除模型", role: .destructive) {
                        Task {
                            do { try await readAloud.removeLocalRoleModel() }
                            catch { localError = error.localizedDescription }
                        }
                    }
                } label: {
                    Label("已安装", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            case .analyzing:
                Label("分析中", systemImage: "brain.head.profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if case let .failed(message) = readAloud.localRoleModelState {
            Text(message).font(.footnote).foregroundStyle(.red)
        }
    }

    private func voicePicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("自动").tag("")
            ForEach(readAloud.availableVoiceChoices) { voice in
                Text(voice.name).tag(voice.id)
            }
        }
    }

    private var voiceSelectionHelp: String {
        switch readAloud.settings.voiceSelectionMode {
        case .automatic:
            "自动模式会为旁白使用稳定音色，并按人物名称稳定分配角色音色。"
        case .roleBased:
            "第一人称、第三人称、未知人物以及每个已识别角色都能分别选择音色。"
        }
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        switch readAloud.connectionState {
        case .idle: EmptyView()
        case .testing: ProgressView().controlSize(.small)
        case .connected: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var providerBinding: Binding<ReadAloudProvider> {
        Binding(
            get: { readAloud.settings.provider },
            set: { readAloud.applyProviderDefaults(for: $0) }
        )
    }

    private var analysisProviderBinding: Binding<ReadAloudAIProvider> {
        Binding(
            get: { readAloud.settings.analysisProvider },
            set: { readAloud.applyAnalysisProviderDefaults(for: $0) }
        )
    }

    private func settingBinding<Value>(_ keyPath: WritableKeyPath<ReadAloudSettings, Value>) -> Binding<Value> {
        Binding(
            get: { readAloud.settings[keyPath: keyPath] },
            set: { readAloud.settings[keyPath: keyPath] = $0 }
        )
    }

    private func characterVoiceBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { readAloud.settings.characterVoiceIdentifiers[name] ?? "" },
            set: { readAloud.settings.characterVoiceIdentifiers[name] = $0 }
        )
    }

    private var selectedRoleBook: NovelBook? {
        guard let selectedRoleBookID else { return nil }
        return library.books.first { $0.id == selectedRoleBookID }
    }

    private func selectDefaultRoleChapter() {
        guard selectedRoleBookID == nil else { return }
        let defaultBook = library.books.max {
            ($0.lastReadAt ?? $0.importedAt) < ($1.lastReadAt ?? $1.importedAt)
        }
        selectedRoleBookID = defaultBook?.id
        selectedRoleChapterIndex = defaultBook?.currentChapter ?? 0
    }

    private func selectDefaultChapterInBook() {
        guard let selectedRoleBook else {
            selectedRoleChapterIndex = 0
            return
        }
        selectedRoleChapterIndex = min(
            max(selectedRoleBook.currentChapter, 0),
            max(selectedRoleBook.chapters.count - 1, 0)
        )
    }

    private func analyzeSelectedLocalChapter() {
        guard let selectedRoleBook else { return }
        readAloud.analyzeLocalRoles(
            book: selectedRoleBook,
            chapterIndex: selectedRoleChapterIndex
        )
    }

    private func stageImportedAudio(_ url: URL) {
        isStagingVoice = true
        Task {
            do {
                let staged = try await Task.detached(priority: .userInitiated) {
                    let hasScope = url.startAccessingSecurityScopedResource()
                    defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("InkShelfVoiceImports", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let fileName = "\(UUID().uuidString).\(url.pathExtension.isEmpty ? "audio" : url.pathExtension)"
                    let staged = directory.appendingPathComponent(fileName)
                    var coordinationError: NSError?
                    var copyError: Error?
                    NSFileCoordinator().coordinate(
                        readingItemAt: url,
                        options: [],
                        error: &coordinationError
                    ) { readableURL in
                        do {
                            try FileManager.default.copyItem(at: readableURL, to: staged)
                        } catch {
                            copyError = error
                        }
                    }
                    if let coordinationError { throw coordinationError }
                    if let copyError { throw copyError }
                    guard FileManager.default.fileExists(atPath: staged.path) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    return staged
                }.value
                pendingVoiceURL = staged
                draftVoiceName = url.deletingPathExtension().lastPathComponent
                draftVoiceGender = .unspecified
                draftReferenceText = ""
                showingVoiceEditor = true
            } catch {
                localError = "无法读取所选音频：\(error.localizedDescription)"
            }
            isStagingVoice = false
        }
    }

    private func saveVoiceProfile() {
        guard let pendingVoiceURL else { return }
        isSavingVoice = true
        Task { @MainActor in
            defer { isSavingVoice = false }
            do {
                try await readAloud.addZipVoiceProfile(
                    from: pendingVoiceURL,
                    name: draftVoiceName,
                    gender: draftVoiceGender,
                    referenceText: draftReferenceText
                )
                showingVoiceEditor = false
                try? FileManager.default.removeItem(at: pendingVoiceURL)
                self.pendingVoiceURL = nil
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func discardStagedAudio() {
        guard let pendingVoiceURL else { return }
        try? FileManager.default.removeItem(at: pendingVoiceURL)
        self.pendingVoiceURL = nil
    }
}
