const std = @import("std");
const assessment = @import("assessment.zig");
const date = @import("date.zig");
const model = @import("model.zig");
const plan_generator = @import("plan_generator.zig");
const plan_validator = @import("plan_validator.zig");
const provenance = @import("plan_provenance.zig");
const revision = @import("plan_revision.zig");
const runner_profile = @import("runner_profile.zig");
const training_policy = @import("training_policy.zig");
const interruption = @import("interruption.zig");

pub const Plan = struct {
    workouts: []const revision.ProposedWorkout,
    weeks: []const provenance.PlanWeek,
    changes: []const provenance.AdjustmentWeek,
    omitted: []const u8,
};

pub fn distance(value: revision.ProposedWorkout) f64 {
    var total: f64 = 0;
    for (value.segments) |segment| {
        total += (segment.distance_km orelse 0) * @as(f64, @floatFromInt(segment.repetitions));
    }
    return total;
}

pub fn movedWorkout(allocator: std.mem.Allocator, source: revision.ProposedWorkout, target_date: []const u8, fraction: f64, minimum_support_km: f64) !revision.ProposedWorkout {
    var output = source;
    output.date = target_date;
    if (fraction == 1 or std.mem.eql(u8, source.kind, "rest") or std.mem.eql(u8, source.kind, "race")) return output;
    const segments = try allocator.dupe(model.Segment, source.segments);
    for (segments) |*segment| {
        if (segment.distance_km) |km| segment.distance_km = km * fraction;
    }
    if (std.mem.eql(u8, source.kind, "quality")) {
        if (segments.len != 3 or segments[1].repetitions == 0) return error.GeneratedQualityProgressionDecisionInvalid;
        const warmup = @max(segments[0].distance_km orelse 0, minimum_support_km);
        const cooldown = @max(segments[2].distance_km orelse 0, minimum_support_km);
        const work = distance(source) * fraction - warmup - cooldown;
        if (work <= 0) return error.AdjustmentNoFeasibleCandidate;
        segments[0].distance_km = warmup;
        segments[2].distance_km = cooldown;
        segments[1].distance_km = work / @as(f64, @floatFromInt(segments[1].repetitions));
    }
    output.segments = segments;
    if (source.distance_min_km) |km| output.distance_min_km = km * fraction;
    if (source.distance_max_km) |km| output.distance_max_km = km * fraction;
    output.details = try std.fmt.allocPrint(allocator, "{s}: {d:.2} km. Original pace and session structure retained; distances shortened for this week's adjustment.", .{ source.kind, distance(output) });
    if (source.decision) |original| {
        var decision = original;
        decision.week_target_core_distance_km *= fraction;
        decision.allocated_distance_km *= fraction;
        if (decision.quality_progression) |*quality| {
            quality.work_distance_km = (segments[1].distance_km orelse 0) * @as(f64, @floatFromInt(segments[1].repetitions));
            if (quality.repetition_distance_km != null) quality.repetition_distance_km = segments[1].distance_km;
            // Previous work is source-plan context, not another scaled session
            // and not a claim about the runner's observed training.
        }
        output.decision = decision;
    }
    return output;
}

pub fn movedWeek(source: provenance.PlanWeek, index: usize, start: []const u8, end: []const u8, fraction: f64) provenance.PlanWeek {
    var output = source;
    output.week = @intCast(index + 1);
    output.start_date = start;
    output.end_date = end;
    output.target_core_distance_km *= fraction;
    output.long_run_distance_km *= fraction;
    if (fraction != 1) {
        // Baseline fields remain the original evidence. Other decision fields
        // describe the source week; the adjustment record explains the overlay.
        output.decision.long_run_weekly_share_limit_km *= fraction;
    }
    return output;
}

