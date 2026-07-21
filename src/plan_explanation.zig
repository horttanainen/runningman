const std = @import("std");
const assessment = @import("assessment.zig");
const date = @import("date.zig");
const model = @import("model.zig");
const plan_provenance = @import("plan_provenance.zig");
const plan_revision = @import("plan_revision.zig");
const store = @import("store.zig");
const training_policy = @import("training_policy.zig");

const Io = std.Io;

pub fn printProposal(
    writer: *Io.Writer,
    revision: plan_revision.RevisionFile,
    target_date: ?date.Date,
) !void {
    try writer.print("Proposal explanation: schedule #{d}\n", .{revision.base_schedule_id});
    try printAssessment(writer, revision.provenance);
    if (target_date) |target| {
        const workout = proposalWorkoutForDate(revision.workouts, target) orelse
            return error.NoScheduleForDate;
        const week = weekForNumber(revision.weeks, weekNumber(revision.workouts[0].date, target));
        if (week) |value| try printWeek(writer, revision.provenance.training_policy, value);
        try printWorkout(writer, revision.provenance.training_policy, workout);
        return;
    }
    try printWeeks(writer, revision.provenance.training_policy, revision.weeks);
}

pub fn printSchedule(
    writer: *Io.Writer,
    storage: *const store.Store,
    schedule_value: model.Schedule,
    target_date: ?date.Date,
) !void {
    const provenance = schedule_value.plan_provenance orelse
        return error.PlanExplanationUnavailable;
    try writer.print("Schedule #{d} explanation\n", .{schedule_value.id});
    try printAssessment(writer, provenance);
    if (target_date) |target| {
        const planned = store.workoutForDate(storage, schedule_value.id, target) orelse
            return error.NoScheduleForDate;
        if (schedule_value.plan_weeks.len != 0) {
            const week = weekForNumber(schedule_value.plan_weeks, planned.week);
            if (week) |value| try printWeek(writer, provenance.training_policy, value);
        } else {
            try writer.writeAll(
                "Week derivation record: unavailable for this previously applied schedule; " ++
                    "the workout decision below was persisted.\n\n",
            );
        }
        try printStoredWorkout(writer, provenance.training_policy, planned);
        return;
    }
    if (schedule_value.plan_weeks.len != 0) {
        try printWeeks(writer, provenance.training_policy, schedule_value.plan_weeks);
    } else {
        try printDerivedWeeks(writer, storage, schedule_value, provenance.training_policy);
    }
}

fn printAssessment(writer: *Io.Writer, provenance: plan_provenance.PlanProvenance) !void {
    const profile = provenance.runner_profile;
    const result = try assessment.assess(profile, provenance.training_policy);
    try writer.print(
        "Planner inputs\n" ++
            "  Generator: {s}\n" ++
            "  Profile: {s} ({s})\n" ++
            "  Policy: {s} v{d} ({s})\n" ++
            "  Baseline volume: {d:.1} km/week ({s})\n" ++
            "  Longest run: {d:.1} km ({s})\n",
        .{
            provenance.generator_version,
            profile.profile_id,
            provenance.runner_profile_sha256,
            provenance.training_policy.policy_id,
            provenance.training_policy.policy_version,
            provenance.training_policy_sha256,
            profile.baseline.average_weekly_distance_km.value,
            @tagName(profile.baseline.average_weekly_distance_km.source),
            profile.baseline.longest_run_km.value,
            @tagName(profile.baseline.longest_run_km.source),
        },
    );
    if (result.primary_performance_index) |index| {
        const performance = profile.baseline.recent_performances.value[index];
        try writer.print("  Primary performance: {s} on {s} in ", .{
            @tagName(performance.distance),
            performance.date,
        });
        try printDuration(writer, performance.duration_seconds);
        try writer.print(" ({s}, {s})\n", .{
            @tagName(performance.kind),
            @tagName(profile.baseline.recent_performances.source),
        });
    } else {
        try writer.writeAll("  Primary performance: unavailable\n");
    }

    try writer.print("\nTarget assessment\n  Confidence: {s}\n  Feasibility: {s}\n", .{
        @tagName(result.confidence),
        @tagName(result.feasibility),
    });
    try printOptionalDuration(writer, "  Current half-marathon equivalent: ", result.current_half_marathon_estimate_seconds);
    if (result.supported_fast_seconds != null and result.supported_slow_seconds != null) {
        try writer.writeAll("  Supported race-date range: ");
        try printDuration(writer, result.supported_fast_seconds.?);
        try writer.writeAll("–");
        try printDuration(writer, result.supported_slow_seconds.?);
        try writer.writeByte('\n');
    }
    try printOptionalDuration(writer, "  Requested target: ", result.requested_target_seconds);
    try printOptionalDuration(writer, "  Planner recommendation: ", result.planner_recommended_target_seconds);
    try printOptionalDuration(writer, "  Training pace anchor: ", result.training_pace_anchor_seconds);
    try printOptionalDuration(writer, "  Expected shortfall: ", result.expected_shortfall_seconds);
    try writer.writeByte('\n');
}

