# ADR-003: Prompt-Based Tool Calling Instead of Native Tool Protocol

**Status:** Accepted  
**Date:** 2026-04-26  
**Decision Makers:** Mark Zimmermann

## Context

Apple's `FoundationModels` framework supports tool calling via the `Tool` protocol with `@Generable` argument types. However, this requires compile-time type definitions — the `Tool` protocol's `Arguments` associated type must be a concrete Swift type with `@Generable` conformance.

In a bridge like AAI2Lama, tool definitions arrive at runtime as JSON Schema from Ollama/OpenAI clients. We cannot create Swift types from JSON Schema at runtime.

Options considered:
1. **Native Tool protocol** — requires compile-time types, cannot handle dynamic tool schemas
2. **Prompt engineering** — inject tool descriptions into the system prompt, parse model output for structured markers
3. **Hybrid** — use `GenerationSchema` (if available) for runtime schema construction

## Decision

**Use prompt engineering with structured markers (`<<TOOL_CALL>>...<<END>>`).**

## Rationale

- Works with any tool schema from any client — no compile-time dependency
- The 3B on-device model reliably follows the marker format for simple tools
- Parsing is deterministic (regex-based extraction)
- A stateful `StreamingTextFilter` handles markers split across streaming deltas
- Tool-call JSON is captured during streaming, eliminating a redundant regex pass at the end
- Clients receive standard Ollama/OpenAI `tool_calls` response format

## Trade-offs

- Tool calling quality depends on the model's ability to follow formatting instructions
- Complex multi-tool scenarios may be less reliable than native tool support
- The `<<TOOL_CALL>>...<<END>>` markers consume context tokens

## Consequences

- System prompt grows when tools are provided (~100-200 tokens for the tool instructions)
- `StreamingTextFilter` must suppress marker text from streaming output
- The filter captures tool-call JSON payloads for later parsing via `parseCapturedToolCalls()`
- After a tool result is sent back, the system prompt instructs the model to not re-call the same tool
