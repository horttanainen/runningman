const std = @import("std");
const evidence_ledger = @import("evidence_ledger.zig");
const runner_profile = @import("runner_profile.zig");

const Io = std.Io;

pub const Rule = struct {
    rule_id: []const u8,
    category: []const u8,
    summary: []const u8,
    evidence_ids: []const []const u8,
    product_assumption: []const u8 = "",
};

pub const Support = struct {
    rule_id: []const u8,
    race_distance: runner_profile.RaceDistance,
    race_distance_km: f64,
    minimum_plan_days: u16,
    maximum_plan_days: u16,
    minimum_core_running_days: u8,
    maximum_core_running_days: u8,
};

pub const Phase = struct {
    phase_id: []const u8,
    purpose: []const u8,
};

pub const Periodization = struct {
    rule_id: []const u8,
    phases: []const Phase,
    minimum_foundation_weeks: u8,
    minimum_race_specific_weeks: u8,
    default_taper_weeks: u8,
};

pub const BaselineAssessment = struct {
    rule_id: []const u8,
    target_rule_id: []const u8,
    race_equivalence_exponent: f64,
    high_confidence_performance_age_days: u16,
    maximum_performance_age_days: u16,
    five_km_uncertainty_fraction: f64,
    ten_km_uncertainty_fraction: f64,
    half_marathon_uncertainty_fraction: f64,
    hard_effort_extra_uncertainty_fraction: f64,
    training_result_extra_uncertainty_fraction: f64,
    old_result_extra_uncertainty_fraction: f64,
    conflicting_result_threshold_fraction: f64,
    projected_improvement_per_week_fraction: f64,
    maximum_projected_improvement_fraction: f64,
    reduced_readiness_improvement_multiplier: f64,
    full_projection_minimum_weekly_distance_km: f64,
    full_projection_minimum_long_run_km: f64,
    full_projection_maximum_interruption_days: u16,
    aspirational_gap_limit_fraction: f64,
    target_rounding_seconds: u16,
    easy_pace_minimum_seconds_slower_per_km: u16,
    easy_pace_maximum_seconds_slower_per_km: u16,
};

pub const VolumeProgression = struct {
    rule_id: []const u8,
    maximum_build_increase_fraction: f64,
    maximum_peak_relative_to_baseline: f64,
};

pub const Recovery = struct {
    rule_id: []const u8,
    minimum_build_weeks_between_recovery: u8,
    maximum_build_weeks_between_recovery: u8,
    minimum_volume_fraction: f64,
    maximum_volume_fraction: f64,
};

pub const IntensityDistribution = struct {
    rule_id: []const u8,
    minimum_low_intensity_fraction: f64,
    maximum_low_intensity_fraction: f64,
    maximum_quality_sessions_per_week: u8,
    easy_effort_guidance: []const u8,
    quality_effort_guidance: []const u8,
};

pub const QualityProgression = struct {
    rule_id: []const u8,
    target_weekly_distance_fraction: f64,
    maximum_weekly_distance_fraction: f64,
    maximum_session_distance_km: f64,
    minimum_warmup_cooldown_km: f64,
    maximum_warmup_cooldown_km: f64,
    foundation_repetition_distance_km: f64,
    foundation_initial_work_fraction: f64,
    foundation_weekly_work_increase_km: f64,
    interval_recovery_seconds: u16,
    recovery_work_fraction: f64,
    race_week_work_distance_km: f64,
};

pub const LongRun = struct {
    rule_id: []const u8,
    maximum_weekly_increase_km: f64,
    maximum_weekly_distance_fraction: f64,
    maximum_peak_distance_km: f64,
};

pub const Taper = struct {
    rule_id: []const u8,
    minimum_days: u8,
    maximum_days: u8,
    minimum_volume_reduction_fraction: f64,
    maximum_volume_reduction_fraction: f64,
    maintain_intensity: bool,
    maintain_core_frequency: bool,
};

pub const Scheduling = struct {
    rule_id: []const u8,
    minimum_easy_or_rest_days_between_demanding_sessions: u8,
};

pub const OptionalRun = struct {
    rule_id: []const u8,
    maximum_weekly_distance_fraction: f64,
    may_be_removed_without_rescheduling: bool,
};

pub const MissedWorkout = struct {
    rule_id: []const u8,
    stack_later_in_week: bool,
    preserve_hard_session_spacing: bool,
};

pub const WorkoutCategory = struct {
    category_id: []const u8,
    intensity_class: []const u8,
    description: []const u8,
};

