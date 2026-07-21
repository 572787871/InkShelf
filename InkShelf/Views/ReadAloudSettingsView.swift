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

                TextField("服务地址", text: settingBinding(\.baseURL))
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                TextField("语音模型", text: settingBinding(\.model))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $readAloud.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("MiMo 使用 chat/completions 音频协议；其他服务需兼容 /audio/speech。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Divider()
                voiceAssignmentRows
            }

            Section("整书角色导演") {
                Label("解析结果按书籍和章节保存，换字体、字号或重新分页后仍能继续使用。", systemImage: "person.3.sequence.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                            "本地解析整本小说",
                            systemImage: "iphone.gen3.radiowaves.left.and.right"
                        )
                    }
                    .disabled(selectedRoleBook == nil)
                }
                if let message = readAloud.roleAnalysisMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(message.contains("失败") ? .red : .secondary)
                }
                Text("本地解析不会上传正文；中断后可继续，听书过程中也会即时使用相同规则兜底。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("播放与隐私") {
                Slider(value: settingBinding(\.rateMultiplier), in: 0.75...2.0, step: 0.05)
                LabeledContent("语速", value: String(format: "%.2f×", readAloud.settings.rateMultiplier))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                
                Toggle("允许发送朗读片段", isOn: settingBinding(\.allowsTextUpload))
                
                Button(action: readAloud.testConnection) {
                    HStack {
                        Label("测试连接并试听", systemImage: "play.circle")
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
                
                Text("API Key 只保存在 iPhone 钥匙串。云端语音只发送正在预生成的朗读文本。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("朗读服务")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: selectDefaultRoleBook)
        .onChange(of: selectedRoleBookID) { _, _ in loadSelectedBookCast() }
        .onDisappear { readAloud.stopVoicePreview() }
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
            if readAloud.detectedCharacterNames.isEmpty {
                Text("建立整书角色档案后会显示识别数量。具体人物不会在分析过程中逐个弹出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if readAloud.wholeBookRoleProgress == nil {
                LabeledContent("已识别角色", value: "\(readAloud.detectedCharacterNames.count) 个")
            }
        }
        Text(voiceSelectionHelp)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var requiresNetwork: Bool {
        return true
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
}
