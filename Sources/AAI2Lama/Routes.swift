import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

enum Routes {
    static func register<Context: RequestContext>(on router: Router<Context>) {
        router.get("/") { _, _ in
            "Ollama is running"
        }
        router.head("/") { _, _ -> Response in
            Response(status: .ok)
        }

        router.get("/api/version") { _, _ in
            VersionResponse(version: Wire.serverVersion)
        }

        router.get("/api/tags") { _, _ -> Response in
            if Proxy.isEnabled() {
                let merged = await Proxy.mergedTags()
                return try jsonResponse(merged)
            }
            return try jsonResponse(TagsResponse(models: [.appleIntelligence]))
        }

        router.post("/api/show") { request, context -> Response in
            var req = request
            let raw = try await req.collectBody(upTo: 1_048_576)
            if let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
               let name = obj["name"] as? String,
               !name.hasPrefix("apple-intelligence") {
                if Proxy.isEnabled() {
                    return try await Proxy.forward(request: request, body: raw)
                }
            }
            return try jsonResponse(ShowResponse.appleIntelligence)
        }

        router.post("/api/chat") { request, context -> Response in
            var req = request
            let raw = try await req.collectBody(upTo: 10_485_760)
            let body = try JSONDecoder().decode(ChatRequest.self, from: raw)
            if Proxy.forwardIfNeeded(request: request, model: body.model) {
                let isStream = body.stream ?? true
                return isStream
                    ? try await Proxy.forwardStreaming(request: request, body: raw)
                    : try await Proxy.forward(request: request, body: raw)
            }
            return try await handleOllamaChat(body)
        }

        router.post("/api/generate") { request, context -> Response in
            var req = request
            let raw = try await req.collectBody(upTo: 10_485_760)
            let body = try JSONDecoder().decode(GenerateRequest.self, from: raw)
            if Proxy.forwardIfNeeded(request: request, model: body.model) {
                let isStream = body.stream ?? true
                return isStream
                    ? try await Proxy.forwardStreaming(request: request, body: raw)
                    : try await Proxy.forward(request: request, body: raw)
            }
            return try await handleOllamaGenerate(body)
        }

        router.post("/api/embed") { request, context -> Response in
            let body = try await request.decode(as: OllamaEmbedRequest.self, context: context)
            return try handleOllamaEmbed(body)
        }
        router.post("/api/embeddings") { request, context -> Response in
            let body = try await request.decode(as: OllamaEmbedRequest.self, context: context)
            return try handleOllamaEmbed(body)
        }

        router.post("/api/pull") { request, _ -> Response in
            if Proxy.isEnabled() {
                var req = request
                return try await Proxy.forwardStreaming(request: request, body: try await req.collectBody(upTo: 1_048_576))
            }
            return ollamaError("pull is not supported — apple-intelligence is always available", status: .badRequest)
        }
        router.delete("/api/delete") { request, _ -> Response in
            if Proxy.isEnabled() {
                var req = request
                return try await Proxy.forward(request: request, body: try await req.collectBody(upTo: 1_048_576))
            }
            return ollamaError("delete is not supported", status: .badRequest)
        }
        router.post("/api/copy") { request, _ -> Response in
            if Proxy.isEnabled() {
                var req = request
                return try await Proxy.forward(request: request, body: try await req.collectBody(upTo: 1_048_576))
            }
            return ollamaError("copy is not supported", status: .badRequest)
        }
        router.post("/api/create") { request, _ -> Response in
            if Proxy.isEnabled() {
                var req = request
                return try await Proxy.forward(request: request, body: try await req.collectBody(upTo: 1_048_576))
            }
            return ollamaError("create is not supported", status: .badRequest)
        }
        router.head("/api/blobs/{digest}") { request, _ -> Response in
            if Proxy.isEnabled() {
                return try await Proxy.forward(request: request, body: nil)
            }
            return Response(status: .notFound)
        }
        router.get("/api/ps") { request, _ -> Response in
            if Proxy.isEnabled() {
                return try await Proxy.forward(request: request, body: nil)
            }
            return try jsonResponse(OllamaPsResponse(models: [.running]))
        }

        router.get("/v1/models") { _, _ in
            OpenAIModelsResponse(object: "list", data: [.appleIntelligence])
        }

        router.post("/v1/chat/completions") { request, context -> Response in
            let body = try await request.decode(as: OpenAIChatRequest.self, context: context)
            return try await handleOpenAIChat(body)
        }

        router.post("/v1/embeddings") { request, context -> Response in
            let body = try await request.decode(as: OpenAIEmbeddingRequest.self, context: context)
            return try handleOpenAIEmbed(body)
        }
    }
}

