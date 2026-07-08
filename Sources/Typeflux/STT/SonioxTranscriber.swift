import AVFoundation
import Foundation

// MARK: - Defaults

enum SonioxASRDefaults {
    static let model = "stt-rt-v5"
    static let suggestedModels = ["stt-rt-v5"]
    static let websocketURL = "wss://stt-rt.soniox.com/transcribe-websocket"
    /// 100ms of PCM16 at 16kHz mono: 16000 * 0.1 * 2 bytes = 3200
    static let chunkSize = 3200
    /// 1500ms of silence appended before sending the stop signal so the server
    /// can finalize any pending tokens before the stream ends.
    static let trailingSilenceBytes = 48000
    /// Timeout waiting for the server to emit `finished: true` after we send the
    /// empty-string stop signal.
    static let finishTimeout: Duration = .seconds(5)
}

// MARK: - Main Transcriber

final class SonioxTranscriber: Transcriber, RealtimeTranscriptionSessionFactory {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    static func testConnection(apiKey: String, model: String = SonioxASRDefaults.model) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw NSError(
                domain: "SonioxTranscriber",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Soniox API key is not configured."]
            )
        }
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SonioxASRDefaults.model
            : model.trimmingCharacters(in: .whitespacesAndNewlines)
        let pcmData = RemoteSTTTestAudio.pcm16MonoSilence()
        return try await SonioxSession.run(pcmData: pcmData, model: resolvedModel, apiKey: trimmedKey) { _ in }
    }

    func transcribe(audioFile: AudioFile) async throws -> String {
        try await transcribeStream(audioFile: audioFile) { _ in }
    }

    func transcribeStream(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        let apiKey = settingsStore.sonioxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settingsStore.sonioxModel

        guard !apiKey.isEmpty else {
            throw NSError(
                domain: "SonioxTranscriber",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Soniox API key is not configured."]
            )
        }

        let pcmData = try SonioxAudioConverter.convert(url: audioFile.fileURL)
        return try await SonioxSession.run(pcmData: pcmData, model: model, apiKey: apiKey, onUpdate: onUpdate)
    }

    func makeRealtimeTranscriptionSession(
        scenario _: TypefluxCloudScenario,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> any RealtimeTranscriptionSession {
        let apiKey = settingsStore.sonioxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settingsStore.sonioxModel

        guard !apiKey.isEmpty else {
            throw NSError(
                domain: "SonioxTranscriber",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Soniox API key is not configured."]
            )
        }

        let upstream = SonioxSession(model: model, apiKey: apiKey, onUpdate: onUpdate)
        return BufferedRealtimeTranscriptionSession(upstream: upstream)
    }
}

// MARK: - Audio Converter

