# Luma — Apple API 查证记录

日期：2026-06-11（WWDC26 当周，macOS 27 beta 1 / Xcode 27 beta 1）

## 证据来源（按权威性排序）

1. **macOS 27.0 SDK `.swiftinterface` / C 头文件**（本机 `/Applications/Xcode-beta.app/.../MacOSX27.0.sdk`）— API 签名与 availability 的最终事实来源。
2. **离线 Apple Developer Documentation**（Xcode 27 组件 10M13306，位于 `/System/Library/AssetsV2/com_apple_MobileAsset_AppleDeveloperDocumentation/`，版本标注 OSVersion 27.0 / XcodeVersion 27.0）— 语义、用法、官方示例代码。
3. **WWDC 2025/2026 公开资料**（网络检索）— 设计方向与背景。

> 标注约定：【已验证-SDK】= 直接读自 swiftinterface/头文件；【已验证-文档】= 读自官方离线文档原文；【网络】= 第三方报道，仅作背景。

## 0. 环境

- 本机 macOS 27.0 (build 26A5353q)。【已验证-SDK】
- Xcode 27.0 beta (27A5194q)，含 `MacOSX27.0.sdk`，路径 `/Applications/Xcode-beta.app`。`xcode-select` 指向 Xcode 26.5，因此构建一律使用 `DEVELOPER_DIR=/Applications/Xcode-beta.app`。【已验证-SDK】
- macOS 27 代号 "Golden Gate"（WWDC26，2026-06-08 发布）。Liquid Glass 增加用户可调透明度滑杆与组合层精化。【网络：9to5Mac、AppleMagazine 等】

## 1. Speech framework（转写主管线）

接口文件：`Speech.swiftmodule/arm64e-apple-macos.swiftinterface`（user-module-version 3600.49.3）。

### macOS 26 基线（@available(anyAppleOS 26)）【已验证-SDK】

- `actor SpeechAnalyzer`：
  - `init(modules:options:)`；`init(inputSequence:modules:options:analysisContext:volatileRangeChangedHandler:)`，inputSequence 为 `AsyncSequence<AnalyzerInput>`。
  - `start(inputSequence:)`、`analyzeSequence(_:)`、`finalize(through:)`、`finalizeAndFinishThroughEndOfInput()`、`cancelAndFinishNow()`、`setModules(_:)`、`prepareToAnalyze(in:)`。
  - `static bestAvailableAudioFormat(compatibleWith:[SpeechModule])`（可加 `considering naturalFormat:`）。
- `SpeechTranscriber: SpeechModule, LocaleDependentSpeechModule`：
  - `init(locale:preset:)` / `init(locale:transcriptionOptions:reportingOptions:attributeOptions:)`。
  - Preset：`.transcription`、`.progressiveTranscription`、`.timeIndexedProgressiveTranscription` 等。
  - `ReportingOption`：`.volatileResults`、`.alternativeTranscriptions`、`.fastResults`。
  - `ResultAttributeOption`：`.audioTimeRange`、`.transcriptionConfidence`。
  - `static isAvailable`、`static supportedLocales`（async）、`static installedLocales`（async）、`supportedLocale(equivalentTo:)`。
  - `results: AsyncSequence<SpeechTranscriber.Result, Error>`；`Result { range: CMTimeRange; resultsFinalizationTime: CMTime; text: AttributedString; alternatives: [AttributedString] }`；`isFinal` 由 `SpeechModuleResult` 协议扩展提供。
- `AnalyzerInput`：`init(buffer: AVAudioPCMBuffer)`、`init(buffer:bufferStartTime: CMTime?)`。
- `AssetInventory`：`status(forModules:) async -> Status`（unsupported/downloading/supported/installed）、`assetInstallationRequest(supporting:) -> AssetInstallationRequest?`（`downloadAndInstall() async throws`、`progress: Progress`）、`reserve(locale:)`、`release(reservedLocale:)`、`maximumReservedLocales`。
- `AnalysisContext`：`contextualStrings`（按 tag）、`userData`。
- `SpeechDetector`（VAD 模块，可选）。
- `SFSpeechError.Code` 新增：`audioDisordered`、`unexpectedAudioFormat`、`noModel`、`assetLocaleNotAllocated`、`insufficientResources` 等。
- 文档明确（离线文档 SpeechAnalyzer 篇）：分析器默认不会自行终止结果流，需调用 `finish` 系列方法。【已验证-文档】

