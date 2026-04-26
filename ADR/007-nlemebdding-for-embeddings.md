# ADR-007: NLEmbedding for Text Embeddings

**Status:** Accepted  
**Date:** 2026-04-26  
**Decision Makers:** Mark Zimmermann

## Context

Ollama and OpenAI APIs expose embedding endpoints (`/api/embed`, `/v1/embeddings`). Clients use these for RAG pipelines, semantic search, and similarity comparisons.

Apple's `FoundationModels` framework does not expose an embedding API. We needed an alternative source of embeddings on macOS.

Options considered:
1. **Return "not supported"** — breaks RAG-dependent clients
2. **NLEmbedding (NaturalLanguage framework)** — Apple's built-in sentence embeddings, available since macOS 11
3. **Third-party embedding model** — adds external dependency

## Decision

**Use `NLEmbedding.sentenceEmbedding(for: .english)` from the NaturalLanguage framework.**

## Rationale

- Zero external dependencies — ships with macOS
- 512-dimensional vectors — reasonable for local RAG
- Fast: no GPU inference, uses pre-computed lookup tables
- Cached as `static let` to avoid reloading the model per request
- Works independently of Foundation Models availability

## Trade-offs

- English-only (`.english` locale) — other languages produce zero vectors
- Quality is lower than transformer-based embeddings (no contextual understanding)
- 512 dimensions may not match what clients expect from typical embedding models

## Consequences

- `/api/embed` and `/v1/embeddings` return 512-dimensional float vectors
- Texts without matches in the vocabulary receive zero vectors
- The `NLEmbedding` instance is marked `nonisolated(unsafe)` for Swift 6 concurrency compatibility
- Token counts for embedding requests use the same estimation heuristic as chat requests
