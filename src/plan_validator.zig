const std = @import("std");
const assessment = @import("assessment.zig");
const date = @import("date.zig");
const plan_provenance = @import("plan_provenance.zig");
const plan_revision = @import("plan_revision.zig");
const runner_profile = @import("runner_profile.zig");
const training_policy = @import("training_policy.zig");
const store = @import("store.zig");
const targeted = @import("targeted_adjustment.zig");
const interruption = @import("interruption.zig");

const WeekSummary = struct {
    phase: []const u8,
    core_distance_km: f64,
    optional_distance_km: f64,
    long_distance_km: f64,
    demanding_distance_km: f64,
    demanding_duration_seconds: u32,
    core_duration_seconds: u32,
    long_duration_seconds: u32,
    core_runs: u8,
    quality_sessions: u8,
    ascent_meters: u32,
    long_ascent_meters: u32,
    trail_sessions: u8,
};

pub const ValidationReport = struct {
    weeks: usize,
    workouts: usize,
    policy_rules: usize,
};

pub fn validateStoredAdjustment(allocator: std.mem.Allocator, storage: *const store.Store, proposed: plan_revision.RevisionFile) !void {
    const context = proposed.provenance.adjustment orelse return;
    if (context.policy_version != 3) return error.SupersededAdjustment;
    const parent = storage.schedules.get(proposed.base_schedule_id) orelse return error.StaleRevision;
    const original = parent.plan_provenance orelse return error.AdjustmentNeedsGeneratedPlan;
    if (!try sameJson(allocator, original, context.parent.provenance) or
        !try sameJson(allocator, parent.plan_weeks, context.parent.weeks)) return error.InvalidAdjustmentContext;
    const restart = try date.parse(proposed.effective_from);
    const observed = try interruption.observe(storage, context.parent, restart);
    const returned = try interruption.validateStage(storage, context.parent.*, restart, context.stage, observed);
    if (returned) |week| {
        if (@abs(week.weekly_km - (context.returned_weekly_km orelse 0)) > 0.01 or
            @abs(week.long_km - (context.returned_long_run_km orelse 0)) > 0.01) return error.InvalidAdjustmentContext;
    } else if (context.returned_weekly_km != null or context.returned_long_run_km != null) return error.InvalidAdjustmentContext;
    if (date.compare(observed.first, try date.parse(context.interruption_start)) != .eq or
        observed.skipped != context.skipped_workouts or observed.repeat_week != context.repeat_source_week or
        @abs(observed.weekly_km - context.observed_weekly_km) > 0.01 or
        @abs(observed.peak_weekly_km - (context.observed_peak_weekly_km orelse 0)) > 0.01 or
        @abs(observed.long_km - context.observed_long_run_km) > 0.01 or
        @abs(observed.easy_km - context.familiar_easy_km) > 0.01 or
        @abs(observed.repeat_km - context.repeat_weekly_km) > 0.01 or
        @abs(observed.repeat_long_km - context.repeat_long_run_km) > 0.01) return error.InvalidAdjustmentContext;
}

