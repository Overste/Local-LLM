# local-llm

A local coding LLM for Zed and OpenCode, reproducible with one command per
machine.

- **Server**: the GPU machine. Runs Ollama in Docker.
- **Client**: any other machine. Reaches the server through an SSH tunnel.

Zed always talks to `http://localhost:11434`. OpenCode runs in a container
and always talks to `http://ollama:11434/v1`. Both use two role names,
`agent` and `autocomplete`; which model sits behind each is set in
`config.env`.

## Server setup (the 4090 PC)

Needs Ubuntu with the NVIDIA driver (`nvidia-smi` works) and Docker with the
Compose plugin.

```sh
git clone <this repo> && cd local-llm
cp local.env.example local.env   # keep ROLE=server, USE_GPU=1
bin/prereqs.sh                   # once: NVIDIA container toolkit, uses sudo
bin/up.sh                        # start Ollama, pull models (about 21 GB), build roles
bin/verify.sh
```

Then set up Zed as described under "Zed" below.

To use it from another machine, the server also needs an SSH server
(`sudo apt-get install openssh-server`) with your client's public key in
`~/.ssh/authorized_keys`.

## Client setup (a laptop)

Needs Docker with the Compose plugin, and an SSH key that logs in to the
server without a prompt.

```sh
git clone <this repo> && cd local-llm
cp local.env.example local.env   # set ROLE=client and SSH_HOST=user@server
ssh user@server true             # once, to record the server's host key
bin/up.sh                        # start the tunnel
bin/verify.sh
```

Notes:

- Port 11434 must be free. If a local Ollama holds it, stop that first.
- A key with a passphrase needs `TUNNEL_USE_AGENT=1` and a running SSH agent.
- The tunnel restarts with Docker, so it comes back after a reboot.

## Zed

`bin/up.sh` writes `out/zed-settings.jsonc`. Merge its three keys (`agent`,
`language_models`, `edit_predictions`) into `~/.config/zed/settings.json`. It
is the same on every machine.

Every model pulled on the server appears in Zed's model picker.

## OpenCode

```sh
bin/opencode.sh                      # interactive, in PROJECTS_DIR
bin/opencode.sh opencode my-app      # interactive, in PROJECTS_DIR/my-app
bin/opencode.sh opencode run "..."   # one-off prompt
```

The container sees only `PROJECTS_DIR` from `local.env`.

## Changing models

All on the server, in `config.env`, followed by `bin/up.sh`. Clients need no
change, because they only know the role names.

| To | Change |
|---|---|
| Swap the agent model | `AGENT_BASE` |
| Swap the autocomplete model | `AUTOCOMPLETE_BASE` (a FIM-capable `-base` model) |
| Change a context size | `AGENT_CTX`, `AUTOCOMPLETE_CTX` |
| Add models to pick from in Zed | `EXTRA_MODELS` |
| Change sampling or add a system prompt | `modelfiles/<role>.Modelfile.tmpl` |

A context size change also changes `out/zed-settings.jsonc`, so merge that
again on each machine running Zed.

A model from Hugging Face is written `hf.co/<user>/<repo>:<quant>`.

If you swap the autocomplete model for another family, also change
`prompt_format` in `zed/settings.jsonc.tmpl`.

## Tuning for 24 GB of VRAM

The default agent model is 19 GB before its context. If `bin/verify.sh`
reports that a role is not fully on the GPU, or replies are slow, change
these in order and rerun `bin/up.sh`:

1. Lower `AGENT_CTX`, for example to `24576`.
2. Set `AUTOCOMPLETE_BASE=qwen2.5-coder:1.5b-base`.
3. Use a smaller or more heavily quantised `AGENT_BASE`.

If everything fits with room to spare, raise `AGENT_CTX`. OpenCode works
better with more context.

Worth comparing once the defaults work:

- Agent: Qwen 3.6 27B, Devstral Small 24B. Check the exact tags at
  <https://ollama.com/library>.
- Autocomplete: Zeta 2.1, Zed's own prediction model. Only community GGUF
  conversions exist; use `prompt_format: "zeta2_1"`.

## Testing the scripts without a GPU

```sh
CONFIG_OVERRIDE=config.test.env bin/up.sh
CONFIG_OVERRIDE=config.test.env bin/verify.sh
```

This runs tiny models on the CPU, on port 11435, as a separate Compose
project. Remove it with:

```sh
docker compose -p local-llm-test down -v --rmi local
```

## Files

| Path | Purpose |
|---|---|
| `config.env` | Shared settings: versions, models, context sizes |
| `local.env` | This machine's role and paths (not committed) |
| `compose.yaml` | The `ollama`, `tunnel` and `opencode` services |
| `modelfiles/` | One template per role |
| `bin/` | `prereqs.sh`, `up.sh`, `verify.sh`, `opencode.sh`, `render.sh` |
| `out/` | Rendered client config (not committed) |
| `docs/superpowers/specs/` | Design notes |
