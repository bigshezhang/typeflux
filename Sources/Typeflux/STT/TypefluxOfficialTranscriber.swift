import AVFoundation
import Foundation
import os

// MARK: - LLM Integration Types

/// Configuration for server-side LLM rewrite, sent as part of the ASR start message.
/// When included, the server runs an LLM pass after transcription and streams the
/// result back over the same WebSocket connection.
struct ASRLLMConfig: Encodable {
    /// Fully-assembled system prompt (language policy + persona + environment context).
    let systemPrompt: String
    /// User prompt template containing "{{transcript}}" as a placeholder for the
    /// final transcription text. The server substitutes it before calling the LLM.
    let userPromptTemplate: String
    /// Stable identifier for the persona used to build the prompts. This is sent
    /// as a request header only, not as part of the WebSocket start payload.
    let personaID: UUID?

    init(systemPrompt: String, userPromptTemplate: String, personaID: UUID? = nil) {
        self.systemPrompt = systemPrompt
        self.userPromptTemplate = userPromptTemplate
        self.personaID = personaID
    }

    enum CodingKeys: String, CodingKey {
        case systemPrompt = "system_prompt"
        case userPromptTemplate = "user_prompt_template"
    }
}

/// Transcribers that support a merged ASR + LLM rewrite in a single WebSocket session.
protocol TypefluxCloudLLMIntegratedTranscriber: TypefluxCloudScenarioAwareTranscriber {
    func transcribeStreamWithLLMRewrite(
        audioFile: AudioFile,
        llmConfig: ASRLLMConfig,
        scenario: TypefluxCloudScenario,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart: @escaping @Sendable () async -> Void,
        onLLMChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> (transcript: String, rewritten: String?)
}

protocol TypefluxOfficialASRTransport: Sendable {
    func transcribeViaWebSocket(
        pcmData: Data,
        apiBaseURL: String,
        token: String,
        provider: String,
        scenario: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String

    func transcribeViaWebSocketWithLLM(
        pcmData: Data,
        apiBaseURL: String,
        token: String,
        provider: String,
        scenario: TypefluxCloudScenario,
        llmConfig: ASRLLMConfig,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart: @escaping @Sendable () async -> Void,
        onLLMChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> (transcript: String, rewritten: String?)
}

// MARK: - Main Transcriber

final class TypefluxOfficialTranscriber: TypefluxCloudScenarioAwareTranscriber, TypefluxCloudLLMIntegratedTranscriber,
    RealtimeTranscriptionSessionFactory {
    private let routingClient: any TypefluxOfficialASRRoutingClient
    private let transport: any TypefluxOfficialASRTransport
    private let serverRegistry: any TypefluxASRServerProviding
    private let accessTokenProvider: @Sendable () async -> String?

    init(
        routingClient: any TypefluxOfficialASRRoutingClient = TypefluxOfficialASRRoutingHTTPClient(),
        transport: any TypefluxOfficialASRTransport = DefaultTypefluxOfficialASRTransport(),
        serverRegistry: any TypefluxASRServerProviding = TypefluxASRServerRegistry.shared,
        accessTokenProvider: @escaping @Sendable () async -> String? = {
            await MainActor.run { AuthState.shared.accessToken }
        }
    ) {
        self.routingClient = routingClient
        self.transport = transport
        self.serverRegistry = serverRegistry
        self.accessTokenProvider = accessTokenProvider
    }

    func transcribeStream(
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        let token = await accessTokenProvider()
        guard let token, !token.isEmpty else {
            throw TypefluxOfficialASRError.notLoggedIn
        }

        let pcmData = try CloudASRAudioConverter.convert(url: audioFile.fileURL)
        let route = try await routingClient.fetchRoute(accessToken: token, scenario: scenario)
        let asrToken: String
        let asrProvider: String
        let serverBaseURLs: [URL]
        switch route {
        case let .webSocket(token, _, _, _, servers):
            asrToken = token
            asrProvider = TypefluxOfficialASRTokenScope.provider(from: token) ?? "default"
            serverBaseURLs = servers
        }

        return try await Self.runWithASRServerFailover(
            preferredServers: serverBaseURLs,
            serverRegistry: serverRegistry
        ) { apiBaseURL in
            try await transport.transcribeViaWebSocket(
                pcmData: pcmData,
                apiBaseURL: apiBaseURL,
                token: asrToken,
                provider: asrProvider,
                scenario: scenario,
                onUpdate: onUpdate
            )
        }
    }

    func transcribeStreamWithLLMRewrite(
        audioFile: AudioFile,
        llmConfig: ASRLLMConfig,
        scenario: TypefluxCloudScenario,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart: @escaping @Sendable () async -> Void,
        onLLMChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> (transcript: String, rewritten: String?) {
        let token = await accessTokenProvider()
        guard let token, !token.isEmpty else {
            throw TypefluxOfficialASRError.notLoggedIn
        }

        let pcmData = try CloudASRAudioConverter.convert(url: audioFile.fileURL)
        let route = try await routingClient.fetchRoute(accessToken: token, scenario: scenario)
        let asrToken: String
        let asrProvider: String
        let serverBaseURLs: [URL]
        switch route {
        case let .webSocket(token, _, _, _, servers):
            asrToken = token
            asrProvider = TypefluxOfficialASRTokenScope.provider(from: token) ?? "default"
            serverBaseURLs = servers
        }

        return try await Self.runWithASRServerFailover(
            preferredServers: serverBaseURLs,
            serverRegistry: serverRegistry
        ) { apiBaseURL in
            try await transport.transcribeViaWebSocketWithLLM(
                pcmData: pcmData,
                apiBaseURL: apiBaseURL,
                token: asrToken,
                provider: asrProvider,
                scenario: scenario,
                llmConfig: llmConfig,
                onASRUpdate: onASRUpdate,
                onLLMStart: onLLMStart,
                onLLMChunk: onLLMChunk
            )
        }
    }

    func makeRealtimeTranscriptionSession(
        scenario: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> any RealtimeTranscriptionSession {
        BufferedRealtimeTranscriptionSession(
            upstream: DeferredPCM16RealtimeTranscriptionSession {
                [accessTokenProvider, routingClient, serverRegistry] in
                let token = await accessTokenProvider()
                guard let token, !token.isEmpty else {
                    throw TypefluxOfficialASRError.notLoggedIn
                }

                let route = try await routingClient.fetchRoute(accessToken: token, scenario: scenario)
                let asrToken: String
                let asrProvider: String
                let serverBaseURLs: [URL]
                switch route {
                case let .webSocket(token, _, _, _, servers):
                    asrToken = token
                    asrProvider = TypefluxOfficialASRTokenScope.provider(from: token) ?? "default"
                    serverBaseURLs = servers
                }

                let baseURLs = await serverRegistry.orderedServers(preferred: serverBaseURLs)
                guard let baseURL = baseURLs.first else {
                    throw TypefluxOfficialASRError.connectionFailed("No Typeflux Cloud endpoint configured.")
                }

                return TypefluxOfficialRealtimePCMStream(
                    apiBaseURL: baseURL.absoluteString,
                    token: asrToken,
                    provider: asrProvider,
                    scenario: scenario,
                    onUpdate: onUpdate
                )
            }
        )
    }

    static func testConnection() async throws -> String {
        let token = await MainActor.run { AuthState.shared.accessToken }
        guard let token, !token.isEmpty else {
            throw TypefluxOfficialASRError.notLoggedIn
        }

        let pcmData = RemoteSTTTestAudio.pcm16MonoSilence()
        let routingClient = TypefluxOfficialASRRoutingHTTPClient()
        let route = try await routingClient.fetchRoute(accessToken: token, scenario: .modelSetup)
        let asrToken: String
        let asrProvider: String
        let serverBaseURLs: [URL]
        switch route {
        case let .webSocket(token, _, _, _, servers):
            asrToken = token
            asrProvider = TypefluxOfficialASRTokenScope.provider(from: token) ?? "default"
            serverBaseURLs = servers
        }

        return try await runWithASRServerFailover(preferredServers: serverBaseURLs) { apiBaseURL in
            try await TypefluxOfficialASRSession.run(
                pcmData: pcmData,
                apiBaseURL: apiBaseURL,
                token: asrToken,
                scenario: .modelSetup,
                provider: asrProvider
            ) { _ in }
        }
    }

    /// Runs an ASR session against the highest-priority cloud endpoint and
    /// transparently retries against the next endpoint when the connection
    /// fails. Once a session begins streaming results we let it run to
    /// completion against the chosen endpoint — mid-session migration is not
    /// supported because that would risk reordering or duplicating audio.
    static func runWithASRServerFailover<T>(
        preferredServers: [URL],
        serverRegistry: any TypefluxASRServerProviding = TypefluxASRServerRegistry.shared,
        operation: @Sendable (String) async throws -> T
    ) async throws -> T {
        let baseURLs = await serverRegistry.orderedServers(preferred: preferredServers)

        guard !baseURLs.isEmpty else {
            throw TypefluxOfficialASRError.connectionFailed("No Typeflux Cloud endpoint configured.")
        }

        var lastError: Error?
        for baseURL in baseURLs {
            do {
                return try await operation(baseURL.absoluteString)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error where TypefluxCloudBillingError.fromError(error) != nil {
                throw TypefluxCloudBillingError.fromError(error) ?? error
            } catch let error as TypefluxOfficialASRError {
                await serverRegistry.reportFailure(baseURL, error: error)
                lastError = error
                continue
            } catch {
                await serverRegistry.reportFailure(baseURL, error: error)
                lastError = error
                continue
            }
        }
        throw lastError ?? TypefluxOfficialASRError.connectionFailed("All endpoints failed.")
    }
}

struct DefaultTypefluxOfficialASRTransport: TypefluxOfficialASRTransport {
    func transcribeViaWebSocket(
        pcmData: Data,
        apiBaseURL: String,
        token: String,
        provider: String,
        scenario: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        try await TypefluxOfficialASRSession.run(
            pcmData: pcmData,
            apiBaseURL: apiBaseURL,
            token: token,
            scenario: scenario,
            provider: provider,
            onUpdate: onUpdate
        )
    }

    func transcribeViaWebSocketWithLLM(
        pcmData: Data,
        apiBaseURL: String,
        token: String,
        provider: String,
        scenario: TypefluxCloudScenario,
        llmConfig: ASRLLMConfig,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart: @escaping @Sendable () async -> Void,
        onLLMChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> (transcript: String, rewritten: String?) {
        try await TypefluxOfficialASRSession.runWithLLM(
            pcmData: pcmData,
            apiBaseURL: apiBaseURL,
            token: token,
            scenario: scenario,
            provider: provider,
            llmConfig: llmConfig,
            onASRUpdate: onASRUpdate,
            onLLMStart: onLLMStart,
            onLLMChunk: onLLMChunk
        )
    }

}

// MARK: - Errors

enum TypefluxOfficialASRError: LocalizedError {
    case notLoggedIn
    case connectionFailed(String)
    case serverError(String)
    case unexpectedClose

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Please sign in to use Typeflux Cloud speech recognition."
        case let .connectionFailed(reason):
            "Failed to connect to Typeflux ASR service: \(reason)"
        case let .serverError(message):
            "Typeflux ASR error: \(message)"
        case .unexpectedClose:
            "The Typeflux ASR connection closed unexpectedly."
        }
    }
}

enum TypefluxOfficialASRClosePolicy {
    static func shouldTreatReceiveFailureAsUnexpectedClose(
        completed: Bool,
        finalSegments: [String]
    ) -> Bool {
        !completed && finalSegments.isEmpty
    }

    static func isNormalProviderCompletion(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("close 1000")
            && lowercased.contains("normal")
            && lowercased.contains("finish last sequence")
    }
}

// MARK: - Audio Converter

enum CloudASRAudioConverter {
    static let targetSampleRate: Double = 16000
    /// 100ms of PCM16 at 16kHz mono = 3200 bytes
    static let chunkSize: Int = 3200

    static func convert(url: URL) throws -> Data {
        let sourceFile = try AVAudioFile(forReading: url)
        let sourceFormat = sourceFile.processingFormat
        let totalSourceFrames = AVAudioFrameCount(sourceFile.length)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(
                domain: "CloudASRAudioConverter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format."]
            )
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(
                domain: "CloudASRAudioConverter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter."]
            )
        }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: totalSourceFrames) else {
            throw NSError(
                domain: "CloudASRAudioConverter",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate source buffer."]
            )
        }
        try sourceFile.read(into: sourceBuffer)

        let ratio = targetSampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(totalSourceFrames) * ratio) + 512
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            throw NSError(
                domain: "CloudASRAudioConverter",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate target buffer."]
            )
        }