### macOS 27 新增（@available(anyAppleOS 27)）【已验证-SDK】

- **`AnalyzerInputConverter`**：`static converter(compatibleWith modules:) async throws`；`convert(_ buffer: AVAudioBuffer, at: AVAudioTime?) throws -> [AnalyzerInput]`；`flush()`。官方音频格式转换器，取代手写 AVAudioConverter 逻辑。
- **`CaptureInputSequenceProvider`**：`providerWithSession(from: AVCaptureDevice, compatibleWith:)`、`provider(from:in: AVCaptureSession, compatibleWith:)`；`analyzerInputs: AsyncSequence<AnalyzerInput, Error>`。从捕获设备直接产出 analyzer 输入。文档：转换源音频到受支持格式并产出异步输入序列。【已验证-文档】
- **`AssetInputSequenceProvider`**：同上，但源为 `AVAsset`（文件/媒体轨）。
- `AnalyzerInput` 新增 `init(buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>)`、`bufferDuration`、`bufferFormat`；旧 `buffer` 属性在 27 标记 deprecated。
- `SpeechAnalyzer.Options` 新增 `ignoresResourceLimits`。
- `SFSpeechError.Code` 新增 `cannotConfigureAudioSystem`。

### 授权

- SpeechAnalyzer/SpeechTranscriber 文档（含 WWDC25 sample "Bringing advanced speech-to-text capabilities to your app"）**未要求** `SFSpeechRecognizer.requestAuthorization`；该授权流程仅出现在 SFSpeechRecognizer 旧路径文档中。【已验证-文档】结论：仅需麦克风权限（`NSMicrophoneUsageDescription` + `AVCaptureDevice.requestAccess(for: .audio)`）。运行期若遇到异常再回补。

### 结论（转写设计）

- 部署目标即 macOS 26 ⇒ 单一 SpeechAnalyzer 管线覆盖 26/27，无需 SFSpeechRecognizer fallback。
- 音频转换：`#available(macOS 27)` 用 `AnalyzerInputConverter`，否则手动 `AVAudioConverter`（26 fallback，API 稳定可验证）。
- 时间戳：开启 `.audioTimeRange` attribute（或 time-indexed preset），`Result.range` 提供 CMTimeRange，用于 SRT 与延迟估算。

## 2. Translation framework（本机翻译）

接口文件：`Translation.swiftmodule/arm64e-apple-macos.swiftinterface`（user-module-version 380.1）。

### 已验证事实【已验证-SDK】

- `TranslationSession`（macOS 15+）：
  - **`convenience init(installedSource: Locale.Language, target: Locale.Language?)` — macOS 26.0+，程序化创建，无需 SwiftUI**。
  - `init(installedSource:target:preferredStrategy:)` — macOS 26.4+。
  - `Strategy`（macOS 26.4+）：`.highFidelity`（Apple Intelligence 模型，不可用时自动回落 lowLatency）/ `.lowLatency`（传统模型）。【已验证-文档】
  - `translate(_ String) async throws -> Response`、`translate(batch:) -> BatchResponse`（AsyncSequence）、`translations(from:) async throws -> [Response]`、`prepareTranslation()`、`cancel()`（26+）、`isReady`（26+，async）、`canRequestDownloads`（26+）。
  - `Configuration(source:target:)` + `invalidate()`；`Response { sourceText, targetText, clientIdentifier, ... }`。