pub const WorkoutRecipe = struct {
    recipe_id: []const u8,
    category_id: []const u8,
    phase_ids: []const []const u8,
    description: []const u8,
    rule_id: []const u8,
};

pub const Policy = struct {
    schema_version: u8,
    policy_id: []const u8,
    policy_version: u16,
    evidence_ledger_id: []const u8,
    support: Support,
    periodization: Periodization,
    baseline_assessment: BaselineAssessment,
    volume_progression: VolumeProgression,
    recovery: Recovery,
    intensity_distribution: IntensityDistribution,
    quality_progression: QualityProgression,
    long_run: LongRun,
    taper: Taper,
    scheduling: Scheduling,
    optional_run: OptionalRun,
    missed_workout: MissedWorkout,
    workout_categories: []const WorkoutCategory,
    workout_recipes: []const WorkoutRecipe,
    rules: []const Rule,
};

pub fn load(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
) !Policy {
    const contents = Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.TrainingPolicyFileNotFound,
        else => return err,
    };
    return std.json.parseFromSliceLeaky(
        Policy,
        allocator,
        contents,
        .{ .ignore_unknown_fields = false },
    ) catch error.InvalidTrainingPolicyFile;
}

pub fn validate(policy: Policy, ledger: evidence_ledger.Ledger) !void {
    try validateSnapshot(policy);
    if (!std.mem.eql(u8, policy.evidence_ledger_id, ledger.ledger_id)) {
        return error.TrainingPolicyEvidenceLedgerMismatch;
    }
    try validateRuleEvidence(policy, ledger);
    try validateEvidenceBacklinks(policy, ledger);
}

pub fn validateSnapshot(policy: Policy) !void {
    if (policy.schema_version != 2) return error.UnsupportedTrainingPolicySchema;
    if (policy.policy_id.len == 0) return error.TrainingPolicyIdentityRequired;
    if (policy.policy_version != 2) return error.UnsupportedTrainingPolicyVersion;
    if (policy.evidence_ledger_id.len == 0) return error.TrainingPolicyEvidenceLedgerRequired;
    if (policy.rules.len == 0) return error.TrainingPolicyNeedsRules;

    try validateRuleStructure(policy);
    try validateSupport(policy.support);
    try validatePeriodization(policy.periodization);
    try validateBaselineAssessment(policy.baseline_assessment);
    try validateProgression(policy);
    try validateQualityProgression(policy);
    try validateWorkouts(policy);
    try validateRuleReferences(policy);
}

pub fn printSummary(writer: *Io.Writer, policy: Policy) !void {
    try writer.print(
        "Training policy is valid: {s} version {d}\n" ++
            "Scope: half marathon, {d}–{d} days, {d}–{d} core running days\n" ++
            "Rules: {d}; phases: {d}; workout recipes: {d}\n" ++
            "Evidence ledger: {s}\n",
        .{
            policy.policy_id,
            policy.policy_version,
            policy.support.minimum_plan_days,
            policy.support.maximum_plan_days,
            policy.support.minimum_core_running_days,
            policy.support.maximum_core_running_days,
            policy.rules.len,
            policy.periodization.phases.len,
            policy.workout_recipes.len,
            policy.evidence_ledger_id,
        },
    );
}

pub fn findRule(policy: Policy, rule_id: []const u8) ?Rule {
    for (policy.rules) |rule| {
        if (std.mem.eql(u8, rule.rule_id, rule_id)) return rule;
    }
    return null;
}

fn validateRuleStructure(policy: Policy) !void {
    for (policy.rules, 0..) |rule, index| {
        if (rule.rule_id.len == 0 or rule.category.len == 0 or rule.summary.len == 0) {
            return error.IncompleteTrainingPolicyRule;
        }
        for (policy.rules[0..index]) |previous| {
            if (std.mem.eql(u8, previous.rule_id, rule.rule_id)) {
                return error.DuplicateTrainingPolicyRuleId;
            }
        }
        if (rule.evidence_ids.len == 0 and rule.product_assumption.len == 0) {
            return error.UnjustifiedTrainingPolicyRule;
        }
        for (rule.evidence_ids, 0..) |evidence_id, evidence_index| {
            if (evidence_id.len == 0) return error.EmptyTrainingPolicyEvidenceId;
            for (rule.evidence_ids[0..evidence_index]) |previous| {
                if (std.mem.eql(u8, previous, evidence_id)) {
                    return error.DuplicateTrainingPolicyEvidenceId;
                }
            }
        }
    }
}

