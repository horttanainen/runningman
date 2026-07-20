const std = @import("std");
const date = @import("date.zig");
const runner_profile = @import("runner_profile.zig");
const training_policy = @import("training_policy.zig");

const Io = std.Io;

pub const Confidence = enum {
    unavailable,
    low,
    moderate,
    high,
};

pub const Feasibility = enum {
    completion,
    recommended,
    supported,
    aspirational,
    infeasible,
};

pub const Assessment = struct {
    plan_days: u16,
    plan_weeks: u8,
    sustainable_weekly_distance_km: f64,
    long_run_capacity_km: f64,
    primary_performance_index: ?usize,
    primary_performance_age_days: ?u16,
    current_half_marathon_estimate_seconds: ?u32,
    supported_fast_seconds: ?u32,
    supported_slow_seconds: ?u32,
    planner_recommended_target_seconds: ?u32,
    requested_target_seconds: ?u32,
    training_pace_anchor_seconds: ?u32,
    expected_shortfall_seconds: ?u32,
    projected_improvement_fraction: f64,
    estimate_uncertainty_fraction: f64,
    confidence: Confidence,
    feasibility: Feasibility,
    conflicting_performances: bool,
    reduced_projection: bool,
};

const Candidate = struct {
    index: usize,
    age_days: u16,
    equivalent_seconds: f64,
    score: u32,
};

pub fn assess(
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
) !Assessment {
    const profile_summary = try runner_profile.validate(profile);
    if (profile.goal.race_distance.value != policy.support.race_distance) {
        return error.ProfileOutsidePolicyScope;
    }
    if (profile_summary.plan_days < policy.support.minimum_plan_days or
        profile_summary.plan_days > policy.support.maximum_plan_days or
        profile_summary.core_running_days <
            policy.support.minimum_core_running_days or
        profile_summary.core_running_days >
            policy.support.maximum_core_running_days)
    {
        return error.ProfileOutsidePolicyScope;
    }

    const plan_start = try date.parse(profile.plan_start_date.value);
    const candidate = selectPrimaryPerformance(profile, policy, plan_start);
    const plan_weeks: u8 = @intCast(profile_summary.plan_days / 7);

    var result: Assessment = .{
        .plan_days = profile_summary.plan_days,
        .plan_weeks = plan_weeks,
        .sustainable_weekly_distance_km = profile.baseline.average_weekly_distance_km.value,
        .long_run_capacity_km = profile.baseline.longest_run_km.value,
        .primary_performance_index = null,
        .primary_performance_age_days = null,
        .current_half_marathon_estimate_seconds = null,
        .supported_fast_seconds = null,
        .supported_slow_seconds = null,
        .planner_recommended_target_seconds = null,
        .requested_target_seconds = if (profile.goal.target_time_seconds) |target|
            target.value
        else
            null,
        .training_pace_anchor_seconds = null,
        .expected_shortfall_seconds = null,
        .projected_improvement_fraction = 0,
        .estimate_uncertainty_fraction = 0,
        .confidence = .unavailable,
        .feasibility = .completion,
        .conflicting_performances = false,
        .reduced_projection = false,
    };

    if (candidate == null) {
        if (result.requested_target_seconds != null) {
            result.feasibility = .aspirational;
        }
        return result;
    }

    const primary = candidate.?;
    const performance = profile.baseline.recent_performances.value[primary.index];
    const conflicting = hasConflictingPerformances(
        profile,
        policy,
        plan_start,
        primary.equivalent_seconds,
    );
    const uncertainty = estimateUncertainty(
        performance,
        primary.age_days,
        conflicting,
        policy.baseline_assessment,
    );
    const projection = projectedImprovement(profile, policy, plan_weeks);
    const current_estimate = secondsFromFloat(primary.equivalent_seconds);
    const supported_fast = secondsFromFloat(
        primary.equivalent_seconds *
            (1 - uncertainty) *
            (1 - projection.fraction),
    );
    const supported_slow = secondsFromFloat(
        primary.equivalent_seconds * (1 + uncertainty),
    );
    const central_target = recommendedTarget(
        profile.goal.intent.value,
        current_estimate,
        supported_slow,
        policy.baseline_assessment.target_rounding_seconds,
    );

    result.primary_performance_index = primary.index;
    result.primary_performance_age_days = primary.age_days;
    result.current_half_marathon_estimate_seconds = current_estimate;
    result.supported_fast_seconds = supported_fast;
    result.supported_slow_seconds = supported_slow;
    result.planner_recommended_target_seconds = central_target;
    result.projected_improvement_fraction = projection.fraction;
    result.estimate_uncertainty_fraction = uncertainty;
    result.conflicting_performances = conflicting;
    result.reduced_projection = projection.reduced;
    result.confidence = estimateConfidence(
        profile,
        performance,
        primary.age_days,
        conflicting,
        policy,
    );

    if (result.requested_target_seconds == null) {
        result.feasibility = .recommended;
        result.training_pace_anchor_seconds = central_target;
        return result;
    }

    const requested = result.requested_target_seconds.?;
    if (requested >= supported_fast) {
        result.feasibility = .supported;
        result.training_pace_anchor_seconds = requested;
        return result;
    }

    result.training_pace_anchor_seconds = central_target;
    result.expected_shortfall_seconds = supported_fast - requested;
    const gap_fraction = @as(f64, @floatFromInt(supported_fast - requested)) /
        @as(f64, @floatFromInt(supported_fast));
    if (gap_fraction <= policy.baseline_assessment.aspirational_gap_limit_fraction) {
        result.feasibility = .aspirational;
        return result;
    }

    result.feasibility = .infeasible;
    return result;
}

