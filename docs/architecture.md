# Luma — 架构设计

目标：Apple Silicon-only、macOS 26 部署目标、macOS 27 SDK 构建的实时字幕 + 本机翻译应用。低延迟、稳定、可测试优先。

## 分层

```
Luma/
  App/             LumaApp（@main，Scene 装配）、AppDependencies（组合根，按协议注入）
  UI/              MainWindow（工作台）、SubtitleOverlay（NSPanel 浮窗）、SettingsView、
                   StatusBar（语言对/模型/音频/延迟/权限/错误指示）
  Domain/          纯 Swift，无系统框架依赖（可单测）：
                   TranscriptSegment、SubtitleEntry、LanguagePair、SessionState、
                   SubtitleBuffer、SessionController、SRTFormatter
  Services/        协议层（Domain 与 Infrastructure 的边界）：
                   AudioInputProviding、TranscriptionProviding、TranslationProviding、
                   CapabilityChecking、TranscriptExporting
  Infrastructure/  系统框架适配（每个类型只 import 自己需要的框架）：
                   MicrophoneAudioProvider（AVAudioEngine）
                   SystemAudioTapProvider（CoreAudio process tap + aggregate device）
                   SpeechAnalyzerTranscriber（Speech）
                   AppleTranslationProvider（Translation；下载经 SwiftUI bridge）
                   CapabilityService（TCC/模型/语言对状态）
  Resources/       Assets.xcassets、Luma.entitlements
LumaTests/         Domain 单测 + mock services + 管线集成测试
docs/              research.md（API 查证）、architecture.md（本文件）
```

依赖方向：`UI → Domain → Services(协议) ← Infrastructure`。View 永不直接触碰 SpeechAnalyzer/TranslationSession/AVAudioEngine/CoreAudio。

## 核心数据流

```
AudioInputProviding                     TranscriptionProviding
  AsyncStream<AudioChunk>  ──────────▶   AsyncStream<TranscriptEvent>
  (PCM buffer + 设备时间)                  (volatile | finalized, CMTimeRange)
                                                  │
                                                  ▼
                                         SessionController (actor)
                                          · 状态机 idle/preparing/running/paused/stopped/failed
                                          · finalized 段去重（按 range 起点 + 文本）
                                                  │ finalized only
                                                  ▼
                                         TranslationProviding
                                          · 串行批量翻译，结果带 segment ID 回填
                                                  │
                                                  ▼
                                         SubtitleBuffer (@MainActor @Observable)
                                          · volatile 文本、finalized 列表、译文回填
                                          · 环形缓存上限、导出快照
                                                  │
                                   ┌──────────────┴──────────────┐
                                   ▼                             ▼
                             MainWindow                    SubtitleOverlay
```

### 关键类型（Domain）

- `AudioChunk`：`AVAudioPCMBuffer` + `AVAudioTime?`（Sendable 包装）。
- `TranscriptEvent`：`.volatile(text, range)` / `.finalized(TranscriptSegment)` / `.status(TranscriptionStatus)`。
- `TranscriptSegment`：`id`、`text: AttributedString`、`range: CMTimeRange`、`finalizedAt: Date`。
- `SubtitleEntry`：`segment` + `translation: String?` + `translationState`。
- `LanguagePair`：`source: Locale`（转写 locale）+ `target: Locale.Language`（翻译目标）。

## 并发模型

- `SessionController`、`SpeechAnalyzerTranscriber`、`AppleTranslationProvider`、两个音频 provider 均为 actor 或拥有内部串行 Task。
- UI 状态唯一出口：`SubtitleBuffer`（`@MainActor @Observable`），SessionController 通过 MainActor 跳板写入。
- start/pause/stop = 结构化 Task 取消：取消音频流 → analyzer `finalizeAndFinishThroughEndOfInput()` → 翻译队列排空。
- pause 实现为"音频流暂停投递"（保持 analyzer 存活），stop 为完整收尾。

## Availability 策略

- 部署目标 macOS 26.0；macOS 27 增强一律 `if #available(macOS 27.0, *)`，集中在 Infrastructure：
  - 音频格式转换：27 用 `AnalyzerInputConverter`，26 用 `AVAudioConverter` 手动转换（同一协议方法内部分支）。
  - 翻译策略：26.4+ 用 `Strategy.lowLatency`。
