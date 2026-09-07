const std = @import("std");
const date = @import("date.zig");
const provenance = @import("plan_provenance.zig");
const revision = @import("plan_revision.zig");
const store = @import("store.zig");
const review = @import("training_review.zig");

pub const Observation = struct {
    first: date.Date,
    skipped: u16,
    weekly_km: f64,
    peak_weekly_km: f64,
    long_km: f64,
    easy_km: f64,
    repeat_week: u8,
    repeat_km: f64,
    repeat_long_km: f64,
    resumed_runs: usize,
};

pub fn originalPlan(parent: *const revision.RevisionFile) !*const revision.RevisionFile {
    var original = parent;
    var depth: usize = 0;
    while (original.provenance.adjustment) |context| {
        if (context.policy_version != 3) return error.SupersededAdjustment;
        depth += 1;
        if (depth > 24) return error.InvalidAdjustmentContext;
        original = context.parent;
    }
    if (original.workouts.len == 0 or original.weeks.len != (original.workouts.len + 6) / 7) return error.InvalidAdjustmentContext;
    return original;
}

pub fn observe(storage: *const store.Store, parent: *const revision.RevisionFile, restart: date.Date) !Observation {
    const original = try originalPlan(parent);
    const state = try review.evaluateSnapshot(storage, restart);
    // An ongoing return may no longer classify REPLAN. Current strain or missing
    // observations still prevent generating a trustworthy continuation.
    if (state.result.classification == .reduce or state.result.classification == .insufficient_data or
        (parent.provenance.adjustment == null and state.result.classification != .replan)) return error.AdjustmentRequiresReplan;
    const first = if (parent.provenance.adjustment) |context|
        try date.parse(context.interruption_start)
    else
        state.result.inputs.first_sickness_skip orelse return error.AdjustmentNeedsSicknessInterruption;
    const start = try date.parse(original.workouts[0].date);
    const before = date.addDays(first, -@as(i32, date.weekday(first)));
    var first_week = date.addDays(before, -28);
    if (date.compare(first_week, start) == .lt) first_week = start;
    var result: Observation = .{ .first = first, .skipped = 0, .weekly_km = 0, .peak_weekly_km = 0, .long_km = 0, .easy_km = 0, .repeat_week = 0, .repeat_km = 0, .repeat_long_km = 0, .resumed_runs = 0 };
    var easy_count: usize = 0;
    var week_count: usize = 0;
    var current = first_week;
    while (date.compare(current, before) == .lt) : (current = date.addDays(current, 7)) {
        const index: usize = @intCast(@divExact(date.daysBetween(start, current), 7));
        if (index >= original.weeks.len) return error.IncompleteParentSchedule;
        var total: f64 = 0;
        var longest: f64 = 0;
        var complete = true;
        var core_count: usize = 0;
        for (0..7) |offset| {
            const day = date.addDays(current, @intCast(offset));
            const planned = store.currentWorkout(storage, day) orelse return error.IncompleteParentSchedule;
            const role = (planned.decision orelse return error.RevisionWorkoutDecisionRequired).allocation_role;
            const core = role != .rest and role != .optional_recovery;
            if (core) core_count += 1;
            const logged = store.latestActivityForDate(storage, day) orelse {
                if (core) return error.AdjustmentBaselineIncomplete;
                continue;
            };
            if (logged.sport != .running or logged.status != .completed) {
                if (core) complete = false;
            }
            if (logged.sport != .running or (logged.status != .completed and logged.status != .modified)) continue;
            const km = logged.distance_km orelse return error.AdjustmentBaselineIncomplete;
            if (!std.math.isFinite(km) or km <= 0) return error.AdjustmentBaselineIncomplete;
            total += km;
            if (role == .long_run) longest = @max(longest, km);
            if (role == .easy and (logged.rpe == null or logged.rpe.? <= 4)) {
                result.easy_km += km;
                easy_count += 1;
            }
        }
        const phase = original.weeks[index].phase;
        if (complete and core_count > 0 and longest > 0 and
            (std.mem.eql(u8, phase, "build") or std.mem.eql(u8, phase, "race_specific")))
        {
            result.repeat_week = @intCast(index + 1);
            result.repeat_km = total;
            result.repeat_long_km = longest;
        }
        result.weekly_km += total;
        result.peak_weekly_km = @max(result.peak_weekly_km, total);
        result.long_km = @max(result.long_km, longest);
        week_count += 1;
    }
    if (week_count == 0 or easy_count == 0 or result.repeat_week == 0 or result.long_km <= 0) return error.AdjustmentCompletedLoadingWeekRequired;
    result.weekly_km /= @as(f64, @floatFromInt(week_count));
    result.easy_km /= @as(f64, @floatFromInt(easy_count));
    current = first;
    while (date.compare(current, restart) == .lt) : (current = date.addDays(current, 1)) {
        const logged = store.latestActivityForDate(storage, current) orelse continue;
        const planned = store.currentWorkout(storage, current) orelse return error.IncompleteParentSchedule;
        const role = (planned.decision orelse return error.RevisionWorkoutDecisionRequired).allocation_role;
        if (logged.sport == .running and role != .rest and role != .optional_recovery and
            logged.status == .skipped and std.ascii.eqlIgnoreCase(logged.deviation_reason, "sickness"))
        {
            result.skipped += 1;
        }
    }
    result.resumed_runs = try completedReturnRuns(storage, first, date.addDays(restart, -1));
    if (result.skipped < 2) return error.AdjustmentNeedsSicknessInterruption;
    for (storage.activities.values()) |logged| {
        if (date.compare(try date.parse(logged.date), restart) != .lt) return error.AdjustmentWouldReplaceLoggedWorkout;
    }
    return result;
}

