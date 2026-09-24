# Inscribe

[![Swift](https://img.shields.io/badge/Swift-6.2+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-iOS%2026%20%7C%20macOS%2026-blue.svg)](https://developer.apple.com)

> **Hold the Globe key, talk, and the words appear where your cursor is. Meetings get transcribed and split by speaker. Nothing leaves your Mac.**

Inscribe is a dictation tool for macOS. Transcription runs on Apple's SpeechTranscriber, text cleanup on Apple's Foundation Models, and speaker separation on CoreML models that run locally.

## System Requirements

- **macOS 26 or newer** — the app is macOS-first; the iOS target builds but has no dictation hotkey
- **Xcode 26** with the Swift 6.2+ toolchain

## Permissions

macOS gates most of what makes this work, and it will not prompt twice:

| Permission | Needed for | Without it |
|---|---|---|
| **Accessibility** | the Globe key, and typing into other apps | no hotkey, no insertion |
| **Microphone** | recording | nothing at all |
| **Speech Recognition** | transcription | nothing at all |
| **System audio** | recording the other half of a call | meetings hear only you |

The macOS target ships **unsandboxed**, deliberately. macOS never grants Accessibility trust to a sandboxed process, so a sandboxed build could neither read the Globe key nor type into another app. That rules out Mac App Store distribution.

Set **System Settings → Keyboard → "Press 🌐 to"** to *Do Nothing*, or macOS will switch your input source every time you dictate.

## Dictation

- **Hold the Globe key to talk**, or press once to start and again to stop — both are settings. Escape discards a recording.
- **Types into whatever text field has focus**, falling back to the clipboard when there isn't one. Optionally presses Return afterwards, or Shift+Return so chat apps add a line break instead of sending.
- **Undo** takes back the last insertion and puts the text on your clipboard.
- **History** keeps recent dictations, so one that lands in the wrong window is recoverable.
- **Per-app profiles** override the prompt and output behaviour based on which app you were in when you started talking.
- **Spoken punctuation** ("period", "new line"), **word replacements** for terms the recognizer mishears, and **vocabulary hints** that steer what it listens for.
- **A floating panel** shows the words as they arrive.

## Meetings

- **Speaker separation** using pyannote and WeSpeaker CoreML models, attributing text by timestamp rather than guesswork.
- **System audio capture** records the far side of a call alongside your microphone, through a Core Audio process tap bound to your mic in one aggregate device.
- **The recording is kept**, so any timestamp plays back — which is how you check whether an attribution is right.
- **Correct attribution by hand**: reassign a line, merge two speakers who are one person, or split a line the diarizer ran together.
- **Pause and resume**, with each session offset onto the meeting's own clock.
- **Import an existing recording** and run it through the same pipeline.
- **Export** to Markdown or plain text, with an optional on-device AI summary.

## AI Processing

Apple's Foundation Models rewrite the transcript using a prompt you choose — clean up, summarize, formalize, and others, plus your own with independent generation settings.

Optionally the model is also shown the text already in the field you are dictating into, fenced as context to read but not rewrite, so a dictated reply matches the thread above it.

## Privacy

Everything runs on-device. Audio and text are never uploaded.

Two network calls exist, both about models rather than your data:

- Apple downloads its speech model through `AssetInventory` on first use.
- FluidAudio downloads the CoreML speaker models on your first meeting, and Inscribe verifies them against the content hashes HuggingFace publishes — SHA-256 for weights, git blob hashes for the rest.

Dictation history stores what you dictate in plain text on this Mac. It is a setting, and it can be switched off.

## Building

```bash
xcodebuild -project Inscribe.xcodeproj -scheme Inscribe -destination 'platform=macOS' build
```

## Architecture

```
Inscribe/
├── ScribeApp.swift                  # Entry point, SwiftData container, scenes
│
├── Models/                          # SwiftData
│   ├── Meeting.swift                # Meeting, Utterance, MeetingSpeaker
│   ├── MeetingCorrections.swift     # Reassign, merge, split
│   ├── MeetingSchema.swift          # Versioned schema and migration plan
│   └── Dictation.swift              # History entries
│
├── Services/
│   ├── GlobalHotkeyMonitor.swift    # CGEventTap: Globe key, push-to-talk, undo
│   ├── TextInsertionService.swift   # Focused-field detection and insertion
│   ├── AccessibilityPermission.swift
│   ├── RecordingCoordinator.swift   # One dictation, start to delivery
│   ├── TranscriptionEngine.swift    # SpeechAnalyzer streaming pipeline
│   ├── AIProcessor.swift            # Foundation Models
│   ├── TextProcessor.swift          # Spoken punctuation, replacements
│   ├── MeetingRecorder.swift        # One meeting, start to saved
│   ├── MeetingDiarizer.swift        # Chunked FluidAudio diarization
│   ├── SpeakerAlignment.swift       # Timestamp-based attribution
│   ├── SystemAudioCapture.swift     # Core Audio process tap + aggregate
│   ├── MeetingAudioStore.swift      # Recording storage
│   ├── MeetingPlayer.swift          # Playback
│   ├── MeetingExporter.swift        # Markdown and plain text
│   ├── FileTranscriber.swift        # Existing audio and video files
│   ├── DiarizationModelStore.swift  # Model verification and updates
│   ├── DictationHistory.swift
│   ├── AudioCaptureHelper.swift     # AVAudioEngine capture
│   ├── AudioDeviceCatalog.swift     # Input device enumeration
│   └── AppSettings.swift            # Preferences
│
└── Views/
    ├── MenuBarView.swift
    ├── SettingsView.swift
    ├── MeetingsView.swift           # Browse, correct, export
    ├── DictationHistoryView.swift
    ├── ImportRecordingView.swift
    └── DictationOverlay.swift       # Floating live panel
```

## Dependencies

| Dependency | Purpose |
|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Speaker diarization CoreML models |

Everything else is Apple's: SwiftUI, SwiftData, Speech, AVFoundation, CoreAudio, FoundationModels, ApplicationServices, AppIntents.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

Originally derived from [Swift Scribe](https://github.com/seamlesscompute/swift-scribe) by seamlesscompute (MIT). Dictation and meeting features are modelled on [voxtype](https://github.com/peteonrails/voxtype).

- **Apple WWDC 2025** — SpeechAnalyzer, Foundation Models, and Rich Text editing sessions
- **[FluidAudio](https://github.com/FluidInference/FluidAudio)** — speaker diarization models
