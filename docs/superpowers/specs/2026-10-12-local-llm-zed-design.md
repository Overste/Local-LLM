# Local coding LLM for Zed and OpenCode: design

Date: 2026-10-12
Status: approved

## Goal

A git repo that reproduces a local coding-LLM setup with one command per
machine. The model server runs on a desktop PC (RTX 4090, 24 GB VRAM, 64 GB
RAM, Ubuntu). Zed and OpenCode use it either on that PC or from a laptop
through an SSH tunnel.

Success means:

- On the 4090 PC, `bin/up.sh` brings up a GPU-backed Ollama with the
  configured models, and `bin/verify.sh` passes.
- On any machine, Zed's agent panel and edit predictions work against
  `http://localhost:11434`, and OpenCode works from its container.
- Swapping the model behind a role means editing `config.env` on the server
  and rerunning `bin/up.sh`. No client config changes.

## Decisions

| Topic | Decision |
|---|---|
| Model server | Ollama in Docker Compose |
| Server OS | Ubuntu, scripts use `apt` |
| Zed features | Agent panel and edit predictions |
| Other clients | OpenCode, running in Docker |
| Remote access | SSH tunnel; the server listens on localhost only |
| Models | Role aliases built from Modelfiles, plus any extra pulled models |
| Scope | Coding only; standard coder models |

## Architecture

```
client machine (laptop)                    server (4090 PC)
┌───────────────────────────────┐         ┌───────────────────────────────┐
│ Zed ── localhost:11434        │         │ Zed ── localhost:11434        │
│          │                    │         │          │                    │
│ ┌────────▼─────────┐          │   SSH   │ ┌────────▼─────────┐          │
│ │ tunnel           ├──────────┼────────►│ │ ollama ── RTX 4090│         │
│ │ (alias: ollama)  │          │         │ │                  │          │
│ └────────▲─────────┘          │         │ └────────▲─────────┘          │
│ ┌────────┴─────────┐          │         │ ┌────────┴─────────┐          │
│ │ opencode         │          │         │ │ opencode         │          │
│ └──────────────────┘          │         │ └──────────────────┘          │
└───────────────────────────────┘         └───────────────────────────────┘
```

One Compose project serves both kinds of machine. On the server the `ollama`
service answers on the Compose network as `ollama`. On a client the `tunnel`
service takes that same name. Zed therefore always uses
`http://localhost:11434` and the OpenCode container always uses
`http://ollama:11434/v1`.

The tunnel runs in a container because a host-side tunnel is unreliable to
reach from other containers under rootless Docker.

## Configuration

Three layers, loaded in this order by `bin/lib.sh`:

1. `config.env`, committed and shared by all machines.
2. `local.env`, gitignored, one per machine, created from
   `local.env.example`.
3. The file named by `CONFIG_OVERRIDE`, if set. Used for tests.

### config.env

| Variable | Starting value | Meaning |
|---|---|---|
| `OLLAMA_IMAGE_TAG` | `0.34.1` | Pinned `ollama/ollama` image |
| `OPENCODE_VERSION` | `2.0.27` | Pinned `@opencode/cli` |
| `OLLAMA_PORT` | `11434` | Host port, bound to 127.0.0.1 |
| `AGENT_BASE` | `qwen3-coder:30b` | Model behind the `agent` role |
| `AGENT_CTX` | `32768` | Context size of `agent` |
| `AUTOCOMPLETE_BASE` | `qwen2.5-coder:3b-base` | Model behind `autocomplete` |
| `AUTOCOMPLETE_CTX` | `4096` | Context size of `autocomplete` |
| `EXTRA_MODELS` | empty | Further tags to pull, space separated |

Model tags and context sizes are starting values, tuned on the 4090 PC.

### local.env

| Variable | Meaning |
|---|---|
| `ROLE` | `server` or `client` |
| `USE_GPU` | Server only. `1` adds the NVIDIA overlay |
| `SSH_HOST` | Client only. SSH destination of the server |
| `TUNNEL_USE_AGENT` | Client only. `1` passes the SSH agent to the tunnel |
| `PROJECTS_DIR` | Folder the OpenCode container may work in |
| `TZ` | Time zone for the OpenCode container |

## Models

### Roles

Each `modelfiles/<role>.Modelfile.tmpl` becomes an Ollama model named
`<role>`. A template sets the base model and `num_ctx`, and may set sampling
parameters and a system prompt. A role shares the weights of its base model.

Two roles ship: `agent` and `autocomplete`. Clients refer only to these
names. Sampling parameters are left at the base model's defaults; the
templates carry commented examples.

Per-role context sizes keep the autocomplete model's memory small and let
OpenCode get a large context even though its OpenAI-compatible endpoint
cannot request one.

### Extra models

Anything in `EXTRA_MODELS` is pulled as-is. Zed discovers every pulled model
and offers it in its model picker. Ollama also accepts Hugging Face GGUF
references of the form `hf.co/<user>/<repo>:<quant>`.

## Components

### compose.yaml

