#!/usr/bin/env bash
# tests/fm-remote-secondmate-profile-axes.test.sh - launch-profile axis regressions
# for the REMOTE second mate route, over the deterministic generic SSH boundary.
#
# The local spawn path's coverage lives in tests/fm-secondmate-harness.test.sh
# (capability C, the optional model/effort tokens config/secondmate-harness
# carries) and tests/fm-spawn-dispatch-profile.test.sh. A remote second mate
# never reaches that path: bin/fm-spawn.sh routes it through
# spawn_remote_secondmate, which validates the configured effort, hands it to
# bin/fm-remote-secondmate-control.sh, and that control script re-validates and
# replays it as --model/--effort into the remote host's OWN bin/fm-spawn.sh.
# Both ends must therefore accept the axis, and only the remote end decides
# whether it reaches the launch command.
#
# These assertions drive the real chain - parent fm-spawn -> fm-on -> the real
# remote entrypoint -> fm-remote-secondmate-control -> the remote host's own
# fm-spawn - against a fake herdr CLI, so the launch literal the remote pane
# received is observable.
#
# See docs/remote-secondmates.md for the remote route's maintained contract and
# .agents/skills/harness-adapters/SKILL.md for the per-harness effort flags.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-profile-axes)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
PI_LOG="$TMP_ROOT/remote-pi.log"
TMUX_LOG="$TMP_ROOT/remote-tmux.log"
TMUX_STATE="$TMP_ROOT/remote-tmux.state"
CLAIMS="$TMP_ROOT/claims"
REMOTE_META="$REMOTE_HOME/state/parent-route/ios.meta"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"
trap 'FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true; if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then kill "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" 2>/dev/null || true; fi; rm -rf -- "$TMP_ROOT"' EXIT

# The remote host's tracked code root is this branch, as a real git repository:
# fm-on and the remote entrypoint both require the dispatched command to be
# tracked there, and the remote side runs the real scripts under test.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)

# The remote host runs the Herdr fixture, whose every invocation is logged
# verbatim, so the launch literal the pane received is read back exactly. The
# tmux fixture below only keeps the remote home's own non-second-mate tooling
# resolvable.
cat > "$REMOTE_ROOT/bin/tmux" <<SH
#!/usr/bin/env bash
set -u
log='$TMUX_LOG'
state='$TMUX_STATE'
printf '%s\n' "\$*" >> "\$log"
case "\${1:-}" in
  has-session|new-session|set-window-option) exit 0 ;;
  list-windows)
    [ -f "\$state" ] || exit 0
    name=\$(cut -d'|' -f1 "\$state")
    case "\$*" in *'#{session_name}:#{window_name}'*) printf 'firstmate:%s\n' "\$name" ;; *) printf '%s\n' "\$name" ;; esac
    exit 0
    ;;
  new-window)
    name=; cwd=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in -n) shift; name=\$1 ;; -c) shift; cwd=\$1 ;; esac
      shift
    done
    printf '%s|%s\n' "\$name" "\$cwd" > "\$state"
    printf '@1\n'
    exit 0
    ;;
  display-message)
    case "\$*" in
      *'#{pane_current_path}'*) cut -d'|' -f2- "\$state" ;;
      *'#{pane_current_command}'*) printf 'codex\n' ;;
      *'#{cursor_y}'*) printf '0\n' ;;
      *'#S'*) printf 'firstmate\n' ;;
      *) printf '%%1\n' ;;
    esac
    exit 0
    ;;
  capture-pane) printf '❯\n'; exit 0 ;;
  send-keys) exit 0 ;;
  kill-window) rm -f -- "\$state"; exit 0 ;;
  list-panes) printf 'codex\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/tmux"

# bin/fm-remote-job-lib.sh rebuilds the child PATH from scratch and leads it with
# the remote root's own bin, so this stub shadows any host pi and the suite never
# touches a real Pi install. bin/fm-spawn.sh resolves the harness name on that
# PATH and probes the resolved executable with `--help` before composing
# --tui-mode, so the stub answers exactly that probe and logs every call, which
# is how the pi cases below prove the launch resolved here.
cat > "$REMOTE_ROOT/bin/pi" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> '$PI_LOG'
if [ "\${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode>'
fi
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/pi"
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
# The readiness gate is answered here rather than by the real doctor, which
# would inspect the RUNNER's own account; tests/fm-remote-doctor.test.sh owns
# the doctor's behavior against controlled account fixtures.
if printf '%s' "$4" | base64 --decode 2>/dev/null | tr '\0' '\n' | head -1 | grep -q '^fm-remote-doctor.sh$'; then
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

printf 'tmux\n' > "$PARENT/config/backend"
printf 'codex\n' > "$PARENT/config/crew-harness"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$PARENT/data/backlog.md"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$@"
}