// MARK: - Ollama Chat

private func handleOllamaChat(_ body: ChatRequest) async throws -> Response {
    let (system, prompt) = collapseOllamaMessages(body.messages)
    let tools: [ToolSpec] = (body.tools ?? []).map {
        ToolSpec(
            name: $0.function.name,
            description: $0.function.description,
            parametersJSONSchema: $0.function.parameters
        )
    }
    let options = BridgeOptions(systemInstruction: system, tools: tools)
    let model = Wire.normalizeModel(body.model)

    if body.stream ?? true {
        return ollamaChatStreamResponse(model: model, prompt: prompt, options: options)
    } else {
        let result = try await ModelBridge.respond(prompt: prompt, options: options)
        let hasTools = !result.toolCalls.isEmpty
        let resp = ChatResponse(
            model: model,
            createdAt: Wire.nowISO8601(),
            message: ChatMessage(
                role: Role.assistant,
                content: result.text,
                tool_calls: hasTools ? result.toolCalls.map(toOllamaToolCall) : nil
            ),
            done: true,
            doneReason: hasTools ? FinishReason.toolCalls : FinishReason.stop,
            promptEvalCount: result.promptTokens,
            evalCount: result.completionTokens
        )
        return try jsonResponse(resp)
    }
}

private func collapseOllamaMessages(_ messages: [ChatMessage]) -> (system: String?, prompt: String) {
    let systems = messages.filter { $0.role == Role.system }.map(\.content)
    let system: String? = systems.isEmpty ? nil : systems.joined(separator: "\n\n")
    let convo = messages.filter { $0.role != Role.system }
    if convo.count == 1, convo[0].role == Role.user {
        return (system, convo[0].content)
    }
    let prompt = convo.map { msg in
        switch msg.role {
        case Role.user:
            return "[User]\n\(msg.content)"
        case Role.assistant:
            var parts = ["[Assistant]"]
            if !msg.content.isEmpty { parts.append(msg.content) }
            if let calls = msg.tool_calls, !calls.isEmpty {
                for c in calls {
                    parts.append("<<TOOL_CALL>>{\"name\":\"\(c.function.name)\",\"arguments\":\(c.function.arguments.compactJSONString())}<<END>>")
                }
            }
            return parts.joined(separator: "\n")
        case Role.tool:
            return "[Tool result]\n\(msg.content)"
        default:
            return "[\(msg.role)]\n\(msg.content)"
        }
    }.joined(separator: "\n\n")
    return (system, prompt)
}

private func toOllamaToolCall(_ call: ParsedToolCall) -> OllamaToolCall {
    OllamaToolCall(function: OllamaToolCallFunction(name: call.name, arguments: call.arguments))
}