pub const ReturnedWeek = struct { weekly_km: f64, long_km: f64 };

pub fn validateStage(storage: *const store.Store, parent: revision.RevisionFile, restart: date.Date, stage: provenance.ReturnStage, observed: Observation) !?ReturnedWeek {
    if (stage == .base) return null;
    if (date.weekday(restart) != 0) return error.AdjustmentLoadingRestartMustBeMonday;
    if (observed.resumed_runs == 0) return error.AdjustmentReturnRunRequired;
    if (stage == .repeat) return null;
    return try completedRepeatedWeek(storage, parent, restart);
}

pub fn completedReturnRuns(storage: *const store.Store, first: date.Date, through: date.Date) !usize {
    var count: usize = 0;
    var current = first;
    while (date.compare(current, through) != .gt) : (current = date.addDays(current, 1)) {
        const logged = store.latestActivityForDate(storage, current) orelse continue;
        const planned = store.currentWorkout(storage, current) orelse return error.IncompleteParentSchedule;
        const role = (planned.decision orelse return error.RevisionWorkoutDecisionRequired).allocation_role;
        if (logged.sport == .running and role != .rest and role != .optional_recovery and
            logged.status == .skipped and std.ascii.eqlIgnoreCase(logged.deviation_reason, "sickness")) count = 0;
        if (logged.sport == .running and logged.status == .completed) count += 1;
    }
    return count;
}

pub fn completedRepeatedWeek(storage: *const store.Store, parent: revision.RevisionFile, before: date.Date) !ReturnedWeek {
    const context = parent.provenance.adjustment orelse return error.AdjustmentRepeatedWeekRequired;
    const start = try date.parse(parent.workouts[0].date);
    var latest: ?ReturnedWeek = null;
    for (context.week_changes) |change| {
        if (change.stage != .repeat) continue;
        const first = date.addDays(start, (@as(i32, change.week) - 1) * 7);
        if (date.compare(date.addDays(first, 7), before) == .gt) continue;
        var complete = true;
        var returned: ReturnedWeek = .{ .weekly_km = 0, .long_km = 0 };
        for (0..7) |i| {
            const day = date.addDays(first, @intCast(i));
            const planned = store.currentWorkout(storage, day) orelse return error.IncompleteParentSchedule;
            const role = (planned.decision orelse return error.RevisionWorkoutDecisionRequired).allocation_role;
            if (role == .rest or role == .optional_recovery) continue;
            const logged = store.latestActivityForDate(storage, day) orelse {
                complete = false;
                break;
            };
            if (logged.sport != .running or logged.status != .completed or (logged.distance_km orelse 0) <= 0) complete = false;
            returned.weekly_km += logged.distance_km orelse 0;
            if (role == .long_run) returned.long_km = @max(returned.long_km, logged.distance_km orelse 0);
        }
        if (complete and returned.weekly_km > 0 and returned.long_km > 0) latest = returned;
    }
    return latest orelse error.AdjustmentRepeatedWeekRequired;
}
