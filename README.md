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
- `ReadAloudService` AI 配音扩展接口

## 运行

1. 使用 Xcode 16 或更新版本打开 `InkShelf.xcodeproj`。
2. 首次打开等待 Swift Package Manager 拉取 ZIPFoundation 0.9.20。
3. 在 Signing & Capabilities 中选择你的开发团队。
4. 选择 iOS 17+ 模拟器或真机运行。

工程不依赖后端。所有书籍、进度、书签和笔记默认只保存在 App 沙盒。

## AI 朗读接入

实现 `Services/ReadAloudService.swift` 中的协议，并将实现注入阅读页即可。接口已覆盖：

- 按书籍/章节预处理音频
- 播放、暂停、停止
- 句子级定位
- 准备中、播放中、暂停和失败状态

建议正式接入时把 API 密钥放在服务端，并增加分段缓存、后台音频、锁屏控制、倍速、定时关闭和隐私授权页。

## 第三方依赖

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)（MIT）：EPUB ZIP 容器读取。
