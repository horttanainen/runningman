const std = @import("std");
const date = @import("date.zig");
const model = @import("model.zig");

pub const initial_name = "Half marathon base — 12 weeks";

const long_run_distances = [_]?f64{
    14, 15, 16, 13, 17, 18, 19, 16, 20, 21, 16, null,
};

pub fn createInitialEvents(
    allocator: std.mem.Allocator,
    start: date.Date,
    recorded_at: i64,
) ![]model.Event {
    var events: std.ArrayList(model.Event) = .empty;
    errdefer events.deinit(allocator);

    const start_text = try date.format(allocator, start);
    const schedule_value: model.Schedule = .{
        .id = 1,
        .parent_schedule_id = null,
        .effective_from = start_text,
        .start_date = start_text,
        .name = initial_name,
        .reason = "Initial plan from ChatGPT: five running days, optional recovery, one rest day. Week 12 remains explicitly unspecified because the source contains no daily taper or race date.",
        .goal = "Finish a half marathon comfortably and build toward approximately 1:50–1:58 without making every run hard.",
        .baseline = "Age 34; comfortable 10–15 km runs; recent 10K 53:00 at very hard effort.",
        .availability = "Up to seven days per week; plan uses five running days, one optional recovery day, and one complete rest day.",
        .intensity_guidance = "Keep about 80% of running in Zone 2 at conversational effort. Easy pace may be around 6:15–7:00 min/km, but effort takes priority over pace.",
        .source = "Running plan supplied by the user on 2026-07-20. Weeks 1–11 are represented directly; the source only says “race week” for week 12.",
        .recorded_at = recorded_at,
    };
    try events.append(allocator, model.scheduleEvent(schedule_value));

    var workout_id: u64 = 0;
    for (0..12) |week_index| {
        for (0..7) |day_index| {
            workout_id += 1;
            const workout_date = date.addDays(start, @intCast(week_index * 7 + day_index));
            const workout = try makeInitialWorkout(
                allocator,
                workout_id,
                workout_date,
                @intCast(week_index + 1),
                @intCast(day_index),
                recorded_at,
            );
            try events.append(allocator, model.workoutEvent(workout));
        }
    }

    return events.toOwnedSlice(allocator);
}

pub fn makeRevision(
    schedule_id: u64,
    parent_schedule_id: u64,
    effective_from: []const u8,
    start_date: []const u8,
    reason: []const u8,
    parent: model.Schedule,
    recorded_at: i64,
) model.Schedule {
    return .{
        .id = schedule_id,
        .parent_schedule_id = parent_schedule_id,
        .effective_from = effective_from,
        .start_date = start_date,
        .name = "Revised running schedule",
        .reason = reason,
        .goal = parent.goal,
        .baseline = parent.baseline,
        .availability = parent.availability,
        .intensity_guidance = parent.intensity_guidance,
        .source = parent.source,
        .recorded_at = recorded_at,
    };
}

pub const RevisionInput = struct {
    target_date: date.Date,
    kind: []const u8,
    intensity: []const u8,
    details: []const u8,
    distance_min_km: ?f64,
    distance_max_km: ?f64,
    reason: []const u8,
};

