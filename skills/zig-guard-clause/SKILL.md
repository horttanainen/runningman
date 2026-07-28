---
name: zig-guard-clause
description: Apply this skill whenever generating new Zig code in Runningman. Handle invalid input, missing required records, unsupported states, and other special cases before the main calculation or rendering path, while preserving concise Zig optional handling where it remains clearer.
---

# Zig Guard Clause Style

Handle invalid input and states that prevent trustworthy work before the main
path. Return typed errors with enough specificity for `friendlyError` or the
calling module to explain the problem.

```zig
pub fn validate(profile: RunnerProfile) !void {
    if (profile.schema_version != current_schema_version) {
        return error.UnsupportedRunnerProfileSchema;
    }
    if (profile.profile_id.len == 0) {
        return error.RunnerProfileIdRequired;
    }

    // Main validation path.
}
```

Use `orelse return error.X` when a required value is absent:

```zig
const schedule = storage.schedules.get(schedule_id) orelse
    return error.ScheduleNotFound;
```

Use `catch` when an error needs domain-specific translation:

```zig
const race_date = date.parse(profile.goal.race_date.value) catch
    return error.InvalidRaceDate;
```

Optional binding remains appropriate for short, genuinely optional behavior:

```zig
if (profile.goal.target_time_seconds) |target| {
    try validateTarget(target.value);
}
```

Do not mechanically duplicate lookups or unwrap with `.?` merely to satisfy a
style preference. Optimize for a flat, readable happy path and explicit domain
errors.

When a guard handles an unexpected condition and processing continues, apply
the `zig-defensive-logging` skill. Expected user validation errors should not be
logged separately.
