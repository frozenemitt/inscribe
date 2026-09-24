import Foundation
import os
import AVFoundation
import FluidAudio

/// One stretch of audio attributed to one speaker.
struct SpeakerTurn: Sendable, Equatable {
    /// The diarizer's own identifier, stable across chunks within a meeting.
    let speakerId: String
    let start: TimeInterval
    let end: TimeInterval

    /// How confident the diarizer is, 0–1. Low scores usually mean crosstalk.
    let quality: Float

    func covers(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

/// Speaker diarization over a live meeting, using FluidAudio's CoreML models.
///
/// An actor rather than a class: `performCompleteDiarization` is synchronous and
/// CPU-bound, and running it on the main actor would stall the UI for the length of
/// every chunk.
///
/// Audio is processed in fixed chunks rather than accumulated and handled at the end.
/// An hour of 16 kHz mono float is roughly 230 MB, and a single inference over all of
/// it would leave the user staring at a spinner once the meeting was already over.
/// `SpeakerManager` inside `DiarizerManager` carries speaker identity across chunks,
/// so someone who speaks at 00:02 and again at 45:00 keeps the same id.
actor MeetingDiarizer {

    // MARK: - Configuration

    /// Seconds of audio per inference pass.
    ///
    /// Long enough for the clustering to have something to work with, short enough
    /// that memory stays flat and results appear during the meeting.
    private static let chunkSeconds: TimeInterval = 30

    /// What FluidAudio's models expect.
    static let sampleRate = 16_000

    private var chunkSampleCount: Int { Int(Self.chunkSeconds) * Self.sampleRate }

    // MARK: - State

    private var manager: DiarizerManager?
    private var pending: [Float] = []

    /// Audio already handed to the diarizer, so each chunk is stamped with its real
    /// position in the meeting rather than restarting at zero.
    private var processedSeconds: TimeInterval = 0

    /// Total audio handed to this diarizer, processed or still pending.
    ///
    /// The meeting's master clock. Segment timestamps are stamped against it, so a
    /// resumed session must offset its transcript by this value or the two analyses
    /// stop describing the same moment.
    private(set) var receivedSeconds: TimeInterval = 0

    private(set) var turns: [SpeakerTurn] = []
    private(set) var lastError: String?

    var isReady: Bool { manager != nil }

    // MARK: - Lifecycle

    /// Load the CoreML models from disk.
    ///
    /// Throws when they are not installed rather than fetching them: a meeting is the
    /// wrong moment to start a download, and the recording path stays offline.
    ///
    /// The download is a one-off, the same shape as the speech model Apple's
    /// transcriber fetches on first use. Everything after it runs on-device.
    func prepare() async throws {
        guard manager == nil else { return }

        // Checked first so `downloadIfNeeded` finds the files already there and loads
        // them from disk. Starting a meeting must not reach the network: the models are
        // installed from Settings, deliberately, before any of this runs.
        guard DiarizationModelStore.isInstalled else {
            throw DiarizationModelStore.ModelStoreError.notInstalled
        }

        let models = try await DiarizerModels.downloadIfNeeded()

        let manager = DiarizerManager(config: .default)
        manager.initialize(models: models)

        self.manager = manager
        pending.removeAll()
        processedSeconds = 0
        receivedSeconds = 0
        turns.removeAll()
        lastError = nil
        Log.diarization.notice("Ready")
    }

    /// Add newly captured audio, processing a chunk whenever enough has arrived.
    func append(_ samples: [Float]) async {
        guard manager != nil else { return }
        pending.append(contentsOf: samples)
        receivedSeconds += Double(samples.count) / Double(Self.sampleRate)

        while pending.count >= chunkSampleCount {
            let chunk = Array(pending.prefix(chunkSampleCount))
            pending.removeFirst(chunkSampleCount)
            await process(chunk)
        }
    }

    /// Process whatever is left and return the complete set of turns.
    func finish() async -> [SpeakerTurn] {
        // A trailing fragment shorter than minSpeechDuration cannot be diarized, and
        // asking anyway just logs an error.
        let minimumSamples = Self.sampleRate
        if pending.count >= minimumSamples {
            let chunk = pending
            pending.removeAll()
            await process(chunk)
        } else {
            pending.removeAll()
        }

        return turns.sorted { $0.start < $1.start }
    }

    /// Diarize a complete recording in one pass.
    ///
    /// For imported files, where the whole thing is already on disk and there is no
    /// live timeline to keep up with.
    func diarizeWholeRecording(_ samples: [Float]) async -> [SpeakerTurn] {
        guard manager != nil else { return [] }

        pending.removeAll()
        processedSeconds = 0
        receivedSeconds = 0
        turns.removeAll()

        // Chunked exactly as live capture is, so memory stays flat on a long file.
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSampleCount, samples.count)
            await process(Array(samples[offset..<end]))
            offset = end
        }

        return turns.sorted { $0.start < $1.start }
    }

