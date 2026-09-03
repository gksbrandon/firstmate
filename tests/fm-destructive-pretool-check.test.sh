#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the destructive-command PreToolUse seatbelt
# (docs/destructive-guard.md).
#
# bin/fm-destructive-command-policy.mjs is the single owner of the deny/allow
# decision; it reuses the shell classifier owned by bin/fm-arm-command-policy.mjs.
# bin/fm-destructive-pretool-check.sh is the stable transport: it honours the
# escape hatch, scopes the guard to a firstmate checkout, and drives all harness
# entry forms. This suite proves the decision matrix (including both 2026-08-30
# incident commands verbatim, the branch-restoring recovery push, and the prose
# near-misses a substring guard gets wrong), the directory gate, the escape
# hatch, the checkout scoping, the harness output shaping, the fail-open
# transport behavior, the prefilter fast path, the end-to-end worktree-removal
# regression, and the per-harness wiring. No harness is spawned.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-destructive-pretool-check)

install_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-destructive-pretool-check.sh" "$dir/bin/fm-destructive-pretool-check.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-destructive-command-policy.mjs" "$dir/bin/fm-destructive-command-policy.mjs"
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  chmod +x "$dir/bin/fm-destructive-pretool-check.sh" "$dir/bin/fm-destructive-command-policy.mjs"
}

# A firstmate checkout: AGENTS.md plus bin/ carrying the transport and both
# policy files. Unlike the cd-guard this needs no plain-checkout shape, because
# the guard deliberately fires in task worktrees too.
make_checkout_fixture() {
  local dir=$1
  mkdir -p "$dir"
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

CHECKOUT=$(make_checkout_fixture "$TMP_ROOT/checkout")
CHECK="$CHECKOUT/bin/fm-destructive-pretool-check.sh"
POLICY="$ROOT/bin/fm-destructive-command-policy.mjs"

# Working directories the gated git class keys off. The test resolves them
# through the same lexical rule the policy uses: a .treehouse component is a
# pool worktree, a component after `projects` is inside a project clone.
NEUTRAL_CWD="$TMP_ROOT/neutral"
POOL_CWD="$TMP_ROOT/.treehouse/pool-9/1/repo"
CLONE_CWD="$TMP_ROOT/home/projects/FAS"
# The fleet home: the directory the primary runs in, holding the clones and the
# pool but matching neither path shape itself. It is where a gate on those two
# shapes would have allowed the removal that contains everything it protects.
HOME_CWD="$TMP_ROOT/home"
mkdir -p "$NEUTRAL_CWD" "$POOL_CWD" "$CLONE_CWD" "$HOME_CWD"

# --- full cross-harness acceptance matrix ----------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_CWD=()
MATRIX_COMMANDS=()
MATRIX_CODES=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_CWD+=("$3")
  MATRIX_CODES+=("$4")
  MATRIX_COMMANDS+=("$5")
}

# The two commands that caused the 2026-08-30 incidents, verbatim in shape.
matrix_case I01 deny neutral destructive-rm 'rm -rf /Users/captain/.treehouse/FAS-e09566/1/FAS/.git'
matrix_case I02 deny neutral destructive-push 'git -C projects/FAS push origin --delete rtc/s7-candidate'

# DENY: recursive+force removal of a pool worktree, a .git path, or a clone.
matrix_case R01 deny neutral destructive-rm 'rm -fr .treehouse/pool/1/repo'
matrix_case R02 deny neutral destructive-rm 'rm -r -f projects/FAS'
matrix_case R03 deny neutral destructive-rm 'rm --recursive --force projects/FAS/build'
matrix_case R04 deny neutral destructive-rm 'rm -rf .git'
matrix_case R05 deny neutral destructive-rm 'rm -rf -- projects/FAS'
matrix_case R06 deny neutral destructive-rm 'sudo rm -rf /Users/x/.treehouse/a'
matrix_case R07 deny neutral destructive-rm 'rm -rf "$WORKTREE/.git"'
matrix_case R08 deny neutral destructive-rm 'echo staged && rm -rf projects/FAS'
matrix_case R09 deny neutral destructive-rm 'rm -rf projects'
matrix_case R10 deny neutral destructive-rm 'rm -Rf projects/FAS'
# A .git component anywhere, not only last: the shell leaves the glob unexpanded
# in the hook payload, and removing everything under .git detaches the checkout
# exactly like removing .git itself.
matrix_case R11 deny neutral destructive-rm 'rm -rf .git/*'
matrix_case R12 deny neutral destructive-rm 'rm -rf "$WORKTREE/.git/objects"'
# An operand that names no fleet path but resolves to the directory the command
# runs in, or an ancestor of it, when that directory is a clone or pool.
matrix_case R13 deny pool destructive-rm 'rm -rf .'
matrix_case R14 deny clone destructive-rm 'rm -rf ..'
matrix_case R15 deny pool destructive-rm 'rm -rf ./'
# The filesystem root is an ancestor like any other. It is the case a naive
# `${resolved}${path.sep}` prefix silently exempts, by building `//`.
matrix_case R16 deny pool destructive-rm 'rm -rf /'
matrix_case R17 deny clone destructive-rm 'rm -rf /'
# The same rule in the fleet home. Denying `rm -rf projects` while allowing the
# `rm -rf .` that contains it would block the narrow target and permit the wide
# one, so the rule is not gated on the pool and clone path shapes.
matrix_case R18 deny home destructive-rm 'rm -rf .'
matrix_case R19 deny home destructive-rm 'rm -rf ..'
matrix_case R20 deny home destructive-rm 'rm -rf projects'
# A bare trailing glob names the whole directory; the hook sees it unexpanded.
matrix_case R21 deny home destructive-rm 'rm -rf *'
matrix_case R22 deny pool destructive-rm 'rm -rf ./*'
matrix_case R23 deny neutral destructive-rm 'rm -rf .'
# The explicit-path tests read the operand's own bytes, so a preceding cd does
# not stand them down the way it stands down the self-or-ancestor test below.
matrix_case R24 deny home destructive-rm 'cd build && rm -rf projects/FAS'
matrix_case R25 deny home destructive-rm 'cd /tmp/scratch && rm -rf "$WORKTREE/.git"'