pub fn flexibleDate(parent: revision.RevisionFile, context: provenance.Adjustment) !date.Date {
    const original = try interruption.originalPlan(&parent);
    if (context.repeat_source_week == 0 or context.repeat_source_week >= original.weeks.len) return error.InvalidAdjustmentContext;
    const restart = try date.parse(context.restart_date);
    const monday = date.addDays(restart, -@as(i32, date.weekday(restart)));
    const source = @as(usize, context.repeat_source_week) - (if (context.stage == .continuation) @as(usize, 0) else 1);
    const source_start = try date.parse(original.weeks[source].start_date);
    const continuation_start = date.addDays(monday, @as(i32, context.base_weeks) * 7);
    return date.addDays(try date.parse(original.race_date), date.daysBetween(source_start, continuation_start));
}

pub const Sequence = struct {
    sources: []const usize,
    omitted: []const u8,
};

pub fn sequence(allocator: std.mem.Allocator, parent: revision.RevisionFile, context: provenance.Adjustment, race: date.Date) !Sequence {
    const original = try interruption.originalPlan(&parent);
    const natural = try flexibleDate(parent, context);
    const difference = date.daysBetween(race, natural);
    if (@mod(difference, 7) != 0) return error.AdjustmentRaceWeekdayChanged;
    if (difference < 0) return error.AdjustmentTargetBeyondContinuation;
    if (std.mem.eql(u8, context.race_date_choice, "flexible") and difference != 0) return error.InvalidAdjustmentContext;
    const first: usize = @as(usize, context.repeat_source_week) - (if (context.stage == .continuation) @as(usize, 0) else 1);
    if (first >= original.weeks.len) return error.InvalidAdjustmentContext;
    const keep = try allocator.alloc(bool, original.weeks.len);
    @memset(keep, true);
    var remove: usize = @intCast(@divExact(difference, 7));
    // Fixed-date compromise order is a product adaptation of Friel, not his
    // exact block taxonomy: later build weeks, recovery weeks, then early taper.
    // Never omit the repeated week, race-specific minimum, or final taper.
    for ([_][]const u8{ "build", "recovery", "taper" }) |phase| {
        var available_taper: usize = 0;
        for (original.weeks[first..]) |week| {
            if (std.mem.eql(u8, week.phase, "taper")) available_taper += 1;
        }
        for (0..original.weeks.len - first) |offset| {
            if (remove == 0) break;
            const index = if (std.mem.eql(u8, phase, "taper")) first + offset else original.weeks.len - 1 - offset;
            if (context.stage != .continuation and index == first) continue;
            if (!std.mem.eql(u8, original.weeks[index].phase, phase)) continue;
            if (std.mem.eql(u8, phase, "taper")) {
                const minimum: usize = (original.provenance.training_policy.taper.minimum_days + 6) / 7;
                if (available_taper <= minimum) continue;
                available_taper -= 1;
            }
            keep[index] = false;
            remove -= 1;
        }
    }
    if (remove != 0) return error.AdjustmentRaceDateTooClose;
    var sources: std.ArrayList(usize) = .empty;
    var omitted: std.ArrayList(u8) = .empty;
    for (first..original.weeks.len) |index| {
        if (!keep[index]) {
            try omitted.append(allocator, @intCast(index + 1));
            continue;
        }
        try sources.append(allocator, index);
    }
    return .{ .sources = try sources.toOwnedSlice(allocator), .omitted = try omitted.toOwnedSlice(allocator) };
}