private func ollamaChatStreamResponse(model: String, prompt: String, options: BridgeOptions) -> Response {
    let ts = Wire.nowISO8601()
    let stream = AsyncThrowingStream<ByteBuffer, Error> { continuation in
        let task = Task {
            do {
                var cumulative = ""
                let filter = ModelBridge.StreamingTextFilter()
                for try await chunk in ModelBridge.stream(prompt: prompt, options: options) {
                    cumulative = chunk.cumulativeText
                    let displayDelta = filter.feed(chunk.textDelta)
                    if !displayDelta.isEmpty {
                        let frame = OllamaChatChunkFrame(
                            model: model, createdAt: ts,
                            message: ChatMessage(role: Role.assistant, content: displayDelta),
                            done: false
                        )
                        continuation.yield(try ndjson(frame))
                    }
                }
                let tail = filter.flush()
                if !tail.isEmpty {
                    let frame = OllamaChatChunkFrame(
                        model: model, createdAt: ts,
                        message: ChatMessage(role: Role.assistant, content: tail),
                        done: false
                    )
                    continuation.yield(try ndjson(frame))
                }
                let calls = filter.parseCapturedToolCalls()
                let hasTools = !calls.isEmpty
                let final = ChatResponse(
                    model: model, createdAt: ts,
                    message: ChatMessage(
                        role: Role.assistant, content: "",
                        tool_calls: hasTools ? calls.map(toOllamaToolCall) : nil
                    ),
                    done: true,
                    doneReason: hasTools ? FinishReason.toolCalls : FinishReason.stop,
                    promptEvalCount: ModelBridge.estimateTokens(prompt),
                    evalCount: ModelBridge.estimateTokens(cumulative)
                )
                continuation.yield(try ndjson(final))
                continuation.finish()
            } catch {
                let err = OllamaErrorFrame(error: String(describing: error))
                if let buf = try? ndjson(err) { continuation.yield(buf) }
                continuation.finish()
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
    return Response(
        status: .ok,
        headers: [.contentType: "application/x-ndjson"],
        body: ResponseBody(asyncSequence: stream)
    )
}

private struct OllamaChatChunkFrame: Encodable {
    let model: String
    let createdAt: String
    let message: ChatMessage
    let done: Bool
    enum CodingKeys: String, CodingKey {
        case model, message, done
        case createdAt = "created_at"
    }
}

private struct OllamaErrorFrame: Encodable {
    let error: String
}

// MARK: - Ollama Generate

private func handleOllamaGenerate(_ body: GenerateRequest) async throws -> Response {
    let options = BridgeOptions(systemInstruction: body.system, tools: [])
    let model = Wire.normalizeModel(body.model)

    if body.stream ?? true {
        let ts = Wire.nowISO8601()
        let stream = AsyncThrowingStream<ByteBuffer, Error> { continuation in
            let task = Task {
                do {
                    var cumulative = ""
                    for try await chunk in ModelBridge.stream(prompt: body.prompt, options: options) {
                        cumulative = chunk.cumulativeText
                        let frame = OllamaGenerateChunkFrame(
                            model: model, createdAt: ts,
                            response: chunk.textDelta, done: false
                        )
                        continuation.yield(try ndjson(frame))
                    }
                    let final = GenerateResponse(
                        model: model, createdAt: ts,
                        response: "", done: true,
                        doneReason: FinishReason.stop,
                        promptEvalCount: ModelBridge.estimateTokens(body.prompt),
                        evalCount: ModelBridge.estimateTokens(cumulative)
                    )
                    continuation.yield(try ndjson(final))
                    continuation.finish()
                } catch {
                    let err = OllamaErrorFrame(error: String(describing: error))
                    if let buf = try? ndjson(err) { continuation.yield(buf) }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return Response(
            status: .ok,
            headers: [.contentType: "application/x-ndjson"],
            body: ResponseBody(asyncSequence: stream)
        )
    } else {
        let result = try await ModelBridge.respond(prompt: body.prompt, options: options)
        let resp = GenerateResponse(
            model: model, createdAt: Wire.nowISO8601(),
            response: result.text, done: true,
            doneReason: FinishReason.stop,
            promptEvalCount: result.promptTokens,
            evalCount: result.completionTokens
        )
        return try jsonResponse(resp)
    }
}

private struct OllamaGenerateChunkFrame: Encodable {
    let model: String
    let createdAt: String
    let response: String
    let done: Bool
    enum CodingKeys: String, CodingKey {
        case model, response, done
        case createdAt = "created_at"
    }
}

// MARK: - OpenAI Chat

private func handleOpenAIChat(_ body: OpenAIChatRequest) async throws -> Response {
    let (system, prompt) = collapseOpenAIMessages(body.messages)
    let tools: [ToolSpec] = (body.tools ?? []).map {
        ToolSpec(
            name: $0.function.name,
            description: $0.function.description,
            parametersJSONSchema: $0.function.parameters
        )
    }
    let options = BridgeOptions(systemInstruction: system, tools: tools)
    let model = Wire.normalizeModel(body.model)
    let id = "chatcmpl-\(ModelBridge.shortID(length: 20))"

    if body.stream ?? false {
        return openAIChatStreamResponse(id: id, model: model, prompt: prompt, options: options)
    } else {
        let result = try await ModelBridge.respond(prompt: prompt, options: options)
        let hasTools = !result.toolCalls.isEmpty
        let toolCalls = result.toolCalls.map { c in
            OpenAIToolCall(
                id: c.id, type: ToolType.function,
                function: OpenAIToolCallFunction(
                    name: c.name, arguments: c.arguments.compactJSONString()
                )
            )
        }
        let message = OpenAIMessage(
            role: Role.assistant,
            content: hasTools ? nil : result.text,
            tool_calls: hasTools ? toolCalls : nil
        )
        let resp = OpenAIChatResponse(
            id: id,
            object: "chat.completion",
            created: Wire.nowEpoch(),
            model: model,
            choices: [OpenAIChatChoice(
                index: 0, message: message,
                finish_reason: hasTools ? FinishReason.toolCalls : FinishReason.stop
            )],
            usage: OpenAIUsage(
                prompt_tokens: result.promptTokens,
                completion_tokens: result.completionTokens
            )
        )
        return try jsonResponse(resp)
    }
}

private func collapseOpenAIMessages(_ messages: [OpenAIMessage]) -> (system: String?, prompt: String) {
    let systems = messages.filter { $0.role == Role.system }.compactMap(\.content)
    let system: String? = systems.isEmpty ? nil : systems.joined(separator: "\n\n")
    let convo = messages.filter { $0.role != Role.system }
    if convo.count == 1, convo[0].role == Role.user {
        return (system, convo[0].content ?? "")
    }
    let prompt = convo.map { msg in
        switch msg.role {
        case Role.user:
            return "[User]\n\(msg.content ?? "")"
        case Role.assistant:
            var parts = ["[Assistant]"]
            if let c = msg.content, !c.isEmpty { parts.append(c) }
            if let calls = msg.tool_calls {
                for c in calls {
                    parts.append("<<TOOL_CALL>>{\"name\":\"\(c.function.name)\",\"arguments\":\(c.function.arguments)}<<END>>")
                }
            }
            return parts.joined(separator: "\n")
        case Role.tool:
            let name = msg.name ?? Role.tool
            return "[Tool result for \(name)]\n\(msg.content ?? "")"
        default:
            return "[\(msg.role)]\n\(msg.content ?? "")"
        }
    }.joined(separator: "\n\n")
    return (system, prompt)
}

private func openAIChatStreamResponse(id: String, model: String, prompt: String, options: BridgeOptions) -> Response {
    let created = Wire.nowEpoch()
    let stream = AsyncThrowingStream<ByteBuffer, Error> { continuation in
        let task = Task {
            do {
                let roleChunk = OpenAIChatChunk(
                    id: id, object: "chat.completion.chunk",
                    created: created, model: model,
                    choices: [OpenAIChatChunkChoice(
                        index: 0,
                        delta: OpenAIDelta(role: Role.assistant, content: nil, tool_calls: nil),
                        finish_reason: nil
                    )]
                )
                continuation.yield(try sse(roleChunk))

                var cumulative = ""
                let filter = ModelBridge.StreamingTextFilter()
                for try await chunk in ModelBridge.stream(prompt: prompt, options: options) {
                    cumulative = chunk.cumulativeText
                    let displayDelta = filter.feed(chunk.textDelta)
                    if !displayDelta.isEmpty {
                        let frame = OpenAIChatChunk(
                            id: id, object: "chat.completion.chunk",
                            created: created, model: model,
                            choices: [OpenAIChatChunkChoice(
                                index: 0,
                                delta: OpenAIDelta(role: nil, content: displayDelta, tool_calls: nil),
                                finish_reason: nil
                            )]
                        )
                        continuation.yield(try sse(frame))
                    }
                }
                let tail = filter.flush()
                if !tail.isEmpty {
                    let frame = OpenAIChatChunk(
                        id: id, object: "chat.completion.chunk",
                        created: created, model: model,
                        choices: [OpenAIChatChunkChoice(
                            index: 0,
                            delta: OpenAIDelta(role: nil, content: tail, tool_calls: nil),
                            finish_reason: nil
                        )]
                    )
                    continuation.yield(try sse(frame))
                }
                let calls = filter.parseCapturedToolCalls()
                if !calls.isEmpty {
                    for (i, call) in calls.enumerated() {
                        let frame = OpenAIChatChunk(
                            id: id, object: "chat.completion.chunk",
                            created: created, model: model,
                            choices: [OpenAIChatChunkChoice(
                                index: 0,
                                delta: OpenAIDelta(
                                    role: nil, content: nil,
                                    tool_calls: [OpenAIToolCallDelta(
                                        index: i, id: call.id, type: ToolType.function,
                                        function: OpenAIToolCallFunctionDelta(
                                            name: call.name,
                                            arguments: call.arguments.compactJSONString()
                                        )
                                    )]
                                ),
                                finish_reason: nil
                            )]
                        )
                        continuation.yield(try sse(frame))
                    }
                }
                let finishReason = calls.isEmpty ? FinishReason.stop : FinishReason.toolCalls
                let final = OpenAIChatChunk(
                    id: id, object: "chat.completion.chunk",
                    created: created, model: model,
                    choices: [OpenAIChatChunkChoice(
                        index: 0,
                        delta: OpenAIDelta(role: nil, content: nil, tool_calls: nil),
                        finish_reason: finishReason
                    )]
                )
                continuation.yield(try sse(final))
                continuation.yield(sseTerminator)
                continuation.finish()
            } catch {
                let payload = ["error": ["message": String(describing: error), "type": "bridge_error"]]
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   let s = String(data: data, encoding: .utf8) {
                    continuation.yield(ByteBuffer(string: "data: \(s)\n\n"))
                }
                continuation.yield(sseTerminator)
                continuation.finish()
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
    return Response(
        status: .ok,
        headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
        body: ResponseBody(asyncSequence: stream)
    )
}

// MARK: - Encoding helpers

private let sharedEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes]
    return e
}()

private let sseTerminator = ByteBuffer(string: "data: [DONE]\n\n")

private func jsonResponse<T: Encodable>(_ value: T) throws -> Response {
    let data = try sharedEncoder.encode(value)
    return Response(
        status: .ok,
        headers: [.contentType: "application/json"],
        body: ResponseBody(byteBuffer: ByteBuffer(data: data))
    )
}

private func ndjson<T: Encodable>(_ value: T) throws -> ByteBuffer {
    let data = try sharedEncoder.encode(value)
    var buf = ByteBuffer()
    buf.reserveCapacity(data.count + 1)
    buf.writeData(data)
    buf.writeInteger(UInt8(0x0A))
    return buf
}

private func sse<T: Encodable>(_ value: T) throws -> ByteBuffer {
    let data = try sharedEncoder.encode(value)
    var buf = ByteBuffer()
    buf.reserveCapacity(data.count + 8)
    buf.writeStaticString("data: ")
    buf.writeData(data)
    buf.writeStaticString("\n\n")
    return buf
}

// MARK: - Error helpers

private func ollamaError(_ message: String, status: HTTPResponse.Status) -> Response {
    let body = OllamaErrorResponse(error: message)
    let data = (try? sharedEncoder.encode(body)) ?? Data("{\"error\":\"internal\"}".utf8)
    return Response(
        status: status,
        headers: [.contentType: "application/json"],
        body: ResponseBody(byteBuffer: ByteBuffer(data: data))
    )
}

// MARK: - Embeddings

private func handleOllamaEmbed(_ body: OllamaEmbedRequest) throws -> Response {
    let vectors = try ModelBridge.embed(texts: body.input.texts)
    return try jsonResponse(OllamaEmbedResponse(
        model: Wire.normalizeModel(body.model),
        embeddings: vectors
    ))
}

private func handleOpenAIEmbed(_ body: OpenAIEmbeddingRequest) throws -> Response {
    let texts = body.input.texts
    let vectors = try ModelBridge.embed(texts: texts)
    let data = vectors.enumerated().map { (i, vec) in
        OpenAIEmbeddingObject(object: "embedding", index: i, embedding: vec)
    }
    let totalTokens = texts.reduce(0) { $0 + ModelBridge.estimateTokens($1) }
    return try jsonResponse(OpenAIEmbeddingResponse(
        object: "list", data: data,
        model: Wire.normalizeModel(body.model),
        usage: OpenAIUsage(prompt_tokens: totalTokens, completion_tokens: 0)
    ))
}

// MARK: - /api/ps

private struct OllamaPsResponse: ResponseCodable {
    let models: [OllamaPsEntry]
}

private struct OllamaPsEntry: Codable {
    let name: String
    let model: String
    let size: Int
    let digest: String
    let expires_at: String

    static let running = OllamaPsEntry(
        name: Wire.modelTag, model: Wire.modelTag,
        size: 0, digest: "0",
        expires_at: "2099-01-01T00:00:00Z"
    )
}
