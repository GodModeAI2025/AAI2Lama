# ADR-008: Stateful Streaming Text Filter for Tool-Call Markers

**Status:** Accepted  
**Date:** 2026-04-26  
**Decision Makers:** Mark Zimmermann

## Context

When tool calling is active, the model may emit `<<TOOL_CALL>>{...}<<END>>` markers in its output. These must be:
1. Suppressed from the streaming text sent to clients
2. Parsed to extract tool call JSON payloads
3. Handled correctly even when markers are split across streaming deltas

An initial stateless approach (checking each delta independently) failed because markers frequently span multiple deltas (e.g., delta 1: `<<TOOL_C`, delta 2: `ALL>>{"name"...`).

## Decision

**Implement a stateful `StreamingTextFilter` class that buffers text, tracks whether it's inside a marker, and captures tool-call JSON during filtering.**

## Design

- `buffer: String` accumulates incoming deltas
- `inToolCall: Bool` tracks whether we're between `<<TOOL_CALL>>` and `<<END>>`
- `toolCallBuffer: String` accumulates JSON content inside markers
- `capturedToolCallJSONs: [String]` stores completed tool-call payloads
- `longestSuffixMatchingPrefix()` operates on UTF-8 bytes to hold back any buffer tail that could be the start of `<<TOOL_CALL>>`

## Key Methods

- `feed(_ delta) -> String` — returns safe-to-emit text, buffers the rest
- `flush() -> String` — emits remaining buffer after stream ends
- `parseCapturedToolCalls() -> [ParsedToolCall]` — parses captured JSONs into structured tool calls

## Rationale

- Single-pass: text is filtered and tool calls are captured simultaneously
- No redundant regex pass over cumulative text after streaming
- UTF-8 byte-level suffix matching avoids `String.count` O(n) overhead on every delta
- The filter is per-stream (not shared), so no concurrency concerns

## Consequences

- Routes create a fresh `StreamingTextFilter()` per streaming request
- After streaming completes, `filter.parseCapturedToolCalls()` replaces the previous `ModelBridge.extractToolCalls(from: cumulative)` call
- The `extractAndStrip` regex path is still used for non-streaming responses (simpler, single-shot)