# ALLOW: a removal that is not both recursive and forced, or not a fleet path.
matrix_case r01 allow neutral '' 'rm -rf build'
matrix_case r02 allow neutral '' 'rm -rf node_modules'
matrix_case r03 allow neutral '' 'rm -f projects/FAS/stale.txt'
matrix_case r04 allow neutral '' 'rm -r projects/FAS/tmp'
matrix_case r05 allow neutral '' 'rm -rf my-projects/build'
matrix_case r06 allow neutral '' 'rm -rf /tmp/scratch.gitignore'
matrix_case r07 allow neutral '' 'rm -rf "$TMP"'
# Self-or-ancestor resolution must stay that narrow: an ordinary build artifact
# inside a pool worktree or a clone is still removable.
matrix_case r08 allow pool '' 'rm -rf build'
matrix_case r09 allow clone '' 'rm -rf node_modules/.cache'
# An empty word names no path, and resolving it would read as the current
# directory; the real rm removes nothing here.
matrix_case r10 allow pool '' 'rm -rf ""'
matrix_case r11 allow clone '' 'rm -rf ""'
# The widened rule must stay self-or-ancestor: ordinary scoped removals from the
# fleet home, and a glob scoped to a subdirectory, are untouched.
matrix_case r12 allow home '' 'rm -rf build'
matrix_case r13 allow home '' 'rm -rf node_modules'
matrix_case r14 allow home '' 'rm -rf build/*'
matrix_case r15 allow home '' 'rm -rf .cache/http/*'
matrix_case r16 allow home '' 'rm -rf dist/assets'
# A cd earlier in the list moves the removal somewhere the hook never saw, so
# resolving the operand against the hook's directory would misattribute it.
# These three shapes are the regression: each denied while the rule was
# unconditional, and each removes something the guard has no claim over.
matrix_case r17 allow home '' 'cd build && rm -rf *'
matrix_case r18 allow home '' 'cd /tmp/scratch && rm -rf .'
matrix_case r19 allow home '' 'mkdir -p out && cd out && rm -rf *'
matrix_case r20 allow pool '' 'cd build && rm -rf *'
matrix_case r21 allow home '' 'pushd build && rm -rf * && popd'

# DENY: a push that deletes or force-updates a remote ref, against any remote.
matrix_case P01 deny neutral destructive-push 'git push origin --delete rtc/s7-candidate'
matrix_case P02 deny neutral destructive-push 'git push origin :refs/heads/colleague-branch'
matrix_case P03 deny neutral destructive-push 'git push --force origin main'
matrix_case P04 deny neutral destructive-push 'git push -f origin main'
matrix_case P05 deny neutral destructive-push 'git push origin +refs/heads/x:refs/heads/x'
matrix_case P06 deny neutral destructive-push 'git push --force-with-lease origin feature'
matrix_case P07 deny neutral destructive-push 'git push -d origin feature'
matrix_case P08 deny neutral destructive-push 'git push --del origin feature'
matrix_case P09 deny neutral destructive-push 'git push upstream --delete feature'
matrix_case P10 deny pool destructive-push 'git push --delete origin feature'
matrix_case P11 deny neutral destructive-push 'git push origin :'
# A mirror push removes every remote ref with no local counterpart and a prune
# push removes the remote refs outside the refspec: the incident-2 outcome
# reached by a sync or cleanup flag rather than by an explicit delete.
matrix_case P12 deny neutral destructive-push 'git push --mirror origin'
matrix_case P13 deny neutral destructive-push 'git push --prune origin "refs/heads/*:refs/heads/*"'
matrix_case P14 deny neutral destructive-push 'git -C projects/FAS push --mirror backup'
matrix_case P15 deny pool destructive-push 'git push --prune upstream main'

