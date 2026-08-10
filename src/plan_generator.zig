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
    session_seconds: ?u32 = null,
    warmup_seconds: ?u32 = null,
    work_seconds: ?u32 = null,
    cooldown_seconds: ?u32 = null,
    previous_work_seconds: ?u32 = null,
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
    target_duration_seconds: ?u32 = null,
    regular_run_duration_seconds: ?u32 = null,
    long_run_duration_seconds: ?u32 = null,
    previous_long_run_duration_seconds: ?u32 = null,
    long_run_progression_limit_seconds: ?u32 = null,
    target_ascent_meters: ?u32 = null,
    previous_ascent_meters: ?u32 = null,
    ascent_progression_limit_meters: ?u32 = null,
    long_run_ascent_meters: ?u32 = null,
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

    const target_text = if (runner_profile.surface(profile) == .trail)
        if (result.requested_target_seconds) |target|
            try std.fmt.allocPrint(
                allocator,
                "Aspirational trail half-marathon target: {d}:{d:0>2}:{d:0>2}; use course-aware effort guidance",
                .{ target / 3600, target % 3600 / 60, target % 60 },
            )
        else
            "Trail half-marathon completion goal using course-aware effort guidance"
    else if (result.training_pace_anchor_seconds) |target|
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
    const pace_text = if (runner_profile.surface(profile) == .trail)
        "Trail sessions use RPE and conversational guidance; flat-road pace is not prescribed"
    else if (result.training_pace_anchor_seconds != null)
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
        .reason = if (runner_profile.surface(profile) == .trail)
            "Generated from runner profile and trail-aware half-marathon policy."
        else
            "Generated from runner profile and half-marathon policy.",
        .name = if (runner_profile.surface(profile) == .trail)
            "Generated periodized trail half-marathon plan"
        else
            "Generated periodized half-marathon plan",
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
            .target_core_duration_seconds = week.target_duration_seconds,
            .long_run_duration_seconds = week.long_run_duration_seconds,
            .target_ascent_meters = week.target_ascent_meters,
            .long_run_ascent_meters = week.long_run_ascent_meters,
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
                .target_core_duration_seconds = week.target_duration_seconds,
                .previous_long_run_duration_seconds = week.previous_long_run_duration_seconds,
                .long_run_progression_limit_seconds = week.long_run_progression_limit_seconds,
                .target_ascent_meters = week.target_ascent_meters,
                .previous_ascent_meters = week.previous_ascent_meters,
                .ascent_progression_limit_meters = week.ascent_progression_limit_meters,
                .long_run_ascent_meters = week.long_run_ascent_meters,
                .trail_rule_id = if (runner_profile.surface(profile) == .trail)
                    if (policy.trail_specific) |trail| trail.rule_id else null
                else
                    null,
                .load_basis = runner_profile.trainingLoadBasis(profile),
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
    if (runner_profile.trainingLoadBasis(profile) == .duration) {
        return buildDurationMacrocycle(allocator, profile, policy, week_count);
    }

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
        week.target_duration_seconds = null;
        week.regular_run_duration_seconds = null;
        week.long_run_duration_seconds = null;
        week.previous_long_run_duration_seconds = null;
        week.long_run_progression_limit_seconds = null;
        week.target_ascent_meters = null;
        week.previous_ascent_meters = null;
        week.ascent_progression_limit_meters = null;
        week.long_run_ascent_meters = null;
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
    try buildTrailAscent(profile, policy, weeks);
    try buildQualityProgression(profile, policy, weeks);
    return weeks;
}

