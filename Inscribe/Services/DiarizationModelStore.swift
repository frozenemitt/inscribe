import Foundation
import FluidAudio
import CryptoKit

#if os(macOS)

/// What the HuggingFace repository currently holds.
struct RemoteModelRevision: Sendable, Equatable {
    /// Commit hash of the repository head.
    let revision: String
    let lastModified: Date?

    /// Every file the repository publishes, keyed by its path.
    var files: [String: RemoteFile] = [:]
}

/// One published file, with whatever HuggingFace states about its contents.
struct RemoteFile: Sendable, Equatable {
    let path: String
    let size: Int

    /// Git blob hash: `sha1("blob <size>\0" + contents)`. Published for every file.
    let blobId: String?

    /// Plain SHA-256 of the contents. Published for LFS files — the model weights.
    let sha256: String?
}

/// What checking the installed files actually established.
struct VerificationReport: Sendable, Equatable {
    /// Files whose hash matched the published one.
    var verified: Int = 0

    /// Files whose contents disagree with the published copy.
    var mismatched: [String] = []

    /// Files the repository does not list — FluidAudio writes some of its own.
    var unlisted: Int = 0

    var isClean: Bool { mismatched.isEmpty && verified > 0 }
}

/// The verdict of comparing what is installed against what is published.
enum ModelComparison: Sendable, Equatable {
    case upToDate(revision: String, lastModified: Date?)
    case updateAvailable(revision: String, lastModified: Date?, changedFiles: Int)
}

/// Manages the CoreML speaker models on disk: what is installed, whether anything
/// newer exists, and replacing them.
///
/// FluidAudio downloads these once and then keeps them forever — its only check is
/// whether the file exists, with no checksum, revision, or update path. That means an
/// install silently keeps whatever the repository held on the day it first ran. This
/// adds the missing half: record the revision at install time, and compare it against
/// the published head on request.
enum DiarizationModelStore {

    /// The HuggingFace repository FluidAudio pulls speaker models from.
    static let repositoryID = "FluidInference/speaker-diarization-coreml"

    /// Where FluidAudio unpacks that repository.
    private static let folderName = "speaker-diarization"

    /// Files that must be present for the models to be usable.
    private static let requiredFiles = ["pyannote_segmentation.mlmodelc", "wespeaker_v2.mlmodelc"]

    private static let installedRevisionKey = "diarizationModelRevision"

    // MARK: - Locations

    static var modelsRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    static var modelsDirectory: URL {
        modelsRoot.appendingPathComponent(folderName, isDirectory: true)
    }

    // MARK: - Local State