- `LanguageAvailability`：`supportedLanguages`（async）、`status(from:to:) async -> installed/supported/unsupported`；macOS 26.4+ 可带 `preferredStrategy`。
- `TranslationError`：`unsupportedLanguagePairing`、`nothingToTranslate`、`notInstalled`（26+）、`alreadyCancelled`（26+）等。
- SwiftUI overlay（`_Translation_SwiftUI`）：`.translationTask(_ configuration:action:)`、`.translationTask(source:target:action:)`、27 SDK 中新增带 `preferredStrategy:` 的重载。
- 官方文档明确：**程序化 init 仅适用于已安装语言对；触发模型下载必须经 `.translationTask` 提供的 session**。【已验证-文档】

### 结论（翻译设计）

- 运行期翻译：`TranslationSession(installedSource:target:)`（已安装语言对，主路径，无 SwiftUI 依赖）；`#available(macOS 26.4)` 时加 `preferredStrategy: .lowLatency`。
- 模型下载：保留一个隐藏 SwiftUI bridge view（`.translationTask` + `prepareTranslation()`），仅在 `LanguageAvailability.status == .supported`（未安装）时挂载触发下载。
- 语言对状态用 `LanguageAvailability` 查询，映射到 UI 模型状态指示。

## 3. 系统音频捕获（Core Audio process taps）

头文件：`AudioHardwareTapping.h`、`CATapDescription.h`、`AudioHardware.h`。【已验证-SDK】

- `AudioHardwareCreateProcessTap(CATapDescription*, AudioObjectID*)` / `AudioHardwareDestroyProcessTap` — macOS 14.2+。
- `CATapDescription`：
  - 全局捕获：`initStereoGlobalTapButExcludeProcesses:`（排除列表传空 = 捕获整个系统混音）。
  - 指定进程：`initStereoMixdownOfProcesses:` / mono 变体 / 指定设备+stream 变体。
  - 属性：`processes`、**`bundleIDs`（macOS 26.0+，直接按 bundle ID 指定目标应用）**、`isPrivate`、`isMixdown`、`isMono`、`isExclusive`、`muteBehavior`、`deviceUID`、`processRestoreEnabled`（26.0+）。
- 聚合设备：`AudioHardwareCreateAggregateDevice` + `kAudioAggregateDeviceTapListKey`/`kAudioAggregateDevicePropertyTapList`（'tap#'）、`kAudioAggregateDeviceTapAutoStartKey`；tap UID 经 `kAudioTapPropertyUID` 读取。官方文章含完整 Swift 示例。【已验证-文档】
- 权限：Info.plist 需 `NSAudioCaptureUsageDescription`；首次从含 tap 的聚合设备录音时系统弹「系统音频录制」授权（独立于屏幕录制权限）。【已验证-文档】
- 读取音频：对聚合设备创建 IOProc（`AudioDeviceCreateIOProcID`）拿 PCM buffer。
- 非沙盒应用（本项目决策）无已知额外限制。
- 备选路线（不实现，仅记录）：ScreenCaptureKit `SCStream` 音频捕获，需屏幕录制权限。

## 4. 麦克风输入

- 标准路径（26 基线）：`AVAudioEngine.inputNode` tap → `AVAudioPCMBuffer` → 转换为 `bestAvailableAudioFormat(compatibleWith:)` 要求的格式 → `AnalyzerInput`。【已验证-文档，WWDC25 sample 同路径】
- macOS 27 可选优化：`CaptureInputSequenceProvider`（见 §1）。本项目为统一麦克风/系统音频两条输入源的抽象（都产出 PCM buffer），采用 PCM 统一管线 + `AnalyzerInputConverter`(27)/手动转换(26)；`CaptureInputSequenceProvider` 记录为后续优化项。
- 权限：`NSMicrophoneUsageDescription` + `AVCaptureDevice.authorizationStatus(for: .audio)` / `requestAccess`。

## 5. SwiftUI / 设计语言（macOS 26/27）