        var hasProvidedInput = false
        var convertError: NSError?
        let status = converter.convert(to: targetBuffer, error: &convertError) { _, outStatus in
            if hasProvidedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let convertError { throw convertError }
        guard status != .error else {
            throw NSError(
                domain: "CloudASRAudioConverter",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed."]
            )
        }

        let bytesPerFrame = Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(targetBuffer.frameLength) * bytesPerFrame
        guard let channelData = targetBuffer.int16ChannelData else { return Data() }
        return Data(bytes: channelData[0], count: byteCount)
    }
}

enum TypefluxOfficialASRRequestFactory {
    static func makeWebSocketRequest(
        apiBaseURL: String,
        token: String,
        scenario: TypefluxCloudScenario,
        provider: String = "default",
        personaID: UUID? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(string: apiBaseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false
        else {
            throw TypefluxOfficialASRError.connectionFailed("Invalid WebSocket server URL: \(apiBaseURL)")
        }
        components.scheme = scheme == "https" ? "wss" : "ws"
        components.path = "/api/v1/asr/ws/\(provider)"
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw TypefluxOfficialASRError.connectionFailed("Invalid WebSocket server URL: \(apiBaseURL)")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        TypefluxCloudRequestHeaders.applyCloudHeaders(scenario: scenario, to: &request)
        TypefluxCloudRequestHeaders.applyPersonaID(personaID, to: &request)
        return request
    }
}

enum TypefluxOfficialASRTokenScope {
    static func provider(from token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = payload.count % 4
        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }

        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONDecoder().decode(Claims.self, from: data)
        else {
            return nil
        }

