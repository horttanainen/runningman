const std = @import("std");
const assessment = @import("assessment.zig");
const date = @import("date.zig");
const model = @import("model.zig");
const plan_provenance = @import("plan_provenance.zig");
const plan_revision = @import("plan_revision.zig");
const plan_validator = @import("plan_validator.zig");
const runner_profile = @import("runner_profile.zig");
const training_policy = @import("training_policy.zig");

const Io = std.Io;

const QualityPlan = struct {
    stage_id: []const u8,
    load_method: plan_provenance.QualityLoadMethod,
    phase_week: u8,
    phase_week_count: u8,
    session_km: f64,
    warmup_km: f64,
    work_km: f64,
    cooldown_km: f64,
    previous_work_km: ?f64,
    repetition_km: ?f64,
    repetitions: u8,
    recovery_seconds: ?u16,
};

const MacroWeek = struct {
    phase: []const u8,
    target_km: f64,
    long_km: f64,
    volume_method: plan_provenance.VolumeMethod,
    previous_progression_km: ?f64,
    applied_volume_fraction: ?f64,
    previous_long_km: ?f64,
    long_weekly_share_limit_km: f64,
    long_progression_limit_km: f64,
    phase_week: u8,
    phase_week_count: u8,
    quality: QualityPlan,
};

const PaceProfile = struct {
    anchored: bool,
    easy_fast: u16,
    easy_slow: u16,
    quality_fast: u16,
    quality_slow: u16,
    race_fast: u16,
    race_slow: u16,
};

pub fn generate(
    allocator: std.mem.Allocator,
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    result: assessment.Assessment,
    evidence_ledger_id: []const u8,
    source_hashes: plan_provenance.SourceHashes,
    base_schedule_id: u64,
) !plan_revision.RevisionFile {
    const profile_summary = try runner_profile.validate(profile);
    if (isUnavailable(profile, profile.goal.race_date.value)) {
        return error.RaceDateUnavailable;
    }

    const week_count = (@as(usize, profile_summary.plan_days) + 6) / 7;
    const macrocycle = try buildMacrocycle(allocator, profile, policy, week_count);
    const paces = derivePaces(result, policy);
    const proposed_weeks = try buildProposedWeeks(
        allocator,
        profile,
        policy,
        macrocycle,
        profile_summary.plan_days,
    );
    const workouts = try allocateWorkouts(
        allocator,
        profile,
        policy,
        macrocycle,
        profile_summary.plan_days,
        paces,
        result.training_pace_anchor_seconds,
    );

    const assessment_snapshot = assessmentSnapshot(profile, policy, result);

    const target_text = if (result.training_pace_anchor_seconds) |target|
        try std.fmt.allocPrint(allocator, "Supported half-marathon target: {d}:{d:0>2}:{d:0>2}", .{
            target / 3600,
            target % 3600 / 60,
            target % 60,
        })
    else
        "Completion goal using effort-based guidance";
    const availability = try std.fmt.allocPrint(
        allocator,
        "{d} core running days per week; long run preference {s}",
        .{ profile.availability.running_days.value.len, @tagName(profile.availability.preferred_long_run_day.value) },
    );
    const pace_text = if (result.training_pace_anchor_seconds != null)
        try std.fmt.allocPrint(
            allocator,
            "Easy {d}:{d:0>2}–{d}:{d:0>2}/km, {d:.1}–{d:.1} km/h; " ++
                "race anchor {d}:{d:0>2}/km, {d:.1} km/h",
            .{
                paces.easy_fast / 60,
                paces.easy_fast % 60,
                paces.easy_slow / 60,
                paces.easy_slow % 60,
                speedForPace(paces.easy_slow),
                speedForPace(paces.easy_fast),
                paces.race_fast / 60,
                paces.race_fast % 60,
                speedForPace(paces.race_fast),
            },
        )
    else
        "Paces unavailable; use the stated RPE and conversational guidance";

    const revision: plan_revision.RevisionFile = .{
        .schema_version = 2,
        .base_schedule_id = base_schedule_id,
        .effective_from = profile.plan_start_date.value,
        .reason = "Generated from runner profile and half-marathon policy.",
        .name = "Generated periodized half-marathon plan",
        .goal = target_text,
        .availability = availability,
        .intensity_guidance = policy.intensity_distribution.easy_effort_guidance,
        .pace_profile = pace_text,
        .race_date = profile.goal.race_date.value,
        .provenance = .{
            .generator_version = plan_provenance.generator_version,
            .runner_profile_sha256 = source_hashes.runner_profile_sha256,
            .training_policy_sha256 = source_hashes.training_policy_sha256,
            .evidence_ledger_id = evidence_ledger_id,
            .evidence_ledger_sha256 = source_hashes.evidence_ledger_sha256,
            .runner_profile = profile,
            .training_policy = policy,
            .assessment = assessment_snapshot,
        },
        .assessment = assessment_snapshot,
        .weeks = proposed_weeks,
        .workouts = workouts,
    };
    try plan_validator.validate(allocator, profile, policy, result, revision);
    return revision;
}

