const std = @import("std");
const assessment = @import("assessment.zig");
const date = @import("date.zig");
const model = @import("model.zig");
const plan_revision = @import("plan_revision.zig");
const plan_validator = @import("plan_validator.zig");
const runner_profile = @import("runner_profile.zig");
const training_policy = @import("training_policy.zig");

const Io = std.Io;

const MacroWeek = struct {
    phase: []const u8,
    target_km: f64,
    long_km: f64,
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
    );

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
            "Easy {d}:{d:0>2}–{d}:{d:0>2}/km; race anchor {d}:{d:0>2}/km",
            .{
                paces.easy_fast / 60,
                paces.easy_fast % 60,
                paces.easy_slow / 60,
                paces.easy_slow % 60,
                paces.race_fast / 60,
                paces.race_fast % 60,
            },
        )
    else
        "Paces unavailable; use the stated RPE and conversational guidance";

    const revision: plan_revision.RevisionFile = .{
        .base_schedule_id = base_schedule_id,
        .effective_from = profile.plan_start_date.value,
        .reason = "Generated from runner profile and half-marathon-v1 policy.",
        .name = "Generated periodized half-marathon plan",
        .goal = target_text,
        .availability = availability,
        .intensity_guidance = policy.intensity_distribution.easy_effort_guidance,
        .pace_profile = pace_text,
        .race_date = profile.goal.race_date.value,
        .assessment = .{
            .profile_id = profile.profile_id,
            .policy_id = policy.policy_id,
            .policy_version = policy.policy_version,
            .confidence = @tagName(result.confidence),
            .feasibility = @tagName(result.feasibility),
            .recommended_target_seconds = result.planner_recommended_target_seconds,
            .requested_target_seconds = result.requested_target_seconds,
            .training_pace_anchor_seconds = result.training_pace_anchor_seconds,
            .expected_shortfall_seconds = result.expected_shortfall_seconds,
        },
        .weeks = proposed_weeks,
        .workouts = workouts,
    };
    try plan_validator.validate(allocator, profile, policy, result, revision);
    return revision;
}

fn buildProposedWeeks(
    allocator: std.mem.Allocator,
    profile: runner_profile.RunnerProfile,
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
        if (index < pre_specific_count) {
            const foundation = index < policy.periodization.minimum_foundation_weeks;
            const recovery = !foundation and build_since_recovery >=
                policy.recovery.minimum_build_weeks_between_recovery;
            if (recovery) {
                week.phase = "recovery";
                week.target_km = roundHalf(progression_volume * policy.recovery.maximum_volume_fraction);
                build_since_recovery = 0;
            } else {
                week.phase = if (foundation) "foundation" else "build";
                if (index > 0) {
                    progression_volume = @min(
                        maximum,
                        roundHalf(progression_volume * (1 + policy.volume_progression.maximum_build_increase_fraction * 0.8)),
                    );
                }
                week.target_km = progression_volume;
                if (!foundation) build_since_recovery += 1;
                peak = @max(peak, week.target_km);
            }
        } else if (index < pre_specific_count + policy.periodization.minimum_race_specific_weeks) {
            week.phase = "race_specific";
            progression_volume = @min(
                maximum,
                roundHalf(progression_volume * (1 + policy.volume_progression.maximum_build_increase_fraction * 0.6)),
            );
            week.target_km = progression_volume;
            peak = @max(peak, week.target_km);
        } else if (index < week_count - 1) {
            week.phase = "taper";
            const taper_index = index - (pre_specific_count + policy.periodization.minimum_race_specific_weeks);
            const fraction: f64 = if (taper_index == 0) 0.59 else 0.50;
            week.target_km = roundHalf(peak * fraction);
        } else {
            week.phase = "race";
            week.target_km = policy.support.race_distance_km +
                @max(0.0, baseline * 0.4);
        }

        if (std.mem.eql(u8, week.phase, "race")) {
            week.long_km = 0;
            continue;
        }
        var desired = @min(
            policy.long_run.maximum_peak_distance_km,
            week.target_km * policy.long_run.maximum_weekly_distance_fraction,
        );
        if (std.mem.eql(u8, week.phase, "recovery")) desired = @min(desired, prior_long);
        desired = @min(desired, prior_long + policy.long_run.maximum_weekly_increase_km);
        week.long_km = floorHalf(desired);
        prior_long = week.long_km;
    }
    return weeks;
}

