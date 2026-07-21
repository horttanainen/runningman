const std = @import("std");
const assessment = @import("assessment.zig");
const date = @import("date.zig");
const plan_provenance = @import("plan_provenance.zig");
const plan_revision = @import("plan_revision.zig");
const runner_profile = @import("runner_profile.zig");
const training_policy = @import("training_policy.zig");

const WeekSummary = struct {
    phase: []const u8,
    core_distance_km: f64,
    optional_distance_km: f64,
    long_distance_km: f64,
    demanding_distance_km: f64,
    quality_sessions: u8,
};

pub const ValidationReport = struct {
    weeks: usize,
    workouts: usize,
    policy_rules: usize,
};

pub fn validateEmbedded(
    allocator: std.mem.Allocator,
    revision: plan_revision.RevisionFile,
) !ValidationReport {
    const provenance = revision.provenance;
    try training_policy.validateSnapshot(provenance.training_policy);
    const result = try assessment.assess(
        provenance.runner_profile,
        provenance.training_policy,
    );
    try validate(
        allocator,
        provenance.runner_profile,
        provenance.training_policy,
        result,
        revision,
    );
    return .{
        .weeks = revision.weeks.len,
        .workouts = revision.workouts.len,
        .policy_rules = provenance.training_policy.rules.len,
    };
}