fn buildProposedWeeks(
    allocator: std.mem.Allocator,
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    macrocycle: []const MacroWeek,
    plan_days: u16,
) ![]plan_revision.ProposedWeek {
    const start = try date.parse(profile.plan_start_date.value);
    const result = try allocator.alloc(plan_revision.ProposedWeek, macrocycle.len);
    for (macrocycle, 0..) |week, index| {
        const first_offset = index * 7;
        const final_offset = @min(first_offset + 6, @as(usize, plan_days) - 1);
        result[index] = .{
            .week = @intCast(index + 1),
            .start_date = try date.format(allocator, date.addDays(start, @intCast(first_offset))),
            .end_date = try date.format(allocator, date.addDays(start, @intCast(final_offset))),
            .phase = week.phase,
            .target_core_distance_km = week.target_km,
            .long_run_distance_km = week.long_km,
            .decision = .{
                .periodization_rule_id = policy.periodization.rule_id,
                .volume_rule_id = policy.volume_progression.rule_id,
                .long_run_rule_id = policy.long_run.rule_id,
                .recovery_rule_id = if (week.volume_method == .recovery_reduction)
                    policy.recovery.rule_id
                else
                    null,
                .taper_rule_id = if (week.volume_method == .taper_reduction)
                    policy.taper.rule_id
                else
                    null,
                .baseline_weekly_distance_km = profile.baseline.average_weekly_distance_km.value,
                .baseline_weekly_distance_source = profile.baseline.average_weekly_distance_km.source,
                .volume_method = week.volume_method,
                .previous_progression_distance_km = week.previous_progression_km,
                .applied_volume_fraction = week.applied_volume_fraction,
                .peak_volume_limit_km = profile.baseline.average_weekly_distance_km.value *
                    policy.volume_progression.maximum_peak_relative_to_baseline,
                .baseline_longest_run_km = profile.baseline.longest_run_km.value,
                .baseline_longest_run_source = profile.baseline.longest_run_km.source,
                .previous_long_run_distance_km = week.previous_long_km,
                .long_run_weekly_share_limit_km = week.long_weekly_share_limit_km,
                .long_run_progression_limit_km = week.long_progression_limit_km,
                .phase_week = week.phase_week,
                .phase_week_count = week.phase_week_count,
            },
        };
    }
    return result;
}

pub fn save(io: Io, path: []const u8, revision: plan_revision.RevisionFile) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &buffer);
    try std.json.Stringify.value(
        revision,
        .{ .whitespace = .indent_2, .emit_null_optional_fields = false },
        &file_writer.interface,
    );
    try file_writer.interface.writeByte('\n');
    try file_writer.flush();
}

fn buildMacrocycle(
    allocator: std.mem.Allocator,
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    week_count: usize,
) ![]MacroWeek {
    const reserved = @as(usize, policy.periodization.minimum_race_specific_weeks) +
        @as(usize, policy.periodization.default_taper_weeks) + 1;
    if (week_count < @as(usize, policy.periodization.minimum_foundation_weeks) + reserved) {
        return error.PlanTooShortForPolicyPhases;
    }

    const weeks = try allocator.alloc(MacroWeek, week_count);
    const pre_specific_count = week_count - reserved;
    const baseline = profile.baseline.average_weekly_distance_km.value;
    const maximum = baseline * policy.volume_progression.maximum_peak_relative_to_baseline;
    var progression_volume = baseline;
    var prior_long = @min(profile.baseline.longest_run_km.value, baseline * policy.long_run.maximum_weekly_distance_fraction);
    var build_since_recovery: u8 = 0;
    var peak: f64 = baseline;

    for (weeks, 0..) |*week, index| {
        week.previous_progression_km = null;
        week.applied_volume_fraction = null;
        if (index < pre_specific_count) {
            const foundation = index < policy.periodization.minimum_foundation_weeks;
            const recovery = !foundation and build_since_recovery >=
                policy.recovery.minimum_build_weeks_between_recovery;
            if (recovery) {
                week.phase = "recovery";
                week.volume_method = .recovery_reduction;
                week.previous_progression_km = progression_volume;
                week.applied_volume_fraction = policy.recovery.maximum_volume_fraction;
                week.target_km = roundHalf(progression_volume * policy.recovery.maximum_volume_fraction);
                build_since_recovery = 0;
            } else {
                week.phase = if (foundation) "foundation" else "build";
                if (index > 0) {
                    week.volume_method = .build_progression;
                    week.previous_progression_km = progression_volume;
                    week.applied_volume_fraction = 1 +
                        policy.volume_progression.maximum_build_increase_fraction * 0.8;
                    progression_volume = @min(
                        maximum,
                        roundHalf(progression_volume * (1 + policy.volume_progression.maximum_build_increase_fraction * 0.8)),
                    );
                } else {
                    week.volume_method = .baseline;
                }
                week.target_km = progression_volume;
                if (!foundation) build_since_recovery += 1;
                peak = @max(peak, week.target_km);
            }
        } else if (index < pre_specific_count + policy.periodization.minimum_race_specific_weeks) {
            week.phase = "race_specific";
            week.volume_method = .race_specific_progression;
            week.previous_progression_km = progression_volume;
            week.applied_volume_fraction = 1 +
                policy.volume_progression.maximum_build_increase_fraction * 0.6;
            progression_volume = @min(
                maximum,
                roundHalf(progression_volume * (1 + policy.volume_progression.maximum_build_increase_fraction * 0.6)),
            );
            week.target_km = progression_volume;
            peak = @max(peak, week.target_km);
        } else if (index < week_count - 1) {
            week.phase = "taper";
            week.volume_method = .taper_reduction;
            const taper_index = index - (pre_specific_count + policy.periodization.minimum_race_specific_weeks);
            const fraction: f64 = if (taper_index == 0) 0.59 else 0.50;
            week.previous_progression_km = peak;
            week.applied_volume_fraction = fraction;
            week.target_km = roundHalf(peak * fraction);
        } else {
            week.phase = "race";
            week.volume_method = .race_week;
            week.target_km = policy.support.race_distance_km +
                @max(0.0, baseline * 0.4);
        }

        if (std.mem.eql(u8, week.phase, "race")) {
            week.long_km = 0;
            week.previous_long_km = prior_long;
            week.long_weekly_share_limit_km =
                week.target_km * policy.long_run.maximum_weekly_distance_fraction;
            week.long_progression_limit_km = prior_long +
                policy.long_run.maximum_weekly_increase_km;
            continue;
        }
        week.previous_long_km = prior_long;
        week.long_weekly_share_limit_km =
            week.target_km * policy.long_run.maximum_weekly_distance_fraction;
        week.long_progression_limit_km =
            prior_long + policy.long_run.maximum_weekly_increase_km;
        var desired = @min(
            policy.long_run.maximum_peak_distance_km,
            week.target_km * policy.long_run.maximum_weekly_distance_fraction,
        );
        if (std.mem.eql(u8, week.phase, "recovery")) desired = @min(desired, prior_long);
        desired = @min(desired, prior_long + policy.long_run.maximum_weekly_increase_km);
        week.long_km = floorHalf(desired);
        prior_long = week.long_km;
    }
    try buildQualityProgression(policy, weeks);
    return weeks;
}

