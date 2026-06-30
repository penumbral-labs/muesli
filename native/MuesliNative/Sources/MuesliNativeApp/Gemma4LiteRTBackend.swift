import Foundation
import CLiteRTLM

enum Gemma4LiteRTLogging {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MUESLI_DEBUG_GEMMA4_LITERT_LOGS"] == "1"
    }

    static func log(_ message: String) {
        guard isEnabled else { return }
        fputs("[gemma4-litert] \(message)\n", stderr)
    }
}

enum Gemma4LiteRTModelStore {
    static let modelPathEnvVar = "MUESLI_GEMMA4_LITERT_MODEL_PATH"
    static let promptEnvVar = "MUESLI_GEMMA4_LITERT_PROMPT"
    static let cacheDirEnvVar = "MUESLI_GEMMA4_LITERT_CACHE_DIR"
    static let backendEnvVar = "MUESLI_GEMMA4_LITERT_BACKEND"
    static let repoID = "litert-community/gemma-4-E2B-it-litert-lm"
    static let modelFilename = "gemma-4-E2B-it.litertlm"
    static let cacheRelativePath = ".cache/muesli/models/gemma-4-e2b-litert-lm"
    static let minimumDownloadedModelSizeBytes: Int64 = 2_000_000_000

    static let downloadURL = URL(
        string: "https://huggingface.co/\(repoID)/resolve/main/\(modelFilename)?download=1"
    )!

    static let defaultPrompt = """
    You are Muesli's ASR transcription engine. The next user message contains one speech segment as audio. Transcribe the following speech segment into clean dictation text.

    Return only the spoken words from the audio. Preserve the speaker's meaning and wording. Add punctuation and capitalization. Remove only obvious filler words and false starts.

    Never answer the speaker, never offer help, never ask for an upload, and never mention that you cannot access audio. Do not summarize, explain, translate, continue the conversation, or add content that was not spoken. If there is no intelligible speech, return an empty transcript.
    """

    static func cacheDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(cacheRelativePath, isDirectory: true)
    }

    static func managedModelURL(fileManager: FileManager = .default) -> URL {
        cacheDirectory(fileManager: fileManager).appendingPathComponent(modelFilename)
    }

    static func managedLiteRTCacheDirectory(fileManager: FileManager = .default) -> URL {
        cacheDirectory(fileManager: fileManager).appendingPathComponent("litert-cache", isDirectory: true)
    }

    static func localOverrideURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let rawPath = environment[modelPathEnvVar]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: rawPath)
    }

    static func resolvedModelURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        localOverrideURL(environment: environment) ?? managedModelURL(fileManager: fileManager)
    }

    static func resolvedCacheDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        guard let rawPath = environment[cacheDirEnvVar]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return managedLiteRTCacheDirectory(fileManager: fileManager)
        }
        return URL(fileURLWithPath: rawPath, isDirectory: true)
    }

    static func resolvedPrompt(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment[promptEnvVar]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return defaultPrompt
    }

    static func resolvedBackend(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment[backendEnvVar]?.lowercased() == "gpu" ? "gpu" : "cpu"
    }

    static func isAvailableLocally(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Bool {
        let url = resolvedModelURL(environment: environment, fileManager: fileManager)
        let minimumSize: Int64 = localOverrideURL(environment: environment) == nil
            ? minimumDownloadedModelSizeBytes
            : 1
        return isValidLiteRTLMFile(at: url, minimumSizeBytes: minimumSize, fileManager: fileManager)
    }

    static func ensureModelDownloaded(
        progress: ((Double, String?) -> Void)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) async throws -> URL {
        let modelURL = resolvedModelURL(environment: environment, fileManager: fileManager)
        if isAvailableLocally(environment: environment, fileManager: fileManager) {
            progress?(0.8, "Gemma 4 E2B already downloaded")
            return modelURL
        }

        if localOverrideURL(environment: environment) != nil {
            throw NSError(domain: "Gemma4LiteRTModelStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Gemma 4 LiteRT-LM model is missing at \(modelURL.path).",
            ])
        }

        try await downloadManagedModel(progress: progress, fileManager: fileManager)
        guard isAvailableLocally(environment: environment, fileManager: fileManager) else {
            throw NSError(domain: "Gemma4LiteRTModelStore", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Gemma 4 LiteRT-LM did not download successfully.",
            ])
        }
        progress?(0.8, "Gemma 4 E2B downloaded")
        return modelURL
    }

    static func deleteModelFiles(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws {
        if let overrideURL = localOverrideURL(environment: environment) {
            guard isValidLiteRTLMFile(at: overrideURL, minimumSizeBytes: 1, fileManager: fileManager) else { return }
            try fileManager.removeItem(at: overrideURL)
            return
        }

        let directory = cacheDirectory(fileManager: fileManager)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    private static func downloadManagedModel(
        progress: ((Double, String?) -> Void)?,
        fileManager: FileManager
    ) async throws {
        let directory = cacheDirectory(fileManager: fileManager)
        let destination = managedModelURL(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let stagingURL = destination.deletingLastPathComponent().appendingPathComponent(".\(modelFilename).download")
        defer { try? fileManager.removeItem(at: stagingURL) }
        try? fileManager.removeItem(at: stagingURL)
        progress?(0.05, "Downloading Gemma 4 E2B...")
        try await downloadWithRetry(from: downloadURL, to: stagingURL)
        try validateDownloadedLiteRTLMFile(at: stagingURL, fileManager: fileManager)
        try installDownloadedModel(from: stagingURL, to: destination, fileManager: fileManager)
    }

    private static func installDownloadedModel(from tempURL: URL, to destination: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: tempURL, to: destination)
        }
    }

    static func isValidLiteRTLMFile(
        at url: URL,
        minimumSizeBytes: Int64,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value >= minimumSizeBytes
    }

    private static func validateDownloadedLiteRTLMFile(at url: URL, fileManager: FileManager) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= minimumDownloadedModelSizeBytes else {
            throw NSError(domain: "Gemma4LiteRTModelStore", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Downloaded Gemma 4 LiteRT-LM model is too small (\(size) bytes).",
            ])
        }
    }
}