pub fn baseWorkout(allocator: std.mem.Allocator, source: revision.ProposedWorkout, target: []const u8, km: f64, total: f64) !revision.ProposedWorkout {
    var output = source;
    output.date = target;
    output.phase = "foundation";
    const original_decision = source.decision orelse return error.RevisionWorkoutDecisionRequired;
    if (original_decision.allocation_role == .rest or original_decision.allocation_role == .optional_recovery) {
        output.kind = "rest";
        output.intensity = "None";
        output.distance_min_km = 0;
        output.distance_max_km = 0;
        output.segments = &.{.{ .kind = "rest", .label = "Rest" }};
        output.details = "Rest during the aerobic return stage; optional mileage is not required.";
        output.decision = .{
            .recipe_id = "rest-day",
            .rule_ids = &.{"SCHED-01"},
            .allocation_role = .rest,
            .distance_method = .none,
            .pace_method = .none,
            .week_target_core_distance_km = total,
            .allocated_distance_km = 0,
            .scheduled_weekday = original_decision.scheduled_weekday,
        };
        return output;
    }
    output.kind = "easy";
    output.intensity = "Low";
    output.distance_min_km = km;
    output.distance_max_km = km;
    output.details = try std.fmt.allocPrint(allocator, "Aerobic return: up to {d:.1} km at conversational effort, normally RPE 2-4. No pace target or hard finish. Shorten if effort is unusual. Remain in this stage until your usual effort/heart-rate/pace relationship and recovery return; the calendar alone does not advance you.", .{km});
    const segments = try allocator.alloc(model.Segment, 1);
    segments[0] = .{ .kind = "effort-distance", .label = "Easy aerobic return", .repetitions = 1, .distance_km = km, .notes = "Effort only; distance is a planning ceiling, not a required minimum." };
    output.segments = segments;
    output.decision = .{
        .recipe_id = "easy-distance",
        .rule_ids = &.{"INT-01"},
        .allocation_role = .easy,
        .distance_method = .weekly_remainder,
        .pace_method = .effort_only,
        .week_target_core_distance_km = total,
        .allocated_distance_km = km,
        .scheduled_weekday = original_decision.scheduled_weekday,
    };
    return output;
}

pub fn pendingStage(context: provenance.Adjustment, target: date.Date) !?provenance.ReturnStage {
    if (context.policy_version != 3) return null;
    const start = try date.parse(context.parent.workouts[0].date);
    if (date.compare(target, try date.parse(context.restart_date)) == .lt) return null;
    const week = @divFloor(date.daysBetween(start, target), 7) + 1;
    for (context.week_changes) |change| {
        if (change.week != week) continue;
        if (change.stage == context.stage or context.stage == .continuation) return null;
        return change.stage;
    }
    return null;
}