fn buildQualityProgression(
    policy: training_policy.Policy,
    weeks: []MacroWeek,
) !void {
    const progression = policy.quality_progression;
    var previous_work_km: ?f64 = null;

    for (weeks, 0..) |*week, index| {
        const phase_position = phasePosition(weeks, index);
        week.phase_week = phase_position.week;
        week.phase_week_count = phase_position.count;
        week.quality = qualityPlan(
            progression,
            week.phase,
            week.target_km,
            phase_position.week,
            phase_position.count,
            previous_work_km,
        );
        previous_work_km = week.quality.work_km;
    }
}

const PhasePosition = struct {
    week: u8,
    count: u8,
};

fn phasePosition(weeks: []const MacroWeek, index: usize) PhasePosition {
    var first = index;
    while (first > 0 and std.mem.eql(u8, weeks[first - 1].phase, weeks[index].phase)) {
        first -= 1;
    }
    var final = index + 1;
    while (final < weeks.len and std.mem.eql(u8, weeks[final].phase, weeks[index].phase)) {
        final += 1;
    }
    return .{
        .week = @intCast(index - first + 1),
        .count = @intCast(final - first),
    };
}

fn qualityPlan(
    progression: training_policy.QualityProgression,
    phase: []const u8,
    target_km: f64,
    phase_week: u8,
    phase_week_count: u8,
    previous_work_km: ?f64,
) QualityPlan {
    const minimum_support_km = progression.minimum_warmup_cooldown_km * 2;
    const weekly_target = target_km * progression.target_weekly_distance_fraction;
    const weekly_cap = target_km * progression.maximum_weekly_distance_fraction;
    var session_km = roundHalf(@min(progression.maximum_session_distance_km, weekly_target));
    var stage_id: []const u8 = "build-threshold";
    var load_method: plan_provenance.QualityLoadMethod = .progress_work;
    var work_km: f64 = 0;
    var repetition_km: ?f64 = null;
    var recovery_seconds: ?u16 = null;

    if (std.mem.eql(u8, phase, "foundation")) {
        stage_id = "foundation-aerobic-intervals";
        load_method = if (phase_week == 1) .establish else .progress_work;
        repetition_km = progression.foundation_repetition_distance_km;
        recovery_seconds = progression.interval_recovery_seconds;
        const desired_work = target_km * progression.foundation_initial_work_fraction +
            @as(f64, @floatFromInt(phase_week - 1)) *
                progression.foundation_weekly_work_increase_km;
        work_km = roundToMultiple(desired_work, repetition_km.?);
    } else if (std.mem.eql(u8, phase, "build")) {
        stage_id = "build-continuous-threshold";
        work_km = @max(
            previous_work_km orelse 0,
            roundHalf(
                session_km * 0.5 +
                    @as(f64, @floatFromInt(phase_week - 1)) * 0.5,
            ),
        );
    } else if (std.mem.eql(u8, phase, "recovery")) {
        stage_id = "recovery-aerobic-intervals";
        load_method = .recovery_reduction;
        repetition_km = progression.foundation_repetition_distance_km;
        recovery_seconds = progression.interval_recovery_seconds;
        const previous = previous_work_km orelse
            target_km * progression.foundation_initial_work_fraction;
        work_km = roundToMultiple(
            previous * progression.recovery_work_fraction,
            repetition_km.?,
        );
    } else if (std.mem.eql(u8, phase, "race_specific")) {
        stage_id = "race-specific-half-marathon-pace";
        load_method = .race_specific_progression;
        work_km = @max(
            previous_work_km orelse 0,
            roundHalf(
                session_km * 0.5 +
                    @as(f64, @floatFromInt(phase_week - 1)) * 0.5,
            ),
        );
    } else if (std.mem.eql(u8, phase, "taper")) {
        stage_id = "taper-half-marathon-pace";
        load_method = .taper_reduction;
        work_km = roundHalf(session_km * 0.45);
    } else {
        stage_id = "race-week-sharpening";
        load_method = .race_sharpening;
        work_km = @min(
            progression.race_week_work_distance_km,
            previous_work_km orelse progression.race_week_work_distance_km,
        );
        session_km = work_km + minimum_support_km;
    }

    const maximum_work = @max(1.0, session_km - minimum_support_km);
    work_km = @min(work_km, maximum_work);
    if (repetition_km) |distance_km| {
        work_km = @max(distance_km, floorToMultiple(work_km, distance_km));
    } else {
        work_km = @max(1.0, roundHalf(work_km));
    }
    session_km = @max(session_km, work_km + minimum_support_km);
    session_km = @min(
        session_km,
        work_km + progression.maximum_warmup_cooldown_km * 2,
    );
    session_km = @min(session_km, floorHalf(weekly_cap));

    const support_km = session_km - work_km;
    var warmup_km = roundHalf(@min(
        progression.maximum_warmup_cooldown_km,
        @max(progression.minimum_warmup_cooldown_km, support_km / 2),
    ));
    var cooldown_km = support_km - warmup_km;
    if (cooldown_km < progression.minimum_warmup_cooldown_km) {
        cooldown_km = progression.minimum_warmup_cooldown_km;
        warmup_km = support_km - cooldown_km;
    }

    const repetitions: u8 = if (repetition_km) |distance_km|
        @intFromFloat(@round(work_km / distance_km))
    else
        1;
    return .{
        .stage_id = stage_id,
        .load_method = load_method,
        .phase_week = phase_week,
        .phase_week_count = phase_week_count,
        .session_km = session_km,
        .warmup_km = warmup_km,
        .work_km = work_km,
        .cooldown_km = cooldown_km,
        .previous_work_km = previous_work_km,
        .repetition_km = repetition_km,
        .repetitions = repetitions,
        .recovery_seconds = recovery_seconds,
    };
}