- Liquid Glass 核心 API（macOS 26 基线，27 沿用）：`glassEffect(_:in:)`（默认 `Glass.regular`、Capsule 形状）、`Glass.regular.tint(_:).interactive()`、`GlassEffectContainer`（合并多个 glass 形状/morph 过渡）、`glassEffectID`、buttonStyle `.glass`。性能注意：glass 效果有合成开销，避免大量叠加。【已验证-文档】
- macOS 27 SwiftUI 增量（与本项目相关性低，记录备查）【已验证-SDK】：`toolbarMinimizeBehavior`、`toolbarMinimizationSafeAreaAdjustment`、`contentMarginsRemoved`（toolbar）、`GlassButtonStyle` 公开类型、alert/confirmationDialog `LocalizedStringResource` 重载、`onTapGesture(inputKinds:)` 等。无破坏性变化，无新材质层级 API。
- WWDC26 设计方向（背景）：Liquid Glass 透明度用户可调 ⇒ 自绘字幕表面必须尊重 `accessibilityReduceTransparency` / 增加对比度设置，提供实底回退。【网络 + HIG 一贯要求】
- 窗口浮层：SwiftUI 无原生"非激活置顶面板"，字幕 overlay 用 `NSPanel`（`.nonactivatingPanel`、`level = .floating`、`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`）+ `NSHostingView` 桥接（AppKit 长期稳定 API）。

## 6. 构建配置

- `objectVersion 77` pbxproj + `PBXFileSystemSynchronizedRootGroup`（Xcode 16+ 文件系统同步组）：手写工程文件可行且 diff 友好。
- 关键 build settings：`ARCHS = arm64`（Apple Silicon-only）、`MACOSX_DEPLOYMENT_TARGET = 26.0`、`SWIFT_VERSION = 6.0`（严格并发）、`ENABLE_APP_SANDBOX = NO`（用户决策）、`GENERATE_INFOPLIST_FILE = YES` + 附加键（两个 usage description）。
- Info.plist 键：`NSMicrophoneUsageDescription`、`NSAudioCaptureUsageDescription`。不需要 `NSSpeechRecognitionUsageDescription`（见 §1 授权）。

## 7. 未决事项 / 低置信项

| 事项 | 状态 | 缓解 |
|---|---|---|
| SpeechTranscriber 实际是否完全免 Speech 授权 | 文档未要求（中高置信） | 真机 smoke test 验证；若报授权错误则补 requestAuthorization |
| `TranslationSession` 程序化实例的线程/Actor 约束 | 接口未标注 isolation | 包在自有 actor 内串行使用 |
| beta 1 的 SpeechAnalyzer 模型下载在新系统上的稳定性 | 未知 | AssetInventory 状态全程上报 UI；错误透出 |
| `CATapMuteBehavior` 取舍（tap 时是否静音原输出） | 默认不静音 | 用默认 unmuted，后续可做选项 |

## 8. iOS 通用化（iOS 26 基线 + iOS 27 系统音频）

日期：2026-06-14。证据来源：`iPhoneOS27.0.sdk` / `iPhoneSimulator27.0.sdk` 的 swiftinterface 与 ObjC 头文件。

