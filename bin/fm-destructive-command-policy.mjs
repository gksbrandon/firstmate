#!/usr/bin/env node
// Semantic policy for the destructive-command guard: would this shell command
// irreversibly destroy a worktree, a remote ref, or unlanded local work?
//
// Two incidents on 2026-08-30 motivate it. A recursive forced removal was run
// against a held candidate worktree's .git link file, and a remote branch
// deletion was run against a colleague's open merge request source branch,
// which the forge auto-closed. Both were recovered, but the second left
// permanent close/reopen events in that merge request's activity.
//
// The decision is STRUCTURAL: it reads the executed command word and then the
// flags and operands of that command. It is never a substring search over the
// command text, so a grep, an echo, a heredoc, or a brief that merely DESCRIBES
// one of these commands is data and is allowed. The shell tokenizer and
// command-position analysis are imported from bin/fm-arm-command-policy.mjs,
// the sole owner of firstmate's shell classification, so this guard never
// duplicates shell lexing. It never evaluates, expands, sources, or runs any
// byte of the submitted command, and it never touches the filesystem: the
// directory gate is pure path arithmetic on the cwd the transport supplies.
//
// Denied classes:
//   rm      recursive AND force (flags in any order, clustered or separate)
//           with an operand naming a pool worktree, a path carrying a .git
//           component, or a projects/ clone path, or - when the current
//           directory is itself inside a clone or pool - an operand that
//           resolves to that directory or one of its ancestors.
//   git push  carrying a delete flag, a force flag (both long or short), a
//           refspec beginning with ':', or a plus-prefixed refspec, against any
//           remote. A plain <sha>:refs/heads/<name> push is ALLOWED: that is the
//           shape that restores a deleted branch.
//   git branch force-delete, git reset --hard, git clean, git filter-branch,
//           when the effective directory - the -C target when present, else the
//           cwd - resolves inside a projects/ clone or a pool worktree.
//
// Environmental scoping and the FM_ALLOW_DESTRUCTIVE=1 escape hatch live in the
// bin/fm-destructive-pretool-check.sh transport, not here.
// See docs/destructive-guard.md for the complete contract.

import path from "node:path";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { Lexer, splitProgram, commandPosition, withoutLeadingKeywords } from "./fm-arm-command-policy.mjs";

const ESCAPE = "Launch the session with FM_ALLOW_DESTRUCTIVE=1 for a deliberate, authorized exception.";

const REASONS = {
  "destructive-rm":
    `a recursive forced removal targeting a pool worktree, a .git directory, or a projects/ clone is blocked; it destroys a checkout and any unlanded work in it. Remove the specific files instead, or retire the worktree through the owned fleet script. ${ESCAPE}`,
  "destructive-push":
    `a push that deletes or force-updates a remote ref is blocked; one such push can destroy a colleague's branch and auto-close their open merge request. Push an ordinary fast-forward update instead - a <sha>:refs/heads/<name> refspec is allowed and is the shape that restores a deleted branch. ${ESCAPE}`,
  "destructive-git-history":
    `a history-destroying git command (branch force-delete, reset --hard, clean, filter-branch) inside a project clone or pool worktree is blocked; it discards unlanded work that no remote holds. Inspect with git status or git stash list first. ${ESCAPE}`,
};

const POOL_COMPONENT = ".treehouse";
const CLONE_COMPONENT = "projects";

// git's own global options that consume a following word, so the subcommand is
// located rather than guessed. --exec-path is deliberately absent: its bare form
// takes no argument and only its --exec-path=<path> form carries one.
const GIT_GLOBAL_TAKES_ARGUMENT = new Set([
  "-C",
  "-c",
  "--git-dir",
  "--work-tree",
  "--namespace",
  "--config-env",
  "--attr-source",
  "--super-prefix",
]);

const GATED_SUBCOMMANDS = new Set(["branch", "reset", "clean", "filter-branch"]);

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function pathComponents(value) {
  return value.split("/").filter((part) => part !== "" && part !== ".");
}

function optionName(option) {
  const equals = option.indexOf("=");
  return equals === -1 ? option : option.slice(0, equals);
}

// A long option git would accept as an unambiguous abbreviation of `full`.
// Anything shorter than two letters after the dashes is ambiguous to git itself.
function isLongAbbreviation(option, full) {
  const name = optionName(option);
  return name.startsWith("--") && name.length >= 4 && full.startsWith(name);
}

function shortLetters(option) {
  if (!option.startsWith("-") || option.startsWith("--")) return "";
  return option.slice(1);
}

function isForceOption(option) {
  if (optionName(option).startsWith("--force")) return true;
  if (isLongAbbreviation(option, "--force")) return true;
  return shortLetters(option).includes("f");
}

function isDeleteOption(option) {
  if (isLongAbbreviation(option, "--delete")) return true;
  return shortLetters(option).includes("d");
}

function isRecursiveOption(option) {
  if (isLongAbbreviation(option, "--recursive")) return true;
  const letters = shortLetters(option);
  return letters.includes("r") || letters.includes("R");
}

// Split a command's arguments into option words and operand words, honouring
// the `--` end-of-options marker. A bare `-` is an operand, not an option.
function splitArguments(words) {
  const options = [];
  const operands = [];
  let endOfOptions = false;
  for (const word of words) {
    const value = word.value;
    if (endOfOptions) {
      operands.push(value);
      continue;
    }
    if (value === "--") {
      endOfOptions = true;
      continue;
    }
    if (value.length > 1 && value.startsWith("-")) {
      options.push(value);
      continue;
    }
    operands.push(value);
  }
  return { options, operands };
}