pub fn build(allocator: std.mem.Allocator, parent: revision.RevisionFile, context: provenance.Adjustment, race: date.Date) !Plan {
    const original = (try interruption.originalPlan(&parent)).*;
    const start = try date.parse(parent.workouts[0].date);
    const restart = try date.parse(context.restart_date);
    if (date.compare(race, restart) != .gt) return error.AdjustmentRaceDateTooClose;
    if (date.weekday(race) != date.weekday(try date.parse(original.race_date))) return error.AdjustmentRaceWeekdayChanged;
    const days: usize = @intCast(date.daysBetween(start, race) + 1);
    if (days > 168) return error.AdjustmentRaceDateTooFar;
    const selected = try sequence(allocator, parent, context, race);
    const workouts = try allocator.alloc(revision.ProposedWorkout, days);
    const weeks = try allocator.alloc(provenance.PlanWeek, (days + 6) / 7);
    const restart_index: usize = @intCast(@divFloor(date.daysBetween(start, restart), 7));
    if (restart_index + context.base_weeks + selected.sources.len != weeks.len) return error.InvalidAdjustmentContext;
    const changes = try allocator.alloc(provenance.AdjustmentWeek, weeks.len - restart_index);
    const policy = original.provenance.training_policy;
    const repeat_index: usize = context.repeat_source_week - 1;
    const repeat_source = original.weeks[repeat_index];
    var established_volume = @min(context.returned_weekly_km orelse context.repeat_weekly_km, repeat_source.target_core_distance_km);
    var established_long = @min(context.returned_long_run_km orelse context.repeat_long_run_km, repeat_source.long_run_distance_km);
    var pre_taper_peak = established_volume;
    var previous_volume = established_volume;
    var core_count: usize = 0;
    for (original.workouts[repeat_index * 7 .. repeat_index * 7 + 7]) |item| {
        const role = (item.decision orelse return error.RevisionWorkoutDecisionRequired).allocation_role;
        if (role != .rest and role != .optional_recovery) core_count += 1;
    }
    if (core_count == 0) return error.InvalidAdjustmentContext;
    const easy_km = @floor(@min(context.familiar_easy_km, context.observed_weekly_km / @as(f64, @floatFromInt(core_count))) * 10) / 10;
    if (easy_km <= 0) return error.AdjustmentBaselineIncomplete;
    const base_total = easy_km * @as(f64, @floatFromInt(core_count));
    for (weeks, 0..) |*week, index| {
        const first_day = index * 7;
        const last_day = @min(first_day + 6, days - 1);
        if (index < restart_index) {
            week.* = parent.weeks[index];
            @memcpy(workouts[first_day .. last_day + 1], parent.workouts[first_day .. last_day + 1]);
            continue;
        }
        const offset = index - restart_index;
        const is_base = offset < context.base_weeks;
        const source_index = if (is_base) repeat_index else selected.sources[offset - context.base_weeks];
        const source = original.weeks[source_index];
        const stage: provenance.ReturnStage = if (is_base) .base else if (context.stage != .continuation and source_index == repeat_index) .repeat else .continuation;
        const is_taper = std.mem.eql(u8, source.phase, "taper");
        const is_race = std.mem.eql(u8, source.phase, "race");
        var fraction: f64 = 1;
        var reason: []const u8 = "preserve source progression; conditional on successful repeated week";
        if (stage == .base) {
            reason = "easy-only aerobic return; duration is provisional, advance by response";
        } else if (stage == .repeat) {
            fraction = @min(fraction, context.repeat_weekly_km / source.target_core_distance_km);
            fraction = @min(fraction, context.repeat_long_run_km / source.long_run_distance_km);
            reason = "repeat last completed loading week; conditional on normal easy-running response";
        } else if (is_taper) {
            fraction = @min(fraction, pre_taper_peak * (1 - policy.taper.minimum_volume_reduction_fraction) / source.target_core_distance_km);
        } else if (!is_race) {
            var limit = established_volume * (1 + policy.volume_progression.maximum_build_increase_fraction);
            if (std.mem.eql(u8, source.phase, "recovery")) limit = previous_volume * policy.recovery.maximum_volume_fraction;
            fraction = @min(fraction, limit / source.target_core_distance_km);
            if (source.long_run_distance_km > 0) fraction = @min(fraction, (established_long + policy.long_run.maximum_weekly_increase_km) / source.long_run_distance_km);
        }
        if (!std.math.isFinite(fraction) or fraction <= 0) return error.AdjustmentNoFeasibleCandidate;
        if (fraction < 1) fraction = @floor(source.target_core_distance_km * fraction * 10) / 10 / source.target_core_distance_km;
        if (stage == .continuation and fraction < 1) reason = "preserve source phase and session structure; shorten to fit progression from the repeated week";
        changes[offset] = .{ .week = @intCast(index + 1), .source_week = @intCast(source_index + 1), .distance_fraction = fraction, .reason = reason, .stage = stage };
        for (first_day..last_day + 1) |day_index| {
            const target_date = date.addDays(start, @intCast(day_index));
            // A midweek return never rewrites the earlier prescriptions or logs.
            if (date.compare(target_date, restart) == .lt) {
                workouts[day_index] = parent.workouts[day_index];
                continue;
            }
            const original_index = source_index * 7 + day_index - first_day;
            if (original_index >= original.workouts.len) return error.AdjustmentRaceDateTooClose;
            const target = try date.format(allocator, target_date);
            workouts[day_index] = if (is_base)
                try baseWorkout(allocator, original.workouts[original_index], target, easy_km, base_total)
            else
                try movedWorkout(allocator, original.workouts[original_index], target, fraction, if (is_taper) policy.quality_progression.minimum_taper_warmup_cooldown_km else policy.quality_progression.minimum_warmup_cooldown_km);
        }
        week.* = movedWeek(source, index, workouts[first_day].date, workouts[last_day].date, fraction);
        if (is_base) {
            week.phase = "foundation";
            week.decision.volume_method = .aerobic_return;
            week.decision.phase_week = @intCast(offset + 1);
            week.decision.phase_week_count = context.base_weeks;
            week.decision.previous_progression_distance_km = null;
            week.decision.applied_volume_fraction = null;
            week.decision.recovery_rule_id = null;
            week.decision.taper_rule_id = null;
            week.decision.previous_long_run_distance_km = null;
            week.decision.long_run_weekly_share_limit_km = 0;
            week.decision.long_run_progression_limit_km = 0;
            week.target_core_distance_km = 0;
            week.long_run_distance_km = 0;
            for (workouts[first_day .. last_day + 1]) |item| {
                const role = item.decision.?.allocation_role;
                if (role != .optional_recovery) week.target_core_distance_km += distance(item);
                if (role == .long_run) week.long_run_distance_km += distance(item);
            }
            for (workouts[first_day .. last_day + 1]) |*item| {
                if (date.compare(try date.parse(item.date), restart) == .lt) continue;
                item.decision.?.week_target_core_distance_km = week.target_core_distance_km;
            }
            continue;
        }
        if (!is_taper and !is_race) {
            established_volume = @max(established_volume, week.target_core_distance_km);
            established_long = @max(established_long, week.long_run_distance_km);
            pre_taper_peak = @max(pre_taper_peak, week.target_core_distance_km);
            previous_volume = week.target_core_distance_km;
        }
    }
    return .{ .workouts = workouts, .weeks = weeks, .changes = changes, .omitted = selected.omitted };
}

