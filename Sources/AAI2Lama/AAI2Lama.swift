import Foundation
import Hummingbird

@main
struct AAI2Lama {
    static let defaultPort = 11435

    static func main() async throws {
        try ModelBridge.ensureAvailable()

        let env = ProcessInfo.processInfo.environment
        let port = env["AAI2LAMA_PORT"].flatMap(Int.init) ?? defaultPort
        let host = env["AAI2LAMA_HOST"] ?? "127.0.0.1"
        Proxy.upstreamBase = env["OLLAMA_UPSTREAM"]

        let router = Router()
        router.add(middleware: LogRequestsMiddleware(.info))
        router.add(middleware: CORSMiddleware(
            allowOrigin: .all,
            allowHeaders: [.contentType, .authorization, .accept],
            allowMethods: [.get, .post, .options, .head]
        ))

        Routes.register(on: router)

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(host, port: port),
                serverName: "AAI2Lama"
            )
        )
        if let upstream = Proxy.upstreamBase {
            print("AAI2Lama \(Wire.serverVersion) listening on http://\(host):\(port) (proxy → \(upstream))")
        } else {
            print("AAI2Lama \(Wire.serverVersion) listening on http://\(host):\(port)")
        }
        try await app.runService()
    }
}
