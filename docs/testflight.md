# TestFlight 发布材料与操作清单(macOS + iOS)

对照 `reference/TestFlight release 前检查清单.md` 的发布准备。macOS + iOS 共用一个
ASC App 记录,各自 archive 与上传。签名身份(team、bundle id)在 gitignored 的
`BuildConfig/Local.xcconfig` 中,不入库;下述 `<APP_ID>` 指其中的
`LUMA_BUNDLE_ID_APP`,扩展 id 恒为 `<APP_ID>.BroadcastExtension`(硬约束,见
`BuildConfig/Local.xcconfig.example`)。

- **Version**: 0.9.0
- **Build**: 1(每次上传递增 `CURRENT_PROJECT_VERSION`,app 与扩展同步,不可复用)
- **Target**: macOS 26.0+(Apple Silicon)/ iOS 26.0+(iPhone + iPad),arm64
- **Feedback Email**: <反馈邮箱>
- **Demo account**: 不需要(应用无登录)
- **Export Compliance**: 仅使用系统提供的豁免加密;`ITSAppUsesNonExemptEncryption = false`
  已写入 Info.plist,上传后无需再答加密问卷

## Beta App Description(两平台共用)

> Luma shows live captions for any audio on your Mac, iPhone, or iPad — your
> microphone or other apps' audio — and translates them on device in real time.
> Transcription uses Apple's SpeechAnalyzer; translation runs entirely on device
> with the Translation framework. No audio or text ever leaves your device.
> On macOS, captions appear in a floating, always-on-top subtitle overlay; on
> iOS they appear in a Picture in Picture window that keeps updating over other
> apps and on the lock screen. TXT/SRT export included.

## What to Test — macOS

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
```

## What to Test — iOS

```
Please test:
1. First launch: microphone permission prompt appears on first mic session
2. Live transcription from microphone (start / pause / stop / clear)
3. Other apps' audio via screen broadcast: tap the broadcast button, select
   "Luma Captions", start broadcasting, then play a video in another app —
   captions should follow. The red status bar while broadcasting is
   system-mandated; stop the broadcast from the status bar or Control Center
4. Broadcast liveness: the session controls should reflect whether the broadcast
   extension is alive; if the broadcast ends on its own (or you stop it from
   Control Center), the session should stop cleanly
5. Picture in Picture captions: start PiP, switch to another app or lock the
   screen, confirm captions keep updating; check show-original / show-translation
   and font-size settings apply
6. Background capture: with mic or broadcast running, background Luma and
   confirm transcription continues
7. Translation presets (Fast / Balanced / Accurate), language-pair switching,
   capability warnings — same as macOS
8. TXT and SRT export via the document picker
9. In-app language switching (System / English / 简体中文) without relaunch
10. iPhone and iPad layouts, rotation

Known issues:
- Model download progress is shown as indeterminate (no percentage)
- Starting a broadcast is a system flow (picker + countdown); Luma cannot start
  it silently — this is an Apple platform requirement
- PiP is device-only; captions pause if the system reclaims the PiP window
```

## 通用 bug 报告要求(附在两平台 What to Test 末尾)

```
When reporting bugs, include:
- OS version (macOS / iOS)
- Device model / chip
- Steps to reproduce
- Screenshot or screen recording
```

## Beta App Review Information(外部测试需要)

- Contact: <姓名> / <反馈邮箱> / <电话>
- Review notes 建议写明:
  - macOS 需要 Microphone 与 System Audio Recording 权限;iOS 需要 Microphone 权限,
    其他 app 音频经系统屏幕广播(ReplayKit Broadcast Upload Extension)采集,
    仅转发音频 PCM,不录屏面
  - 测试翻译需在 Diagnostics 标签页先下载语言包
  - 无账号体系,无需 demo account

## ASC 操作步骤(按序执行)

1. [developer.apple.com](https://developer.apple.com/account) → 确认 Program License
   Agreement 无待同意项
2. Certificates, IDs & Profiles → Identifiers,注册三项:
   - App ID `<APP_ID>`(Explicit;勾选 **App Groups** capability)
   - App ID `<APP_ID>.BroadcastExtension`(Explicit;勾选 **App Groups**)
   - App Group `group.<APP_ID>`,并在上述两个 App ID 的 App Groups 配置中分配它
   - 备注:Xcode Automatic 签名在首次真机构建/archive 时也能代注册,手动注册更可控
3. App Store Connect → My Apps → New App:**同一记录同时勾选 macOS 与 iOS**,绑定
   `<APP_ID>`。App 名称若 "Luma" 被占用,备选 "Luma Captions"、"Luma Live Captions"
   (名称仅 ASC 层面,不影响 bundle id)
4. Xcode → Settings → Accounts 登录开发者账号;Manage Certificates 确认存在
   Apple Development 证书(分发用证书/描述文件由 Automatic 签名在上传时管理)
5. 两平台分别 archive(命令见下)→ Organizer → Distribute App → TestFlight,
   dSYM 随 archive 自动上传
6. 等待 processing 完成 → TestFlight 标签页按平台填 Test Information(上方文案)
7. 建 Internal Testing 分组(≤100 人,无需审核)→ 添加测试者 → 分配两平台 build
8. 外部测试(≤10,000 人):建 External 分组,首个 build 需 Beta App Review,
   提交前确认上方 Review Information 完整
9. Build 有效期 90 天,到期前需上传新 build

## 本地构建命令

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app

# macOS archive
xcodebuild -project Luma.xcodeproj -scheme Luma -configuration Release \
  -destination 'platform=macOS,arch=arm64' -archivePath build/Luma-macOS.xcarchive archive

# iOS archive(含广播扩展;需已登录 Xcode 账号,必要时加 -allowProvisioningUpdates)
xcodebuild -project Luma.xcodeproj -scheme Luma -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Luma-iOS.xcarchive archive

# 验证(macOS 产物;iOS 产物路径为 .../Applications/Luma.app 同理)
codesign --verify --deep --strict --verbose=2 build/Luma-macOS.xcarchive/Products/Applications/Luma.app
plutil -p build/Luma-macOS.xcarchive/Products/Applications/Luma.app/Contents/Info.plist
# iOS:确认 appex 的 bundle id 为 <APP_ID>.BroadcastExtension 且两端 App Group 一致
codesign -d --entitlements - --xml \
  build/Luma-iOS.xcarchive/Products/Applications/Luma.app/PlugIns/LumaBroadcastExtension.appex
```

## 剩余风险与待办

- [x] 注册 Apple Developer Program(2026-07 完成)
- [ ] **Xcode 登录账号 + 生成开发证书**(本机钥匙串当前无签名证书)——签名构建的前置
- [ ] **macOS sandbox 下人工功能验证**:麦克风转写、系统音频 process tap(TCC 弹窗)、
      模型下载、导出保存需真人完整过一遍
- [ ] **iOS 真机人工验证**:广播扩展端到端、PiP、后台采集、扩展意外终止后的行为
      (此前受无付费账号阻塞,现可执行)
- [ ] **干净环境验证**:非开发机(或本机新建用户)启动 Release app,确认首启权限
      弹窗与 icon 显示正常
- [ ] **Beta Xcode 构建的接受度**:本项目必须用 Xcode 27 beta 编译(macOS/iOS 27 API)。
      Apple 允许 beta Xcode 构建上 TestFlight(不允许正式发布);若上传被拒,
      备选方案是用正式 Xcode 26 构建并用 `#if compiler` 在编译期裁掉 27 路径
- [ ] 截图(可选但建议):macOS 主窗口 + overlay 各一张;iOS 主界面 + PiP 字幕各一张
