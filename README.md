# local-llm

A self-hosted coding assistant for the [Zed](https://zed.dev) editor and
[OpenCode](https://opencode.ai), running on your own GPU. Nothing leaves your
machines.

This repo is the whole setup as config: clone it on a machine, run one
script, and that machine is either the model server or a client of it.

## What you get

- **An agent in Zed.** Chat, file edits and tool use in Zed's agent panel.
- **Autocomplete in Zed.** Edit predictions as you type, from a second,
  smaller model.
- **OpenCode.** A coding agent in the terminal or in Zed's agent panel,
  sandboxed in a container that can only see one projects folder.
- **Use from anywhere.** A laptop reaches the GPU machine through an SSH
  tunnel. The model port is never exposed to the network.
- **Swappable models.** Clients know two role names, `agent` and
  `autocomplete`. Which model sits behind each is one line of config on the
  server.

## How it works

```
client (computer)                         server (GPU machine)
┌───────────────────────────────┐         ┌───────────────────────────────┐
│ Zed ── localhost:11434        │         │ Zed ── localhost:11434        │
│          │                    │         │          │                    │
│ ┌────────▼─────────┐          │   SSH   │ ┌────────▼─────────┐          │
│ │ tunnel           ├──────────┼────────►│ │ ollama ── GPU    │          │
│ │ (named "ollama") │          │         │ │                  │          │
│ └────────▲─────────┘          │         │ └────────▲─────────┘          │
│ ┌────────┴─────────┐          │         │ ┌────────┴─────────┐          │
│ │ opencode         │          │         │ │ opencode         │          │
│ └──────────────────┘          │         │ └──────────────────┘          │
└───────────────────────────────┘         └───────────────────────────────┘
```

Everything runs in Docker Compose. A machine has one of two roles:

- **Server**: runs [Ollama](https://ollama.com) with the models on the GPU.
- **Client**: runs a small SSH tunnel container that stands in for Ollama.

Because the tunnel takes Ollama's place on a client, the addresses never
change. Zed always uses `http://localhost:11434`, and the OpenCode container
always uses `http://ollama:11434/v1`. The Zed and OpenCode config is the
same on every machine.

### Roles instead of model names

On the server, `bin/up.sh` builds two Ollama models from the templates in
`modelfiles/`:

| Role | Used for | Default model | Context |
|---|---|---|---|
| `agent` | Zed agent panel, OpenCode | `qwen3.6:27b` | 32,768 tokens |
| `autocomplete` | Zed edit predictions | `qwen2.5-coder:3b-base` | 4,096 tokens |

A role is a thin layer over its base model: the same weights, plus a context
size and optional sampling settings or system prompt. Swapping the model
behind a role is a server-side change, and no client needs to know.

## Requirements

**Server**

- Ubuntu with an NVIDIA GPU and working driver (`nvidia-smi` prints a table).
  The defaults are sized for 24 GB of VRAM.
- Docker Engine with the Compose plugin.
- About 25 GB of free disk for the default models.
- An SSH server, if other machines will connect.

**Client**

- Linux with Docker Engine and the Compose plugin.
- An SSH key that logs in to the server without a password prompt.

**Both**: `curl`, `jq` and `envsubst` (`sudo apt-get install curl jq
gettext-base`), and Zed if you want the editor integration.

## Server setup

```sh
git clone <this repo> && cd local-llm
cp local.env.example local.env   # keep ROLE=server and USE_GPU=1
bin/prereqs.sh                   # once: lets Docker use the GPU, needs sudo
bin/up.sh                        # start Ollama, pull models, build the roles
bin/verify.sh
```

`bin/prereqs.sh` installs the NVIDIA container toolkit with `apt` and
configures Docker to use it. It does not install GPU drivers or Docker.

`bin/up.sh` downloads about 21 GB the first time. It is safe to rerun.

Then set up Zed as described under [Zed](#zed).

## Client setup

```sh
git clone <this repo> && cd local-llm
cp local.env.example local.env   # set ROLE=client and SSH_HOST=user@server
ssh user@server true             # once, to record the server's host key
bin/up.sh                        # start the tunnel
bin/verify.sh
```

- **Port 11434 must be free.** If a local Ollama holds it, stop that first.
- **Keys with a passphrase** need `TUNNEL_USE_AGENT=1` in `local.env` and a
  running SSH agent. A key without a passphrase needs nothing extra.
- **The tunnel restarts with Docker**, so it comes back after a reboot.

## Zed

`bin/up.sh` writes `out/zed-settings.jsonc`. Open your Zed settings
(`~/.config/zed/settings.json`) and merge in its keys:

- `agent`, `language_models` and `edit_predictions`: replace any existing
  keys of the same name.
- `agent_servers`: add its `OpenCode` entry next to the agents you already
  have. See [OpenCode in Zed](#opencode-in-zed).

The snippet is not applied automatically, since your settings file holds your
own preferences and comments.

Every model pulled on the server shows up in Zed's model picker, so you can
switch models per conversation.

## OpenCode

```sh
bin/opencode.sh                      # interactive, in your projects folder
bin/opencode.sh opencode my-app      # interactive, in one project
bin/opencode.sh opencode run "..."   # a one-off prompt
```

The container sees only the folder named by `PROJECTS_DIR` in `local.env`,
mounted at the same path as on the host. Files it creates there belong to
your user.

### OpenCode in Zed

With the `agent_servers` entry from `out/zed-settings.jsonc`, Zed starts
OpenCode in its container over ACP, the protocol Zed uses for external
agents. Start a thread with the `+` button in the agent panel, then
**OpenCode**. The agents from [the harness](#the-harness) and your coding
rules work there as in the terminal. Custom slash commands do not: in
OpenCode 2.0.27 they return nothing over ACP.

- **Only projects under `PROJECTS_DIR`.** Zed passes the project's path to
  OpenCode, and the container has no other folders.
- **Run `bin/opencode.sh` once in a terminal first.** The first start builds
  the image, which takes minutes, and Zed shows no progress meanwhile.
- **Linux only.** On Windows, Zed passes Windows paths that do not exist in
  the container.

### The harness

The agents in `opencode/config/agents/` shape how OpenCode works, the same on
every machine. They are mounted into the container, so a change applies the
next time OpenCode starts.

| Agent | What it does |
|---|---|
| `build` | The default. Reads first, makes small changes, checks them and calls `review`. Asks before any command that is not read-only. |
| `plan` | Read-only. Investigates the code and writes a plan. Switch to it with Tab, or in Zed's mode menu. |
| `review` | A subagent that checks the uncommitted changes against the coding rules and for bugs. |

The docs at opencode.ai describe OpenCode 1.x. Plugins and custom commands
work differently in 2.x and are not part of this harness yet.

**Your own coding rules.** Set `OPENCODE_RULES` in `local.env` to a markdown
file, for example `$HOME/.claude/CLAUDE.md`. OpenCode follows it in every
session. The file stays on your machine and is not committed.

## Configuration

Settings are read from three files, later ones overriding earlier ones.

| File | Committed | Holds |
|---|---|---|
| `config.env` | yes | Shared settings: versions, models, context sizes |
| `local.env` | no | This machine's role, SSH host, projects folder, coding rules |
| `$CONFIG_OVERRIDE` | n/a | Optional extra file, used for testing |

### Changing models

Edit `config.env` on the server, then run `bin/up.sh` there.

| To | Change |
|---|---|
| Swap the agent model | `AGENT_BASE`, and `AGENT_THINKING` to match |
| Swap the autocomplete model | `AUTOCOMPLETE_BASE` |
| Change a context size | `AGENT_CTX`, `AUTOCOMPLETE_CTX` |
| Add models to choose from in Zed | `EXTRA_MODELS` |
| Change sampling or add a system prompt | `modelfiles/<role>.Modelfile.tmpl` |

Things to keep in mind:

- **Agent models must support tool calling.** Some small models write tool
  calls as plain text, which `bin/verify.sh` reports as a failure.
- **Autocomplete models must support fill-in-the-middle.** In the Ollama
  library these usually carry a `-base` suffix. If you switch to another
  model family, also change `prompt_format` in `zed/settings.jsonc.tmpl`.
- **A context size or `AGENT_THINKING` change alters the Zed snippet.** Merge
  `out/zed-settings.jsonc` again on each machine running Zed.
- **Models from Hugging Face** are written `hf.co/<user>/<repo>:<quant>`.
- **Commit and pull `config.env`** on the other machines afterwards, so that
  every copy of the repo agrees.

### Tuning for 24 GB of VRAM

The default agent model takes 19 GB before its context is counted, so the
defaults are close to the limit. If `bin/verify.sh` reports that a role is
not fully on the GPU, or replies are slow, change these in order:

1. Lower `AGENT_CTX`, for example to `24576`.
2. Set `AUTOCOMPLETE_BASE=qwen2.5-coder:1.5b-base`.
3. Use a smaller or more heavily quantised `AGENT_BASE`.

If everything fits with room to spare, raise `AGENT_CTX` instead. Agents work
better with more context.

Models worth comparing once the defaults work:

- **Agent, faster**: `qwen3.6:35b`, a mixture-of-experts model that is
  quicker per token but scores lower on agentic coding. At 24 GB it spills a
  little into system RAM.
- **Agent, larger**: `qwen3-coder-next` (52 GB), which only fits with most of
  it in system RAM. Needs 64 GB of RAM and is slower.
- **Agent, previous default**: `qwen3-coder:30b`.
- **Autocomplete**: Zeta 2.1, Zed's own prediction model. Only community
  GGUF conversions exist; use `prompt_format: "zeta2_1"`.

When you change `AGENT_BASE`, set `AGENT_THINKING` to match: `true` only for
models with a thinking mode.

## Day-to-day

| Task | Command |
|---|---|
| Check everything works | `bin/verify.sh` |
| Apply a config change | `bin/up.sh` |
| See what is loaded on the GPU | `docker compose -p local-llm exec ollama ollama ps` |
| Read the server's logs | `docker compose -p local-llm logs ollama` |
| Read the tunnel's logs | `docker compose -p local-llm logs tunnel` |
| Stop, keeping the models | `docker compose -p local-llm down` |
| Remove everything, models included | `docker compose -p local-llm down -v` |

Models unload after 30 minutes without use, which frees the GPU. The first
request afterwards is slow while the model loads again.

### Updating

Raise `OLLAMA_IMAGE_TAG` or `OPENCODE_VERSION` in `config.env`, then run
`bin/up.sh` for Ollama. OpenCode rebuilds the next time `bin/opencode.sh`
runs.

## Troubleshooting

**`port 11434 is already in use by something else`**
Another program holds the port, usually another Ollama. Find it with
`docker ps` or `systemctl status ollama` and stop it, or set a different
`OLLAMA_PORT` in `config.env` on every machine.

**`the tunnel did not reach Ollama`**
Check each of these from the client:
- `ssh <SSH_HOST> true` succeeds without asking anything.
- `bin/up.sh` has run on the server.
- The server's SSH daemon allows TCP forwarding. Ubuntu does by default.
- The tunnel's logs, for the exact SSH error.

**`Host key verification failed` in the tunnel's logs**
The server's host key is not in `~/.ssh/known_hosts`. Run
`ssh <SSH_HOST> true` once and accept the key, then `bin/up.sh`.

**A role is not fully on the GPU**
The models do not fit in VRAM. See
[Tuning](#tuning-for-24-gb-of-vram).

**The Zed agent forgets earlier parts of a conversation**
Zed asks Ollama for a 4,096-token context unless told otherwise. Check that
`language_models.ollama` from `out/zed-settings.jsonc` is in your Zed
settings.

**The Zed agent explains changes but never makes them**
Check these in order:
- The agent panel's profile is **Write**. The **Ask** profile is read-only,
  and **Minimal** has no tools at all. Switch in the profile selector at the
  bottom of the agent panel.
- The model makes real tool calls. Some models, including the small Qwen 2.5
  Coder models, write the call out as text, and Zed then shows it instead of
  running it. `bin/verify.sh` checks this for the `agent` role.
- Zed's model picker shows the `agent` model, not a model without the tools
  label.
- You started a new thread. An existing thread keeps the model it started
  with, even after you change `default_model`.

**`agent returns a tool call` fails in `bin/verify.sh`**
The model behind `agent` does not produce structured tool calls, so Zed and
OpenCode cannot edit files with it. Choose another `AGENT_BASE`.

**A model pull fails with `503`**
The Ollama registry is briefly unavailable. Rerun `bin/up.sh`; a pull
resumes where it stopped.

**`could not select device driver "nvidia"`**
Docker cannot use the GPU yet. Run `bin/prereqs.sh`.

## Testing the scripts without a GPU

```sh
CONFIG_OVERRIDE=config.test.env bin/up.sh
CONFIG_OVERRIDE=config.test.env bin/verify.sh
docker compose -p local-llm-test down -v --rmi local   # clean up
```

This runs tiny models on the CPU, on port 11435, as a separate Compose
project, so it does not disturb a real setup on the same machine.

## Repository layout

| Path | Purpose |
|---|---|
| `config.env` | Shared settings |
| `local.env.example` | Template for this machine's `local.env` |
| `config.test.env` | Overrides for testing without a GPU |
| `compose.yaml` | The `ollama`, `tunnel` and `opencode` services |
| `compose.gpu.yaml` | Adds the NVIDIA GPU to `ollama` |
| `compose.agent.yaml` | Adds the SSH agent to `tunnel` |
| `modelfiles/` | One template per role |
| `opencode/` | OpenCode image and config template |
| `opencode/config/agents/` | OpenCode agents: `build`, `plan`, `review` |
| `tunnel/` | SSH tunnel image |
| `zed/` | Zed settings template |
| `bin/prereqs.sh` | Server, once: GPU support for Docker |
| `bin/up.sh` | Start this machine's side |
| `bin/verify.sh` | Check that everything works |
| `bin/opencode.sh` | Run OpenCode |
| `bin/render.sh` | Write `out/` from the templates |
| `out/` | Generated client config, not committed |
| `docs/superpowers/specs/` | Design notes |

## Security

- Ollama has no authentication. It is published on `127.0.0.1` only and
  reached remotely through SSH; do not bind it to another interface.
- The tunnel container reads a copy of `~/.ssh`, mounted read-only.
- The OpenCode container can read and write everything in `PROJECTS_DIR`,
  and nothing else on the host.
