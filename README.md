# AAI2Lama

**Apple Intelligence as an Ollama-compatible model.** AAI2Lama is a lightweight Swift server that exposes Apple's on-device Foundation Model (Apple Intelligence) through an Ollama and OpenAI-compatible REST API. Use Apple Intelligence with any tool that speaks Ollama or OpenAI — Open WebUI, Continue, LangChain, Cursor, the `ollama` CLI, and more.

## What it does

- Runs Apple's on-device ~3B Foundation Model via the `FoundationModels` framework
- Exposes it as `apple-intelligence:latest` through standard APIs
- **Ollama API** — `/api/chat`, `/api/generate`, `/api/tags`, `/api/embed`, `/api/show`, `/api/ps`
- **OpenAI API** — `/v1/chat/completions`, `/v1/models`, `/v1/embeddings`
- Streaming (NDJSON + SSE), tool calling, embeddings (via `NLEmbedding`)
- Sampling options (`temperature`, max tokens, `top_p`/`top_k`, `seed`) mapped to Apple's `GenerationOptions`
- Model failures (context overflow, guardrails, rate limits) returned as distinct HTTP errors
- **Proxy mode** — sits in front of real Ollama, merges apple-intelligence with your existing models
- Automatic context truncation for Apple Intelligence's 4K token window
- CORS enabled for browser-based clients

## Requirements

- **macOS 26.0+** (Tahoe) with Apple Intelligence enabled
- **Apple Silicon** (M1 or later)
- **Swift 6.0+** / Xcode 26+

## Quick Start

```bash
git clone https://github.com/GodModeAI2025/AAI2Lama.git
cd AAI2Lama
swift build -c release
.build/release/AAI2Lama
```

The server starts on `http://127.0.0.1:11435`. Test it:

```bash
# List models
curl http://127.0.0.1:11435/api/tags

# Chat
curl -X POST http://127.0.0.1:11435/api/chat \
  -d '{"model":"apple-intelligence","messages":[{"role":"user","content":"Hello!"}],"stream":false}'

# Streaming
curl -N http://127.0.0.1:11435/api/chat \
  -d '{"messages":[{"role":"user","content":"Tell me a joke"}]}'
```

## Use with Ollama CLI

```bash
OLLAMA_HOST=http://127.0.0.1:11435 ollama run apple-intelligence
```

Or set it once per terminal session:

```bash
export OLLAMA_HOST=http://127.0.0.1:11435
ollama list
ollama run apple-intelligence
```

## Use with OpenAI SDK (Python)

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:11435/v1", api_key="unused")
response = client.chat.completions.create(
    model="apple-intelligence",
    messages=[{"role": "user", "content": "What is 2+2?"}]
)
print(response.choices[0].message.content)
```

## Proxy Mode — Integrate with Ollama App

In proxy mode, AAI2Lama sits on Ollama's default port (11434) and forwards non-Apple-Intelligence requests to your real Ollama instance. All clients see `apple-intelligence` alongside your existing models.

```bash
# 1. Quit the Ollama app (menubar → Quit Ollama)

# 2. Start real Ollama on a different port
OLLAMA_HOST=0.0.0.0:11436 ollama serve &

# 3. Start AAI2Lama on the default Ollama port with proxy
AAI2LAMA_PORT=11434 OLLAMA_UPSTREAM=http://127.0.0.1:11436 .build/release/AAI2Lama
```

Now `ollama list` shows all models:

```
NAME                         ID              SIZE      MODIFIED
apple-intelligence:latest    sha256:00000    0 B       16 months ago
llama3:latest                365c0bd3c000    4.7 GB    3 days ago
mistral:latest               f974a74358d6    4.1 GB    1 week ago
```

## Use with Open WebUI

1. Start AAI2Lama (standalone or proxy mode)
2. In Open WebUI: Settings → Connections → set Ollama URL to `http://127.0.0.1:11435` (or `11434` in proxy mode)
3. Select `apple-intelligence:latest` from the model dropdown

## Configuration

| Environment Variable | Default | Description |
|---|---|---|
| `AAI2LAMA_PORT` | `11435` | Port to listen on |
| `AAI2LAMA_HOST` | `127.0.0.1` | Host to bind to |
| `OLLAMA_UPSTREAM` | *(none)* | Upstream Ollama URL for proxy mode (e.g. `http://127.0.0.1:11436`) |

## Features

### Tool Calling

Apple Intelligence supports tool calling through prompt engineering. Pass tools in Ollama or OpenAI format:

```bash
curl -X POST http://127.0.0.1:11435/api/chat -d '{
  "model": "apple-intelligence",
  "messages": [{"role": "user", "content": "What is the weather in Berlin?"}],
  "stream": false,
  "tools": [{
    "type": "function",
    "function": {
      "name": "get_weather",
      "description": "Get weather for a city",
      "parameters": {"type": "object", "properties": {"city": {"type": "string"}}}
    }
  }]
}'
```

### Embeddings

512-dimensional sentence embeddings via Apple's `NLEmbedding`:

```bash
# Ollama format
curl -X POST http://127.0.0.1:11435/api/embed \
  -d '{"model":"apple-intelligence","input":"Hello world"}'

# OpenAI format
curl -X POST http://127.0.0.1:11435/v1/embeddings \
  -d '{"model":"apple-intelligence","input":["Hello","World"]}'
```

### Sampling Options

Ollama `options` and OpenAI request fields are passed to Apple's `GenerationOptions`:

| Ollama `options` | OpenAI field | Apple `GenerationOptions` |
|---|---|---|
| `temperature` | `temperature` | `temperature` (clamped to 0–2) |
| `num_predict` | `max_completion_tokens` / `max_tokens` | `maximumResponseTokens` (`-1`/`0` = no limit) |
| `top_p` | `top_p` | `.random(probabilityThreshold:seed:)` when 0 < p < 1 |
| `top_k` | — | `.random(top:seed:)` when k ≥ 1 and no usable `top_p` |
| `seed` | `seed` | seed of the random sampling mode; ignored without `top_p`/`top_k` |

Apple accepts only one sampling mode, so `top_p` takes precedence over `top_k`. `stop`, `repeat_penalty`, `frequency_penalty` and `presence_penalty` have no Foundation Models equivalent and are ignored. A response limit above the default 800-token output reserve also enlarges the reserve used for truncation (at most half the context window).

```bash
curl -X POST http://127.0.0.1:11435/api/generate -d '{
  "prompt": "Name three rivers.", "stream": false,
  "options": {"temperature": 0.2, "num_predict": 120, "top_k": 5, "seed": 42}
}'
```

### Error Responses

Failures from `LanguageModelSession` keep their cause instead of becoming a generic 500:

| Cause | HTTP status | OpenAI `error.code` |
|---|---|---|
| Context window exceeded, guardrail violation, refusal, unsupported language | 400 | `context_length_exceeded`, `guardrail_violation`, `refusal`, `unsupported_language` |
| Rate limited, concurrent requests | 429 | `rate_limited`, `concurrent_requests` |
| Model assets unavailable | 503 | `assets_unavailable` |
| Other generation failures | 500 | `generation_failed` |

Ollama endpoints return `{"error": "..."}`; OpenAI endpoints return `{"error": {"message", "type", "code"}}`. Streaming responses have already sent status 200, so the error arrives as a final NDJSON/SSE frame with the same message.

### Context Window Management

Apple Intelligence has a ~4K token context window (queried at runtime via `SystemLanguageModel.default.contextSize`). AAI2Lama automatically truncates long conversations, keeping the most recent messages and system prompt. A `[...earlier messages truncated...]` marker indicates when truncation occurred.

On macOS 26.4+, exact token counting is used via Apple's native `tokenCount(for:)` API. On older versions, a conservative heuristic is used as fallback.

### No Private Cloud Compute

Apple has confirmed that the Foundation Models framework is **strictly on-device**. Private Cloud Compute (PCC) is used only by Apple's own first-party features (Siri, etc.) — there is no developer API to access it. This means:
- The model is always the on-device ~3B model
- Context window is fixed at ~4K tokens with no cloud fallback
- There is no way to route to a larger server-side model

## Limitations

- **macOS 26+ only** — Foundation Models framework is not available on older macOS, iOS (except 26+), Linux, or Windows
- **Single model** — Apple Intelligence exposes one model; pull/delete/create operations are no-ops (proxied in proxy mode)
- **4K context window** — significantly smaller than typical Ollama models; automatic truncation helps but long conversations lose early context
- **No image input** — Foundation Models API is text-only
- **Tool calling is prompt-engineered** — works well for simple tools but may be unreliable for complex schemas
- **Usage counts are estimates** — truncation uses exact counts on macOS 26.4+, but `prompt_eval_count`/`eval_count` and OpenAI `usage` are approximated
- **Partial sampling control** — no stop sequences or repetition penalties; see [Sampling Options](#sampling-options)

## Architecture Decisions

Detailed architecture decision records are available in the [ADR/](ADR/) directory:

| ADR | Decision |
|---|---|
| [001](ADR/001-ollama-api-as-primary-interface.md) | Ollama API as primary interface |
| [002](ADR/002-hummingbird-as-http-server.md) | Hummingbird 2 as HTTP server |
| [003](ADR/003-prompt-based-tool-calling.md) | Prompt-based tool calling |
| [004](ADR/004-proxy-mode-for-ollama-integration.md) | Proxy mode for Ollama integration |
| [005](ADR/005-context-window-management.md) | Automatic context truncation |
| [006](ADR/006-on-device-only-no-pcc.md) | On-device only, no PCC access |
| [007](ADR/007-nlemebdding-for-embeddings.md) | NLEmbedding for text embeddings |
| [008](ADR/008-streaming-text-filter-design.md) | Stateful streaming text filter |
| [009](ADR/009-generation-options-and-error-mapping.md) | Generation options and error mapping |

## Architecture

```
┌──────────────┐     ┌──────────────┐     ┌─────────────────────┐
│  Ollama CLI  │     │  Open WebUI  │     │  OpenAI SDK / etc.  │
└──────┬───────┘     └──────┬───────┘     └──────────┬──────────┘
       │                    │                        │
       └────────────────────┼────────────────────────┘
                            │
                   ┌────────▼────────┐
                   │    AAI2Lama     │ :11434 (proxy) or :11435
                   │  Hummingbird 2  │
                   └───┬─────────┬───┘
                       │         │
          model=apple  │         │  other models
          -intelligence│         │
                       │         │
              ┌────────▼──┐  ┌───▼──────────┐
              │ Foundation │  │ Real Ollama  │
              │  Models    │  │   :11436     │
              │ (on-device)│  │ (llama3,etc) │
              └────────────┘  └──────────────┘
```

## License

Apache 2.0

## Credits

Built with [Hummingbird 2](https://github.com/hummingbird-project/hummingbird) and Apple's [Foundation Models](https://developer.apple.com/documentation/foundationmodels) framework.