pub fn createRevisionEvents(
    allocator: std.mem.Allocator,
    schedules: *const std.AutoArrayHashMapUnmanaged(u64, model.Schedule),
    workouts: *const std.AutoArrayHashMapUnmanaged(u64, model.Workout),
    parent_schedule_id: u64,
    new_schedule_id: u64,
    first_workout_id: u64,
    input: RevisionInput,
    recorded_at: i64,
) ![]model.Event {
    const parent = schedules.get(parent_schedule_id) orelse return error.ScheduleNotFound;
    const target_text = try date.format(allocator, input.target_date);
    const revision = makeRevision(
        new_schedule_id,
        parent_schedule_id,
        target_text,
        parent.start_date,
        input.reason,
        parent,
        recorded_at,
    );

    var events: std.ArrayList(model.Event) = .empty;
    errdefer events.deinit(allocator);
    try events.append(allocator, model.scheduleEvent(revision));

    var next_workout_id = first_workout_id;
    var target_found = false;
    for (workouts.values()) |existing| {
        if (existing.schedule_id != parent_schedule_id) continue;

        var copied = existing;
        copied.id = next_workout_id;
        copied.schedule_id = new_schedule_id;
        copied.recorded_at = recorded_at;
        next_workout_id += 1;

        const existing_date = date.parse(existing.date) catch return error.InvalidWorkoutDate;
        if (date.compare(existing_date, input.target_date) == .eq) {
            copied.kind = input.kind;
            copied.intensity = input.intensity;
            copied.distance_min_km = input.distance_min_km;
            copied.distance_max_km = input.distance_max_km;
            copied.details = input.details;
            target_found = true;
        }
        try events.append(allocator, model.workoutEvent(copied));
    }

    if (!target_found) return error.WorkoutNotFound;
    if (events.items.len != 85) return error.IncompleteScheduleSnapshot;
    return events.toOwnedSlice(allocator);
}

fn makeInitialWorkout(
    allocator: std.mem.Allocator,
    id: u64,
    workout_date: date.Date,
    week: u8,
    day_index: u8,
    recorded_at: i64,
) !model.Workout {
    const date_text = try date.format(allocator, workout_date);
    const common: model.Workout = .{
        .id = id,
        .schedule_id = 1,
        .date = date_text,
        .week = week,
        .day = date.weekdayName(workout_date),
        .kind = undefined,
        .intensity = undefined,
        .distance_min_km = null,
        .distance_max_km = null,
        .details = undefined,
        .recorded_at = recorded_at,
    };

    if (week == 12) return raceWeekWorkout(common);

    return switch (day_index) {
        0 => withPlan(common, "easy", "Zone 2, conversational", 6, 8, "Easy 6–8 km in Zone 2; conversational effort."),
        1 => if (@mod(week, 2) == 1)
            withPlan(common, "intervals", "Hard repetitions, easy recoveries", null, null, "Warm up; 6 × 800 m with 2 min easy jog recoveries; cool down.")
        else
            withPlan(common, "hills", "Hard uphill repetitions, easy recoveries", null, null, "Warm up; 8 × 1 min uphill, jogging back down; cool down."),
        2 => withPlan(common, "easy", "Zone 2, conversational", 8, 10, "Easy 8–10 km in Zone 2; conversational effort."),
        3 => withPlan(common, "tempo", "Comfortably hard", 9, 12, "Warm up 2 km; 5–8 km comfortably hard around current half-marathon pace; cool down 2 km."),
        4 => withPlan(common, "recovery-or-rest", "Very easy or complete rest", 0, 5, "Complete rest or an optional 5 km very easy recovery jog."),
        5 => withPlan(
            common,
            "long",
            "Easy, conversational",
            long_run_distances[week - 1],
            long_run_distances[week - 1],
            "Long run at easy effort; do not target speed.",
        ),
        6 => withPlan(common, "easy-or-rest", "Zone 2 or complete rest", 0, 8, "Easy 5–8 km in Zone 2 or complete rest."),
        else => unreachable,
    };
}

fn raceWeekWorkout(common: model.Workout) model.Workout {
    return withPlan(
        common,
        "race-week-unspecified",
        "Not specified",
        null,
        null,
        "Race week. The supplied plan does not specify this day’s workout or the race date; create a revision once those are known.",
    );
}

fn withPlan(
    common: model.Workout,
    kind: []const u8,
    intensity: []const u8,
    distance_min_km: ?f64,
    distance_max_km: ?f64,
    details: []const u8,
) model.Workout {
    var result = common;
    result.kind = kind;
    result.intensity = intensity;
    result.distance_min_km = distance_min_km;
    result.distance_max_km = distance_max_km;
    result.details = details;
    return result;
}

