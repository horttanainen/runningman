const std = @import("std");
const date = @import("date.zig");
const model = @import("model.zig");

pub const initial_name = "Periodized two-hour half marathon — 13 weeks";

const recovery_fast: u16 = 395;
const recovery_slow: u16 = 440;
const easy_fast: u16 = 375;
const easy_slow: u16 = 420;
const long_fast: u16 = 375;
const long_slow: u16 = 415;
const steady_fast: u16 = 350;
const steady_slow: u16 = 370;
const half_marathon_fast: u16 = 338;
const half_marathon_slow: u16 = 348;
const tempo_fast: u16 = 325;
const tempo_slow: u16 = 340;
const interval_fast: u16 = 300;
const interval_slow: u16 = 315;

const monday_distances = [_]f64{ 6, 7, 8, 6, 8, 8, 9, 7, 9, 9, 8, 6, 5 };
const optional_distances = [_]f64{ 5, 5, 6, 4, 6, 6, 6, 5, 6, 6, 5, 4, 4 };
const long_distances = [_]?f64{ 14, 15, 16, 13, 17, 18, 19, 15, 18, 20, 16, 12, null };

pub fn createInitialEvents(
    allocator: std.mem.Allocator,
    start: date.Date,
    recorded_at: i64,
) ![]model.Event {
    return createPeriodizedEvents(
        allocator,
        null,
        1,
        1,
        start,
        "Initial 13-week periodized plan targeting approximately two hours.",
        recorded_at,
    );
}

pub fn createPeriodizedRevisionEvents(
    allocator: std.mem.Allocator,
    parent: model.Schedule,
    schedule_id: u64,
    first_workout_id: u64,
    recorded_at: i64,
) ![]model.Event {
    const start = try date.parse(parent.start_date);
    return createPeriodizedEvents(
        allocator,
        parent.id,
        schedule_id,
        first_workout_id,
        start,
        "Replaced the repeating plan with an approved 13-week periodized program.",
        recorded_at,
    );
}

fn createPeriodizedEvents(
    allocator: std.mem.Allocator,
    parent_schedule_id: ?u64,
    schedule_id: u64,
    first_workout_id: u64,
    start: date.Date,
    reason: []const u8,
    recorded_at: i64,
) ![]model.Event {
    var events: std.ArrayList(model.Event) = .empty;
    errdefer events.deinit(allocator);

    const start_text = try date.format(allocator, start);
    const race_text = try date.format(allocator, date.addDays(start, 90));
    const schedule_value: model.Schedule = .{
        .id = schedule_id,
        .parent_schedule_id = parent_schedule_id,
        .effective_from = start_text,
        .start_date = start_text,
        .name = initial_name,
        .reason = reason,
        .goal = "Run the half marathon in approximately 2:00 (about 5:41 min/km, 10.6 km/h), adjusting the remaining plan from weekly evidence.",
        .baseline = "Comfortable 10–15 km runs; recent 10K 53:00 at very hard effort.",
        .availability = "Four core runs each week plus one optional recovery run; two full rest days.",
        .intensity_guidance = "Most running stays easy. Foundation uses one hard session; build and race-specific phases add controlled half-marathon or threshold work, separated by easy or rest days.",
        .pace_profile = "Recovery 6:35–7:20/km, 8.2–9.1 km/h; easy 6:15–7:00/km, 8.6–9.6 km/h; long 6:15–6:55/km, 8.7–9.6 km/h; steady 5:50–6:10/km, 9.7–10.3 km/h; half-marathon effort 5:38–5:48/km, 10.3–10.7 km/h; tempo 5:25–5:40/km, 10.6–11.1 km/h; short intervals 5:00–5:15/km, 11.4–12.0 km/h.",
        .race_date = race_text,
        .source = "Periodized 13-week half-marathon plan approved by the user.",
        .recorded_at = recorded_at,
    };
    try events.append(allocator, model.scheduleEvent(schedule_value));

    var workout_id = first_workout_id;
    for (0..13) |week_index| {
        for (0..7) |day_index| {
            const workout_date = date.addDays(start, @intCast(week_index * 7 + day_index));
            const workout = try makeWorkout(
                allocator,
                workout_id,
                schedule_id,
                workout_date,
                @intCast(week_index + 1),
                @intCast(day_index),
                recorded_at,
            );
            try events.append(allocator, model.workoutEvent(workout));
            workout_id += 1;
        }
    }
    return events.toOwnedSlice(allocator);
}

