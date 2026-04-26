import Foundation
import FoundationModels
@preconcurrency import NaturalLanguage

struct BridgeOptions {
    let systemInstruction: String?
    let tools: [ToolSpec]
}

struct ToolSpec {
    let name: String
    let description: String?
    let parametersJSONSchema: JSONValue?
}

struct ParsedToolCall {
    let id: String
    let name: String
    let arguments: JSONValue
}

struct BridgeResult {
    let text: String
    let toolCalls: [ParsedToolCall]
    let promptTokens: Int
    let completionTokens: Int
}

enum BridgeError: Error, CustomStringConvertible {
    case modelUnavailable(String)
    case generationFailed(String)
    var description: String {
        switch self {
        case .modelUnavailable(let r): return "Apple Intelligence not available: \(r)"
        case .generationFailed(let r): return "Generation failed: \(r)"
        }
    }
}

enum ModelBridge {
    static func ensureAvailable() throws {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw BridgeError.modelUnavailable(String(describing: reason))
        @unknown default:
            throw BridgeError.modelUnavailable("unknown availability state")
        }
    }

    // MARK: - Session

    static func makeSession(options: BridgeOptions) -> LanguageModelSession {
        makeSession(instructions: combineInstructions(options))
    }

    static func makeSession(instructions: String?) -> LanguageModelSession {
        if let instructions, !instructions.isEmpty {
            return LanguageModelSession(instructions: instructions)
        }
        return LanguageModelSession()
    }

    static func combineInstructions(_ options: BridgeOptions) -> String? {
        var parts: [String] = []
        if let s = options.systemInstruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            parts.append(s)
        }
        if !options.tools.isEmpty {
            parts.append(toolPrompt(options.tools))
        }
        let joined = parts.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    static func toolPrompt(_ tools: [ToolSpec]) -> String {
        var lines: [String] = []
        lines.append("You have access to the following tools.")
        lines.append("If, and only if, calling a tool is the best way to answer the user's most recent question, respond with EXACTLY one line in this format and nothing else:")
        lines.append("<<TOOL_CALL>>{\"name\":\"<tool_name>\",\"arguments\":<json_object>}<<END>>")
        lines.append("Otherwise, respond normally in plain natural language. Never wrap normal answers in <<TOOL_CALL>>.")
        lines.append("If the conversation already contains a line starting with `Tool result for <name>:`, that tool has already been executed — DO NOT call it again. Use the result to answer the user in plain natural language.")
        lines.append("")
        lines.append("Tools:")
        for t in tools {
            let desc = t.description ?? ""
            let schema = t.parametersJSONSchema?.compactJSONString() ?? "{}"
            lines.append("- name: \(t.name)")
            if !desc.isEmpty { lines.append("  description: \(desc)") }
            lines.append("  parameters_schema: \(schema)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Stateful streaming text filter

    /// Filters out `<<TOOL_CALL>>...<<END>>` segments from a streaming text feed,
    /// even when the markers are split across deltas.
    final class StreamingTextFilter {
        private var buffer: String = ""
        private var inToolCall: Bool = false
        private var toolCallBuffer: String = ""
        private(set) var capturedToolCallJSONs: [String] = []
        private static let openTag = "<<TOOL_CALL>>"
        private static let closeTag = "<<END>>"
        private static let openTagBytes: [UInt8] = Array("<<TOOL_CALL>>".utf8)

        func feed(_ delta: String) -> String {
            buffer += delta
            var output = ""
            while !buffer.isEmpty {
                if inToolCall {
                    if let r = buffer.range(of: Self.closeTag) {
                        toolCallBuffer += buffer[..<r.lowerBound]
                        let trimmed = toolCallBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { capturedToolCallJSONs.append(trimmed) }
                        toolCallBuffer = ""
                        buffer = String(buffer[r.upperBound...])
                        inToolCall = false
                        continue
                    }
                    toolCallBuffer += buffer
                    buffer = ""
                    return output
                }
                if let r = buffer.range(of: Self.openTag) {
                    output += buffer[..<r.lowerBound]
                    buffer = String(buffer[r.upperBound...])
                    inToolCall = true
                    toolCallBuffer = ""
                    continue
                }
                let hold = longestSuffixMatchingPrefix()
                let bufUTF8 = buffer.utf8
                let safeCount = bufUTF8.count - hold
                if safeCount > 0 {
                    let idx = bufUTF8.index(bufUTF8.startIndex, offsetBy: safeCount)
                    output += buffer[..<idx]
                    buffer = String(buffer[idx...])
                }
                return output
            }
            return output
        }

        func flush() -> String {
            if inToolCall {
                buffer = ""
                toolCallBuffer = ""
                return ""
            }
            let out = buffer
            buffer = ""
            return out
        }

        func parseCapturedToolCalls() -> [ParsedToolCall] {
            capturedToolCallJSONs.compactMap { json in
                guard let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = obj["name"] as? String else { return nil }
                let argsAny = obj["arguments"] ?? [String: Any]()
                return ParsedToolCall(
                    id: "call_\(ModelBridge.shortID())",
                    name: name,
                    arguments: JSONValue.from(argsAny)
                )
            }
        }

        private func longestSuffixMatchingPrefix() -> Int {
            let utf8 = buffer.utf8
            let bufLen = utf8.count
            let markerLen = Self.openTagBytes.count
            let maxK = Swift.min(bufLen, markerLen - 1)
            if maxK <= 0 { return 0 }
            for k in stride(from: maxK, through: 1, by: -1) {
                let start = utf8.index(utf8.endIndex, offsetBy: -k)
                if utf8[start...].elementsEqual(Self.openTagBytes.prefix(k)) {
                    return k
                }
            }
            return 0
        }
    }

    // MARK: - Non-streaming

    static func respond(prompt: String, options: BridgeOptions) async throws -> BridgeResult {
        let instructions = combineInstructions(options)
        let trimmedPrompt = truncateToFit(prompt: prompt, instructions: instructions)
        let session = makeSession(instructions: instructions)
        let raw: String
        do {
            let response = try await session.respond(to: trimmedPrompt)
            raw = response.content
        } catch {
            throw BridgeError.generationFailed(String(describing: error))
        }
        let (calls, cleaned) = extractAndStrip(from: raw)
        let promptText = (instructions ?? "") + "\n" + prompt
        return BridgeResult(
            text: cleaned,
            toolCalls: calls,
            promptTokens: estimateTokens(promptText),
            completionTokens: estimateTokens(raw)
        )
    }

    // MARK: - Streaming

    struct StreamChunk {
        let textDelta: String
        let cumulativeText: String
    }

    static func stream(prompt: String, options: BridgeOptions)
        -> AsyncThrowingStream<StreamChunk, Error>
    {
        let instructions = combineInstructions(options)
        let trimmedPrompt = truncateToFit(prompt: prompt, instructions: instructions)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = makeSession(instructions: instructions)
                    var last = ""
                    let s = session.streamResponse(to: trimmedPrompt)
                    for try await partial in s {
                        let snap = stringFromPartial(partial)
                        if snap.count >= last.count, snap.hasPrefix(last) {
                            let delta = String(snap.dropFirst(last.count))
                            if !delta.isEmpty {
                                continuation.yield(StreamChunk(textDelta: delta, cumulativeText: snap))
                            }
                        } else {
                            // Snapshot diverged from last — emit full snap as delta replacement.
                            continuation.yield(StreamChunk(textDelta: snap, cumulativeText: snap))
                        }
                        last = snap
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: BridgeError.generationFailed(String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The streaming element type is a Snapshot with a `.content` property, not a raw String.
    private static func stringFromPartial<T>(_ partial: T) -> String {
        if let s = partial as? String { return s }
        let mirror = Mirror(reflecting: partial)
        for child in mirror.children {
            if child.label == "content", let s = child.value as? String { return s }
        }
        return String(describing: partial)
    }

    // MARK: - Tool-call parsing

    private static let toolCallRegex = try! NSRegularExpression(
        pattern: #"<<TOOL_CALL>>\s*(\{[\s\S]*?\})\s*<<END>>"#
    )

    static func extractToolCalls(from text: String) -> [ParsedToolCall] {
        extractAndStrip(from: text).calls
    }

    static func extractAndStrip(from text: String) -> (calls: [ParsedToolCall], cleaned: String) {
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = toolCallRegex.matches(in: text, range: nsRange)
        if matches.isEmpty { return ([], text) }

        var calls: [ParsedToolCall] = []
        for m in matches {
            guard m.numberOfRanges >= 2,
                  let r = Range(m.range(at: 1), in: text) else { continue }
            let json = String(text[r])
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = obj["name"] as? String else { continue }
            let argsAny = obj["arguments"] ?? [String: Any]()
            calls.append(ParsedToolCall(
                id: "call_\(shortID())",
                name: name,
                arguments: JSONValue.from(argsAny)
            ))
        }
        let cleaned = toolCallRegex
            .stringByReplacingMatches(in: text, range: nsRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (calls, cleaned)
    }

    // MARK: - Helpers

    static func truncateToFit(prompt: String, instructions: String?) -> String {
        let instructionTokens = estimateTokens(instructions ?? "")
        let budget = Wire.maxInputTokens - instructionTokens
        if budget <= 0 { return String(prompt.prefix(100)) }

        let promptTokens = estimateTokens(prompt)
        if promptTokens <= budget { return prompt }

        let blocks = prompt.components(separatedBy: "\n\n")
        if blocks.count <= 1 {
            let charBudget = budget * 4
            let start = prompt.index(prompt.endIndex, offsetBy: -min(charBudget, prompt.count))
            return "[...truncated...]\n\n" + prompt[start...]
        }

        var kept: [String] = []
        var usedTokens = 0
        for block in blocks.reversed() {
            let blockTokens = estimateTokens(block)
            if usedTokens + blockTokens > budget && !kept.isEmpty { break }
            kept.insert(block, at: 0)
            usedTokens += blockTokens
        }

        if kept.count < blocks.count {
            kept.insert("[...earlier messages truncated...]", at: 0)
        }
        return kept.joined(separator: "\n\n")
    }

    static func estimateTokens(_ s: String) -> Int {
        max(0, s.utf8.count * 2 / 5)
    }

    static func shortID(length: Int = 12) -> String {
        let hex = UUID().uuid
        return withUnsafeBytes(of: hex) { buf in
            buf.prefix(length / 2).map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: - Embeddings

    nonisolated(unsafe) private static let sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)

    static func embed(texts: [String]) throws -> [[Float]] {
        guard let embedding = sentenceEmbedding else {
            throw BridgeError.generationFailed("NLEmbedding for sentence not available")
        }
        let dim = embedding.dimension
        return texts.map { text in
            if let vector = embedding.vector(for: text) {
                return vector.map(Float.init)
            }
            return [Float](repeating: 0, count: dim)
        }
    }

    static var embeddingDimension: Int {
        sentenceEmbedding?.dimension ?? 512
    }
}