pub fn print(
    writer: *Io.Writer,
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    result: Assessment,
) !void {
    try writer.print(
        "Half-marathon assessment: {s}\n" ++
            "Policy: {s} version {d}\n" ++
            "Plan window: {d} days ({d} complete weeks)\n\n" ++
            "Baseline\n" ++
            "  Sustainable weekly volume: {d:.1} km\n" ++
            "  Current long-run capacity: {d:.1} km\n",
        .{
            profile.profile_id,
            policy.policy_id,
            policy.policy_version,
            result.plan_days,
            result.plan_weeks,
            result.sustainable_weekly_distance_km,
            result.long_run_capacity_km,
        },
    );

    if (result.primary_performance_index == null) {
        try writer.writeAll(
            "  Performance estimate: unavailable\n" ++
                "  Reason: no hard or maximal 5K, 10K, or half-marathon result " ++
                "inside the policy's recency window\n\n",
        );
        try printTarget(writer, profile, result);
        try printEffortGuidance(writer, policy, result);
        try printPolicyBasis(writer, policy);
        return;
    }

    const performance =
        profile.baseline.recent_performances.value[result.primary_performance_index.?];
    try writer.print("  Primary performance: {s} {s} in ", .{
        performance.date,
        performanceName(performance.distance),
    });
    try printDuration(writer, performance.duration_seconds);
    try writer.print(
        " ({s}, {s}, {d} days before plan start)\n" ++
            "  Current half-marathon equivalent: ",
        .{
            @tagName(performance.kind),
            @tagName(performance.effort),
            result.primary_performance_age_days.?,
        },
    );
    try printDuration(writer, result.current_half_marathon_estimate_seconds.?);
    try writer.print(
        "\n  Estimate uncertainty: ±{d:.1}%\n" ++
            "  Bounded training improvement assumption: up to {d:.1}%{s}\n" ++
            "  Supported race-date outcome range: ",
        .{
            result.estimate_uncertainty_fraction * 100,
            result.projected_improvement_fraction * 100,
            if (result.reduced_projection)
                " (reduced by baseline readiness)"
            else
                "",
        },
    );
    try printDuration(writer, result.supported_fast_seconds.?);
    try writer.writeAll("–");
    try printDuration(writer, result.supported_slow_seconds.?);
    try writer.print(
        "\n  Confidence: {s}\n",
        .{@tagName(result.confidence)},
    );
    if (result.conflicting_performances) {
        try writer.writeAll(
            "  Confidence note: other eligible results differ beyond the " ++
                "policy threshold\n",
        );
    }
    if (profile.baseline.weekly_distance_history_km == null) {
        try writer.writeAll(
            "  Confidence note: weekly distance history is missing\n",
        );
    }
    try writer.writeByte('\n');

    try printTarget(writer, profile, result);
    try printEffortGuidance(writer, policy, result);
    try printPolicyBasis(writer, policy);
}

