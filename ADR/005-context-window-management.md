# ADR-005: Automatic Context Window Truncation

**Status:** Accepted  
**Date:** 2026-04-26  
**Decision Makers:** Mark Zimmermann

## Context

Apple Intelligence's on-device Foundation Model has a fixed context window of ~4096 tokens. This is significantly smaller than typical Ollama models (8K-128K). Clients routinely send multi-turn conversations that exceed this limit, causing `exceededContextWindowSize` errors.

There is no way to access larger context via Private Cloud Compute — Apple has confirmed the Foundation Models framework is strictly on-device with no PCC routing.

Options considered:
1. **Return error to client** — breaks the conversation flow
2. **Automatic truncation** — silently trim older messages, keep recent context
3. **Summarization** — use a second model session to compress history (doubles latency)

## Decision

**Automatic truncation with block-level granularity, using Apple's native `tokenCount(for:)` API when available.**

## Implementation

1. Messages are collapsed into `\n\n`-separated blocks (one block per conversation turn)
2. System instructions and tool definitions are never truncated
3. Token budget = `contextSize - reservedOutputTokens (800)` - instruction tokens
4. Blocks are kept from newest to oldest until budget is exhausted
5. A `[...earlier messages truncated...]` marker is inserted when truncation occurs
6. On macOS 26.4+, `SystemLanguageModel.default.tokenCount(for:)` provides exact counts
7. On older versions, a heuristic (`utf8.count * 2 / 5`) is used as fallback

## Rationale

- Users expect conversations to work, not to crash on long chats
- Most recent messages are most relevant for the current question
- Block-level (not character-level) truncation avoids cutting mid-sentence
- Native `tokenCount(for:)` eliminates estimation errors that caused past overflow failures
- `SystemLanguageModel.default.contextSize` future-proofs against context window changes

## Consequences

- Long conversations silently lose early context (acceptable trade-off for a 4K window)
- The truncation marker is visible to the model, which may reference it
- Token counting adds a small async overhead per request (negligible vs. model inference)
- The 800-token output reserve is conservative but prevents output truncation