# ALLOW: ordinary pushes. p01 is the exact recovery shape used to restore the
# deleted branch, so it must never be blocked.
matrix_case p01 allow neutral '' 'git push origin 66ad57f52d:refs/heads/rtc/s7-candidate'
matrix_case p02 allow neutral '' 'git push origin HEAD:refs/heads/feature'
matrix_case p03 allow neutral '' 'git push -u origin feature'
matrix_case p04 allow neutral '' 'git push'
matrix_case p05 allow neutral '' 'git push origin main'
matrix_case p06 allow neutral '' 'git push --set-upstream origin feature'
matrix_case p07 allow neutral '' 'git push --follow-tags origin main'
matrix_case p08 allow pool '' 'git push origin fm/task-branch'
# Near-misses for the mirror and prune shapes. A fetch prunes only local
# remote-tracking refs, and --porcelain is not an abbreviation of --prune.
matrix_case p09 allow neutral '' 'git fetch --prune origin'
matrix_case p10 allow neutral '' 'git fetch --prune --all'
matrix_case p11 allow neutral '' 'git push --porcelain origin main'
matrix_case p12 allow neutral '' 'git remote prune origin'

# DENY: history destruction inside a project clone or a pool worktree.
matrix_case H01 deny clone destructive-git-history 'git reset --hard HEAD~1'
matrix_case H02 deny pool destructive-git-history 'git reset --hard'
matrix_case H03 deny clone destructive-git-history 'git clean -fd'
matrix_case H04 deny pool destructive-git-history 'git branch -D feature'
matrix_case H05 deny clone destructive-git-history 'git filter-branch --tree-filter true HEAD'
matrix_case H06 deny pool destructive-git-history 'git branch --delete --force feature'
matrix_case H07 deny neutral destructive-git-history 'git -C projects/FAS reset --hard'
matrix_case H08 deny neutral destructive-git-history 'git -C projects/FAS clean -fdx'
matrix_case H09 deny pool destructive-git-history 'git branch -fd feature'

# ALLOW: the same verbs outside a clone or pool, and their non-destroying forms.
matrix_case h01 allow neutral '' 'git reset --hard'
matrix_case h02 allow neutral '' 'git clean -fd'
matrix_case h03 allow clone '' 'git reset --soft HEAD~1'
matrix_case h04 allow clone '' 'git reset'
matrix_case h05 allow clone '' 'git branch -d merged-feature'
matrix_case h06 allow clone '' 'git status'
matrix_case h07 allow pool '' 'git branch --list'
# A force flag that creates or moves a branch is not a force-DELETE.
matrix_case h08 allow clone '' 'git branch -f newbranch origin/main'
matrix_case h09 allow clone '' 'git branch --force newbranch origin/main'

# DENY: the same classes reached through a loop, a conditional, or `time`. Bulk
# stale-branch cleanup in a loop is the shape the second incident takes at scale,
# so a reserved word in front of the body must not hide the command it runs.
matrix_case K01 deny neutral destructive-push 'for b in one two; do git push origin --delete $b; done'
matrix_case K02 deny neutral destructive-push 'if git rev-parse HEAD; then git push origin --delete rtc/s7-candidate; fi'
matrix_case K03 deny neutral destructive-push 'time git push origin --delete rtc/s7-candidate'
matrix_case K04 deny neutral destructive-rm 'for f in a b; do rm -rf projects/FAS; done'
matrix_case K05 deny clone destructive-git-history 'while read -r b; do git branch -D "$b"; done'
matrix_case K06 deny pool destructive-git-history 'if [ -d x ]; then true; else git clean -fdx; fi'
matrix_case K07 deny neutral destructive-rm 'until false; do rm -rf .treehouse/pool/1/repo; done'

# ALLOW: the same compounds when the body is not destructive. Stripping a leading
# reserved word must reach the real command, not turn every loop into a match.
matrix_case k01 allow neutral '' 'for f in one two; do echo "$f"; done'
matrix_case k02 allow clone '' 'for b in $(git branch --list); do echo "$b"; done'
matrix_case k03 allow neutral '' 'for d in projects/*; do git -C "$d" status; done'
matrix_case k04 allow clone '' 'time git status'
# A case arm is the documented limit: stripping `case` leaves the discriminant in
# command position rather than exposing the arm body (Accepted non-goals).
matrix_case k05 allow neutral '' 'case $x in a) git push origin --delete b ;; esac'
matrix_case k06 allow neutral '' 'case $x in a) rm -rf projects/FAS ;; esac'