fn makeWorkout(
    allocator: std.mem.Allocator,
    id: u64,
    schedule_id: u64,
    workout_date: date.Date,
    week: u8,
    day_index: u8,
    recorded_at: i64,
) !model.Workout {
    const common: model.Workout = .{
        .id = id,
        .schedule_id = schedule_id,
        .date = try date.format(allocator, workout_date),
        .week = week,
        .day = date.weekdayName(workout_date),
        .phase = phaseForWeek(week),
        .kind = undefined,
        .intensity = undefined,
        .distance_min_km = null,
        .distance_max_km = null,
        .details = undefined,
        .segments = &.{},
        .recorded_at = recorded_at,
    };

    if (week == 13) return raceWeekWorkout(allocator, common, day_index);
    return switch (day_index) {
        0 => distanceWorkout(
            allocator,
            common,
            "easy",
            "Zone 2, conversational",
            monday_distances[week - 1],
            easy_fast,
            easy_slow,
            "Core easy aerobic run.",
        ),
        1 => qualityWorkout(allocator, common, week),
        2 => optionalRecoveryWorkout(allocator, common, optional_distances[week - 1]),
        3 => thursdayWorkout(allocator, common, week),
        4 => restWorkout(allocator, common, "Full rest before the long run."),
        5 => longWorkout(allocator, common, week),
        6 => restWorkout(allocator, common, "Full rest. Do not move missed hard training here."),
        else => unreachable,
    };
}

fn qualityWorkout(
    allocator: std.mem.Allocator,
    common: model.Workout,
    week: u8,
) !model.Workout {
    return switch (week) {
        1 => timedRepeatWorkout(allocator, common, "hills", 6, 45, 75, "6 × 45 sec uphill at controlled hard effort; jog easily downhill."),
        2 => distanceRepeatWorkout(allocator, common, 6, 0.4, interval_fast, interval_slow, 90, "6 × 400 m controlled intervals."),
        3 => timedRepeatWorkout(allocator, common, "hills", 8, 45, 75, "8 × 45 sec uphill at controlled hard effort; jog easily downhill."),
        4 => timedRepeatWorkout(allocator, common, "strides", 6, 20, 60, "Recovery week: 6 × 20 sec relaxed strides, never sprinting."),
        5 => distanceRepeatWorkout(allocator, common, 5, 0.8, interval_fast, interval_slow, 120, "5 × 800 m controlled intervals."),
        6 => distanceRepeatWorkout(allocator, common, 6, 0.8, interval_fast, interval_slow, 120, "6 × 800 m controlled intervals."),
        7 => distanceRepeatWorkout(allocator, common, 5, 1.0, 315, 325, 120, "5 × 1 km around current 10K effort."),
        8 => timedRepeatWorkout(allocator, common, "hills", 6, 30, 75, "Recovery week: 6 × 30 sec relaxed hill repetitions."),
        9 => distanceRepeatWorkout(allocator, common, 4, 1.2, tempo_fast, 335, 150, "4 × 1.2 km controlled threshold repetitions."),
        10 => distanceRepeatWorkout(allocator, common, 3, 1.6, tempo_fast, 335, 180, "3 × 1.6 km controlled threshold repetitions."),
        11 => distanceRepeatWorkout(allocator, common, 5, 1.0, tempo_fast, 335, 120, "5 × 1 km controlled threshold repetitions."),
        12 => distanceRepeatWorkout(allocator, common, 4, 0.4, interval_fast, interval_slow, 120, "Taper: 4 × 400 m relaxed and quick with full recovery."),
        else => unreachable,
    };
}