fn printTarget(
    writer: *Io.Writer,
    profile: runner_profile.RunnerProfile,
    result: Assessment,
) !void {
    try writer.writeAll("Target assessment\n");
    if (result.requested_target_seconds) |requested| {
        try writer.writeAll("  Requested target: ");
        try printDuration(writer, requested);
        try writer.writeByte('\n');
    } else {
        try writer.writeAll("  Requested target: none\n");
    }

    if (result.planner_recommended_target_seconds) |recommended| {
        try writer.writeAll("  Planner recommendation: ");
        try printDuration(writer, recommended);
        try writer.writeByte('\n');
    } else {
        try writer.writeAll(
            "  Planner recommendation: completion goal until a recent hard " ++
                "performance is available\n",
        );
    }
    try writer.print(
        "  Classification: {s}\n",
        .{@tagName(result.feasibility)},
    );

    switch (result.feasibility) {
        .completion => try writer.writeAll(
            "  Explanation: a numeric target would create false precision " ++
                "from the available baseline.\n",
        ),
        .recommended => try writer.writeAll(
            "  Explanation: no target was supplied; the recommendation is " ++
                "rounded from the supported current estimate.\n",
        ),
        .supported => try writer.writeAll(
            "  Explanation: the requested time is no faster than the " ++
                "policy-supported race-date boundary.\n",
        ),
        .aspirational => {
            if (result.current_half_marathon_estimate_seconds == null) {
                try writer.writeAll(
                    "  Explanation: the requested time lacks supporting " ++
                        "performance evidence and remains aspirational.\n",
                );
            } else {
                try writer.writeAll(
                    "  Explanation: the requested time is faster than the " ++
                        "supported range but within the aspirational margin.\n",
                );
            }
        },
        .infeasible => {
            try writer.writeAll(
                "  Explanation: the requested time is beyond the strongest " ++
                    "outcome supported by this profile and policy.\n",
            );
            try writer.writeAll("  Expected shortfall from requested target: ");
            try printDuration(writer, result.expected_shortfall_seconds.?);
            try writer.writeByte('\n');
        },
    }
    try writer.writeByte('\n');

    _ = profile;
}

fn printEffortGuidance(
    writer: *Io.Writer,
    policy: training_policy.Policy,
    result: Assessment,
) !void {
    try writer.writeAll("Training anchors\n");
    try writer.print(
        "  Easy effort: {s}\n" ++
            "  Quality effort: {s}\n",
        .{
            policy.intensity_distribution.easy_effort_guidance,
            policy.intensity_distribution.quality_effort_guidance,
        },
    );
    if (result.training_pace_anchor_seconds) |anchor| {
        const pace_seconds = @as(f64, @floatFromInt(anchor)) /
            policy.support.race_distance_km;
        const pace = secondsFromFloat(pace_seconds);
        try writer.writeAll("  Supported half-marathon pace anchor: ");
        try printPace(writer, pace);
        try writer.writeAll("/km\n  Indicative easy pace: ");
        try printPace(
            writer,
            pace +
                policy.baseline_assessment.easy_pace_minimum_seconds_slower_per_km,
        );
        try writer.writeAll("–");
        try printPace(
            writer,
            pace +
                policy.baseline_assessment.easy_pace_maximum_seconds_slower_per_km,
        );
        try writer.writeAll("/km\n");
        if (result.feasibility == .aspirational or result.feasibility == .infeasible) {
            try writer.writeAll(
                "  Aspirational pace is not used as the training anchor.\n",
            );
        }
    } else {
        try writer.writeAll(
            "  Pace guidance: effort-only until a supported performance " ++
                "estimate is available\n",
        );
    }
    try writer.writeByte('\n');
}