# ALLOW: the command text as DATA. A guard that greps prose blocks all of these,
# which is the false positive this structural classifier exists to avoid.
matrix_case D01 allow neutral '' 'grep -rn "rm -rf" bin/'
matrix_case D02 allow neutral '' 'grep -rn "git push --delete" docs/'
matrix_case D03 allow neutral '' 'echo "git push origin --delete branch"'
matrix_case D04 allow neutral '' "printf '%s\\n' 'rm -rf projects/FAS'"
matrix_case D05 allow neutral '' '# rm -rf projects/FAS'
matrix_case D06 allow neutral '' 'git commit -m "deny rm -rf and git push --delete"'
matrix_case D07 allow clone '' 'git log --grep="reset --hard"'
matrix_case D08 allow neutral '' 'git show HEAD:bin/fm-destructive-command-policy.mjs'
matrix_case D09 allow neutral '' $'cat <<EOF\nrm -rf projects/FAS\ngit push --delete origin x\nEOF'
matrix_case D10 allow neutral '' 'tasks-axi add "guard git push --force in the seatbelt"'
matrix_case D11 allow neutral '' 'grep -rn "git push --mirror" docs/'
matrix_case D12 allow neutral '' 'git commit -m "deny a mirror push and a prune push"'
matrix_case D13 allow home '' 'echo "rm -rf * would take the whole home"'

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-destructive-matrix.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")

cwd_for_kind() {
  case "$1" in
    neutral) printf '%s\n' "$NEUTRAL_CWD" ;;
    pool) printf '%s\n' "$POOL_CWD" ;;
    clone) printf '%s\n' "$CLONE_CWD" ;;
    home) printf '%s\n' "$HOME_CWD" ;;
    *) fail "unknown matrix cwd kind: $1" ;;
  esac
}

run_matrix_entry() {
  local id=$1 expected=$2 cwd_kind=$3 code=$4 entry=$5 cmd=$6 payload out_file err_file rc dir
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"
  dir=$(cwd_for_kind "$cwd_kind")
  rc=0

  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      (cd "$dir" && printf '%s' "$payload" | "$CHECK") >"$out_file" 2>"$err_file" || rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      (cd "$dir" && printf '%s' "$payload" | "$CHECK" --claude) >"$out_file" 2>"$err_file" || rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      (cd "$dir" && printf '%s' "$payload" | "$CHECK") >"$out_file" 2>"$err_file" || rc=$?
      ;;
    opencode|pi)
      (cd "$dir" && "$CHECK" --command "$cmd") >"$out_file" 2>"$err_file" || rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e --arg code "[$code]" '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | contains($code))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry the $code reason code on stderr: $(cat "$err_file")"
  jq -e '.systemMessage | contains("FM_ALLOW_DESTRUCTIVE=1")' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must name the escape hatch: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  elif [ "$entry" = grok ]; then
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude grok opencode pi; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "${MATRIX_CWD[$i]}" \
        "${MATRIX_CODES[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
  done
  pass "destructive-guard acceptance matrix: ${#MATRIX_IDS[@]} cases x 5 harness entry forms, deny/allow all correct"
}

# --- the ancestor rule reaches every ancestor, root included ----------------

# A `..` chain deep enough to bottom out at the filesystem root is the shape a
# fixed matrix string cannot express, because the pool fixture's depth varies
# with the temp root. It is also the shape rm itself does not refuse: BSD rm's
# own root check keys on the literal operand, not on where the chain lands.
test_ancestor_removal_reaches_the_filesystem_root() {
  local deep i out rc
  deep=""
  for ((i = 0; i < 40; i++)); do deep="../$deep"; done
  rc=0
  out=$( (cd "$POOL_CWD" && "$CHECK" --claude --command "rm -rf $deep") 2>&1) || rc=$?
  expect_code 2 "$rc" "a .. chain that bottoms out at / is still an ancestor of the pool worktree"
  assert_contains "$out" '[destructive-rm]' "root-ancestor deny must carry its reason code"
  rc=0
  out=$( (cd "$CLONE_CWD" && "$CHECK" --claude --command "rm -rf $deep") 2>&1) || rc=$?
  expect_code 2 "$rc" "the same chain from inside a clone must deny too"
  # The rule must not have widened: a sibling of an ancestor is not an ancestor.
  rc=0
  out=$( (cd "$POOL_CWD" && "$CHECK" --claude --command 'rm -rf ../sibling') 2>&1) || rc=$?
  expect_code 0 "$rc" "a sibling directory is not an ancestor and must stay allowed"
  [ -z "$out" ] || fail "sibling removal produced output: $out"
  pass "destructive-guard: the self-or-ancestor removal rule includes the filesystem root and stops at ancestors"
}

# --- the directory gate is what separates the gated git class ---------------

test_gated_class_turns_only_on_the_effective_directory() {
  local out rc
  for dir in "$POOL_CWD" "$CLONE_CWD"; do
    rc=0
    out=$( (cd "$dir" && "$CHECK" --claude --command 'git clean -fdx') 2>&1) || rc=$?
    expect_code 2 "$rc" "git clean must be denied inside $dir"
    assert_contains "$out" '[destructive-git-history]' "gated deny must carry its reason code"
  done
  rc=0
  out=$( (cd "$NEUTRAL_CWD" && "$CHECK" --claude --command 'git clean -fdx') 2>&1) || rc=$?
  expect_code 0 "$rc" "git clean outside a clone or pool is out of this guard's scope"
  [ -z "$out" ] || fail "allowed gated command produced output: $out"
  pass "destructive-guard: the gated git class turns on the effective directory, not the verb alone"
}

