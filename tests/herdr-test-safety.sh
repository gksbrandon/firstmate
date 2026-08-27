#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

# herdr_forget_inherited_pane: drop the Herdr PANE identity this test process
# inherited from whatever terminal it was started in.
#
# Herdr injects HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID, HERDR_WORKSPACE_ID,
# HERDR_SOCKET_PATH, and HERDR_SESSION into every process it manages a pane for
# (verified 0.7.5 - docs/verification/runtime-backends.md), and a test run from
# inside a Herdr pane inherits all of them. Spawn now treats that pane as the
# authoritative parent to place workers next to, so a leaked identity from the
# developer's own session would follow the test into its isolated lab session
# and be refused there as a cross-session parent - a result that depends on
# where the suite was launched from, not on what it asserts.
#
# Call this before exporting the lab HERDR_SESSION in any suite whose subject is
# the per-home container path. A suite that means to exercise a launcher-bound
# spawn sets HERDR_PANE_ID itself, to a pane it created in its own lab session.
herdr_forget_inherited_pane() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}

# herdr_await_agent_registration: preflight classifier for any guard whose
# subject is herdr's NATIVE agent state.
#
# Some Herdr builds never register an agent for a launched harness at all:
# `agent get` answers error code agent_not_found and `agent list` stays empty
# for the whole window while the harness draws its TUI normally (measured on
# herdr 0.7.5 with Claude Code 2.1.224). Nothing about the version or the api
# schema distinguishes that build, so the capability can only be probed by
# launching the harness and reading the surface, which is why this belongs in a
# guard's setup rather than in a cheap up-front gate.
#
# The distinction it exists to draw: an environment that never registers
# anything cannot exercise the behavior under test and is a skip, while an agent
# that registers and then never becomes ready is the real failure the guard is
# for. A surface that answers neither is also a failure, so an inconclusive read
# never licenses a skip.
#
# Prints exactly one verdict:
#   ready        - a registered agent reported idle, done, or blocked
#   unregistered - nothing ever registered and the surface said agent_not_found
#   stuck        - an agent registered but never reached a ready state
#   unreadable   - nothing registered and the surface answered something else
#
# The command is invoked once per poll and must emit one raw `agent get`
# response. Its streams are merged because herdr answers agent_not_found on
# stderr with a non-zero exit, the same read fm_backend_herdr_pane_agent_state
# makes. FM_HERDR_AGENT_POLL_INTERVAL overrides the one-second spacing.
herdr_await_agent_registration() { # <polls> <agent get command...>
  local polls=$1 interval=${FM_HERDR_AGENT_POLL_INTERVAL:-1}
  local i=0 out status code registered=0 unreadable=0
  shift
  while [ "$i" -lt "$polls" ]; do
    out=$("$@" 2>&1)
    status=$(printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
    code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
    case "$status" in
      idle|done|blocked) printf 'ready'; return 0 ;;
      ?*) registered=1 ;;
      *) [ "$code" = agent_not_found ] || unreadable=1 ;;
    esac
    i=$((i + 1))
    sleep "$interval"
  done
  if [ "$registered" = 1 ]; then
    printf 'stuck'
  elif [ "$unreadable" = 1 ]; then
    printf 'unreadable'
  else
    printf 'unregistered'
  fi
}