fn validateRuleEvidence(policy: Policy, ledger: evidence_ledger.Ledger) !void {
    for (policy.rules) |rule| {
        for (rule.evidence_ids) |evidence_id| {
            if (findEvidence(ledger, evidence_id) == null) {
                return error.UnknownTrainingPolicyEvidenceId;
            }
        }
    }
}

fn validateSupport(support: Support) !void {
    if (support.race_distance_km <= 0 or
        !std.math.isFinite(support.race_distance_km))
    {
        return error.InvalidTrainingPolicySupport;
    }
    if (support.minimum_plan_days < 1 or
        support.minimum_plan_days > support.maximum_plan_days)
    {
        return error.InvalidTrainingPolicySupport;
    }
    if (support.minimum_core_running_days < 1 or
        support.minimum_core_running_days > support.maximum_core_running_days or
        support.maximum_core_running_days > 7)
    {
        return error.InvalidTrainingPolicySupport;
    }
}

fn validatePeriodization(periodization: Periodization) !void {
    if (periodization.phases.len == 0 or
        periodization.minimum_foundation_weeks == 0 or
        periodization.minimum_race_specific_weeks == 0 or
        periodization.default_taper_weeks == 0)
    {
        return error.InvalidTrainingPolicyPeriodization;
    }
    for (periodization.phases, 0..) |phase, index| {
        if (phase.phase_id.len == 0 or phase.purpose.len == 0) {
            return error.InvalidTrainingPolicyPhase;
        }
        for (periodization.phases[0..index]) |previous| {
            if (std.mem.eql(u8, previous.phase_id, phase.phase_id)) {
                return error.DuplicateTrainingPolicyPhase;
            }
        }
    }
}

fn validateBaselineAssessment(baseline: BaselineAssessment) !void {
    if (baseline.race_equivalence_exponent <= 1 or
        !std.math.isFinite(baseline.race_equivalence_exponent) or
        baseline.high_confidence_performance_age_days == 0 or
        baseline.high_confidence_performance_age_days >
            baseline.maximum_performance_age_days or
        baseline.target_rounding_seconds == 0)
    {
        return error.InvalidBaselineAssessmentPolicy;
    }

    const fractions = [_]f64{
        baseline.five_km_uncertainty_fraction,
        baseline.ten_km_uncertainty_fraction,
        baseline.half_marathon_uncertainty_fraction,
        baseline.hard_effort_extra_uncertainty_fraction,
        baseline.training_result_extra_uncertainty_fraction,
        baseline.old_result_extra_uncertainty_fraction,
        baseline.conflicting_result_threshold_fraction,
        baseline.projected_improvement_per_week_fraction,
        baseline.maximum_projected_improvement_fraction,
        baseline.reduced_readiness_improvement_multiplier,
        baseline.aspirational_gap_limit_fraction,
    };
    for (fractions) |fraction| {
        if (!validFraction(fraction)) return error.InvalidBaselineAssessmentPolicy;
    }
    if (baseline.five_km_uncertainty_fraction <
        baseline.ten_km_uncertainty_fraction or
        baseline.ten_km_uncertainty_fraction <
            baseline.half_marathon_uncertainty_fraction or
        baseline.maximum_projected_improvement_fraction <
            baseline.projected_improvement_per_week_fraction or
        baseline.full_projection_minimum_weekly_distance_km < 0 or
        !std.math.isFinite(
            baseline.full_projection_minimum_weekly_distance_km,
        ) or
        baseline.full_projection_minimum_long_run_km < 0 or
        !std.math.isFinite(baseline.full_projection_minimum_long_run_km) or
        baseline.easy_pace_minimum_seconds_slower_per_km >
            baseline.easy_pace_maximum_seconds_slower_per_km)
    {
        return error.InvalidBaselineAssessmentPolicy;
    }
}

