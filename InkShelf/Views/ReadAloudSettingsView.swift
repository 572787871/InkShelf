import SwiftUI
import UniformTypeIdentifiers

struct ReadAloudSettingsView: View {
    @EnvironmentObject private var readAloud: ReadAloudService
    @State private var showingVoiceImporter = false
    @State private var showingVoiceEditor = false
    @State private var pendingVoiceURL: URL?
    @State private var draftVoiceName = ""
    @State private var draftVoiceGender = ZipVoiceProfileGender.unspecified
    @State private var draftReferenceText = ""
    @State private var isSavingVoice = false
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
                            Text("AI 识别角色 · 云端与本地共存 · 下一句预生成")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("播放当前句时会提前生成下一句，减少段落之间的停顿。阅读页只负责开始、暂停和继续，所有配置仍集中在这里。")
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
                    Text("AI 会按章节判断每句话属于旁白还是具体人物；接口失败时自动回退到本地引号和说话动词规则，不中断朗读。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("完全离线识别引号对白和“某某说、问、答”等提示语。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("音色分配") {
                Picker("方式", selection: settingBinding(\.voiceSelectionMode)) {
                    ForEach(ReadAloudVoiceSelectionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if readAloud.settings.voiceSelectionMode == .single {
                    Picker("指定音色", selection: settingBinding(\.selectedVoiceIdentifier)) {
                        Text("请选择").tag("")
                        ForEach(readAloud.availableVoiceChoices) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    }
                }
                Text(readAloud.settings.voiceSelectionMode == .automatic
                    ? "自动模式会让旁白使用稳定音色，并按人物名称稳定分配其他音色。"
                    : "指定模式会让旁白和所有角色统一使用所选音色。")
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
                .disabled(!readAloud.canStartReading || readAloud.connectionState == .testing)

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
        .onDisappear { readAloud.stopVoicePreview() }
        .fileImporter(
            isPresented: $showingVoiceImporter,
            allowedContentTypes: [.wav],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                pendingVoiceURL = url
                draftVoiceName = url.deletingPathExtension().lastPathComponent
                draftVoiceGender = .unspecified
                draftReferenceText = ""
                showingVoiceEditor = true
            case let .failure(error):
                localError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingVoiceEditor) { voiceEditor }
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
            Label("导入参考音色 WAV", systemImage: "waveform.badge.plus")
        }
        .disabled(readAloud.zipVoiceInstallState != .installed)

        ForEach(readAloud.zipVoiceProfiles) { profile in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                    Text("\(profile.gender.title) · \(profile.referenceText.prefix(24))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    do { try readAloud.removeZipVoiceProfile(profile) }
                    catch { localError = error.localizedDescription }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }

        Text("ZipVoice 是零样本声音复刻：参考文字必须与 WAV 中实际说出的内容完全一致。请只导入你有权使用的声音。模型和音色均保存在本机。")
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
                    Text("必须逐字对应 WAV 中的语音，标点可以不同，但不要漏字或添加说明。音频需为单声道 16-bit PCM WAV。")
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
                self.pendingVoiceURL = nil
            } catch {
                localError = error.localizedDescription
            }
        }
    }
}