- `ollama` (profile `server`): pinned image, port
  `127.0.0.1:${OLLAMA_PORT}:11434`, named volume `ollama-models`,
  `restart: unless-stopped`, healthcheck `ollama list`. Environment:
  `OLLAMA_MAX_LOADED_MODELS=2`, `OLLAMA_NUM_PARALLEL=1`,
  `OLLAMA_KEEP_ALIVE=30m`, `OLLAMA_FLASH_ATTENTION=1`,
  `OLLAMA_KV_CACHE_TYPE=q8_0`.
- `tunnel` (profile `client`): Alpine with an SSH client. Forwards its port
  11434 to `127.0.0.1:${OLLAMA_PORT}` on `SSH_HOST`, with keep-alives,
  `ExitOnForwardFailure` and strict host key checking. Network alias
  `ollama`. Publishes `127.0.0.1:${OLLAMA_PORT}`. Reads a copy of the host's
  `~/.ssh`, mounted read-only.
- `opencode` (profile `opencode`): Node image with pinned `@opencode/cli`.
  Mounts `PROJECTS_DIR` at `/workspace`, the rendered `opencode.json`
  read-only, and a named volume for its data. Runs as the host user under
  rootful Docker so that files it creates are owned by that user.

No service sets `container_name`, and the project is named `local-llm`, so it
cannot collide with other stacks.

`compose.gpu.yaml` adds the NVIDIA device reservation to `ollama`.
`compose.agent.yaml` adds the SSH agent socket to `tunnel`.

### Scripts

All in `bin/`, all using `set -euo pipefail`, all sourcing `lib.sh`.

- `prereqs.sh`: server only, run once. Fails with instructions if
  `nvidia-smi` or Docker is missing. Installs `nvidia-container-toolkit` via
  apt, configures the runtime for rootful or rootless Docker, and runs
  `nvidia-smi` in a throwaway GPU container.
- `up.sh`: on a server, checks the port is free, starts `ollama`, pulls the
  role bases and `EXTRA_MODELS`, and creates the roles. On a client, starts
  `tunnel` and waits for the endpoint. Then renders the client config.
  Idempotent.
- `render.sh`: writes `out/zed-settings.jsonc` and `out/opencode.json` from
  the templates.
- `opencode.sh`: runs the OpenCode container, passing arguments through.
- `verify.sh`: see Verification.

### Client config

- **Zed** (`zed/settings.jsonc.tmpl`): Ollama provider at
  `http://localhost:${OLLAMA_PORT}` with a provider-wide `context_window`,
  the `agent` role with `max_tokens` equal to `AGENT_CTX`, `agent` as default
  model, and edit predictions on `autocomplete` with `prompt_format: "qwen"`.
  Zed otherwise requests a 4096-token context. Merged into
  `~/.config/zed/settings.json` by hand.
- **OpenCode** (`opencode/opencode.json.tmpl`): provider `ollama` through
  `@ai-sdk/openai-compatible` at `http://ollama:11434/v1`, model `agent`
  with `limit.context` equal to `AGENT_CTX`, default model `ollama/agent`.

## Error handling

Every failure message names what failed and the next command to run. No
script installs GPU drivers or Docker, edits Zed settings, stops or removes
other Docker stacks, opens firewall ports, creates SSH keys or enables
`sshd`.

## Verification

`bin/verify.sh` prints pass or fail per check and exits non-zero on failure.

1. Model endpoint answers at `http://localhost:${OLLAMA_PORT}`.
2. Roles `agent` and `autocomplete` exist with the configured `num_ctx`.
3. `agent` answers a chat request offering one tool with a tool call.
4. `autocomplete` answers `/v1/completions` with non-empty text.
5. The OpenCode container loads its config and gets a model reply from
   `http://ollama:11434/v1`.
6. A file created by the OpenCode container in `PROJECTS_DIR` is owned by the
   host user.
7. Server with `USE_GPU=1` only: `nvidia-smi` works in the container, and
   both roles are loaded fully on the GPU.

### Testing

- **On the laptop (no NVIDIA GPU):** the server role with
  `CONFIG_OVERRIDE=config.test.env`, which uses tiny models, port 11435 and a
  separate project name. Covers checks 1 to 6.
- **Static:** `shellcheck` on all scripts, `docker compose config` for every
  profile, a JSON parse of the rendered OpenCode config.
- **On the 4090 PC only:** `prereqs.sh`, check 7, the VRAM fit of the real
  models, and the tunnel end to end.

## Tuning

24 GB is tight for a 19 GB agent model, its context and a second model. If
check 7 reports a CPU split, or generation is slow, change `config.env` in
this order and rerun `bin/up.sh`:

1. Lower `AGENT_CTX` (for example to 24576).
2. Use a smaller `AUTOCOMPLETE_BASE` (`qwen2.5-coder:1.5b-base`).
3. Use a smaller or more heavily quantised `AGENT_BASE`.

Alternatives to compare once the baseline works: Qwen 3.6 27B or Devstral
Small 24B behind `agent`, and Zeta 2.1 behind `autocomplete` (community GGUF
conversions only, with `prompt_format: "zeta2_1"` in Zed).

## Out of scope

- Odysseus and other non-coding assistants.
- Tailscale, LAN exposure, TLS or authentication on the Ollama port.
- Installing NVIDIA drivers or Docker.
- Automatic merging into Zed settings.
- llama.cpp or other model servers.