test "initial schedule contains one revision and 84 workouts" {
    const allocator = std.testing.allocator;
    const events = try createInitialEvents(allocator, try date.parse("2026-07-20"), 1);
    defer {
        for (events) |event| {
            if (event.date) |value| allocator.free(value);
        }
        allocator.free(events[0].start_date.?);
        allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 85), events.len);
    try std.testing.expectEqual(model.EventType.schedule, events[0].type);
    try std.testing.expectEqualStrings("long", events[6].kind.?);
    try std.testing.expectEqual(@as(?f64, 14), events[6].distance_min_km);

    for (long_run_distances, 0..) |expected_distance, week_index| {
        const saturday_event = events[1 + week_index * 7 + 5];
        try std.testing.expectEqual(expected_distance, saturday_event.distance_min_km);
    }
    for (0..7) |day_index| {
        const race_week_event = events[1 + 11 * 7 + day_index];
        try std.testing.expectEqualStrings("race-week-unspecified", race_week_event.kind.?);
        try std.testing.expectEqual(@as(?f64, null), race_week_event.distance_min_km);
    }
}

test "revision creates a complete independent schedule snapshot" {
    const allocator = std.testing.allocator;
    const initial = try createInitialEvents(allocator, try date.parse("2026-07-20"), 1);
    defer {
        for (initial) |event| {
            if (event.date) |value| allocator.free(value);
        }
        allocator.free(initial[0].start_date.?);
        allocator.free(initial);
    }

    var schedules: std.AutoArrayHashMapUnmanaged(u64, model.Schedule) = .empty;
    defer schedules.deinit(allocator);
    var workouts: std.AutoArrayHashMapUnmanaged(u64, model.Workout) = .empty;
    defer workouts.deinit(allocator);

    const initial_schedule_event = initial[0];
    try schedules.put(allocator, 1, .{
        .id = 1,
        .parent_schedule_id = null,
        .effective_from = initial_schedule_event.effective_from.?,
        .start_date = initial_schedule_event.start_date.?,
        .name = initial_schedule_event.name.?,
        .reason = initial_schedule_event.reason.?,
        .goal = initial_schedule_event.goal.?,
        .baseline = initial_schedule_event.baseline.?,
        .availability = initial_schedule_event.availability.?,
        .intensity_guidance = initial_schedule_event.intensity_guidance.?,
        .source = initial_schedule_event.source.?,
        .recorded_at = 1,
    });
    for (initial[1..]) |event| {
        try workouts.put(allocator, event.id, .{
            .id = event.id,
            .schedule_id = 1,
            .date = event.date.?,
            .week = event.week.?,
            .day = event.day.?,
            .kind = event.kind.?,
            .intensity = event.intensity.?,
            .distance_min_km = event.distance_min_km,
            .distance_max_km = event.distance_max_km,
            .details = event.details.?,
            .recorded_at = 1,
        });
    }

    const revised = try createRevisionEvents(
        allocator,
        &schedules,
        &workouts,
        1,
        2,
        85,
        .{
            .target_date = try date.parse("2026-08-01"),
            .kind = "long",
            .intensity = "Easy",
            .details = "Reduced to 12 km.",
            .distance_min_km = 12,
            .distance_max_km = 12,
            .reason = "Fatigue",
        },
        2,
    );
    defer {
        allocator.free(revised[0].effective_from.?);
        allocator.free(revised);
    }

    try std.testing.expectEqual(@as(usize, 85), revised.len);
    try std.testing.expectEqual(@as(?u64, 1), revised[0].parent_schedule_id);
    var changed_count: usize = 0;
    for (revised[1..]) |event| {
        try std.testing.expectEqual(@as(?u64, 2), event.schedule_id);
        if (std.mem.eql(u8, event.date.?, "2026-08-01")) {
            changed_count += 1;
            try std.testing.expectEqual(@as(?f64, 12), event.distance_min_km);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), changed_count);
}
