# DuoShot

[English](README.md) · 简体中文

一个常驻菜单栏的 macOS 截图和录屏工具。基于原生 AppKit 和 ScreenCaptureKit，不在
Dock 显示图标，不需要账号，也不收集任何遥测数据。

## 功能

**截图**
- 区域截图、指针下的窗口、全屏，以及“重截上一次的区域”。
- 滚动截图：你来滚动，DuoShot 负责拼接。它不会自己去滚动页面，所以不需要辅助功能权限。
- 可选：选区时冻结屏幕、延时截图，以及是否包含光标、菜单栏和子窗口（菜单、弹出框）。
- 窗口截图可以加边距，垫上当前显示器实际显示的壁纸，并带阴影。

**录屏**
- 区域或全屏录制为 MP4，支持系统声音、麦克风（可以选择输入设备）、光标和点击高亮，帧率可调。
- 可以裁剪录制的片段，也能导出为 GIF。

**标注**
- 箭头、直线、矩形、文字、马克笔、荧光笔、打码和裁剪。每个标记有自己的颜色和粗细，所有编辑都能撤销。
- 自动识别敏感信息（邮箱、IP、电话、卡号、API 密钥等），可以一键打码。

**截图之后**
- 浮动预览卡片：可以拖进别的应用，也可以复制、编辑或丢弃。
- 复制文字：用 Vision 在本机做 OCR。
- 搜索截图（菜单里按 ⌘F）：按截图里出现过的文字找回旧截图。
- 可选的分享链接，走你自己部署的 Cloudflare Worker（见 [`Worker/`](Worker/README.md)）。

### 默认快捷键

| 操作 | 快捷键 |
| --- | --- |
| 区域截图 | ⇧⌘A |
| 截取指针下的窗口 | ⇧⌘S |
| 区域录屏（再按一次停止） | ⇧⌘Y |
| 滚动截图 | ⇧⌘L |

全屏截图、重截上一次区域和全屏录屏默认没有绑定快捷键。所有快捷键都可以在设置里修改。

## 系统要求

- macOS 26 或更高版本，Apple 芯片或 Intel 均可。
- **屏幕录制**权限，第一次截图时会申请。
- **麦克风**权限，只在你为录屏打开旁白时才会申请。

## 安装

从[最新 Release](../../releases/latest) 下载 `DuoShot.zip`，解压后把 `DuoShot.app`
拖进 `/Applications`。Release 包使用 Developer ID 签名，并经过 Apple 公证。

## 隐私

- 截图只保存在你的 Mac 上。OCR 和敏感信息识别都在本机用 Apple 的 Vision 框架完成。
- 只要你没有配置分享链接，DuoShot 就不会发出任何网络请求。配置之后，文件只会上传到你自己设置的服务器，鉴权
  token 存在钥匙串里。
- 没有统计分析，没有崩溃上报，也不会检查更新。

## 从源码构建

需要 Xcode 26（Swift 6）和一张 **Developer ID Application** 证书。项目没有 Xcode
工程文件，签名由 Makefile 手动完成。屏幕录制权限绑定在签名的 Designated Requirement 上，如果用 ad-hoc
签名，每次重新构建都会丢失这个权限。

```bash
make verify     # 构建、打包、签名，并校验 Designated Requirement
make install    # 替换 /Applications/DuoShot.app 并重新启动
make test       # 无人值守的自测套件（运行的几分钟里会占用屏幕）
make help       # 列出所有目标
```

如果要用自己的证书签名，新建一个不提交到 git 的 `local.mk`：

```make
TEAM_ID := ABCDE12345
SIGN_ID := Developer ID Application: Your Name (ABCDE12345)
```

`make dist` 会构建通用二进制、完成公证，然后生成 `dist/DuoShot.zip`。运行前需要先配置
notarytool 的钥匙串配置（`xcrun notarytool store-credentials DuoShot`）。

项目约定写在 [`CLAUDE.md`](CLAUDE.md) 里，包括并发规则、自测规范和图片编辑器必须遵守的不变式。做较大的改动之前请先读一遍。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `Sources/DuoShot/` | 应用本体 |
| `Packages/Linkdrop/` | 分享链接的上传客户端（Swift package，MIT） |
| `Worker/` | 分享链接的后端：Cloudflare Worker 加 R2 存储 |
| `Scripts/` | 调试时用到的独立探针和复现脚本 |

## 许可证

[MIT](LICENSE) © 2026 Bo Li
