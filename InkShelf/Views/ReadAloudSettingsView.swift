import SwiftUI

struct ReadAloudSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ReadAloudSettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}

struct ReadAloudSettingsView: View {
    @EnvironmentObject private var readAloud: ReadAloudService

    private var voiceOptions: [ReadAloudVoiceOption] {
        readAloud.availableChineseVoices
    }

    var body: some View {
        Form {
            Section("分角色配音") {
                Toggle(
                    "自动分配角色声线",
                    isOn: settingBinding(\.automaticallyAssignsCharacterVoices)
                )
                Toggle(
                    "连续未知对话轮换声线",
                    isOn: settingBinding(\.alternatesUnattributedDialogue)
                )
                .disabled(!readAloud.settings.automaticallyAssignsCharacterVoices)

                Text("应用会在本机识别引号对话和“某某说、问、答、喊”等提示语。无法确定人物时只轮换未知角色声线，不会改写或上传正文。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("朗读速度") {
                Slider(
                    value: settingBinding(\.rateMultiplier),
                    in: 0.65...1.2,
                    step: 0.05
                )
                LabeledContent("当前速度", value: speedDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("声线") {
                voicePicker(
                    title: "旁白",
                    selection: settingBinding(\.narratorVoiceIdentifier)
                )
                ForEach(0..<ReadAloudSettings.roleVoiceCount, id: \.self) { index in
                    voicePicker(
                        title: "角色声线 \(index + 1)",
                        selection: roleVoiceBinding(at: index)
                    )
                }

                if voiceOptions.count < 2 {
                    Text("当前设备可用的中文系统声线较少。可在系统辅助功能的语音设置中下载更多声线；缺少声线时会使用不同音调作为回退。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("选择“自动选择”时，墨架会从设备已安装的中文声线中分配；同一人物会稳定使用同一声线槽位。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("生效范围") {
                Text("声线和速度会从下一句开始生效；连续对话轮换规则会从下一页或下次开始朗读时生效。后台播放、锁屏控制和原进度返回方式保持不变。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("朗读设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func voicePicker(title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("自动选择").tag("")
            if !selection.wrappedValue.isEmpty,
               !voiceOptions.contains(where: { $0.id == selection.wrappedValue }) {
                Text("已不可用的声线").tag(selection.wrappedValue)
            }
            ForEach(voiceOptions) { voice in
                Text("\(voice.name) · \(voice.language)").tag(voice.id)
            }
        }
    }

    private var speedDescription: String {
        "\(Int((readAloud.settings.rateMultiplier * 100).rounded()))%"
    }

    private func settingBinding<Value>(
        _ keyPath: WritableKeyPath<ReadAloudSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { readAloud.settings[keyPath: keyPath] },
            set: { readAloud.settings[keyPath: keyPath] = $0 }
        )
    }

    private func roleVoiceBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard readAloud.settings.roleVoiceIdentifiers.indices.contains(index) else { return "" }
                return readAloud.settings.roleVoiceIdentifiers[index]
            },
            set: { identifier in
                guard readAloud.settings.roleVoiceIdentifiers.indices.contains(index) else { return }
                readAloud.settings.roleVoiceIdentifiers[index] = identifier
            }
        )
    }
}
