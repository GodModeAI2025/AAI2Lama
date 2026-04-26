# ADR-004: Proxy Mode for Transparent Ollama Integration

**Status:** Accepted  
**Date:** 2026-04-26  
**Decision Makers:** Mark Zimmermann

## Context

Users want Apple Intelligence to appear alongside their existing Ollama models (llama3, gemma4, etc.) in a single model list. The Ollama ecosystem expects all models at one URL (`localhost:11434`). Running AAI2Lama on a separate port requires reconfiguring every client.

Options considered:
1. **Separate port** — simplest, but users must reconfigure clients
2. **Reverse proxy (Nginx/Caddy)** — external dependency, complex setup
3. **Built-in proxy** — AAI2Lama sits on port 11434, proxies non-Apple-Intelligence requests to real Ollama

## Decision

**Implement built-in proxy mode via `OLLAMA_UPSTREAM` environment variable.**

## Rationale

- Zero external dependencies — one binary does everything
- Transparent to clients: `ollama list` shows all models (apple-intelligence + upstream)
- Model-name routing is simple: requests for `apple-intelligence` are handled locally, everything else is forwarded
- `/api/tags` merges both model lists automatically
- Streaming proxy preserves NDJSON line-by-line forwarding

## Setup

```bash
# Real Ollama on alternate port
OLLAMA_HOST=0.0.0.0:11436 ollama serve &

# AAI2Lama on default port with proxy
AAI2LAMA_PORT=11434 OLLAMA_UPSTREAM=http://127.0.0.1:11436 .build/release/AAI2Lama
```

## Consequences

- Request body must be buffered to inspect the `model` field before deciding to proxy or handle locally
- `/api/tags` makes an async fetch to the upstream Ollama and merges results
- `/api/pull`, `/api/delete`, `/api/copy`, `/api/create` are forwarded to upstream in proxy mode
- Without `OLLAMA_UPSTREAM`, proxy is disabled and AAI2Lama runs standalone
- Users must stop the Ollama app before starting AAI2Lama on port 11434