fn printWeeks(
    writer: *Io.Writer,
    policy: training_policy.Policy,
    weeks: []const plan_provenance.PlanWeek,
) !void {
    try writer.writeAll("Macrocycle explanation\n");
    for (weeks) |week| try printWeek(writer, policy, week);
}

fn printWeek(
    writer: *Io.Writer,
    policy: training_policy.Policy,
    week: plan_provenance.PlanWeek,
) !void {
    const decision = week.decision;
    try writer.print(
        "  Week {d} ({s}–{s}): {s}, {d:.1} km core, {d:.1} km long run\n" ++
            "    Purpose: {s}\n" ++
            "    Volume method: {s}",
        .{
            week.week,
            week.start_date,
            week.end_date,
            week.phase,
            week.target_core_distance_km,
            week.long_run_distance_km,
            phasePurpose(policy, week.phase),
            @tagName(decision.volume_method),
        },
    );
    if (decision.previous_progression_distance_km) |previous| {
        try writer.print(" from {d:.1} km", .{previous});
    }
    if (decision.applied_volume_fraction) |fraction| {
        try writer.print(" at {d:.0}%", .{fraction * 100});
    }
    try writer.print(
        "\n    Limits: peak {d:.1} km; long-run share {d:.1} km; progression {d:.1} km\n" ++
            "    Rules: {s}, {s}, {s}\n",
        .{
            decision.peak_volume_limit_km,
            decision.long_run_weekly_share_limit_km,
            decision.long_run_progression_limit_km,
            decision.periodization_rule_id,
            decision.volume_rule_id,
            decision.long_run_rule_id,
        },
    );
}

fn printDerivedWeeks(
    writer: *Io.Writer,
    storage: *const store.Store,
    schedule_value: model.Schedule,
    policy: training_policy.Policy,
) !void {
    try writer.writeAll(
        "Macrocycle explanation\n" ++
            "  Weekly derivation records were not persisted for this previously applied schedule.\n" ++
            "  The following targets are reconstructed from persisted workout decisions.\n",
    );
    const start = try date.parse(schedule_value.start_date);
    const race = try date.parse(schedule_value.race_date);
    var current = start;
    var previous_week: ?u8 = null;
    while (date.compare(current, race) != .gt) : (current = date.addDays(current, 1)) {
        const planned = store.workoutForDate(storage, schedule_value.id, current) orelse
            return error.IncompleteParentSchedule;
        if (previous_week != null and previous_week.? == planned.week) continue;
        previous_week = planned.week;
        const decision = planned.decision orelse return error.PlanWorkoutExplanationUnavailable;
        try writer.print(
            "  Week {d}: {s}, {d:.1} km core target\n" ++
                "    Purpose: {s}\n",
            .{
                planned.week,
                planned.phase,
                decision.week_target_core_distance_km,
                phasePurpose(policy, planned.phase),
            },
        );
    }
}

fn printStoredWorkout(
    writer: *Io.Writer,
    policy: training_policy.Policy,
    planned: model.Workout,
) !void {
    const proposed: plan_revision.ProposedWorkout = .{
        .date = planned.date,
        .phase = planned.phase,
        .kind = planned.kind,
        .intensity = planned.intensity,
        .details = planned.details,
        .distance_min_km = planned.distance_min_km,
        .distance_max_km = planned.distance_max_km,
        .segments = planned.segments,
        .decision = planned.decision,
    };
    try printWorkout(writer, policy, proposed);
}