@available(macOS 15, *)
actor Gemma4LiteRTTranscriber {
    static let maxOutputTokens: Int32 = 1024

    private var engine: OpaquePointer?
    private var isLoading = false
    private var loadGeneration = 0
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []

    enum TranscriberError: Error, LocalizedError, Equatable {
        case modelMissing(path: String)
        case failedToCreateSettings
        case failedToCreateEngine
        case failedToCreateSessionConfig
        case failedToCreateConversationConfig
        case failedToCreateConversation
        case failedToCreateOptionalArgs
        case failedToCreateMessage
        case invalidResponse
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .modelMissing(let path):
                return "Gemma 4 LiteRT-LM model is missing at \(path). Download it from the Models tab or set \(Gemma4LiteRTModelStore.modelPathEnvVar)."
            case .failedToCreateSettings:
                return "Gemma 4 LiteRT-LM failed to create engine settings."
            case .failedToCreateEngine:
                return "Gemma 4 LiteRT-LM failed to create the engine."
            case .failedToCreateSessionConfig:
                return "Gemma 4 LiteRT-LM failed to create session config."
            case .failedToCreateConversationConfig:
                return "Gemma 4 LiteRT-LM failed to create conversation config."
            case .failedToCreateConversation:
                return "Gemma 4 LiteRT-LM failed to create a conversation."
            case .failedToCreateOptionalArgs:
                return "Gemma 4 LiteRT-LM failed to create optional conversation arguments."
            case .failedToCreateMessage:
                return "Gemma 4 LiteRT-LM failed to create a conversation message."
            case .invalidResponse:
                return "Gemma 4 LiteRT-LM returned an invalid response."
            case .notLoaded:
                return "Gemma 4 LiteRT-LM is not loaded. Call prepare() first."
            }
        }
    }

    func prepare(progress: ((Double, String?) -> Void)? = nil) async throws {
        if engine != nil { return }
        if isLoading {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                loadWaiters.append(continuation)
            }
            return
        }

        isLoading = true
        let generation = loadGeneration
        do {
            try await loadEngine(progress: progress, generation: generation)
            isLoading = false
            completeLoadWaiters()
        } catch {
            isLoading = false
            completeLoadWaiters(throwing: error)
            throw error
        }
    }

    private func loadEngine(progress: ((Double, String?) -> Void)?, generation: Int) async throws {
        let fileManager = FileManager.default
        let modelURL = try await Gemma4LiteRTModelStore.ensureModelDownloaded(progress: progress)
        try checkLoadGeneration(generation)
        guard fileManager.fileExists(atPath: modelURL.path) else {
            throw TranscriberError.modelMissing(path: modelURL.path)
        }

        let cacheDirectory = Gemma4LiteRTModelStore.resolvedCacheDirectory()
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try checkLoadGeneration(generation)

        progress?(0.9, "Loading Gemma 4 E2B...")
        Gemma4LiteRTLogging.log("loading \(modelURL.path)")
        let backend = Gemma4LiteRTModelStore.resolvedBackend()
        // Gemma E2B is audio-only here: no vision backend, and the audio backend follows
        // the selected engine backend ("cpu" by default; "gpu" only via explicit env opt-in).
        guard let settings = litert_lm_engine_settings_create(modelURL.path, backend, nil, backend) else {
            throw TranscriberError.failedToCreateSettings
        }
        defer { litert_lm_engine_settings_delete(settings) }
        litert_lm_engine_settings_set_max_num_tokens(settings, 4096)
        litert_lm_engine_settings_set_cache_dir(settings, cacheDirectory.path)

        guard let loadedEngine = litert_lm_engine_create(settings) else {
            throw TranscriberError.failedToCreateEngine
        }
        engine = loadedEngine
        progress?(1.0, nil)
        Gemma4LiteRTLogging.log("engine ready; backend=\(backend) cache=\(cacheDirectory.path)")
    }

    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard let engine else { throw TranscriberError.notLoaded }
        let start = CFAbsoluteTimeGetCurrent()

        guard let sessionConfig = litert_lm_session_config_create() else {
            throw TranscriberError.failedToCreateSessionConfig
        }
        defer { litert_lm_session_config_delete(sessionConfig) }
        litert_lm_session_config_set_max_output_tokens(sessionConfig, Self.maxOutputTokens)
        var sampler = LiteRtLmSamplerParams(
            type: kLiteRtLmSamplerTypeTopP,
            top_k: 1,
            top_p: 0.95,
            temperature: 1.0,
            seed: 0
        )
        litert_lm_session_config_set_sampler_params(sessionConfig, &sampler)

        guard let conversationConfig = litert_lm_conversation_config_create() else {
            throw TranscriberError.failedToCreateConversationConfig
        }
        defer { litert_lm_conversation_config_delete(conversationConfig) }
        litert_lm_conversation_config_set_session_config(conversationConfig, sessionConfig)
        litert_lm_conversation_config_set_system_message(
            conversationConfig,
            try Self.messageJSONString(role: "system", contents: [["type": "text", "text": Gemma4LiteRTModelStore.resolvedPrompt()]])
        )

        guard let conversation = litert_lm_conversation_create(engine, conversationConfig) else {
            throw TranscriberError.failedToCreateConversation
        }
        defer { litert_lm_conversation_delete(conversation) }

        guard let optionalArgs = litert_lm_conversation_optional_args_create() else {
            throw TranscriberError.failedToCreateOptionalArgs
        }
        defer { litert_lm_conversation_optional_args_delete(optionalArgs) }

        let messageJSON = try Self.userMessageJSONString(wavURL: wavURL)
        guard let jsonResponse = litert_lm_conversation_send_message(conversation, messageJSON, nil, optionalArgs) else {
            throw TranscriberError.invalidResponse
        }
        defer { litert_lm_json_response_delete(jsonResponse) }
        guard let responseCString = litert_lm_json_response_get_string(jsonResponse) else {
            throw TranscriberError.invalidResponse
        }

        let response = String(cString: responseCString)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        return (try Self.validatedTranscript(fromResponseJSON: response), elapsed)
    }

    func shutdown() {
        loadGeneration += 1
        if let engine {
            litert_lm_engine_delete(engine)
        }
        engine = nil
        isLoading = false
        completeLoadWaiters(throwing: TranscriberError.notLoaded)
    }

    static func cleanTranscript(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = cleaned.lowercased()
        for prefix in ["final transcript:", "transcript:", "transcription:"] where lowered.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if cleaned.hasPrefix("\""), cleaned.hasSuffix("\""), cleaned.count >= 2 {
            cleaned = String(cleaned.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    static func validatedTranscript(fromResponseJSON responseJSON: String) throws -> String {
        let cleaned = cleanTranscript(try textContent(fromResponseJSON: responseJSON))
        guard !looksLikeAssistantResponse(cleaned) else {
            Gemma4LiteRTLogging.log("rejected assistant-style Gemma response: \(cleaned.prefix(160))")
            throw TranscriberError.invalidResponse
        }
        return cleaned
    }

    static func looksLikeAssistantResponse(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !normalized.isEmpty else { return false }

        let assistantMarkers = [
            "i understand you're looking for",
            "i understand you are looking for",
            "looking for a quick and accurate transcription",
            "i can certainly help you with that",
            "i can help you with that",
            "please provide the audio",
            "please upload the audio",
            "i don't have access to the audio",
            "i do not have access to the audio",
            "i can't listen to audio",
            "i cannot listen to audio",
            "as an ai",
        ]
        return assistantMarkers.contains { normalized.contains($0) }
    }

    private static func messageJSONString(role: String, contents: [[String: String]]) throws -> String {
        let message: [String: Any] = ["role": role, "content": contents]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: message)
        } catch {
            throw TranscriberError.failedToCreateMessage
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw TranscriberError.failedToCreateMessage
        }
        return string
    }

    static func userMessageJSONString(wavURL: URL) throws -> String {
        try messageJSONString(role: "user", contents: [
            ["type": "audio", "path": wavURL.path],
        ])
    }

    static func textContent(fromResponseJSON responseJSON: String) throws -> String {
        guard let data = responseJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriberError.invalidResponse
        }
        if let content = json["content"] as? [[String: Any]] {
            let texts = content.compactMap { item in item["text"] as? String }
            guard !texts.isEmpty else { throw TranscriberError.invalidResponse }
            return texts.joined(separator: " ")
        }
        if let content = json["content"] as? String {
            return content
        }
        throw TranscriberError.invalidResponse
    }

    private func checkLoadGeneration(_ generation: Int) throws {
        guard generation == loadGeneration else {
            throw TranscriberError.notLoaded
        }
    }

    private func completeLoadWaiters(throwing error: Error? = nil) {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }
}
