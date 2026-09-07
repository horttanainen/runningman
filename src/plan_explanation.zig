const std = @import("std");
const assessment = @import("assessment.zig");
const date = @import("date.zig");
const model = @import("model.zig");
const plan_provenance = @import("plan_provenance.zig");
const plan_revision = @import("plan_revision.zig");
const store = @import("store.zig");
const training_policy = @import("training_policy.zig");
const interruption = @import("interruption.zig");
const targeted_adjustment = @import("targeted_adjustment.zig");

const Io = std.Io;

pub fn printProposal(
    writer: *Io.Writer,
    revision: plan_revision.RevisionFile,
    target_date: ?date.Date,
) !void {
    try writer.print("Proposal explanation: schedule #{d}\n", .{revision.base_schedule_id});
    try printAssessment(writer, revision.provenance);
    if (target_date) |target| {
        try printReturnStage(writer, revision.provenance, target);
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
    if (provenance.schema_version != 2 or
        provenance.training_policy.schema_version != 2 or
        schedule_value.plan_weeks.len == 0)
    {
        return error.PlanExplanationUnavailable;
    }
    try writer.print("Schedule #{d} explanation\n", .{schedule_value.id});
    try printAssessment(writer, provenance);
    if (target_date) |target| {
        try printReturnStage(writer, provenance, target);
        const planned = store.workoutForDate(storage, schedule_value.id, target) orelse
            return error.NoScheduleForDate;
        const week = weekForNumber(schedule_value.plan_weeks, planned.week) orelse
            return error.PlanExplanationUnavailable;
        try printWeek(writer, provenance.training_policy, week);
        try printStoredWorkout(writer, provenance.training_policy, planned);
        return;
    }
    try printWeeks(writer, provenance.training_policy, schedule_value.plan_weeks);
}

fn printAssessment(writer: *Io.Writer, provenance: plan_provenance.PlanProvenance) !void {
    const profile = provenance.runner_profile;
    const assessment_profile = if (provenance.adjustment) |context|
        (try interruption.originalPlan(context.parent)).provenance.runner_profile
    else
        profile;
    const result = try assessment.assess(assessment_profile, provenance.training_policy);
    if (provenance.adjustment) |context| {
        try writer.print("Friel-inspired return, current stage: {s}. Source-week decisions below are retained context.\nThe performance assessment uses the original plan inputs, not extra improvement inferred from the moved target date. Later stages require response confirmation.\n\n", .{@tagName(context.stage)});
    }
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

fn printReturnStage(writer: *Io.Writer, provenance: plan_provenance.PlanProvenance, target: date.Date) !void {
    const context = provenance.adjustment orelse return;
    const stage = (try targeted_adjustment.pendingStage(context, target)) orelse return;
    try writer.print("PROVISIONAL {s} stage: this prescription requires a response-confirmed adjustment before use.\n", .{@tagName(stage)});
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
    try writer.print("  Week {d} ({s}–{s}): {s}", .{
        week.week,
        week.start_date,
        week.end_date,
        week.phase,
    });
    if (week.target_core_duration_seconds) |duration_seconds| {
        try writer.print(", {d} minutes core", .{duration_seconds / 60});
        if (week.long_run_duration_seconds) |long_seconds| {
            try writer.print(", {d} minutes long run", .{long_seconds / 60});
        }
    } else {
        try writer.print(", {d:.1} km core, {d:.1} km long run", .{
            week.target_core_distance_km,
            week.long_run_distance_km,
        });
    }
    try writer.print("\n    Purpose: {s}", .{phasePurpose(policy, week.phase)});
    try writer.print(
        "; phase week {d} of {d}\n",
        .{
            decision.phase_week,
            decision.phase_week_count,
        },
    );
    try writer.print("    Volume method: {s}", .{@tagName(decision.volume_method)});
    if (decision.previous_progression_distance_km) |previous| {
        try writer.print(" from {d:.1} km", .{previous});
    }
    if (decision.applied_volume_fraction) |fraction| {
        try writer.print(" at {d:.0}%", .{fraction * 100});
    }
    if (decision.target_core_duration_seconds) |duration_seconds| {
        try writer.print("\n    Duration target: {d} minutes", .{duration_seconds / 60});
        if (decision.long_run_progression_limit_seconds) |limit_seconds| {
            try writer.print("; long-run progression limit {d} minutes", .{limit_seconds / 60});
        }
        try writer.writeByte('\n');
    } else {
        try writer.print(
            "\n    Limits: peak {d:.1} km; long-run share {d:.1} km; progression {d:.1} km\n",
            .{
                decision.peak_volume_limit_km,
                decision.long_run_weekly_share_limit_km,
                decision.long_run_progression_limit_km,
            },
        );
    }
    try writer.print("    Rules: {s}, {s}, {s}\n", .{
        decision.periodization_rule_id,
        decision.volume_rule_id,
        decision.long_run_rule_id,
    });
    if (week.target_ascent_meters) |ascent| {
        try writer.print("    Vertical target: {d} m ascent", .{ascent});
        if (week.long_run_ascent_meters) |long_ascent| {
            try writer.print("; long run {d} m", .{long_ascent});
        }
        if (decision.previous_ascent_meters) |previous| {
            try writer.print("; previous week {d} m", .{previous});
        }
        if (decision.ascent_progression_limit_meters) |limit| {
            try writer.print("; progression limit {d} m", .{limit});
        }
        try writer.writeByte('\n');
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
        .terrain = planned.terrain,
        .ascent_meters = planned.ascent_meters,
        .descent_meters = planned.descent_meters,
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
            "  Allocation: {s}; ",
        .{
            workout.date,
            workout.kind,
            workout.phase,
            workout.details,
            recipe.recipe_id,
            recipe.description,
            @tagName(decision.allocation_role),
        },
    );
    if (decision.allocated_duration_seconds) |duration_seconds| {
        try writer.print("{d} minutes", .{duration_seconds / 60});
        if (decision.week_target_core_duration_seconds) |week_seconds| {
            try writer.print(" from a {d} minute core week", .{week_seconds / 60});
        }
    } else {
        try writer.print("{d:.1} km from a {d:.1} km core week", .{
            decision.allocated_distance_km,
            decision.week_target_core_distance_km,
        });
    }
    try writer.print(" using {s}\n  Pace method: {s}", .{
        @tagName(decision.distance_method),
        @tagName(decision.pace_method),
    });
    if (decision.training_pace_anchor_seconds) |anchor| {
        try writer.writeAll(" from ");
        try printDuration(writer, anchor);
    }
    try writer.writeByte('\n');
    if (decision.terrain) |terrain| {
        try writer.print("  Terrain: {s}", .{@tagName(terrain)});
        if (decision.planned_ascent_meters) |ascent| try writer.print("; {d} m ascent", .{ascent});
        if (decision.planned_descent_meters) |descent| try writer.print("; {d} m descent", .{descent});
        try writer.writeByte('\n');
    }
    if (decision.quality_progression) |quality| {
        try writer.print("  Quality progression: {s}; {s}; phase week {d} of {d}; ", .{
            quality.stage_id,
            @tagName(quality.load_method),
            quality.phase_week,
            quality.phase_week_count,
        });
        if (quality.work_duration_seconds) |work_seconds| {
            try writer.print("{d} minutes work", .{work_seconds / 60});
            if (quality.previous_work_duration_seconds) |previous| {
                const change = @as(i64, work_seconds) - @as(i64, previous);
                try writer.print(" ({d} seconds from the previous quality session)", .{change});
            }
        } else {
            try writer.print("{d:.1} km work", .{quality.work_distance_km});
        }
        if (quality.previous_work_distance_km) |previous| {
            const change = quality.work_distance_km - previous;
            if (change >= 0) {
                try writer.print(
                    " (+{d:.1} km from the previous quality session)",
                    .{change},
                );
            } else {
                try writer.print(
                    " ({d:.1} km from the previous quality session)",
                    .{change},
                );
            }
        }
        if (quality.repetition_distance_km) |repetition_km| {
            try writer.print(
                "; {d} × {d:.1} km",
                .{ quality.repetitions, repetition_km },
            );
            if (quality.recovery_seconds) |recovery_seconds| {
                try writer.print(
                    " with {d}:{d:0>2} recovery",
                    .{ recovery_seconds / 60, recovery_seconds % 60 },
                );
            }
        } else {
            try writer.writeAll("; continuous work");
        }
        try writer.writeByte('\n');
    }
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