fn roundToMultiple(value: f64, multiple: f64) f64 {
    return @round(value / multiple) * multiple;
}

fn floorToMultiple(value: f64, multiple: f64) f64 {
    return @floor(value / multiple) * multiple;
}

fn allocateWorkouts(
    allocator: std.mem.Allocator,
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    weeks: []const MacroWeek,
    plan_days: u16,
    paces: PaceProfile,
    training_pace_anchor_seconds: ?u32,
) ![]plan_revision.ProposedWorkout {
    const workouts = try allocator.alloc(plan_revision.ProposedWorkout, plan_days);
    const start = try date.parse(profile.plan_start_date.value);
    const race_date = try date.parse(profile.goal.race_date.value);
    var output_index: usize = 0;

    for (weeks, 0..) |week, week_index| {
        const first_day_index = week_index * 7;
        const days_this_week = @min(@as(usize, 7), @as(usize, plan_days) - first_day_index);
        const long_day = if (std.mem.eql(u8, week.phase, "race"))
            null
        else
            try chooseLongDay(profile, start, first_day_index, days_this_week);
        const quality_day = try chooseQualityDay(
            profile,
            policy,
            start,
            first_day_index,
            days_this_week,
            long_day,
            race_date,
        );

        var core_run_count: usize = 0;
        for (0..days_this_week) |offset| {
            const current = date.addDays(start, @intCast(first_day_index + offset));
            const text = try date.format(allocator, current);
            if (isUnavailable(profile, text)) continue;
            const weekday: runner_profile.Weekday = @enumFromInt(date.weekday(current));
            if (containsWeekday(profile.availability.running_days.value, weekday) and
                date.compare(current, race_date) != .eq)
            {
                core_run_count += 1;
            }
        }
        if (!std.mem.eql(u8, week.phase, "race") and core_run_count < 3) {
            return error.NotEnoughAvailableRunningDays;
        }

        const quality_km = if (quality_day != null) week.quality.session_km else 0;
        const reserved_race = if (std.mem.eql(u8, week.phase, "race")) policy.support.race_distance_km else 0;
        const easy_count = core_run_count - @intFromBool(long_day != null) - @intFromBool(quality_day != null);
        const easy_total = @max(0.0, week.target_km - week.long_km - quality_km - reserved_race);
        const easy_km = if (easy_count > 0) roundHalf(easy_total / @as(f64, @floatFromInt(easy_count))) else 0;
        var easy_assigned: usize = 0;

        for (0..days_this_week) |offset| {
            const absolute_index = first_day_index + offset;
            const current = date.addDays(start, @intCast(absolute_index));
            const text = try date.format(allocator, current);
            const weekday: runner_profile.Weekday = @enumFromInt(date.weekday(current));

            if (date.compare(current, race_date) == .eq) {
                workouts[output_index] = try raceWorkout(allocator, text, week.phase, policy, paces);
            } else if (isUnavailable(profile, text)) {
                workouts[output_index] = try restWorkout(allocator, text, week.phase, "Unavailable date from runner profile.");
            } else if (long_day != null and absolute_index == long_day.?) {
                workouts[output_index] = try distanceWorkout(
                    allocator,
                    text,
                    week.phase,
                    "long",
                    week.long_km,
                    paces.easy_fast,
                    paces.easy_slow,
                    paces.anchored,
                    "Long easy run",
                    policy.intensity_distribution.easy_effort_guidance,
                );
            } else if (quality_day != null and absolute_index == quality_day.?) {
                workouts[output_index] = try qualityWorkout(
                    allocator,
                    text,
                    week.phase,
                    week.quality,
                    paces,
                    policy,
                );
            } else if (containsWeekday(profile.availability.running_days.value, weekday)) {
                easy_assigned += 1;
                const remaining = easy_total - easy_km * @as(f64, @floatFromInt(easy_assigned - 1));
                const distance_km = if (easy_assigned == easy_count) remaining else easy_km;
                workouts[output_index] = try distanceWorkout(
                    allocator,
                    text,
                    week.phase,
                    "easy",
                    @max(1.0, distance_km),
                    paces.easy_fast,
                    paces.easy_slow,
                    paces.anchored,
                    "Easy aerobic run",
                    policy.intensity_distribution.easy_effort_guidance,
                );
            } else if (profile.availability.optional_recovery_day) |optional| {
                if (optional.value == weekday and !std.mem.eql(u8, week.phase, "taper") and
                    !std.mem.eql(u8, week.phase, "race"))
                {
                    const optional_km = floorHalf(@min(4.0, week.target_km * policy.optional_run.maximum_weekly_distance_fraction));
                    workouts[output_index] = try distanceWorkout(
                        allocator,
                        text,
                        week.phase,
                        "optional-recovery",
                        optional_km,
                        paces.easy_slow,
                        paces.easy_slow + 30,
                        paces.anchored,
                        "Optional recovery run — remove freely if recovery or schedule calls for it",
                        "Very easy, RPE 2–3 out of 10.",
                    );
                } else {
                    workouts[output_index] = try restWorkout(allocator, text, week.phase, "Rest day.");
                }
            } else {
                workouts[output_index] = try restWorkout(allocator, text, week.phase, "Rest day.");
            }
            workouts[output_index].decision = try workoutDecision(
                allocator,
                profile,
                policy,
                workouts[output_index],
                week.target_km,
                weekday,
                training_pace_anchor_seconds,
                if (std.mem.eql(u8, workouts[output_index].kind, "quality"))
                    week.quality
                else
                    null,
            );
            output_index += 1;
        }
    }
    return workouts;
}

