# Luma

Real-time captions and on-device translation for **macOS and iOS**. Luma transcribes
microphone audio (and, on macOS, system audio) live with Apple's `SpeechAnalyzer`
pipeline, translates lines with the on-device Translation framework, and shows the
result in a low-distraction caption surface — a floating panel on macOS, a Picture in
Picture window on iOS.

- **Platforms**: macOS 26 (Apple Silicon) and iOS 26+ (iPhone + iPad), `arm64`
- **Deployment targets**: macOS 26.0, iOS 26.0
- **Built with**: Xcode 27 beta / macOS 27 + iOS 27 SDKs; newer APIs are adopted behind
  availability gates (`AnalyzerInputConverter`, translation strategies, …)
- **Privacy**: all speech recognition and translation runs on device; no third-party or
  cloud services

## Features

- Live transcription with volatile (in-progress) and finalized results, including audio
  timestamps, model download status, latency estimate, and permission/error reporting
- **Audio input** (differs by platform — see [Platform differences](#platform-differences)):
  - macOS: microphone via `AVAudioEngine`, **or** system / per-app audio via **Core Audio
    process taps** (needs only the separate "System Audio Recording" permission — *not*
    Screen Recording)
  - iOS: microphone via `AVAudioEngine` (iOS has no public API to capture other apps'
    system audio)
- On-device translation with three presets:
  - **Fast** — re-translates the in-progress line as it changes (low-latency model,
    throttled to bound resource use)
  - **Balanced** — translates each finalized sentence with the low-latency model
  - **Accurate** — translates finalized sentences with the high-fidelity strategy
    (Apple Intelligence when available, macOS 26.4 / iOS 26.4+)
- **Caption surface** (native idiom per platform):
  - macOS: floating, always-on-top `NSPanel` overlay — Liquid Glass / material / solid
    surfaces, draggable and resizable, joins all Spaces and full-screen apps, automatic
    solid fallback when Reduce Transparency is on, VoiceOver live captions
  - iOS: **Picture in Picture** window that floats over other apps and the lock screen and
    keeps updating while Luma is backgrounded; honors the show-original / show-translation
    / font-size settings
- Start / pause / stop / clear; language-pair switching backed by live capability checks
- TXT and SRT export with session-relative timecodes derived from real audio ranges
  (`NSSavePanel` on macOS, document picker on iOS)
- In-app language switching (System / English / 简体中文) with no relaunch, via a string
  catalog and SwiftUI locale environment override
- iPhone + iPad adaptive layout; settings via a dedicated scene on macOS, an in-app sheet
  on iOS
- Customizable transcript font size and translation accent color (applied as app tint)

## Platform differences

| | macOS | iOS (iPhone / iPad) |
|---|---|---|
| Microphone capture | ✅ | ✅ |
| System / other-app audio | ✅ Core Audio process tap | ❌ no public API on iOS |
| Caption surface | Floating `NSPanel` | Picture in Picture |
| Background captioning | window stays up | mic + PiP continue in background |
| Transcript export | `NSSavePanel` | document picker |

> Capturing **other apps'** audio on iOS would require a ReplayKit Broadcast Upload
> Extension; it is tracked as a future TODO (see `docs/architecture.md` §未来 TODO / 路线图),
> not abandoned. iOS Picture in Picture and background audio are device-only capabilities
> (the Simulator can't run PiP).

## Building

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app   # Xcode 27 beta

# macOS
xcodebuild -project Luma.xcodeproj -scheme Luma -destination 'platform=macOS,arch=arm64' build
xcodebuild -project Luma.xcodeproj -scheme Luma -destination 'platform=macOS,arch=arm64' test

# iOS Simulator
xcodebuild -project Luma.xcodeproj -scheme Luma -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project Luma.xcodeproj -scheme Luma -destination 'platform=iOS Simulator,name=iPhone 17' test

# iOS device (compile check without signing)
xcodebuild -project Luma.xcodeproj -scheme Luma -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```

Luma is a single multiplatform target (`SDKROOT = auto`); platform-specific concretions
are gated behind `#if os(...)`. The project file is a hand-written `objectVersion 77`
project using filesystem-synchronized groups, so adding files requires no project edits.
Formatting follows the repo's `.swift-format` (4-space indentation):

```sh
xcrun swift-format lint --recursive Luma/ LumaTests/
```

## Architecture

```
AudioInputProviding ──▶ SpeechAnalyzerTranscriber ──▶ TranscriptEvent
   (PCM AsyncStream)        (Speech, macOS/iOS 26+)     (volatile/finalized)
                                                            │
                                                            ▼
                  SubtitleBuffer ◀── TranslationProviding ◀── SessionController (actor)
                       │                 (Translation)          · dedupe, latency,
                       ▼                                        · serial translation queues
        SessionStore (@MainActor @Observable)
                       │
            ┌──────────┴──────────┐
            ▼                     ▼
       Main window         Caption surface
                           · macOS: NSPanel overlay
                           · iOS:   Picture in Picture
```

Layering is `UI → Domain → Services (protocols) ← Infrastructure`; views never touch
system frameworks directly, and every system service is mockable (see `LumaTests/`).
Swift 6 strict concurrency with MainActor default isolation; non-Sendable framework
types (`TranslationSession`, `LanguageAvailability`) are confined with `@concurrent`
helpers.

Key design notes live in:

| Path | Purpose |
|---|---|
| `docs/research.md` | Verified Apple API research: sources, signatures, confidence levels |
| `docs/architecture.md` | Architecture, data flow, concurrency model, availability strategy, risks |

## Permissions

| Permission | Platform | Why | When prompted |
|---|---|---|---|
| Microphone | macOS + iOS | live transcription | first start with mic input |
| System Audio Recording | macOS only | Core Audio process tap capture | first start with system-audio input |

Speech models and translation language packs are downloaded on demand by the system;
Luma surfaces their status in the Diagnostics tab, where translation model downloads
can also be triggered.

## Known limitations

- macOS 27 / iOS 27 beta / Xcode 27 beta: APIs may change; `docs/research.md` §7 tracks
  low-confidence items
- Model download progress is shown as indeterminate (Progress observation is a TODO)
- Per-app audio capture via `CATapDescription.bundleIDs` (macOS) is experimental on beta
  systems
- iOS cannot caption **other apps'** audio (platform limitation); it captions microphone
  audio, so place the device near the audio source. System-wide capture via a ReplayKit
  Broadcast Upload Extension is a future TODO (`docs/architecture.md` §未来 TODO / 路线图)
- iOS Picture in Picture and background audio are device-only (not available in the
  Simulator) and pending on-device confirmation
- System-provided menu bar items follow the launch language; in-app language switching
  affects Luma's own UI

## License

MIT