    func reset() {
        manager?.cleanup()
        manager = nil
        pending.removeAll()
        processedSeconds = 0
        receivedSeconds = 0
        turns.removeAll()
        lastError = nil
    }

    // MARK: - Inference

    private func process(_ samples: [Float]) async {
        guard let manager else { return }

        let offset = processedSeconds
        processedSeconds += Double(samples.count) / Double(Self.sampleRate)

        do {
            let result = try manager.performCompleteDiarization(
                samples,
                sampleRate: Self.sampleRate,
                atTime: offset
            )

            let new = result.segments.map { segment in
                SpeakerTurn(
                    speakerId: segment.speakerId,
                    start: TimeInterval(segment.startTimeSeconds),
                    end: TimeInterval(segment.endTimeSeconds),
                    quality: segment.qualityScore
                )
            }

            turns.append(contentsOf: new)
            Log.diarization.notice("Chunk at \(Int(offset), privacy: .public)s produced \(new.count, privacy: .public) turns")
        } catch {
            // One bad chunk should not end the meeting; the transcript still stands,
            // it just loses speaker labels for that stretch.
            lastError = error.localizedDescription
            Log.diarization.error("Chunk at \(Int(offset), privacy: .public)s failed: \(error, privacy: .public)")
        }
    }
}

// MARK: - File Reading

/// Reads a whole audio file as the mono float the diarizer expects.
///
/// Lets an already-recorded meeting be speaker-separated on import, not just one
/// captured live.
enum AudioFileSamples {

    /// Decode `url` to 16 kHz mono float, resampling whatever it holds.
    static func read(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(MeetingDiarizer.sampleRate),
            channels: 1,
            interleaved: false
        ) else { throw AudioFileError.unsupportedFormat }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw AudioFileError.unsupportedFormat
        }
        // Mixed to mono rather than remapped, which keeps only the first channel: a
        // call recorded with each side on its own channel would lose one side.
        converter.downmix = true

        // Read in chunks so an hour-long file does not arrive as one enormous buffer.
        let framesPerChunk: AVAudioFrameCount = 1 << 16
        var samples: [Float] = []
        var finished = false

        while !finished {
            let ratio = target.sampleRate / file.processingFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(framesPerChunk) * ratio) + 1024

            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw AudioFileError.unsupportedFormat
            }

            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard let input = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: framesPerChunk
                ) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                do {
                    try file.read(into: input, frameCount: framesPerChunk)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                if input.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                inputStatus.pointee = .haveData
                return input
            }

            if let conversionError { throw conversionError }
            if status == .endOfStream || output.frameLength == 0 { finished = true }

            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
        }

        return samples
    }

    enum AudioFileError: LocalizedError {
        case unsupportedFormat
        var errorDescription: String? { "That audio format could not be read." }
    }
}

// MARK: - Audio Conversion

/// Resamples microphone buffers to the 16 kHz mono float the diarizer expects.
///
/// Separate from the actor because conversion happens on the audio thread, where
/// hopping to an actor per buffer would be wasteful.
final class DiarizationAudioConverter: @unchecked Sendable {

    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init?() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(MeetingDiarizer.sampleRate),
            channels: 1,
            interleaved: false
        ) else { return nil }
        self.targetFormat = format
    }

    /// Convert one buffer, rebuilding the converter if the input format changed.
    func floats(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let inputFormat = buffer.format

        if converter == nil || sourceFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            // Mixed, not remapped. Without this the converter keeps channel 0 and drops
            // the rest, and with system audio on, channel 0 is the microphone: the
            // diarizer never heard anyone on the call.
            converter?.downmix = true
            sourceFormat = inputFormat
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024

        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?

        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard conversionError == nil,
              output.frameLength > 0,
              let channel = output.floatChannelData?[0] else {
            return nil
        }

        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