function isProtectedRemovalTarget(value) {
  const parts = pathComponents(value);
  if (parts.length === 0) return false;
  if (parts.includes(POOL_COMPONENT)) return true;
  if (parts.includes(".git")) return true;
  return parts.includes(CLONE_COMPONENT);
}

// Inside a projects/ clone means a component AFTER `projects`, so the fleet's
// own projects/ directory is not itself treated as a clone.
function insideCloneOrPool(directory) {
  const parts = pathComponents(path.resolve(directory));
  if (parts.includes(POOL_COMPONENT)) return true;
  const at = parts.indexOf(CLONE_COMPONENT);
  return at !== -1 && at < parts.length - 1;
}

// An operand naming no fleet path of its own still destroys the checkout when it
// resolves to the directory the command runs in, or to an ancestor of it, and
// that directory sits in a clone or pool: `rm -rf .` and `rm -rf ..` are the
// shapes. The filesystem root is an ancestor like any other, so the prefix is
// normalized rather than concatenated - `/` + `/` would never match. Resolution
// is deliberately limited to self-or-ancestor, because resolving every operand
// would deny an ordinary `rm -rf build` there too.
function removesOwnDirectory(value, cwd) {
  const resolved = path.resolve(cwd, value);
  const directory = path.resolve(cwd);
  if (directory === resolved) return true;
  const prefix = resolved.endsWith(path.sep) ? resolved : `${resolved}${path.sep}`;
  return directory.startsWith(prefix);
}

function removalDestroys(words, cwd) {
  const { options, operands } = splitArguments(words);
  const recursive = options.some(isRecursiveOption);
  const force = options.some(isForceOption);
  if (!recursive || !force) return false;
  // An empty word names no path at all, and path.resolve would read it as the
  // current directory. Both operand rules agree it is not a target.
  const targets = operands.filter((operand) => operand !== "");
  if (targets.some(isProtectedRemovalTarget)) return true;
  return insideCloneOrPool(cwd) && targets.some((target) => removesOwnDirectory(target, cwd));
}

// Resolve git's global options to the subcommand, the effective directory after
// every -C (git composes them in order), and the subcommand's own arguments.
function gitInvocation(words, cwd) {
  let directory = cwd;
  let index = 0;
  while (index < words.length) {
    const value = words[index].value;
    if (value === "--") {
      index += 1;
      break;
    }
    if (!value.startsWith("-") || value === "-") break;
    const name = optionName(value);
    if (!value.includes("=") && GIT_GLOBAL_TAKES_ARGUMENT.has(name)) {
      if (name === "-C" && words[index + 1]) directory = path.resolve(directory, words[index + 1].value);
      index += 2;
      continue;
    }
    index += 1;
  }
  return { subcommand: words[index] ? words[index].value : "", directory, words: words.slice(index + 1) };
}

function pushDestroys(words) {
  const { options, operands } = splitArguments(words);
  if (options.some(isDeleteOption)) return true;
  if (options.some(isForceOption)) return true;
  // A refspec beginning with ':' deletes the destination ref; a '+' prefix makes
  // the update forced. A colon INSIDE a refspec is an ordinary update.
  return operands.some((operand) => operand.startsWith(":") || operand.startsWith("+"));
}

function historyDestroys(subcommand, words) {
  if (subcommand === "clean" || subcommand === "filter-branch") return true;
  const { options } = splitArguments(words);
  if (subcommand === "reset") return options.some((option) => isLongAbbreviation(option, "--hard"));
  if (subcommand !== "branch") return false;
  if (options.some((option) => shortLetters(option).includes("D"))) return true;
  return options.some(isDeleteOption) && options.some(isForceOption);
}

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

function decision(command, cwd) {
  const lexed = new Lexer(command).tokenize();
  // Fail open on syntax this classifier cannot tokenize, matching the sibling
  // cd-guard: the threat model is agent mistakes, and every command in both
  // incidents tokenizes cleanly, so zero false blocks is worth more here than
  // catching deliberately malformed syntax.
  if (lexed.error) return { decision: "allow" };

  const { nodes } = splitProgram(lexed.tokens);
  for (const node of nodes) {
    // commandPosition skips leading assignments and forking wrappers, and
    // contributes no command word for quoted data, comments, substitutions, or
    // subshell and brace groups - which is exactly what keeps a command that
    // merely mentions these patterns in an argument from matching.
    // withoutLeadingKeywords drops the reserved word a loop or conditional puts
    // in front of its body, so `do git push --delete ...` classifies as a push.
    const position = commandPosition(withoutLeadingKeywords(node));
    if (!position.command) continue;
    const words = position.words.slice(position.index + 1);
    const name = basename(position.command.value);

    if (name === "rm") {
      if (removalDestroys(words, cwd)) return deny("destructive-rm");
      continue;
    }
    if (name !== "git") continue;

    const invocation = gitInvocation(words, cwd);
    if (invocation.subcommand === "push") {
      if (pushDestroys(invocation.words)) return deny("destructive-push");
      continue;
    }
    if (!GATED_SUBCOMMANDS.has(invocation.subcommand)) continue;
    if (!historyDestroys(invocation.subcommand, invocation.words)) continue;
    if (insideCloneOrPool(invocation.directory)) return deny("destructive-git-history");
  }
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false, cwd: process.cwd() };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command" || name === "--cwd") {
      if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
      if (name === "--command") {
        result.command = argv[i + 1];
        result.commandSet = true;
      } else {
        result.cwd = argv[i + 1];
      }
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    if (name.startsWith("--cwd=")) {
      result.cwd = name.slice("--cwd=".length);
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command, args.cwd);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
