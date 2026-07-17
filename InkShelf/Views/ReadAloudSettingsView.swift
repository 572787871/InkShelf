import SwiftUI
import UniformTypeIdentifiers

struct ReadAloudSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var readAloud: ReadAloudService
    let onStart: (() -> Void)?

    init(onStart: (() -> Void)? = nil) {
        self.onStart = onStart
    }

    var body: some View {
        NavigationStack {
            ReadAloudSettingsView(onStart: onStart == nil ? nil : startReading)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(onStart == nil ? "完成" : "取消") { dismiss() }
                    }
                }
        }
    }

    private func startReading() {
        readAloud.stopVoicePreview()
        dismiss()
        onStart?()
    }
}

struct ReadAloudSettingsView: View {
    @EnvironmentObject private var readAloud: ReadAloudService
    let onStart: (() -> Void)?
    @State private var showingVoiceImporter = false
    @State private var isImportingVoice = false
    @State private var importError: String?
    @State private var packageToDelete: LocalVoicePackage?

    init(onStart: (() -> Void)? = nil) {
        self.onStart = onStart
    }

    private var voiceOptions: [ReadAloudVoiceOption] {
        readAloud.availableLocalVoices
    }

    var body: some View {
        Form {
            Section("本地音色模型") {
                Button {
                    showingVoiceImporter = true
                } label: {
                    HStack {
                        Label("导入音色包", systemImage: "square.and.arrow.down")
                        Spacer()
                        if isImportingVoice { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isImportingVoice)

                if readAloud.localVoicePackages.isEmpty {
                    ContentUnavailableView(
                        "尚未导入音色",
                        systemImage: "waveform.badge.exclamationmark",
                        description: Text("导入包含 voice.json 的 Kokoro 或 VITS ZIP 模型包后，才能试听和开始朗读。")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(readAloud.localVoicePackages) { package in
                        HStack(spacing: 12) {
                            Image(systemName: "waveform.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(package.name)
                                Text("\(package.engineName) · \(package.voiceCount) 个音色 · 完全离线")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                packageToDelete = package
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("删除\(package.name)")
                        }
                    }
                }

                Text("模型只保存在本机 Application Support 中。导入过程会校验模型清单和文件路径，不会上传音色或小说正文。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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
                voiceRow(
                    title: "旁白",
                    selection: settingBinding(\.narratorVoiceIdentifier),
                    roleSlot: nil
                )
                ForEach(0..<ReadAloudSettings.roleVoiceCount, id: \.self) { index in
                    voiceRow(
                        title: "角色声线 \(index + 1)",
                        selection: roleVoiceBinding(at: index),
                        roleSlot: index
                    )
                }

                if voiceOptions.isEmpty {
                    Text("没有本地音色。请先导入 Kokoro 或 VITS 音色模型包。墨架不会回退使用苹果系统声音。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("选择“自动选择”时，墨架只会从已导入的本地模型音色中分配；同一人物会稳定使用同一声线槽位。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("生效范围") {
                Text("声线和速度会从下一句开始生效；连续对话轮换规则会从下一页或下次开始朗读时生效。后台播放、锁屏控制和原进度返回方式保持不变。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let onStart {
                Section {
                    Button(action: onStart) {
                        Label("开始朗读", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                    .disabled(!readAloud.canStartLocalReading || isImportingVoice)
                } footer: {
                    Text(readAloud.canStartLocalReading
                        ? "将使用本地模型，从当前可见页面开头开始朗读。"
                        : "必须先导入至少一个本地音色才能开始朗读。")
                }
            }
        }
        .navigationTitle("朗读设置")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { readAloud.stopVoicePreview() }
        .fileImporter(
            isPresented: $showingVoiceImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                importVoicePackage(from: url)
            case let .failure(error):
                importError = error.localizedDescription
            }
        }
        .alert("音色包导入失败", isPresented: importErrorIsPresented) {
            Button("知道了", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "未知错误")
        }
        .confirmationDialog(
            "删除本地音色包？",
            isPresented: packageDeleteIsPresented,
            titleVisibility: .visible
        ) {
            if let packageToDelete {
                Button("删除 \(packageToDelete.name)", role: .destructive) {
                    removeVoicePackage(packageToDelete)
                }
            }
            Button("取消", role: .cancel) { packageToDelete = nil }
        } message: {
            Text("模型文件会从此设备删除；如果正在使用该音色，朗读也会停止。")
        }
    }

    @ViewBuilder
    private func voiceRow(
        title: String,
        selection: Binding<String>,
        roleSlot: Int?
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Picker(title, selection: selection) {
                    Text("自动选择").tag("")
                    if !selection.wrappedValue.isEmpty,
                       !voiceOptions.contains(where: { $0.id == selection.wrappedValue }) {
                        Text("已不可用的声线").tag(selection.wrappedValue)
                    }
                    ForEach(voiceOptions) { voice in
                        Text("\(voice.name) · \(voice.packageName)").tag(voice.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(voiceOptions.isEmpty)

                Button {
                    readAloud.previewVoice(roleSlot: roleSlot)
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("试听\(title)")
                .disabled(voiceOptions.isEmpty)
            }
        }
    }

    private var importErrorIsPresented: Binding<Bool> {
        Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )
    }

    private var packageDeleteIsPresented: Binding<Bool> {
        Binding(
            get: { packageToDelete != nil },
            set: { if !$0 { packageToDelete = nil } }
        )
    }

    private func importVoicePackage(from url: URL) {
        isImportingVoice = true
        Task {
            do {
                try await readAloud.importLocalVoicePackage(from: url)
            } catch {
                importError = error.localizedDescription
            }
            isImportingVoice = false
        }
    }

    private func removeVoicePackage(_ package: LocalVoicePackage) {
        packageToDelete = nil
        do {
            try readAloud.removeLocalVoicePackage(package)
        } catch {
            importError = error.localizedDescription
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