        let provider = claims.asrProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard allowedProviders.contains(provider) else { return nil }
        return provider
    }

    private static let allowedProviders: Set<String> = ["aliyun", "doubao", "google"]

    private struct Claims: Decodable {
        let asrProvider: String

        enum CodingKeys: String, CodingKey {
            case asrProvider = "asr_provider"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            asrProvider = try container.decodeIfPresent(String.self, forKey: .asrProvider) ?? ""
        }
    }
}

// MARK: - WebSocket ASR Session

private actor TypefluxOfficialASRSession {
    static func run(
        pcmData: Data,
        apiBaseURL: String,
        token: String,
        scenario: TypefluxCloudScenario,
        provider: String = "default",
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        let session = TypefluxOfficialASRSession(
            pcmData: pcmData,
            apiBaseURL: apiBaseURL,
            token: token,
            scenario: scenario,
            provider: provider,
            personaID: nil,
            onASRUpdate: onUpdate,
            llmConfig: nil,
            onLLMStart: nil,
            onLLMChunk: nil
        )
        let (transcript, _) = try await session.execute()
        return transcript
    }

    static func runWithLLM(
        pcmData: Data,
        apiBaseURL: String,
        token: String,
        scenario: TypefluxCloudScenario,
        provider: String = "default",
        llmConfig: ASRLLMConfig,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart: @escaping @Sendable () async -> Void,
        onLLMChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> (transcript: String, rewritten: String?) {
        let session = TypefluxOfficialASRSession(
            pcmData: pcmData,
            apiBaseURL: apiBaseURL,
            token: token,
            scenario: scenario,
            provider: provider,
            personaID: llmConfig.personaID,
            onASRUpdate: onASRUpdate,
            llmConfig: llmConfig,
            onLLMStart: onLLMStart,
            onLLMChunk: onLLMChunk
        )
        return try await session.execute()
    }

    private let pcmData: Data
    private let apiBaseURL: String
    private let token: String
    private let scenario: TypefluxCloudScenario
    private let provider: String
    private let personaID: UUID?
    private let onASRUpdate: @Sendable (TranscriptionSnapshot) async -> Void
    private let llmConfig: ASRLLMConfig?
    private let onLLMStart: (@Sendable () async -> Void)?
    private let onLLMChunk: (@Sendable (String) async -> Void)?
    private let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "TypefluxOfficialASRSession")

    private var finalSegments: [String] = []
    private var currentPartialText: String = ""
    private var completed = false
    private var sessionError: Error?
    private var rewrittenText: String?

    private init(
        pcmData: Data,
        apiBaseURL: String,
        token: String,
        scenario: TypefluxCloudScenario,
        provider: String,
        personaID: UUID?,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        llmConfig: ASRLLMConfig?,
        onLLMStart: (@Sendable () async -> Void)?,
        onLLMChunk: (@Sendable (String) async -> Void)?
    ) {
        self.pcmData = pcmData
        self.apiBaseURL = apiBaseURL
        self.token = token
        self.scenario = scenario
        self.provider = provider
        self.personaID = personaID
        self.onASRUpdate = onASRUpdate
        self.llmConfig = llmConfig
        self.onLLMStart = onLLMStart
        self.onLLMChunk = onLLMChunk
    }

    private func execute() async throws -> (transcript: String, rewritten: String?) {
        let request = try TypefluxOfficialASRRequestFactory.makeWebSocketRequest(
            apiBaseURL: apiBaseURL,
            token: token,
            scenario: scenario,
            provider: provider,
            personaID: personaID
        )
        let session = URLSession(configuration: .default)
        let socketTask = session.webSocketTask(with: request)
        socketTask.resume()

        defer {
            socketTask.cancel(with: .goingAway, reason: nil)
            session.finishTasksAndInvalidate()
        }

        // Build start message; include LLM config when present.
        let audioConfig: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16000,
            "channel": 1,
            "lang": "auto"
        ]
        var config: [String: Any] = ["audio": audioConfig]
        if let llmConfig {
            config["llm"] = [
                "system_prompt": llmConfig.systemPrompt,
                "user_prompt_template": llmConfig.userPromptTemplate
            ]
        }
        let startMessage: [String: Any] = ["type": "start", "config": config]
        let startData = try JSONSerialization.data(withJSONObject: startMessage)
        try await socketTask.send(.string(String(data: startData, encoding: .utf8)!))

        // Start receive loop in a separate task
        let receiveTask = Task { [self] in
            await receiveLoop(socketTask: socketTask)
        }

        // Stream audio chunks
        let chunkSize = CloudASRAudioConverter.chunkSize
        var offset = pcmData.startIndex
        while offset < pcmData.endIndex {
            let end = pcmData.index(offset, offsetBy: chunkSize, limitedBy: pcmData.endIndex) ?? pcmData.endIndex
            try await socketTask.send(.data(Data(pcmData[offset ..< end])))
            offset = end
        }

        // Send stop message
        let stopMessage = try JSONSerialization.data(withJSONObject: ["type": "stop"])
        try await socketTask.send(.string(String(data: stopMessage, encoding: .utf8)!))

        // Wait for receive loop to complete
        await receiveTask.value

        if let error = sessionError {
            let transcript = assembleTranscript()
            if llmConfig != nil,
               !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               TypefluxCloudBillingError.fromError(error) != nil {
                throw TypefluxCloudIntegratedRewriteError(
                    transcript: transcript,
                    underlyingError: error
                )
            }
            throw error
        }

        let transcript = assembleTranscript()
        if !transcript.isEmpty {
            await onASRUpdate(TranscriptionSnapshot(text: transcript, isFinal: true))
        }
        return (transcript: transcript, rewritten: rewrittenText)
    }

    private func receiveLoop(socketTask: URLSessionWebSocketTask) async {
        while !completed {
            do {
                let message = try await socketTask.receive()
                switch message {
                case let .string(text):
                    await handleTextMessage(text)
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleTextMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if TypefluxOfficialASRClosePolicy.shouldTreatReceiveFailureAsUnexpectedClose(
                    completed: completed,
                    finalSegments: finalSegments
                ) {
                    logger.error("WebSocket receive error: \(error.localizedDescription)")
                    sessionError = sessionError
                        ?? TypefluxCloudBillingError.fromError(error)
                        ?? TypefluxOfficialASRError.unexpectedClose
                }
                completed = true
            }
        }
    }

    private func handleTextMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "partial":
            let partialText = json["text"] as? String ?? ""
            currentPartialText = partialText
            let display = assembleTranscript()
            await onASRUpdate(TranscriptionSnapshot(text: display, isFinal: false))

        case "final":
            let finalText = json["text"] as? String ?? ""
            if !finalText.isEmpty {
                finalSegments.append(finalText)
            }
            currentPartialText = ""
            let display = assembleTranscript()
            await onASRUpdate(TranscriptionSnapshot(text: display, isFinal: true))

        case "event":
            let eventText = json["text"] as? String ?? ""
            if eventText == "completed" {
                // If LLM is pending, keep the receive loop alive to handle llm_* messages.
                if llmConfig == nil {
                    completed = true
                }
            }

        case "llm_start":
            await onLLMStart?()

        case "llm_chunk":
            let chunkText = json["text"] as? String ?? ""
            if !chunkText.isEmpty {
                await onLLMChunk?(chunkText)
            }

        case "llm_final":
            let finalRewrite = json["text"] as? String ?? ""
            rewrittenText = finalRewrite.isEmpty ? nil : finalRewrite
            completed = true

        case "error":
            let errorText = json["error"] as? String ?? "Unknown error"
            if TypefluxOfficialASRClosePolicy.isNormalProviderCompletion(errorText) {
                completed = true
                return
            }
            logger.error("ASR server error: \(errorText)")
            sessionError = TypefluxCloudBillingError.fromMessage(errorText)
                ?? TypefluxOfficialASRError.serverError(errorText)
            completed = true

        default:
            break
        }
    }

    private func assembleTranscript() -> String {
        var parts = finalSegments
        if !currentPartialText.isEmpty {
            parts.append(currentPartialText)
        }
        return parts.joined()
    }
}