pub fn validate(
    allocator: std.mem.Allocator,
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    result: assessment.Assessment,
    revision: plan_revision.RevisionFile,
) !void {
    const profile_summary = try runner_profile.validate(profile);
    if (revision.schema_version != 2) return error.UnsupportedRevisionSchema;
    if (revision.workouts.len == 0 or
        !std.mem.eql(u8, revision.workouts[0].date, profile.plan_start_date.value))
    {
        return error.GeneratedPlanStartMismatch;
    }
    if (!std.mem.eql(u8, revision.race_date, profile.goal.race_date.value)) {
        return error.GeneratedRaceDateMismatch;
    }
    if (revision.workouts.len != profile_summary.plan_days) {
        return error.GeneratedPlanMissingDays;
    }

    const provenance = revision.provenance;
    if (provenance.schema_version != 1 or
        !std.mem.eql(u8, provenance.generator_version, plan_provenance.generator_version) or
        !plan_provenance.validSha256(provenance.runner_profile_sha256) or
        !plan_provenance.validSha256(provenance.training_policy_sha256) or
        !plan_provenance.validSha256(provenance.evidence_ledger_sha256) or
        !std.mem.eql(u8, provenance.evidence_ledger_id, policy.evidence_ledger_id) or
        !std.mem.eql(u8, provenance.runner_profile.profile_id, profile.profile_id) or
        !std.mem.eql(u8, provenance.training_policy.policy_id, policy.policy_id) or
        provenance.training_policy.policy_version != policy.policy_version)
    {
        return error.GeneratedPlanProvenanceMismatch;
    }

    const proposed_assessment = revision.assessment;
    if (!std.mem.eql(u8, proposed_assessment.profile_id, profile.profile_id) or
        !std.mem.eql(u8, proposed_assessment.policy_id, policy.policy_id) or
        proposed_assessment.policy_version != policy.policy_version or
        !std.mem.eql(u8, proposed_assessment.confidence, @tagName(result.confidence)) or
        !std.mem.eql(u8, proposed_assessment.feasibility, @tagName(result.feasibility)) or
        proposed_assessment.recommended_target_seconds != result.planner_recommended_target_seconds or
        proposed_assessment.requested_target_seconds != result.requested_target_seconds or
        proposed_assessment.training_pace_anchor_seconds != result.training_pace_anchor_seconds or
        proposed_assessment.expected_shortfall_seconds != result.expected_shortfall_seconds)
    {
        return error.GeneratedAssessmentMismatch;
    }
    if (!sameAssessment(provenance.assessment, proposed_assessment)) {
        return error.GeneratedPlanProvenanceMismatch;
    }

    const start = try date.parse(profile.plan_start_date.value);
    const race_date = try date.parse(profile.goal.race_date.value);
    var expected = start;
    var race_count: u8 = 0;
    var last_demanding: ?date.Date = null;
    var phase_stage: u8 = 0;

    const week_count = (revision.workouts.len + 6) / 7;
    const proposed_weeks = revision.weeks;
    if (proposed_weeks.len != week_count) return error.GeneratedWeeklySummaryCountMismatch;
    for (proposed_weeks, 0..) |week, index| {
        const decision = week.decision;
        const expected_start = date.addDays(start, @intCast(index * 7));
        const expected_end = date.addDays(
            start,
            @intCast(@min(index * 7 + 6, revision.workouts.len - 1)),
        );
        if (date.compare(try date.parse(week.start_date), expected_start) != .eq or
            date.compare(try date.parse(week.end_date), expected_end) != .eq)
        {
            return error.GeneratedWeeklySummaryDatesMismatch;
        }
        if (!std.mem.eql(u8, decision.periodization_rule_id, policy.periodization.rule_id) or
            !std.mem.eql(u8, decision.volume_rule_id, policy.volume_progression.rule_id) or
            !std.mem.eql(u8, decision.long_run_rule_id, policy.long_run.rule_id))
        {
            return error.GeneratedWeekDecisionMismatch;
        }
    }
    const weeks = try allocator.alloc(WeekSummary, week_count);
    @memset(weeks, .{
        .phase = "",
        .core_distance_km = 0,
        .optional_distance_km = 0,
        .long_distance_km = 0,
        .demanding_distance_km = 0,
        .quality_sessions = 0,
    });

    for (revision.workouts, 0..) |workout, day_index| {
        const workout_date = try date.parse(workout.date);
        if (date.compare(workout_date, expected) != .eq) {
            return error.GeneratedPlanDatesNotConsecutive;
        }
        expected = date.addDays(expected, 1);

        const week_index = day_index / 7;
        if (weeks[week_index].phase.len == 0) {
            weeks[week_index].phase = workout.phase;
            phase_stage = try advancePhase(phase_stage, workout.phase);
        } else if (!std.mem.eql(u8, weeks[week_index].phase, workout.phase)) {
            return error.GeneratedWeekHasMultiplePhases;
        }

        const is_race = std.mem.eql(u8, workout.kind, "race");
        const is_optional = std.mem.eql(u8, workout.kind, "optional-recovery");
        const is_running = !std.mem.eql(u8, workout.kind, "rest");
        if (is_race) {
            race_count += 1;
            if (date.compare(workout_date, race_date) != .eq) {
                return error.GeneratedRaceOnWrongDate;
            }
        }

        if (isUnavailable(profile, workout.date) and is_running) {
            return error.GeneratedWorkoutOnUnavailableDate;
        }
        const weekday: runner_profile.Weekday = @enumFromInt(date.weekday(workout_date));
        const decision = workout.decision orelse return error.GeneratedWorkoutNeedsDecision;
        if (decision.scheduled_weekday != weekday) {
            return error.GeneratedWorkoutDecisionWeekdayMismatch;
        }
        if (!validRecipe(policy, decision.recipe_id, workout.phase)) {
            return error.GeneratedWorkoutDecisionRecipeMismatch;
        }
        if (decision.rule_ids.len == 0 or !validRuleIds(policy, decision.rule_ids)) {
            return error.GeneratedWorkoutDecisionRuleMismatch;
        }
        if (is_running and !is_race and !is_optional and
            !containsWeekday(profile.availability.running_days.value, weekday))
        {
            return error.GeneratedWorkoutOutsideAvailability;
        }
        if (is_optional) {
            const optional_day = profile.availability.optional_recovery_day orelse
                return error.GeneratedOptionalRunWithoutOptionalDay;
            if (optional_day.value != weekday) {
                return error.GeneratedOptionalRunOnWrongDay;
            }
        }

        const distance_km = try workoutDistance(workout);
        if (@abs(decision.allocated_distance_km - distance_km) > 0.01) {
            return error.GeneratedWorkoutDecisionDistanceMismatch;
        }
        if (is_optional) {
            weeks[week_index].optional_distance_km += distance_km;
        } else {
            weeks[week_index].core_distance_km += distance_km;
        }
        if (std.mem.eql(u8, workout.kind, "long")) {
            weeks[week_index].long_distance_km += distance_km;
        }
        if (std.mem.eql(u8, workout.kind, "quality")) {
            weeks[week_index].quality_sessions += 1;
            weeks[week_index].demanding_distance_km += distance_km;
        }

        const demanding = std.mem.eql(u8, workout.kind, "quality") or
            std.mem.eql(u8, workout.kind, "long") or is_race;
        if (demanding) {
            if (last_demanding) |previous| {
                const gap = date.daysBetween(previous, workout_date) - 1;
                if (gap < policy.scheduling.minimum_easy_or_rest_days_between_demanding_sessions) {
                    return error.GeneratedDemandingSessionsTooClose;
                }
            }
            last_demanding = workout_date;
        }
    }

    if (race_count != 1) return error.GeneratedPlanNeedsOneRace;
    for (weeks, proposed_weeks, 0..) |week, proposed, index| {
        const decision = proposed.decision;
        if (proposed.week != index + 1 or
            !std.mem.eql(u8, proposed.phase, week.phase) or
            @abs(proposed.target_core_distance_km - week.core_distance_km) > 0.01 or
            @abs(proposed.long_run_distance_km - week.long_distance_km) > 0.01 or
            @abs(decision.baseline_weekly_distance_km -
                profile.baseline.average_weekly_distance_km.value) > 0.01)
        {
            return error.GeneratedWeeklySummaryMismatch;
        }
    }
    try validateWeeks(profile, policy, weeks);
}

