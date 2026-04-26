# ADR-001: Ollama API as Primary Interface

**Status:** Accepted  
**Date:** 2026-04-26  
**Decision Makers:** Mark Zimmermann

## Context

Apple Intelligence exposes an on-device Foundation Model via the `FoundationModels` Swift framework. This model has no standard API — it's only accessible via Swift on macOS 26+. Meanwhile, the LLM ecosystem has converged on two dominant API formats: Ollama and OpenAI.

We needed to decide which API format to expose as the primary interface.

## Decision

**Expose the Ollama REST API as the primary interface, with OpenAI compatibility as a secondary layer.**

## Rationale

- Ollama is the de-facto standard for local LLM serving on macOS — the same platform Apple Intelligence runs on
- The Ollama API is simpler (fewer required fields) and streaming uses NDJSON instead of SSE
- The `ollama` CLI exists on most developer machines and provides instant testing
- Open WebUI, Continue, and other popular tools speak Ollama natively
- OpenAI compatibility is easy to add on top (same underlying model call, different response shape)

## Consequences

- Server must implement Ollama-specific endpoints (`/api/chat`, `/api/generate`, `/api/tags`, `/api/show`, `/api/ps`, `/api/embed`)
- Streaming defaults to NDJSON (Ollama convention), not SSE
- Model discovery uses Ollama's tag format
- Default port is 11435 (one above Ollama's 11434) to avoid conflicts
- OpenAI endpoints (`/v1/chat/completions`, `/v1/models`, `/v1/embeddings`) added as secondary interface
