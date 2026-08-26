import Foundation
import AVFoundation
import os

/// Writes a meeting's audio to disk and finds it again later.
///
/// Audio used to be discarded the moment a meeting ended, which left the speaker
/// corrections unverifiable: told that Speaker 2 said something, you had no way to
/// check. Keeping the recording also means a meeting can be re-diarized after a model
/// update instead of being stuck with whatever the old one decided.
///
/// Written as AAC, not the raw float the engine hands over. An hour of 48 kHz stereo
/// float is about 1.4 GB; the same hour as AAC is around 30 MB, and speech survives
/// the compression well enough for a human listening back.
final class MeetingAudioStore {

    private static let log = Logger(subsystem: "com.inscribe.app", category: "MeetingAudio")

    /// Where recordings live, alongside the meeting database.
    static var directory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inscribe/MeetingAudio", isDirectory: true)

        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func url(forFileNamed name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func fileExists(named name: String?) -> Bool {
        guard let name else { return false }
        return FileManager.default.fileExists(atPath: url(forFileNamed: name).path)
    }

    static func delete(fileNamed name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: url(forFileNamed: name))
    }

    static func size(ofFileNamed name: String?) -> Int64 {
        guard let name else { return 0 }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url(forFileNamed: name).path)
        return (attributes?[.size] as? Int64) ?? 0
    }

    /// Total disk used by every saved recording.
    static func totalSize() -> Int64 {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []

        return contents.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func formatted(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Appends live audio to one file for the length of a meeting.
///
/// Deliberately not closed when the user pauses: `AVAudioFile` cannot reopen a file to
/// append, so closing on pause would leave a meeting split across several recordings
/// whose timestamps no longer line up with the transcript.
final class MeetingAudioWriter: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.inscribe.app", category: "MeetingAudio")

    private var file: AVAudioFile?
    private let lock = NSLock()

    private(set) var fileName: String?

    /// Begin a recording, returning the file name to store on the meeting.
    func begin() -> String {
        let name = "\(UUID().uuidString).m4a"
        fileName = name
        file = nil
        return name
    }

    /// Write a buffer, opening the file on the first one.
    ///
    /// Opened lazily because the engine's format is only known once audio arrives, and
    /// it varies with the input device — a meeting using the system-audio aggregate has
    /// a different channel count from one using the built-in microphone.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard let fileName else { return }

        if file == nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: buffer.format.sampleRate,
                AVNumberOfChannelsKey: min(buffer.format.channelCount, 2),
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]

            do {
                file = try AVAudioFile(
                    forWriting: MeetingAudioStore.url(forFileNamed: fileName),
                    settings: settings
                )
            } catch {
                Self.log.error("Could not open the recording file: \(error, privacy: .public)")
                self.fileName = nil
                return
            }
        }

        do {
            try file?.write(from: buffer)
        } catch {
            // One bad buffer should not end the meeting; the transcript is unaffected.
            Self.log.error("Dropped a buffer: \(error, privacy: .public)")
        }
    }

    /// Close the file and report what was written.
    @discardableResult
    func finish() -> String? {
        lock.lock()
        defer { lock.unlock() }

        let name = fileName
        file = nil
        fileName = nil

        // Nothing was ever written — do not leave a name pointing at a missing file.
        guard let name, MeetingAudioStore.fileExists(named: name) else { return nil }
        return name
    }

    /// Abandon the recording and remove the partial file.
    func discard() {
        lock.lock()
        defer { lock.unlock() }

        let name = fileName
        file = nil
        fileName = nil
        MeetingAudioStore.delete(fileNamed: name)
    }
}
