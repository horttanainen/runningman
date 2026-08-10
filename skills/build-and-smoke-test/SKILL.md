---
name: build-and-smoke-test
description: Run this skill automatically after finishing any task that introduced code or script changes to Runningman. Use the repository check script, then perform a focused CLI smoke check when the change affects user-visible behavior. Never test mutations against the user's default training data.
---

# Build and Smoke Test

After code or script changes, validate the complete project and the changed
user-facing workflow.

## 1. Run the complete check

Always format through the repository wrapper:

```sh
bash scripts/format.sh
```

Never invoke `zig fmt` directly. The wrapper defines the repository file set
and cache exclusions, and is approved for sandboxed use.

Run exactly:

```sh
./check.sh
```

`check.sh` calls the same formatter wrapper, then runs the project's canonical
build, unit-test, CLI-test, shell syntax, and Polar and Garmin importer checks.
Do not run separate `zig fmt`, `zig build`, or `zig build test` commands when
`./check.sh` covers the task.

If the check fails, fix the failure and run `./check.sh` again.

## 2. Smoke-test changed behavior

If the change affects a CLI workflow, run the smallest representative command
against the built binary:

```sh
./zig-out/bin/runningman COMMAND
```

Read-only planner inputs may use committed examples:

```sh
./zig-out/bin/runningman profile validate examples/runner-profile.json
./zig-out/bin/runningman evidence validate examples/evidence-ledger.json
```

For commands that read or write training data:

- create an isolated temporary directory;
- pass its data file with `--data PATH`;
- initialize it when the command requires a schedule; and
- remove it after the smoke check.

Never run a mutating smoke test against `runningman-data.jsonl` or another
personal data file. Do not invent a long-running process or timeout-based smoke
test: Runningman is a terminating CLI.

Skip a separate smoke command when the change is internal and the complete
check already exercises it directly.

## 3. Report

Report:

- whether `./check.sh` passed;
- the focused command used, if any; and
- unexpected output, failures, or warnings.

When everything passes, a short confirmation is enough.
