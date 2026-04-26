import Foundation
import Hummingbird

// MARK: - Common

enum Wire {
    static let modelTag = "apple-intelligence:latest"
    static let serverVersion = "0.1.0"
    static let createdSeconds: Int = 1_735_689_600 // 2025-01-01T00:00:00Z
    static let modelModifiedAt = "2025-01-01T00:00:00Z"

    private static let iso8601Style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static func nowISO8601() -> String { iso8601Style.format(.now) }
    static func nowEpoch() -> Int { Int(Date.now.timeIntervalSince1970) }

    static let maxContextTokens = 4096
    static let reservedOutputTokens = 800
    static var maxInputTokens: Int { maxContextTokens - reservedOutputTokens }

    static func normalizeModel(_ name: String?) -> String { modelTag }
}

enum Role {
    static let system = "system"
    static let user = "user"
    static let assistant = "assistant"
    static let tool = "tool"
}

enum FinishReason {
    static let stop = "stop"
    static let toolCalls = "tool_calls"
}

enum ToolType {
    static let function = "function"
}

// MARK: - Ollama: Discovery

struct VersionResponse: ResponseCodable {
    let version: String
}

struct ModelDetails: ResponseCodable {
    let parent_model: String
    let format: String
    let family: String
    let families: [String]
    let parameter_size: String
    let quantization_level: String

    static let appleIntelligence = ModelDetails(
        parent_model: "",
        format: "apple-foundation-models",
        family: "apple-intelligence",
        families: ["apple-intelligence"],
        parameter_size: "3B",
        quantization_level: "unknown"
    )
}

struct ModelInfo: ResponseCodable {
    let name: String
    let model: String
    let modified_at: String
    let size: Int
    let digest: String
    let details: ModelDetails

    static let appleIntelligence = ModelInfo(
        name: Wire.modelTag,
        model: Wire.modelTag,
        modified_at: Wire.modelModifiedAt,
        size: 0,
        digest: "sha256:000000000000000000000000000000000000000000000000000000000000dead",
        details: .appleIntelligence
    )
}

struct TagsResponse: ResponseCodable {
    let models: [ModelInfo]
}

struct ShowResponse: ResponseCodable {
    let modelfile: String
    let parameters: String
    let template: String
    let details: ModelDetails

    static let appleIntelligence = ShowResponse(
        modelfile: "# Apple Intelligence on-device model (no GGUF)",
        parameters: "",
        template: "{{ .Prompt }}",
        details: .appleIntelligence
    )
}

// MARK: - Ollama: Chat

struct ChatRequest: Decodable {
    let model: String?
    let messages: [ChatMessage]
    let stream: Bool?
    let tools: [OllamaTool]?
    let options: OllamaOptions?
    let keep_alive: JSONValue?
    let format: String?
}

struct OllamaTool: Codable {
    let type: String
    let function: OllamaToolFunction
}

struct OllamaToolFunction: Codable {
    let name: String
    let description: String?
    let parameters: JSONValue?
}

struct ChatMessage: Codable {
    let role: String
    let content: String
    let tool_calls: [OllamaToolCall]?

    init(role: String, content: String, tool_calls: [OllamaToolCall]? = nil) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
    }
}

struct OllamaToolCall: Codable {
    let function: OllamaToolCallFunction
}

struct OllamaToolCallFunction: Codable {
    let name: String
    let arguments: JSONValue
}

struct ChatResponse: ResponseCodable {
    let model: String
    let createdAt: String
    let message: ChatMessage
    let done: Bool
    let doneReason: String?
    let promptEvalCount: Int?
    let evalCount: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case createdAt = "created_at"
        case message
        case done
        case doneReason = "done_reason"
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
    }
}

// MARK: - Ollama: Generate

struct OllamaOptions: Decodable {
    let temperature: Double?
    let top_p: Double?
    let top_k: Int?
    let num_predict: Int?
    let seed: Int?
    let stop: [String]?
    let repeat_penalty: Double?
}

struct GenerateRequest: Decodable {
    let model: String?
    let prompt: String
    let system: String?
    let stream: Bool?
    let options: OllamaOptions?
    let keep_alive: JSONValue?
}

struct GenerateResponse: ResponseCodable {
    let model: String
    let createdAt: String
    let response: String
    let done: Bool
    let doneReason: String?
    let promptEvalCount: Int?
    let evalCount: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case createdAt = "created_at"
        case response
        case done
        case doneReason = "done_reason"
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
    }
}

// MARK: - OpenAI

struct OpenAIChatRequest: Decodable {
    let model: String?
    let messages: [OpenAIMessage]
    let stream: Bool?
    let tools: [OpenAITool]?
    let temperature: Double?
    let top_p: Double?
    let max_tokens: Int?
    let frequency_penalty: Double?
    let presence_penalty: Double?
    let stop: JSONValue?
    let n: Int?
}