fn testParent(allocator: std.mem.Allocator) !revision.RevisionFile {
    const profile = try std.json.parseFromSliceLeaky(runner_profile.RunnerProfile, allocator, @embedFile("../examples/runner-profile.json"), .{});
    const policy = try std.json.parseFromSliceLeaky(training_policy.Policy, allocator, @embedFile("../policies/half-marathon.json"), .{});
    return plan_generator.generate(allocator, profile, policy, try assessment.assess(profile, policy), policy.evidence_ledger_id, .{
        .runner_profile_sha256 = "a" ** 64,
        .training_policy_sha256 = "b" ** 64,
        .evidence_ledger_sha256 = "c" ** 64,
    }, 1);
}

fn testContext(parent: *const revision.RevisionFile) provenance.Adjustment {
    return .{
        .restart_date = "2026-09-07",
        .interruption_start = "2026-08-24",
        .skipped_workouts = 8,
        .ready_to_resume = true,
        .observed_weekly_km = 30.86,
        .observed_peak_weekly_km = 38.56,
        .observed_long_run_km = 15,
        .repeat_source_week = 4,
        .repeat_weekly_km = 38.56,
        .repeat_long_run_km = 15,
        .familiar_easy_km = 7.8,
        .race_date_choice = "flexible",
        .parent = parent,
    };
}

fn testProposal(allocator: std.mem.Allocator, context: provenance.Adjustment, race: date.Date) !revision.RevisionFile {
    var output = context.parent.*;
    output.effective_from = context.restart_date;
    output.race_date = try date.format(allocator, race);
    output.provenance.runner_profile.goal.race_date = .{
        .value = output.race_date,
        .source = if (std.mem.eql(u8, context.race_date_choice, "flexible")) .derived else context.parent.provenance.runner_profile.goal.race_date.source,
    };
    const plan = try build(allocator, context.parent.*, context, race);
    var recorded = context;
    recorded.week_changes = plan.changes;
    recorded.omitted_source_weeks = plan.omitted;
    output.provenance.adjustment = recorded;
    output.workouts = plan.workouts;
    output.weeks = plan.weeks;
    return output;
}