private enum SonioxAudioConverter {
    static let targetSampleRate: Double = 16000

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
                domain: "SonioxAudioConverter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format."]
            )
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(
                domain: "SonioxAudioConverter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter."]
            )
        }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: totalSourceFrames) else {
            throw NSError(
                domain: "SonioxAudioConverter",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate source buffer."]
            )
        }
        try sourceFile.read(into: sourceBuffer)

        let ratio = targetSampleRate / sourceFormat.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(totalSourceFrames) * ratio) + 512
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            throw NSError(
                domain: "SonioxAudioConverter",
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
                domain: "SonioxAudioConverter",
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

// MARK: - WebSocket Session

/// Soniox real-time WebSocket session.
///
/// Protocol summary:
/// 1. Connect to `wss://stt-rt.soniox.com/transcribe-websocket`
/// 2. Send one JSON config message as the very first message
/// 3. Stream raw PCM16-le 16kHz mono binary frames
/// 4. Send an empty string `""` to signal end-of-stream
/// 5. Server streams back JSON responses with `tokens[]` until it sends `finished: true`
actor SonioxSession: PCM16RealtimeTranscriptionSession {
    static func run(
        pcmData: Data,
        model: String,
        apiKey: String,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        let session = SonioxSession(model: model, apiKey: apiKey, onUpdate: onUpdate)
        try await session.start()
        try await session.appendPCM16(pcmData)
        return try await session.finish()
    }

    private let model: String
    private let apiKey: String
    private let onUpdate: @Sendable (TranscriptionSnapshot) async -> Void
    private let snapshotDispatcher: SonioxSnapshotDispatcher

    // Text accumulation: `finalText` collects tokens where `is_final == true`.
    // `partialText` holds the current non-final tokens that update continuously.
    private var finalText: String = ""
    private var partialText: String = ""
    private var lastEmitted: String = ""

    private var sessionReady = false
    private var sessionFinished = false
    private var sessionError: Error?
    private var sessionReadyCont: CheckedContinuation<Void, Error>?
    private var sessionFinishedCont: CheckedContinuation<Void, Error>?

    private var urlSession: URLSession?
    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    init(
        model: String,
        apiKey: String,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) {
        self.model = model
        self.apiKey = apiKey
        self.onUpdate = onUpdate
        snapshotDispatcher = SonioxSnapshotDispatcher(onUpdate: onUpdate)
    }

    func start() async throws {
        let url = URL(string: SonioxASRDefaults.websocketURL)!
        let request = URLRequest(url: url)
        NetworkDebugLogger.logRequest(request, bodyDescription: "<websocket handshake>")
        NetworkDebugLogger.logWebSocketEvent(provider: "Soniox", phase: "connect", details: "model=\(model)")

        let socketDelegate = SonioxWSDelegate()
        let urlSession = URLSession(configuration: .default, delegate: socketDelegate, delegateQueue: nil)
        let socketTask = urlSession.webSocketTask(with: request)
        self.urlSession = urlSession
        self.socketTask = socketTask
        socketTask.resume()

        try await socketDelegate.waitUntilOpen(timeout: .seconds(10))
        NetworkDebugLogger.logWebSocketEvent(provider: "Soniox", phase: "open")

        // Send the initial config as the very first message.
        let config: [String: Any] = [
            "api_key": apiKey,
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": 16000,
            "num_channels": 1
        ]
        try await sendJSON(config, to: socketTask)

        // Start background receive loop — the server does not send a separate
        // "session ready" event; it just starts accepting audio immediately after
        // the config is sent, so we mark the session as ready right away.
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socketTask: socketTask)
        }

        sessionReady = true
        sessionReadyCont?.resume()
        sessionReadyCont = nil
    }

    func appendPCM16(_ data: Data) async throws {
        guard let socketTask else {
            throw NSError(
                domain: "SonioxSession",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Soniox WebSocket is not connected."]
            )
        }
        var offset = data.startIndex
        let chunkSize = SonioxASRDefaults.chunkSize
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            try await socketTask.send(.data(Data(data[offset ..< end])))
            offset = end
        }
    }

    func finish() async throws -> String {
        defer {
            receiveTask?.cancel()
            receiveTask = nil
            socketTask?.cancel(with: .normalClosure, reason: nil)
            socketTask = nil
            urlSession?.invalidateAndCancel()
            urlSession = nil
        }

        guard let socketTask else {
            throw NSError(
                domain: "SonioxSession",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Soniox WebSocket is not connected."]
            )
        }

        // Append trailing silence so the server can finalize any pending tokens
        // before the stream ends.
        let silencePadding = Data(count: SonioxASRDefaults.trailingSilenceBytes)
        var silenceOffset = silencePadding.startIndex
        let chunkSize = SonioxASRDefaults.chunkSize
        while silenceOffset < silencePadding.endIndex {
            let end = silencePadding.index(
                silenceOffset,
                offsetBy: chunkSize,
                limitedBy: silencePadding.endIndex
            ) ?? silencePadding.endIndex
            try await socketTask.send(.data(Data(silencePadding[silenceOffset ..< end])))
            silenceOffset = end
        }

        // Soniox protocol: sending an empty string signals end-of-stream.
        NetworkDebugLogger.logWebSocketEvent(provider: "Soniox", phase: "send", details: "<end-of-stream>")
        try await socketTask.send(.string(""))

        // Wait for the server to emit `finished: true`.
        try await waitForSessionFinished()
        await snapshotDispatcher.flush()

        return composedText().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        receiveTask?.cancel()
        receiveTask = nil
        socketTask?.cancel(with: .normalClosure, reason: nil)
        socketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionReadyCont?.resume(throwing: CancellationError())
        sessionReadyCont = nil
        sessionFinishedCont?.resume(throwing: CancellationError())
        sessionFinishedCont = nil
    }

    // MARK: - Receive loop

    private func receiveLoop(socketTask: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socketTask.receive()
                let data: Data? = switch message {
                case let .data(d): d
                case let .string(s): s.data(using: .utf8)
                @unknown default: nil
                }
                guard let data else { continue }
                NetworkDebugLogger.logWebSocketEvent(
                    provider: "Soniox",
                    phase: "receive",
                    details: String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
                )
                await handleEvent(data: data)
            } catch {
                if !Task.isCancelled {
                    NetworkDebugLogger.logError(context: "Soniox receive loop failed", error: error)
                    signalError(error)
                }
                break
            }
        }
    }

    private func handleEvent(data: Data) async {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Handle error response from server.
        if let errorMessage = json["error_message"] as? String {
            let errorType = json["error_type"] as? String ?? "UNKNOWN"
            NetworkDebugLogger.logWebSocketEvent(
                provider: "Soniox",
                phase: "error",
                details: "type=\(errorType) message=\(errorMessage)"
            )
            signalError(NSError(
                domain: "SonioxSession",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "[\(errorType)] \(errorMessage)"]
            ))
            return
        }

        // Handle `finished: true` — session complete.
        if let isFinished = json["finished"] as? Bool, isFinished {
            NetworkDebugLogger.logWebSocketEvent(provider: "Soniox", phase: "finished")
            // Promote any remaining partial text to final before closing.
            if !partialText.isEmpty {
                finalText += partialText
                partialText = ""
            }
            let preview = composedText()
            if preview != lastEmitted {
                lastEmitted = preview
                await snapshotDispatcher.submit(TranscriptionSnapshot(text: preview, isFinal: true))
            }
            sessionFinished = true
            sessionFinishedCont?.resume()
            sessionFinishedCont = nil
            return
        }

        // Handle token updates.
        guard let tokens = json["tokens"] as? [[String: Any]], !tokens.isEmpty else { return }

        var newFinalText = ""
        var newPartialText = ""

        for token in tokens {
            let text = token["text"] as? String ?? ""
            let isFinal = token["is_final"] as? Bool ?? false
            if isFinal {
                newFinalText += text
            } else {
                newPartialText += text
            }
        }

        // Soniox sends the full window each time — `newFinalText` contains all
        // confirmed tokens received in this message, and `newPartialText` contains
        // the current non-final hypothesis. We accumulate confirmed tokens into
        // `finalText` only from the delta, while `partialText` is replaced wholesale.
        if !newFinalText.isEmpty {
            finalText += newFinalText
        }
        partialText = newPartialText

        let preview = composedText()
        guard preview != lastEmitted else { return }
        lastEmitted = preview
        await snapshotDispatcher.submit(TranscriptionSnapshot(text: preview, isFinal: false))
    }

    private func composedText() -> String {
        if partialText.isEmpty {
            return finalText
        }
        return finalText + partialText
    }

    private func signalError(_ error: Error) {
        sessionError = error
        sessionReadyCont?.resume(throwing: error)
        sessionReadyCont = nil
        sessionFinishedCont?.resume(throwing: error)
        sessionFinishedCont = nil
    }

    private func waitForSessionFinished() async throws {
        if sessionFinished { return }
        if let error = sessionError { throw error }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    Task { await self.storeFinishedContinuation(cont) }
                }
            }
            group.addTask {
                try await Task.sleep(for: SonioxASRDefaults.finishTimeout)
                throw NSError(
                    domain: "SonioxSession",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for Soniox session to finish."]
                )
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func storeFinishedContinuation(_ cont: CheckedContinuation<Void, Error>) {
        if sessionFinished {
            cont.resume()
        } else if let error = sessionError {
            cont.resume(throwing: error)
        } else {
            sessionFinishedCont = cont
        }
    }

    private func sendJSON(_ json: [String: Any], to socketTask: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "SonioxSession",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode JSON payload."]
            )
        }
        NetworkDebugLogger.logWebSocketEvent(provider: "Soniox", phase: "send", details: text)
        try await socketTask.send(.string(text))
    }
}