fn assessmentSnapshot(
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    result: assessment.Assessment,
) plan_provenance.AssessmentSnapshot {
    return .{
        .profile_id = profile.profile_id,
        .policy_id = policy.policy_id,
        .policy_version = policy.policy_version,
        .confidence = @tagName(result.confidence),
        .feasibility = @tagName(result.feasibility),
        .recommended_target_seconds = result.planner_recommended_target_seconds,
        .requested_target_seconds = result.requested_target_seconds,
        .training_pace_anchor_seconds = result.training_pace_anchor_seconds,
        .expected_shortfall_seconds = result.expected_shortfall_seconds,
    };
}

fn workoutDecision(
    allocator: std.mem.Allocator,
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    workout: plan_revision.ProposedWorkout,
    week_target_km: f64,
    scheduled_weekday: runner_profile.Weekday,
    training_pace_anchor_seconds: ?u32,
    quality_plan: ?QualityPlan,
) !plan_provenance.WorkoutDecision {
    const role: plan_provenance.AllocationRole = if (std.mem.eql(u8, workout.kind, "rest"))
        .rest
    else if (std.mem.eql(u8, workout.kind, "easy"))
        .easy
    else if (std.mem.eql(u8, workout.kind, "optional-recovery"))
        .optional_recovery
    else if (std.mem.eql(u8, workout.kind, "quality"))
        .quality
    else if (std.mem.eql(u8, workout.kind, "long"))
        .long_run
    else if (std.mem.eql(u8, workout.kind, "race"))
        .race
    else
        return error.UnknownGeneratedWorkoutKind;
    const recipe_id = recipeId(role, workout.phase);
    const recipe = findRecipe(policy, recipe_id) orelse
        return error.GeneratedWorkoutRecipeNotFound;

    const rule_ids_buffer = try allocator.alloc([]const u8, 4);
    var rule_count: usize = 0;
    appendUniqueRule(rule_ids_buffer, &rule_count, recipe.rule_id);
    switch (role) {
        .rest, .easy => {},
        .optional_recovery => appendUniqueRule(
            rule_ids_buffer,
            &rule_count,
            policy.optional_run.rule_id,
        ),
        .quality => {
            appendUniqueRule(
                rule_ids_buffer,
                &rule_count,
                policy.intensity_distribution.rule_id,
            );
            appendUniqueRule(
                rule_ids_buffer,
                &rule_count,
                policy.scheduling.rule_id,
            );
        },
        .long_run => {
            appendUniqueRule(rule_ids_buffer, &rule_count, policy.long_run.rule_id);
            appendUniqueRule(rule_ids_buffer, &rule_count, policy.scheduling.rule_id);
        },
        .race => appendUniqueRule(rule_ids_buffer, &rule_count, policy.support.rule_id),
    }

    const preferred_weekday: ?runner_profile.Weekday = switch (role) {
        .long_run => profile.availability.preferred_long_run_day.value,
        .quality => if (profile.availability.preferred_quality_day) |preferred|
            preferred.value
        else
            null,
        .optional_recovery => if (profile.availability.optional_recovery_day) |preferred|
            preferred.value
        else
            null,
        else => null,
    };
    const distance_method: plan_provenance.DistanceMethod = switch (role) {
        .rest => .none,
        .easy => .weekly_remainder,
        .optional_recovery => .optional_weekly_fraction,
        .quality => .quality_progression,
        .long_run => .weekly_long_run,
        .race => .race_distance,
    };
    const pace_method: plan_provenance.PaceMethod = if (role == .rest)
        .none
    else if (training_pace_anchor_seconds == null)
        .effort_only
    else switch (role) {
        .easy, .optional_recovery, .long_run => .easy_anchor_offset,
        .quality => .quality_anchor_offset,
        .race => .race_anchor,
        .rest => .none,
    };

    return .{
        .recipe_id = recipe_id,
        .rule_ids = rule_ids_buffer[0..rule_count],
        .allocation_role = role,
        .distance_method = distance_method,
        .pace_method = pace_method,
        .week_target_core_distance_km = week_target_km,
        .allocated_distance_km = proposedWorkoutDistance(workout),
        .training_pace_anchor_seconds = training_pace_anchor_seconds,
        .scheduled_weekday = scheduled_weekday,
        .preferred_weekday = preferred_weekday,
        .preference_honored = if (preferred_weekday) |preferred|
            preferred == scheduled_weekday
        else
            null,
        .quality_progression = if (quality_plan) |quality| .{
            .stage_id = quality.stage_id,
            .load_method = quality.load_method,
            .phase_week = quality.phase_week,
            .phase_week_count = quality.phase_week_count,
            .work_distance_km = quality.work_km,
            .previous_work_distance_km = quality.previous_work_km,
            .repetition_distance_km = quality.repetition_km,
            .repetitions = quality.repetitions,
            .recovery_seconds = quality.recovery_seconds,
        } else null,
    };
}