- 不为未查证 API 写代码；不确定处用 TODO + 协议隔离（见 research.md §7）。

## 翻译管线细节

1. 运行期：`TranslationSession(installedSource:target:)`（macOS 26+ 程序化 init，仅限已安装语言对）。session 随「语言对 + 模式」缓存，变更时重建并 `prepareTranslation()` 预热。
2. 三档模式（`TranslationMode`）：
   - **fast**：lowLatency 策略 + volatile 实时刷新——独立 worker 经 `bufferingNewest(1)` 流消费未定稿文本（永远只保留最新快照），相同文本跳过，每次请求后休眠 250ms 限制资源占用；定稿时实时译文被正式译文取代。
   - **balanced**：lowLatency 策略，仅翻译 finalized segment（默认档）。
   - **accurate**：highFidelity 策略（macOS 26.4+，可用时为 Apple Intelligence 模型），仅翻译 finalized segment。
3. finalized 翻译按到达顺序串行处理（独立 worker，不阻塞转写事件循环），按 segment UUID 回填 SubtitleBuffer。
4. 模型下载：`LanguageAvailability.status == .supported`（未安装）时，UI 提示并挂载隐藏 `TranslationDownloadBridge` view（`.translationTask` + `prepareTranslation()`）触发系统下载流程；完成后切回程序化 session。
5. 不可用语言对：字幕回退为原文 + 状态栏明示。

## 字幕 overlay（按平台采用原生形态）

由 `SubtitleOverlayController` 统一驱动（`toggle/show/hide` + `isVisible`），具体表面分平台：

- **macOS — 浮动面板**：`SubtitleOverlayView` 装入 `NSPanel`（`styleMask [.nonactivatingPanel, .borderless …]`、`level .floating`、`collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary]`、`isMovableByWindowBackground`，内容 `NSHostingView`）。表面默认 Liquid Glass（`glassEffect`），`accessibilityReduceTransparency` 或用户选择时切实底/material；动态字体；VoiceOver 朗读最新 finalized+译文。
- **iOS — 画中画(PiP)**：`CaptionPiPController` 把原文/译文自绘进 `CVPixelBuffer` → `CMSampleBufferCreateReadyWithImageBuffer` → `AVSampleBufferDisplayLayer`，驱动 `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`；`ContentView` 用 1×1 隐藏 `CaptionPiPLayerView` 挂载源 layer。配 `UIBackgroundModes=audio` + `AVAudioSession.playAndRecord/[.mixWithOthers,.defaultToSpeaker]`，退后台仍采集、字幕浮于其他 App 之上、不打断其他 App 播放。PiP 共享 Overlay 设置的 `showOriginal/showTranslation/fontSize`（`surface` 仅 macOS，PiP 为不透明视频）。PiP 为真机能力，模拟器不支持。
- **音频来源**：macOS 麦克风 + 系统音频（CoreAudio process tap）；iOS 麦克风 + 系统音频。iOS 无公开 API 在进程内捕获其他 App 音频（详见 research.md §8.1），故系统音频走 **ReplayKit 广播上传扩展**（见下「## iOS 系统级音频」）。

## 延迟指标

`now - (sessionAudioStart + segment.range.end)` ≈ 端到端字幕延迟（音频末端到显示）；volatile 与 finalized 分别统计，状态栏显示滑动平均。

## 导出

- TXT：finalized 原文 +（可选）译文逐行。
- SRT：`SRTFormatter`（纯函数，可单测）以 segment `range` 生成 session-relative timecode；条目 = finalized segment（含译文时双语行）。

## 风险

见 research.md §7。macOS 系统音频 provider 失败不影响麦克风主管线；翻译不可用不影响转写显示。iOS 已移除系统音频 provider（平台不支持）。

## iOS 系统级音频（ReplayKit 广播上传扩展）

iOS 无法在进程内捕获其他 App 音频（research.md §8.1），故经 ReplayKit **Broadcast
Upload Extension**（`LumaBroadcastExtension` target，独立进程）实现。架构「B 方案」——
**扩展仅转发 PCM，转写/翻译/字幕全部留主 App**（扩展 ~50MB 内存上限装不下设备端
`SpeechAnalyzer`+`TranslationSession`，故扩展零 ML）：

