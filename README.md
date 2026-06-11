# Luma

Real-time captions and on-device translation for macOS. Luma transcribes microphone or
system audio live with Apple's `SpeechAnalyzer` pipeline, translates finalized lines with
the on-device Translation framework, and shows the result in a low-distraction floating
subtitle overlay.

- **Platform**: Apple Silicon only (`arm64`)
- **Deployment target**: macOS 26.0
- **Built with**: Xcode 27 beta / macOS 27 SDK; macOS 27 APIs are adopted behind
  availability gates (`AnalyzerInputConverter`, translation strategies, …)
- **Privacy**: all speech recognition and translation runs on device; no third-party or
  cloud services

## Features (target scope)

- Live microphone transcription (volatile + finalized results with audio timestamps)
- Optional system-audio / per-app capture via Core Audio process taps
  (requires the separate "System Audio Recording" permission, *not* Screen Recording)
- On-device translation of finalized segments only, with language-pair availability
  checks and model-download handling
- Floating, always-on-top subtitle overlay honoring Reduce Transparency / contrast
  settings
- Start / pause / stop / clear, language switching, TXT and SRT export

## Building

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app
xcodebuild -project Luma.xcodeproj -scheme Luma -destination 'platform=macOS,arch=arm64' build
```

## Repository layout

| Path | Purpose |
|---|---|
| `Luma/` | App sources (App / UI / Domain / Services / Infrastructure) |
| `LumaTests/` | Unit tests and mock services |
| `docs/research.md` | Verified Apple API research (sources + confidence levels) |
| `docs/architecture.md` | Architecture, data flow, availability strategy, risks |

## Permissions

| Permission | Why | When prompted |
|---|---|---|
| Microphone | live transcription | first start with mic input |
| System Audio Recording | Core Audio process tap capture | first start with system-audio input |

Speech models and translation language packs are downloaded on demand by the system;
Luma surfaces their status in the UI.