// MARK: - Embeddings

struct OllamaEmbedRequest: Decodable {
    let model: String?
    let input: EmbedInput
    let keep_alive: JSONValue?
}

enum EmbedInput: Decodable {
    case single(String)
    case batch([String])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .single(s); return }
        if let a = try? c.decode([String].self) { self = .batch(a); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected string or [string]")
    }
    var texts: [String] {
        switch self {
        case .single(let s): return [s]
        case .batch(let a): return a
        }
    }
}

struct OllamaEmbedResponse: ResponseCodable {
    let model: String
    let embeddings: [[Float]]
}

struct OpenAIEmbeddingRequest: Decodable {
    let model: String?
    let input: EmbedInput
    let encoding_format: String?
}

struct OpenAIEmbeddingObject: Codable {
    let object: String
    let index: Int
    let embedding: [Float]
}

struct OpenAIEmbeddingResponse: ResponseCodable {
    let object: String
    let data: [OpenAIEmbeddingObject]
    let model: String
    let usage: OpenAIUsage
}

// MARK: - Error responses

struct OllamaErrorResponse: ResponseCodable {
    let error: String
}

struct OpenAIErrorResponse: ResponseCodable {
    let error: OpenAIErrorDetail
}

struct OpenAIErrorDetail: Codable {
    let message: String
    let type: String
    let code: String?
}

struct OpenAIMessage: Codable {
    let role: String
    let content: String?
    let tool_calls: [OpenAIToolCall]?
    let tool_call_id: String?
    let name: String?

    init(role: String, content: String?, tool_calls: [OpenAIToolCall]? = nil,
         tool_call_id: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.name = name
    }
}

struct OpenAITool: Codable {
    let type: String
    let function: OpenAIToolFunction
}

struct OpenAIToolFunction: Codable {
    let name: String
    let description: String?
    let parameters: JSONValue?
}

struct OpenAIToolCall: Codable {
    let id: String
    let type: String
    let function: OpenAIToolCallFunction
}

struct OpenAIToolCallFunction: Codable {
    let name: String
    let arguments: String // OpenAI uses stringified JSON here
}

struct OpenAIChatChoice: Codable {
    let index: Int
    let message: OpenAIMessage
    let finish_reason: String?
}

struct OpenAIUsage: Codable {
    let prompt_tokens: Int
    let completion_tokens: Int
    let total_tokens: Int

    init(prompt_tokens: Int, completion_tokens: Int) {
        self.prompt_tokens = prompt_tokens
        self.completion_tokens = completion_tokens
        self.total_tokens = prompt_tokens + completion_tokens
    }
}

struct OpenAIChatResponse: ResponseCodable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [OpenAIChatChoice]
    let usage: OpenAIUsage
}

struct OpenAIDelta: Codable {
    let role: String?
    let content: String?
    let tool_calls: [OpenAIToolCallDelta]?
}

struct OpenAIToolCallDelta: Codable {
    let index: Int
    let id: String?
    let type: String?
    let function: OpenAIToolCallFunctionDelta?
}

struct OpenAIToolCallFunctionDelta: Codable {
    let name: String?
    let arguments: String?
}

struct OpenAIChatChunkChoice: Codable {
    let index: Int
    let delta: OpenAIDelta
    let finish_reason: String?
}

struct OpenAIChatChunk: Codable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [OpenAIChatChunkChoice]
}

struct OpenAIModelEntry: Codable {
    let id: String
    let object: String
    let created: Int
    let owned_by: String

    static let appleIntelligence = OpenAIModelEntry(
        id: Wire.modelTag,
        object: "model",
        created: Wire.createdSeconds,
        owned_by: "apple"
    )
}

struct OpenAIModelsResponse: ResponseCodable {
    let object: String
    let data: [OpenAIModelEntry]
}

// MARK: - JSONValue (for arbitrary JSON in tool params/args)

enum JSONValue: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    static func from(_ any: Any) -> JSONValue {
        if any is NSNull { return .null }
        if let b = any as? Bool { return .bool(b) }
        if let i = any as? Int { return .int(i) }
        if let d = any as? Double { return .double(d) }
        if let s = any as? String { return .string(s) }
        if let a = any as? [Any] { return .array(a.map(JSONValue.from)) }
        if let o = any as? [String: Any] {
            var dict: [String: JSONValue] = [:]
            for (k, v) in o { dict[k] = .from(v) }
            return .object(dict)
        }
        return .null
    }

    private static let compactEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    func compactJSONString() -> String {
        guard let data = try? Self.compactEncoder.encode(self),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
