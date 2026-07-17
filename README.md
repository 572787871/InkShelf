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
- 下载后完全离线的 Kokoro/VITS 分角色配音、模型商店、音色包导入、试听、后台与锁屏控制

## 运行

1. 使用 Xcode 16 或更新版本打开 `InkShelf.xcodeproj`。
2. 运行 `bash scripts/bootstrap-local-tts.sh`，下载并校验固定版本的 sherpa-onnx iOS 运行库。
3. 首次打开等待 Swift Package Manager 拉取 ZIPFoundation 0.9.20 和 SWCompression 4.9.0。
4. 在 Signing & Capabilities 中选择你的开发团队。
5. 选择 iOS 17+ 模拟器或真机运行。

工程不依赖后端。所有书籍、进度、书签和笔记默认只保存在 App 沙盒。

## 本地音色包

朗读不使用 `AVSpeechSynthesizer`，也不会回退到苹果系统音色。在“设置 → 朗读 → 功能设置 → 模型商店”可以下载官方 Kokoro 中文多音色模型；应用会显示进度、支持取消和重试，并在安装前校验固定 SHA-256。模型安装完成后删除下载缓存，后续语音生成不需要网络。

也可以从文件 App 导入自定义 ZIP 音色包。ZIP 内可有一层目录，但模型根目录必须包含 `voice.json`：

```json
{
  "formatVersion": 1,
  "name": "中文小说音色",
  "engine": "kokoro",
  "model": "model.onnx",
  "voices": "voices.bin",
  "tokens": "tokens.txt",
  "lexicons": ["lexicon-zh.txt", "lexicon-us-en.txt"],
  "dataDirectory": "espeak-ng-data",
  "speakers": [
    { "id": 0, "name": "温柔女声" },
    { "id": 1, "name": "沉稳男声" }
  ]
}
```

`engine` 可为 `kokoro` 或 `vits`。VITS 不需要 `voices`；`lexicons` 和 `dataDirectory` 可按模型实际文件省略。`speakers.id` 必须对应模型的 speaker ID。模型包展开上限为 2 GB，导入器拒绝绝对路径、父目录路径和符号链接。

## 第三方依赖

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)（MIT）：EPUB ZIP 容器读取。
- [SWCompression](https://github.com/tsolomko/SWCompression)（MIT）：官方模型 `.tar.bz2` 解压。
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)（Apache-2.0）：Kokoro/VITS 离线语音合成。
