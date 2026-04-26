import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

enum Proxy {
    nonisolated(unsafe) static var upstreamBase: String?

    static func isEnabled() -> Bool { upstreamBase != nil }

    static func forwardIfNeeded(
        request: Request,
        model: String?
    ) -> Bool {
        guard isEnabled() else { return false }
        if let model, model.hasPrefix(Wire.modelBase) { return false }
        return true
    }

    static func forward(request: Request, body: ByteBuffer?) async throws -> Response {
        guard let base = upstreamBase else {
            return errorResponse("Proxy not configured", status: .badGateway)
        }
        let path = request.uri.string
        guard let url = URL(string: base + path) else {
            return errorResponse("Bad upstream URL", status: .badGateway)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue

        for field in request.headers {
            if field.name.rawName == "Host" || field.name == .transferEncoding { continue }
            urlRequest.setValue(field.value, forHTTPHeaderField: field.name.rawName)
        }

        if let body {
            urlRequest.httpBody = Data(buffer: body, byteTransferStrategy: .noCopy)
        }

        let (data, urlResponse) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            return errorResponse("Upstream not HTTP", status: .badGateway)
        }

        var headers = HTTPFields()
        for (key, value) in httpResponse.allHeaderFields {
            guard let name = key as? String, let val = value as? String else { continue }
            if let fieldName = HTTPField.Name(name) {
                headers.append(HTTPField(name: fieldName, value: val))
            }
        }

        let status = HTTPResponse.Status(code: httpResponse.statusCode)
        return Response(
            status: status,
            headers: headers,
            body: ResponseBody(byteBuffer: ByteBuffer(data: data))
        )
    }

    static func forwardStreaming(request: Request, body: ByteBuffer?) async throws -> Response {
        guard let base = upstreamBase else {
            return errorResponse("Proxy not configured", status: .badGateway)
        }
        let path = request.uri.string
        guard let url = URL(string: base + path) else {
            return errorResponse("Bad upstream URL", status: .badGateway)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue

        for field in request.headers {
            if field.name.rawName == "Host" || field.name == .transferEncoding { continue }
            urlRequest.setValue(field.value, forHTTPHeaderField: field.name.rawName)
        }

        if let body {
            urlRequest.httpBody = Data(buffer: body, byteTransferStrategy: .noCopy)
        }

        let (bytes, urlResponse) = try await URLSession.shared.bytes(for: urlRequest)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            return errorResponse("Upstream not HTTP", status: .badGateway)
        }

        var headers = HTTPFields()
        for (key, value) in httpResponse.allHeaderFields {
            guard let name = key as? String, let val = value as? String else { continue }
            if let fieldName = HTTPField.Name(name) {
                headers.append(HTTPField(name: fieldName, value: val))
            }
        }

        let status = HTTPResponse.Status(code: httpResponse.statusCode)
        let stream = AsyncThrowingStream<ByteBuffer, Error> { continuation in
            let task = Task {
                var lineBuffer = Data()
                for try await byte in bytes {
                    lineBuffer.append(byte)
                    if byte == 0x0A {
                        continuation.yield(ByteBuffer(data: lineBuffer))
                        lineBuffer.removeAll(keepingCapacity: true)
                    }
                }
                if !lineBuffer.isEmpty {
                    continuation.yield(ByteBuffer(data: lineBuffer))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return Response(
            status: status,
            headers: headers,
            body: ResponseBody(asyncSequence: stream)
        )
    }

    static func mergedTags() async -> TagsResponse {
        var models: [ModelInfo] = [.appleIntelligence]
        if let base = upstreamBase,
           let url = URL(string: base + "/api/tags") {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let upstream = try JSONDecoder().decode(TagsResponse.self, from: data)
                models.append(contentsOf: upstream.models)
            } catch {
                print("AAI2Lama: upstream tags fetch failed: \(error)")
            }
        }
        return TagsResponse(models: models)
    }

    private static func errorResponse(_ message: String, status: HTTPResponse.Status) -> Response {
        let body = OllamaErrorResponse(error: message)
        let data = (try? JSONEncoder().encode(body)) ?? Data("{\"error\":\"proxy\"}".utf8)
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: ResponseBody(byteBuffer: ByteBuffer(data: data))
        )
    }
}

private extension Wire {
    static let modelBase = "apple-intelligence"
}