fn validateProgression(policy: Policy) !void {
    if (!validFraction(
        policy.volume_progression.maximum_build_increase_fraction,
    ) or
        policy.volume_progression.maximum_peak_relative_to_baseline < 1 or
        !std.math.isFinite(
            policy.volume_progression.maximum_peak_relative_to_baseline,
        ))
    {
        return error.InvalidVolumeProgressionPolicy;
    }
    if (policy.recovery.minimum_build_weeks_between_recovery == 0 or
        policy.recovery.minimum_build_weeks_between_recovery >
            policy.recovery.maximum_build_weeks_between_recovery or
        !validOrderedFractions(
            policy.recovery.minimum_volume_fraction,
            policy.recovery.maximum_volume_fraction,
        ))
    {
        return error.InvalidRecoveryPolicy;
    }
    if (!validOrderedFractions(
        policy.intensity_distribution.minimum_low_intensity_fraction,
        policy.intensity_distribution.maximum_low_intensity_fraction,
    ) or
        policy.intensity_distribution.maximum_quality_sessions_per_week == 0 or
        policy.intensity_distribution.easy_effort_guidance.len == 0 or
        policy.intensity_distribution.quality_effort_guidance.len == 0)
    {
        return error.InvalidIntensityDistributionPolicy;
    }
    if (policy.long_run.maximum_weekly_increase_km <= 0 or
        !std.math.isFinite(policy.long_run.maximum_weekly_increase_km) or
        !validFraction(policy.long_run.maximum_weekly_distance_fraction) or
        policy.long_run.maximum_peak_distance_km <= 0 or
        !std.math.isFinite(policy.long_run.maximum_peak_distance_km))
    {
        return error.InvalidLongRunPolicy;
    }
    if (policy.taper.minimum_days == 0 or
        policy.taper.minimum_days > policy.taper.maximum_days or
        !validOrderedFractions(
            policy.taper.minimum_volume_reduction_fraction,
            policy.taper.maximum_volume_reduction_fraction,
        ) or
        !policy.taper.maintain_intensity or
        !policy.taper.maintain_core_frequency)
    {
        return error.InvalidTaperPolicy;
    }
    if (policy.scheduling.minimum_easy_or_rest_days_between_demanding_sessions == 0) {
        return error.InvalidSchedulingPolicy;
    }
    if (!validFraction(policy.optional_run.maximum_weekly_distance_fraction) or
        !policy.optional_run.may_be_removed_without_rescheduling)
    {
        return error.InvalidOptionalRunPolicy;
    }
    if (policy.missed_workout.stack_later_in_week or
        !policy.missed_workout.preserve_hard_session_spacing)
    {
        return error.InvalidMissedWorkoutPolicy;
    }
}

fn validateQualityProgression(policy: Policy) !void {
    const progression = policy.quality_progression;
    if (!validFraction(progression.target_weekly_distance_fraction) or
        !validFraction(progression.maximum_weekly_distance_fraction) or
        progression.target_weekly_distance_fraction >
            progression.maximum_weekly_distance_fraction or
        progression.maximum_session_distance_km <= 0 or
        !std.math.isFinite(progression.maximum_session_distance_km) or
        progression.minimum_warmup_cooldown_km <= 0 or
        !std.math.isFinite(progression.minimum_warmup_cooldown_km) or
        progression.maximum_warmup_cooldown_km <
            progression.minimum_warmup_cooldown_km or
        !std.math.isFinite(progression.maximum_warmup_cooldown_km) or
        progression.foundation_repetition_distance_km <= 0 or
        !std.math.isFinite(progression.foundation_repetition_distance_km) or
        !validFraction(progression.foundation_initial_work_fraction) or
        progression.foundation_weekly_work_increase_km <= 0 or
        !std.math.isFinite(progression.foundation_weekly_work_increase_km) or
        progression.interval_recovery_seconds == 0 or
        !validFraction(progression.recovery_work_fraction) or
        progression.race_week_work_distance_km <= 0 or
        !std.math.isFinite(progression.race_week_work_distance_km))
    {
        return error.InvalidQualityProgressionPolicy;
    }
    if (progression.maximum_session_distance_km <=
        progression.minimum_warmup_cooldown_km * 2)
    {
        return error.InvalidQualityProgressionPolicy;
    }
}

fn validateWorkouts(policy: Policy) !void {
    if (policy.workout_categories.len == 0 or policy.workout_recipes.len == 0) {
        return error.TrainingPolicyNeedsWorkoutRecipes;
    }
    for (policy.workout_categories, 0..) |category, index| {
        if (category.category_id.len == 0 or category.intensity_class.len == 0 or
            category.description.len == 0)
        {
            return error.InvalidWorkoutCategory;
        }
        for (policy.workout_categories[0..index]) |previous| {
            if (std.mem.eql(u8, previous.category_id, category.category_id)) {
                return error.DuplicateWorkoutCategory;
            }
        }
    }
    for (policy.workout_recipes, 0..) |recipe, index| {
        if (recipe.recipe_id.len == 0 or recipe.description.len == 0 or
            recipe.phase_ids.len == 0)
        {
            return error.InvalidWorkoutRecipe;
        }
        for (policy.workout_recipes[0..index]) |previous| {
            if (std.mem.eql(u8, previous.recipe_id, recipe.recipe_id)) {
                return error.DuplicateWorkoutRecipe;
            }
        }
        if (!hasCategory(policy, recipe.category_id)) {
            return error.UnknownWorkoutCategory;
        }
        for (recipe.phase_ids) |phase_id| {
            if (!hasPhase(policy, phase_id)) return error.UnknownWorkoutPhase;
        }
    }
}

