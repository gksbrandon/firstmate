#!/usr/bin/env bash
# Live Herdr busy-pane injection guard (live-harness-optin family).
#
# The away daemon may now inject into a supervisor pane that is genuinely
# mid-turn, but only for a harness verified to QUEUE the submitted line as its
# next turn (FM_COMPOSER_BUSY_QUEUEING_HARNESSES, bin/fm-composer-lib.sh). That
# is vendor behavior no stub can prove: a fake pane queues whatever the fake was
# written to queue. This guard drives real Claude Code into a real turn in an
# isolated Herdr lab and requires the daemon's own inject_msg to deliver an
# escalation that Claude then answers once the running turn ends.
#
# It also pins the gate itself: the same busy pane must still defer for a
# harness with no verified queueing behavior, and for any composer that is not
# affirmatively empty.
#
# Run explicitly with FM_HERDR_BUSY_INJECT_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Herdr busy-pane injection" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_HERDR_BUSY_INJECT_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_BUSY_INJECT_LIVE=1 to run the live Herdr busy-pane injection guard"
  exit 0
fi

command -v herdr >/dev/null 2>&1 || fail "FM_HERDR_BUSY_INJECT_LIVE=1 but herdr is not installed"
command -v jq >/dev/null 2>&1 || fail "FM_HERDR_BUSY_INJECT_LIVE=1 but jq is not installed"
command -v claude >/dev/null 2>&1 || fail "FM_HERDR_BUSY_INJECT_LIVE=1 but Claude Code is not installed"
[ -x "$LAB_HELPER" ] || fail "FM_HERDR_BUSY_INJECT_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-busy-inject-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-busy-inject-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
STATE="$TMP_ROOT/state"
mkdir -p "$FAKEBIN" "$STATE"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

export FM_WEDGE_ALARM_EXEC=discard
# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-busyinject --no-focus) \
  || fail "could not create the isolated busy-injection workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

agent_status() { lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty'; }

# Preflight: this guard reads herdr's native agent state, so a Herdr build that
# registers no agent for a launched harness cannot exercise it at all. That is
# an environment limitation, and the family's convention for one is a visible
# gate skip rather than a hard failure. A build that DOES register and then
# never becomes ready is a real failure and still fails loudly here.
case "$(herdr_await_agent_registration 45 lab agent get "$PANE")" in
  ready) ;;
  unregistered)
    echo "skip: $HERDR_VER on this machine publishes no native agent state (agent get answers agent_not_found for a lab pane running Claude Code ($VERSION)), so the busy-pane injection guard cannot be exercised here"
    exit 0
    ;;
  stuck)
    fail "Claude Code ($VERSION) on $HERDR_VER registered an agent in the lab pane that never became idle"
    ;;
  *)
    fail "Claude Code ($VERSION) on $HERDR_VER: the native agent surface in the lab pane was unreadable, so registration could not be established"
    ;;
esac

# A registered idle agent is not yet a drawn composer, and typing before the TUI
# is ready is silently dropped. Wait for the composer the injection path itself
# reads.
i=0
while [ "$i" -lt 45 ]; do
  [ "$(fm_backend_composer_state herdr "$TARGET")" = empty ] && break
  i=$((i + 1))
  sleep 1
done
[ "$i" -lt 45 ] || fail "Claude Code ($VERSION) on $HERDR_VER never drew a readable empty composer in the lab pane"

# Occupy the pane with a turn long enough to inject into. No tools, so the turn
# is pure generation and cannot stall on a permission prompt. The adapter's own
# submit primitive is used rather than a raw send so a swallowed Enter is
# retried instead of leaving this guard vacuous.
occupy=$(fm_backend_send_text_submit herdr "$TARGET" \
  'Write every number from 1 to 600, one per line, each with a short remark. Use no tools.' 5 0.5 0.5)
[ "$occupy" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the occupying prompt was not confirmed submitted (got '$occupy')"

i=0
while [ "$i" -lt 45 ]; do
  [ "$(agent_status)" = working ] && break
  i=$((i + 1))
  sleep 1
done
[ "$i" -lt 45 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER never entered a working turn, so the busy path was never exercised"

export FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET"
afk_enter "$STATE" || fail "could not enter away mode for the guard"

FM_DAEMON_PRIMARY_HARNESS=claude pane_is_busy "$TARGET" herdr \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the occupying turn did not read busy, so this guard proves nothing"
composer=$(fm_backend_composer_state herdr "$TARGET")
[ "$composer" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a working pane's composer read '$composer', not the empty this guard depends on"

# The gate: an unverified harness must still defer on exactly this pane.
if FM_DAEMON_PRIMARY_HARNESS=codex inject_msg "unverified harness must not inject" "$STATE"; then
  fail "a harness with no verified queueing behavior must still defer on a busy pane"
fi

TOKEN="FMBUSYINJECT$$_$RANDOM"
FM_DAEMON_PRIMARY_HARNESS=claude inject_msg "Reply with exactly $TOKEN and nothing else." "$STATE" \
  || fail "Claude Code ($VERSION) on $HERDR_VER: inject_msg could not deliver into a busy pane with an empty composer"
CHECKED=1

# Delivery is not enough: prove Claude QUEUED it and answered once the occupying
# turn ended. The token occurs once in the queued prompt and once in the reply.
landed=0
i=0
while [ "$i" -lt 240 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 400 2>/dev/null || true)
  if [ "$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the escalation was accepted but never answered, so it was swallowed rather than queued"

pass "live Herdr busy-pane injection: Claude Code ($VERSION) on $HERDR_VER queues and answers an escalation injected mid-turn, while an unverified harness still defers, in isolated session $SESSION"

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_BUSY_INJECT_LIVE=1 checked no harness"
