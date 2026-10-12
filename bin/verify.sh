#!/usr/bin/env bash
# Checks the model endpoint, both roles and the OpenCode container.
# Exits non-zero if any check fails.

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
need curl "sudo apt-get install curl"
need jq "sudo apt-get install jq"

base="$(endpoint_url)"
timeout="${VERIFY_TIMEOUT:-600}"
failures=0

pass() { printf 'PASS  %s\n' "$1"; }
skip() { printf 'SKIP  %s (%s)\n' "$1" "$2"; }
fail() {
  printf 'FAIL  %s\n      %s\n' "$1" "$2"
  failures=$((failures + 1))
}

api() {
  local path="$1"
  shift
  curl -fsS --max-time "$timeout" -H 'Content-Type: application/json' "$base$path" "$@"
}

info "Verifying $ROLE at $base"

# 1. Endpoint
if api /api/version >/dev/null 2>&1; then
  pass "model endpoint answers"
else
  fail "model endpoint answers" "nothing at $base; run bin/up.sh"
  exit 1
fi

# 2. Roles and their context sizes
check_role() {
  local role="$1" ctx="$2" params
  if params="$(api /api/show -d "{\"model\":\"$role\"}" 2>/dev/null | jq -r '.parameters // ""')" &&
    grep -Eq "^num_ctx[[:space:]]+$ctx\$" <<<"$params"; then
    pass "role '$role' exists with num_ctx $ctx"
  else
    fail "role '$role' exists with num_ctx $ctx" "run bin/up.sh on the server to rebuild the roles"
  fi
}
check_role agent "$AGENT_CTX"
check_role autocomplete "$AUTOCOMPLETE_CTX"

# 3. Tool calling
tool_request="$(jq -n '{
  model: "agent",
  stream: false,
  options: {temperature: 0},
  messages: [{role: "user", content: "What is the weather in Amsterdam? Use the tool."}],
  tools: [{type: "function", function: {
    name: "get_weather",
    description: "Get the current weather for a city",
    parameters: {type: "object", properties: {city: {type: "string"}}, required: ["city"]}
  }}]
}')"
if reply="$(api /api/chat -d "$tool_request" 2>&1)" &&
  [ "$(jq -r '.message.tool_calls | length' <<<"$reply" 2>/dev/null)" -ge 1 ] 2>/dev/null; then
  pass "agent returns a tool call"
else
  fail "agent returns a tool call" "reply was: $(head -c 300 <<<"$reply")"
fi

# 4. Completion
completion_request='{"model":"autocomplete","prompt":"def add(a, b):\n    return","max_tokens":16}'
if reply="$(api /v1/completions -d "$completion_request" 2>&1)" &&
  [ -n "$(jq -r '.choices[0].text // ""' <<<"$reply" 2>/dev/null | tr -d '[:space:]')" ]; then
  pass "autocomplete returns a completion"
else
  fail "autocomplete returns a completion" "reply was: $(head -c 300 <<<"$reply")"
fi

# 5 and 6. OpenCode container
"$REPO_ROOT/bin/render.sh" >/dev/null
mkdir -p "$PROJECTS_DIR"
oc() { compose run --rm -T --no-deps opencode "$@"; }

if oc opencode debug config 2>/dev/null | grep -q 'http://ollama:11434/v1'; then
  pass "opencode loads its config"
else
  fail "opencode loads its config" "run: bin/opencode.sh opencode debug config"
fi

chat_request='{"model":"agent","max_tokens":8,"messages":[{"role":"user","content":"Say OK"}]}'
if reply="$(oc curl -fsS --max-time "$timeout" -H 'Content-Type: application/json' \
  http://ollama:11434/v1/chat/completions -d "$chat_request" 2>/dev/null)" &&
  jq -e '.choices[0].message' <<<"$reply" >/dev/null 2>&1; then
  pass "opencode container gets a reply from http://ollama:11434/v1"
else
  fail "opencode container gets a reply from http://ollama:11434/v1" "reply was: $(head -c 300 <<<"$reply")"
fi

probe=".local-llm-verify.$$"
if oc touch "/workspace/$probe" 2>/dev/null && [ "$(stat -c %u "$PROJECTS_DIR/$probe")" = "$(id -u)" ]; then
  pass "files created by opencode belong to $(id -un)"
else
  fail "files created by opencode belong to $(id -un)" "check PROJECTS_DIR ($PROJECTS_DIR) is writable"
fi
rm -f "$PROJECTS_DIR/$probe" 2>/dev/null || true

# 7. GPU
if [ "$ROLE" = server ] && [ "$USE_GPU" = 1 ]; then
  if compose exec -T ollama nvidia-smi >/dev/null 2>&1; then
    pass "GPU is visible in the ollama container"
  else
    fail "GPU is visible in the ollama container" "run bin/prereqs.sh"
  fi

  # Checks 3 and 4 loaded both roles; size_vram equals size when a model sits
  # entirely on the GPU.
  loaded="$(api /api/ps 2>/dev/null || echo '{}')"
  for role in agent autocomplete; do
    split="$(jq -r --arg m "$role:latest" \
      '.models[]? | select(.name == $m) | if .size_vram >= .size then "gpu" else "\(.size_vram * 100 / .size | floor)%" end' \
      <<<"$loaded")"
    case "$split" in
      gpu) pass "role '$role' is fully on the GPU" ;;
      "") fail "role '$role' is fully on the GPU" "it is not loaded; rerun bin/verify.sh" ;;
      *) fail "role '$role' is fully on the GPU" "only $split fits in VRAM; see Tuning in README.md" ;;
    esac
  done
else
  skip "GPU checks" "ROLE=$ROLE USE_GPU=$USE_GPU"
fi

echo
if [ "$failures" -eq 0 ]; then
  info "All checks passed"
else
  info "$failures check(s) failed"
  exit 1
fi