test_dash_c_target_overrides_the_working_directory() {
  local out rc
  rc=0
  out=$( (cd "$NEUTRAL_CWD" && "$CHECK" --claude --command 'git -C projects/FAS reset --hard') 2>&1) || rc=$?
  expect_code 2 "$rc" "-C into a clone must be gated even from a neutral cwd"
  assert_contains "$out" '[destructive-git-history]' "-C deny must carry its reason code"
  rc=0
  out=$( (cd "$POOL_CWD" && "$CHECK" --claude --command 'git -C /tmp/scratch reset --hard') 2>&1) || rc=$?
  expect_code 0 "$rc" "-C out of the pool must not be gated by the pool cwd it left"
  [ -z "$out" ] || fail "-C escape produced output: $out"
  pass "destructive-guard: -C is the effective directory, exactly as git resolves it"
}

# --- escape hatch ------------------------------------------------------------

test_escape_hatch_releases_only_on_the_exact_value() {
  local out rc value
  rc=0
  out=$( (cd "$NEUTRAL_CWD" && FM_ALLOW_DESTRUCTIVE=1 "$CHECK" --claude --command 'git push origin --delete feature') 2>&1) || rc=$?
  expect_code 0 "$rc" "FM_ALLOW_DESTRUCTIVE=1 must allow a deliberate exception"
  [ -z "$out" ] || fail "escape hatch allow produced output: $out"
  for value in '' 0 yes true 11; do
    rc=0
    out=$( (cd "$NEUTRAL_CWD" && FM_ALLOW_DESTRUCTIVE="$value" "$CHECK" --claude --command 'git push origin --delete feature') 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || fail "FM_ALLOW_DESTRUCTIVE='$value' must not release the guard, got exit $rc"
  done
  pass "destructive-guard: the escape hatch releases the guard only on the exact opt-in value"
}

test_deny_message_names_the_escape_hatch() {
  local out rc
  rc=0
  out=$( (cd "$NEUTRAL_CWD" && "$CHECK" --claude --command 'rm -rf projects/FAS') 2>&1) || rc=$?
  expect_code 2 "$rc" "removal of a clone must deny"
  assert_contains "$out" 'FM_ALLOW_DESTRUCTIVE=1' "the deny message must name the escape hatch so it is one setting away"
  pass "destructive-guard: every deny names FM_ALLOW_DESTRUCTIVE=1"
}

# --- checkout scoping --------------------------------------------------------

test_fires_in_a_task_worktree() {
  local base dir out rc
  base="$TMP_ROOT/wt-base"
  dir="$TMP_ROOT/wt-task"
  fm_git_worktree "$base" "$dir" fm/destructive-guard-test-branch
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  rc=0
  out=$( (cd "$dir" && "$dir/bin/fm-destructive-pretool-check.sh" --claude --command 'git push origin --delete feature') 2>&1) || rc=$?
  expect_code 2 "$rc" "the destructive guard must fire in a task worktree, unlike the cd-guard"
  assert_contains "$out" '[destructive-push]' "task-worktree deny must carry the reason code"
  pass "destructive-guard: fires in a crewmate/scout task worktree (a colleague's branch is not a primary-only hazard)"
}

test_inert_when_not_firstmate_repo() {
  local dir out rc
  dir="$TMP_ROOT/not-firstmate"
  mkdir -p "$dir"
  install_scripts "$dir"   # bin/ present but no AGENTS.md
  rc=0
  out=$( (cd "$dir" && "$dir/bin/fm-destructive-pretool-check.sh" --claude --command 'rm -rf projects/FAS') 2>&1) || rc=$?
  expect_code 0 "$rc" "guard must be inert without AGENTS.md (not a firstmate checkout)"
  [ -z "$out" ] || fail "guard produced output outside a firstmate checkout: $out"
  pass "destructive-guard: inert in a non-firstmate repo"
}

# --- cursor rendering --------------------------------------------------------

test_cursor_returns_its_own_decision_object() {
  local out rc
  rc=0
  out=$( (cd "$NEUTRAL_CWD" && "$CHECK" --cursor --command 'git push origin --delete feature') 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "Cursor reads the returned object, so a deny still exits 0"
  printf '%s' "$out" | jq -e '.permission == "deny" and (.user_message | contains("[destructive-push]"))' >/dev/null 2>&1 \
    || fail "cursor deny must return its own decision object: $out"
  pass "destructive-guard: --cursor renders Cursor's own deny object on stdout"
}

# Cursor also loads the tracked Claude settings, so the same event arrives twice.
# Only Cursor's own registration passes --cursor; the Claude-settings duplicate
# must allow without re-classifying rather than deny the command a second time.
test_cursor_payload_without_cursor_flag_is_the_duplicate() {
  local payload out rc=0
  payload=$(jq -cn '{cursor_version:"1.0.0",tool_name:"Shell",tool_input:{command:"git push origin --delete feature"}}')
  out=$( (cd "$NEUTRAL_CWD" && printf '%s' "$payload" | "$CHECK" --claude) 2>&1) || rc=$?
  expect_code 0 "$rc" "a Cursor payload without --cursor is the Claude-settings duplicate and must allow"
  [ -z "$out" ] || fail "the duplicate registration produced output: $out"
  rc=0
  out=$( (cd "$NEUTRAL_CWD" && printf '%s' "$payload" | "$CHECK" --cursor) 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "Cursor's own registration returns its decision object at exit 0"
  printf '%s' "$out" | jq -e '.permission == "deny"' >/dev/null 2>&1 \
    || fail "Cursor's own registration must still deny the same payload: $out"
  pass "destructive-guard: only Cursor's own registration classifies a Cursor payload"
}

# --- end-to-end incident regression -----------------------------------------

test_e2e_worktree_removal_regression() {
  local sandbox base worktree out rc
  sandbox="$TMP_ROOT/e2e"
  base="$sandbox/base"
  worktree="$sandbox/.treehouse/pool-1/1/repo"
  mkdir -p "$sandbox"
  fm_git_worktree "$base" "$worktree" fm/e2e-destructive-branch

  # Baseline: removing the worktree's .git link file is exactly what happened on
  # 2026-08-30, and it detaches the checkout from its repository.
  [ -e "$worktree/.git" ] || fail "baseline: the task worktree has no .git link to destroy"
  rm -rf "$worktree/.git"
  git -C "$worktree" rev-parse --git-dir >/dev/null 2>&1 \
    && fail "baseline: the worktree still resolves its git dir, the incident did not reproduce"

  # With the guard, that exact command is denied before it can run.
  rc=0
  out=$( (cd "$NEUTRAL_CWD" && "$CHECK" --claude --command "rm -rf $worktree/.git") 2>&1) || rc=$?
  expect_code 2 "$rc" "guard must deny the exact removal that detached the worktree"
  assert_contains "$out" '[destructive-rm]' "incident block must carry the reason code"
  pass "destructive-guard: reproduces the worktree detachment and denies the exact command that causes it"
}

# --- fail-open transport behavior -------------------------------------------

test_fail_open_empty_stdin() {
  local out rc=0
  out=$("$CHECK" < /dev/null 2>&1) || rc=$?
  expect_code 0 "$rc" "transport must exit 0 on empty stdin"
  [ -z "$out" ] || fail "transport produced output on empty stdin: $out"
  pass "destructive-guard: fails open on empty stdin"
}

test_fail_open_unparseable_json() {
  local out rc=0
  out=$(printf 'not json at all' | "$CHECK" 2>&1) || rc=$?
  expect_code 0 "$rc" "transport must exit 0 on unparseable stdin JSON"
  [ -z "$out" ] || fail "transport produced output on unparseable JSON: $out"
  pass "destructive-guard: fails open on unparseable stdin JSON"
}

test_fail_open_missing_node() {
  local fakebin tool tool_path out rc=0
  fakebin=$(fm_fakebin "$TMP_ROOT/nonode")
  for tool in bash sh git dirname cat printf sed tr jq pwd; do
    tool_path=$(command -v "$tool") || continue
    ln -sf "$tool_path" "$fakebin/$tool"
  done
  # node deliberately absent from this PATH.
  out=$( (cd "$NEUTRAL_CWD" && PATH="$fakebin" "$CHECK" --command 'rm -rf projects/FAS') 2>&1) || rc=$?
  expect_code 0 "$rc" "transport must fail open when node is unavailable"
  [ -z "$out" ] || fail "transport produced output without node: $out"
  pass "destructive-guard: fails open (never blocks) when node is missing"
}

test_fail_open_missing_jq_on_stdin() {
  local fakebin tool tool_path out rc=0
  fakebin=$(fm_fakebin "$TMP_ROOT/nojq")
  for tool in bash sh git dirname cat printf sed tr node pwd; do
    tool_path=$(command -v "$tool") || continue
    ln -sf "$tool_path" "$fakebin/$tool"
  done
  # jq deliberately absent: the stdin transport cannot extract the command.
  out=$(printf '{"tool_input":{"command":"rm -rf projects/FAS"}}' | (cd "$NEUTRAL_CWD" && PATH="$fakebin" "$CHECK") 2>&1) || rc=$?
  expect_code 0 "$rc" "stdin transport must fail open when jq is unavailable"
  [ -z "$out" ] || fail "transport produced output without jq on the stdin path: $out"
  pass "destructive-guard: fails open on the stdin path when jq is missing"
}

# --- prefilter fast path -----------------------------------------------------

test_prefilter_skips_node_without_rm_or_git_substring() {
  local dir fakebin marker tool tool_path out rc=0
  dir="$TMP_ROOT/prefilter"
  make_checkout_fixture "$dir" >/dev/null
  fakebin=$(fm_fakebin "$TMP_ROOT/prefilter-fake")
  marker="$TMP_ROOT/prefilter-node-called"
  for tool in bash sh dirname cat printf sed tr jq pwd; do
    tool_path=$(command -v "$tool") || continue
    ln -sf "$tool_path" "$fakebin/$tool"
  done
  cat > "$fakebin/node" <<EOF
#!/usr/bin/env bash
: > "$marker"
exit 0
EOF
  chmod +x "$fakebin/node"
  out=$( (cd "$NEUTRAL_CWD" && PATH="$fakebin" "$dir/bin/fm-destructive-pretool-check.sh" --command 'ls -la') 2>&1) || rc=$?
  expect_code 0 "$rc" "prefilter must fast-allow a command with no rm or git substring"
  [ -z "$out" ] || fail "prefilter fast-allow produced output: $out"
  [ ! -e "$marker" ] || fail "prefilter fast-allow still invoked the node policy owner"
  pass "destructive-guard: prefilter fast-allows (skips node) when no rm or git substring is present"
}

# --- policy CLI contract -----------------------------------------------------

test_policy_cli_direct() {
  [ "$(node "$POLICY" --command 'rm -rf projects/FAS' --cwd "$NEUTRAL_CWD" | cut -f1)" = deny ] \
    || fail "policy CLI must deny a recursive forced removal of a clone"
  [ "$(node "$POLICY" --command 'git push origin 66ad57f5:refs/heads/x' --cwd "$NEUTRAL_CWD")" = allow ] \
    || fail "policy CLI must allow the branch-restoring recovery push"
  [ "$(node "$POLICY" --command 'git reset --hard' --cwd "$CLONE_CWD" | cut -f1)" = deny ] \
    || fail "policy CLI must deny a hard reset inside a clone"
  [ "$(node "$POLICY" --command 'git reset --hard' --cwd "$NEUTRAL_CWD")" = allow ] \
    || fail "policy CLI must allow a hard reset outside a clone or pool"
  [ "$(node "$POLICY")" = allow ] \
    || fail "policy CLI must allow when no command is supplied"
  pass "destructive-guard: fm-destructive-command-policy.mjs CLI honors the deny/allow output contract"
}

# --- per-harness wiring ------------------------------------------------------

test_every_documented_harness_is_wired() {
  local checker=fm-destructive-pretool-check.sh
  jq -e --arg c "$checker" '[.hooks.PreToolUse[]?.hooks[]?.command? | select(type == "string" and contains($c))] | length == 1' \
    "$ROOT/.claude/settings.json" >/dev/null 2>&1 \
    || fail "Claude PreToolUse must register $checker exactly once"
  jq -e --arg c "$checker" '[.hooks.PreToolUse[]?.hooks[]?.command? | select(type == "string" and contains($c))] | length == 1' \
    "$ROOT/.codex/hooks.json" >/dev/null 2>&1 \
    || fail "Codex PreToolUse must register $checker exactly once"
  jq -e --arg c "$checker" '[.hooks.PreToolUse[]?.hooks[]?.command? | select(type == "string" and contains($c))] | length == 1' \
    "$ROOT/.grok/hooks/fm-primary-destructive-check.json" >/dev/null 2>&1 \
    || fail "Grok must register $checker in its own PreToolUse hook file"
  jq -e --arg c "$checker" '[.hooks.preToolUse[]? | select(.command? | type == "string" and contains($c))] | length == 1' \
    "$ROOT/.cursor/hooks.json" >/dev/null 2>&1 \
    || fail "Cursor preToolUse must register $checker exactly once"
  pass "destructive-guard: registered in every declarative harness hook the seatbelt family covers"
}

# OpenCode and Pi register this guard in code rather than in a declarative hook
# file, so their wiring is proven by driving the real handler and observing what
# it does with a denied command, not by reading the adapter's source.
test_opencode_plugin_blocks_a_denied_command() {
  local fixture out rc=0
  fixture="$TMP_ROOT/opencode-plugin"
  make_checkout_fixture "$fixture" >/dev/null
  mkdir -p "$fixture/.opencode/plugins"
  cp "$ROOT/.opencode/plugins/fm-primary-destructive-check.js" "$fixture/.opencode/plugins/"
  # directory is deliberately the clone rather than the plugin root, so the run
  # also proves the checker is invoked in the session directory the gated class
  # reads.
  out=$(PLUGIN="$fixture/.opencode/plugins/fm-primary-destructive-check.js" \
    WORKTREE="$fixture" DIRECTORY="$CLONE_CWD" \
    node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
const plugin = await import(pathToFileURL(process.env.PLUGIN).href);
const hooks = await plugin.FmPrimaryDestructiveCheck({
  directory: process.env.DIRECTORY,
  worktree: process.env.WORKTREE,
});
const before = hooks["tool.execute.before"];
const run = async (tool, command) => {
  try {
    await before({ tool }, { args: { command } });
    return "ran";
  } catch (error) {
    return `blocked:${error.message}`;
  }
};
console.log(JSON.stringify({
  incident: await run("bash", "git push origin --delete rtc/s7-candidate"),
  gated: await run("bash", "git clean -fdx"),
  recovery: await run("bash", "git push origin 66ad57f52d:refs/heads/rtc/s7-candidate"),
  unrelated: await run("bash", "ls -la"),
  otherTool: await run("read", "git push origin --delete rtc/s7-candidate"),
}));
JS
  ) || rc=$?
  expect_code 0 "$rc" "the OpenCode plugin harness must run: $out"
  printf '%s' "$out" | jq -e '
    (.incident | startswith("blocked:") and contains("[destructive-push]"))
    and (.gated | startswith("blocked:") and contains("[destructive-git-history]"))
    and .recovery == "ran" and .unrelated == "ran" and .otherTool == "ran"' >/dev/null 2>&1 \
    || fail "OpenCode plugin did not block the denied commands through tool.execute.before: $out"
  pass "destructive-guard: the OpenCode plugin throws from tool.execute.before on a denied bash command"
}

test_pi_extension_blocks_a_denied_command() {
  local fixture out rc=0
  fixture="$TMP_ROOT/pi-extension"
  make_checkout_fixture "$fixture" >/dev/null
  mkdir -p "$fixture/.pi/extensions/lib" "$fixture/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$fixture/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$fixture/.pi/extensions/lib/"
  # The extension spawns the checker without a cwd override, so the process cwd
  # is what the gated class reads; running from the clone is what arms it.
  out=$( (cd "$CLONE_CWD" && EXT="$fixture/.pi/extensions/fm-primary-turnend-guard.ts" \
    FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" \
    node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = { on(event, handler) { handlers.set(event, handler); }, sendMessage() {} };
const extension = await import(pathToFileURL(process.env.EXT).href);
extension.default(pi);
const toolCall = handlers.get("tool_call");
const run = async (toolName, command) => {
  const result = await toolCall({ type: "tool_call", toolName, input: { command } });
  return result?.block ? `blocked:${result.reason}` : "ran";
};
console.log(JSON.stringify({
  incident: await run("bash", "git push origin --delete rtc/s7-candidate"),
  gated: await run("bash", "git clean -fdx"),
  recovery: await run("bash", "git push origin 66ad57f52d:refs/heads/rtc/s7-candidate"),
  unrelated: await run("bash", "ls -la"),
  otherTool: await run("read", "git push origin --delete rtc/s7-candidate"),
}));
JS
  ) ) || rc=$?
  expect_code 0 "$rc" "the Pi extension harness must run: $out"
  printf '%s' "$out" | jq -e '
    (.incident | startswith("blocked:") and contains("[destructive-push]"))
    and (.gated | startswith("blocked:") and contains("[destructive-git-history]"))
    and .recovery == "ran" and .unrelated == "ran" and .otherTool == "ran"' >/dev/null 2>&1 \
    || fail "Pi extension did not block the denied commands from its tool_call handler: $out"
  pass "destructive-guard: the Pi extension returns block=true from tool_call on a denied bash command"
}

test_claude_and_cursor_pass_their_own_rendering_flag() {
  jq -e '[.hooks.PreToolUse[]?.hooks[]?.command? | select(type == "string" and contains("fm-destructive-pretool-check.sh") and contains("--claude"))] | length == 1' \
    "$ROOT/.claude/settings.json" >/dev/null 2>&1 \
    || fail "the Claude registration must pass --claude so its deny keeps stdout empty"
  jq -e '[.hooks.preToolUse[]? | select(.command? | type == "string" and contains("fm-destructive-pretool-check.sh") and contains("--cursor"))] | length == 1' \
    "$ROOT/.cursor/hooks.json" >/dev/null 2>&1 \
    || fail "the Cursor registration must pass --cursor so Cursor receives its own decision object"
  pass "destructive-guard: Claude and Cursor registrations carry their required rendering flags"
}

# Delegated to bin/fm-lint.sh, the single owner of the lint definition including
# --external-sources; invoking the linter directly here would be a second copy of
# that definition.
test_scripts_are_shellcheck_clean() {
  local out
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  out=$("$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-destructive-pretool-check.sh" 2>&1) \
    || fail "bin/fm-destructive-pretool-check.sh is not lint-clean under the pinned definition: $out"
  pass "bin/fm-destructive-pretool-check.sh is clean under bin/fm-lint.sh"
}

test_full_acceptance_matrix
test_ancestor_removal_reaches_the_filesystem_root
test_gated_class_turns_only_on_the_effective_directory
test_dash_c_target_overrides_the_working_directory
test_escape_hatch_releases_only_on_the_exact_value
test_deny_message_names_the_escape_hatch
test_fires_in_a_task_worktree
test_inert_when_not_firstmate_repo
test_cursor_returns_its_own_decision_object
test_cursor_payload_without_cursor_flag_is_the_duplicate
test_e2e_worktree_removal_regression
test_fail_open_empty_stdin
test_fail_open_unparseable_json
test_fail_open_missing_node
test_fail_open_missing_jq_on_stdin
test_prefilter_skips_node_without_rm_or_git_substring
test_policy_cli_direct
test_every_documented_harness_is_wired
test_opencode_plugin_blocks_a_denied_command
test_pi_extension_blocks_a_denied_command
test_claude_and_cursor_pass_their_own_rendering_flag
test_scripts_are_shellcheck_clean
