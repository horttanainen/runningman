const std = @import("std");
const date = @import("date.zig");
const interruption = @import("interruption.zig");
const plan_adjustment = @import("plan_adjustment.zig");
const provenance = @import("plan_provenance.zig");
const store = @import("store.zig");

pub const Commands = struct { executable: []const u8, data_path: []const u8 };
pub const ReviewState = enum { clear, missing_data, reduce };
pub const Checkpoint = struct {
    review_on: date.Date,
    planned_from: date.Date,
    from: date.Date,
    next_stage: provenance.ReturnStage,
};

pub fn checkpoint(context: provenance.Adjustment, as_of: date.Date, unlogged_from: date.Date) !?Checkpoint {
    if (context.policy_version != 3) return null;
    if (context.stage == .continuation) return null;
    const next: provenance.ReturnStage = if (context.stage == .base) .repeat else .continuation;
    const start = try date.parse(context.parent.provenance.runner_profile.plan_start_date.value);
    for (context.week_changes) |change| {
        if (change.stage != next) continue;
        const planned_from = date.addDays(start, (@as(i32, change.week) - 1) * 7);
        var from = planned_from;
        if (date.compare(as_of, from) == .gt) from = as_of;
        if (date.compare(unlogged_from, from) == .gt) from = unlogged_from;
        const weekday = date.weekday(from);
        if (weekday != 0) from = date.addDays(from, 7 - @as(i32, weekday));
        return .{ .review_on = date.addDays(planned_from, -1), .planned_from = planned_from, .from = from, .next_stage = next };
    }
    return error.InvalidAdjustmentContext;
}

pub fn printShellArgument(writer: *std.Io.Writer, value: []const u8) !void {
    const safe = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-:";
    if (value.len > 0 and std.mem.indexOfNone(u8, value, safe) == null) {
        try writer.writeAll(value);
        return;
    }
    try writer.writeByte('\'');
    for (value) |character| {
        if (character == '\'') {
            try writer.writeAll("'\\''");
            continue;
        }
        try writer.writeByte(character);
    }
    try writer.writeByte('\'');
}

pub fn printPrefix(writer: *std.Io.Writer, commands: Commands) !void {
    try writer.writeAll("  ");
    try printShellArgument(writer, commands.executable);
    if (std.mem.eql(u8, commands.data_path, "runningman-data.jsonl")) return;
    try writer.writeAll(" --data ");
    try printShellArgument(writer, commands.data_path);
}

fn printCheckpoint(allocator: std.mem.Allocator, writer: *std.Io.Writer, next: Checkpoint, as_of: date.Date) !void {
    const review_on = try date.format(allocator, next.review_on);
    const from = try date.format(allocator, next.from);
    try writer.print("Checkpoint: {s}, {s}; possible {s} stage from {s}, {s}.\n", .{
        date.weekdayName(next.review_on), review_on, @tagName(next.next_stage), date.weekdayName(next.from), from,
    });
    if (date.compare(as_of, next.review_on) == .eq) {
        try writer.writeAll("The checkpoint is today. Assess your response before the next stage.\n");
    } else if (date.compare(as_of, next.review_on) == .gt) {
        try writer.writeAll("The checkpoint is overdue. Later workouts remain provisional; do not start them just because their date has arrived.\n");
    } else {
        try writer.writeAll("Until the checkpoint, follow the confirmed stage, log actual workouts and keep morning Oura scores current. No daily adjustment is needed.\n");
    }
    if (date.compare(next.from, next.planned_from) == .gt) {
        try writer.writeAll("The proposed start has moved to the next available Monday to preserve logged training and complete source weeks.\n");
    }
}

pub fn printReminder(allocator: std.mem.Allocator, writer: *std.Io.Writer, commands: Commands, context: provenance.Adjustment, as_of: date.Date, unlogged_from: date.Date) !void {
    if (context.policy_version != 3) return;
    try writer.print("\nReturn-plan guidance: selected stage {s}, effective {s}.\n", .{ @tagName(context.stage), context.restart_date });
    const next = (try checkpoint(context, as_of, unlogged_from)) orelse {
        try writer.writeAll("Continuation is confirmed. No further return-stage checkpoint is scheduled; follow the applied progression and regular reviews.\n");
        return;
    };
    try printCheckpoint(allocator, writer, next, as_of);
    try writer.writeAll("At the checkpoint, review the recorded training and follow the stage instructions shown by:\n");
    try printPrefix(writer, commands);
    try writer.writeAll(" review\nThe checkpoint is a scheduling reminder, not an automatic readiness decision.\n");
}

