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

# OpenCode reads the user's own coding rules from this copy. It is empty when
# OPENCODE_RULES is not set, because the container always mounts it.
if [ -n "$OPENCODE_RULES" ]; then
  [ -f "$OPENCODE_RULES" ] || die "OPENCODE_RULES file not found: $OPENCODE_RULES" "fix the path in local.env, or leave it empty"
  cp "$OPENCODE_RULES" "$OUT_DIR/opencode-rules.md"
else
  : >"$OUT_DIR/opencode-rules.md"
fi

info "Wrote $OUT_DIR/opencode.json (used by bin/opencode.sh)"
info "Wrote $OUT_DIR/zed-settings.jsonc"
echo "    Merge its keys into ~/.config/zed/settings.json by hand."
