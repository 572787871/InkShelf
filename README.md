# 墨架 InkShelf

一款原生 SwiftUI 小说阅读器。首页模拟实体木质书架，支持 TXT、Markdown、EPUB 导入，提供目录、全文检索、书签、笔记、阅读进度和多种翻页方式。工程为后续 AI 配音朗读保留了独立服务协议。

![墨架双屏视觉预览](Preview/inkshelf-ui-preview.png)

## 当前功能

- 仿真木质书架、书封、最近阅读/导入时间/书名排序
- 书名和作者搜索、长按管理、元数据编辑
- TXT（UTF-8、UTF-16、GB18030）、Markdown、EPUB 导入
- EPUB OPF/Spine/封面/作者解析
- 中文与英文标题自动分章
- 仿真 3D 翻页、覆盖翻页、无动画和纵向滚动
- 目录、全书搜索、书签、笔记、章节与页级进度
- 羊皮纸、纯白、护眼、夜间主题；宋体、楷体、系统字体
- 字号、行距、页边距、屏幕亮度和阅读常亮
- 正文/封面独立文件存储、轻量元数据原子持久化、隐私清单、单元测试
- AI/本地规则识别角色、自动或指定音色、云端/ZipVoice 本地朗读、后台播放与锁屏控制

## 运行

1. 运行 `bash scripts/bootstrap-zipvoice.sh`，下载固定版本的 sherpa-onnx 与 ONNX Runtime iOS XCFramework。
2. 使用 Xcode 16 或更新版本打开 `InkShelf.xcodeproj`。
3. 首次打开等待 Swift Package Manager 拉取 ZIPFoundation 0.9.20 与 SWCompression 4.9.0。
4. 在 Signing & Capabilities 中选择你的开发团队。
5. 选择 iOS 17+ 模拟器或真机运行。

所有书籍、进度、书签和笔记默认只保存在 App 沙盒；仅启用 AI 朗读时需要用户自行配置语音服务。

## AI 与本地有声书

朗读不使用 `AVSpeechSynthesizer`。实现参考 [mimo-tts](https://github.com/dqsq2e2/mimo-tts) 的“角色识别 → 选角 → 分段合成”流程，并在播放当前句时提前生成下一句，减少句子之间等待语音服务的停顿。

配置入口只在“主页右上角设置 → 朗读 → 功能设置”。当前支持：

- AI 按章节判断旁白和人物；也可切换到完全离线的引号/说话动词规则。AI 失败时自动保留本地分析结果。
- 自动音色会让旁白使用稳定音色，并按人物名稳定分配其他音色；指定音色会让全书统一使用一个音色。
- 小米 MiMo `chat/completions` 音频协议，默认使用 `mimo-v2.5-tts`。
- 标准 `audio/speech` 形式的 OpenAI 兼容服务或自建网关。
- iPhone 本地 ZipVoice：Swift 调用 Objective-C++ 桥接，再调用 sherpa-onnx C API 与 ONNX Runtime，在设备上生成语音。设置页会下载约 156 MB 的中英 INT8 模型，模型不打进 IPA。
- 本地模拟音色：确认声音授权后，可在 App 内录制 5～10 秒参考人声，或从“文件”App 导入 WAV/M4A/MP3/AAC/CAF 并裁剪；解码、单声道转换、模型采样率重采样、静音裁剪、质量检测和试听生成全部留在 iPhone。
- 模拟音色按独立目录保存原音、参考 WAV、逐字稿、试听、资料与授权记录；可分配给第一/第三人称旁白、未知人物及整书角色。内置参考音色精简为 5 个，减少包体和低质量选择。
- ZipVoice 模拟音色来自用户录制或导入的授权音频及与内容完全一致的逐字稿；App 会在设备上生成模型需要的单声道 PCM WAV。

API Key 只保存在 iOS 钥匙串中。用户必须明确允许发送角色分析章节或云端朗读短句；“本地规则 + 本地 ZipVoice”组合完全离线。未授权或未完成配置时，阅读页不会发起网络请求。不同兼容服务对模型、角色 ID 和 `instructions` 的支持可能不同，应先用设置页的连接试听确认。

## 第三方依赖

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)（MIT）：EPUB ZIP 容器读取。
- [SWCompression](https://github.com/tsolomko/SWCompression)（MIT）：在设备上解包官方 ZipVoice `.tar.bz2` 模型。
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)（Apache-2.0）与 ONNX Runtime（MIT）：iOS 本地 ZipVoice 推理。
