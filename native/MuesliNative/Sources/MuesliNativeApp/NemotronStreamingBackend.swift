import Accelerate
import MuesliCore
@preconcurrency import CoreML
import Foundation

/// Native RNNT streaming ASR backend for NVIDIA Nemotron Speech 0.6B (English).
/// Runs entirely on Apple Neural Engine via CoreML.
///
/// Pipeline: audio → preprocessor(mel) → encoder(with cache) → decoder+joint(RNNT greedy) → tokens
/// Model: FluidInference/nemotron-speech-streaming-en-0.6b-coreml (560ms chunks)
///
/// The chunk pipeline lives in `NemotronRNNTEngine` (shared with the multilingual
/// `Nemotron35StreamingTranscriber`); this actor only owns the loaded models,
/// tokenizer, the EN model config, and download/caching.
@available(macOS 15, iOS 18, *)
actor NemotronStreamingTranscriber: NemotronStreamingTranscribing {
    private var preprocessor: MLModel?
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var joint: MLModel?
    private var tokenizer: [Int: String] = [:]
    private var loaded = false

    /// EN config from metadata.json (560ms variant).
    private let config = NemotronRNNTConfig(
        chunkSamples: 8960,          // 560ms at 16kHz
        cacheChannelFrames: 70,
        totalMelFrames: 65,          // chunk + cache
        encoderDim: 1024,
        decoderHiddenSize: 640,
        blankTokenId: 1024,
        promptId: nil,               // EN model has no language input
        stripAngleBracketTags: false
    )

    /// Streaming state + error types are shared across the Nemotron backends.
    typealias StreamState = RNNTStreamState
    typealias TranscriberError = NemotronRNNTError

    // MARK: - Model Loading

    private static let cacheDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models/nemotron-560ms", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func loadModels(progress: ((Double, String?) -> Void)? = nil) async throws {
        if loaded { return }

        let modelDir = try await ensureModelsDownloaded(progress: progress)

        fputs("[nemotron] loading CoreML models...\n", stderr)
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = .all

        preprocessor = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("preprocessor.mlmodelc"), configuration: mlConfig)
        encoder = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("encoder/encoder_int8.mlmodelc"), configuration: mlConfig)
        decoder = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("decoder.mlmodelc"), configuration: mlConfig)
        joint = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("joint.mlmodelc"), configuration: mlConfig)

        // Load tokenizer: {id_string: token_string}
        let tokenizerURL = modelDir.appendingPathComponent("tokenizer.json")
        let tokenizerData = try Data(contentsOf: tokenizerURL)
        if let json = try JSONSerialization.jsonObject(with: tokenizerData) as? [String: String] {
            for (key, value) in json {
                if let id = Int(key) {
                    tokenizer[id] = value
                }
            }
        }

        loaded = true
        fputs("[nemotron] models ready (\(tokenizer.count) vocab tokens)\n", stderr)
    }

    // MARK: - Streaming API

    /// Create a fresh streaming state with zero-initialized caches.
    func makeStreamState() throws -> StreamState {
        try nemotronMakeStreamState(config: config)
    }

    /// Process one 560ms audio chunk (8960 samples) and return newly decoded text.
    /// State is mutated in-place to carry encoder cache + LSTM state to the next chunk.
    func transcribeChunk(samples: [Float], state: inout StreamState) async throws -> String {
        guard loaded, let preprocessor, let encoder, let decoder, let joint else {
            throw TranscriberError.notLoaded
        }
        let newTokens = try await nemotronTranscribeChunk(
            preprocessor: preprocessor, encoder: encoder, decoder: decoder, joint: joint,
            config: config, samples: samples, state: &state)
        return nemotronDecodeTokens(
            newTokens, tokenizer: tokenizer,
            stripAngleBracketTags: config.stripAngleBracketTags, trim: false)
    }

    // MARK: - Convenience (full-file transcription)

    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard loaded else { throw TranscriberError.notLoaded }

        let samples = try nemotronLoadWavAsFloats(url: wavURL)
        let start = CFAbsoluteTimeGetCurrent()

        var state = try makeStreamState()
        var sampleOffset = 0

        while sampleOffset < samples.count {
            let chunkEnd = min(sampleOffset + config.chunkSamples, samples.count)
            let chunk = Array(samples[sampleOffset..<chunkEnd])
            _ = try await transcribeChunk(samples: chunk, state: &state)
            sampleOffset += config.chunkSamples
        }

        let text = nemotronDecodeTokens(
            state.allTokens, tokenizer: tokenizer,
            stripAngleBracketTags: config.stripAngleBracketTags, trim: true)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        return (text: text, processingTime: elapsed)
    }

    func shutdown() {
        preprocessor = nil; encoder = nil; decoder = nil; joint = nil
        tokenizer = [:]; loaded = false
    }

    // MARK: - Model Download

    private static let repoID = "FluidInference/nemotron-speech-streaming-en-0.6b-coreml"
    private static let variantPath = "nemotron_coreml_560ms"

    private func ensureModelsDownloaded(progress: ((Double, String?) -> Void)? = nil) async throws -> URL {
        let modelDir = Self.cacheDir
        let requiredFile = modelDir.appendingPathComponent("encoder/encoder_int8.mlmodelc/coremldata.bin")
        if FileManager.default.fileExists(atPath: requiredFile.path) {
            fputs("[nemotron] models already cached\n", stderr)
            return modelDir
        }

        fputs("[nemotron] downloading 560ms variant from HuggingFace...\n", stderr)
        progress?(0.0, "Downloading Nemotron model...")

        let hfAPI = "https://huggingface.co/api/models/\(Self.repoID)/tree/main/\(Self.variantPath)"
        var filesDownloaded = 0
        try await nemotronDownloadHuggingFaceTree(
            repoID: Self.repoID, apiURL: hfAPI, remotePath: Self.variantPath,
            localDir: modelDir, logPrefix: "[nemotron]"
        ) {
            filesDownloaded += 1
            progress?(min(Double(filesDownloaded) / 50.0, 0.95), "Downloading Nemotron model...")
        }

        fputs("[nemotron] download complete\n", stderr)
        return modelDir
    }
}