fn printPolicyBasis(
    writer: *Io.Writer,
    policy: training_policy.Policy,
) !void {
    try writer.writeAll("Policy basis\n");
    const rule_ids = [_][]const u8{ "BASE-01", "TARGET-01", "INT-01" };
    for (rule_ids) |rule_id| {
        const rule = training_policy.findRule(policy, rule_id) orelse
            return error.MissingAssessmentPolicyRule;
        try writer.print("  {s}: {s}\n", .{ rule.rule_id, rule.summary });
    }
    try writer.writeAll(
        "\nThis command only assesses the profile. It does not generate or apply a schedule.\n",
    );
}

fn selectPrimaryPerformance(
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    plan_start: date.Date,
) ?Candidate {
    var selected: ?Candidate = null;
    for (profile.baseline.recent_performances.value, 0..) |performance, index| {
        const candidate = makeCandidate(
            performance,
            index,
            policy,
            plan_start,
        ) orelse continue;
        if (selected == null or candidate.score > selected.?.score) {
            selected = candidate;
        }
    }
    return selected;
}

fn makeCandidate(
    performance: runner_profile.RecentPerformance,
    index: usize,
    policy: training_policy.Policy,
    plan_start: date.Date,
) ?Candidate {
    if (performance.effort != .hard and performance.effort != .maximal) {
        return null;
    }
    const performance_date = date.parse(performance.date) catch return null;
    const age_days_signed = date.daysBetween(performance_date, plan_start);
    if (age_days_signed < 0 or
        age_days_signed > policy.baseline_assessment.maximum_performance_age_days)
    {
        return null;
    }
    const age_days: u16 = @intCast(age_days_signed);
    const source_distance_km = performanceDistanceKm(performance.distance);
    const ratio = policy.support.race_distance_km / source_distance_km;
    const equivalent = @as(f64, @floatFromInt(performance.duration_seconds)) *
        std.math.pow(f64, ratio, policy.baseline_assessment.race_equivalence_exponent);
    return .{
        .index = index,
        .age_days = age_days,
        .equivalent_seconds = equivalent,
        .score = performanceScore(performance, age_days, policy),
    };
}

fn performanceScore(
    performance: runner_profile.RecentPerformance,
    age_days: u16,
    policy: training_policy.Policy,
) u32 {
    const distance_score: u32 = switch (performance.distance) {
        .five_km => 100_000,
        .ten_km => 200_000,
        .half_marathon => 300_000,
    };
    const effort_score: u32 = switch (performance.effort) {
        .maximal => 20_000,
        .hard => 10_000,
        else => 0,
    };
    const kind_score: u32 = switch (performance.kind) {
        .race => 2_000,
        .time_trial => 1_000,
        .training => 0,
    };
    const recency_score: u32 =
        policy.baseline_assessment.maximum_performance_age_days - age_days;
    return distance_score + effort_score + kind_score + recency_score;
}

fn hasConflictingPerformances(
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    plan_start: date.Date,
    primary_equivalent_seconds: f64,
) bool {
    for (profile.baseline.recent_performances.value, 0..) |performance, index| {
        const candidate = makeCandidate(
            performance,
            index,
            policy,
            plan_start,
        ) orelse continue;
        const difference = @abs(
            candidate.equivalent_seconds - primary_equivalent_seconds,
        ) / primary_equivalent_seconds;
        if (difference >
            policy.baseline_assessment.conflicting_result_threshold_fraction)
        {
            return true;
        }
    }
    return false;
}