- 转录/翻译核心跨平台【已验证-SDK】：`SpeechAnalyzer` / `SpeechTranscriber` / `AssetInventory` / `AnalyzerInput` 均 `@available(anyAppleOS 26, *)`；`TranslationSession`（含 `Strategy.highFidelity/.lowLatency`）、`LanguageAvailability` 在 iOS 27 SDK 存在。`#available(macOS 26.4, *)` / `#available(macOS 27.0, *)` 已补 `iOS 26.4` / `iOS 27.0`。
- 麦克风【已验证-SDK】：`AVAudioEngine` 跨平台；iOS 启动前需 `AVAudioSession.setCategory(.record, mode: .measurement)` + `setActive(true)`。授权经 `AVCaptureDevice.authorizationStatus/requestAccess(for: .audio)`（双端可用），故 `CapabilityService` 无需改动。
- 系统音频仅 iOS 27+【已验证-SDK】：`SCStreamConfiguration.capturesAudio` / `sampleRate` / `channelCount` / `excludesCurrentProcessAudio`、`SCStreamOutputType.audio`、`SCContentSharingPicker.presentForCurrentApplication()` 皆 `ios(27.0)`。iOS 无 `AudioHardwareCreateProcessTap` / `CATapDescription`（CoreAudio 头文件不含），故 macOS 的 process-tap 路径无法移植。
- iOS 专属/不可用项【已验证-SDK】：`SCContentSharingPickerConfiguration.allowedPickerModes`、`SCRunningApplication`、`SCWindow`、`SCDisplay`、`SCStreamConfiguration.captureMicrophone` 均 `API_UNAVAILABLE(ios)`；picker 配置在 iOS 仅 `showsMicrophoneControl` 可用。
- 编译期纠正的 Swift 名（device SDK 编译验证）：`SCContentSharingPicker.addObserver→add(_:)`、`removeObserver→remove(_:)`、`presentPickerForCurrentApplication()→presentForCurrentApplication()`。
- CMSampleBuffer→PCM【已验证-SDK】：`CMSampleBuffer.withAudioBufferList(...)` + `formatDescription.audioStreamBasicDescription`，复制进新 `AVAudioPCMBuffer`（无 `bufferListNoCopy` init，沿用 macOS `TapIOHandler` 拷贝法）。
- 并发隔离：`SCContentFilter` / `SCStream` 非 Sendable，按 `AppleTranslationProvider` 的 confinement 模式封进 nonisolated `CaptureEngine`，仅 `AsyncStream<AudioChunk>` 等 Sendable 值跨 actor；picker filter 经一次性 `@unchecked Sendable` box 交接（同 `AudioChunk` 规则）。
- **ScreenCaptureKit 仅 device SDK，不在 simulator SDK**【已验证-SDK】：`SCStreamSystemAudioProvider` 用 `#if os(iOS) && !targetEnvironment(simulator)` 门控；simulator 与 iOS 26 回退麦克风。

### 8.1 iOS 27 真机结论（M0 spike 已定性）

**iOS 无法捕获其他 App 的系统音频。** iOS 27 真机实测：`SCContentSharingPicker.
presentForCurrentApplication()` 弹出的是"仅画面 / 画面+麦克风"，`SCStream` 下发的是
**当前 App 自身的屏幕(`RemoteVideoQueue`) + 可选麦克风(`RemoteMicrophoneQueue`)**，
日志为 "stream output NOT found. Dropping frame"（我们只注册了 `.audio` output）。
选麦克风会降级设备自身播放，`stopCapture()` 卡死。即 iOS 的 ScreenCaptureKit 是
**当前 App 屏幕录制**，非系统音频 tap；`capturesAudio` 捕的是本 App 自身音频。

**决策**：iOS 移除 SCStream provider，**改麦克风专用**；系统音频仅 macOS。字幕改走
**Picture in Picture**（`AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:
playbackDelegate:)`，`ios(15.0)`；自绘 `CVPixelBuffer` →
`CMSampleBufferCreateReadyWithImageBuffer` → `AVSampleBufferDisplayLayer`），配
`UIBackgroundModes=audio` + `AVAudioSession.playAndRecord/.mixWithOthers` 实现后台采集、
不打断其他 App 播放、字幕浮于其他 App 之上。

**已实现**：跨 App 系统级音频经 ReplayKit **Broadcast Upload Extension**
（`LumaBroadcastExtension` + App Group，收 `RPSampleBufferTypeAudioApp`）。采「扩展仅转发
PCM、转写/翻译/字幕留主 App」方案，规避扩展 ~50MB 内存上限（扩展零 ML）；字幕复用现有 iOS
PiP，经 `AudioInputProviding` 协议边界（`BroadcastAudioProvider`）接入，下游零改。架构与
文件清单见 `docs/architecture.md` §iOS 系统级音频。残留风险：后台保活（仅靠 PiP）待真机
验证；App Group/appex 真机部署需开发者账号（同 TestFlight 阻塞点）。本地三向 build / macOS
单测（含 `SharedAudioRingTests`）/ lint 全绿。
