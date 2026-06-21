import Accelerate
import MuesliCore
@preconcurrency import CoreML
import Foundation

/// Native RNNT streaming ASR backend for NVIDIA Nemotron 3.5 ASR Streaming (multilingual).
/// Runs entirely on Apple Neural Engine via CoreML.
///
/// Pipeline: audio → preprocessor(mel) → encoder(with cache + prompt_id) → decoder+joint(RNNT greedy) → tokens
/// Model: FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML (multilingual/2240ms variant)
///
/// Differs from the English-only `NemotronStreamingTranscriber` only in the
/// `NemotronRNNTConfig` below (cache geometry, vocab/blank, chunk length, the
/// language `prompt_id`, `<…>` tag stripping) and the download/cache paths. The
/// shared chunk pipeline lives in `NemotronRNNTEngine`. Reuses the neutral
/// `RNNTStreamState` so it conforms to `NemotronStreamingTranscribing` unchanged.
@available(macOS 15, iOS 18, *)
actor Nemotron35StreamingTranscriber: NemotronStreamingTranscribing {
    private var preprocessor: MLModel?
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var joint: MLModel?
    private var tokenizer: [Int: String] = [:]
    private var loaded = false

    /// Multilingual config from metadata.json (multilingual/2240ms variant).
    /// Geometry: chunk_mel_frames 224 + pre_encode_cache 9 = total 233; 8× subsampling
    /// → 28 encoder frames/chunk; chunkSamples = 2240ms · 16kHz = 35840.
    private let config = NemotronRNNTConfig(
        chunkSamples: 35840,
        cacheChannelFrames: 42,      // att_context left
        totalMelFrames: 233,
        encoderDim: 1024,
        decoderHiddenSize: 640,
        blankTokenId: 13087,         // = vocab_size (last logit index)
        promptId: 101,               // auto-detect language
        stripAngleBracketTags: true  // drop <lang>/<unk> tags the model emits
    )

    typealias StreamState = RNNTStreamState
    typealias TranscriberError = NemotronRNNTError

    /// Samples per streaming chunk — read cross-actor by the runtime/controller to
    /// size the audio buffer (must match config.chunkSamples).
    nonisolated let chunkSamples = 35840

    // MARK: - Model Loading

    private static let cacheDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models/nemotron35-multilingual-2240ms", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func loadModels(progress: ((Double, String?) -> Void)? = nil) async throws {
        if loaded { return }

        let modelDir = try await ensureModelsDownloaded(progress: progress)

        fputs("[nemotron35] loading CoreML models...\n", stderr)
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = .all

        preprocessor = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("preprocessor.mlmodelc"), configuration: mlConfig)
        encoder = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("encoder.mlmodelc"), configuration: mlConfig)
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
        fputs("[nemotron35] models ready (\(tokenizer.count) vocab tokens)\n", stderr)
    }

    // MARK: - Streaming API

    func makeStreamState() throws -> StreamState {
        try nemotronMakeStreamState(config: config)
    }

    /// Process one 2240ms audio chunk (35840 samples) and return newly decoded text.
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

    private static let repoID = "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
    private static let variantPath = "multilingual/2240ms"

    private func ensureModelsDownloaded(progress: ((Double, String?) -> Void)? = nil) async throws -> URL {
        let modelDir = Self.cacheDir
        let requiredFile = modelDir.appendingPathComponent("encoder.mlmodelc/coremldata.bin")
        if FileManager.default.fileExists(atPath: requiredFile.path) {
            fputs("[nemotron35] models already cached\n", stderr)
            return modelDir
        }

        fputs("[nemotron35] downloading multilingual/2240ms variant from HuggingFace...\n", stderr)
        progress?(0.0, "Downloading Nemotron 3.5 model...")

        let hfAPI = "https://huggingface.co/api/models/\(Self.repoID)/tree/main/\(Self.variantPath)"
        var filesDownloaded = 0
        // Skip the fused decoder_joint — we run decoder + joint separately (saves ~49 MB).
        try await nemotronDownloadHuggingFaceTree(
            repoID: Self.repoID, apiURL: hfAPI, remotePath: Self.variantPath,
            localDir: modelDir, skipRelativePrefix: "decoder_joint.mlmodelc", logPrefix: "[nemotron35]"
        ) {
            filesDownloaded += 1
            progress?(min(Double(filesDownloaded) / 30.0, 0.95), "Downloading Nemotron 3.5 model...")
        }

        fputs("[nemotron35] download complete\n", stderr)
        return modelDir
    }
}