    /// Whether both models are on disk whole, ready to load.
    ///
    /// Checking that the two folders exist was not enough. An install interrupted part
    /// way leaves them without their `coremldata.bin`, or with a weight file still named
    /// `.partial`; Settings said Installed, and the next meeting start found the models
    /// incomplete and went to HuggingFace for them. This is FluidAudio's own test for a
    /// complete model.
    static var isInstalled: Bool {
        requiredFiles.allSatisfy { name in
            let model = modelsDirectory.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: model.appendingPathComponent("coremldata.bin").path)
                && !containsPartialDownload(model)
        }
    }

    /// Whether a download into `folder` was cut off and left a `.partial` file behind.
    private static func containsPartialDownload(_ folder: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: nil
        ) else { return false }

        for case let file as URL in enumerator where file.pathExtension == "partial" {
            return true
        }
        return false
    }

    /// Keep FluidAudio off the network.
    ///
    /// Left to itself, FluidAudio deletes and re-downloads any model it finds incomplete
    /// or cannot load, wherever it is called from. Set once at launch; `install()` lifts
    /// it for its own download and puts it back.
    static func stayOffline() {
        ModelHub.offlineMode = true
    }

    /// When the models landed on disk.
    static var installedAt: Date? {
        try? FileManager.default
            .attributesOfItem(atPath: modelsDirectory.path)[.modificationDate] as? Date
    }

    static var sizeOnDisk: Int64 { directorySize(modelsDirectory) }

    /// The repository revision recorded when these models were installed.
    ///
    /// Absent for models fetched before this tracking existed, which is why an
    /// unknown revision is reported as "unknown" rather than "up to date".
    static var installedRevision: String? {
        UserDefaults.standard.string(forKey: installedRevisionKey)
    }

    static func recordInstalledRevision(_ revision: String) {
        UserDefaults.standard.set(revision, forKey: installedRevisionKey)
    }

    // MARK: - Install

    /// Download the models, and record which revision they came from.
    ///
    /// Deliberately not called from the recording path: starting a meeting must not
    /// reach the network. Settings is the only caller, behind a button.
    ///
    /// The one place FluidAudio is let online. An incomplete install is repaired here
    /// too: FluidAudio finds the broken model, deletes it and downloads it again.
    static func install() async throws {
        ModelHub.offlineMode = false
        defer { ModelHub.offlineMode = true }

        _ = try await DiarizerModels.downloadIfNeeded()

        // FluidAudio keeps no record of which revision it took, so "check for updates"
        // would have nothing to compare against.
        if let remote = try? await fetchLatestRevision() {
            recordInstalledRevision(remote.revision)
        }
    }

    // MARK: - Remote

    /// Ask HuggingFace what the repository head is now.
    ///
    /// Reached only from Settings, when the user presses Install or Check for Updates.
    /// Nothing on the recording path calls it. No audio, transcript, or user data goes
    /// with it — it is a public metadata read.
    static func fetchLatestRevision() async throws -> RemoteModelRevision {
        // blobs=true adds a published size per file, which is what makes comparing an
        // untracked install possible without re-downloading it.
        let url = URL(string: "https://huggingface.co/api/models/\(repositoryID)?blobs=true")!

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ModelStoreError.badResponse(code)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String else {
            throw ModelStoreError.malformedResponse
        }

        var lastModified: Date?
        if let raw = json["lastModified"] as? String {
            lastModified = ISO8601DateFormatter().date(from: raw)
                ?? ISO8601DateFormatter.fractionalSeconds().date(from: raw)
        }

        var files: [String: RemoteFile] = [:]
        if let siblings = json["siblings"] as? [[String: Any]] {
            for entry in siblings {
                guard let path = entry["rfilename"] as? String,
                      let size = entry["size"] as? Int else { continue }

                let lfs = entry["lfs"] as? [String: Any]
                files[path] = RemoteFile(
                    path: path,
                    size: size,
                    blobId: entry["blobId"] as? String,
                    sha256: lfs?["sha256"] as? String
                )
            }
        }

        return RemoteModelRevision(revision: sha, lastModified: lastModified, files: files)
    }

    /// Compare what is on disk against what the repository publishes.
    ///
    /// When the recorded revision matches the head there is nothing to check. Otherwise
    /// — including the common case of an install made before revisions were recorded —
    /// every local file is checked against its published size.
    ///
    /// Size is not a checksum, and two different files can share one. Across a whole
    /// model tree, though, every file matching is strong evidence the copies are the
    /// published ones, and it beats deleting a working install to find out.
    static func compareWithRemote() async throws -> ModelComparison {
        let remote = try await fetchLatestRevision()

        if let installedRevision, installedRevision == remote.revision {
            return .upToDate(revision: remote.revision, lastModified: remote.lastModified)
        }

        // Hashing 13 MB is quick but not instant, and this is called from the UI.
        let report = await Task.detached { verifyLocalFiles(against: remote.files) }.value
        let changed = report.mismatched.count

        if report.isClean {
            // The files are the published ones; adopt the revision so later checks
            // take the fast path.
            recordInstalledRevision(remote.revision)
            return .upToDate(revision: remote.revision, lastModified: remote.lastModified)
        }

        return .updateAvailable(
            revision: remote.revision,
            lastModified: remote.lastModified,
            changedFiles: changed
        )
    }

    /// Hash every installed file and compare it against what the repository publishes.
    ///
    /// File size was the first thing I reached for and it is not good enough: two
    /// different files can share a size, and a model can be retrained without changing
    /// its byte count at all. HuggingFace publishes real content hashes, so these are
    /// checked instead.
    ///
    /// Two hash schemes, because the repository uses two. Model weights are stored in
    /// Git LFS and carry a plain SHA-256 of their contents. Everything else is an
    /// ordinary git object identified by its blob hash, `sha1("blob <size>\0" + bytes)`
    /// — the size and null byte are part of what git hashes, not decoration.
    nonisolated static func verifyLocalFiles(against published: [String: RemoteFile]) -> VerificationReport {
        var report = VerificationReport()
        guard !published.isEmpty else { return report }

        let root = modelsDirectory
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return report }

        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"

        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let localSize = values?.fileSize else { continue }

            let relative = file.path.replacingOccurrences(of: prefix, with: "")

            // FluidAudio writes files of its own alongside the downloaded ones; those
            // are not the repository's to vouch for.
            guard let remote = published[relative] else {
                report.unlisted += 1
                continue
            }

            // Size is a free pre-filter. It cannot prove a match, but it does prove a
            // mismatch, and it saves hashing a file that has already failed.
            if remote.size != localSize {
                report.mismatched.append(relative)
                continue
            }

            do {
                if let expected = remote.sha256 {
                    let actual = try sha256Hex(of: file)
                    if actual == expected { report.verified += 1 }
                    else { report.mismatched.append(relative) }
                } else if let expected = remote.blobId {
                    let actual = try gitBlobHex(of: file, size: localSize)
                    if actual == expected { report.verified += 1 }
                    else { report.mismatched.append(relative) }
                } else {
                    report.unlisted += 1
                }
            } catch {
                report.mismatched.append(relative)
            }
        }

        return report
    }

    // MARK: - Hashing

    /// Files are streamed rather than read whole: model weights run to hundreds of
    /// megabytes for other FluidAudio models, and loading one to hash it is wasteful.
    private static let hashChunkSize = 1 << 20

    private nonisolated static func sha256Hex(of url: URL) throws -> String {
        var hasher = SHA256()
        try stream(url) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Git's object hash: the literal bytes `blob <size>\0` followed by the contents.
    private nonisolated static func gitBlobHex(of url: URL, size: Int) throws -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        try stream(url) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func stream(_ url: URL, _ consume: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        while let chunk = try handle.read(upToCount: hashChunkSize), !chunk.isEmpty {
            consume(chunk)
        }
    }

    // MARK: - Mutation

    /// Replace the local copies with fresh ones from HuggingFace.
    ///
    /// Removal rather than in-place replacement: FluidAudio skips any file already on
    /// disk, so a stale copy would survive a re-download.
    ///
    /// This used to stop at the removal and leave the download to the next meeting.
    /// A meeting is not allowed to download, so that meeting recorded without speakers
    /// and Settings offered only Install. The download now follows at once. The old
    /// copies are moved aside rather than deleted until the new ones are in, so a
    /// failed download puts them back instead of leaving no models at all.
    static func reinstall() async throws {
        let fileManager = FileManager.default
        let previous = modelsRoot.appendingPathComponent("\(folderName).previous", isDirectory: true)
        let previousRevision = installedRevision

        try? fileManager.removeItem(at: previous)
        if fileManager.fileExists(atPath: modelsDirectory.path) {
            try fileManager.moveItem(at: modelsDirectory, to: previous)
        }
        UserDefaults.standard.removeObject(forKey: installedRevisionKey)

        do {
            try await install()
            try? fileManager.removeItem(at: previous)
        } catch {
            try? fileManager.removeItem(at: modelsDirectory)
            if fileManager.fileExists(atPath: previous.path) {
                try? fileManager.moveItem(at: previous, to: modelsDirectory)
                if let previousRevision {
                    recordInstalledRevision(previousRevision)
                }
            }
            throw error
        }
    }

    // MARK: - Unused Models

    /// FluidAudio model folders Inscribe never loads.
    ///
    /// The library shares one cache across every model family it offers, so trying its
    /// speech recognition once leaves hundreds of megabytes behind that nothing here
    /// reads — Apple's SpeechTranscriber does the transcribing.
    static func unusedModelFolders() -> [(name: String, size: Int64)] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: modelsRoot,
            includingPropertiesForKeys: nil
        )) ?? []

        return contents
            .filter { $0.hasDirectoryPath && $0.lastPathComponent != folderName }
            .map { ($0.lastPathComponent, directorySize($0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }

    static func removeUnusedModels() throws {
        for folder in unusedModelFolders() {
            try FileManager.default.removeItem(at: modelsRoot.appendingPathComponent(folder.name))
        }
    }

    // MARK: - Helpers

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    static func formatted(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    enum ModelStoreError: LocalizedError {
        case badResponse(Int)
        case malformedResponse
        case notInstalled

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): "HuggingFace returned status \(code)."
            case .malformedResponse: "Could not read the repository details."
            case .notInstalled: "The speaker separation models are not installed. Install them in Settings."
            }
        }
    }
}

private extension ISO8601DateFormatter {
    /// Built per call rather than shared: `ISO8601DateFormatter` is not `Sendable`,
    /// and this runs once per update check.
    static func fractionalSeconds() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
#endif
