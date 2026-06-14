# TestFlight 发布材料与操作清单

对照 `reference/TestFlight release 前检查清单.md` 的发布准备。本地准备工作已完成
（icon、sandbox、版本、加密申报、Release archive 验证）；以下材料在 Apple Developer
账号就绪后直接粘贴进 App Store Connect。

- **Version**: 0.9.0
- **Build**: 1（每次上传递增 `CURRENT_PROJECT_VERSION`，不可复用）
- **Bundle ID**: `com.example.Luma`
- **Target macOS**: 26.0+，Apple Silicon (arm64) only
- **Feedback Email**: <反馈邮箱>
- **Demo account**: 不需要（应用无登录）
- **Export Compliance**: 仅使用系统提供的豁免加密；`ITSAppUsesNonExemptEncryption = false`
  已写入 Info.plist，上传后无需再答加密问卷

## Beta App Description

> Luma shows live captions for any audio on your Mac — your microphone or other
> apps' audio — and translates them on device in real time. Transcription uses
> Apple's SpeechAnalyzer; translation runs entirely on device with the Translation
> framework. No audio or text ever leaves your Mac. Captions appear in a floating,
> always-on-top subtitle overlay that joins every Space and full-screen app, with
> adjustable appearance and TXT/SRT export.

## What to Test

```
Please test:
1. First launch: microphone permission prompt appears on first mic session;
   "System Audio Recording" permission prompt appears on first system-audio session
2. Live transcription from microphone (start / pause / stop / clear)
3. System audio capture: play a video in another app, select system audio input,
   confirm captions follow
4. Translation presets: Fast (translates the in-progress line), Balanced, Accurate —
   switch language pairs and confirm capability warnings appear for unsupported pairs
5. Floating subtitle overlay: drag, resize, follows full-screen apps and Spaces;
   turn on Reduce Transparency and confirm the solid fallback
6. TXT and SRT export: timecodes should match real audio timing
7. In-app language switching (System / English / 简体中文) without relaunch
8. Diagnostics tab: speech model and translation language pack download status

Known issues:
- Model download progress is shown as indeterminate (no percentage)
- Per-app audio capture is experimental on current beta systems
- System-provided menu bar items follow the launch language; in-app language
  switching affects Luma's own UI only

When reporting bugs, include:
- macOS version
- Mac model / chip
- Steps to reproduce
- Screenshot or screen recording
```

## Beta App Review Information（外部测试需要）

- Contact: <姓名> / <反馈邮箱> / <电话>
- Review notes 建议写明：app 需要 Microphone 与 System Audio Recording 权限；
  测试翻译需在 Diagnostics 标签页先下载语言包；无账号体系。

## ASC 操作步骤（账号就绪后按序执行）

1. [developer.apple.com](https://developer.apple.com/account) → Certificates, IDs &
   Profiles → Identifiers → 注册 App ID `com.example.Luma`（capability 无需额外勾选，
   sandbox/audio-input 由 entitlements 描述）
2. App Store Connect → My Apps → 新建 macOS App，绑定该 bundle ID
3. Xcode（beta）→ Settings → Accounts 登录账号；工程改用
   `CODE_SIGN_STYLE = Automatic` + `DEVELOPMENT_TEAM = <团队ID>`（替换当前 ad-hoc 手动签名）
4. Product → Archive（或 `xcodebuild archive`，见下）→ Organizer →
   Distribute App → TestFlight，dSYM 随 archive 自动上传
5. 等待 processing 完成 → TestFlight 标签页填 Test Information（上方文案）
6. 建 Internal Testing 分组（≤100 人，无需审核）→ 添加测试者 → 分配 build
7. 外部测试（≤10,000 人）：建 External 分组，首个 build 需 Beta App Review，
   提交前确认上方 Review Information 完整
8. Build 有效期 90 天，到期前需上传新 build

## 本地构建命令

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app
xcodebuild -project Luma.xcodeproj -scheme Luma -configuration Release \
  -destination 'platform=macOS,arch=arm64' -archivePath build/Luma.xcarchive archive
# 验证
codesign --verify --deep --strict --verbose=2 build/Luma.xcarchive/Products/Applications/Luma.app
plutil -p build/Luma.xcarchive/Products/Applications/Luma.app/Contents/Info.plist
```

## 剩余风险与待办

- [ ] **注册 Apple Developer Program**（$99/年）——一切 ASC 步骤的前置条件
- [ ] **Sandbox 下人工功能验证**：sandbox 已启用且应用启动无违规日志，但麦克风转写、
      **系统音频 process tap**、模型下载、导出保存需真人完整过一遍（TCC 弹窗需手动确认）。
      若系统音频在 sandbox 下不可用，需决定仅以 mic 模式上 TestFlight 或另寻方案
- [ ] **干净环境验证**：在一台非开发机（或本机新建用户）上启动 Release app，
      确认首启权限弹窗与 icon 显示正常
- [ ] **Beta Xcode 构建的接受度**：本项目必须用 Xcode 27 beta 编译（macOS 27 API）。
      Apple 允许 beta Xcode 构建上 TestFlight（不允许正式发布）；若上传被拒，
      备选方案是用正式 Xcode 26 构建并用 `#if compiler` 在编译期裁掉 macOS 27 路径
- [ ] 截图（可选但建议）：主窗口 + overlay 字幕效果各一张，供 TestFlight 页面使用