fn recipeId(role: plan_provenance.AllocationRole, phase: []const u8) []const u8 {
    return switch (role) {
        .rest => "rest-day",
        .easy => "easy-distance",
        .optional_recovery => "optional-recovery",
        .long_run => "long-easy",
        .race => "half-marathon-race",
        .quality => if (std.mem.eql(u8, phase, "foundation") or
            std.mem.eql(u8, phase, "recovery"))
            "aerobic-intervals"
        else if (std.mem.eql(u8, phase, "build"))
            "continuous-threshold"
        else if (std.mem.eql(u8, phase, "race"))
            "race-week-sharpening"
        else
            "half-marathon-segments",
    };
}

fn findRecipe(
    policy: training_policy.Policy,
    recipe_id: []const u8,
) ?training_policy.WorkoutRecipe {
    for (policy.workout_recipes) |recipe| {
        if (std.mem.eql(u8, recipe.recipe_id, recipe_id)) return recipe;
    }
    return null;
}

fn appendUniqueRule(
    rule_ids: [][]const u8,
    count: *usize,
    rule_id: []const u8,
) void {
    for (rule_ids[0..count.*]) |existing| {
        if (std.mem.eql(u8, existing, rule_id)) return;
    }
    rule_ids[count.*] = rule_id;
    count.* += 1;
}

fn proposedWorkoutDistance(workout: plan_revision.ProposedWorkout) f64 {
    var total_km: f64 = 0;
    for (workout.segments) |segment| {
        if (segment.distance_km) |distance_km| {
            total_km += distance_km * @as(f64, @floatFromInt(segment.repetitions));
        }
    }
    return total_km;
}

fn chooseLongDay(
    profile: runner_profile.RunnerProfile,
    start: date.Date,
    first_day_index: usize,
    days_this_week: usize,
) !?usize {
    var fallback: ?usize = null;
    for (0..days_this_week) |offset| {
        const absolute = first_day_index + offset;
        const current = date.addDays(start, @intCast(absolute));
        const text_buffer = dateText(current);
        if (isUnavailable(profile, &text_buffer)) continue;
        const weekday: runner_profile.Weekday = @enumFromInt(date.weekday(current));
        if (!containsWeekday(profile.availability.running_days.value, weekday)) continue;
        fallback = absolute;
        if (weekday == profile.availability.preferred_long_run_day.value) return absolute;
    }
    return fallback orelse error.LongRunCannotBeScheduled;
}

fn chooseQualityDay(
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    start: date.Date,
    first_day_index: usize,
    days_this_week: usize,
    long_day: ?usize,
    race_date: date.Date,
) !?usize {
    var fallback: ?usize = null;
    for (0..days_this_week) |offset| {
        const absolute = first_day_index + offset;
        if (long_day != null and absolute == long_day.?) continue;
        const current = date.addDays(start, @intCast(absolute));
        const text_buffer = dateText(current);
        if (isUnavailable(profile, &text_buffer)) continue;
        const weekday: runner_profile.Weekday = @enumFromInt(date.weekday(current));
        if (!containsWeekday(profile.availability.running_days.value, weekday)) continue;
        if (!hasDemandingGap(absolute, long_day, policy)) continue;
        if (date.daysBetween(current, race_date) <=
            policy.scheduling.minimum_easy_or_rest_days_between_demanding_sessions)
        {
            continue;
        }
        fallback = absolute;
        if (profile.availability.preferred_quality_day) |preferred| {
            if (preferred.value == weekday) return absolute;
        }
    }
    return fallback orelse error.QualityWorkoutCannotBeScheduled;
}

