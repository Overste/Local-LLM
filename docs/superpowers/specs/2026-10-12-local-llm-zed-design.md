# Local coding LLM for Zed: design

Date: 2026-10-12
Status: awaiting review

## Goal

A git repo that reproduces a local coding-LLM setup with one command per
machine. The model server runs on a desktop PC (RTX 4090, 24 GB VRAM, 64 GB
RAM, Ubuntu). Zed and OpenCode use it either on that PC or from a laptop
through an SSH tunnel.

Success means:

- On the 4090 PC, `server/up.sh` brings up a GPU-backed Ollama with the pinned
  models, and `server/verify.sh` passes.
- On any client, Zed's agent panel and edit predictions both work against
  `http://localhost:11434`, and so does OpenCode.
- Changing a model means editing one file, `models.env`.

## Decisions

| Topic | Decision |
|---|---|
| Model server | Ollama in Docker Compose |
| Server OS | Ubuntu, scripts use `apt` |
| Zed features | Agent panel and edit predictions |
| Other clients | OpenCode (terminal, and as a Zed external agent) |
| Remote access | SSH tunnel; the server listens on localhost only |
| Scope | Coding only |

## Architecture

```
laptop                                   4090 PC
┌──────────────────────┐                ┌────────────────────────────┐
│ Zed, OpenCode        │                │ Zed, OpenCode              │
│   │ localhost:11434  │                │   │ localhost:11434        │
│   ▼                  │   SSH tunnel   │   ▼                        │
│ tunnel.sh ───────────┼───────────────►│ 127.0.0.1:11434            │
└──────────────────────┘                │   ▼                        │
                                        │ docker: ollama ── RTX 4090 │
                                        │   └─ volume: ollama-models │
                                        └────────────────────────────┘
```

Every client talks to a localhost port, so client config is identical on both
machines.

## Repo layout

```
local-llm/
├── models.env              # pinned image tag, model tags, context size, port
├── server/
│   ├── compose.yaml        # ollama service, CPU-capable
│   ├── compose.gpu.yaml    # overlay adding the NVIDIA GPU reservation
│   ├── install-prereqs.sh  # NVIDIA container toolkit, GPU-in-container check
│   ├── up.sh               # start stack, pull models
│   └── verify.sh
├── client/
│   ├── zed-settings.jsonc.tmpl
│   ├── opencode.json.tmpl
│   ├── render.sh           # templates + models.env -> client/out/
│   ├── tunnel.sh
│   └── verify.sh
├── .gitignore              # client/out/
└── README.md
```

## models.env

The single source of truth. Shell-sourceable and usable as a Compose env file.

| Variable | Starting value | Meaning |
|---|---|---|
| `OLLAMA_IMAGE_TAG` | `0.34.1` | Pinned `ollama/ollama` image version |
| `OLLAMA_PORT` | `11434` | Host port, bound to 127.0.0.1 |
| `AGENT_MODEL` | `qwen3-coder:30b` | Agent and chat model |
| `COMPLETION_MODEL` | `qwen2.5-coder:3b-base` | Edit prediction model |
| `CONTEXT_LENGTH` | `32768` | Context size, server-wide |
| `USE_GPU` | `1` | `0` drops the GPU overlay, for testing |

The model tags and the context size are starting values. They are tuned on
the 4090 PC; see "Tuning" below.

## Server

### compose.yaml

One service, `ollama`:

- Image `ollama/ollama:${OLLAMA_IMAGE_TAG}`.
- Port `127.0.0.1:${OLLAMA_PORT}:11434`. Never bound to other interfaces.
- Named volume `ollama-models` mounted at `/root/.ollama`.
- `restart: unless-stopped`.
- Healthcheck: `ollama list`.
- Environment:
  - `OLLAMA_CONTEXT_LENGTH=${CONTEXT_LENGTH}`. Set on the server because
    OpenCode uses the OpenAI-compatible endpoint, which cannot set a context
    size per request.
  - `OLLAMA_MAX_LOADED_MODELS=2`, so agent and completion models stay loaded
    together.
  - `OLLAMA_NUM_PARALLEL=1`.
  - `OLLAMA_KEEP_ALIVE=30m`, so VRAM is released when the machine is idle.
  - `OLLAMA_FLASH_ATTENTION=1` and `OLLAMA_KV_CACHE_TYPE=q8_0`, to reduce
    context memory.

### compose.gpu.yaml

Adds `deploy.resources.reservations.devices` with driver `nvidia`, count
`all`, capabilities `[gpu]`. Kept separate so the base stack runs on a machine
without an NVIDIA GPU.

### install-prereqs.sh

Run once on the 4090 PC.

1. Fail with instructions if `nvidia-smi` is missing. The script does not
   install GPU drivers.
2. Fail with instructions if Docker or the Compose plugin is missing.
3. Install `nvidia-container-toolkit` from NVIDIA's apt repository if absent,
   run `nvidia-ctk runtime configure --runtime=docker`, restart Docker.
