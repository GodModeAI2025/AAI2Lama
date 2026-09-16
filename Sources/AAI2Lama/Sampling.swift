import Foundation

/// Client sampling parameters, normalised from Ollama `options` or OpenAI request fields.
/// Kept free of `FoundationModels` so the mapping rules stay readable in one place;
/// `ModelBridge.generationOptions(for:)` turns this into `GenerationOptions`.
struct SamplingSettings: Equatable {
    enum Mode: Equatable {
        case `default`
        case topK(Int)
        case topP(Double)
    }

    var temperature: Double?
    var maximumResponseTokens: Int?
    var mode: Mode = .default
    var seed: UInt64?

    static let none = SamplingSettings()

    /// Normalises raw client values. Out-of-range values are dropped or clamped rather than
    /// rejected, because clients such as Open WebUI send their own defaults on every request.
    ///
    /// - temperature is clamped to 0...1, the range `GenerationOptions.temperature` accepts
    ///   (OpenAI allows up to 2; higher values are capped, not rejected).
    /// - maxTokens <= 0 (Ollama's `-1` = unlimited) means "no explicit limit".
    /// - Apple's API accepts one sampling mode: `top_p` in (0, 1) wins over `top_k` >= 1.
    ///   `top_p` >= 1 and `top_k` <= 0 are Ollama's "disabled" values and fall back to default.
    /// - A seed only exists for random sampling, so it is ignored in default mode.
    init(temperature: Double? = nil, maxTokens: Int? = nil,
         topP: Double? = nil, topK: Int? = nil, seed: Int? = nil) {
        self.temperature = temperature.map { min(max($0, 0), 1) }
        self.maximumResponseTokens = maxTokens.flatMap { $0 > 0 ? $0 : nil }
        if let p = topP, p > 0, p < 1 {
            mode = .topP(p)
        } else if let k = topK, k >= 1 {
            mode = .topK(k)
        }
        if mode != .default, let seed {
            self.seed = UInt64(bitPattern: Int64(seed))
        }
    }

    init(ollama options: OllamaOptions?) {
        self.init(
            temperature: options?.temperature,
            maxTokens: options?.num_predict,
            topP: options?.top_p,
            topK: options?.top_k,
            seed: options?.seed
        )
    }

    init(openAI request: OpenAIChatRequest) {
        self.init(
            temperature: request.temperature,
            maxTokens: request.max_completion_tokens ?? request.max_tokens,
            topP: request.top_p,
            seed: request.seed
        )
    }

    /// Output tokens to keep free when truncating the prompt. A larger explicit response
    /// limit widens the reserve, but never beyond half the context window.
    func reservedOutputTokens(contextSize: Int) -> Int {
        let requested = max(Wire.reservedOutputTokens, maximumResponseTokens ?? 0)
        return min(requested, max(Wire.reservedOutputTokens, contextSize / 2))
    }
}

/// Framework-independent classification of a failed generation, used to pick an HTTP status.
enum GenerationFailureKind: String {
    case modelUnavailable = "model_unavailable"
    case assetsUnavailable = "assets_unavailable"
    case contextWindowExceeded = "context_length_exceeded"
    case guardrailViolation = "guardrail_violation"
    case refusal = "refusal"
    case unsupportedLanguage = "unsupported_language"
    case rateLimited = "rate_limited"
    case concurrentRequests = "concurrent_requests"
    case decodingFailure = "decoding_failure"
    case cancelled = "cancelled"
    case other = "generation_failed"

    /// 4xx for requests the client can change, 429 for back-off, 503 when the model itself is not ready.
    var httpStatusCode: Int {
        switch self {
        case .contextWindowExceeded, .guardrailViolation, .refusal, .unsupportedLanguage:
            return 400
        case .rateLimited, .concurrentRequests:
            return 429
        case .modelUnavailable, .assetsUnavailable:
            return 503
        case .cancelled:
            return 499
        case .decodingFailure, .other:
            return 500
        }
    }

    /// OpenAI clients branch on `error.type`; keep it close to OpenAI's own vocabulary.
    var openAIErrorType: String {
        switch httpStatusCode {
        case 400: return "invalid_request_error"
        case 429: return "rate_limit_error"
        case 503: return "service_unavailable"
        default: return "server_error"
        }
    }
}