fn buildDurationMacrocycle(
    allocator: std.mem.Allocator,
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    week_count: usize,
) ![]MacroWeek {
    const duration = policy.duration_progression orelse
        return error.DurationProgressionPolicyRequired;
    const core_running_days = profile.availability.running_days.value.len;
    if (core_running_days < duration.minimum_core_running_days) {
        return error.NotEnoughAvailableRunningDays;
    }
    const reserved = @as(usize, policy.periodization.minimum_race_specific_weeks) +
        @as(usize, policy.periodization.default_taper_weeks) + 1;
    if (week_count < @as(usize, policy.periodization.minimum_foundation_weeks) + reserved) {
        return error.PlanTooShortForPolicyPhases;
    }

    const weeks = try allocator.alloc(MacroWeek, week_count);
    const pre_specific_count = week_count - reserved;
    var progression_regular = duration.initial_regular_run_seconds;
    const recorded_long = if (profile.baseline.longest_run_duration_seconds) |value|
        value.value
    else
        duration.default_initial_long_run_seconds;
    var progression_long = @min(recorded_long, duration.maximum_initial_long_run_seconds);
    var peak_regular = progression_regular;
    var peak_long = progression_long;
    var build_since_recovery: u8 = 0;
    var previous_scheduled_long: ?u32 = null;

    for (weeks, 0..) |*week, index| {
        var phase: []const u8 = "foundation";
        var volume_method: plan_provenance.VolumeMethod = .baseline;
        var applied_fraction: ?f64 = null;
        var regular_seconds = progression_regular;
        var long_seconds = progression_long;

        if (index < pre_specific_count) {
            const foundation = index < policy.periodization.minimum_foundation_weeks;
            const recovery = !foundation and build_since_recovery >=
                policy.recovery.minimum_build_weeks_between_recovery;
            if (recovery) {
                phase = "recovery";
                volume_method = .recovery_reduction;
                applied_fraction = duration.recovery_duration_fraction;
                regular_seconds = fractionSeconds(progression_regular, duration.recovery_duration_fraction);
                long_seconds = fractionSeconds(progression_long, duration.recovery_duration_fraction);
                build_since_recovery = 0;
            } else {
                phase = if (foundation) "foundation" else "build";
                if (index > 0) {
                    volume_method = .build_progression;
                    progression_regular = @min(
                        duration.maximum_regular_run_seconds,
                        progression_regular + duration.regular_run_weekly_increase_seconds,
                    );
                    progression_long = @min(
                        duration.maximum_long_run_seconds,
                        progression_long + duration.long_run_weekly_increase_seconds,
                    );
                    regular_seconds = progression_regular;
                    long_seconds = progression_long;
                }
                if (!foundation) build_since_recovery += 1;
                peak_regular = @max(peak_regular, regular_seconds);
                peak_long = @max(peak_long, long_seconds);
            }
        } else if (index < pre_specific_count + policy.periodization.minimum_race_specific_weeks) {
            phase = "race_specific";
            volume_method = .race_specific_progression;
            progression_regular = @min(
                duration.maximum_regular_run_seconds,
                progression_regular + duration.regular_run_weekly_increase_seconds,
            );
            progression_long = @min(
                duration.maximum_long_run_seconds,
                progression_long + duration.long_run_weekly_increase_seconds,
            );
            regular_seconds = progression_regular;
            long_seconds = progression_long;
            peak_regular = @max(peak_regular, regular_seconds);
            peak_long = @max(peak_long, long_seconds);
        } else if (index < week_count - 1) {
            phase = "taper";
            volume_method = .taper_reduction;
            const taper_index = index -
                (pre_specific_count + policy.periodization.minimum_race_specific_weeks);
            const fraction = if (taper_index == 0)
                duration.first_taper_duration_fraction
            else
                duration.final_taper_duration_fraction;
            applied_fraction = fraction;
            regular_seconds = fractionSeconds(peak_regular, fraction);
            long_seconds = fractionSeconds(peak_long, fraction);
        } else {
            phase = "race";
            volume_method = .race_week;
            regular_seconds = duration.race_week_short_run_seconds;
            long_seconds = 0;
        }

        week.* = .{
            .phase = phase,
            .target_km = if (std.mem.eql(u8, phase, "race"))
                policy.support.race_distance_km
            else
                0,
            .long_km = 0,
            .volume_method = volume_method,
            .previous_progression_km = null,
            .applied_volume_fraction = applied_fraction,
            .previous_long_km = null,
            .long_weekly_share_limit_km = 0,
            .long_progression_limit_km = 0,
            .phase_week = 0,
            .phase_week_count = 0,
            .quality = undefined,
            .target_duration_seconds = if (std.mem.eql(u8, phase, "race"))
                regular_seconds
            else
                regular_seconds * @as(u32, @intCast(core_running_days - 1)) + long_seconds,
            .regular_run_duration_seconds = regular_seconds,
            .long_run_duration_seconds = if (long_seconds > 0) long_seconds else null,
            .previous_long_run_duration_seconds = previous_scheduled_long,
            .long_run_progression_limit_seconds = if (long_seconds > 0)
                (previous_scheduled_long orelse long_seconds) +
                    duration.long_run_weekly_increase_seconds
            else
                null,
        };
        if (long_seconds > 0) previous_scheduled_long = long_seconds;
    }

    for (weeks, 0..) |*week, index| {
        const position = phasePosition(weeks, index);
        week.phase_week = position.week;
        week.phase_week_count = position.count;
    }
    try buildTrailAscent(profile, policy, weeks);
    try buildDurationQualityProgression(profile, weeks);
    return weeks;
}

fn fractionSeconds(seconds: u32, fraction: f64) u32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(seconds)) * fraction));
}

fn fractionMeters(meters: u32, fraction: f64) u32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(meters)) * fraction));
}

