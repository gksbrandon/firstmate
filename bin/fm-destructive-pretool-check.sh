#!/usr/bin/env bash
# Stable PreToolUse transport for the destructive-command policy.
#
# Two incidents on 2026-08-30 motivate this seatbelt: a recursive forced removal
# run against a held candidate worktree's .git link file, and a remote branch
# deletion run against a colleague's open merge request source branch, which the
# forge auto-closed. bin/fm-destructive-command-policy.mjs is the sole owner of
# the deny/allow decision; it reuses the shell classifier owned by
# bin/fm-arm-command-policy.mjs. This wrapper only honours the escape hatch,
# scopes the guard to a firstmate checkout, acquires the harness payload,
# invokes that policy with the current directory, and renders the established
# harness responses. It never executes, sources, evaluates, or expands the
# command. See docs/destructive-guard.md for the complete contract.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-destructive-pretool-check.sh
#   bin/fm-destructive-pretool-check.sh --command '<cmd>'
#
# Stdin mode extracts .toolInput.command for Grok or .tool_input.command for
# Claude, Codex, and Cursor. CLI mode is used by OpenCode and Pi after their
# adapters extract the exact command string. --cursor selects Cursor's own deny
# rendering and marks this invocation as the Cursor registration rather than the
# Claude-settings duplicate Cursor also loads.
#
# Escape hatch: FM_ALLOW_DESTRUCTIVE=1 in the session ENVIRONMENT allows every
# command. Any other value, including empty, 0, yes, and true, stays guarded. It
# is read from the environment rather than the command text so that no tool call
# the agent makes can enable it for the call that follows; a deliberate
# exception means launching the session with it set.
#
# Exit/output contract (identical shape to bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   DENY, --cursor - exit 0 and Cursor's own decision object on stdout. Cursor
#          reads the returned object rather than the exit status.
#   INERT - not a firstmate checkout: exit 0 with no output, exactly like ALLOW.
#           Unlike bin/fm-cd-pretool-check.sh this guard does NOT require a plain
#           primary checkout: destroying a colleague's branch or a held worktree
#           is not a primary-only hazard, and the gated git class is scoped by
#           the pool/clone directory test in the policy instead.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing Node or policy owner, or an invalid policy response.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
# Cursor consumes the stdout decision object.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0
CURSOR_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-destructive-pretool-check.sh [--command <cmd>] [--claude|--cursor]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex/Cursor tool_input.command).
Fires in any firstmate checkout, primary or task worktree; it is a silent no-op
in a non-firstmate repo.
Exits 0 to allow and 2 to deny a recursive forced removal of a pool worktree,
a .git path, a projects/ clone, or the current directory or one of its
ancestors; a push that deletes, force-updates, mirrors or prunes a remote ref;
or a branch force-delete, hard reset, clean, or filter-branch inside a project
clone or pool worktree.
Set FM_ALLOW_DESTRUCTIVE=1 in the environment to allow a deliberate exception.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
With --cursor, a deny is Cursor's own decision object on stdout and exit 0,
because Cursor reads the returned object rather than the exit status.
Malformed transport and an unavailable classifier runtime fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    --cursor)
      CURSOR_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fm-hook-host-lib.sh"
  # Cursor's own registration passes --cursor. Without it a Cursor-delivered
  # payload is the Claude-settings duplicate Cursor also loads, already
  # evaluated by that registration, so this copy allows without re-classifying.
  if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

# Deliberate, unforgeable exception. Only the exact value 1 opens the guard, so
# an empty, 0, yes, or true value stays guarded rather than silently allowing.
[ "${FM_ALLOW_DESTRUCTIVE:-}" = "1" ] && exit 0

# Strict-superset prefilter (transport only; owns zero classification
# semantics). Every deniable command runs `rm` or `git` in command position, so
# a command whose text cannot contain either substring can never be denied.
# Strip syntax bytes that the classifier joins within a shell word before
# testing, so an ordinary quoted or escaped command word still delegates. A
# quoting-decoder marker - a $ immediately followed by a single quote (ANSI-C
# $'...') or a double quote (bash locale $"...") - delegates too, because the
# classifier decodes those and can reconstruct a command word from bytes this
# substring test cannot see. This marker set is COUPLED to the classifier's
# decoder set in bin/fm-arm-command-policy.mjs: adding any new quote/expansion
# form the classifier decodes REQUIRES extending it here in the same change, or
# the prefilter stops being a strict superset.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *rm*|*git*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0

# Scope to a firstmate checkout of any shape. A crewmate or scout task worktree
# is deliberately IN scope here, unlike the cd-guard: the hazards this guard
# covers are not primary-only. Any failure to confirm the checkout is inert
# (exit 0), never a block, so a broken environment never denies a command.
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0

POLICY="$FM_ROOT/bin/fm-destructive-command-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

CWD=$(pwd -P 2>/dev/null) || exit 0

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" --cwd "$CWD" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
if [ "$CURSOR_MODE" -eq 1 ]; then
  printf '{"permission":"deny","user_message":"%s"}\n' "$ESCAPED"
  exit 0
fi
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