fn hasDemandingGap(index: usize, other: ?usize, policy: training_policy.Policy) bool {
    const other_index = other orelse return true;
    const difference = if (index > other_index) index - other_index else other_index - index;
    return difference > policy.scheduling.minimum_easy_or_rest_days_between_demanding_sessions;
}

fn distanceWorkout(
    allocator: std.mem.Allocator,
    date_text: []const u8,
    phase: []const u8,
    kind: []const u8,
    distance_km: f64,
    pace_fast: u16,
    pace_slow: u16,
    pace_anchored: bool,
    title: []const u8,
    guidance: []const u8,
) !plan_revision.ProposedWorkout {
    const details = try std.fmt.allocPrint(allocator, "{s}: {d:.1} km. {s}", .{ title, distance_km, guidance });
    const segments = try allocator.alloc(model.Segment, 1);
    segments[0] = .{
        .kind = if (pace_anchored) "distance" else "effort-distance",
        .label = "Run",
        .distance_km = distance_km,
        .pace_fast_seconds_per_km = if (pace_anchored) pace_fast else null,
        .pace_slow_seconds_per_km = if (pace_anchored) pace_slow else null,
    };
    return .{
        .date = date_text,
        .phase = phase,
        .kind = kind,
        .intensity = if (std.mem.eql(u8, kind, "optional-recovery")) "Very low" else "Low",
        .details = details,
        .distance_min_km = distance_km,
        .distance_max_km = distance_km,
        .segments = segments,
    };
}

fn qualityWorkout(
    allocator: std.mem.Allocator,
    date_text: []const u8,
    phase: []const u8,
    quality: QualityPlan,
    paces: PaceProfile,
    policy: training_policy.Policy,
) !plan_revision.ProposedWorkout {
    const is_intervals = quality.repetition_km != null;
    const label = if (is_intervals)
        "Aerobic intervals"
    else if (std.mem.eql(u8, phase, "race_specific") or std.mem.eql(u8, phase, "taper"))
        "Continuous half-marathon-pace segment"
    else if (std.mem.eql(u8, phase, "build"))
        "Continuous threshold segment"
    else if (std.mem.eql(u8, phase, "race"))
        "Race-week half-marathon-pace sharpening"
    else
        "Continuous controlled segment";
    const work_fast = if (std.mem.eql(u8, phase, "race_specific") or
        std.mem.eql(u8, phase, "taper") or std.mem.eql(u8, phase, "race"))
        paces.race_fast
    else
        paces.quality_fast;
    const work_slow = if (std.mem.eql(u8, phase, "race_specific") or
        std.mem.eql(u8, phase, "taper") or std.mem.eql(u8, phase, "race"))
        paces.race_slow
    else
        paces.quality_slow;
    const segments = try allocator.alloc(model.Segment, 3);
    segments[0] = .{
        .kind = if (paces.anchored) "distance" else "effort-distance",
        .label = "Warm-up",
        .distance_km = quality.warmup_km,
        .pace_fast_seconds_per_km = if (paces.anchored) paces.easy_fast else null,
        .pace_slow_seconds_per_km = if (paces.anchored) paces.easy_slow else null,
    };
    segments[1] = .{
        .kind = if (is_intervals)
            "repeat"
        else if (paces.anchored)
            "distance"
        else
            "effort-distance",
        .label = label,
        .repetitions = quality.repetitions,
        .distance_km = quality.repetition_km orelse quality.work_km,
        .pace_fast_seconds_per_km = if (paces.anchored) work_fast else null,
        .pace_slow_seconds_per_km = if (paces.anchored) work_slow else null,
        .recovery_seconds = quality.recovery_seconds,
    };
    segments[2] = .{
        .kind = if (paces.anchored) "distance" else "effort-distance",
        .label = "Cooldown",
        .distance_km = quality.cooldown_km,
        .pace_fast_seconds_per_km = if (paces.anchored) paces.easy_fast else null,
        .pace_slow_seconds_per_km = if (paces.anchored) paces.easy_slow else null,
    };
    const details = if (is_intervals)
        try std.fmt.allocPrint(
            allocator,
            "Aerobic intervals: {d} repetitions totalling {d:.1} km, with {d}:{d:0>2} easy recovery between repetitions; {d:.1} km total excluding recovery distance. {s}",
            .{
                quality.repetitions,
                quality.work_km,
                quality.recovery_seconds.? / 60,
                quality.recovery_seconds.? % 60,
                quality.session_km,
                policy.intensity_distribution.quality_effort_guidance,
            },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{s}: {d:.1} km continuous; {d:.1} km total. {s}",
            .{
                label,
                quality.work_km,
                quality.session_km,
                policy.intensity_distribution.quality_effort_guidance,
            },
        );
    return .{
        .date = date_text,
        .phase = phase,
        .kind = "quality",
        .intensity = "High",
        .details = details,
        .distance_min_km = quality.session_km,
        .distance_max_km = quality.session_km,
        .segments = segments,
    };
}