fn expectSameJson(allocator: std.mem.Allocator, expected: anytype, actual: @TypeOf(expected)) !void {
    try std.testing.expectEqualStrings(
        try std.json.Stringify.valueAlloc(allocator, expected, .{}),
        try std.json.Stringify.valueAlloc(allocator, actual, .{}),
    );
}

test "movable target preserves the full progression after aerobic return and completed loading week" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parent = try testParent(allocator);
    const context = testContext(&parent);
    const proposed = try testProposal(allocator, context, try flexibleDate(parent, context));
    _ = try plan_validator.validateEmbedded(allocator, proposed);
    try std.testing.expectEqualStrings("2026-11-22", proposed.race_date);
    try expectSameJson(allocator, parent.workouts[0..49], proposed.workouts[0..49]);
    try expectSameJson(allocator, parent.assessment, proposed.assessment);
    const changes = proposed.provenance.adjustment.?.week_changes;
    try std.testing.expectEqual(provenance.ReturnStage.base, changes[0].stage);
    try std.testing.expectEqual(provenance.ReturnStage.repeat, changes[1].stage);
    try std.testing.expectEqual(@as(usize, 0), proposed.provenance.adjustment.?.omitted_source_weeks.len);
    for (changes[1..], 0..) |change, i| try std.testing.expectEqual(@as(u8, @intCast(i + 4)), change.source_week);
    for (proposed.workouts[49..56]) |item| {
        try std.testing.expect(std.mem.eql(u8, item.kind, "easy") or std.mem.eql(u8, item.kind, "rest"));
        for (item.segments) |segment| {
            try std.testing.expect(segment.pace_fast_seconds_per_km == null);
            try std.testing.expect(segment.pace_slow_seconds_per_km == null);
        }
    }
    var race_workout = parent.workouts[parent.workouts.len - 1];
    race_workout.date = proposed.race_date;
    try expectSameJson(allocator, race_workout, proposed.workouts[proposed.workouts.len - 1]);
    try std.testing.expect((try pendingStage(proposed.provenance.adjustment.?, try date.parse("2026-09-07"))) == null);
    try std.testing.expectEqual(provenance.ReturnStage.repeat, (try pendingStage(proposed.provenance.adjustment.?, try date.parse("2026-09-14"))).?);
    try std.testing.expectEqual(provenance.ReturnStage.continuation, (try pendingStage(proposed.provenance.adjustment.?, try date.parse("2026-09-21"))).?);
}

test "base forecast length moves the target without changing the repeated prescriptions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parent = try testParent(allocator);
    var context = testContext(&parent);
    const one = try testProposal(allocator, context, try flexibleDate(parent, context));
    context.base_weeks = 2;
    const two = try testProposal(allocator, context, try flexibleDate(parent, context));
    _ = try plan_validator.validateEmbedded(allocator, two);
    try std.testing.expectEqualStrings("2026-11-29", two.race_date);
    try std.testing.expectEqual(one.weeks[8].target_core_distance_km, two.weeks[9].target_core_distance_km);
    try std.testing.expectEqual(@as(f64, 30), two.provenance.runner_profile.baseline.average_weekly_distance_km.value);
    for (two.weeks[7..]) |week| {
        try std.testing.expectEqual(@as(f64, 30), week.decision.baseline_weekly_distance_km);
        try std.testing.expectEqual(@as(f64, 15), week.decision.baseline_longest_run_km);
    }
}

test "fixed target explicitly omits source weeks but preserves specificity and a taper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parent = try testParent(allocator);
    var context = testContext(&parent);
    context.race_date_choice = "keep";
    const proposed = try testProposal(allocator, context, try date.parse(parent.race_date));
    _ = try plan_validator.validateEmbedded(allocator, proposed);
    try std.testing.expectEqualStrings(parent.race_date, proposed.race_date);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8, 11 }, proposed.provenance.adjustment.?.omitted_source_weeks);
    try std.testing.expectError(error.AdjustmentRaceDateTooClose, testProposal(allocator, context, try date.parse("2026-09-20")));
    try std.testing.expectError(error.AdjustmentRaceWeekdayChanged, testProposal(allocator, context, try date.parse("2026-10-17")));
}

