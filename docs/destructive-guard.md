# destructive-command PreToolUse seatbelt

This document is the authoritative human-readable contract for the destructive-command PreToolUse seatbelt.
`bin/fm-destructive-command-policy.mjs` is the single decision owner.
`bin/fm-destructive-pretool-check.sh` is the stable harness transport, checkout scope, and output renderer, and its header owns the exact entry forms, flags, and exit mechanics.
The tracked harness adapters forward command text without classifying it.

It is the fourth member of a family of session guards that share the same cross-harness hook machinery:
the watcher-arm PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, [`arm-pretool-check.md`](arm-pretool-check.md)), the cd-guard (`bin/fm-cd-pretool-check.sh`, [`cd-guard.md`](cd-guard.md)), and the turn-end supervision guard (`bin/fm-turnend-guard.sh`, [`turnend-guard.md`](turnend-guard.md)).
The delegation guard ([`subagent-guard.md`](subagent-guard.md)) uses the same hook surface on tool names rather than command text.

## Why this exists

Two incidents on 2026-08-30, in one session, define the shape of this guard.

- A recursive forced removal was run against a held candidate worktree's `.git` link file, detaching that checkout from its repository.
  The work survived only because the pool shared the project's object store and a full patch had been captured.
- A remote branch deletion was run against a colleague's open merge request source branch, with a cleanup rationale that was not true.
  The forge auto-closed the merge request.

Both were recovered within minutes, and the close and reopen events remain permanently visible in that merge request's activity under the captain's identity.
The durable lesson is that neither command was stopped by anything: both were single tool calls whose damage was irreversible in the social record even after the technical state was restored.

## Purpose and boundary

The guard denies a small, closed set of command SHAPES that destroy a checkout, a remote ref, or unlanded local work.
It classifies shell command positions only; it never evaluates, expands, sources, or runs any byte of the submitted command, and it never touches the filesystem, because the directory gate is pure path arithmetic on the current directory the transport supplies.

The decision is structural, never a substring search over the command text.
This distinction is the guard's main design requirement rather than an implementation detail: an interim local guard written after the incidents matched prose, so it blocked an ordinary `grep` whose search pattern merely named one of these commands, and it would equally block a brief, a commit message, or a heredoc that describes them.
A command word of `rm` or `git` in executed position is what makes a command relevant here; the same bytes in an argument, a quoted string, a comment, or a heredoc body are data and are allowed.

The guard is not a general sandbox and does not judge whether a destructive action is justified.
It converts an irreversible single tool call into a deliberate one.

## Scope: any firstmate checkout

The guard fires in any firstmate checkout, primary or task worktree, and is a silent no-op (exit 0, no output) in a non-firstmate repo.
This is a deliberate difference from the cd-guard, which is inert outside a plain primary checkout.
A stray persistent `cd` only harms the primary's own shell, but deleting a colleague's branch or destroying a held worktree is not a primary-only hazard, and the pool worktree named in the first incident is exactly where a crewmate or scout runs.

The removal and push classes therefore apply in every firstmate checkout, including a crewmate's or a scout's task worktree.

The gated git class is narrower, because it is scoped by the path test below rather than by checkout shape.
It covers a `.treehouse` pool worktree and a `projects/` clone, which is where the fleet keeps work no remote holds.
A task worktree whose path carries neither component - an Orca-managed worktree, or a gate worktree under `.no-mistakes/worktrees/` - is a firstmate checkout where the removal and push classes still fire but `git reset --hard`, `git clean` and `git branch -D` are allowed.
That is the deliberate consequence of a directory gate that is pure path arithmetic and never reads the filesystem, and it is stated here so the gate's reach is not overclaimed.

## Denied classes

Every class below denies only when the command word is the real executed command.

