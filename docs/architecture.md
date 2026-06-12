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

## 字幕 overlay

- `NSPanel`：`styleMask [.nonactivatingPanel, .titled→borderless]`、`level .floating`、`collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary]`、`isMovableByWindowBackground`，内容为 `NSHostingView`。
- 表面：默认 Liquid Glass（`glassEffect`），`accessibilityReduceTransparency` 或用户选择时切换实底/material；动态字体；VoiceOver 朗读最新 finalized+译文。

## 延迟指标

`now - (sessionAudioStart + segment.range.end)` ≈ 端到端字幕延迟（音频末端到显示）；volatile 与 finalized 分别统计，状态栏显示滑动平均。

## 导出

- TXT：finalized 原文 +（可选）译文逐行。
- SRT：`SRTFormatter`（纯函数，可单测）以 segment `range` 生成 session-relative timecode；条目 = finalized segment（含译文时双语行）。

## 风险

见 research.md §7。系统音频 provider（M9）失败不影响麦克风主管线；翻译不可用不影响转写显示。