fn estimateUncertainty(
    performance: runner_profile.RecentPerformance,
    age_days: u16,
    conflicting: bool,
    policy: training_policy.BaselineAssessment,
) f64 {
    var uncertainty = switch (performance.distance) {
        .five_km => policy.five_km_uncertainty_fraction,
        .ten_km => policy.ten_km_uncertainty_fraction,
        .half_marathon => policy.half_marathon_uncertainty_fraction,
    };
    if (performance.effort == .hard) {
        uncertainty += policy.hard_effort_extra_uncertainty_fraction;
    }
    if (performance.kind == .training) {
        uncertainty += policy.training_result_extra_uncertainty_fraction;
    }
    if (age_days > policy.high_confidence_performance_age_days) {
        uncertainty += policy.old_result_extra_uncertainty_fraction;
    }
    if (conflicting) {
        uncertainty += policy.old_result_extra_uncertainty_fraction;
    }
    return @min(uncertainty, 0.25);
}

const Projection = struct {
    fraction: f64,
    reduced: bool,
};

fn projectedImprovement(
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    plan_weeks: u8,
) Projection {
    var fraction = @min(
        policy.baseline_assessment.maximum_projected_improvement_fraction,
        @as(f64, @floatFromInt(plan_weeks)) *
            policy.baseline_assessment.projected_improvement_per_week_fraction,
    );
    const reduced =
        profile.baseline.average_weekly_distance_km.value <
        policy.baseline_assessment.full_projection_minimum_weekly_distance_km or
        profile.baseline.longest_run_km.value <
            policy.baseline_assessment.full_projection_minimum_long_run_km or
        profile.constraints.recent_training_interruption_days.value >
            policy.baseline_assessment.full_projection_maximum_interruption_days;
    if (reduced) {
        fraction *=
            policy.baseline_assessment.reduced_readiness_improvement_multiplier;
    }
    return .{ .fraction = fraction, .reduced = reduced };
}

fn estimateConfidence(
    profile: runner_profile.RunnerProfile,
    performance: runner_profile.RecentPerformance,
    age_days: u16,
    conflicting: bool,
    policy: training_policy.Policy,
) Confidence {
    var score: i8 = 3;
    if (performance.distance != .half_marathon) score -= 1;
    if (performance.effort != .maximal) score -= 1;
    if (performance.kind == .training) score -= 1;
    if (age_days >
        policy.baseline_assessment.high_confidence_performance_age_days)
    {
        score -= 1;
    }
    if (profile.baseline.weekly_distance_history_km == null) score -= 1;
    if (conflicting) score -= 1;
    if (profile.constraints.recent_training_interruption_days.value >
        policy.baseline_assessment.full_projection_maximum_interruption_days)
    {
        score -= 1;
    }
    if (score >= 3) return .high;
    if (score >= 1) return .moderate;
    return .low;
}

fn recommendedTarget(
    intent: runner_profile.GoalIntent,
    current_estimate: u32,
    supported_slow: u32,
    rounding_seconds: u16,
) u32 {
    const base = if (intent == .finish_comfortably)
        supported_slow
    else
        current_estimate;
    return roundUp(base, rounding_seconds);
}

fn roundUp(value: u32, increment: u16) u32 {
    const increment_u32: u32 = increment;
    return ((value + increment_u32 - 1) / increment_u32) * increment_u32;
}

fn secondsFromFloat(value: f64) u32 {
    return @intFromFloat(@round(value));
}

fn performanceDistanceKm(distance_value: runner_profile.PerformanceDistance) f64 {
    return switch (distance_value) {
        .five_km => 5,
        .ten_km => 10,
        .half_marathon => 21.0975,
    };
}

fn performanceName(distance_value: runner_profile.PerformanceDistance) []const u8 {
    return switch (distance_value) {
        .five_km => "5K",
        .ten_km => "10K",
        .half_marathon => "half marathon",
    };
}

