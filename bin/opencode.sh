#!/usr/bin/env bash
# Runs OpenCode in its container, with PROJECTS_DIR mounted at /workspace.
#   bin/opencode.sh                     interactive, in /workspace
#   bin/opencode.sh opencode my-app     interactive, in /workspace/my-app
#   bin/opencode.sh opencode run "..."  one-off prompt

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

"$REPO_ROOT/bin/render.sh" >/dev/null
mkdir -p "$PROJECTS_DIR"

compose run --rm --no-deps opencode "$@"
