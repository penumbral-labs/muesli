import Foundation

/// The shared on-disk Nemotron 3.5 model store used by the app and CLI.
///
/// The app's RNNT engine and FluidAudio's multilingual manager can both load
/// this top-level CoreML layout. Keeping the downloader and path here prevents
/// the two products from maintaining separate copies of the same model.
public enum Nemotron35ModelStore {
    public static let repoID = "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
    public static let variantPath = "multilingual/2240ms"
    public static let cacheRelativePath = ".cache/muesli/models/nemotron35-multilingual-2240ms"
    public static let requiredFileRelativePath = "encoder.mlmodelc/coremldata.bin"
    public static let requiredFileRelativePaths = [
        "encoder.mlmodelc/analytics/coremldata.bin",
        "encoder.mlmodelc/coremldata.bin",
        "encoder.mlmodelc/model.mil",
        "encoder.mlmodelc/weights/weight.bin",
        "decoder.mlmodelc/analytics/coremldata.bin",
        "decoder.mlmodelc/coremldata.bin",
        "decoder.mlmodelc/model.mil",
        "decoder.mlmodelc/weights/weight.bin",
        "joint.mlmodelc/analytics/coremldata.bin",
        "joint.mlmodelc/coremldata.bin",
        "joint.mlmodelc/model.mil",
        "joint.mlmodelc/weights/weight.bin",
        "preprocessor.mlmodelc/analytics/coremldata.bin",
        "preprocessor.mlmodelc/coremldata.bin",
        "preprocessor.mlmodelc/model.mil",
        "preprocessor.mlmodelc/weights/weight.bin",
        "metadata.json",
        "tokenizer.json",
    ]

    public static func cacheDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(cacheRelativePath, isDirectory: true)
    }

    public static func revisionFileURL(fileManager: FileManager = .default) -> URL {
        cacheDirectory(fileManager: fileManager).appendingPathComponent(".revision")
    }

    public static func isModelDownloaded(fileManager: FileManager = .default) -> Bool {
        let directory = cacheDirectory(fileManager: fileManager)
        return requiredFileRelativePaths.allSatisfy { relativePath in
            let url = directory.appendingPathComponent(relativePath)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let type = attributes[.type] as? FileAttributeType,
                  type == .typeRegular else {
                return false
            }
            return true
        }
    }

    /// Ensure the app-compatible multilingual/2240ms model exists locally.
    /// Existing files are reused, so an interrupted download can resume.
    @discardableResult
    public static func ensureDownloaded(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws -> URL {
        let directory = cacheDirectory()
        if isModelDownloaded() {
            return directory
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        progress?(0.0, "Downloading Nemotron 3.5 model...")

        let manifest = try await HuggingFaceModelManifestResolver.shared.resolve(
            modelID: repoID,
            repository: repoID,
            selections: [
                HuggingFaceModelSelection(
                    remoteDirectory: variantPath,
                    includedPaths: [
                        "encoder.mlmodelc",
                        "decoder.mlmodelc",
                        "joint.mlmodelc",
                        "preprocessor.mlmodelc",
                        "metadata.json",
                        "tokenizer.json",
                    ]
                )
            ],
            maximumConcurrency: 2
        )
        try await ModelDownloadCoordinator.shared.download(manifest, to: directory) { snapshot in
            progress?(snapshot.fractionCompleted ?? 0, "Downloading Nemotron 3.5 model...")
            progressSnapshot?(snapshot)
        }

        if let revision = await fetchRemoteRevision() {
            recordInstalledRevision(revision)
        }
        progress?(1.0, "Nemotron 3.5 model ready")
        return directory
    }

    /// The Hugging Face commit currently backing the shared model repository.
    /// A failed lookup is intentionally non-fatal to model downloads.
    public static func fetchRemoteRevision() async -> String? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)") else {
            return nil
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revision = object["sha"] as? String
        else {
            return nil
        }
        return revision
    }

    public static func installedRevision(fileManager: FileManager = .default) -> String? {
        guard let value = try? String(
            contentsOf: revisionFileURL(fileManager: fileManager),
            encoding: .utf8
        ) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func recordInstalledRevision(
        _ revision: String,
        fileManager: FileManager = .default
    ) {
        try? revision.write(
            to: revisionFileURL(fileManager: fileManager),
            atomically: true,
            encoding: .utf8
        )
    }

}