fn buildTrailAscent(
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    weeks: []MacroWeek,
) !void {
    if (runner_profile.surface(profile) != .trail) return;

    const trail = policy.trail_specific orelse return error.TrailPolicyRulesRequired;
    const course = runner_profile.trailCourse(profile) orelse
        return error.TrailCourseAscentRequired;
    const race_ascent = (course.total_ascent_meters orelse
        return error.TrailCourseAscentRequired).value;
    const baseline_known = profile.baseline.average_weekly_ascent_meters != null and
        profile.baseline.longest_run_ascent_meters != null;
    const baseline: u32 = if (profile.baseline.average_weekly_ascent_meters) |source|
        @max(@as(u32, 100), source.value)
    else
        @intFromFloat(@round(
            @as(f64, @floatFromInt(race_ascent)) *
                trail.unknown_ascent_initial_race_fraction,
        ));
    const baseline_peak = if (baseline_known)
        @as(f64, @floatFromInt(baseline)) *
            trail.maximum_peak_ascent_relative_to_baseline
    else
        @as(f64, @floatFromInt(race_ascent)) *
            trail.unknown_ascent_peak_race_fraction;
    const race_peak = @as(f64, @floatFromInt(race_ascent)) *
        trail.maximum_peak_ascent_relative_to_race;
    const calculated_peak: u32 = @intFromFloat(@round(@min(baseline_peak, race_peak)));
    const maximum_peak = @max(baseline, calculated_peak);
    var progression = baseline;
    var prior_long: u32 = if (profile.baseline.longest_run_ascent_meters) |source|
        source.value
    else
        @intFromFloat(@round(
            @as(f64, @floatFromInt(baseline)) *
                trail.maximum_long_run_weekly_ascent_fraction,
        ));
    var peak = baseline;

    for (weeks, 0..) |*week, index| {
        week.previous_ascent_meters = if (!baseline_known and index == 0)
            null
        else
            progression;
        const increase_limit: u32 = @intFromFloat(@round(
            @as(f64, @floatFromInt(progression)) *
                (1 + trail.maximum_weekly_ascent_increase_fraction),
        ));
        week.ascent_progression_limit_meters = increase_limit;

        if (std.mem.eql(u8, week.phase, "race")) {
            week.target_ascent_meters = race_ascent;
            week.long_run_ascent_meters = null;
            continue;
        }
        if (std.mem.eql(u8, week.phase, "recovery")) {
            progression = @intFromFloat(@round(
                @as(f64, @floatFromInt(progression)) * trail.recovery_ascent_fraction,
            ));
        } else if (std.mem.eql(u8, week.phase, "taper")) {
            const taper_fraction = if (runner_profile.trainingLoadBasis(profile) == .duration)
                if (policy.duration_progression) |duration|
                    if (week.phase_week == 1)
                        duration.first_taper_duration_fraction
                    else
                        duration.final_taper_duration_fraction
                else
                    0.5
            else
                0.5;
            progression = @intFromFloat(@round(
                @as(f64, @floatFromInt(peak)) * taper_fraction,
            ));
        } else if (baseline_known or index > 0) {
            progression = @min(maximum_peak, increase_limit);
            peak = @max(peak, progression);
        }
        week.target_ascent_meters = progression;

        const race_long_cap: u32 = @intFromFloat(@round(
            @as(f64, @floatFromInt(race_ascent)) *
                trail.maximum_long_run_race_ascent_fraction,
        ));
        const weekly_long_cap: u32 = @intFromFloat(@round(
            @as(f64, @floatFromInt(progression)) *
                trail.maximum_long_run_weekly_ascent_fraction,
        ));
        const long_increase_limit: u32 = @intFromFloat(@round(
            @as(f64, @floatFromInt(@max(@as(u32, 50), prior_long))) *
                (1 + trail.maximum_weekly_ascent_increase_fraction),
        ));
        var desired_long = @min(race_long_cap, @min(weekly_long_cap, long_increase_limit));
        if (std.mem.eql(u8, week.phase, "recovery") or
            std.mem.eql(u8, week.phase, "taper"))
        {
            desired_long = @min(desired_long, prior_long);
        }
        week.long_run_ascent_meters = desired_long;
        prior_long = desired_long;
    }
}

fn buildQualityProgression(
    profile: runner_profile.RunnerProfile,
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
            runner_profile.surface(profile) == .trail,
        );
        previous_work_km = week.quality.work_km;
    }
}

fn buildDurationQualityProgression(
    profile: runner_profile.RunnerProfile,
    weeks: []MacroWeek,
) !void {
    var previous_work_seconds: ?u32 = null;
    for (weeks) |*week| {
        const session_seconds = week.regular_run_duration_seconds orelse
            return error.DurationProgressionIncomplete;
        const support_seconds = @divFloor(session_seconds * 4, 5);
        const warmup_seconds = @divFloor(support_seconds, 2);
        const cooldown_seconds = support_seconds - warmup_seconds;
        const work_seconds = session_seconds - support_seconds;
        const expected = expectedDurationQualityStage(
            week.phase,
            week.phase_week,
            runner_profile.surface(profile) == .trail,
        );
        week.quality = .{
            .stage_id = expected.stage_id,
            .load_method = expected.load_method,
            .phase_week = week.phase_week,
            .phase_week_count = week.phase_week_count,
            .session_km = 0,
            .warmup_km = 0,
            .work_km = 0,
            .cooldown_km = 0,
            .previous_work_km = null,
            .repetition_km = null,
            .repetitions = 1,
            .recovery_seconds = null,
            .session_seconds = session_seconds,
            .warmup_seconds = warmup_seconds,
            .work_seconds = work_seconds,
            .cooldown_seconds = cooldown_seconds,
            .previous_work_seconds = previous_work_seconds,
        };
        previous_work_seconds = work_seconds;
    }
}

const DurationQualityStage = struct {
    stage_id: []const u8,
    load_method: plan_provenance.QualityLoadMethod,
};