fn thursdayWorkout(
    allocator: std.mem.Allocator,
    common: model.Workout,
    week: u8,
) !model.Workout {
    return switch (week) {
        1 => threePartWorkout(allocator, common, "steady", 3, steady_fast, steady_slow, "3 km steady between easy warm-up and cooldown."),
        2 => threePartWorkout(allocator, common, "tempo", 3, tempo_fast, tempo_slow, "3 km tempo between easy warm-up and cooldown."),
        3 => threePartWorkout(allocator, common, "tempo", 4, tempo_fast, tempo_slow, "4 km tempo between easy warm-up and cooldown."),
        4 => distanceWorkout(allocator, common, "easy", "Zone 2, conversational", 6, easy_fast, easy_slow, "Recovery-week easy run."),
        5 => threePartWorkout(allocator, common, "half-marathon-pace", 4, half_marathon_fast, half_marathon_slow, "4 km at half-marathon effort between easy warm-up and cooldown."),
        6 => threePartWorkout(allocator, common, "half-marathon-pace", 5, half_marathon_fast, half_marathon_slow, "5 km at half-marathon effort between easy warm-up and cooldown."),
        7 => threePartWorkout(allocator, common, "tempo", 5, tempo_fast, tempo_slow, "5 km tempo between easy warm-up and cooldown."),
        8 => threePartWorkout(allocator, common, "steady", 4, steady_fast, steady_slow, "Recovery week: 4 km steady between easy warm-up and cooldown."),
        9 => threePartWorkout(allocator, common, "half-marathon-pace", 6, half_marathon_fast, half_marathon_slow, "6 km at half-marathon effort between easy warm-up and cooldown."),
        10 => threePartWorkout(allocator, common, "half-marathon-pace", 8, half_marathon_fast, half_marathon_slow, "8 km at half-marathon effort between easy warm-up and cooldown."),
        11 => distanceRepeatWorkoutWithPace(
            allocator,
            common,
            "half-marathon-pace",
            3,
            2,
            half_marathon_fast,
            half_marathon_slow,
            120,
            "3 × 2 km at half-marathon effort with 2 min easy recovery.",
        ),
        12 => threePartWorkout(allocator, common, "half-marathon-pace", 3, half_marathon_fast, half_marathon_slow, "Taper: 3 km at half-marathon effort between short easy running."),
        else => unreachable,
    };
}

fn longWorkout(
    allocator: std.mem.Allocator,
    common: model.Workout,
    week: u8,
) !model.Workout {
    if (week == 9) {
        return segmentedDistanceWorkout(
            allocator,
            common,
            "long-progression",
            "Easy with controlled steady finish",
            18,
            "15 km easy, then 3 km steady. Do not race the finish.",
            &.{
                distanceSegment("Easy running", 15, long_fast, long_slow),
                distanceSegment("Steady finish", 3, steady_fast, steady_slow),
            },
        );
    }
    if (week == 11) {
        return segmentedDistanceWorkout(
            allocator,
            common,
            "long-race-specific",
            "Easy followed by half-marathon effort",
            16,
            "10 km easy, then 6 km at controlled half-marathon effort.",
            &.{
                distanceSegment("Easy running", 10, long_fast, long_slow),
                distanceSegment("Half-marathon effort", 6, half_marathon_fast, half_marathon_slow),
            },
        );
    }
    return distanceWorkout(
        allocator,
        common,
        "long",
        "Easy, conversational",
        long_distances[week - 1].?,
        long_fast,
        long_slow,
        if (week == 4 or week == 8)
            "Recovery-week long run at easy effort."
        else if (week == 10)
            "Peak-distance long run at easy effort; do not target speed."
        else if (week == 12)
            "Taper long run at relaxed easy effort."
        else
            "Long run at easy conversational effort.",
    );
}

