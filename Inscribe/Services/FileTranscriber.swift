import Foundation
import AVFoundation
import Speech
import Observation
import os

/// Transcribes an audio or video file already on disk.
///
/// The whole pipeline already existed for the microphone; this feeds it a file instead.
/// `SpeechAnalyzer` reads one directly, so the audio is never routed through the engine
/// — which also means it runs faster than real time rather than taking an hour to read
/// an hour.
@MainActor
@Observable
final class FileTranscriber {

    private static let log = Logger(subsystem: "com.inscribe.app", category: "FileTranscribe")

    /// Everything `AVFoundation` will open, so a video file works as well as audio.
    static let supportedExtensions = [
        "wav", "mp3", "m4a", "aac", "aiff", "aif", "caf", "flac",
        "mp4", "mov", "m4v"
    ]

    enum State: Equatable {
        case idle
        case transcribing(fileName: String)
        case finished
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var transcript = ""
    private(set) var timedSegments: [TimedTranscriptSegment] = []

    var isBusy: Bool {
        if case .transcribing = state { return true }
        return false
    }

    // MARK: - Transcription

    /// Read a file and return its transcript.
    ///
    /// - Parameter contextualStrings: Vocabulary hints, same as live dictation.
    @discardableResult
    func transcribe(fileURL: URL, contextualStrings: [String] = []) async throws -> String {
        guard !isBusy else { throw FileTranscriberError.alreadyRunning }

        state = .transcribing(fileName: fileURL.lastPathComponent)
        transcript = ""
        timedSegments = []

        // A security-scoped URL from the open panel needs this to stay readable.
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }

        do {
            let audioFile = try AVAudioFile(forReading: fileURL)

            let transcriber = SpeechTranscriber(
                locale: TranscriptionEngine.defaultLocale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )

            // Same asset the live path uses; already installed after any dictation.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }

            let context = AnalysisContext()
            let hints = contextualStrings.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !hints.isEmpty {
                context.contextualStrings[.general] = hints
            }

            let analyzer = try await SpeechAnalyzer(
                inputAudioFile: audioFile,
                modules: [transcriber],
                analysisContext: context,
                finishAfterFile: true
            )

            var collected = ""
            var segments: [TimedTranscriptSegment] = []

            for try await result in transcriber.results where result.isFinal {
                collected += String(result.text.characters)

                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let piece = String(result.text[run.range].characters)
                    guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                    segments.append(TimedTranscriptSegment(
                        text: piece,
                        start: range.start.seconds,
                        end: range.end.seconds
                    ))
                }
            }

            try await analyzer.finalizeAndFinishThroughEndOfInput()

            transcript = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            timedSegments = segments
            state = .finished

            Self.log.notice("Transcribed \(fileURL.lastPathComponent, privacy: .public): \(collected.count) characters")
            return transcript

        } catch {
            state = .failed(error.localizedDescription)
            Self.log.error("Failed on \(fileURL.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            throw error
        }
    }

    func reset() {
        state = .idle
        transcript = ""
        timedSegments = []
    }
}

enum FileTranscriberError: LocalizedError {
    case alreadyRunning
    case unsupportedFile

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "A file is already being transcribed."
        case .unsupportedFile: "That file type cannot be read."
        }
    }
}
