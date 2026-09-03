import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

// PreToolUse seatbelt for OpenCode: deny a shell command that would destroy a
// worktree, a remote ref, or unlanded local work before the agent's bash tool
// runs it (see bin/fm-destructive-pretool-check.sh and docs/destructive-guard.md).
// This mirrors fm-primary-cd-check.js, calling the destructive-command owner
// instead of the cd-guard one. tool.execute.before can block by throwing
// (verified 2026-07-09 against OpenCode 1.17.15 for the watcher-arm plugin; the
// same mechanism carries this guard). The owner script owns its own decision and
// is inert outside a firstmate checkout; unlike the cd-guard it deliberately
// stays armed inside a task worktree.

function runProcess(command, args, cwd) {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"], cwd });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolvePromise({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? 0, stdout, stderr }));
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

export const FmPrimaryDestructiveCheck = async ({ directory, worktree }) => {
  const root = worktree ? (() => {
    try {
      return realpathSync(worktree);
    } catch {
      return resolve(worktree);
    }
  })() : await resolveRoot(directory);

  return {
    "tool.execute.before": async (input, output) => {
      if (!root || input?.tool !== "bash") return;
      const command = output?.args?.command;
      if (!command || typeof command !== "string") return;

      // The checker reads its own cwd for the directory-gated git class, so it
      // runs in the session directory rather than wherever OpenCode was started.
      const result = await runProcess(
        `${root}/bin/fm-destructive-pretool-check.sh`,
        ["--command", command],
        directory || root,
      );
      if (result.code !== 2) return;

      const reason = result.stderr.trim() || "denied by the destructive-command PreToolUse seatbelt";
      throw new Error(reason);
    },
  };
};
