# AAI2Lama

**Apple Intelligence as an Ollama-compatible model.** AAI2Lama is a lightweight Swift server that exposes Apple's on-device Foundation Model (Apple Intelligence) through an Ollama and OpenAI-compatible REST API. Use Apple Intelligence with any tool that speaks Ollama or OpenAI — Open WebUI, Continue, LangChain, Cursor, the `ollama` CLI, and more.

## What it does

- Runs Apple's on-device ~3B Foundation Model via the `FoundationModels` framework
- Exposes it as `apple-intelligence:latest` through standard APIs
- **Ollama API** — `/api/chat`, `/api/generate`, `/api/tags`, `/api/embed`, `/api/show`, `/api/ps`
- **OpenAI API** — `/v1/chat/completions`, `/v1/models`, `/v1/embeddings`
- Streaming (NDJSON + SSE), tool calling, embeddings (via `NLEmbedding`)
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
- **No local/cloud routing control** — Apple decides whether to use on-device or Private Cloud Compute; there is no API to override this
- **Tool calling is prompt-engineered** — works well for simple tools but may be unreliable for complex schemas
- **Token counts are estimates** — Apple does not expose exact token counts; values are approximated

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