fn printStageCommands(allocator: std.mem.Allocator, writer: *std.Io.Writer, commands: Commands, stage: provenance.ReturnStage, from: date.Date) !void {
    const from_text = try date.format(allocator, from);
    const output = try std.fmt.allocPrint(allocator, "{s}-plan-{s}.json", .{ @tagName(stage), from_text });
    try printPrefix(writer, commands);
    try writer.print(" plan adjust --from {s} --ready-to-resume --stage {s} --output {s}\n", .{ from_text, @tagName(stage), output });
    try writer.writeAll("Inspect the generated preview. Only if you accept it, apply that proposal:\n");
    try printPrefix(writer, commands);
    try writer.print(" plan apply {s}\n", .{output});
}

pub fn printReview(allocator: std.mem.Allocator, writer: *std.Io.Writer, commands: Commands, storage: *const store.Store, as_of: date.Date, state: ReviewState) !bool {
    const active = storage.schedules.get(storage.max_schedule_id) orelse return false;
    const source = active.plan_provenance orelse return false;
    const context = source.adjustment orelse return false;
    if (context.policy_version != 3) return false;
    if (date.compare(as_of, try date.parse(context.interruption_start)) == .lt) return false;
    const unlogged_from = try plan_adjustment.suggestedRestart(storage, as_of);
    try writer.print("\nApplied return plan: schedule #{d}, selected stage {s}, effective {s}.\n", .{ active.id, @tagName(context.stage), context.restart_date });
    const next = (try checkpoint(context, as_of, unlogged_from)) orelse {
        try writer.writeAll("Continuation is confirmed. No further return-stage checkpoint is scheduled; use regular reviews for new issues. Historical sickness skips alone do not require another adjustment.\n");
        return true;
    };
    try printCheckpoint(allocator, writer, next, as_of);
    if (state != .clear) {
        try writer.writeAll(if (state == .missing_data)
            "Stage change blocked: resolve the missing information listed above, then review again. No readiness confirmation has been inferred.\n"
        else
            "Stage change blocked: the current review recommends REDUCE. Address the effort, recovery or confirmed-pain signals before choosing a next stage.\n");
        try printPrefix(writer, commands);
        try writer.writeAll(" review\n");
        return true;
    }
    if (date.compare(next.from, try date.parse(active.race_date)) != .lt) {
        try writer.writeAll("No next-stage Monday remains before this plan's target date. This return workflow cannot propose a stage starting on or after that date; the remaining plan needs a separate revision.\n");
        return true;
    }
    const due = date.compare(as_of, next.review_on) != .lt;
    const return_runs = try interruption.completedReturnRuns(storage, try date.parse(context.interruption_start), as_of);
    var recorded = return_runs > 0;
    if (context.stage == .repeat) {
        const parent = try plan_adjustment.snapshot(allocator, storage);
        var before = date.addDays(as_of, 1);
        if (date.compare(before, next.from) == .gt) before = next.from;
        const completed: ?interruption.ReturnedWeek = interruption.completedRepeatedWeek(storage, parent, before) catch |err| switch (err) {
            error.AdjustmentRepeatedWeekRequired => null,
            else => return err,
        };
        if (completed == null) recorded = false;
        try writer.writeAll("At the checkpoint: was the repeated loading week completed, and did the training and subsequent recovery go well?\n");
        try writer.writeAll("Continuation requires all core runs in that repeated week logged as completed running, with actual distances.\n");
    } else {
        try writer.writeAll("At the checkpoint: do easy-running effort/heart rate relative to pace, and recovery afterward, feel normal compared with before the illness?\n");
        try writer.print("Completed runs after the latest sickness skip: {d}. At least one is required, but logging alone does not confirm normal response.\n", .{return_runs});
    }
    if (due and !recorded) {
        try writer.writeAll("The recorded-training prerequisite is not met. Record what actually happened; do not confirm the next stage yet.\n");
    } else {
        try writer.writeAll("If YES at the checkpoint, with the required training recorded, create the next-stage proposal:\n");
        try printStageCommands(allocator, writer, commands, next.next_stage, next.from);
    }
    try writer.writeAll(if (context.stage == .base)
        "If NOT YET, but you are ready to continue easy running, extend the base stage instead:\n"
    else
        "If the repeated week did not go well, but you are ready to repeat that training, repeat it instead of advancing:\n");
    var stay_from = next.from;
    if (context.stage == .base) {
        // An overdue base extension can cover the current partial week; it
        // must not leave the runner waiting for another Monday to get a plan.
        stay_from = next.planned_from;
        if (date.compare(as_of, stay_from) == .gt) stay_from = as_of;
        if (date.compare(unlogged_from, stay_from) == .gt) stay_from = unlogged_from;
    }
    try printStageCommands(allocator, writer, commands, context.stage, stay_from);
    if (context.stage == .repeat) try writer.writeAll("For an easy-only return instead, use --stage base and an unused base-plan filename.\n");
    try writer.writeAll("Run only the branch matching your response, not both. If you are not ready to resume, do not use --ready-to-resume.\nThe adjustment asks whether the target date can move; use unused output filenames. Later stages require explicit apply, never just a calendar date.\n");
    return true;
}
