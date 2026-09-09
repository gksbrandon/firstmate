# Watcher pre-lock migration: uname-cache regression evidence

Change under test: `c640ebd` "fix(bin): resolve the OS once in poll-file stat helpers".

The four `fm-pr-lib.sh` and three `fm-x-lib.sh` stat helpers (plus
`fm-config-inherit-lib.sh` and `fm-remote-inherit-push.sh`) now read a single
cached `_FM_UNAME` instead of forking `uname` on every call. The migration runs
these helpers once per poll line, so the fork count previously scaled with the
number of armed PR polls and delayed watcher startup.

## Executable regression (fails before the fix, passes after)

Test: `test_migration_resolves_os_once_regardless_of_poll_count` in
`tests/fm-pr-check-security.test.sh`. It arms 4 and 16 canonical PR polls
through `fm-pr-check.sh` using the existing fixtures, prepends a counting
`uname` shim to `PATH`, runs `fm-pr-check-migrate.sh --checks-safe`, and asserts
the invocation count is a small constant (<= 8) and equal across poll counts.

### After the fix (target commit, current source)

```
$ bash tests/<trimmed-copy invoking only the target test>
ok - pre-lock migration resolves the OS once per process, not per poll line (4 and 16 polls both forked uname 1 times)
```

4 polls and 16 polls both fork `uname` exactly **1** time. The count does not
scale with poll count.

### Before the fix (base libs restored, per-call `$(uname)`)

```
$ git checkout c9dfbe9 -- bin/fm-pr-lib.sh bin/fm-x-lib.sh \
      bin/fm-config-inherit-lib.sh bin/fm-remote-inherit-push.sh
$ bash tests/<trimmed-copy invoking only the target test>
not ok - migration forked uname 280 times for 16 polls (must be <= 8: resolve the OS once, not per poll line)
```

With the per-call version, 16 polls fork `uname` **280** times (and 76 at 4
polls per the test comment) - it scales with poll count and blows the bound.
The base libs were restored to the target commit afterwards; the working tree
is clean apart from evidence.

## What this demonstrates

- The intended behavior (resolve the OS once per process, reused across all
  poll-file stat helpers) is real and observable end-to-end through the actual
  migration entry point `fm-pr-check-migrate.sh --checks-safe`.
- The fork count is now a small constant (1) independent of the number of armed
  PR polls, which is the root cause behind the reported watcher
  `reason=confirmation-timeout` before the singleton lock was established.
- The regression genuinely reproduces the reported failure: it fails on the
  pre-fix source and passes on the fixed source.