```
其他 App 音频 ──(系统广播)──▶ SampleHandler.processSampleBuffer(.audioApp)
  → CMSampleBuffer → AVAudioPCMBuffer → 转 48k mono Float32（AVAudioConverter）
  → SharedAudioRing.write（App Group mmap SPSC 环形缓冲）→ Darwin 通知 .audio
      │  group.com.example.Luma
      ▼
主 App  BroadcastAudioProvider: AudioInputProviding
  → Darwin .audio 唤醒 → SharedAudioRing.read → AVAudioPCMBuffer → AudioChunk
  → AsyncStream<AudioChunk>（现有协议边界，下游零改）
  → SpeechAnalyzerTranscriber → SessionController → CaptionPiPController（PiP 浮窗）
```

要点与文件：
- 共享层 `Shared/`（双 target 成员）：`SharedAudioRing`（mmap 单生产者单消费者环形缓冲，
  monotonic 64-bit 索引 + 内存屏障）、`DarwinNotificationCenter`（`CFNotificationCenter`
  Darwin 通知，跨进程纯唤醒）、`BroadcastShared`（App Group id、规范 PCM 格式、通知名）。
- 扩展 `LumaBroadcastExtension/`：`SampleHandler: RPBroadcastSampleHandler` 只取
  `.audioApp`、丢弃 `.video/.audioMic`；Info.plist `NSExtensionAttributes.RPBroadcastProcessMode
  = RPBroadcastProcessModeSampleBuffer`（缺则被 ASC 拒）；entitlements 含同一 App Group。
- 主 App：`BroadcastAudioProvider`（`AppDependencies.makeAudioProvider` 的 iOS `.systemAudio`
  分支）；UI `BroadcastPickerButton`（`RPSystemBroadcastPickerView`，`preferredExtension`
  直启本扩展、隐藏麦克风按钮）；iOS 选 System Audio 时控制栏显示广播按钮，Start 时自动起 PiP。
- 工程：扩展为 iOS-only target；嵌入相位与依赖加 `platformFilter = ios`，故 macOS 构建不嵌入
  此 appex（三向 build 已验证）。共享类在主 App 默认 `MainActor` 隔离下显式标 `nonisolated`。
- 保活：靠 active PiP（持续渲染字幕帧）+ `.playback` 会话 + `UIBackgroundModes=audio`，
  使主 App 在用户切到其他 App 后仍转写——与现有麦克风+PiP 后台路径同机制。
- 体验：系统广播须用户主动发起、控制中心常驻红条、停止亦需手动（Apple 强制隐私行为）。

**iOS 27 弃用提示**：`RPSystemBroadcastPickerView` / `RPBroadcastSampleHandler` /
`RPSampleBufferType` 在 **iOS 27 SDK 标记 `API_DEPRECATED`**（指向 ScreenCaptureKit）。
但本项目部署目标 iOS **26.0**，弃用版本 27.0 > 26.0，故 iOS 26 上完全受支持、**编译零弃用
警告**。且 ScreenCaptureKit 在 iOS 经真机验证只能录当前 App（research.md §8.1），其跨 App
`excludesCurrentProcessAudio` 又是 `ios(27.0)`，**无法作为 iOS 26 的替代**——故 ReplayKit
广播仍是当前唯一可行路径。未来基线升到 iOS 27 时再评估 ScreenCaptureKit 广播迁移。

**残留风险（待真机验证）**：后台保活是否在用户长时间停留其他 App 时稳定（仅靠 PiP）。
若真机 spike 显示被挂起/降频，启用静音 buffer 保活兜底（`AudioSessionCoordinator` 预留）。
另：用户从控制中心停广播 → provider 结束音频流，但 `SessionController` 不会自动转 idle
（协议无回传），需用户在 App 内点 Stop——已知 UX 小瑕疵。
App Group + appex 真机部署需开发者账号（与 TestFlight 同一阻塞点）；
本地三向 build / macOS 单测 / lint 已全绿，真机端到端待账号就绪。

并发实现要点：`SharedAudioRing` 索引用 `Synchronization.Atomic<UInt64>`（acquire/release）
置于共享映射，免用已弃用的 `OSMemoryBarrier`；`DarwinNotificationCenter` 在最后一个
handler 取消时移除底层 CF observer，避免 start→stop→start 重复注册导致重复触发。