fn printDuration(writer: *Io.Writer, total_seconds: u32) !void {
    const hours = total_seconds / 3600;
    const minutes = total_seconds % 3600 / 60;
    const seconds = total_seconds % 60;
    if (hours > 0) {
        try writer.print("{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds });
    } else {
        try writer.print("{d}:{d:0>2}", .{ minutes, seconds });
    }
}

fn printPace(writer: *Io.Writer, total_seconds: u32) !void {
    try writer.print(
        "{d}:{d:0>2}",
        .{ total_seconds / 60, total_seconds % 60 },
    );
}

fn parseTestProfile(allocator: std.mem.Allocator) !runner_profile.RunnerProfile {
    return std.json.parseFromSliceLeaky(
        runner_profile.RunnerProfile,
        allocator,
        @embedFile("../examples/runner-profile.json"),
        .{ .ignore_unknown_fields = false },
    );
}

fn parseTestPolicy(allocator: std.mem.Allocator) !training_policy.Policy {
    return std.json.parseFromSliceLeaky(
        training_policy.Policy,
        allocator,
        @embedFile("../policies/half-marathon-v1.json"),
        .{ .ignore_unknown_fields = false },
    );
}

test "recommends two hours from the example baseline without a requested target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const profile = try parseTestProfile(allocator);
    const policy = try parseTestPolicy(allocator);

    const result = try assess(profile, policy);
    try std.testing.expectEqual(Feasibility.recommended, result.feasibility);
    try std.testing.expectEqual(
        @as(?u32, 2 * 60 * 60),
        result.planner_recommended_target_seconds,
    );
    try std.testing.expectEqual(Confidence.moderate, result.confidence);
    try std.testing.expect(result.supported_fast_seconds.? < 2 * 60 * 60);
    try std.testing.expect(result.supported_slow_seconds.? > 2 * 60 * 60);
}

test "classifies supported aspirational and infeasible requested targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var profile = try parseTestProfile(allocator);
    const policy = try parseTestPolicy(allocator);

    profile.goal.target_time_seconds = .{
        .value = 2 * 60 * 60,
        .source = .user_entered,
    };
    var result = try assess(profile, policy);
    try std.testing.expectEqual(Feasibility.supported, result.feasibility);
    try std.testing.expectEqual(
        profile.goal.target_time_seconds.?.value,
        result.training_pace_anchor_seconds.?,
    );

    profile.goal.target_time_seconds.?.value = 105 * 60;
    result = try assess(profile, policy);
    try std.testing.expectEqual(Feasibility.aspirational, result.feasibility);
    try std.testing.expect(
        result.training_pace_anchor_seconds.? !=
            profile.goal.target_time_seconds.?.value,
    );

    profile.goal.target_time_seconds.?.value = 100 * 60;
    result = try assess(profile, policy);
    try std.testing.expectEqual(Feasibility.infeasible, result.feasibility);
    try std.testing.expect(result.expected_shortfall_seconds.? > 0);
}

test "keeps a numeric target unsupported when performance evidence is absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var profile = try parseTestProfile(allocator);
    const policy = try parseTestPolicy(allocator);
    profile.baseline.recent_performances.value = &.{};

    var result = try assess(profile, policy);
    try std.testing.expectEqual(Feasibility.completion, result.feasibility);
    try std.testing.expectEqual(Confidence.unavailable, result.confidence);
    try std.testing.expectEqual(
        @as(?u32, null),
        result.planner_recommended_target_seconds,
    );

    profile.goal.target_time_seconds = .{
        .value = 2 * 60 * 60,
        .source = .user_entered,
    };
    result = try assess(profile, policy);
    try std.testing.expectEqual(Feasibility.aspirational, result.feasibility);
    try std.testing.expectEqual(@as(?u32, null), result.training_pace_anchor_seconds);
}
