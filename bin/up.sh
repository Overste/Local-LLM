#!/usr/bin/env bash
# Brings this machine's side of the setup up. Safe to rerun.
#   server: starts Ollama, pulls the models, builds the roles.
#   client: starts the SSH tunnel to the server.

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
need curl "sudo apt-get install curl"
need envsubst "sudo apt-get install gettext-base"

service="$(endpoint_service)"

if [ -z "$(compose ps -q "$service" 2>/dev/null)" ] && port_in_use "$OLLAMA_PORT"; then
  die "port $OLLAMA_PORT is already in use by something else" \
    "stop it (often another Ollama: 'docker ps', 'systemctl status ollama'), or change OLLAMA_PORT"
fi

ollama() { compose exec -T ollama ollama "$@"; }

up_server() {
  info "Starting Ollama $OLLAMA_IMAGE_TAG (GPU: $USE_GPU)"
  compose up -d --wait ollama

  local model
  # EXTRA_MODELS is a space-separated list.
  # shellcheck disable=SC2086
  for model in "$AGENT_BASE" "$AUTOCOMPLETE_BASE" $EXTRA_MODELS; do
    info "Pulling $model"
    # The registry answers 503 now and then; a pull resumes where it stopped.
    ollama pull "$model" || { sleep 5 && ollama pull "$model"; } ||
      die "could not pull '$model'" "check the tag at https://ollama.com/library, or rerun bin/up.sh"
  done

  local tmpl role
  for tmpl in "$REPO_ROOT"/modelfiles/*.Modelfile.tmpl; do
    role="$(basename "$tmpl" .Modelfile.tmpl)"
    info "Building role '$role'"
    # $1 is expanded by the shell inside the container.
    # shellcheck disable=SC2016
    render_template "$tmpl" |
      compose exec -T ollama sh -c 'cat >/tmp/role.Modelfile && ollama create "$1" -f /tmp/role.Modelfile' sh "$role" ||
      die "could not build role '$role'" "check modelfiles/$role.Modelfile.tmpl"
  done
}

up_client() {
  [ -n "$SSH_HOST" ] || die "SSH_HOST is not set" "set SSH_HOST in local.env"
  [ -d "$HOME/.ssh" ] || die "$HOME/.ssh does not exist" "create a key with ssh-keygen and add it to the server"

  info "Starting SSH tunnel to $SSH_HOST"
  compose up -d --build tunnel

  for _ in $(seq 1 30); do
    if curl -fsS --max-time 2 "$(endpoint_url)/api/version" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  compose logs --tail 20 tunnel >&2 || true
  die "the tunnel did not reach Ollama on $SSH_HOST" \
    "check 'ssh $SSH_HOST' works without a prompt, and that bin/up.sh has run on the server"
}

if [ "$ROLE" = server ]; then up_server; else up_client; fi

"$REPO_ROOT/bin/render.sh"

echo
info "Up. Next: bin/verify.sh"
