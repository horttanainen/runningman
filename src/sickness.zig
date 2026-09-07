const std = @import("std");
const activity = @import("activity.zig");
const date = @import("date.zig");
const model = @import("model.zig");
const store = @import("store.zig");

pub const Command = struct {
    from: date.Date,
    through: date.Date,
    dry_run: bool,
};

pub fn parse(args: []const []const u8, today: date.Date) !Command {
    var from: ?date.Date = null;
    var through: ?date.Date = null;
    var sick = false;
    var dry_run = false;
    var index: usize = 0;
    while (index < args.len) {
        const flag = args[index];
        index += 1;
        if (std.mem.eql(u8, flag, "--sick") and !sick) {
            sick = true;
            continue;
        }
        if (std.mem.eql(u8, flag, "--dry-run") and !dry_run) {
            dry_run = true;
            continue;
        }
        const is_from = std.mem.eql(u8, flag, "--from");
        const is_through = std.mem.eql(u8, flag, "--through");
        if (!is_from and !is_through) return error.InvalidSicknessCommand;
        if (index == args.len) return error.MissingFlagValue;
        const value = try date.parse(args[index]);
        index += 1;
        if (is_from) {
            if (from != null) return error.InvalidSicknessCommand;
            from = value;
            continue;
        }
        if (through != null) return error.InvalidSicknessCommand;
        through = value;
    }
    if (!sick) return error.InvalidSicknessCommand;
    const start = from orelse return error.InvalidSicknessCommand;
    const end = through orelse return error.InvalidSicknessCommand;
    if (date.compare(start, end) == .gt) return error.InvalidSicknessRange;
    if (date.compare(end, today) == .gt) return error.FutureSicknessDate;
    return .{ .from = start, .through = end, .dry_run = dry_run };
}

// Build the entire batch before preview or append; existing outcomes are immutable.
pub fn propose(allocator: std.mem.Allocator, storage: *const store.Store, command: Command) ![]model.Event {
    var events: std.ArrayList(model.Event) = .empty;
    errdefer events.deinit(allocator);
    var current = command.from;
    const recorded_at = date.unixTimestamp();
    while (date.compare(current, command.through) != .gt) : (current = date.addDays(current, 1)) {
        const schedule = store.effectiveSchedule(storage, current) orelse return error.NoScheduleForDate;
        const workout = store.workoutForDate(storage, schedule.id, current) orelse return error.NoWorkoutForDate;
        if (store.latestActivityForDate(storage, current) != null) continue;
        if (std.mem.eql(u8, workout.kind, "rest")) continue;
        if (std.mem.eql(u8, workout.kind, "recovery-or-rest") or
            std.mem.eql(u8, workout.kind, "optional-recovery")) continue;
        if (workout.decision) |decision| {
            if (decision.allocation_role == .optional_recovery) continue;
        }
        const value = try activity.make(
            storage.max_activity_id + events.items.len + 1,
            null,
            schedule.id,
            workout.id,
            workout.date,
            .{ .status = .skipped, .deviation_reason = "sickness" },
            recorded_at,
        );
        try events.append(allocator, model.activityEvent(value));
    }
    return events.toOwnedSlice(allocator);
}
