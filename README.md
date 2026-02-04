# Inscribe

[![Swift](https://img.shields.io/badge/Swift-6.2+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-iOS%2026%20%7C%20macOS%2026-blue.svg)](https://developer.apple.com)

> **Real-time voice transcription with on-device AI processing, speaker diarization, and intelligent note-taking — completely private, completely offline.**

Inscribe uses Apple's Foundation Models framework and SpeechTranscriber to deliver fast, accurate transcription that never leaves your device.

## System Requirements

- **iOS 26 Beta or newer** (will not work on iOS 25 or earlier)
- **macOS 26 Beta or newer** (will not work on macOS 25 or earlier)
- **Xcode Beta** with Swift 6.2+ toolchain
- **Apple Developer Account** with beta access

## Getting Started

1. **Clone the repository:**

   ```bash
   git clone https://github.com/frozenemitt/inscribe.git
   cd inscribe
   ```

2. **Open in Xcode Beta:**

   ```bash
   open Inscribe.xcodeproj
   ```

3. **Configure deployment targets** for iOS 26 Beta / macOS 26 Beta or newer.

4. **Build and run** using Xcode Beta with the Swift 6.2+ toolchain.

## Features

### Transcription
- **Real-time speech-to-text** — Streaming transcription powered by Apple's SpeechTranscriber and SpeechAnalyzer APIs, with live volatile and finalized text
- **Speaker diarization** — Identify and label different speakers via FluidAudio integration

### On-Device AI
- **AI-powered text processing** — Clean up, summarize, formalize, casualize, or fix punctuation on transcriptions using Apple's Foundation Models framework
- **Customizable prompts** — Six built-in prompts plus unlimited custom prompts, each with independent generation settings (temperature, sampling mode, max tokens)
- **Structured output** — Uses the `@Generable` macro to enforce consistent AI responses
- **iCloud-synced prompts** — Custom prompts sync across devices via iCloud key-value storage

### Platform Integration
- **macOS menu bar app** — Persistent menu bar icon with quick-access dropdown for recording and prompt selection
- **Global hotkey** (macOS) — System-wide keyboard shortcut to start/stop recording from any app (default: `⌃⌥⌘C`)
- **Siri & Shortcuts** — App Intents for quick transcription, timed recording, and start/stop control
- **Live Activities** (iOS) — Lock screen and Dynamic Island display showing recording status, elapsed time, and character count
- **Auto-copy to clipboard** — Transcription results automatically copied after processing

### User Experience
- **Audio feedback** — System sounds for recording start, stop, completion, and errors
- **System notifications** — Optional alerts when transcription and AI processing complete
- **Cross-platform** — Native SwiftUI interface on both iOS and macOS with platform-specific adaptations

### Privacy
- **Completely offline** — All transcription and AI processing happens on-device
- **No network calls** — Audio and text never leave your device
- **Minimal permissions** — Only microphone access and speech recognition authorization required

## Architecture

```
Scribe/
├── ScribeApp.swift                    # App entry point, SwiftData container setup
├── Info.plist                         # Privacy usage descriptions
│
├── Services/
│   ├── TranscriptionEngine.swift      # SpeechTranscriber/SpeechAnalyzer streaming pipeline
│   ├── AIProcessor.swift              # Foundation Models text processing with @Generable
│   ├── AppSettings.swift              # @Observable user preferences (UserDefaults)
│   ├── PromptConfiguration.swift      # Built-in + custom prompt management, iCloud sync
│   ├── AudioCaptureHelper.swift       # AVAudioEngine microphone capture (AsyncStream)
│   ├── AudioFeedbackService.swift     # System sounds and haptic feedback
│   ├── ClipboardService.swift         # Cross-platform clipboard abstraction
│   ├── HotkeyService.swift            # macOS global hotkey via Carbon framework
│   ├── LiveActivityManager.swift      # iOS ActivityKit live activities
│   ├── DiarizationManager.swift       # Speaker diarization (FluidAudio)
│   └── AppIntents.swift               # Siri Shortcuts integration
│
├── Transcription/
│   └── Memo.swift                     # SwiftData models (Memo, SpeakerSegment)
│
├── Views/
│   ├── MenuBarView.swift              # macOS menu bar interface
│   └── SettingsView.swift             # Settings UI (iOS & macOS)
│
└── Helpers/
    ├── FoundationModelsHelper.swift   # AI session management and language support
    ├── BufferConversion.swift         # Float32 → Int16 audio format conversion
    └── Helpers.swift                  # General utilities
```

## How It Works

1. **Record** — Tap the mic button, use the global hotkey (macOS), or trigger via Siri. Audio streams through `AVAudioEngine` and feeds into Apple's `SpeechAnalyzer`.
2. **Transcribe** — Live results appear as you speak: volatile (unconfirmed) text updates in real-time, finalized text commits when the speech engine detects pauses.
3. **Process** — If AI is enabled, the finalized transcript is sent to Apple's on-device Foundation Models with your selected prompt. Structured output via `@Generable` ensures clean results.
4. **Output** — The result is copied to your clipboard, with optional audio feedback and system notifications.

## Dependencies

| Dependency | Purpose |
|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Speaker diarization and voice identification |

All other functionality uses Apple first-party frameworks: SwiftUI, SwiftData, Speech, AVFoundation, FoundationModels, ActivityKit, AppIntents, and Carbon.

## License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

## Acknowledgments

Originally inspired by [Swift Scribe](https://github.com/seamlesscompute/swift-scribe) by seamlesscompute, licensed under MIT.

- **Apple WWDC 2025** — SpeechAnalyzer, Foundation Models, and Rich Text editing sessions
- **[FluidAudio](https://github.com/FluidInference/FluidAudio)** — Speaker diarization and voice identification
