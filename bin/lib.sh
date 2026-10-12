#!/usr/bin/env bash
# Shared helpers. Sourced by the other scripts in bin/.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# Variables the templates may use. Anything else containing "$" is left alone.
# shellcheck disable=SC2016
TEMPLATE_VARS='$OLLAMA_PORT $AGENT_BASE $AGENT_CTX $AUTOCOMPLETE_BASE $AUTOCOMPLETE_CTX'

info() { printf '==> %s\n' "$*"; }

# die <what failed> [<command or action that fixes it>]
die() {
  printf 'error: %s\n' "$1" >&2
  if [ $# -gt 1 ]; then printf '  fix: %s\n' "$2" >&2; fi
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is not installed" "$2"
}

# Loads config.env, then local.env, then $CONFIG_OVERRIDE, and exports the lot
# so that docker compose can interpolate it.
load_config() {
  local override="${CONFIG_OVERRIDE:-}"
  if [ -n "$override" ] && [ "${override#/}" = "$override" ]; then
    if [ -f "$override" ]; then override="$PWD/$override"; else override="$REPO_ROOT/$override"; fi
  fi

  set -a
  # shellcheck source=../config.env
  . "$REPO_ROOT/config.env"
  if [ -f "$REPO_ROOT/local.env" ]; then
    # shellcheck source=../local.env.example
    . "$REPO_ROOT/local.env"
  elif [ -z "$override" ]; then
    die "local.env is missing" "cp local.env.example local.env, then edit it"
  fi
  if [ -n "$override" ]; then
    [ -f "$override" ] || die "CONFIG_OVERRIDE file not found: $override"
    # shellcheck source=../config.test.env
    . "$override"
  fi

  : "${COMPOSE_PROJECT_NAME:=local-llm}"
  : "${USE_GPU:=0}"
  : "${TUNNEL_USE_AGENT:=0}"
  : "${SSH_HOST:=}"
  : "${PROJECTS_DIR:=$HOME/Projects}"
  : "${OUT_DIR:=$REPO_ROOT/out}"
  : "${TZ:=UTC}"
  set +a

  case "${ROLE:-}" in
    server | client) ;;
    *) die "ROLE must be 'server' or 'client', got '${ROLE:-}'" "set ROLE in local.env" ;;
  esac

  need docker "install Docker Engine: https://docs.docker.com/engine/install/ubuntu/"
  docker compose version >/dev/null 2>&1 ||
    die "the Docker Compose plugin is missing" "sudo apt-get install docker-compose-plugin"

  # Rootless Docker maps container root to the host user. Rootful Docker does
  # not, so there the OpenCode container runs under the host user's ids.
  if is_rootless; then CONTAINER_USER="0:0"; else CONTAINER_USER="$(id -u):$(id -g)"; fi
  export CONTAINER_USER
}

is_rootless() {
  docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless
}

# docker compose for this project, with the profile and overlays for this
# machine's role.
compose() {
  local files=(-f "$REPO_ROOT/compose.yaml")
  if [ "$ROLE" = server ] && [ "$USE_GPU" = 1 ]; then
    files+=(-f "$REPO_ROOT/compose.gpu.yaml")
  fi
  if [ "$ROLE" = client ] && [ "$TUNNEL_USE_AGENT" = 1 ]; then
    [ -S "${SSH_AUTH_SOCK:-}" ] ||
      die "TUNNEL_USE_AGENT=1 but no SSH agent is running" "start an agent, or set TUNNEL_USE_AGENT=0"
    files+=(-f "$REPO_ROOT/compose.agent.yaml")
  fi
  docker compose --project-directory "$REPO_ROOT" "${files[@]}" --profile "$ROLE" "$@"
}

# The service that answers as "ollama" on this machine.
endpoint_service() {
  if [ "$ROLE" = server ]; then echo ollama; else echo tunnel; fi
}

endpoint_url() { echo "http://127.0.0.1:${OLLAMA_PORT}"; }

port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

render_template() {
  envsubst "$TEMPLATE_VARS" <"$1"
}
