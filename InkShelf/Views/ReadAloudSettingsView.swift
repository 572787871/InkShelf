import SwiftUI

struct ReadAloudSettingsView: View {
    @EnvironmentObject private var readAloud: ReadAloudService
    @EnvironmentObject private var library: LibraryStore
    @State private var selectedRoleBookID: UUID?

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
                            Text("多声线连续朗读")
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
                    ForEach(networkProviders) { provider in
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
                Text("MiMo 使用 chat/completions 音频协议；其他服务需兼容 /audio/speech。API Key 只保存在 iPhone 钥匙串。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Divider()
                voiceAssignmentRows
            }

            Section("本地角色导演") {
                Text("仅在本机分析对白、说话人和连续对话，不上传小说正文。分析结果会按章节保存，并在朗读时直接用于角色声线分配。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("分析书籍", selection: $selectedRoleBookID) {
                    Text("请选择").tag(UUID?.none)
                    ForEach(library.books) { book in
                        Text(book.title).tag(Optional(book.id))
                    }
                }
                if let progress = readAloud.wholeBookRoleProgress,
                   progress.bookID == selectedRoleBookID {
                    ProgressView(value: progress.fraction)
                    Text("\(progress.completedChapters)/\(progress.totalChapters) · \(progress.chapterTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(role: .destructive, action: readAloud.cancelWholeBookRoleAnalysis) {
                        Label("暂停本地分析", systemImage: "pause.circle")
                    }
                } else {
                    Button(action: analyzeSelectedBookLocally) {
                        Label("分析整本书的角色", systemImage: "person.3.sequence.fill")
                    }
                    .disabled(selectedRoleBook == nil)
                }
                if let confidence = readAloud.roleAnalysisAverageConfidence {
                    LabeledContent("规则归因置信度（估计）", value: "\(Int((confidence * 100).rounded()))%")
                        .font(.footnote)
                }
                if let message = readAloud.roleAnalysisMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(message.contains("失败") ? .red : .secondary)
                }
                LabeledContent("已识别角色", value: "\(readAloud.detectedCharacterNames.count) 个")
                    .font(.footnote)
            }

            Section("播放") {
                Slider(value: settingBinding(\.rateMultiplier), in: 0.75...2.0, step: 0.05)
                LabeledContent("语速", value: String(format: "%.2f×", readAloud.settings.rateMultiplier))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("隐私与试听") {
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

                Text("只有在你明确允许后，正在预生成的朗读文本才会发送到配置的语音服务。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("朗读服务")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            normalizeProvider()
            selectDefaultRoleBook()
        }
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
        }
        Text(voiceSelectionHelp)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var networkProviders: [ReadAloudProvider] {
        ReadAloudProvider.allCases.filter { $0 != .localZipVoice }
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
            "自动模式会为旁白和对白保持稳定的音色分配。"
        case .roleBased:
            "第一人称旁白、第三人称旁白和对白可以分别指定音色。"
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
                try? readAloud.refreshVoiceProfileBindings()
            }
        )
    }

    private func normalizeProvider() {
        if readAloud.settings.provider == .localZipVoice {
            readAloud.applyProviderDefaults(for: .mimo)
        }
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

    private func analyzeSelectedBookLocally() {
        guard let selectedRoleBook else { return }
        readAloud.analyzeWholeBook(selectedRoleBook, forceLocal: true)
    }
}
