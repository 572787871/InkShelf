import SwiftUI

struct ReadAloudSettingsView: View {
    @EnvironmentObject private var readAloud: ReadAloudService
    @EnvironmentObject private var library: LibraryStore
    @State private var showingAuthorization = false
    @State private var authorizationIntent = VoiceCreationIntent.record
    @State private var showingRecorder = false
    @State private var showingVoiceImporter = false
    @State private var importedVoiceSource: ImportedVoiceSource?
    @State private var selectedRoleBookID: UUID?
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
                            Text("整书角色档案 · 本地多声线连续朗读")
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
                    zipVoiceRows
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

            Section("整书角色导演") {
                Label("解析结果按书籍和章节保存，换字体、字号或重新分页后仍能继续使用。", systemImage: "person.3.sequence.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("角色解析", selection: settingBinding(\.roleDetectionMode)) {
                    ForEach(ReadAloudRoleDetectionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
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
                } else {
                    Label("完全离线：结合引号、说话动词、上下句、人物称谓和连续对话轮次识别角色。", systemImage: "iphone")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Picker("本地图书", selection: $selectedRoleBookID) {
                    Text("请选择").tag(UUID?.none)
                    ForEach(library.books) { book in
                        Text(book.title).tag(Optional(book.id))
                    }
                }
                if let progress = readAloud.wholeBookRoleProgress,
                   progress.bookID == selectedRoleBookID {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress.fraction)
                        Text("\(progress.completedChapters)/\(progress.totalChapters) · \(progress.chapterTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive, action: readAloud.cancelWholeBookRoleAnalysis) {
                        Label("暂停整书分析", systemImage: "pause.circle")
                    }
                } else {
                    Button(action: analyzeSelectedBook) {
                        Label(
                            readAloud.settings.roleDetectionMode == .localRules
                                ? "本地解析整本小说"
                                : "建立或继续整书角色档案",
                            systemImage: readAloud.settings.roleDetectionMode == .localRules
                                ? "iphone.gen3.radiowaves.left.and.right"
                                : "wand.and.stars"
                        )
                    }
                    .disabled(selectedRoleBook == nil)
                }
                if let message = readAloud.roleAnalysisMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(message.contains("失败") ? .red : .secondary)
                }
                Text(readAloud.settings.roleDetectionMode == .localRules
                    ? "本地解析不会上传正文；中断后可继续，听书过程中也会即时使用相同规则兜底。"
                    : "AI 按章节和短批次工作；网络或接口失败时会自动保存本地增强解析结果，不再阻塞播放。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    Text("API Key 只保存在 iPhone 钥匙串。整书角色导演按章节短批次发送文本，云端语音只发送正在预生成的朗读块；本地 ZipVoice 不上传声音样本。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("朗读服务")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: selectDefaultRoleBook)
        .onChange(of: selectedRoleBookID) { _, _ in loadSelectedBookCast() }
        .onDisappear { readAloud.stopVoicePreview() }
        .alert("声音授权确认", isPresented: $showingAuthorization) {
            Button("取消", role: .cancel) { }
            Button("我确认并继续") { continueAuthorizedCreation() }
        } message: {
            Text("我确认这是本人的声音，或我已经获得声音所有者的明确授权。我不会使用该功能进行冒充、欺骗或侵犯他人权益。")
        }
        .sheet(isPresented: $showingRecorder) {
            NavigationStack {
                LocalVoiceRecordingView { }
            }
        }
        .sheet(isPresented: $showingVoiceImporter) {
            LocalVoiceDocumentPicker { result in
                showingVoiceImporter = false
                switch result {
                case let .success(source):
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        importedVoiceSource = source
                    }
                case let .failure(error):
                    localError = "无法读取所选音频：\(error.localizedDescription)"
                }
            }
        }
        .sheet(item: $importedVoiceSource) { source in
            NavigationStack {
                ImportedVoiceEditorView(source: source) { }
            }
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
            voicePicker("第一人称旁白", selection: voiceSettingBinding(\.narratorVoiceIdentifier))
            voicePicker("第三人称旁白", selection: voiceSettingBinding(\.thirdPersonVoiceIdentifier))
            voicePicker("未识别角色", selection: voiceSettingBinding(\.characterVoiceIdentifier))
            ForEach(readAloud.detectedCharacterNames, id: \.self) { name in
                let gender = readAloud.detectedCharacterGenders[name]?.title ?? "未定"
                voicePicker("角色 · \(name) · \(gender)", selection: characterVoiceBinding(name))
            }
            if readAloud.detectedCharacterNames.isEmpty {
                Text("建立整书角色档案后，每个明确人物都会显示独立音色选项；本地与云端语音引擎都支持。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Text(voiceSelectionHelp)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var zipVoiceRows: some View {
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

        Button {
            requestAuthorization(for: .record)
        } label: {
            Label("录制我的声音", systemImage: "mic.circle")
        }

        Button {
            requestAuthorization(for: .importFile)
        } label: {
            Label("导入音频文件", systemImage: "waveform.badge.plus")
        }

        NavigationLink {
            MyVoiceProfilesView()
        } label: {
            LabeledContent("我的模拟音色", value: "\(customVoices.count)")
        }

        DisclosureGroup("内置女声 · \(builtInFemaleVoices.count)") {
            ForEach(builtInFemaleVoices) { profile in
                voiceProfileRow(profile, removable: false)
            }
        }
        DisclosureGroup("内置男声 · \(builtInMaleVoices.count)") {
            ForEach(builtInMaleVoices) { profile in
                voiceProfileRow(profile, removable: false)
            }
        }
        Text("录音和导入文件都只在 iPhone 本地处理。支持 WAV、M4A、MP3、AAC、CAF；App 会读取当前 ZipVoice 模型的实际采样率，再统一转换、裁静音并检查有效人声。")
            .font(.footnote)
            .foregroundStyle(.secondary)

        if case let .failed(message) = readAloud.zipVoiceInstallState {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private var builtInFemaleVoices: [ZipVoiceProfile] {
        readAloud.zipVoiceProfiles
            .filter { ZipVoiceBuiltInProfiles.contains($0) && $0.gender == .female }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var builtInMaleVoices: [ZipVoiceProfile] {
        readAloud.zipVoiceProfiles
            .filter { ZipVoiceBuiltInProfiles.contains($0) && $0.gender == .male }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var customVoices: [ZipVoiceProfile] {
        readAloud.zipVoiceProfiles.filter { $0.sourceType != .builtIn }
    }

    private func voiceProfileRow(_ profile: ZipVoiceProfile, removable: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                Text("\(removable ? "已导入" : "内置高清") · \(profile.gender.title)")
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

    private var requiresNetwork: Bool {
        readAloud.settings.provider != .localZipVoice
            || readAloud.settings.roleDetectionMode == .ai
    }

    private func voicePicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("自动").tag("")
            if readAloud.settings.provider == .localZipVoice {
                if !customVoices.isEmpty {
                    Section("我的模拟音色") {
                        ForEach(customVoices) { profile in
                            Text(profile.name).tag(profile.voiceIdentifier)
                        }
                    }
                }
                Section("内置女声") {
                    ForEach(builtInFemaleVoices) { profile in
                        Text(profile.name).tag(profile.voiceIdentifier)
                    }
                }
                Section("内置男声") {
                    ForEach(builtInMaleVoices) { profile in
                        Text(profile.name).tag(profile.voiceIdentifier)
                    }
                }
            } else {
                ForEach(readAloud.availableVoiceChoices) { voice in
                    Text(voice.name).tag(voice.id)
                }
            }
        }
    }

    private var voiceSelectionHelp: String {
        switch readAloud.settings.voiceSelectionMode {
        case .automatic:
            "自动模式会固定旁白声线，并结合整书档案中的人物名称和性别稳定分配角色音色。"
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

    private func voiceSettingBinding(_ keyPath: WritableKeyPath<ReadAloudSettings, String>) -> Binding<String> {
        Binding(
            get: { readAloud.settings[keyPath: keyPath] },
            set: {
                readAloud.settings[keyPath: keyPath] = $0
                do { try readAloud.refreshVoiceProfileBindings() }
                catch { localError = error.localizedDescription }
            }
        )
    }

    private func characterVoiceBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { readAloud.settings.characterVoiceIdentifiers[name] ?? "" },
            set: {
                readAloud.settings.characterVoiceIdentifiers[name] = $0
                do { try readAloud.refreshVoiceProfileBindings() }
                catch { localError = error.localizedDescription }
            }
        )
    }

    private var selectedRoleBook: NovelBook? {
        guard let selectedRoleBookID else { return nil }
        return library.books.first { $0.id == selectedRoleBookID }
    }

    private func selectDefaultRoleBook() {
        guard selectedRoleBookID == nil else { return }
        let defaultBook = library.books.max {
            ($0.lastReadAt ?? $0.importedAt) < ($1.lastReadAt ?? $1.importedAt)
        }
        selectedRoleBookID = defaultBook?.id
        if let defaultBook { readAloud.loadStoredCastCharacters(for: defaultBook) }
    }

    private func loadSelectedBookCast() {
        guard let selectedRoleBook else { return }
        readAloud.loadStoredCastCharacters(for: selectedRoleBook)
    }

    private func analyzeSelectedBook() {
        guard let selectedRoleBook else { return }
        readAloud.analyzeWholeBook(selectedRoleBook)
    }

    private func requestAuthorization(for intent: VoiceCreationIntent) {
        authorizationIntent = intent
        showingAuthorization = true
    }

    private func continueAuthorizedCreation() {
        switch authorizationIntent {
        case .record: showingRecorder = true
        case .importFile: showingVoiceImporter = true
        }
    }

    private enum VoiceCreationIntent {
        case record
        case importFile
    }
}
