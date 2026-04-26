# ADR-002: Hummingbird 2 as HTTP Server Framework

**Status:** Accepted  
**Date:** 2026-04-26  
**Decision Makers:** Mark Zimmermann

## Context

We needed a Swift HTTP server framework for exposing the REST API. The project must support:
- NDJSON streaming (Ollama)
- SSE streaming (OpenAI)
- JSON request/response encoding
- CORS for browser clients
- Low overhead for a lightweight bridge

Options considered:
1. **Vapor** — full-featured, widely used, heavier dependency tree
2. **Hummingbird 2** — lightweight, NIO-based, modern Swift concurrency
3. **Raw SwiftNIO** — maximum control, but verbose for REST APIs

## Decision

**Use Hummingbird 2.**

## Rationale

- Lightweight: minimal dependency footprint compared to Vapor
- Native async/await support with `ResponseBody(asyncSequence:)` for streaming
- Built-in `CORSMiddleware` and `LogRequestsMiddleware`
- Swift 6 strict concurrency compatible
- `ResponseCodable` protocol simplifies JSON encoding for route handlers
- NIO-based ByteBuffer integration allows zero-copy streaming optimizations

## Consequences

- Streaming responses use `ResponseBody(asyncSequence:)` with `ByteBuffer` chunks
- JSON encoding uses a shared `JSONEncoder` instance for consistency
- Route registration is centralized in `Routes.swift` via a generic `register<Context>(on:)` function
- CORS is handled at the middleware layer, not per-route