4. Run `nvidia-smi` in a throwaway GPU container and fail if it errors.

Steps 3 and 4 need `sudo`; the script says so before prompting.

### up.sh

1. Source `models.env`.
2. Fail if `OLLAMA_PORT` is already in use by something other than this
   stack, naming the likely cause (a native Ollama service) and the fix.
3. `docker compose up -d --wait`, with the GPU overlay when `USE_GPU=1`.
4. Pull `AGENT_MODEL` and `COMPLETION_MODEL` inside the container. A tag that
   does not exist fails here with the tag named.

Idempotent: safe to rerun after editing `models.env`.

### verify.sh

Each check prints pass or fail with the reason; exit code is non-zero on any
failure.

1. Container is healthy.
2. With `USE_GPU=1`: `nvidia-smi` works inside the container.
3. Both models are present.
4. Agent model answers a chat request that offers one tool, and the reply
   contains a tool call.
5. Completion model answers a `/v1/completions` request with non-empty text.
6. With `USE_GPU=1`: `ollama ps` reports both models loaded 100% on GPU. A
   CPU split is a failure, with a pointer to "Tuning".

## Client

### render.sh

Substitutes `models.env` values into the two templates and writes
`client/out/zed-settings.jsonc` and `client/out/opencode.json`. It then prints
where each file goes. It does not write outside the repo.

### Zed settings snippet

Merged into `~/.config/zed/settings.json` by hand, because that file holds
comments and personal settings that an automatic merge could damage.

- `language_models.ollama`: `api_url` `http://localhost:${OLLAMA_PORT}`, and
  one `available_models` entry for `AGENT_MODEL` with `max_tokens` set to
  `CONTEXT_LENGTH` and `supports_tools: true`. Without `max_tokens`, Zed
  requests a 4096-token context.
- `agent.default_model`: provider `ollama`, model `AGENT_MODEL`.
- `edit_predictions`: provider `ollama`, model `COMPLETION_MODEL`,
  `prompt_format: "qwen"`, `max_output_tokens: 512`.

### OpenCode config

Copied to `~/.config/opencode/opencode.json` by hand if that file exists
already, otherwise `render.sh` prints the `cp` command.

- A provider named `ollama` using `@ai-sdk/openai-compatible` with
  `baseURL` `http://localhost:${OLLAMA_PORT}/v1`.
- One model whose key equals `AGENT_MODEL` exactly.

Running OpenCode inside Zed's agent panel is a manual step, documented in the
README: install it from Zed's ACP registry. It reads the same `opencode.json`.

### tunnel.sh

`client/tunnel.sh <ssh-host> [local-port]`

Runs `ssh -N -L <local-port>:127.0.0.1:${OLLAMA_PORT} <ssh-host>` with
`ServerAliveInterval=30` and `ExitOnForwardFailure=yes`. The local port
defaults to `OLLAMA_PORT`. If that port is taken, it fails and names the two
fixes: stop the local service holding it, or pass another port and render the
client config with the same port.

Not needed on the 4090 PC itself.

### client/verify.sh

Runs checks 3, 4 and 5 of the server verify against
`http://localhost:<port>`. Passing on the laptop proves the tunnel too.

## Error handling

All scripts use `set -euo pipefail`. Every failure message names what failed
and the next command to run. No script installs GPU drivers, edits Zed
settings, stops system services or opens firewall ports.

## Testing

- **On the laptop (no NVIDIA GPU):** the full server and client flow with
  `USE_GPU=0`, a spare port, and small models already present locally. This
  exercises every script path except GPU checks 2 and 6.
- **Static:** `shellcheck` on all scripts, `docker compose config` on both
  compose files, and a JSON parse of both rendered client files.
- **On the 4090 PC:** `install-prereqs.sh`, `up.sh`, `verify.sh` with the real
  models. This is the only place the GPU checks and VRAM fit can be
  confirmed, and it is run by the owner, not during implementation.

## Tuning

24 GB is tight for a 19 GB agent model, its context and a second model. If
verify check 6 fails, or generation is slow, adjust `models.env` in this
order:

1. Lower `CONTEXT_LENGTH` (for example to 24576).
2. Use a smaller `COMPLETION_MODEL` (`qwen2.5-coder:1.5b-base`).
3. Use a smaller or more heavily quantised `AGENT_MODEL`.

Alternatives worth comparing once the baseline works, each a one-line change:
Qwen 3.6 27B or Devstral Small 24B as the agent model, and Zeta 2.1 as the
completion model (community GGUF conversions only, with `prompt_format`
`zeta2_1`).

## Out of scope

- Odysseus and other non-coding assistants.
- Tailscale, LAN exposure, TLS or authentication on the Ollama port.
- Installing NVIDIA drivers or Docker.
- Automatic merging into Zed settings.
- llama.cpp or other model servers.
- A persistent tunnel service.