private actor TypefluxOfficialRealtimePCMStream: PCM16RealtimeTranscriptionSession {
    private let apiBaseURL: String
    private let token: String
    private let provider: String
    private let scenario: TypefluxCloudScenario
    private let onUpdate: @Sendable (TranscriptionSnapshot) async -> Void
    private let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "TypefluxOfficialRealtimePCMStream")

    private var urlSession: URLSession?
    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var finalSegments: [String] = []
    private var currentPartialText = ""
    private var completed = false
    private var sessionError: Error?

    init(
        apiBaseURL: String,
        token: String,
        provider: String = "default",
        scenario: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) {
        self.apiBaseURL = apiBaseURL
        self.token = token
        self.provider = provider
        self.scenario = scenario
        self.onUpdate = onUpdate
    }

    func start() async throws {
        let request = try TypefluxOfficialASRRequestFactory.makeWebSocketRequest(
            apiBaseURL: apiBaseURL,
            token: token,
            scenario: scenario,
            provider: provider
        )
        let session = URLSession(configuration: .default)
        let socketTask = session.webSocketTask(with: request)
        urlSession = session
        self.socketTask = socketTask
        socketTask.resume()

        let audioConfig: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16000,
            "channel": 1,
            "lang": "auto"
        ]
        let startMessage: [String: Any] = ["type": "start", "config": ["audio": audioConfig]]
        try await sendJSON(startMessage)

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func appendPCM16(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        guard let socketTask else {
            throw TypefluxOfficialASRError.connectionFailed("Realtime WebSocket is not connected.")
        }
        try await socketTask.send(.data(Data(data)))
    }

    func finish() async throws -> String {
        try await sendJSON(["type": "stop"])
        await receiveTask?.value

        if let sessionError {
            throw sessionError
        }

        let transcript = assembleTranscript()
        if !transcript.isEmpty {
            await onUpdate(TranscriptionSnapshot(text: transcript, isFinal: true))
        }
        await close()
        return transcript
    }

    func cancel() async {
        await close()
    }

    private func close() async {
        completed = true
        receiveTask?.cancel()
        receiveTask = nil
        socketTask?.cancel(with: .normalClosure, reason: nil)
        socketTask = nil
        urlSession?.finishTasksAndInvalidate()
        urlSession = nil
    }

    private func receiveLoop() async {
        while !completed, !Task.isCancelled {
            do {
                guard let socketTask else { break }
                let message = try await socketTask.receive()
                switch message {
                case let .string(text):
                    await handleTextMessage(text)
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleTextMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled,
                   TypefluxOfficialASRClosePolicy.shouldTreatReceiveFailureAsUnexpectedClose(
                       completed: completed,
                       finalSegments: finalSegments
                   ) {
                    logger.error("WebSocket receive error: \(error.localizedDescription)")
                    sessionError = sessionError
                        ?? TypefluxCloudBillingError.fromError(error)
                        ?? TypefluxOfficialASRError.unexpectedClose
                }
                completed = true
            }
        }
    }

    private func handleTextMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "partial":
            currentPartialText = json["text"] as? String ?? ""
            await onUpdate(TranscriptionSnapshot(text: assembleTranscript(), isFinal: false))
        case "final":
            let finalText = json["text"] as? String ?? ""
            if !finalText.isEmpty {
                finalSegments.append(finalText)
            }
            currentPartialText = ""
            await onUpdate(TranscriptionSnapshot(text: assembleTranscript(), isFinal: true))
        case "event":
            if (json["text"] as? String) == "completed" {
                completed = true
            }
        case "error":
            let errorText = json["error"] as? String ?? "Unknown error"
            if TypefluxOfficialASRClosePolicy.isNormalProviderCompletion(errorText) {
                completed = true
                return
            }
            logger.error("ASR server error: \(errorText)")
            sessionError = TypefluxCloudBillingError.fromMessage(errorText)
                ?? TypefluxOfficialASRError.serverError(errorText)
            completed = true
        default:
            break
        }
    }

    private func sendJSON(_ json: [String: Any]) async throws {
        guard let socketTask else {
            throw TypefluxOfficialASRError.connectionFailed("Realtime WebSocket is not connected.")
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TypefluxOfficialASRError.connectionFailed("Failed to encode realtime message.")
        }
        try await socketTask.send(.string(text))
    }

    private func assembleTranscript() -> String {
        var parts = finalSegments
        if !currentPartialText.isEmpty {
            parts.append(currentPartialText)
        }
        return parts.joined()
    }
}
