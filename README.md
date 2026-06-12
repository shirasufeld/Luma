# Luma

Real-time captions and on-device translation for macOS. Luma transcribes microphone or
system audio live with Apple's `SpeechAnalyzer` pipeline, translates lines with the
on-device Translation framework, and shows the result in a low-distraction floating
subtitle overlay.

- **Platform**: Apple Silicon only (`arm64`)
- **Deployment target**: macOS 26.0
- **Built with**: Xcode 27 beta / macOS 27 SDK; macOS 27 APIs are adopted behind
  availability gates (`AnalyzerInputConverter`, translation strategies, …)
- **Privacy**: all speech recognition and translation runs on device; no third-party or
  cloud services

## Features

- Live transcription with volatile (in-progress) and finalized results, including audio
  timestamps, model download status, latency estimate, and permission/error reporting
- Microphone input via `AVAudioEngine`, or system / per-app audio via **Core Audio
  process taps** (needs only the separate "System Audio Recording" permission — *not*
  Screen Recording)
- On-device translation with three presets:
  - **Fast** — re-translates the in-progress line as it changes (low-latency model,
    throttled to bound resource use)
  - **Balanced** — translates each finalized sentence with the low-latency model
  - **Accurate** — translates finalized sentences with the high-fidelity strategy
    (Apple Intelligence when available, macOS 26.4+)
- Floating, always-on-top caption overlay: Liquid Glass / material / solid surfaces,
  draggable and resizable, joins all Spaces and full-screen apps, automatic solid
  fallback when Reduce Transparency is on, VoiceOver live captions
- Start / pause / stop / clear; language-pair switching backed by live capability checks
- TXT and SRT export with session-relative timecodes derived from real audio ranges
- In-app language switching (System / English / 简体中文) with no relaunch, via a string
  catalog and SwiftUI locale environment override
- Customizable transcript font size and translation accent color (applied as app tint)

## Building

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app   # Xcode 27 beta
xcodebuild -project Luma.xcodeproj -scheme Luma -destination 'platform=macOS,arch=arm64' build
xcodebuild -project Luma.xcodeproj -scheme Luma -destination 'platform=macOS,arch=arm64' test
```

The project file is a hand-written `objectVersion 77` project using filesystem-
synchronized groups, so adding files requires no project edits. Formatting follows the
repo's `.swift-format` (4-space indentation):

```sh
xcrun swift-format lint --recursive Luma/ LumaTests/
```

## Architecture

```
AudioInputProviding ──▶ SpeechAnalyzerTranscriber ──▶ TranscriptEvent
   (PCM AsyncStream)        (Speech, macOS 26+)        (volatile/finalized)
                                                            │
                                                            ▼
                  SubtitleBuffer ◀── TranslationProviding ◀── SessionController (actor)
                       │                 (Translation)          · dedupe, latency,
                       ▼                                        · serial translation queues
        SessionStore (@MainActor @Observable)
                       │
            ┌──────────┴──────────┐
            ▼                     ▼
       Main window         Subtitle overlay (NSPanel)
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

| Permission | Why | When prompted |
|---|---|---|
| Microphone | live transcription | first start with mic input |
| System Audio Recording | Core Audio process tap capture | first start with system-audio input |

Speech models and translation language packs are downloaded on demand by the system;
Luma surfaces their status in the Diagnostics tab, where translation model downloads
can also be triggered.

## Known limitations

- macOS 27 beta 1 / Xcode 27 beta: APIs may change; `docs/research.md` §7 tracks
  low-confidence items
- Model download progress is shown as indeterminate (Progress observation is a TODO)
- Per-app audio capture via `CATapDescription.bundleIDs` is experimental on beta systems
- System-provided menu bar items follow the launch language; in-app language switching
  affects Luma's own UI

## License

MIT
