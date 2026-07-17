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
- 自动识别对白并稳定分配角色的 AI 有声书、后台播放与锁屏控制

## 运行

1. 使用 Xcode 16 或更新版本打开 `InkShelf.xcodeproj`。
2. 首次打开等待 Swift Package Manager 拉取 ZIPFoundation 0.9.20。
3. 在 Signing & Capabilities 中选择你的开发团队。
4. 选择 iOS 17+ 模拟器或真机运行。

所有书籍、进度、书签和笔记默认只保存在 App 沙盒；仅启用 AI 朗读时需要用户自行配置语音服务。

## AI 有声书

朗读不使用 `AVSpeechSynthesizer`，也没有手工声线设置。实现参考 [mimo-tts](https://github.com/dqsq2e2/mimo-tts) 的“角色识别 → 自动选角 → 分段合成”流程：墨架在设备上识别旁白和对白，同一人物会获得稳定的自动角色，然后按短句调用语音接口。

配置入口只在“主页右上角设置 → 朗读 → 功能设置”。当前支持：

- 小米 MiMo `chat/completions` 音频协议，默认使用 `mimo-v2.5-tts`。
- 标准 `audio/speech` 形式的 OpenAI 兼容服务或自建网关。

API Key 只保存在 iOS 钥匙串中。用户必须明确允许发送朗读片段；未授权或未完成配置时，阅读页不会发起网络请求。不同兼容服务对模型、角色 ID 和 `instructions` 的支持可能不同，应先用设置页的连接试听确认。

## 第三方依赖

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)（MIT）：EPUB ZIP 容器读取。