fn validateWeeks(
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    weeks: []const WeekSummary,
) !void {
    var previous_progression_volume: ?f64 = null;
    var previous_long: ?f64 = null;
    var pre_taper_peak: f64 = 0;
    var foundation_weeks: u8 = 0;
    var race_specific_weeks: u8 = 0;
    var taper_weeks: u8 = 0;
    var build_weeks_since_recovery: u8 = 0;
    const maximum_peak = profile.baseline.average_weekly_distance_km.value *
        policy.volume_progression.maximum_peak_relative_to_baseline;

    for (weeks) |week| {
        if (std.mem.eql(u8, week.phase, "foundation")) foundation_weeks += 1;
        if (std.mem.eql(u8, week.phase, "race_specific")) race_specific_weeks += 1;
        if (std.mem.eql(u8, week.phase, "taper")) taper_weeks += 1;
        if (std.mem.eql(u8, week.phase, "build")) build_weeks_since_recovery += 1;
        if (week.quality_sessions > policy.intensity_distribution.maximum_quality_sessions_per_week) {
            return error.GeneratedTooManyQualitySessions;
        }
        if (week.optional_distance_km >
            week.core_distance_km * policy.optional_run.maximum_weekly_distance_fraction + 0.01)
        {
            return error.GeneratedOptionalRunTooLong;
        }

        const race_week = std.mem.eql(u8, week.phase, "race");
        if (!race_week and week.core_distance_km > 0) {
            const low_fraction = 1 - week.demanding_distance_km / week.core_distance_km;
            if (low_fraction + 0.01 < policy.intensity_distribution.minimum_low_intensity_fraction or
                low_fraction - 0.01 > policy.intensity_distribution.maximum_low_intensity_fraction)
            {
                return error.GeneratedIntensityDistributionInvalid;
            }
        }
        if (!race_week and week.core_distance_km > maximum_peak + 0.01) {
            return error.GeneratedWeeklyVolumeAbovePeak;
        }
        if (week.long_distance_km > 0 and
            week.long_distance_km >
                week.core_distance_km * policy.long_run.maximum_weekly_distance_fraction + 0.01)
        {
            return error.GeneratedLongRunShareTooHigh;
        }
        if (week.long_distance_km > policy.long_run.maximum_peak_distance_km + 0.01) {
            return error.GeneratedLongRunTooLong;
        }
        if (previous_long) |last_long| {
            if (week.long_distance_km > 0 and
                week.long_distance_km - last_long >
                    policy.long_run.maximum_weekly_increase_km + 0.01)
            {
                return error.GeneratedLongRunIncreaseTooLarge;
            }
        }
        if (week.long_distance_km > 0) previous_long = week.long_distance_km;

        if (std.mem.eql(u8, week.phase, "recovery")) {
            if (build_weeks_since_recovery < policy.recovery.minimum_build_weeks_between_recovery or
                build_weeks_since_recovery > policy.recovery.maximum_build_weeks_between_recovery)
            {
                return error.GeneratedRecoveryTimingInvalid;
            }
            build_weeks_since_recovery = 0;
            const previous = previous_progression_volume orelse
                return error.GeneratedRecoveryWithoutBuild;
            const fraction = week.core_distance_km / previous;
            if (fraction + 0.01 < policy.recovery.minimum_volume_fraction or
                fraction - 0.01 > policy.recovery.maximum_volume_fraction)
            {
                return error.GeneratedRecoveryVolumeInvalid;
            }
            continue;
        }

        if (std.mem.eql(u8, week.phase, "taper")) {
            if (pre_taper_peak <= 0) return error.GeneratedTaperWithoutPeak;
            const reduction = 1 - week.core_distance_km / pre_taper_peak;
            if (reduction + 0.01 < policy.taper.minimum_volume_reduction_fraction or
                reduction - 0.01 > policy.taper.maximum_volume_reduction_fraction)
            {
                return error.GeneratedTaperVolumeInvalid;
            }
            if (week.quality_sessions == 0 and policy.taper.maintain_intensity) {
                return error.GeneratedTaperMissingIntensity;
            }
            continue;
        }

        if (race_week) continue;
        if (previous_progression_volume) |previous| {
            const increase = week.core_distance_km / previous - 1;
            if (increase > policy.volume_progression.maximum_build_increase_fraction + 0.01) {
                return error.GeneratedWeeklyVolumeIncreaseTooLarge;
            }
        }
        previous_progression_volume = week.core_distance_km;
        pre_taper_peak = @max(pre_taper_peak, week.core_distance_km);
    }

    if (foundation_weeks < policy.periodization.minimum_foundation_weeks or
        race_specific_weeks < policy.periodization.minimum_race_specific_weeks)
    {
        return error.GeneratedRequiredPhaseTooShort;
    }
    const taper_days = taper_weeks * 7;
    if (taper_days < policy.taper.minimum_days or taper_days > policy.taper.maximum_days) {
        return error.GeneratedTaperLengthInvalid;
    }
    if (!std.mem.eql(u8, weeks[weeks.len - 1].phase, "race")) {
        return error.GeneratedPlanMustEndInRacePhase;
    }
}

