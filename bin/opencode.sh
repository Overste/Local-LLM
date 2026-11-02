#!/usr/bin/env bash
# Runs OpenCode in its container, with PROJECTS_DIR mounted at the same path.
#   bin/opencode.sh                     interactive, in PROJECTS_DIR
#   bin/opencode.sh opencode my-app     interactive, in PROJECTS_DIR/my-app
#   bin/opencode.sh opencode run "..."  one-off prompt
#   bin/opencode.sh opencode acp        for Zed's agent panel (see zed/)

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

"$REPO_ROOT/bin/render.sh" >/dev/null
mkdir -p "$PROJECTS_DIR"

# Zed starts OpenCode with pipes instead of a terminal. A TTY would mix stderr
# into stdout and break the ACP messages there, so only use one in a terminal.
run_flags=()
if [ ! -t 0 ]; then run_flags+=(-T); fi

# --build picks up a changed OPENCODE_VERSION; it is a no-op otherwise.
compose run --build --quiet-build --rm --no-deps "${run_flags[@]}" opencode "$@"
