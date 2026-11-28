import Foundation
import llama

public enum LlamaError: LocalizedError, Sendable {
    case modelNotFound(String)
    case loadFailed
    case contextFailed
    case tokenizationFailed
    case decodeFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let path): "Local model file was not found at \(path)."
        case .loadFailed: "Couldn't load the local GGUF model on this device."
        case .contextFailed: "Couldn't allocate inference context for the local model."
        case .tokenizationFailed: "Couldn't encode prompt tokens."
        case .decodeFailed(let code): "Local inference failed (code \(code))."
        }
    }
}

private final class LlamaCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private struct SendablePointer: @unchecked Sendable {
    let raw: OpaquePointer
}

/// Manages `llama.cpp` model weights and runs C inference on a dedicated serial queue so cooperative
/// concurrency never stalls and Stop cancels token generation right away.
public actor LlamaRunner {
    private static let backendInitOnce: Void = {
        llama_backend_init()
    }()

    private nonisolated(unsafe) var model: OpaquePointer?
    private var loadedPath: String?
    private let queue = DispatchQueue(label: "app.totality.ai.llama", qos: .userInitiated)

    public init() {}

    deinit {
        if let model {
            llama_model_free(model)
        }
    }

    public func unload() {
        if let model {
            llama_model_free(model)
        }
        model = nil
        loadedPath = nil
    }

    public func generate(
        modelURL: URL,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int = 384
    ) async throws -> String {
        _ = Self.backendInitOnce
        let path = modelURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw LlamaError.modelNotFound(path)
        }

        let loadedModel = SendablePointer(raw: try await ensureModel(at: path))
        let cancelFlag = LlamaCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let output = try Self.runInference(
                            model: loadedModel.raw,
                            systemPrompt: systemPrompt,
                            userPrompt: userPrompt,
                            maxTokens: maxTokens,
                            cancellation: cancelFlag
                        )
                        continuation.resume(returning: output)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    private func ensureModel(at path: String) async throws -> OpaquePointer {
        if let model, loadedPath == path {
            return model
        }
        unload()
        let loaded = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SendablePointer, Error>) in
            queue.async {
                var params = llama_model_default_params()
                #if targetEnvironment(simulator)
                params.n_gpu_layers = 0
                #else
                params.n_gpu_layers = 99
                #endif
                if let ptr = llama_model_load_from_file(path, params) {
                    continuation.resume(returning: SendablePointer(raw: ptr))
                } else {
                    continuation.resume(throwing: LlamaError.loadFailed)
                }
            }
        }
        self.model = loaded.raw
        self.loadedPath = path
        return loaded.raw
    }

    private static func runInference(
        model: OpaquePointer,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        cancellation: LlamaCancellation
    ) throws -> String {
        if cancellation.isCancelled { throw CancellationError() }

        var ctxParams = llama_context_default_params()
        let batchCapacity = 512
        ctxParams.n_ctx = 4096
        ctxParams.n_batch = UInt32(batchCapacity)
        let threads = Int32(max(2, min(6, ProcessInfo.processInfo.processorCount - 1)))
        ctxParams.n_threads = threads
        ctxParams.n_threads_batch = threads

        guard let ctx = llama_init_from_model(model, ctxParams) else {
            throw LlamaError.contextFailed
        }
        defer { llama_free(ctx) }

        guard let vocab = llama_model_get_vocab(model) else {
            throw LlamaError.loadFailed
        }

        let formatted = formatPrompt(model: model, systemPrompt: systemPrompt, userPrompt: userPrompt)
        var promptTokens = try tokenize(formatted, vocab: vocab, addSpecial: true, parseSpecial: true)
        let maxPromptTokens = Int(ctxParams.n_ctx) - maxTokens - 32
        if promptTokens.count > maxPromptTokens, maxPromptTokens > 64 {
            promptTokens = Array(promptTokens.suffix(maxPromptTokens))
        }

        var cursor = 0
        while cursor < promptTokens.count {
            if cancellation.isCancelled { throw CancellationError() }
            let end = min(cursor + batchCapacity, promptTokens.count)
            var slice = Array(promptTokens[cursor..<end])
            let status = slice.withUnsafeMutableBufferPointer { buf -> Int32 in
                let batch = llama_batch_get_one(buf.baseAddress, Int32(buf.count))
                return llama_decode(ctx, batch)
            }
            guard status == 0 else {
                throw LlamaError.decodeFailed(status)
            }
            cursor = end
        }

        let sparams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(sparams) else {
            throw LlamaError.contextFailed
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(64, 1.08, 0.0, 0.0))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.35))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(42))

        var outputBytes: [UInt8] = []
        let stopMarkers = ["<|im_end|>", "<|eot_id|>", "</s>"]

        for _ in 0..<maxTokens {
            if cancellation.isCancelled { throw CancellationError() }
            var token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }

            let piece = tokenPieceBytes(token, vocab: vocab)
            outputBytes.append(contentsOf: piece)

            if let text = String(bytes: outputBytes, encoding: .utf8),
               stopMarkers.contains(where: { text.hasSuffix($0) }) {
                break
            }

            let status = withUnsafeMutablePointer(to: &token) { ptr in
                let batch = llama_batch_get_one(ptr, 1)
                return llama_decode(ctx, batch)
            }
            if status != 0 { break }
        }

        var raw = String(decoding: outputBytes, as: UTF8.self)
        for marker in stopMarkers {
            if let range = raw.range(of: marker) {
                raw = String(raw[..<range.lowerBound])
            }
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatPrompt(model: OpaquePointer, systemPrompt: String, userPrompt: String) -> String {
        if let templatePtr = llama_model_chat_template(model, nil) {
            let sysRole = strdup("system")
            let sysContent = strdup(systemPrompt)
            let usrRole = strdup("user")
            let usrContent = strdup(userPrompt)
            defer {
                free(sysRole)
                free(sysContent)
                free(usrRole)
                free(usrContent)
            }
            var messages = [
                llama_chat_message(role: sysRole, content: sysContent),
                llama_chat_message(role: usrRole, content: usrContent),
            ]
            let approx = max(1024, (systemPrompt.utf8.count + userPrompt.utf8.count) * 2)
            var buffer = [CChar](repeating: 0, count: approx)
            let written = messages.withUnsafeMutableBufferPointer { msgPtr in
                llama_chat_apply_template(templatePtr, msgPtr.baseAddress, msgPtr.count, true, &buffer, Int32(buffer.count))
            }
            if written > 0 {
                if Int(written) >= buffer.count {
                    buffer = [CChar](repeating: 0, count: Int(written) + 8)
                    let retry = messages.withUnsafeMutableBufferPointer { msgPtr in
                        llama_chat_apply_template(templatePtr, msgPtr.baseAddress, msgPtr.count, true, &buffer, Int32(buffer.count))
                    }
                    if retry > 0, retry < buffer.count {
                        let utf8 = buffer.prefix(Int(retry)).map { UInt8(bitPattern: $0) }
                        return String(decoding: utf8, as: UTF8.self)
                    }
                } else {
                    let utf8 = buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }
                    return String(decoding: utf8, as: UTF8.self)
                }
            }
        }
        return "<|im_start|>system\n\(systemPrompt)\n<|im_end|>\n<|im_start|>user\n\(userPrompt)\n<|im_end|>\n<|im_start|>assistant\n"
    }

    private static func tokenize(
        _ text: String,
        vocab: OpaquePointer,
        addSpecial: Bool,
        parseSpecial: Bool
    ) throws -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        let textLen = Int32(max(0, utf8.count - 1))
        let countGuess = utf8.withUnsafeBufferPointer { ptr in
            llama_tokenize(vocab, ptr.baseAddress, textLen, nil, 0, addSpecial, parseSpecial)
        }
        let needed = countGuess < 0 ? Int(-countGuess) : Int(countGuess)
        guard needed > 0 else { throw LlamaError.tokenizationFailed }

        var tokens = [llama_token](repeating: 0, count: needed)
        let actual = utf8.withUnsafeBufferPointer { textPtr in
            tokens.withUnsafeMutableBufferPointer { tokPtr in
                llama_tokenize(vocab, textPtr.baseAddress, textLen, tokPtr.baseAddress, Int32(needed), addSpecial, parseSpecial)
            }
        }
        guard actual >= 0 else { throw LlamaError.tokenizationFailed }
        return Array(tokens.prefix(Int(actual)))
    }

    private static func tokenPieceBytes(_ token: llama_token, vocab: OpaquePointer) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 128)
        var length = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if length < 0 {
            let needed = Int(-length)
            buf = [CChar](repeating: 0, count: needed)
            length = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        }
        guard length > 0 else { return [] }
        return buf.prefix(Int(length)).map { UInt8(bitPattern: $0) }
    }
}