fn advancePhase(current: u8, phase: []const u8) !u8 {
    if (std.mem.eql(u8, phase, "foundation")) {
        if (current > 0) return error.GeneratedPhaseOrderInvalid;
        return 0;
    }
    if (std.mem.eql(u8, phase, "build") or std.mem.eql(u8, phase, "recovery")) {
        if (current > 1) return error.GeneratedPhaseOrderInvalid;
        return 1;
    }
    if (std.mem.eql(u8, phase, "race_specific")) {
        if (current > 2) return error.GeneratedPhaseOrderInvalid;
        return 2;
    }
    if (std.mem.eql(u8, phase, "taper")) {
        if (current > 3) return error.GeneratedPhaseOrderInvalid;
        return 3;
    }
    if (std.mem.eql(u8, phase, "race")) {
        if (current > 4) return error.GeneratedPhaseOrderInvalid;
        return 4;
    }
    return error.GeneratedUnknownPhase;
}

fn workoutDistance(workout: plan_revision.ProposedWorkout) !f64 {
    var total: f64 = 0;
    for (workout.segments) |segment| {
        if (segment.distance_km) |distance_km| {
            total += distance_km * @as(f64, @floatFromInt(segment.repetitions));
        } else if (!std.mem.eql(u8, segment.kind, "rest")) {
            return error.GeneratedWorkoutNeedsDistance;
        }
    }
    return total;
}

fn containsWeekday(values: []const runner_profile.Weekday, expected: runner_profile.Weekday) bool {
    for (values) |value| {
        if (value == expected) return true;
    }
    return false;
}

fn isUnavailable(profile: runner_profile.RunnerProfile, date_text: []const u8) bool {
    const unavailable = profile.constraints.unavailable_dates orelse return false;
    for (unavailable.value) |candidate| {
        if (std.mem.eql(u8, candidate, date_text)) return true;
    }
    return false;
}

fn sameAssessment(
    left: plan_provenance.AssessmentSnapshot,
    right: plan_provenance.AssessmentSnapshot,
) bool {
    return std.mem.eql(u8, left.profile_id, right.profile_id) and
        std.mem.eql(u8, left.policy_id, right.policy_id) and
        left.policy_version == right.policy_version and
        std.mem.eql(u8, left.confidence, right.confidence) and
        std.mem.eql(u8, left.feasibility, right.feasibility) and
        left.recommended_target_seconds == right.recommended_target_seconds and
        left.requested_target_seconds == right.requested_target_seconds and
        left.training_pace_anchor_seconds == right.training_pace_anchor_seconds and
        left.expected_shortfall_seconds == right.expected_shortfall_seconds;
}

fn validRecipe(
    policy: training_policy.Policy,
    recipe_id: []const u8,
    phase: []const u8,
) bool {
    for (policy.workout_recipes) |recipe| {
        if (!std.mem.eql(u8, recipe.recipe_id, recipe_id)) continue;
        for (recipe.phase_ids) |phase_id| {
            if (std.mem.eql(u8, phase_id, phase)) return true;
        }
        return false;
    }
    return false;
}

fn validRuleIds(policy: training_policy.Policy, rule_ids: []const []const u8) bool {
    for (rule_ids) |rule_id| {
        if (training_policy.findRule(policy, rule_id) == null) return false;
    }
    return true;
}