fn printWorkout(
    writer: *Io.Writer,
    policy: training_policy.Policy,
    workout: plan_revision.ProposedWorkout,
) !void {
    const decision = workout.decision orelse return error.PlanWorkoutExplanationUnavailable;
    const recipe = findRecipe(policy, decision.recipe_id) orelse
        return error.GeneratedWorkoutRecipeNotFound;
    try writer.print(
        "Workout explanation\n" ++
            "  {s}: {s} ({s})\n" ++
            "  Prescription: {s}\n" ++
            "  Recipe: {s} — {s}\n" ++
            "  Allocation: {s}; {d:.1} km from a {d:.1} km core week using {s}\n" ++
            "  Pace method: {s}",
        .{
            workout.date,
            workout.kind,
            workout.phase,
            workout.details,
            recipe.recipe_id,
            recipe.description,
            @tagName(decision.allocation_role),
            decision.allocated_distance_km,
            decision.week_target_core_distance_km,
            @tagName(decision.distance_method),
            @tagName(decision.pace_method),
        },
    );
    if (decision.training_pace_anchor_seconds) |anchor| {
        try writer.writeAll(" from ");
        try printDuration(writer, anchor);
    }
    try writer.writeByte('\n');
    if (decision.preferred_weekday) |preferred| {
        try writer.print("  Scheduling: {s} preferred; {s} scheduled; preference {s}\n", .{
            @tagName(preferred),
            @tagName(decision.scheduled_weekday),
            if (decision.preference_honored orelse false) "honoured" else "not honoured",
        });
    } else {
        try writer.print("  Scheduling: {s}; no weekday preference applied\n", .{
            @tagName(decision.scheduled_weekday),
        });
    }
    try writer.writeAll("  Rules\n");
    for (decision.rule_ids) |rule_id| try printRule(writer, policy, rule_id);
}

fn printRule(writer: *Io.Writer, policy: training_policy.Policy, rule_id: []const u8) !void {
    const rule = training_policy.findRule(policy, rule_id) orelse
        return error.UnknownTrainingPolicyRuleReference;
    try writer.print("    {s}: {s}\n", .{ rule.rule_id, rule.summary });
    if (rule.evidence_ids.len != 0) {
        try writer.writeAll("      Evidence: ");
        for (rule.evidence_ids, 0..) |evidence_id, index| {
            if (index != 0) try writer.writeAll(", ");
            try writer.writeAll(evidence_id);
        }
        try writer.writeByte('\n');
    }
    if (rule.product_assumption.len != 0) {
        try writer.print("      Product assumption: {s}\n", .{rule.product_assumption});
    }
}

fn proposalWorkoutForDate(
    workouts: []const plan_revision.ProposedWorkout,
    target: date.Date,
) ?plan_revision.ProposedWorkout {
    for (workouts) |workout| {
        const candidate = date.parse(workout.date) catch continue;
        if (date.compare(candidate, target) == .eq) return workout;
    }
    return null;
}

fn weekForNumber(
    weeks: []const plan_provenance.PlanWeek,
    expected: u8,
) ?plan_provenance.PlanWeek {
    for (weeks) |week| {
        if (week.week == expected) return week;
    }
    return null;
}

fn weekNumber(start_text: []const u8, target: date.Date) u8 {
    const start = date.parse(start_text) catch return 0;
    return @intCast(@divFloor(date.daysBetween(start, target), 7) + 1);
}

fn phasePurpose(policy: training_policy.Policy, phase_id: []const u8) []const u8 {
    for (policy.periodization.phases) |phase| {
        if (std.mem.eql(u8, phase.phase_id, phase_id)) return phase.purpose;
    }
    return "Purpose unavailable in the embedded policy.";
}

fn findRecipe(policy: training_policy.Policy, recipe_id: []const u8) ?training_policy.WorkoutRecipe {
    for (policy.workout_recipes) |recipe| {
        if (std.mem.eql(u8, recipe.recipe_id, recipe_id)) return recipe;
    }
    return null;
}

fn printOptionalDuration(writer: *Io.Writer, label: []const u8, value: ?u32) !void {
    try writer.writeAll(label);
    if (value) |seconds| {
        try printDuration(writer, seconds);
    } else {
        try writer.writeAll("none");
    }
    try writer.writeByte('\n');
}

fn printDuration(writer: *Io.Writer, total_seconds: u32) !void {
    const hours = total_seconds / 3600;
    const minutes = total_seconds % 3600 / 60;
    const seconds = total_seconds % 60;
    try writer.print("{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds });
}
