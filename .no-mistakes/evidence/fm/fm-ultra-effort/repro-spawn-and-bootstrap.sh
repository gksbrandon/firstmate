#!/usr/bin/env bash
# Operator transcript for the Codex-only `ultra` reasoning effort.
# Drives the real bin/fm-spawn.sh and bin/fm-bootstrap.sh against a fake tmux
# backend that records the literal launch command a pane would receive.
set -u

ROOT=${FM_EVIDENCE_ROOT:?}
OUT=${FM_EVIDENCE_OUT:?}

. "$ROOT/tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ultra-evidence)

exec > >(tee "$OUT") 2>&1

section() { printf '\n================================================================\n%s\n================================================================\n' "$1"; }
step() { printf '\n$ %s\n' "$1"; }

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" = "-l" ] && printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  cat > "$fakebin/muse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/timeout" "$fakebin/muse"
  printf '%s\n' "$fakebin"
}

CASES=$TMP_ROOT/cases
make_case() { # <name> <harness> -> echoes home|wt|fakebin|log|id|proj
  local name=$1 harness=$2 dir home proj wt fakebin log id
  dir="$CASES/$name"
  home="$dir/home"; proj="$dir/project"; wt="$dir/wt"; log="$dir/launch.log"
  fakebin=$(make_fakebin "$dir/fake")
  id="task-$name"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$home/xdgconfig/muse" "$home/xdgdata"
  printf '{"token":"evidence"}\n' > "$home/xdgconfig/muse/auth.json"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name" >/dev/null 2>&1
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home|$wt|$fakebin|$log|$id|$proj"
}

spawn() { # <case-record> [spawn args...]
  local rec=$1 home wt fakebin log id proj
  shift
  IFS='|' read -r home wt fakebin log id proj <<EOF
$rec
EOF
  : > "$log"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$log" \
    FM_FAKE_MUSE_EXECUTABLE="$fakebin/muse" \
    FM_FAKE_WORKER_META_KEY=present META_API_KEY=evidence-key \
    XDG_CONFIG_HOME="$home/xdgconfig" XDG_DATA_HOME="$home/xdgdata" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "$@" --mode no-mistakes --yolo off 2>&1
}

show_launch() { # <case-record>
  local rec=$1 home wt fakebin log id proj
  IFS='|' read -r home wt fakebin log id proj <<EOF
$rec
EOF
  printf '\n  launch command sent to the pane:\n'
  sed 's/^/    /' "$log"
  printf '\n  recorded task metadata:\n'
  grep -E '^(harness|model|effort)=' "$home/state/$id.meta" | sed 's/^/    /'
}

# ---------------------------------------------------------------------------
section "1. fm-spawn accepted effort vocabulary (operator-visible refusal)"
rec=$(make_case vocab codex)
step "fm-spawn.sh task-vocab <project> --model gpt-5.6-sol --effort turbo"
spawn "$rec" --model gpt-5.6-sol --effort turbo
printf '  exit status: %s\n' "$?"

# ---------------------------------------------------------------------------
section "2. codex + ultra: emitted as -c model_reasoning_effort=\"ultra\""
rec=$(make_case codex-ultra codex)
step "fm-spawn.sh task-codex-ultra <project> --model gpt-5.6-sol --effort ultra"
spawn "$rec" --model gpt-5.6-sol --effort ultra
show_launch "$rec"

# ---------------------------------------------------------------------------
section "2b. the gpt-5.6-sol pairing is documentation, not a code gate"
rec=$(make_case codex-ultra-nonsol codex)
step "fm-spawn.sh task-codex-ultra-nonsol <project> --model gpt-5.5 --effort ultra"
spawn "$rec" --model gpt-5.5 --effort ultra
show_launch "$rec"
printf '\n  (firstmate does not refuse the pairing; codex itself rejects an invalid\n   model/effort combination at launch)\n'

# ---------------------------------------------------------------------------
section "3. claude + ultra: recorded in metadata, omitted from the launch"
rec=$(make_case claude-ultra claude)
step "fm-spawn.sh task-claude-ultra <project> --model sonnet --effort ultra"
spawn "$rec" --model sonnet --effort ultra
show_launch "$rec"

# ---------------------------------------------------------------------------
section "4. muse: shared max maps to muse-native ultra; Codex-only ultra does not"
rec=$(make_case muse-max muse)
step "fm-spawn.sh task-muse-max <project> --effort max"
spawn "$rec" --effort max
show_launch "$rec"

rec=$(make_case muse-ultra muse)
step "fm-spawn.sh task-muse-ultra <project> --effort ultra"
spawn "$rec" --effort ultra
show_launch "$rec"

# ---------------------------------------------------------------------------
section "5. bootstrap crew-dispatch validation for config/crew-dispatch.json"

make_bootstrap_fakebin() {
  local dir=$1 fakebin real_jq
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi gh
  for tool in lavish-axi gh-axi quota-axi; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf '9.9.9\n'
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '0.2.4\n'; exit 0; fi
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --body-file <path>' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
fi
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
fi
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf '%s\n' 'no-mistakes version v9.9.9 (fake) 2026-06-27T00:02:18Z'
exit 0
SH
  chmod +x "$fakebin/tasks-axi" "$fakebin/treehouse" "$fakebin/no-mistakes"
  real_jq=$(command -v jq)
  ln -sf "$real_jq" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

dispatch_case() { # <label> <json>
  local label=$1 json=$2 dir fakebin out
  dir="$CASES/dispatch-$label"
  mkdir -p "$dir/home/config"
  printf 'manual\n' > "$dir/home/config/backlog-backend"
  printf '%s\n' "$json" > "$dir/home/config/crew-dispatch.json"
  git -C "$dir/home" init -q 2>/dev/null || true
  fakebin=$(make_bootstrap_fakebin "$dir/fake")
  step "cat config/crew-dispatch.json && fm-bootstrap.sh   # $label"
  printf '  %s\n' "$json"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  if [ -z "$out" ]; then
    printf '  bootstrap output: (silent - profile accepted)\n'
  else
    printf '%s\n' "$out" | sed 's/^/  /'
  fi
}

dispatch_case codex-ultra '{"rules":[{"when":"ultra coding","use":{"harness":"codex","model":"gpt-5.6-sol","effort":"ultra"}}]}'
dispatch_case claude-ultra '{"rules":[{"when":"ultra coding","use":{"harness":"claude","model":"claude-opus-4-6","effort":"ultra"}}]}'
dispatch_case muse-ultra '{"rules":[{"when":"muse ultra","use":{"harness":"muse","effort":"ultra"}}]}'
dispatch_case pi-ultra '{"rules":[{"when":"pi ultra","use":{"harness":"pi","model":"anthropic/claude-opus-5","effort":"ultra"}}]}'
dispatch_case grok-ultra '{"rules":[{"when":"grok ultra","use":{"harness":"grok","model":"grok-4","effort":"ultra"}}]}'
dispatch_case codex-xhigh '{"rules":[{"when":"deep feature","use":{"harness":"codex","model":"gpt-5.6","effort":"xhigh"}}]}'
dispatch_case codex-max '{"rules":[{"when":"big feature","use":{"harness":"codex","model":"gpt-5","effort":"max"}}]}'

printf '\n'
