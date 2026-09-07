const std = @import("std");
const date = @import("date.zig");
const provenance = @import("plan_provenance.zig");
const targeted = @import("targeted_adjustment.zig");
const revision = @import("plan_revision.zig");
const validator = @import("plan_validator.zig");
const runner_profile = @import("runner_profile.zig");
const store = @import("store.zig");
const interruption = @import("interruption.zig");

pub const RaceChoice = enum { flexible, keep, change };

pub const Options = struct {
    restart: date.Date,
    race_date: ?date.Date = null,
    race_choice: ?RaceChoice = null,
    ready: bool = false,
    stage: provenance.ReturnStage = .base,
    base_weeks: u8 = 1,
};

pub fn suggestedRestart(storage: *const store.Store, as_of: date.Date) !date.Date {
    var restart = as_of;
    for (storage.activities.values()) |logged| {
        const logged_date = try date.parse(logged.date);
        if (date.compare(logged_date, restart) == .lt) continue;
        restart = date.addDays(logged_date, 1);
    }
    return restart;
}

pub fn snapshot(allocator: std.mem.Allocator, storage: *const store.Store) !revision.RevisionFile {
    const parent = storage.schedules.get(storage.max_schedule_id) orelse return error.NotInitialized;
    const context = parent.plan_provenance orelse return error.AdjustmentNeedsGeneratedPlan;
    const start = try date.parse(parent.start_date);
    const end = try date.parse(parent.race_date);
    const count: usize = @intCast(date.daysBetween(start, end) + 1);
    const workouts = try allocator.alloc(revision.ProposedWorkout, count);
    for (workouts, 0..) |*item, i| {
        const planned = store.workoutForDate(storage, parent.id, date.addDays(start, @intCast(i))) orelse return error.IncompleteParentSchedule;
        item.* = .{
            .date = planned.date,
            .phase = planned.phase,
            .kind = planned.kind,
            .intensity = planned.intensity,
            .details = planned.details,
            .distance_min_km = planned.distance_min_km,
            .distance_max_km = planned.distance_max_km,
            .terrain = planned.terrain,
            .ascent_meters = planned.ascent_meters,
            .descent_meters = planned.descent_meters,
            .segments = planned.segments,
            .decision = planned.decision,
        };
    }
    return .{
        .schema_version = 2,
        .base_schedule_id = parent.id,
        .effective_from = parent.effective_from,
        .reason = parent.reason,
        .name = parent.name,
        .goal = parent.goal,
        .availability = parent.availability,
        .intensity_guidance = parent.intensity_guidance,
        .pace_profile = parent.pace_profile,
        .race_date = parent.race_date,
        .provenance = context,
        .assessment = context.assessment,
        .weeks = parent.plan_weeks,
        .workouts = workouts,
    };
}

pub fn generate(allocator: std.mem.Allocator, storage: *const store.Store, options: Options) !revision.RevisionFile {
    if (!options.ready) return error.AdjustmentReadinessRequired;
    if (options.base_weeks < 1 or options.base_weeks > 4) return error.InvalidBaseWeeks;
    const choice = options.race_choice orelse return error.AdjustmentRaceChoiceRequired;
    if ((choice == .change) != (options.race_date != null)) return error.InvalidAdjustmentContext;
    const parent = try allocator.create(revision.RevisionFile);
    parent.* = try snapshot(allocator, storage);
    if (runner_profile.trainingLoadBasis(parent.provenance.runner_profile) != .distance or
        runner_profile.surface(parent.provenance.runner_profile) == .trail) return error.AdjustmentRoadDistanceOnly;
    const start = try date.parse(parent.workouts[0].date);
    const old_race = try date.parse(parent.race_date);
    if (date.compare(options.restart, start) != .gt or date.compare(options.restart, old_race) != .lt) return error.InvalidAdjustmentRestart;
    const observed = try interruption.observe(storage, parent, options.restart);
    const returned = try interruption.validateStage(storage, parent.*, options.restart, options.stage, observed);
    var output = parent.*;
    output.effective_from = try date.format(allocator, options.restart);
    var context: provenance.Adjustment = .{
        .restart_date = output.effective_from,
        .interruption_start = try date.format(allocator, observed.first),
        .skipped_workouts = observed.skipped,
        .ready_to_resume = options.ready,
        .observed_weekly_km = observed.weekly_km,
        .observed_peak_weekly_km = observed.peak_weekly_km,
        .observed_long_run_km = observed.long_km,
        .race_date_choice = @tagName(choice),
        .parent = parent,
        .stage = options.stage,
        .base_weeks = if (options.stage == .base) options.base_weeks else 0,
        .repeat_source_week = observed.repeat_week,
        .repeat_weekly_km = observed.repeat_km,
        .repeat_long_run_km = observed.repeat_long_km,
        .familiar_easy_km = observed.easy_km,
        .returned_weekly_km = if (returned) |week| week.weekly_km else null,
        .returned_long_run_km = if (returned) |week| week.long_km else null,
        .recovery_rounding = .source_half_km,
    };
    const race = switch (choice) {
        .flexible => try targeted.flexibleDate(parent.*, context),
        .keep => old_race,
        .change => options.race_date.?,
    };
    output.race_date = try date.format(allocator, race);
    output.reason = try std.fmt.allocPrint(allocator, "Friel-inspired return after {d} sickness skips: aerobic return, repeat completed source week {d}, then resume its progression. Stage: {s}. Future stages require the runner's response; the target date is a projection, not a recovery prediction.", .{ observed.skipped, observed.repeat_week, @tagName(options.stage) });
    output.provenance.runner_profile.goal.race_date = .{
        .value = output.race_date,
        .source = switch (choice) {
            .flexible => .derived,
            .keep => parent.provenance.runner_profile.goal.race_date.source,
            .change => .user_entered,
        },
    };
    const plan = try targeted.build(allocator, parent.*, context, race);
    context.week_changes = plan.changes;
    context.omitted_source_weeks = plan.omitted;
    output.provenance.adjustment = context;
    output.workouts = plan.workouts;
    output.weeks = plan.weeks;
    try revision.validate(storage, output);
    try validator.validateStoredAdjustment(allocator, storage, output);
    _ = try validator.validateEmbedded(allocator, output);
    return output;
}