fn raceWeekWorkout(
    allocator: std.mem.Allocator,
    common: model.Workout,
    day_index: u8,
) !model.Workout {
    return switch (day_index) {
        0 => distanceWorkout(allocator, common, "easy", "Zone 2, conversational", 5, easy_fast, easy_slow, "Short race-week easy run."),
        1 => timedRepeatWorkout(allocator, common, "strides", 4, 20, 60, "Race week: 4 × 20 sec relaxed strides after easy running."),
        2 => optionalRecoveryWorkout(allocator, common, 4),
        3 => distanceWorkout(allocator, common, "easy", "Very easy", 4, recovery_fast, recovery_slow, "Short relaxed race-week run."),
        4 => restWorkout(allocator, common, "Full rest."),
        5 => distanceWorkout(allocator, common, "shakeout", "Very easy", 2, recovery_fast, recovery_slow, "Optional 2 km shakeout; rest instead if preferred."),
        6 => distanceWorkout(allocator, common, "race", "Target approximately 5:41/km, 10.6 km/h", 21.0975, half_marathon_fast, half_marathon_slow, "Half marathon race. Start controlled and use the two-hour pace as a target, not a demand."),
        else => unreachable,
    };
}

fn distanceWorkout(
    allocator: std.mem.Allocator,
    common: model.Workout,
    kind: []const u8,
    intensity: []const u8,
    distance_km: f64,
    pace_fast: u16,
    pace_slow: u16,
    details: []const u8,
) !model.Workout {
    return segmentedDistanceWorkout(
        allocator,
        common,
        kind,
        intensity,
        distance_km,
        details,
        &.{distanceSegment("Run", distance_km, pace_fast, pace_slow)},
    );
}

fn optionalRecoveryWorkout(
    allocator: std.mem.Allocator,
    common: model.Workout,
    distance_km: f64,
) !model.Workout {
    var result = try distanceWorkout(
        allocator,
        common,
        "recovery-or-rest",
        "Recovery pace or complete rest",
        distance_km,
        recovery_fast,
        recovery_slow,
        "Optional recovery run. Rest is equally valid.",
    );
    result.distance_min_km = 0;
    return result;
}

fn restWorkout(
    allocator: std.mem.Allocator,
    common: model.Workout,
    details: []const u8,
) !model.Workout {
    var result = common;
    result.kind = "rest";
    result.intensity = "Rest";
    result.distance_min_km = 0;
    result.distance_max_km = 0;
    result.details = details;
    result.segments = try allocator.dupe(model.Segment, &.{.{
        .kind = "rest",
        .label = "Rest",
        .notes = details,
    }});
    return result;
}

fn threePartWorkout(
    allocator: std.mem.Allocator,
    common: model.Workout,
    kind: []const u8,
    work_distance_km: f64,
    work_pace_fast: u16,
    work_pace_slow: u16,
    details: []const u8,
) !model.Workout {
    const total_distance = 4 + work_distance_km;
    return segmentedDistanceWorkout(
        allocator,
        common,
        kind,
        "Controlled quality",
        total_distance,
        details,
        &.{
            distanceSegment("Warm-up", 2, easy_fast, easy_slow),
            distanceSegment("Work segment", work_distance_km, work_pace_fast, work_pace_slow),
            distanceSegment("Cooldown", 2, easy_fast, easy_slow),
        },
    );
}

fn timedRepeatWorkout(
    allocator: std.mem.Allocator,
    common: model.Workout,
    kind: []const u8,
    repetitions: u8,
    work_seconds: u32,
    recovery_seconds: u16,
    details: []const u8,
) !model.Workout {
    var result = common;
    result.kind = kind;
    result.intensity = "Controlled hard repetitions";
    result.distance_min_km = null;
    result.distance_max_km = null;
    result.details = details;
    result.segments = try allocator.dupe(model.Segment, &.{
        distanceSegment("Warm-up", 2, easy_fast, easy_slow),
        .{
            .kind = "repeat",
            .label = "Repetitions",
            .repetitions = repetitions,
            .duration_seconds = work_seconds,
            .recovery_seconds = recovery_seconds,
            .notes = "Run by effort; pace is not prescribed for hills or strides.",
        },
        distanceSegment("Cooldown", 2, easy_fast, easy_slow),
    });
    return result;
}

fn distanceRepeatWorkout(
    allocator: std.mem.Allocator,
    common: model.Workout,
    repetitions: u8,
    repeat_distance_km: f64,
    pace_fast: u16,
    pace_slow: u16,
    recovery_seconds: u16,
    details: []const u8,
) !model.Workout {
    return distanceRepeatWorkoutWithPace(
        allocator,
        common,
        "intervals",
        repetitions,
        repeat_distance_km,
        pace_fast,
        pace_slow,
        recovery_seconds,
        details,
    );
}

