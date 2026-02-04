# CLAUDE.md

## Git Workflow

Never commit directly to `main`. Always use feature branches, then merge locally and push. No PRs — this overrides the global CLAUDE.md PR requirement.

## Build Commands

```bash
# Build for macOS
xcodebuild -project Inscribe.xcodeproj -scheme Inscribe -destination 'platform=macOS' build

# Clean build
xcodebuild clean -project Inscribe.xcodeproj -scheme Inscribe
```

## Constraints

- **Minimum targets**: iOS 26 / macOS 26 — use only APIs available on these platforms
- **Fully offline**: No network calls. All processing (transcription, AI, diarization) is on-device
- **Privacy first**: Never send user data to external servers