fn raceWorkout(
    allocator: std.mem.Allocator,
    date_text: []const u8,
    phase: []const u8,
    policy: training_policy.Policy,
    paces: PaceProfile,
) !plan_revision.ProposedWorkout {
    const segments = try allocator.alloc(model.Segment, 1);
    segments[0] = .{
        .kind = if (paces.anchored) "distance" else "effort-distance",
        .label = "Half marathon",
        .distance_km = policy.support.race_distance_km,
        .pace_fast_seconds_per_km = if (paces.anchored) paces.race_fast else null,
        .pace_slow_seconds_per_km = if (paces.anchored) paces.race_slow else null,
    };
    return .{
        .date = date_text,
        .phase = phase,
        .kind = "race",
        .intensity = "Race effort",
        .details = "Half marathon. Start controlled and use the supported pace anchor, not an unsupported aspirational target.",
        .distance_min_km = policy.support.race_distance_km,
        .distance_max_km = policy.support.race_distance_km,
        .segments = segments,
    };
}

fn restWorkout(
    allocator: std.mem.Allocator,
    date_text: []const u8,
    phase: []const u8,
    details: []const u8,
) !plan_revision.ProposedWorkout {
    const segments = try allocator.alloc(model.Segment, 1);
    segments[0] = .{ .kind = "rest", .label = "Rest", .notes = details };
    return .{
        .date = date_text,
        .phase = phase,
        .kind = "rest",
        .intensity = "None",
        .details = details,
        .segments = segments,
    };
}

fn derivePaces(result: assessment.Assessment, policy: training_policy.Policy) PaceProfile {
    const target_seconds = result.training_pace_anchor_seconds orelse 2 * 60 * 60;
    const race_pace: u16 = @intFromFloat(@round(@as(f64, @floatFromInt(target_seconds)) / policy.support.race_distance_km));
    return .{
        .anchored = result.training_pace_anchor_seconds != null,
        .easy_fast = race_pace + policy.baseline_assessment.easy_pace_minimum_seconds_slower_per_km,
        .easy_slow = race_pace + policy.baseline_assessment.easy_pace_maximum_seconds_slower_per_km,
        .quality_fast = if (race_pace > 40) race_pace - 40 else race_pace,
        .quality_slow = if (race_pace > 15) race_pace - 15 else race_pace,
        .race_fast = if (race_pace > 5) race_pace - 5 else race_pace,
        .race_slow = race_pace + 5,
    };
}

fn speedForPace(seconds_per_km: u16) f64 {
    return 3600.0 / @as(f64, @floatFromInt(seconds_per_km));
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

fn dateText(value: date.Date) [10]u8 {
    var buffer: [10]u8 = undefined;
    _ = std.fmt.bufPrint(&buffer, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(value.year)),
        value.month,
        value.day,
    }) catch unreachable;
    return buffer;
}

fn roundHalf(value: f64) f64 {
    return @round(value * 2) / 2;
}

fn floorHalf(value: f64) f64 {
    return @floor(value * 2) / 2;
}

test "foundation quality work progresses without changing repetition length" {
    const progression = testQualityProgression();
    const first = qualityPlan(
        progression,
        "foundation",
        30,
        1,
        2,
        null,
    );
    const second = qualityPlan(
        progression,
        "foundation",
        32.5,
        2,
        2,
        first.work_km,
    );

    try std.testing.expectEqual(@as(f64, 3), first.work_km);
    try std.testing.expectEqual(@as(u8, 3), first.repetitions);
    try std.testing.expectEqual(@as(f64, 1), first.repetition_km.?);
    try std.testing.expectEqual(@as(f64, 4), second.work_km);
    try std.testing.expectEqual(@as(u8, 4), second.repetitions);
    try std.testing.expectEqual(@as(f64, 1), second.repetition_km.?);
    try std.testing.expectEqual(@as(u16, 120), second.recovery_seconds.?);
}

test "quality plan reduces work for recovery and race-week sharpening" {
    const progression = testQualityProgression();
    const recovery = qualityPlan(
        progression,
        "recovery",
        32.5,
        1,
        1,
        4.5,
    );
    const race = qualityPlan(
        progression,
        "race",
        33.0975,
        1,
        1,
        2.5,
    );

    try std.testing.expectEqual(
        plan_provenance.QualityLoadMethod.recovery_reduction,
        recovery.load_method,
    );
    try std.testing.expectEqual(@as(f64, 3), recovery.work_km);
    try std.testing.expectEqual(
        plan_provenance.QualityLoadMethod.race_sharpening,
        race.load_method,
    );
    try std.testing.expectEqual(@as(f64, 2), race.work_km);
    try std.testing.expectEqual(@as(f64, 4), race.session_km);
}

fn testQualityProgression() training_policy.QualityProgression {
    return .{
        .rule_id = "RECIPE-01",
        .target_weekly_distance_fraction = 0.2,
        .maximum_weekly_distance_fraction = 0.22,
        .maximum_session_distance_km = 8,
        .minimum_warmup_cooldown_km = 1,
        .maximum_warmup_cooldown_km = 2,
        .foundation_repetition_distance_km = 1,
        .foundation_initial_work_fraction = 0.1,
        .foundation_weekly_work_increase_km = 1,
        .interval_recovery_seconds = 120,
        .recovery_work_fraction = 0.75,
        .race_week_work_distance_km = 2,
    };
}