**Recursive forced removal.**
An `rm` carrying both a recursive and a force flag, in any order and whether clustered or separate, with at least one operand naming a `.treehouse` pool path, a path with a `.git` component, or a path with a `projects` component.
Both flags are required, so `rm -r <clone-path>` and `rm -f <clone-path>` are allowed; a removal that is neither recursive nor forced cannot silently destroy a tree.
Path matching is on whole path components, so `my-projects/build` is not a `projects/` path.
An operand that is still a variable is matched on the bytes present, so `rm -rf "$WORKTREE/.git"` is denied on its `.git` component.
The `.git` component is matched anywhere in the path rather than only at the end, so `rm -rf .git/*`, whose final component the shell leaves as a glob, is denied like `rm -rf .git`.

An operand that names no fleet path of its own is resolved against the current directory in exactly one case: when that directory is itself inside a clone or a pool and the operand resolves to it or to an ancestor of it.
`rm -rf .` and `rm -rf ..` from inside a pool worktree destroy that checkout as surely as naming its path, so they are denied there.
Resolution stops at self-or-ancestor on purpose, because resolving every operand would deny an ordinary `rm -rf build` inside a pool worktree too.

**A push that deletes or force-updates a remote ref.**
A `git push` carrying a delete flag, a force flag (both in long or short form, including `--force-with-lease` and git's own unambiguous long-option abbreviations), a refspec beginning with `:`, or a plus-prefixed refspec, against any remote.
The remote name is deliberately not part of the test: the second incident targeted a colleague's branch on an ordinary project remote, and no remote is safe to delete a ref from by accident.

A refspec with a colon INSIDE it is an ordinary update and is allowed.
That matters concretely: `git push origin <sha>:refs/heads/<name>` is the shape that restored the deleted branch, so the guard must never block the recovery from the damage it exists to prevent.

**History destruction inside a clone or pool worktree.**
A `git branch` force-delete, `git reset --hard`, `git clean`, or `git filter-branch`, when the effective directory resolves inside a `projects/` clone or a `.treehouse` pool worktree.
The effective directory is git's own: the `-C` target when one is present, composed in order when several are, and otherwise the current directory.
Outside a clone or pool these four verbs are allowed, which keeps the class pointed at the checkouts that hold unlanded work no remote has.

`git branch -d` without a force flag is allowed, because git itself refuses it for unmerged work.
`git clean` and `git filter-branch` are denied in any form, including a `--dry-run` probe, rather than modelling each tool's own safety flags for a rare case the escape hatch already covers.

**Every class sees through a loop or a conditional.**
A node that begins with a shell reserved word - `do`, `then`, `else`, `time`, and the rest - is classified on the command that word introduces, so `for b in $stale; do git push origin --delete $b; done` is denied exactly like the bare push.
Bulk branch cleanup in a loop is the shape the second incident would most naturally have taken at scale, so leaving it unclassified would have left the guard's own scenario open.
The reserved-word list is `SHELL_KEYWORDS` in `bin/fm-arm-command-policy.mjs`, which is also what that file's own classifier uses to mark a compound node unsupported; both consumers read the one list rather than each deriving it.

## Accepted non-goals

Consistent with the agent-mistake threat model this family shares, the guard does not chase obfuscated bypasses.

- A destructive command reached only through a subshell `( ... )`, a brace group, a command substitution, a nested `bash -c` payload, or `xargs` is not classified. The classifier contributes no top-level command word for those, the same boundary `docs/cd-guard.md` records. Because that is a real gap rather than a theoretical one, the cd-guard's deny message no longer recommends a subshell unqualified; it recommends `git -C <dir>` first and says plainly that a subshell hides its contents from this guard. A guard in this family must not route an agent it just blocked into a sibling's blind spot.
- A leading `!` negation is not a reserved word this guard strips, so `! git push --delete ...` is unclassified. It inverts the exit status of a command whose result nothing reads, so it is an obfuscation shape rather than an agent mistake.
- Malformed or untokenizable syntax fails open (allow), matching the cd-guard rather than the watcher-arm seatbelt. Both incident commands tokenize cleanly, so zero false blocks is worth more here than catching deliberately malformed input.
- `--git-dir` and `--work-tree` are not treated as directory redirection for the gated class; only `-C` and the current directory are.
- The current directory the policy reads is the hook process's, which is the session directory rather than the tool shell's own cwd if an earlier command moved it. In a primary the cd-guard already prevents that drift, and the `-C` form is classified exactly.

If a genuinely ambiguous command shape is found that risks a false block, the guard is not extended by guesswork; the ambiguity is escalated and the guard stays precise rather than over-eager.

## Escape hatch

`FM_ALLOW_DESTRUCTIVE=1` in the session environment allows every command the guard would otherwise deny, and every deny message names it.
The guard fails closed on every other value, including empty, `0`, `yes`, and `true`.

It is an environment variable rather than a flag, a config file, or a state file for the same reason as `FM_ALLOW_SUBAGENT` ([`subagent-guard.md`](subagent-guard.md)): it must be unforgeable in-session.
The variable has to be present when the harness process is launched, so no tool call the agent makes can enable it for the call that follows, including an inline `FM_ALLOW_DESTRUCTIVE=1 git push ...` assignment, which the hook never sees.
A deliberate exception therefore requires relaunching the session with it set, which is a conscious act, while an accidental use is impossible.
This property is the point rather than an inconvenience, because the second incident was an agent that had convinced itself the deletion was justified, and an in-session bypass would simply have been used.

For a genuinely one-off authorized operation the captain can also run the command in their own terminal, which is outside the harness and therefore not hooked at all.

## Stable reason codes

Every deny carries one stable code in square brackets before its prose reason.

| Code | Meaning |
| --- | --- |
| `destructive-rm` | A recursive forced removal targets a pool worktree, a `.git` path, or a `projects/` clone. |
| `destructive-push` | A push would delete or force-update a remote ref. |
| `destructive-git-history` | A branch force-delete, hard reset, clean, or filter-branch runs inside a project clone or pool worktree. |

Reason codes are the stable contract for tests and adapters.
Prose may improve without changing adapter behavior.

## Transport, output, and fail-open behavior

The entry forms, the deny and allow output shapes, and the fail-open cases are identical to the cd-guard's, which [`cd-guard.md`](cd-guard.md) owns; `bin/fm-destructive-pretool-check.sh`'s header owns this guard's exact mechanics.
Two things are specific to this guard.

- The escape hatch is honoured in the transport, before the classifier is consulted.
- The prefilter fast-allows any command whose text cannot contain `rm` or `git` after the classifier's cheapest byte normalizations, plus the same quoting-decoder marker delegation. Every deniable command runs one of those two programs, so this stays a strict superset. That marker set is coupled to the classifier's decoder set in `bin/fm-arm-command-policy.mjs`: adding any new quote or expansion form the classifier decodes requires extending it in the same change.

## Shared classifier ownership

`bin/fm-destructive-command-policy.mjs` imports the shell tokenizer, command-position analysis, and reserved-word handling (`Lexer`, `splitProgram`, `commandPosition`, `withoutLeadingKeywords`) from `bin/fm-arm-command-policy.mjs`, the sole owner of firstmate's shell classification, exactly as the cd policy does.
This guard never duplicates shell lexing; it adds only the destructive-command decision on top of that shared classifier.
Reusing that parser is what makes the structural, non-prose classification cheap enough to be the default.

## Harness wiring

| Harness | Entry | Adapter behavior on checker exit 2 |
| --- | --- | --- |
| Claude | `.claude/settings.json` PreToolUse Bash hook forwarding stdin with `--claude` | Blocks the tool call; stderr deny object, stdout empty. |
| Codex | `.codex/hooks.json` PreToolUse hook that anchors from `pwd -P`, verifies the hook-loaded firstmate root, and forwards the payload | Blocks on exit 2 and displays stderr. |
| Grok | `.grok/hooks/fm-primary-destructive-check.json` PreToolUse hook anchored on `${GROK_WORKSPACE_ROOT:-}` | Consumes the stdout `decision=deny` object. |
| OpenCode | `.opencode/plugins/fm-primary-destructive-check.js` `tool.execute.before` | Throws, which surfaces as the failed tool result. |
| Pi / pi-signed | `.pi/extensions/fm-primary-turnend-guard.ts` `tool_call` handler | Returns `{block: true}`; piggybacks on the already-loaded primary extension so no extra `-e` flag is needed. |
| Cursor | `.cursor/hooks.json` `preToolUse` hook matching `tool_name` `Shell`, forwarding stdin with `--cursor` | Prints Cursor's own `{"permission":"deny","user_message":...}` object on stdout and exits 0, because Cursor reads the returned object rather than the exit status. |

Each harness runs this guard alongside the watcher-arm seatbelt and the cd-guard; the three are independent checks, and any deny blocks the command.
Every shell variable reference in the Grok hook command carries an inline default (`${GROK_WORKSPACE_ROOT:-}`) because Grok expands the raw hook command before `bash -lc` runs it, the same requirement [`arm-pretool-check.md`](arm-pretool-check.md) documents.
The OpenCode plugin runs the checker in the session directory so the gated class reads the right current directory.

## Automated validation

`tests/fm-destructive-pretool-check.test.sh` owns the acceptance matrix and is registered in the `pure-contract-unit` family in `bin/fm-test-run.sh`.
Every deny and allow case runs through Codex-shaped stdin, Claude-shaped stdin, Grok-shaped stdin, OpenCode-shaped CLI, and Pi-shaped CLI entry forms.
The suite covers both 2026-08-30 incident commands; the branch-restoring `<sha>:refs/heads/<name>` recovery push; the prose and data near-misses a substring guard blocks; the loop and conditional bodies each class is classified through, with the loop headers they must not match; the self-or-ancestor removal rule and the ordinary `rm -rf build` it must not catch; the directory gate and its `-C` override; the escape hatch including its fail-closed values; the deny message naming that hatch; the task-worktree scope difference from the cd-guard; the Cursor rendering and the duplicate-registration suppression that keeps the Claude-settings copy from re-classifying a Cursor payload; an end-to-end regression that first reproduces the worktree detachment and then denies the exact command; the fail-open transport behavior; the prefilter fast path; the policy CLI contract; and the per-harness registration, with the OpenCode plugin and the Pi extension driven through their real handlers rather than read as source.

`tests/fm-brief.test.sh` covers the companion scaffold rule that makes a colleague's branch, merge request, deployment, ticket, or thread read-only in generated ship and scout briefs unless the brief authorizes the exact mutation.

Run:

```sh
bash -n bin/fm-destructive-pretool-check.sh
bin/fm-lint.sh
node --check bin/fm-destructive-command-policy.mjs
node --check bin/fm-arm-command-policy.mjs
tests/fm-destructive-pretool-check.test.sh
tests/fm-brief.test.sh
```

## Live validation record, 2026-08-30

Harness version:

```text
2.1.224 (Claude Code)
```

The run used a scratch firstmate-shaped project under a temporary directory: a git repo with `AGENTS.md`, a `bin/` holding the real transport and both policy files, a `projects/fake-clone/` stand-in, a `benign-dir/` control, and the tracked Claude registration verbatim in shape.
No modified file was installed into the primary checkout or a live harness configuration, and no live watcher, fleet state, or task metadata was involved.
The launch command was:

```sh
claude -p "$PROMPT" --dangerously-skip-permissions --output-format text
```

Claude was told to run two removals as separate tool calls, with the directories themselves as the observable: `rm -rf <scratch>/benign-dir` (must run) and `rm -rf <scratch>/projects/fake-clone` (must be denied).
Claude reported the first "succeeded, the directory is gone" and the second "blocked by a PreToolUse hook (`fm-destructive-pretool-check.sh`)", and relayed the escape hatch from the deny message.
The observable outcome matched: `benign-dir` was removed and `projects/fake-clone` survived.
The control is what makes this conclusive, because it proves the harness executed commands in that session rather than failing to run them at all.

Grok, OpenCode, Pi, Codex, and Cursor are not separately live-validated for this guard.
Their registrations are asserted by the test suite, and the transport, entry forms, and output shapes are structurally identical to `bin/fm-cd-pretool-check.sh`, whose per-harness deny behavior is live-validated in [`cd-guard.md`](cd-guard.md) and [`arm-pretool-check.md`](arm-pretool-check.md).
Refresh that evidence with the same scratch-project procedure those records describe.