fn expectedDurationQualityStage(
    phase: []const u8,
    phase_week: u8,
    trail: bool,
) DurationQualityStage {
    const stage_id = if (trail)
        if (std.mem.eql(u8, phase, "foundation"))
            "trail-foundation-hills"
        else if (std.mem.eql(u8, phase, "build"))
            "trail-build-climbing"
        else if (std.mem.eql(u8, phase, "recovery"))
            "trail-recovery-hills"
        else if (std.mem.eql(u8, phase, "race_specific"))
            "trail-race-specific-effort"
        else if (std.mem.eql(u8, phase, "taper"))
            "trail-taper-uphill"
        else
            "trail-race-week-sharpening"
    else if (std.mem.eql(u8, phase, "foundation"))
        "foundation-aerobic-intervals"
    else if (std.mem.eql(u8, phase, "build"))
        "build-continuous-threshold"
    else if (std.mem.eql(u8, phase, "recovery"))
        "recovery-aerobic-intervals"
    else if (std.mem.eql(u8, phase, "race_specific"))
        "race-specific-half-marathon-pace"
    else if (std.mem.eql(u8, phase, "taper"))
        "taper-half-marathon-pace"
    else
        "race-week-sharpening";
    const load_method: plan_provenance.QualityLoadMethod = if (std.mem.eql(u8, phase, "foundation"))
        if (phase_week == 1) .establish else .progress_work
    else if (std.mem.eql(u8, phase, "build"))
        .progress_work
    else if (std.mem.eql(u8, phase, "recovery"))
        .recovery_reduction
    else if (std.mem.eql(u8, phase, "race_specific"))
        .race_specific_progression
    else if (std.mem.eql(u8, phase, "taper"))
        .taper_reduction
    else
        .race_sharpening;
    return .{ .stage_id = stage_id, .load_method = load_method };
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
    trail: bool,
) QualityPlan {
    const minimum_support_each_km = if (std.mem.eql(u8, phase, "taper"))
        progression.minimum_taper_warmup_cooldown_km
    else
        progression.minimum_warmup_cooldown_km;
    const minimum_support_km = minimum_support_each_km * 2;
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

    if (trail) {
        stage_id = if (std.mem.eql(u8, phase, "foundation"))
            "trail-foundation-hills"
        else if (std.mem.eql(u8, phase, "build"))
            "trail-build-climbing"
        else if (std.mem.eql(u8, phase, "recovery"))
            "trail-recovery-hills"
        else if (std.mem.eql(u8, phase, "race_specific"))
            "trail-race-specific-effort"
        else if (std.mem.eql(u8, phase, "taper"))
            "trail-taper-uphill"
        else
            "trail-race-week-sharpening";
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
        @max(minimum_support_each_km, support_km / 2),
    ));
    var cooldown_km = support_km - warmup_km;
    if (cooldown_km < minimum_support_each_km) {
        cooldown_km = minimum_support_each_km;
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
    if (runner_profile.trainingLoadBasis(profile) == .duration) {
        return allocateDurationWorkouts(
            allocator,
            profile,
            policy,
            weeks,
            plan_days,
            paces,
            training_pace_anchor_seconds,
        );
    }

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
        const week_ascent = week.target_ascent_meters orelse 0;
        const long_ascent = week.long_run_ascent_meters orelse 0;
        const quality_ascent: u32 = if (quality_day != null and
            policy.trail_specific != null and
            !std.mem.eql(u8, week.phase, "race"))
            @intFromFloat(@round(
                @as(f64, @floatFromInt(week_ascent)) *
                    policy.trail_specific.?.quality_ascent_fraction,
            ))
        else
            0;
        const reserved_ascent = if (std.mem.eql(u8, week.phase, "race"))
            week_ascent
        else
            @min(week_ascent, long_ascent + quality_ascent);
        const easy_ascent_total = week_ascent - reserved_ascent;
        var easy_ascent_assigned: u32 = 0;

        for (0..days_this_week) |offset| {
            const absolute_index = first_day_index + offset;
            const current = date.addDays(start, @intCast(absolute_index));
            const text = try date.format(allocator, current);
            const weekday: runner_profile.Weekday = @enumFromInt(date.weekday(current));

            if (date.compare(current, race_date) == .eq) {
                workouts[output_index] = try raceWorkout(
                    allocator,
                    text,
                    week.phase,
                    profile,
                    policy,
                    paces,
                );
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
                    runner_profile.surface(profile) == .trail,
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
            if (runner_profile.surface(profile) == .trail and
                !std.mem.eql(u8, workouts[output_index].kind, "rest") and
                !std.mem.eql(u8, workouts[output_index].kind, "optional-recovery"))
            {
                var planned_ascent: u32 = 0;
                if (std.mem.eql(u8, workouts[output_index].kind, "long")) {
                    planned_ascent = long_ascent;
                } else if (std.mem.eql(u8, workouts[output_index].kind, "quality")) {
                    planned_ascent = quality_ascent;
                } else if (std.mem.eql(u8, workouts[output_index].kind, "easy") and
                    easy_count > 0)
                {
                    const even_ascent = easy_ascent_total / @as(u32, @intCast(easy_count));
                    planned_ascent = if (easy_assigned == easy_count)
                        easy_ascent_total - easy_ascent_assigned
                    else
                        even_ascent;
                    easy_ascent_assigned += planned_ascent;
                }
                workouts[output_index].terrain = .trail;
                if (!std.mem.eql(u8, workouts[output_index].kind, "race")) {
                    workouts[output_index].ascent_meters = planned_ascent;
                    workouts[output_index].descent_meters = plannedDescent(
                        profile,
                        planned_ascent,
                    );
                    if (planned_ascent == 0) {
                        workouts[output_index].details = try std.fmt.allocPrint(
                            allocator,
                            "{s} Trail target: flat or gently rolling terrain with no required climbing; keep footing relaxed.",
                            .{workouts[output_index].details},
                        );
                    } else {
                        workouts[output_index].details = try std.fmt.allocPrint(
                            allocator,
                            "{s} Trail target: approximately {d} m ascent. {s}",
                            .{
                                workouts[output_index].details,
                                planned_ascent,
                                try trailTerrainGuidance(profile),
                            },
                        );
                    }
                }
            }
            workouts[output_index].decision = try workoutDecision(
                allocator,
                profile,
                policy,
                workouts[output_index],
                week.target_km,
                week.target_duration_seconds,
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

fn allocateDurationWorkouts(
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
        var available_core_days: usize = 0;
        for (0..days_this_week) |offset| {
            const current = date.addDays(start, @intCast(first_day_index + offset));
            const text_buffer = dateText(current);
            if (isUnavailable(profile, &text_buffer)) continue;
            const weekday: runner_profile.Weekday = @enumFromInt(date.weekday(current));
            if (containsWeekday(profile.availability.running_days.value, weekday) and
                date.compare(current, race_date) != .eq)
            {
                available_core_days += 1;
            }
        }
        const required_core_days = if (std.mem.eql(u8, week.phase, "race"))
            @as(usize, 1)
        else
            profile.availability.running_days.value.len;
        if (available_core_days < required_core_days) {
            return error.NotEnoughAvailableRunningDays;
        }
        const easy_count = if (std.mem.eql(u8, week.phase, "race"))
            @as(usize, 0)
        else
            available_core_days - 2;
        const total_ascent = week.target_ascent_meters orelse 0;
        const long_ascent = week.long_run_ascent_meters orelse 0;
        const quality_ascent: u32 = if (easy_count == 0)
            total_ascent - @min(total_ascent, long_ascent)
        else if (policy.trail_specific) |trail|
            @intFromFloat(@round(
                @as(f64, @floatFromInt(total_ascent)) * trail.quality_ascent_fraction,
            ))
        else
            0;
        const reserved_ascent = @min(total_ascent, long_ascent + quality_ascent);
        const easy_ascent_total = total_ascent - reserved_ascent;
        var easy_ascent_assigned: u32 = 0;
        var easy_assigned: usize = 0;
        const regular_duration = week.regular_run_duration_seconds orelse
            return error.DurationProgressionIncomplete;
        const terrain_guidance = if (runner_profile.surface(profile) == .trail)
            try trailTerrainGuidance(profile)
        else
            "Choose a safe, familiar route and keep the prescribed effort controlled.";

        for (0..days_this_week) |offset| {
            const absolute_index = first_day_index + offset;
            const current = date.addDays(start, @intCast(absolute_index));
            const text = try date.format(allocator, current);
            const weekday: runner_profile.Weekday = @enumFromInt(date.weekday(current));

            if (date.compare(current, race_date) == .eq) {
                workouts[output_index] = try raceWorkout(
                    allocator,
                    text,
                    week.phase,
                    profile,
                    policy,
                    paces,
                );
            } else if (isUnavailable(profile, text)) {
                workouts[output_index] = try restWorkout(
                    allocator,
                    text,
                    week.phase,
                    "Unavailable date from runner profile.",
                );
            } else if (long_day != null and absolute_index == long_day.?) {
                const duration_seconds = week.long_run_duration_seconds orelse
                    return error.DurationProgressionIncomplete;
                workouts[output_index] = try durationWorkout(
                    allocator,
                    text,
                    week.phase,
                    "long",
                    duration_seconds,
                    long_ascent,
                    plannedDescent(profile, long_ascent),
                    true,
                    terrain_guidance,
                    runner_profile.surface(profile),
                );
            } else if (quality_day != null and absolute_index == quality_day.?) {
                workouts[output_index] = try durationQualityWorkout(
                    allocator,
                    text,
                    week.phase,
                    week.quality,
                    if (std.mem.eql(u8, week.phase, "race")) 0 else quality_ascent,
                    plannedDescent(
                        profile,
                        if (std.mem.eql(u8, week.phase, "race")) 0 else quality_ascent,
                    ),
                    terrain_guidance,
                    runner_profile.surface(profile),
                );
            } else if (!std.mem.eql(u8, week.phase, "race") and
                containsWeekday(profile.availability.running_days.value, weekday))
            {
                easy_assigned += 1;
                const even_ascent = if (easy_count > 0)
                    easy_ascent_total / @as(u32, @intCast(easy_count))
                else
                    0;
                const easy_ascent = if (easy_assigned == easy_count)
                    easy_ascent_total - easy_ascent_assigned
                else
                    even_ascent;
                easy_ascent_assigned += easy_ascent;
                workouts[output_index] = try durationWorkout(
                    allocator,
                    text,
                    week.phase,
                    "easy",
                    regular_duration,
                    easy_ascent,
                    plannedDescent(profile, easy_ascent),
                    false,
                    terrain_guidance,
                    runner_profile.surface(profile),
                );
            } else {
                workouts[output_index] = try restWorkout(
                    allocator,
                    text,
                    week.phase,
                    "Rest day.",
                );
            }

            workouts[output_index].decision = try workoutDecision(
                allocator,
                profile,
                policy,
                workouts[output_index],
                week.target_km,
                week.target_duration_seconds,
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

fn durationWorkout(
    allocator: std.mem.Allocator,
    date_text: []const u8,
    phase: []const u8,
    kind: []const u8,
    duration_seconds: u32,
    ascent_meters: u32,
    descent_meters: ?u32,
    long_run: bool,
    terrain_guidance: []const u8,
    surface: runner_profile.Surface,
) !plan_revision.ProposedWorkout {
    if (duration_seconds == 0) return error.DurationProgressionIncomplete;

    const duration_minutes = duration_seconds / 60;
    const trail = surface == .trail;
    const title = if (long_run)
        if (trail) "Long trail run/hike" else "Long run"
    else if (trail)
        "Easy trail run"
    else
        "Easy run";
    const phase_guidance = if (long_run and trail)
        "Keep the effort conversational at RPE 3-4, power hike steep grades, and practise fueling after 60 minutes."
    else if (long_run)
        "Keep the effort conversational at RPE 3-4 and practise fueling after 60 minutes."
    else if (std.mem.eql(u8, phase, "taper"))
        "Run easily at RPE 3-4 with a few short uphill pickups; avoid hard descending."
    else
        "Run easily at conversational RPE 2-4; keep the route and footing relaxed.";
    const details = if (trail)
        try std.fmt.allocPrint(
            allocator,
            "{s}: {d} minutes, approximately {d} m ascent. {s} {s}",
            .{ title, duration_minutes, ascent_meters, phase_guidance, terrain_guidance },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{s}: {d} minutes. {s} {s}",
            .{ title, duration_minutes, phase_guidance, terrain_guidance },
        );
    const segments = try allocator.alloc(model.Segment, 1);
    segments[0] = .{
        .kind = "effort-duration",
        .label = title,
        .duration_seconds = duration_seconds,
        .notes = phase_guidance,
    };
    return .{
        .date = date_text,
        .phase = phase,
        .kind = kind,
        .intensity = if (long_run or std.mem.eql(u8, phase, "foundation") or
            std.mem.eql(u8, phase, "taper") or std.mem.eql(u8, phase, "race"))
            "Low"
        else
            "Moderate",
        .details = details,
        .terrain = surface,
        .ascent_meters = if (trail) ascent_meters else null,
        .descent_meters = if (trail) descent_meters else null,
        .segments = segments,
    };
}

fn durationQualityWorkout(
    allocator: std.mem.Allocator,
    date_text: []const u8,
    phase: []const u8,
    quality: QualityPlan,
    ascent_meters: u32,
    descent_meters: ?u32,
    terrain_guidance: []const u8,
    surface: runner_profile.Surface,
) !plan_revision.ProposedWorkout {
    const session_seconds = quality.session_seconds orelse
        return error.DurationProgressionIncomplete;
    const warmup_seconds = quality.warmup_seconds orelse
        return error.DurationProgressionIncomplete;
    const work_seconds = quality.work_seconds orelse
        return error.DurationProgressionIncomplete;
    const cooldown_seconds = quality.cooldown_seconds orelse
        return error.DurationProgressionIncomplete;
    const trail = surface == .trail;
    const race_week = std.mem.eql(u8, phase, "race");
    const work_label = if (race_week)
        if (trail)
            "Short relaxed trail sharpening on flat or gently rolling terrain"
        else
            "Relaxed strides on flat or gently rolling terrain"
    else if (trail)
        if (std.mem.eql(u8, phase, "taper"))
            "Short uphill sharpening without hard descending"
        else
            "Controlled uphill effort"
    else
        "Controlled quality effort";
    const work_notes = if (race_week)
        "Relaxed RPE 4-5; keep the effort smooth and finish fresh."
    else
        "Controlled RPE 5-6; stop before form deteriorates.";
    const work_description = if (race_week) "relaxed sharpening" else "controlled work";
    const workout_terrain_guidance = if (race_week and trail)
        "Choose flat or gently rolling trail, stay relaxed, and avoid hard descending."
    else
        terrain_guidance;
    const details = if (trail)
        try std.fmt.allocPrint(
            allocator,
            "Time-based trail quality: {d} minutes, including {d} minutes of {s} and approximately {d} m ascent. {s}",
            .{ session_seconds / 60, work_seconds / 60, work_description, ascent_meters, workout_terrain_guidance },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "Time-based quality: {d} minutes, including {d} minutes of {s}. {s}",
            .{ session_seconds / 60, work_seconds / 60, work_description, workout_terrain_guidance },
        );
    const segments = try allocator.alloc(model.Segment, 3);
    segments[0] = .{
        .kind = "effort-duration",
        .label = "Easy warm-up",
        .duration_seconds = warmup_seconds,
        .notes = "Conversational RPE 2-3.",
    };
    segments[1] = .{
        .kind = "effort-duration",
        .label = work_label,
        .duration_seconds = work_seconds,
        .notes = work_notes,
    };
    segments[2] = .{
        .kind = "effort-duration",
        .label = "Easy cooldown",
        .duration_seconds = cooldown_seconds,
        .notes = "Return to conversational RPE 2-3.",
    };
    return .{
        .date = date_text,
        .phase = phase,
        .kind = "quality",
        .intensity = "Moderate",
        .details = details,
        .terrain = surface,
        .ascent_meters = if (trail) ascent_meters else null,
        .descent_meters = if (trail) descent_meters else null,
        .segments = segments,
    };
}

fn plannedDescent(profile: runner_profile.RunnerProfile, ascent_meters: u32) ?u32 {
    const course = runner_profile.trailCourse(profile) orelse return null;
    const course_ascent = course.total_ascent_meters orelse return null;
    const course_descent = course.total_descent_meters orelse return null;
    if (course_ascent.value == 0) return 0;
    return @intFromFloat(@round(
        @as(f64, @floatFromInt(ascent_meters)) *
            @as(f64, @floatFromInt(course_descent.value)) /
            @as(f64, @floatFromInt(course_ascent.value)),
    ));
}

fn trailTerrainGuidance(profile: runner_profile.RunnerProfile) ![]const u8 {
    const course = runner_profile.trailCourse(profile) orelse
        return error.TrailCourseTechnicalityRequired;
    const technicality = course.technicality orelse
        return error.TrailCourseTechnicalityRequired;
    return switch (technicality.value) {
        .smooth => "Keep runnable grades relaxed and descents controlled.",
        .mixed => "Use short controlled steps on uneven descents.",
        .technical => "Prioritize footing, power hike steep grades, and keep technical descents controlled.",
    };
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
    week_target_duration_seconds: ?u32,
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
    const duration_seconds = proposedWorkoutDuration(workout);
    const duration_based = duration_seconds > 0;
    const recipe_id = if (duration_based and role == .easy)
        "easy-duration"
    else if (duration_based and role == .quality)
        "quality-duration"
    else if (duration_based and role == .long_run)
        "long-duration"
    else
        recipeId(
            role,
            workout.phase,
            runner_profile.surface(profile) == .trail,
        );
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
    if (runner_profile.surface(profile) == .trail and role != .rest) {
        const trail = policy.trail_specific orelse return error.TrailPolicyRulesRequired;
        appendUniqueRule(rule_ids_buffer, &rule_count, trail.rule_id);
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
    const distance_method: plan_provenance.DistanceMethod = if (duration_based)
        .duration_progression
    else switch (role) {
        .rest => .none,
        .easy => .weekly_remainder,
        .optional_recovery => .optional_weekly_fraction,
        .quality => .quality_progression,
        .long_run => .weekly_long_run,
        .race => .race_distance,
    };
    const pace_method: plan_provenance.PaceMethod = if (role == .rest)
        .none
    else if (duration_based)
        .effort_only
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
        .week_target_core_duration_seconds = week_target_duration_seconds,
        .allocated_duration_seconds = if (duration_seconds > 0) duration_seconds else null,
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
            .work_duration_seconds = quality.work_seconds,
            .previous_work_duration_seconds = quality.previous_work_seconds,
        } else null,
        .planned_ascent_meters = workout.ascent_meters,
        .planned_descent_meters = workout.descent_meters,
        .terrain = workout.terrain,
        .load_basis = runner_profile.trainingLoadBasis(profile),
    };
}

fn recipeId(
    role: plan_provenance.AllocationRole,
    phase: []const u8,
    trail: bool,
) []const u8 {
    if (trail) {
        return switch (role) {
            .rest => "rest-day",
            .easy => "easy-distance",
            .optional_recovery => "optional-recovery",
            .long_run => "long-easy",
            .race => "trail-half-marathon-race",
            .quality => if (std.mem.eql(u8, phase, "foundation") or
                std.mem.eql(u8, phase, "build") or
                std.mem.eql(u8, phase, "recovery"))
                "trail-hill-repeats"
            else
                "trail-specific-effort",
        };
    }
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

fn proposedWorkoutDuration(workout: plan_revision.ProposedWorkout) u32 {
    var total_seconds: u32 = 0;
    for (workout.segments) |segment| {
        const duration_seconds = segment.duration_seconds orelse continue;
        total_seconds += duration_seconds * @as(u32, segment.repetitions);
        const recovery_seconds = segment.recovery_seconds orelse continue;
        if (segment.repetitions > 1) {
            total_seconds += @as(u32, recovery_seconds) *
                (@as(u32, segment.repetitions) - 1);
        }
    }
    return total_seconds;
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
    trail: bool,
) !plan_revision.ProposedWorkout {
    const is_intervals = quality.repetition_km != null;
    const label = if (trail and is_intervals)
        "Uphill repetitions with controlled downhill recovery"
    else if (trail and std.mem.eql(u8, phase, "build"))
        "Sustained uphill effort with controlled descending"
    else if (trail and std.mem.eql(u8, phase, "race_specific"))
        "Sustained race-like trail effort; power hike steep grades"
    else if (trail and std.mem.eql(u8, phase, "taper"))
        "Short uphill sharpening without hard descending"
    else if (trail and std.mem.eql(u8, phase, "race"))
        "Short relaxed trail sharpening on flat or gently rolling terrain"
    else if (is_intervals)
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
        .kind = if (paces.anchored and !trail) "distance" else "effort-distance",
        .label = "Warm-up",
        .distance_km = quality.warmup_km,
        .pace_fast_seconds_per_km = if (paces.anchored and !trail) paces.easy_fast else null,
        .pace_slow_seconds_per_km = if (paces.anchored and !trail) paces.easy_slow else null,
    };
    segments[1] = .{
        .kind = if (is_intervals)
            "repeat"
        else if (paces.anchored and !trail)
            "distance"
        else
            "effort-distance",
        .label = label,
        .repetitions = quality.repetitions,
        .distance_km = quality.repetition_km orelse quality.work_km,
        .pace_fast_seconds_per_km = if (paces.anchored and !trail) work_fast else null,
        .pace_slow_seconds_per_km = if (paces.anchored and !trail) work_slow else null,
        .recovery_seconds = quality.recovery_seconds,
    };
    segments[2] = .{
        .kind = if (paces.anchored and !trail) "distance" else "effort-distance",
        .label = "Cooldown",
        .distance_km = quality.cooldown_km,
        .pace_fast_seconds_per_km = if (paces.anchored and !trail) paces.easy_fast else null,
        .pace_slow_seconds_per_km = if (paces.anchored and !trail) paces.easy_slow else null,
    };
    const details = if (is_intervals)
        try std.fmt.allocPrint(
            allocator,
            "{s}: {d} repetitions totalling {d:.1} km, with {d}:{d:0>2} easy recovery between repetitions; {d:.1} km total excluding recovery distance. {s}",
            .{
                if (trail) "Uphill intervals" else "Aerobic intervals",
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
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    paces: PaceProfile,
) !plan_revision.ProposedWorkout {
    const segments = try allocator.alloc(model.Segment, 1);
    const trail = runner_profile.surface(profile) == .trail;
    segments[0] = .{
        .kind = if (paces.anchored and !trail) "distance" else "effort-distance",
        .label = if (trail) "Trail half marathon" else "Half marathon",
        .distance_km = policy.support.race_distance_km,
        .pace_fast_seconds_per_km = if (paces.anchored and !trail) paces.race_fast else null,
        .pace_slow_seconds_per_km = if (paces.anchored and !trail) paces.race_slow else null,
    };
    const course = profile.goal.course;
    const ascent = if (course) |value|
        if (value.total_ascent_meters) |source| source.value else null
    else
        null;
    const descent = if (course) |value|
        if (value.total_descent_meters) |source| source.value else null
    else
        null;
    return .{
        .date = date_text,
        .phase = phase,
        .kind = "race",
        .intensity = "Race effort",
        .details = if (trail)
            "Trail half marathon. Start by effort, power hike steep grades, and keep descents controlled until the final third."
        else
            "Half marathon. Start controlled and use the supported pace anchor, not an unsupported aspirational target.",
        .distance_min_km = policy.support.race_distance_km,
        .distance_max_km = policy.support.race_distance_km,
        .terrain = if (trail) .trail else .road,
        .ascent_meters = ascent,
        .descent_meters = descent,
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
        false,
    );
    const second = qualityPlan(
        progression,
        "foundation",
        32.5,
        2,
        2,
        first.work_km,
        false,
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
        false,
    );
    const race = qualityPlan(
        progression,
        "race",
        33.0975,
        1,
        1,
        2.5,
        false,
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

test "short taper quality keeps non-zero warmup and cooldown" {
    const taper = qualityPlan(
        testQualityProgression(),
        "taper",
        10,
        2,
        2,
        1,
        true,
    );

    try std.testing.expectEqual(@as(f64, 0.5), taper.warmup_km);
    try std.testing.expectEqual(@as(f64, 1), taper.work_km);
    try std.testing.expectEqual(@as(f64, 0.5), taper.cooldown_km);
    try std.testing.expectEqual(@as(f64, 2), taper.session_km);
}

fn testQualityProgression() training_policy.QualityProgression {
    return .{
        .rule_id = "RECIPE-01",
        .target_weekly_distance_fraction = 0.2,
        .maximum_weekly_distance_fraction = 0.22,
        .maximum_session_distance_km = 8,
        .minimum_warmup_cooldown_km = 1,
        .minimum_taper_warmup_cooldown_km = 0.5,
        .maximum_warmup_cooldown_km = 2,
        .foundation_repetition_distance_km = 1,
        .foundation_initial_work_fraction = 0.1,
        .foundation_weekly_work_increase_km = 1,
        .interval_recovery_seconds = 120,
        .recovery_work_fraction = 0.75,
        .race_week_work_distance_km = 2,
    };
}