fn distanceRepeatWorkoutWithPace(
    allocator: std.mem.Allocator,
    common: model.Workout,
    kind: []const u8,
    repetitions: u8,
    repeat_distance_km: f64,
    pace_fast: u16,
    pace_slow: u16,
    recovery_seconds: u16,
    details: []const u8,
) !model.Workout {
    var result = common;
    result.kind = kind;
    result.intensity = "Controlled quality";
    const known_distance = 4 + @as(f64, @floatFromInt(repetitions)) * repeat_distance_km;
    result.distance_min_km = known_distance;
    result.distance_max_km = known_distance;
    result.details = details;
    result.segments = try allocator.dupe(model.Segment, &.{
        distanceSegment("Warm-up", 2, easy_fast, easy_slow),
        .{
            .kind = "repeat",
            .label = "Work repetitions",
            .repetitions = repetitions,
            .distance_km = repeat_distance_km,
            .pace_fast_seconds_per_km = pace_fast,
            .pace_slow_seconds_per_km = pace_slow,
            .recovery_seconds = recovery_seconds,
            .notes = "Recovery is easy walking or jogging.",
        },
        distanceSegment("Cooldown", 2, easy_fast, easy_slow),
    });
    return result;
}

fn segmentedDistanceWorkout(
    allocator: std.mem.Allocator,
    common: model.Workout,
    kind: []const u8,
    intensity: []const u8,
    distance_km: f64,
    details: []const u8,
    segment_values: []const model.Segment,
) !model.Workout {
    var result = common;
    result.kind = kind;
    result.intensity = intensity;
    result.distance_min_km = distance_km;
    result.distance_max_km = distance_km;
    result.details = details;
    result.segments = try allocator.dupe(model.Segment, segment_values);
    return result;
}

fn distanceSegment(
    label: []const u8,
    distance_km: f64,
    pace_fast: u16,
    pace_slow: u16,
) model.Segment {
    return .{
        .kind = "distance",
        .label = label,
        .distance_km = distance_km,
        .pace_fast_seconds_per_km = pace_fast,
        .pace_slow_seconds_per_km = pace_slow,
    };
}

fn phaseForWeek(week: u8) []const u8 {
    return switch (week) {
        1...3 => "foundation",
        4 => "recovery",
        5...7 => "build",
        8 => "recovery",
        9...11 => "race-specific",
        12 => "taper",
        13 => "race",
        else => unreachable,
    };
}

test "periodized plan contains 13 complete weeks" {
    const allocator = std.testing.allocator;
    const events = try createInitialEvents(allocator, try date.parse("2026-07-20"), 1);
    defer freeEventsForTest(allocator, events);

    try std.testing.expectEqual(@as(usize, 92), events.len);
    try std.testing.expectEqualStrings("foundation", events[1].phase.?);
    try std.testing.expectEqualStrings("recovery", events[1 + 3 * 7].phase.?);
    try std.testing.expectEqualStrings("race-specific", events[1 + 8 * 7].phase.?);
    try std.testing.expectEqualStrings("taper", events[1 + 11 * 7].phase.?);
    try std.testing.expectEqualStrings("race", events[1 + 12 * 7].phase.?);

    for (long_distances, 0..) |expected, week_index| {
        if (expected) |distance_km| {
            const saturday = events[1 + week_index * 7 + 5];
            try std.testing.expectEqual(@as(?f64, distance_km), saturday.distance_max_km);
        }
    }
    const race = events[1 + 12 * 7 + 6];
    try std.testing.expectEqualStrings("race", race.kind.?);
    try std.testing.expectApproxEqAbs(@as(f64, 21.0975), race.distance_max_km.?, 0.0001);
}

fn freeEventsForTest(allocator: std.mem.Allocator, events: []model.Event) void {
    for (events) |event| {
        if (event.date) |value| allocator.free(value);
        if (event.segments) |value| allocator.free(value);
    }
    allocator.free(events[0].start_date.?);
    allocator.free(events[0].race_date.?);
    allocator.free(events);
}
