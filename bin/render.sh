#!/usr/bin/env bash
# Writes the client config for Zed and OpenCode from the templates.
# Nothing outside the repo is touched.

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
need envsubst "sudo apt-get install gettext-base"

mkdir -p "$OUT_DIR"
render_template "$REPO_ROOT/zed/settings.jsonc.tmpl" >"$OUT_DIR/zed-settings.jsonc"
render_template "$REPO_ROOT/opencode/opencode.json.tmpl" >"$OUT_DIR/opencode.json"

info "Wrote $OUT_DIR/opencode.json (used by bin/opencode.sh)"
info "Wrote $OUT_DIR/zed-settings.jsonc"
echo "    Merge its keys into ~/.config/zed/settings.json by hand."
