# ADR-006: On-Device Only — No Private Cloud Compute Access

**Status:** Accepted (Constraint)  
**Date:** 2026-04-26  
**Decision Makers:** Apple (platform constraint)

## Context

Apple Intelligence uses two tiers internally:
- **On-device model** (~3B parameters, 2-bit quantized) — fast, private, limited capability
- **Private Cloud Compute (PCC)** — larger server-side model, used by Siri and first-party features for complex tasks

Users expected AAI2Lama to automatically route to PCC for large or complex requests.

## Reality

**The Foundation Models framework provides access to the on-device model only. PCC is not available to developers.**

Apple Developer Relations has confirmed:
> *"The Foundation Models framework currently doesn't provide an API to access cloud-based models. PCC is never used. Ever. Inference is entirely on-device."*

## Implications for AAI2Lama

- The model is always the on-device ~3B model — small, fast, but limited
- Context window is fixed at ~4096 tokens (no cloud fallback for larger contexts)
- Model quality is appropriate for quick tasks, summaries, tool calling, and local tooling — not for complex reasoning
- There is no parameter to control routing between local and cloud
- `SystemLanguageModel.default` is the only model available; `UseCase` variants (`.contentTagging`) apply LoRA adapters on the same base model

## If This Changes

If Apple opens PCC access in the future:
- `SystemLanguageModel.default.contextSize` would return a larger value automatically
- AAI2Lama's truncation logic already uses this property, so it would adapt without code changes
- A new model variant (e.g., `apple-intelligence:cloud`) could be exposed alongside the local one