pub fn validateEmbedded(
    allocator: std.mem.Allocator,
    revision: plan_revision.RevisionFile,
) !ValidationReport {
    if (revision.provenance.adjustment) |context| {
        return validateAdjustment(allocator, revision, context);
    }
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

fn sameJson(allocator: std.mem.Allocator, left: anytype, right: @TypeOf(left)) !bool {
    const a = try std.json.Stringify.valueAlloc(allocator, left, .{});
    defer allocator.free(a);
    const b = try std.json.Stringify.valueAlloc(allocator, right, .{});
    defer allocator.free(b);
    return std.mem.eql(u8, a, b);
}

fn validateAdjustment(allocator: std.mem.Allocator, proposed: plan_revision.RevisionFile, context: plan_provenance.Adjustment) anyerror!ValidationReport {
    if (context.policy_version != 3) return error.SupersededAdjustment;
    if (!context.ready_to_resume or context.skipped_workouts < 2 or context.continuation != null or context.return_load_percent != null or
        !std.mem.eql(u8, context.method, "friel-inspired") or
        !std.mem.eql(u8, context.guidance_url, "https://joefrieltraining.com/missed-workouts/")) return error.InvalidAdjustmentContext;
    for ([_]f64{ context.observed_weekly_km, context.observed_peak_weekly_km orelse 0, context.observed_long_run_km, context.familiar_easy_km, context.repeat_weekly_km, context.repeat_long_run_km }) |value| {
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidAdjustmentContext;
    }
    if (context.stage == .base) {
        if (context.base_weeks < 1 or context.base_weeks > 4) return error.InvalidAdjustmentContext;
    } else if (context.base_weeks != 0) return error.InvalidAdjustmentContext;
    if (context.stage == .continuation) {
        const volume = context.returned_weekly_km orelse return error.InvalidAdjustmentContext;
        const long = context.returned_long_run_km orelse return error.InvalidAdjustmentContext;
        if (!std.math.isFinite(volume) or !std.math.isFinite(long) or volume <= 0 or long <= 0 or long > volume) return error.InvalidAdjustmentContext;
    } else if (context.returned_weekly_km != null or context.returned_long_run_km != null) return error.InvalidAdjustmentContext;
    const parent = context.parent.*;
    const original = (try interruption.originalPlan(context.parent)).*;
    if (parent.workouts.len == 0 or parent.weeks.len != (parent.workouts.len + 6) / 7 or
        context.repeat_source_week == 0 or context.repeat_source_week >= original.weeks.len) return error.InvalidAdjustmentContext;
    _ = try validateEmbedded(allocator, parent);
    const policy = parent.provenance.training_policy;
    const repeat = original.weeks[context.repeat_source_week - 1];
    const restart = try date.parse(context.restart_date);
    const first = try date.parse(context.interruption_start);
    if (date.compare(try date.parse(repeat.end_date), first) != .lt or
        (!std.mem.eql(u8, repeat.phase, "build") and !std.mem.eql(u8, repeat.phase, "race_specific")) or
        !std.mem.eql(u8, proposed.effective_from, context.restart_date)) return error.InvalidAdjustmentContext;
    var expected_provenance = parent.provenance;
    var race_source: runner_profile.Source = .user_entered;
    if (std.mem.eql(u8, context.race_date_choice, "keep")) {
        if (!std.mem.eql(u8, parent.race_date, proposed.race_date)) return error.InvalidAdjustmentContext;
        race_source = parent.provenance.runner_profile.goal.race_date.source;
    } else if (std.mem.eql(u8, context.race_date_choice, "flexible")) {
        race_source = .derived;
        if (date.compare(try targeted.flexibleDate(parent, context), try date.parse(proposed.race_date)) != .eq) return error.InvalidAdjustmentContext;
    } else if (!std.mem.eql(u8, context.race_date_choice, "change")) return error.InvalidAdjustmentContext;
    expected_provenance.runner_profile.goal.race_date = .{ .value = proposed.race_date, .source = race_source };
    expected_provenance.adjustment = proposed.provenance.adjustment;
    if (!std.mem.eql(u8, proposed.name, parent.name) or !std.mem.eql(u8, proposed.goal, parent.goal) or
        !std.mem.eql(u8, proposed.availability, parent.availability) or
        !std.mem.eql(u8, proposed.intensity_guidance, parent.intensity_guidance) or
        !try sameJson(allocator, proposed.pace_profile, parent.pace_profile) or
        !try sameJson(allocator, proposed.provenance, expected_provenance) or
        !try sameJson(allocator, proposed.assessment, parent.assessment)) return error.InvalidAdjustmentContext;
    const start = try date.parse(parent.workouts[0].date);
    const race = try date.parse(proposed.race_date);
    if ((context.stage != .base and date.weekday(restart) != 0) or date.compare(restart, start) != .gt or
        date.compare(first, start) == .lt or date.compare(first, restart) != .lt or date.compare(restart, race) != .lt or
        date.compare(restart, try date.parse(parent.race_date)) != .lt) return error.InvalidAdjustmentContext;
    const expected = try targeted.build(allocator, parent, context, race);
    if (!try sameJson(allocator, expected.workouts, proposed.workouts)) return error.AdjustmentContinuationChanged;
    if (!try sameJson(allocator, expected.weeks, proposed.weeks)) return error.GeneratedWeeklySummaryMismatch;
    if (!try sameJson(allocator, expected.changes, context.week_changes) or
        !try sameJson(allocator, expected.omitted, context.omitted_source_weeks)) return error.InvalidAdjustmentContext;
    // Check physiological planning bounds independently of the construction and
    // mapping above. These remain product rules, not medical clearance.
    var established_volume = @min(context.returned_weekly_km orelse context.repeat_weekly_km, repeat.target_core_distance_km);
    var established_long = @min(context.returned_long_run_km orelse context.repeat_long_run_km, repeat.long_run_distance_km);
    var reached_peak = established_volume;
    var previous_volume = established_volume;
    var race_specific_weeks: usize = 0;
    var taper_weeks: usize = 0;
    var race_count: usize = 0;
    var loading_weeks: usize = 0;
    var last_demanding: ?date.Date = null;
    var taper_started = false;
    const restart_index: usize = @intCast(@divFloor(date.daysBetween(start, restart), 7));
    for (proposed.weeks, 0..) |week, index| {
        if (index < restart_index) continue;
        const change = context.week_changes[index - restart_index];
        const is_base = change.stage == .base;
        const is_race = std.mem.eql(u8, week.phase, "race");
        const is_taper = std.mem.eql(u8, week.phase, "taper");
        const is_recovery = std.mem.eql(u8, week.phase, "recovery");
        var total: f64 = 0;
        var long: f64 = 0;
        var optional: f64 = 0;
        var quality: f64 = 0;
        var quality_count: usize = 0;
        for (proposed.workouts[index * 7 .. @min((index + 1) * 7, proposed.workouts.len)]) |item| {
            try plan_revision.validateWorkout(item);
            const target = try date.parse(item.date);
            const role = (item.decision orelse return error.RevisionWorkoutDecisionRequired).allocation_role;
            const km = targeted.distance(item);
            if (role == .optional_recovery) optional += km else total += km;
            if (role == .long_run) long += km;
            if (date.compare(target, restart) == .lt) continue;
            if (is_base and role != .easy and role != .rest) return error.AdjustmentBaseMustBeEasy;
            if (is_base and role == .easy) {
                if (km > context.familiar_easy_km + 0.01 or item.decision.?.pace_method != .effort_only) return error.AdjustmentBaseMustBeEasy;
                for (item.segments) |segment| {
                    if (segment.pace_fast_seconds_per_km != null or segment.pace_slow_seconds_per_km != null) return error.AdjustmentBaseMustBeEasy;
                }
            }
            if (role == .quality) {
                quality += km;
                quality_count += 1;
                const support = if (is_taper) policy.quality_progression.minimum_taper_warmup_cooldown_km else policy.quality_progression.minimum_warmup_cooldown_km;
                if (item.segments.len != 3 or (item.segments[0].distance_km orelse 0) + 0.01 < support or
                    (item.segments[2].distance_km orelse 0) + 0.01 < support) return error.GeneratedQualityProgressionDecisionInvalid;
                if (km > week.target_core_distance_km * policy.quality_progression.maximum_weekly_distance_fraction + 0.01 or
                    km > policy.quality_progression.maximum_session_distance_km + 0.01) return error.GeneratedQualitySessionTooLong;
            }
            if (role == .race) {
                race_count += 1;
                if (date.compare(target, race) != .eq or change.distance_fraction != 1) return error.GeneratedRaceOnWrongDate;
            }
            if (role != .rest) {
                if (isUnavailable(parent.provenance.runner_profile, item.date)) return error.GeneratedWorkoutOnUnavailableDate;
                const weekday: runner_profile.Weekday = @enumFromInt(date.weekday(target));
                if (role != .race and role != .optional_recovery and !containsWeekday(parent.provenance.runner_profile.availability.running_days.value, weekday)) return error.GeneratedWorkoutOutsideAvailability;
            }
            if (role == .quality or role == .long_run or role == .race) {
                if (last_demanding) |prior| {
                    if (date.daysBetween(prior, target) - 1 < policy.scheduling.minimum_easy_or_rest_days_between_demanding_sessions) return error.GeneratedDemandingSessionsTooClose;
                }
                last_demanding = target;
            }
        }
        if (@abs(total - week.target_core_distance_km) > 0.01 or @abs(long - week.long_run_distance_km) > 0.01) return error.GeneratedWeeklySummaryMismatch;
        if (is_base) continue;
        if (optional > total * policy.optional_run.maximum_weekly_distance_fraction + 0.01 or quality_count > policy.intensity_distribution.maximum_quality_sessions_per_week) return error.GeneratedIntensityDistributionInvalid;
        if (!is_race) {
            if (total <= 0 or long > total * policy.long_run.maximum_weekly_distance_fraction + 0.01 or long > policy.long_run.maximum_peak_distance_km + 0.01) return error.GeneratedLongRunShareTooHigh;
            const low = 1 - quality / total;
            if (low + 0.01 < policy.intensity_distribution.minimum_low_intensity_fraction or low - 0.01 > policy.intensity_distribution.maximum_low_intensity_fraction) return error.GeneratedIntensityDistributionInvalid;
            if (total > parent.provenance.runner_profile.baseline.average_weekly_distance_km.value * policy.volume_progression.maximum_peak_relative_to_baseline + 0.01) return error.GeneratedWeeklyVolumeAbovePeak;
        }
        if (is_taper) {
            taper_started = true;
            taper_weeks += 1;
            const reduction = 1 - total / reached_peak;
            if (reduction + 0.01 < policy.taper.minimum_volume_reduction_fraction or reduction - 0.01 > policy.taper.maximum_volume_reduction_fraction or
                (policy.taper.maintain_intensity and quality_count == 0)) return error.GeneratedTaperVolumeInvalid;
        } else if (!is_race) {
            if (taper_started) return error.GeneratedTaperLengthInvalid;
            if (total > established_volume * (1 + policy.volume_progression.maximum_build_increase_fraction) + 0.01 or
                long > established_long + policy.long_run.maximum_weekly_increase_km + 0.01) return error.AdjustmentReturnLoadExceeded;
            if (is_recovery) {
                loading_weeks = 0;
                const fraction = total / previous_volume;
                if (fraction + 0.01 < policy.recovery.minimum_volume_fraction or fraction - 0.01 > policy.recovery.maximum_volume_fraction) return error.GeneratedRecoveryVolumeInvalid;
            } else {
                loading_weeks += 1;
                if (loading_weeks > policy.recovery.maximum_build_weeks_between_recovery) return error.AdjustmentRaceDateTooClose;
            }
            established_volume = @max(established_volume, total);
            established_long = @max(established_long, long);
            reached_peak = @max(reached_peak, total);
            previous_volume = total;
        }
        if (std.mem.eql(u8, week.phase, "race_specific")) race_specific_weeks += 1;
    }
    if (race_count != 1 or race_specific_weeks < policy.periodization.minimum_race_specific_weeks or
        taper_weeks * 7 < policy.taper.minimum_days or taper_weeks * 7 > policy.taper.maximum_days) return error.AdjustmentRaceDateTooClose;
    return .{ .weeks = proposed.weeks.len, .workouts = proposed.workouts.len, .policy_rules = policy.rules.len };
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
    if (provenance.schema_version != 2 or
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
    var previous_quality: ?plan_provenance.QualityProgressionDecision = null;

    const week_count = (revision.workouts.len + 6) / 7;
    const proposed_weeks = revision.weeks;
    if (proposed_weeks.len != week_count) return error.GeneratedWeeklySummaryCountMismatch;
    for (proposed_weeks, 0..) |week, index| {
        const decision = week.decision;
        const phase_position = planPhasePosition(proposed_weeks, index);
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
            !std.mem.eql(u8, decision.long_run_rule_id, policy.long_run.rule_id) or
            decision.phase_week != phase_position.week or
            decision.phase_week_count != phase_position.count)
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
        .demanding_duration_seconds = 0,
        .core_duration_seconds = 0,
        .long_duration_seconds = 0,
        .core_runs = 0,
        .quality_sessions = 0,
        .ascent_meters = 0,
        .long_ascent_meters = 0,
        .trail_sessions = 0,
    });

    for (revision.workouts, 0..) |workout, day_index| {
        try plan_revision.validateWorkout(workout);
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
        if (decision.load_basis != runner_profile.trainingLoadBasis(profile)) {
            return error.GeneratedWorkoutLoadBasisMismatch;
        }
        if (decision.scheduled_weekday != weekday) {
            return error.GeneratedWorkoutDecisionWeekdayMismatch;
        }
        if (!validRecipe(policy, decision.recipe_id, workout.phase)) {
            return error.GeneratedWorkoutDecisionRecipeMismatch;
        }
        if (decision.rule_ids.len == 0 or !validRuleIds(policy, decision.rule_ids)) {
            return error.GeneratedWorkoutDecisionRuleMismatch;
        }
        if (decision.planned_ascent_meters != workout.ascent_meters or
            decision.planned_descent_meters != workout.descent_meters or
            decision.terrain != workout.terrain)
        {
            return error.GeneratedWorkoutTrailDecisionMismatch;
        }
        if (runner_profile.surface(profile) == .trail and is_running and !is_optional) {
            if (workout.terrain != .trail or decision.pace_method != .effort_only) {
                return error.GeneratedTrailWorkoutInvalid;
            }
            weeks[week_index].trail_sessions += 1;
            const workout_ascent = workout.ascent_meters orelse 0;
            weeks[week_index].ascent_meters += workout_ascent;
            if (decision.allocation_role == .long_run) {
                weeks[week_index].long_ascent_meters = workout_ascent;
            }
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
        const duration_seconds = workoutDuration(workout);
        if (@abs(decision.allocated_distance_km - distance_km) > 0.01) {
            return error.GeneratedWorkoutDecisionDistanceMismatch;
        }
        if (decision.allocated_duration_seconds !=
            (if (duration_seconds > 0) duration_seconds else null))
        {
            return error.GeneratedWorkoutDecisionDurationMismatch;
        }
        if (is_optional) {
            weeks[week_index].optional_distance_km += distance_km;
        } else {
            weeks[week_index].core_distance_km += distance_km;
            weeks[week_index].core_duration_seconds += duration_seconds;
            if (is_running) weeks[week_index].core_runs += 1;
        }
        if (std.mem.eql(u8, workout.kind, "long")) {
            weeks[week_index].long_distance_km += distance_km;
            weeks[week_index].long_duration_seconds += duration_seconds;
        }
        if (std.mem.eql(u8, workout.kind, "quality")) {
            weeks[week_index].quality_sessions += 1;
            weeks[week_index].demanding_distance_km += distance_km;
            weeks[week_index].demanding_duration_seconds += duration_seconds;
            const quality = decision.quality_progression orelse
                return error.GeneratedQualityProgressionDecisionRequired;
            try validateQualityProgression(
                profile,
                policy,
                workout,
                quality,
                proposed_weeks[week_index],
                previous_quality,
            );
            previous_quality = quality;
        } else if (decision.quality_progression != null) {
            return error.GeneratedQualityProgressionOnNonQualityWorkout;
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
        const expected_long_ascent: ?u32 = if (std.mem.eql(u8, proposed.phase, "race"))
            null
        else
            week.long_ascent_meters;
        if (proposed.week != index + 1 or
            !std.mem.eql(u8, proposed.phase, week.phase) or
            @abs(proposed.target_core_distance_km - week.core_distance_km) > 0.01 or
            @abs(proposed.long_run_distance_km - week.long_distance_km) > 0.01 or
            proposed.target_core_duration_seconds !=
                (if (week.core_duration_seconds > 0) week.core_duration_seconds else null) or
            proposed.long_run_duration_seconds !=
                (if (week.long_duration_seconds > 0) week.long_duration_seconds else null) or
            decision.target_core_duration_seconds != proposed.target_core_duration_seconds or
            decision.load_basis != runner_profile.trainingLoadBasis(profile) or
            @abs(decision.baseline_weekly_distance_km -
                profile.baseline.average_weekly_distance_km.value) > 0.01)
        {
            return error.GeneratedWeeklySummaryMismatch;
        }
        if (runner_profile.surface(profile) == .trail and
            (proposed.target_ascent_meters != week.ascent_meters or
                proposed.long_run_ascent_meters != expected_long_ascent or
                decision.target_ascent_meters != proposed.target_ascent_meters or
                decision.long_run_ascent_meters != proposed.long_run_ascent_meters or
                decision.trail_rule_id == null))
        {
            return error.GeneratedTrailWeekMismatch;
        }
    }
    try validateWeeks(profile, policy, weeks);
}

const PlanPhasePosition = struct {
    week: ?u8,
    count: ?u8,
};

fn planPhasePosition(
    weeks: []const plan_provenance.PlanWeek,
    index: usize,
) PlanPhasePosition {
    var first = index;
    while (first > 0 and
        std.mem.eql(u8, weeks[first - 1].phase, weeks[index].phase))
    {
        first -= 1;
    }
    var final = index + 1;
    while (final < weeks.len and
        std.mem.eql(u8, weeks[final].phase, weeks[index].phase))
    {
        final += 1;
    }
    return .{
        .week = @intCast(index - first + 1),
        .count = @intCast(final - first),
    };
}

fn validateQualityProgression(
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    workout: plan_revision.ProposedWorkout,
    quality: plan_provenance.QualityProgressionDecision,
    week: plan_provenance.PlanWeek,
    previous: ?plan_provenance.QualityProgressionDecision,
) !void {
    if (runner_profile.trainingLoadBasis(profile) == .duration) {
        return validateDurationQualityProgression(profile, workout, quality, week, previous);
    }
    const progression = policy.quality_progression;
    if (quality.stage_id.len == 0 or
        quality.phase_week == 0 or
        quality.phase_week_count == 0 or
        quality.phase_week > quality.phase_week_count or
        quality.work_distance_km <= 0 or
        quality.repetitions == 0 or
        quality.phase_week != week.decision.phase_week or
        quality.phase_week_count != week.decision.phase_week_count)
    {
        return error.GeneratedQualityProgressionDecisionInvalid;
    }
    const expected_stage = expectedQualityStage(
        week.phase,
        quality.phase_week,
        runner_profile.surface(profile) == .trail,
    ) orelse
        return error.GeneratedQualityProgressionDecisionInvalid;
    if (!std.mem.eql(u8, quality.stage_id, expected_stage.stage_id) or
        quality.load_method != expected_stage.load_method)
    {
        return error.GeneratedQualityProgressionDecisionInvalid;
    }
    if (expected_stage.repetitions) {
        const repetition_km = quality.repetition_distance_km orelse
            return error.GeneratedQualityProgressionDecisionInvalid;
        if (@abs(repetition_km -
            progression.foundation_repetition_distance_km) > 0.01 or
            quality.recovery_seconds != progression.interval_recovery_seconds)
        {
            return error.GeneratedQualityProgressionDecisionInvalid;
        }
    } else if (quality.repetition_distance_km != null or
        quality.recovery_seconds != null or
        quality.repetitions != 1)
    {
        return error.GeneratedQualityProgressionDecisionInvalid;
    }
    const allocated = try workoutDistance(workout);
    if (allocated >
        week.target_core_distance_km *
            progression.maximum_weekly_distance_fraction + 0.01)
    {
        return error.GeneratedQualitySessionTooLong;
    }
    if (workout.segments.len != 3) {
        return error.GeneratedQualityProgressionDecisionInvalid;
    }
    const minimum_support_km = if (std.mem.eql(u8, week.phase, "taper"))
        progression.minimum_taper_warmup_cooldown_km
    else
        progression.minimum_warmup_cooldown_km;
    const warmup_distance = workout.segments[0].distance_km orelse
        return error.GeneratedQualityProgressionDecisionInvalid;
    const cooldown_distance = workout.segments[2].distance_km orelse
        return error.GeneratedQualityProgressionDecisionInvalid;
    if (warmup_distance + 0.01 < minimum_support_km or
        cooldown_distance + 0.01 < minimum_support_km)
    {
        return error.GeneratedQualityProgressionDecisionInvalid;
    }
    const work_segment = workout.segments[1];
    const segment_distance = work_segment.distance_km orelse
        return error.GeneratedQualityProgressionDecisionInvalid;
    const represented_work = segment_distance *
        @as(f64, @floatFromInt(work_segment.repetitions));
    if (@abs(represented_work - quality.work_distance_km) > 0.01 or
        work_segment.repetitions != quality.repetitions or
        work_segment.recovery_seconds != quality.recovery_seconds)
    {
        return error.GeneratedQualityProgressionDecisionMismatch;
    }
    if (quality.repetition_distance_km) |repetition_km| {
        if (@abs(repetition_km - segment_distance) > 0.01) {
            return error.GeneratedQualityProgressionDecisionMismatch;
        }
    } else if (quality.repetitions != 1) {
        return error.GeneratedQualityProgressionDecisionMismatch;
    }

    if (previous) |prior| {
        const recorded_previous = quality.previous_work_distance_km orelse
            return error.GeneratedQualityProgressionDecisionMismatch;
        if (@abs(recorded_previous - prior.work_distance_km) > 0.01) {
            return error.GeneratedQualityProgressionDecisionMismatch;
        }
        switch (quality.load_method) {
            .establish => return error.GeneratedQualityProgressionInvalid,
            .progress_work, .race_specific_progression => {
                if (quality.work_distance_km + 0.01 < prior.work_distance_km) {
                    return error.GeneratedQualityProgressionInvalid;
                }
            },
            .recovery_reduction => {
                if (quality.work_distance_km >= prior.work_distance_km - 0.01) {
                    return error.GeneratedQualityRecoveryNotReduced;
                }
            },
            .taper_reduction, .race_sharpening => {
                if (quality.work_distance_km > prior.work_distance_km + 0.01) {
                    return error.GeneratedQualityProgressionInvalid;
                }
            },
        }
        if (std.mem.eql(u8, quality.stage_id, prior.stage_id) and
            quality.repetition_distance_km != null and
            prior.repetition_distance_km != null)
        {
            const recovery_seconds = quality.recovery_seconds orelse
                return error.GeneratedQualityProgressionDecisionInvalid;
            const prior_recovery_seconds = prior.recovery_seconds orelse
                return error.GeneratedQualityProgressionDecisionInvalid;
            if (quality.repetition_distance_km.? + 0.01 <
                prior.repetition_distance_km.? or
                recovery_seconds > prior_recovery_seconds)
            {
                return error.GeneratedQualityDensityRegressed;
            }
        }
    } else if (quality.previous_work_distance_km != null or
        quality.load_method != .establish)
    {
        return error.GeneratedQualityProgressionDecisionMismatch;
    }
}

fn validateDurationQualityProgression(
    profile: runner_profile.RunnerProfile,
    workout: plan_revision.ProposedWorkout,
    quality: plan_provenance.QualityProgressionDecision,
    week: plan_provenance.PlanWeek,
    previous: ?plan_provenance.QualityProgressionDecision,
) !void {
    const work_seconds = quality.work_duration_seconds orelse
        return error.GeneratedQualityProgressionDecisionInvalid;
    if (quality.stage_id.len == 0 or
        quality.phase_week == 0 or
        quality.phase_week_count == 0 or
        quality.phase_week > quality.phase_week_count or
        work_seconds == 0 or
        quality.repetitions != 1 or
        quality.repetition_distance_km != null or
        quality.recovery_seconds != null or
        quality.phase_week != week.decision.phase_week or
        quality.phase_week_count != week.decision.phase_week_count)
    {
        return error.GeneratedQualityProgressionDecisionInvalid;
    }
    const expected_stage = expectedQualityStage(
        week.phase,
        quality.phase_week,
        runner_profile.surface(profile) == .trail,
    ) orelse return error.GeneratedQualityProgressionDecisionInvalid;
    if (!std.mem.eql(u8, quality.stage_id, expected_stage.stage_id) or
        quality.load_method != expected_stage.load_method or
        workout.segments.len != 3)
    {
        return error.GeneratedQualityProgressionDecisionInvalid;
    }
    const warmup_seconds = workout.segments[0].duration_seconds orelse
        return error.GeneratedQualityProgressionDecisionInvalid;
    const represented_work = workout.segments[1].duration_seconds orelse
        return error.GeneratedQualityProgressionDecisionInvalid;
    const cooldown_seconds = workout.segments[2].duration_seconds orelse
        return error.GeneratedQualityProgressionDecisionInvalid;
    if (warmup_seconds == 0 or cooldown_seconds == 0 or
        represented_work != work_seconds or
        workoutDuration(workout) != warmup_seconds + represented_work + cooldown_seconds)
    {
        return error.GeneratedQualityProgressionDecisionMismatch;
    }
    if (previous) |prior| {
        const prior_work = prior.work_duration_seconds orelse
            return error.GeneratedQualityProgressionDecisionMismatch;
        const recorded_previous = quality.previous_work_duration_seconds orelse
            return error.GeneratedQualityProgressionDecisionMismatch;
        if (recorded_previous != prior_work) {
            return error.GeneratedQualityProgressionDecisionMismatch;
        }
        switch (quality.load_method) {
            .establish => return error.GeneratedQualityProgressionInvalid,
            .progress_work, .race_specific_progression => {
                if (work_seconds < prior_work) return error.GeneratedQualityProgressionInvalid;
            },
            .recovery_reduction => {
                if (work_seconds >= prior_work) return error.GeneratedQualityRecoveryNotReduced;
            },
            .taper_reduction, .race_sharpening => {
                if (work_seconds > prior_work) return error.GeneratedQualityProgressionInvalid;
            },
        }
    } else if (quality.previous_work_duration_seconds != null or
        quality.load_method != .establish)
    {
        return error.GeneratedQualityProgressionDecisionMismatch;
    }
}

const ExpectedQualityStage = struct {
    stage_id: []const u8,
    load_method: plan_provenance.QualityLoadMethod,
    repetitions: bool,
};

fn expectedQualityStage(
    phase: []const u8,
    phase_week: u8,
    trail: bool,
) ?ExpectedQualityStage {
    if (trail) {
        if (std.mem.eql(u8, phase, "foundation")) {
            return .{
                .stage_id = "trail-foundation-hills",
                .load_method = if (phase_week == 1) .establish else .progress_work,
                .repetitions = true,
            };
        }
        if (std.mem.eql(u8, phase, "build")) {
            return .{
                .stage_id = "trail-build-climbing",
                .load_method = .progress_work,
                .repetitions = false,
            };
        }
        if (std.mem.eql(u8, phase, "recovery")) {
            return .{
                .stage_id = "trail-recovery-hills",
                .load_method = .recovery_reduction,
                .repetitions = true,
            };
        }
        if (std.mem.eql(u8, phase, "race_specific")) {
            return .{
                .stage_id = "trail-race-specific-effort",
                .load_method = .race_specific_progression,
                .repetitions = false,
            };
        }
        if (std.mem.eql(u8, phase, "taper")) {
            return .{
                .stage_id = "trail-taper-uphill",
                .load_method = .taper_reduction,
                .repetitions = false,
            };
        }
        if (std.mem.eql(u8, phase, "race")) {
            return .{
                .stage_id = "trail-race-week-sharpening",
                .load_method = .race_sharpening,
                .repetitions = false,
            };
        }
        return null;
    }
    if (std.mem.eql(u8, phase, "foundation")) {
        return .{
            .stage_id = "foundation-aerobic-intervals",
            .load_method = if (phase_week == 1) .establish else .progress_work,
            .repetitions = true,
        };
    }
    if (std.mem.eql(u8, phase, "build")) {
        return .{
            .stage_id = "build-continuous-threshold",
            .load_method = .progress_work,
            .repetitions = false,
        };
    }
    if (std.mem.eql(u8, phase, "recovery")) {
        return .{
            .stage_id = "recovery-aerobic-intervals",
            .load_method = .recovery_reduction,
            .repetitions = true,
        };
    }
    if (std.mem.eql(u8, phase, "race_specific")) {
        return .{
            .stage_id = "race-specific-half-marathon-pace",
            .load_method = .race_specific_progression,
            .repetitions = false,
        };
    }
    if (std.mem.eql(u8, phase, "taper")) {
        return .{
            .stage_id = "taper-half-marathon-pace",
            .load_method = .taper_reduction,
            .repetitions = false,
        };
    }
    if (std.mem.eql(u8, phase, "race")) {
        return .{
            .stage_id = "race-week-sharpening",
            .load_method = .race_sharpening,
            .repetitions = false,
        };
    }
    return null;
}

fn validateWeeks(
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    weeks: []const WeekSummary,
) !void {
    if (runner_profile.trainingLoadBasis(profile) == .duration) {
        return validateDurationWeeks(profile, policy, weeks);
    }

    var previous_progression_volume: ?f64 = null;
    var previous_long: ?f64 = null;
    var pre_taper_peak: f64 = 0;
    var foundation_weeks: u8 = 0;
    var race_specific_weeks: u8 = 0;
    var taper_weeks: u8 = 0;
    var build_weeks_since_recovery: u8 = 0;
    const maximum_peak = profile.baseline.average_weekly_distance_km.value *
        policy.volume_progression.maximum_peak_relative_to_baseline;
    var previous_ascent: ?u32 = null;
    var previous_long_ascent: ?u32 = null;

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
        if (runner_profile.surface(profile) == .trail) {
            const trail = policy.trail_specific orelse
                return error.TrailPolicyRulesRequired;
            const course = runner_profile.trailCourse(profile) orelse
                return error.TrailCourseAscentRequired;
            const race_ascent = (course.total_ascent_meters orelse
                return error.TrailCourseAscentRequired).value;
            const baseline_known = profile.baseline.average_weekly_ascent_meters != null and
                profile.baseline.longest_run_ascent_meters != null;
            const baseline_ascent: u32 = if (profile.baseline.average_weekly_ascent_meters) |source|
                @max(@as(u32, 100), source.value)
            else
                @intFromFloat(@round(
                    @as(f64, @floatFromInt(race_ascent)) *
                        trail.unknown_ascent_initial_race_fraction,
                ));
            const baseline_peak = if (baseline_known)
                @as(f64, @floatFromInt(baseline_ascent)) *
                    trail.maximum_peak_ascent_relative_to_baseline
            else
                @as(f64, @floatFromInt(race_ascent)) *
                    trail.unknown_ascent_peak_race_fraction;
            const race_peak = @as(f64, @floatFromInt(race_ascent)) *
                trail.maximum_peak_ascent_relative_to_race;
            const trail_peak: u32 = @max(baseline_ascent, @as(u32, @intFromFloat(
                @round(@min(baseline_peak, race_peak)),
            )));
            if (!std.mem.eql(u8, week.phase, "race") and
                week.trail_sessions < trail.minimum_trail_sessions_per_week)
            {
                return error.GeneratedTrailSpecificityMissing;
            }
            if (!std.mem.eql(u8, week.phase, "race") and
                week.ascent_meters > trail_peak)
            {
                return error.GeneratedWeeklyAscentAbovePeak;
            }
            const race_long_limit: u32 = @intFromFloat(@round(
                @as(f64, @floatFromInt(race_ascent)) *
                    trail.maximum_long_run_race_ascent_fraction,
            ));
            const weekly_long_limit: u32 = @intFromFloat(@round(
                @as(f64, @floatFromInt(week.ascent_meters)) *
                    trail.maximum_long_run_weekly_ascent_fraction,
            ));
            if (!std.mem.eql(u8, week.phase, "race") and
                (week.long_ascent_meters > race_long_limit or
                    week.long_ascent_meters > weekly_long_limit))
            {
                return error.GeneratedLongRunAscentTooHigh;
            }
            if (previous_ascent) |previous| {
                const progression_limit: u32 = @intFromFloat(@round(
                    @as(f64, @floatFromInt(previous)) *
                        (1 + trail.maximum_weekly_ascent_increase_fraction),
                ));
                if (!std.mem.eql(u8, week.phase, "race") and
                    !std.mem.eql(u8, week.phase, "recovery") and
                    !std.mem.eql(u8, week.phase, "taper") and
                    week.ascent_meters > progression_limit + 1)
                {
                    return error.GeneratedWeeklyAscentIncreaseTooLarge;
                }
            }
            if (previous_long_ascent) |previous| {
                const long_progression_limit: u32 = @intFromFloat(@round(
                    @as(f64, @floatFromInt(@max(@as(u32, 50), previous))) *
                        (1 + trail.maximum_weekly_ascent_increase_fraction),
                ));
                const reduced_week = std.mem.eql(u8, week.phase, "recovery") or
                    std.mem.eql(u8, week.phase, "taper");
                if (!std.mem.eql(u8, week.phase, "race") and
                    ((!reduced_week and week.long_ascent_meters > long_progression_limit) or
                        (reduced_week and week.long_ascent_meters > previous)))
                {
                    return error.GeneratedLongRunAscentIncreaseTooLarge;
                }
            }
            if (!std.mem.eql(u8, week.phase, "race")) {
                previous_ascent = week.ascent_meters;
                previous_long_ascent = week.long_ascent_meters;
            }
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

fn validateDurationWeeks(
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    weeks: []const WeekSummary,
) !void {
    const duration = policy.duration_progression orelse
        return error.DurationProgressionPolicyRequired;
    const trail = if (runner_profile.surface(profile) == .trail)
        policy.trail_specific
    else
        null;
    const course = runner_profile.trailCourse(profile);
    const race_ascent: u32 = if (course) |trail_course|
        (trail_course.total_ascent_meters orelse
            return error.TrailCourseAscentRequired).value
    else
        0;
    const ascent_peak: u32 = if (trail) |trail_policy|
        if (profile.baseline.average_weekly_ascent_meters) |baseline_source|
            @max(
                @max(@as(u32, 100), baseline_source.value),
                @as(u32, @intFromFloat(@round(@min(
                    @as(f64, @floatFromInt(@max(@as(u32, 100), baseline_source.value))) *
                        trail_policy.maximum_peak_ascent_relative_to_baseline,
                    @as(f64, @floatFromInt(race_ascent)) *
                        trail_policy.maximum_peak_ascent_relative_to_race,
                )))),
            )
        else
            @intFromFloat(@round(
                @as(f64, @floatFromInt(race_ascent)) *
                    trail_policy.unknown_ascent_peak_race_fraction,
            ))
    else
        0;
    var previous_regular: ?u32 = null;
    var previous_long: ?u32 = null;
    var previous_ascent: ?u32 = null;
    var foundation_weeks: u8 = 0;
    var race_specific_weeks: u8 = 0;
    var taper_weeks: u8 = 0;

    for (weeks) |week| {
        const race_week = std.mem.eql(u8, week.phase, "race");
        const expected_core_runs: u8 = if (race_week)
            2
        else
            @intCast(profile.availability.running_days.value.len);
        if (week.core_runs != expected_core_runs) return error.GeneratedDurationWeekCountMismatch;
        if (runner_profile.surface(profile) == .trail and
            week.trail_sessions != expected_core_runs)
        {
            return error.GeneratedTrailSpecificityMissing;
        }
        if (week.quality_sessions != 1) return error.GeneratedDurationQualityMissing;
        if (std.mem.eql(u8, week.phase, "foundation")) foundation_weeks += 1;
        if (std.mem.eql(u8, week.phase, "race_specific")) race_specific_weeks += 1;
        if (std.mem.eql(u8, week.phase, "taper")) taper_weeks += 1;

        if (race_week) {
            if (week.long_duration_seconds != 0 or
                week.core_duration_seconds != duration.race_week_short_run_seconds or
                week.ascent_meters != race_ascent)
            {
                return error.GeneratedDurationRaceWeekInvalid;
            }
            continue;
        }
        if (week.long_duration_seconds == 0 or
            week.core_duration_seconds <= week.long_duration_seconds)
        {
            return error.GeneratedDurationInvalid;
        }
        const regular_run_count = @as(u32, week.core_runs - 1);
        const regular_total = week.core_duration_seconds - week.long_duration_seconds;
        if (@rem(regular_total, regular_run_count) != 0) {
            return error.GeneratedDurationInvalid;
        }
        const regular_seconds = @divExact(regular_total, regular_run_count);
        const reduced_week = std.mem.eql(u8, week.phase, "recovery") or
            std.mem.eql(u8, week.phase, "taper");
        if (previous_regular) |previous| {
            if ((!reduced_week and regular_seconds >
                previous + duration.regular_run_weekly_increase_seconds) or
                (reduced_week and regular_seconds > previous))
            {
                return error.GeneratedDurationIncreaseTooLarge;
            }
        }
        if (previous_long) |previous| {
            if ((!reduced_week and week.long_duration_seconds >
                previous + duration.long_run_weekly_increase_seconds) or
                (reduced_week and week.long_duration_seconds > previous))
            {
                return error.GeneratedDurationIncreaseTooLarge;
            }
        }
        if (regular_seconds > duration.maximum_regular_run_seconds or
            week.long_duration_seconds > duration.maximum_long_run_seconds)
        {
            return error.GeneratedDurationAbovePeak;
        }
        const low_fraction = 1 -
            @as(f64, @floatFromInt(week.demanding_duration_seconds)) /
                @as(f64, @floatFromInt(week.core_duration_seconds));
        if (low_fraction + 0.01 < policy.intensity_distribution.minimum_low_intensity_fraction or
            low_fraction - 0.01 > policy.intensity_distribution.maximum_low_intensity_fraction)
        {
            return error.GeneratedIntensityDistributionInvalid;
        }
        if (trail != null and week.ascent_meters > ascent_peak) {
            return error.GeneratedWeeklyAscentAbovePeak;
        }
        if (trail) |trail_policy| {
            const long_ascent_limit: u32 = @intFromFloat(@round(
                @as(f64, @floatFromInt(week.ascent_meters)) *
                    trail_policy.maximum_long_run_weekly_ascent_fraction,
            ));
            if (week.long_ascent_meters > long_ascent_limit) {
                return error.GeneratedLongRunAscentTooHigh;
            }
            if (previous_ascent) |previous| {
                const increase_limit: u32 = @intFromFloat(@round(
                    @as(f64, @floatFromInt(previous)) *
                        (1 + trail_policy.maximum_weekly_ascent_increase_fraction),
                ));
                if (!reduced_week and week.ascent_meters > increase_limit + 1) {
                    return error.GeneratedWeeklyAscentIncreaseTooLarge;
                }
                if (reduced_week and week.ascent_meters > previous) {
                    return error.GeneratedWeeklyAscentIncreaseTooLarge;
                }
            }
        }
        previous_regular = regular_seconds;
        previous_long = week.long_duration_seconds;
        previous_ascent = week.ascent_meters;
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
        }
    }
    return total;
}

fn workoutDuration(workout: plan_revision.ProposedWorkout) u32 {
    var total: u32 = 0;
    for (workout.segments) |segment| {
        const duration_seconds = segment.duration_seconds orelse continue;
        total += duration_seconds * @as(u32, segment.repetitions);
        const recovery_seconds = segment.recovery_seconds orelse continue;
        if (segment.repetitions > 1) {
            total += @as(u32, recovery_seconds) *
                (@as(u32, segment.repetitions) - 1);
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
