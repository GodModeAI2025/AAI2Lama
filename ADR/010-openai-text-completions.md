# ADR-010: OpenAI Text-Completion Endpoint

**Status:** Accepted  
**Date:** 2026-09-20  
**Decision Makers:** Mark Zimmermann

## Context

AAI2Lama served `/v1/chat/completions`, `/v1/models` and `/v1/embeddings`, but not
`/v1/completions` — OpenAI's older text-completion route. Ollama's own OpenAI
compatibility layer serves it, and editor extensions still use it for inline
suggestions: chat goes to the chat route, autocomplete goes to `/v1/completions`,
usually with a `suffix` so the model can fill in at the cursor. A request to the
missing route got Hummingbird's bodyless 404, which reads like a broken server
rather than an unsupported feature.

The on-device model is instruction-tuned and has no fill-in-the-middle mode, so a
`prompt`/`suffix` pair cannot be forwarded as raw text.

Options considered:
1. **Leave it out** — keeps the surface small, but contradicts the README's claim of
   OpenAI compatibility and the clients it names
2. **Serve the route and reject `suffix` with 400** — half a feature; the clients that
   use this route send `suffix` by default
3. **Serve the route and frame `suffix` as an instruction** — one prompt shape, honest
   about what the model can do

## Decision

**Serve `POST /v1/completions` in OpenAI's format, and turn a request carrying `suffix`
into an explicit fill-in instruction for the model.**

## Implementation

1. `OpenAICompletionRequest` accepts `prompt` as a string or an array of strings
   (joined with newlines), plus `suffix`, `stream`, `echo` and the sampling fields
2. Sampling reuses `SamplingSettings`; only `max_tokens` applies here, since
   `max_completion_tokens` is a chat-only field
3. Without `suffix` the prompt is passed through unchanged; with `suffix` the text
   before and after the cursor is labelled and a short system instruction asks for the
   missing passage only
4. Responses use `"object": "text_completion"`, streaming emits the same object per
   SSE frame and closes with a `finish_reason` frame and `data: [DONE]`. Every choice
   carries `logprobs` and `finish_reason` as keys, `null` where there is nothing to
   report, because OpenAI's schema lists both as required
5. `stop` cuts the completion before the first sequence, streaming included — the
   cutter holds back a tail that could still grow into a sequence, so one split across
   two deltas is not emitted by halves
6. Failures reuse `openAIError(for:)`, so the status and error body match the chat route

## Rationale

- Completes the OpenAI surface that the README already promises
- Editor clients need no proxy or shim to reach Apple Intelligence
- Framing beats rejecting: the request still produces a usable suggestion

## Consequences

- A field that would change the shape of the answer is refused with 400 and
  `code: "unsupported_parameter"` naming it: `n` and `best_of` above 1, and `logprobs`.
  One on-device generation is one completion, and the framework exposes no token
  probabilities — a client that asked for more should hear that rather than quietly
  receive less. Fields that only nudge sampling and have no counterpart in
  `GenerationOptions` (`frequency_penalty`, `presence_penalty`, `logit_bias`, `user`)
  stay ignored, as on the chat route
- The chat route keeps its own, older handling of `n` and `stop`; aligning it is a
  separate change
- Suggestion quality is bounded by a ~3B instruction model — the format is compatible,
  the model is not a code-completion model
- Like `/v1/chat/completions`, the route always answers from Apple Intelligence; it is
  not forwarded upstream in proxy mode (see ADR-004)
