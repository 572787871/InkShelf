import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var readAloud: ReadAloudService
    @AppStorage("readerTheme") private var theme = ReaderTheme.paper.rawValue
    @AppStorage("readerFont") private var font = ReaderFont.system.rawValue
    @AppStorage("pageTurnStyle") private var pageTurn = PageTurnStyle.curl.rawValue
    @AppStorage("keepScreenAwake") private var keepAwake = true

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读偏好") {
                    Picker("默认主题", selection: $theme) { ForEach(ReaderTheme.allCases) { Text($0.displayName).tag($0.rawValue) } }
                    Picker("默认字体", selection: $font) { ForEach(ReaderFont.allCases) { Text($0.displayName).tag($0.rawValue) } }
                    Picker("翻页方式", selection: $pageTurn) { ForEach(PageTurnStyle.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    Toggle("阅读时屏幕常亮", isOn: $keepAwake)
                }
                Section("导入与存储") {
                    Label("TXT / Markdown / EPUB", systemImage: "doc.badge.plus")
                    Text("书籍只保存在本机 App 沙盒内，不会上传。删除 App 会同时删除书架内容。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("AI 朗读") {
                    HStack { Label("配音引擎", systemImage: "waveform"); Spacer(); Text("等待接入").foregroundStyle(.secondary) }
                    Text("工程已定义章节预处理、播放、暂停、句子定位与状态同步接口，可直接接入后续 AI 语音服务。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("应用", value: "墨架 InkShelf")
                    LabeledContent("版本", value: "1.0.0")
                    NavigationLink("隐私说明") { PrivacyView() }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .overlay { PersistentReadAloudOverlay(readAloud: readAloud, bottomPadding: 18) }
    }
}

private struct PrivacyView: View {
    var body: some View {
        List {
            Text("墨架不会收集、分析或上传你的阅读文件、阅读进度和书签。所有数据默认仅保存在设备本地。")
            Text("未来启用 AI 朗读时，应用会在发送任何正文前明确展示所使用的服务、数据范围和隐私条款，并再次征得同意。")
        }.navigationTitle("隐私说明")
    }
}
