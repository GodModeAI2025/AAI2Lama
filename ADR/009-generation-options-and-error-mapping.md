# ADR-009: Generation Options and Error Mapping

**Status:** Accepted  
**Date:** 2026-09-16  
**Decision Makers:** Mark Zimmermann

## Context

Clients send sampling parameters on nearly every request: Ollama in `options`, OpenAI as top-level fields. AAI2Lama decoded them but never passed them on, so `temperature: 0` or `num_predict: 50` had no effect. Apple's `GenerationOptions` supports temperature, a response token limit, and one sampling mode (greedy, top-k, or nucleus with an optional seed).

Every `LanguageModelSession` failure was also wrapped into one opaque error. Clients got HTTP 500 for a context overflow, a guardrail hit, or a rate limit alike, and could not tell whether to shorten the prompt, rephrase, or retry later.

Options considered:
1. **Reject unsupported or out-of-range parameters with 400** — breaks clients like Open WebUI that always send their defaults
2. **Normalise and map what Apple supports, ignore the rest** — tolerant, like Ollama itself
3. **Keep ignoring options** — status quo

## Decision

**Normalise client options into a framework-independent `SamplingSettings` value and map it to `GenerationOptions`. Classify `LanguageModelSession.GenerationError` into `GenerationFailureKind` and derive HTTP status and OpenAI error fields from it.**

## Implementation

1. `Sampling.swift` holds `SamplingSettings` and `GenerationFailureKind` without importing `FoundationModels`
2. Temperature is clamped to 0–2; token limits ≤ 0 mean "no limit"
3. `top_p` in (0, 1) wins over `top_k` ≥ 1, because Apple accepts one sampling mode; a seed is only used with a random mode
4. The truncation reserve grows with an explicit response limit, capped at half the context window (see ADR-005)
5. `ModelBridge.classify(_:)` maps framework errors: client-fixable → 400, rate limits → 429, missing assets → 503, everything else → 500
6. Non-streaming routes return the mapped status; streaming routes keep status 200 and send the classified message in the error frame

## Rationale

- Deterministic output (`temperature: 0`, fixed seed) matters for evals and tool calling
- Status codes let clients react correctly: shorten, rephrase, or back off
- A pure value type keeps the mapping rules readable and checkable without the model

## Consequences

- `stop`, `repeat_penalty`, `frequency_penalty` and `presence_penalty` stay ignored
- Streaming errors cannot change the already-sent HTTP status
- Future `GenerationError` cases fall back to 500 via `@unknown default`
