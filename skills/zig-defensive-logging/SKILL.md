---
name: zig-defensive-logging
description: Apply this skill whenever generating new Zig code in Runningman. Distinguish expected validation errors from unexpected recoverable internal conditions, and ensure unexpected conditions leave useful diagnostic context without duplicating normal CLI error reporting.
---

# Zig Defensive Logging

Runningman normally reports expected failures by returning a specific error to
the CLI, where `friendlyError` renders it. Do not add `std.log` calls for normal
validation failures, missing user input, unsupported profiles, or file-not-found
errors that the caller reports.

Log only when the program continues after an unexpected internal condition that
would otherwise be invisible.

```zig
const workout = storage.workouts.get(workout_id) orelse {
    std.log.warn(
        "renderReview: workout {d} referenced by activity {d} is missing",
        .{ workout_id, activity_id },
    );
    continue;
};
```

Prefer returning a precise error when the operation cannot produce a trustworthy
result:

```zig
const schedule = storage.schedules.get(schedule_id) orelse
    return error.ScheduleNotFound;
```

Do not both log and return an error that the top-level CLI will immediately
print unless the log provides essential context absent from the returned error.

Use:

- `std.log.warn` when an unexpected record or optional value is skipped and the
  command can still produce a valid result;
- `std.log.err` when continuing is possible but indicates a serious invariant
  violation; and
- a typed error instead of logging when the command must stop.

Include the function name and relevant record ID, date, path, or rule ID.