fn validateRuleReferences(policy: Policy) !void {
    const quality_progression = policy.quality_progression;
    const rule_ids = [_][]const u8{
        policy.support.rule_id,
        policy.periodization.rule_id,
        policy.baseline_assessment.rule_id,
        policy.baseline_assessment.target_rule_id,
        policy.volume_progression.rule_id,
        policy.recovery.rule_id,
        policy.intensity_distribution.rule_id,
        quality_progression.rule_id,
        policy.long_run.rule_id,
        policy.taper.rule_id,
        policy.scheduling.rule_id,
        policy.optional_run.rule_id,
        policy.missed_workout.rule_id,
    };
    for (rule_ids) |rule_id| {
        if (findRule(policy, rule_id) == null) {
            return error.UnknownTrainingPolicyRuleReference;
        }
    }
    for (policy.workout_recipes) |recipe| {
        if (findRule(policy, recipe.rule_id) == null) {
            return error.UnknownTrainingPolicyRuleReference;
        }
    }
}

fn validateEvidenceBacklinks(
    policy: Policy,
    ledger: evidence_ledger.Ledger,
) !void {
    for (policy.rules) |rule| {
        for (rule.evidence_ids) |evidence_id| {
            const evidence = findEvidence(ledger, evidence_id).?;
            if (!containsString(evidence.policy_rule_ids, rule.rule_id)) {
                return error.MissingEvidencePolicyBacklink;
            }
        }
    }
    for (ledger.entries) |evidence| {
        for (evidence.policy_rule_ids) |rule_id| {
            const rule = findRule(policy, rule_id) orelse
                return error.UnknownEvidencePolicyRule;
            if (!containsString(rule.evidence_ids, evidence.evidence_id)) {
                return error.MissingPolicyEvidenceBacklink;
            }
        }
    }
}

fn findEvidence(
    ledger: evidence_ledger.Ledger,
    evidence_id: []const u8,
) ?evidence_ledger.Entry {
    for (ledger.entries) |entry| {
        if (std.mem.eql(u8, entry.evidence_id, evidence_id)) return entry;
    }
    return null;
}

fn hasCategory(policy: Policy, category_id: []const u8) bool {
    for (policy.workout_categories) |category| {
        if (std.mem.eql(u8, category.category_id, category_id)) return true;
    }
    return false;
}

fn hasPhase(policy: Policy, phase_id: []const u8) bool {
    for (policy.periodization.phases) |phase| {
        if (std.mem.eql(u8, phase.phase_id, phase_id)) return true;
    }
    return false;
}

fn containsString(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, expected)) return true;
    }
    return false;
}

fn validFraction(value: f64) bool {
    return value >= 0 and value <= 1 and std.math.isFinite(value);
}

fn validOrderedFractions(minimum: f64, maximum: f64) bool {
    return validFraction(minimum) and validFraction(maximum) and minimum <= maximum;
}

test "validates the committed half marathon policy and evidence links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const ledger = try std.json.parseFromSliceLeaky(
        evidence_ledger.Ledger,
        allocator,
        @embedFile("../evidence/half-marathon.json"),
        .{ .ignore_unknown_fields = false },
    );
    const policy = try std.json.parseFromSliceLeaky(
        Policy,
        allocator,
        @embedFile("../policies/half-marathon.json"),
        .{ .ignore_unknown_fields = false },
    );
    try evidence_ledger.validate(ledger);
    try validate(policy, ledger);
}

test "training policy schema is valid JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        @embedFile("../schemas/training-policy.schema.json"),
        .{},
    );
}

test "rejects a policy rule without reciprocal evidence linkage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const ledger = try std.json.parseFromSliceLeaky(
        evidence_ledger.Ledger,
        allocator,
        @embedFile("../evidence/half-marathon.json"),
        .{ .ignore_unknown_fields = false },
    );
    var policy = try std.json.parseFromSliceLeaky(
        Policy,
        allocator,
        @embedFile("../policies/half-marathon.json"),
        .{ .ignore_unknown_fields = false },
    );
    const rules = try allocator.dupe(Rule, policy.rules);
    rules[0].evidence_ids = &.{"E-TAPER-001"};
    policy.rules = rules;

    try std.testing.expectError(
        error.MissingEvidencePolicyBacklink,
        validate(policy, ledger),
    );
}