fn allocateWorkouts(
    allocator: std.mem.Allocator,
    profile: runner_profile.RunnerProfile,
    policy: training_policy.Policy,
    weeks: []const MacroWeek,
    plan_days: u16,
    paces: PaceProfile,
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

        const quality_km = if (quality_day != null)
            roundHalf(@min(8.0, @max(2.0, week.target_km * 0.20)))
        else
            0;
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
                    quality_km,
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
            output_index += 1;
        }
    }
    return workouts;
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
    total_km: f64,
    paces: PaceProfile,
    policy: training_policy.Policy,
) !plan_revision.ProposedWorkout {
    const warmup = roundHalf(@min(2.0, total_km * 0.25));
    const cooldown = warmup;
    const work = @max(1.0, roundHalf(total_km - warmup - cooldown));
    const is_intervals = std.mem.eql(u8, phase, "foundation") or
        std.mem.eql(u8, phase, "recovery");
    const label = if (is_intervals)
        "Aerobic intervals"
    else if (std.mem.eql(u8, phase, "race_specific") or std.mem.eql(u8, phase, "taper"))
        "Continuous half-marathon-pace segment"
    else if (std.mem.eql(u8, phase, "build"))
        "Continuous threshold segment"
    else
        "Continuous controlled segment";
    const work_fast = if (std.mem.eql(u8, phase, "race_specific") or std.mem.eql(u8, phase, "taper"))
        paces.race_fast
    else
        paces.quality_fast;
    const work_slow = if (std.mem.eql(u8, phase, "race_specific") or std.mem.eql(u8, phase, "taper"))
        paces.race_slow
    else
        paces.quality_slow;
    const repetitions = if (is_intervals) intervalRepetitions(work) else 1;
    const work_distance_km = work / @as(f64, @floatFromInt(repetitions));
    const segments = try allocator.alloc(model.Segment, 3);
    segments[0] = .{
        .kind = if (paces.anchored) "distance" else "effort-distance",
        .label = "Warm-up",
        .distance_km = warmup,
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
        .repetitions = repetitions,
        .distance_km = work_distance_km,
        .pace_fast_seconds_per_km = if (paces.anchored) work_fast else null,
        .pace_slow_seconds_per_km = if (paces.anchored) work_slow else null,
        .recovery_seconds = if (is_intervals) 120 else null,
    };
    segments[2] = .{
        .kind = if (paces.anchored) "distance" else "effort-distance",
        .label = "Cooldown",
        .distance_km = cooldown,
        .pace_fast_seconds_per_km = if (paces.anchored) paces.easy_fast else null,
        .pace_slow_seconds_per_km = if (paces.anchored) paces.easy_slow else null,
    };
    const details = if (is_intervals)
        try std.fmt.allocPrint(
            allocator,
            "Aerobic intervals: {d} repetitions totalling {d:.1} km, with 2:00 easy recovery between repetitions; {d:.1} km total excluding recovery distance. {s}",
            .{
                repetitions,
                work,
                warmup + work + cooldown,
                policy.intensity_distribution.quality_effort_guidance,
            },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{s}: {d:.1} km continuous; {d:.1} km total. {s}",
            .{
                label,
                work,
                warmup + work + cooldown,
                policy.intensity_distribution.quality_effort_guidance,
            },
        );
    return .{
        .date = date_text,
        .phase = phase,
        .kind = "quality",
        .intensity = "High",
        .details = details,
        .distance_min_km = warmup + work + cooldown,
        .distance_max_km = warmup + work + cooldown,
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

fn intervalRepetitions(work_distance_km: f64) u8 {
    const half_kilometres: u8 = @intFromFloat(@round(work_distance_km * 2));
    if (half_kilometres <= 2) return 2;
    if (half_kilometres % 2 == 0) return half_kilometres / 2;
    return half_kilometres;
}
