import SwiftUI

struct ReadAloudSettingsView: View {
    @EnvironmentObject private var readAloud: ReadAloudService

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
                            Text("AI 有声书")
                                .font(.headline)
                            Text("自动识别对白、稳定分配角色并连续朗读")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("不再提供手工声线选择。旁白、人物和未知对白由导演逻辑自动分配；阅读页只负责开始、暂停和继续播放。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("语音服务") {
                Picker("服务类型", selection: providerBinding) {
                    ForEach(ReadAloudProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }

                TextField("服务地址", text: settingBinding(\.baseURL))
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()

                TextField("模型", text: settingBinding(\.model))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("API Key", text: $readAloud.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                providerHelp
            }

            Section("自动导演") {
                Label("旁白与对白自动拆分", systemImage: "text.quote")
                Label("同一人物保持稳定角色", systemImage: "person.2.wave.2")
                Label("按句合成，自动衔接翻页", systemImage: "books.vertical")

                Text("角色识别在设备上完成，只把当前要朗读的短句发送给所选语音服务。服务支持的音色能力不同，OpenAI 兼容服务需实现 /audio/speech 接口。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("播放") {
                Slider(value: settingBinding(\.rateMultiplier), in: 0.7...1.2, step: 0.05)
                LabeledContent("语速", value: speedDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("隐私与连接") {
                Toggle("允许发送朗读文本片段", isOn: settingBinding(\.allowsTextUpload))

                Button(action: readAloud.testConnection) {
                    HStack {
                        Label("测试连接并试听", systemImage: "network")
                        Spacer()
                        connectionIndicator
                    }
                }
                .disabled(!readAloud.canStartReading || readAloud.connectionState == .testing)

                if case let .failed(message) = readAloud.connectionState {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if readAloud.connectionState == .connected {
                    Text("连接成功，已播放自动旁白试听。")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }

                Text("API Key 保存在 iPhone 钥匙串中，不会写入书库或偏好文件。小说只会在开始朗读或连接试听时发送给你选择的服务，墨架不会代为保存。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("朗读服务")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { readAloud.stopVoicePreview() }
    }

    @ViewBuilder
    private var providerHelp: some View {
        switch readAloud.settings.provider {
        case .mimo:
            Text("使用 MiMo 的 OpenAI 兼容 chat/completions 音频协议，自动调用白桦、冰糖、苏打、茉莉等预置角色。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .openAICompatible:
            Text("可连接其他兼容服务或自建网关。墨架会调用 audio/speech，并自动分配服务常见的角色 ID；服务不支持某个角色时会直接显示接口错误。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        switch readAloud.connectionState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .connected:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case let .failed(message):
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel(message)
        }
    }

    private var providerBinding: Binding<ReadAloudProvider> {
        Binding(
            get: { readAloud.settings.provider },
            set: { readAloud.applyProviderDefaults(for: $0) }
        )
    }

    private func settingBinding<Value>(
        _ keyPath: WritableKeyPath<ReadAloudSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { readAloud.settings[keyPath: keyPath] },
            set: { readAloud.settings[keyPath: keyPath] = $0 }
        )
    }

    private var speedDescription: String {
        String(format: "%.2f×", readAloud.settings.rateMultiplier)
    }
}