test "midweek aerobic return preserves every earlier prescription" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parent = try testParent(allocator);
    var context = testContext(&parent);
    context.restart_date = "2026-09-09";
    const proposed = try testProposal(allocator, context, try flexibleDate(parent, context));
    _ = try plan_validator.validateEmbedded(allocator, proposed);
    try expectSameJson(allocator, parent.workouts[0..51], proposed.workouts[0..51]);
    for (proposed.workouts[51..56]) |item| try std.testing.expect(std.mem.eql(u8, item.kind, "easy") or std.mem.eql(u8, item.kind, "rest"));
}

test "subsequent stages use the original source weeks rather than the provisional calendar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parent = try testParent(allocator);
    var context = testContext(&parent);
    const base = try testProposal(allocator, context, try flexibleDate(parent, context));
    context.parent = &base;
    context.restart_date = "2026-09-14";
    context.stage = .repeat;
    context.base_weeks = 0;
    const repeated = try testProposal(allocator, context, try flexibleDate(base, context));
    _ = try plan_validator.validateEmbedded(allocator, repeated);
    try std.testing.expectEqualStrings(base.race_date, repeated.race_date);
    try std.testing.expect((try pendingStage(repeated.provenance.adjustment.?, try date.parse("2026-09-14"))) == null);
    context.parent = &repeated;
    context.restart_date = "2026-09-21";
    context.stage = .continuation;
    context.returned_weekly_km = 38;
    context.returned_long_run_km = 15;
    const continued = try testProposal(allocator, context, try flexibleDate(repeated, context));
    _ = try plan_validator.validateEmbedded(allocator, continued);
    try std.testing.expectEqualStrings(base.race_date, continued.race_date);
    try std.testing.expectEqual(@as(u8, 5), continued.provenance.adjustment.?.week_changes[0].source_week);
    try std.testing.expect((try pendingStage(continued.provenance.adjustment.?, try date.parse("2026-09-21"))) == null);
    context.returned_weekly_km = 30;
    context.returned_long_run_km = 12;
    const shorter = try testProposal(allocator, context, try flexibleDate(repeated, context));
    _ = try plan_validator.validateEmbedded(allocator, shorter);
    try std.testing.expect(shorter.weeks[9].target_core_distance_km < continued.weeks[9].target_core_distance_km);
    try std.testing.expect(shorter.weeks[9].target_core_distance_km <= 30 * 0.85);
}

test "validation rejects changed evidence race prescriptions mapping and old policies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parent = try testParent(allocator);
    const context = testContext(&parent);
    const original = try testProposal(allocator, context, try flexibleDate(parent, context));
    var proposed = original;
    proposed.provenance.runner_profile.baseline.longest_run_km.value = 7.2;
    try std.testing.expectError(error.InvalidAdjustmentContext, plan_validator.validateEmbedded(allocator, proposed));
    proposed = original;
    proposed.provenance.adjustment.?.policy_version = 2;
    try std.testing.expectError(error.SupersededAdjustment, plan_validator.validateEmbedded(allocator, proposed));
    proposed = original;
    proposed.provenance.adjustment.?.return_load_percent = 80;
    try std.testing.expectError(error.InvalidAdjustmentContext, plan_validator.validateEmbedded(allocator, proposed));
    proposed = original;
    const workouts = try allocator.dupe(revision.ProposedWorkout, proposed.workouts);
    workouts[workouts.len - 1].details = "Changed race";
    proposed.workouts = workouts;
    try std.testing.expectError(error.AdjustmentContinuationChanged, plan_validator.validateEmbedded(allocator, proposed));
}