# Relaunch the one seeded route under a fresh profile pin. The previous endpoint
# is retired first, so this is an ordinary relaunch that re-resolves
# config/secondmate-harness rather than a duplicate-launch refusal.
relaunch_with_profile() { # <secondmate-harness line> <failure message>
  printf '%s\n' "$1" > "$PARENT/config/secondmate-harness"
  reset_remote_herdr_fixture "$HERDR_STATE"
  : > "$HERDR_LOG"
  remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate >/dev/null 2>&1 \
    || fail "$2"
}

meta_axis() { sed -n "s/^$2=//p" "$1"; }

# Provision and register the remote route from the captain-facing primary.
FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" --no-projects >/dev/null \
  || fail "remote seed did not provision the route"

# --- codex: the Codex-only ultra tier survives both ends and reaches the pane --
# Before ultra was accepted, the parent's own effort validation refused this
# spawn outright, so the launch below never happened on either host.
relaunch_with_profile 'codex gpt-5.6-sol ultra' \
  "the remote route refused a configured codex+ultra profile"
[ "$(meta_axis "$PARENT/state/ios.meta" harness)" = codex ] \
  || fail "parent metadata did not record the configured remote harness"
[ "$(meta_axis "$PARENT/state/ios.meta" model)" = gpt-5.6-sol ] \
  || fail "parent metadata did not record the configured remote model"
[ "$(meta_axis "$PARENT/state/ios.meta" effort)" = ultra ] \
  || fail "parent metadata did not record the configured remote ultra effort"
[ "$(meta_axis "$REMOTE_META" effort)" = ultra ] \
  || fail "the remote host's own route metadata did not record ultra"
assert_grep "--model 'gpt-5.6-sol'" "$HERDR_LOG" \
  "the remote codex launch did not carry the configured model"
assert_grep "-c 'model_reasoning_effort=\"ultra\"'" "$HERDR_LOG" \
  "the remote codex launch did not emit the ultra reasoning effort"
pass "codex: a configured ultra profile crosses the SSH boundary and reaches the remote pane's launch command"

# --- pi: the shared vocabulary still emits its own top tier --------------------
# The control below proves the pi adapter's effort flag is live on this route,
# so the omission asserted next is specific to ultra rather than a dead flag.
relaunch_with_profile 'pi anthropic/claude-opus-5 max' \
  "the remote route refused a configured pi+max profile"
assert_present "$PI_LOG" \
  "the remote pi launch never probed the stub, so it resolved a host pi instead"
assert_grep '--help' "$PI_LOG" \
  "the remote pi launch did not run the stub's help probe"
[ "$(meta_axis "$PARENT/state/ios.meta" effort)" = max ] \
  || fail "parent metadata did not record the configured remote max effort"
assert_grep "--thinking 'max'" "$HERDR_LOG" \
  "the remote pi launch did not emit its own max thinking level"
pass "pi: the shared max level still reaches the remote pi launch command"

# --- pi: ultra is recorded for traceability and omitted from the launch --------
# Pi has no ultra concept and its ladder ends at max, so the remote end applies
# the documented record-and-omit contract rather than passing a rejected value.
relaunch_with_profile 'pi anthropic/claude-opus-5 ultra' \
  "the remote route refused a configured pi+ultra profile"
[ "$(meta_axis "$PARENT/state/ios.meta" effort)" = ultra ] \
  || fail "the parent dropped an unsupported remote effort instead of recording it"
[ "$(meta_axis "$REMOTE_META" effort)" = ultra ] \
  || fail "the remote host's own route metadata dropped the unsupported effort"
assert_grep "--model 'anthropic/claude-opus-5'" "$HERDR_LOG" \
  "the remote pi launch dropped the model alongside the unsupported effort"
assert_no_grep '--thinking' "$HERDR_LOG" \
  "the remote pi launch passed the Codex-only ultra to an adapter that rejects it"
assert_no_grep 'ultra' "$HERDR_LOG" \
  "the Codex-only ultra token leaked into a non-codex remote launch"
pass "pi: a Codex-only ultra profile is recorded on both hosts and omitted from the remote launch"

# --- an unverified effort is refused before anything is published -------------
printf 'codex gpt-5.6-sol supreme\n' > "$PARENT/config/secondmate-harness"
reset_remote_herdr_fixture "$HERDR_STATE"
: > "$HERDR_LOG"
if out=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1); then
  fail "the remote route launched an unverified configured effort"
fi
assert_contains "$out" 'invalid configured remote secondmate effort' \
  "the remote route did not name the unverified effort it refused"
assert_no_grep 'tab create' "$HERDR_LOG" \
  "an unverified remote effort reached the remote backend"
pass "an unverified configured effort is refused by the parent before any remote launch"

echo "ALL TESTS PASSED"