// MARK: - Snapshot Dispatcher

private actor SonioxSnapshotDispatcher {
    private let onUpdate: @Sendable (TranscriptionSnapshot) async -> Void
    private var pendingSnapshot: TranscriptionSnapshot?
    private var isDispatching = false
    private var flushContinuations: [CheckedContinuation<Void, Never>] = []

    init(onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void) {
        self.onUpdate = onUpdate
    }

    func submit(_ snapshot: TranscriptionSnapshot) {
        pendingSnapshot = merge(existing: pendingSnapshot, incoming: snapshot)
        guard !isDispatching else { return }
        isDispatching = true
        Task { await drain() }
    }

    func flush() async {
        if !isDispatching, pendingSnapshot == nil { return }
        await withCheckedContinuation { continuation in
            flushContinuations.append(continuation)
        }
    }

    private func drain() async {
        while true {
            guard let snapshot = pendingSnapshot else {
                isDispatching = false
                let continuations = flushContinuations
                flushContinuations.removeAll()
                for continuation in continuations { continuation.resume() }
                return
            }
            pendingSnapshot = nil
            await onUpdate(snapshot)
        }
    }

    private func merge(
        existing: TranscriptionSnapshot?,
        incoming: TranscriptionSnapshot
    ) -> TranscriptionSnapshot {
        guard let existing else { return incoming }
        if incoming.isFinal || !existing.isFinal { return incoming }
        return existing
    }
}

// MARK: - WebSocket Delegate

private actor SonioxWSDelegateState {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Error>?

    func waitUntilOpen(timeout: Duration) async throws {
        if opened { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.store(continuation: continuation) }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NSError(
                    domain: "SonioxWSDelegate",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "WebSocket handshake timed out."]
                )
            }
            try await group.next()
            group.cancelAll()
        }
    }

    func markOpened() {
        opened = true
        continuation?.resume()
        continuation = nil
    }

    func markFailed(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func store(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }
}

private final class SonioxWSDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    private let state = SonioxWSDelegateState()

    func waitUntilOpen(timeout: Duration) async throws {
        try await state.waitUntilOpen(timeout: timeout)
    }

    func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?
    ) {
        Task { await state.markOpened() }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { await state.markFailed(error) }
    }
}
