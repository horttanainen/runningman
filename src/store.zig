const std = @import("std");
const date = @import("date.zig");
const model = @import("model.zig");

const Io = std.Io;

pub const Store = struct {
    schedules: std.AutoArrayHashMapUnmanaged(u64, model.Schedule) = .empty,
    workouts: std.AutoArrayHashMapUnmanaged(u64, model.Workout) = .empty,
    workouts_by_schedule_date: std.AutoArrayHashMapUnmanaged(u128, u64) = .empty,
    activities: std.AutoArrayHashMapUnmanaged(u64, model.Activity) = .empty,
    morning_check_ins: std.AutoArrayHashMapUnmanaged(u64, model.MorningCheckIn) = .empty,
    max_schedule_id: u64 = 0,
    max_workout_id: u64 = 0,
    max_activity_id: u64 = 0,
    max_check_in_id: u64 = 0,
};

pub fn deinit(storage: *Store, allocator: std.mem.Allocator) void {
    storage.schedules.deinit(allocator);
    storage.workouts.deinit(allocator);
    storage.workouts_by_schedule_date.deinit(allocator);
    storage.activities.deinit(allocator);
    storage.morning_check_ins.deinit(allocator);
}

pub fn load(
    storage: *Store,
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
) !void {
    const contents = Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_number: usize = 0;
    while (lines.next()) |line| {
        line_number += 1;
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
        const event = std.json.parseFromSliceLeaky(
            model.Event,
            allocator,
            line,
            .{ .ignore_unknown_fields = true },
        ) catch {
            std.log.err("invalid JSON event on line {d}", .{line_number});
            return error.InvalidDataFile;
        };
        try applyEvent(storage, allocator, event);
    }
}

pub fn append(
    io: Io,
    path: []const u8,
    events: []const model.Event,
) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    });
    defer file.close(io);

    const stat = try file.stat(io);
    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &buffer);
    try file_writer.seekTo(stat.size);
    const writer = &file_writer.interface;

    for (events) |event| {
        try std.json.Stringify.value(event, .{ .emit_null_optional_fields = false }, writer);
        try writer.writeByte('\n');
    }
    try file_writer.flush();
}

pub fn effectiveSchedule(storage: *const Store, target_date: date.Date) ?model.Schedule {
    var result: ?model.Schedule = null;
    for (storage.schedules.values()) |schedule| {
        const effective_from = date.parse(schedule.effective_from) catch continue;
        if (date.compare(effective_from, target_date) == .gt) continue;
        if (result == null or schedule.id > result.?.id) result = schedule;
    }
    return result;
}

pub fn workoutForDate(
    storage: *const Store,
    schedule_id: u64,
    target_date: date.Date,
) ?model.Workout {
    var current_id: ?u64 = schedule_id;
    while (current_id) |id| {
        const key = scheduleDateKey(id, target_date);
        if (storage.workouts_by_schedule_date.get(key)) |workout_id| {
            return storage.workouts.get(workout_id);
        }
        const schedule = storage.schedules.get(id) orelse return null;
        current_id = schedule.parent_schedule_id;
    }
    return null;
}

pub fn currentWorkout(storage: *const Store, target_date: date.Date) ?model.Workout {
    const schedule = effectiveSchedule(storage, target_date) orelse return null;
    return workoutForDate(storage, schedule.id, target_date);
}

pub fn latestActivityForDate(storage: *const Store, target_date: date.Date) ?model.Activity {
    var result: ?model.Activity = null;
    for (storage.activities.values()) |activity| {
        const activity_date = date.parse(activity.date) catch continue;
        if (date.compare(activity_date, target_date) != .eq) continue;
        if (result == null or activity.id > result.?.id) result = activity;
    }
    return result;
}

pub fn latestCheckInForDate(storage: *const Store, target_date: date.Date) ?model.MorningCheckIn {
    var result: ?model.MorningCheckIn = null;
    for (storage.morning_check_ins.values()) |check_in| {
        const check_in_date = date.parse(check_in.date) catch continue;
        if (date.compare(check_in_date, target_date) != .eq) continue;
        if (result == null or check_in.id > result.?.id) result = check_in;
    }
    return result;
}

pub fn earliestScheduleDate(storage: *const Store) ?date.Date {
    var result: ?date.Date = null;
    for (storage.schedules.values()) |schedule| {
        const start = date.parse(schedule.start_date) catch continue;
        if (result == null or date.compare(start, result.?) == .lt) result = start;
    }
    return result;
}

fn applyEvent(storage: *Store, allocator: std.mem.Allocator, event: model.Event) !void {
    if (event.schema_version != 2) return error.UnsupportedSchemaVersion;
    switch (event.type) {
        .schedule => {
            const value: model.Schedule = .{
                .id = event.id,
                .parent_schedule_id = event.parent_schedule_id,
                .effective_from = event.effective_from orelse return error.InvalidDataFile,
                .start_date = event.start_date orelse return error.InvalidDataFile,
                .name = event.name orelse return error.InvalidDataFile,
                .reason = event.reason orelse "",
                .goal = event.goal orelse "",
                .baseline = event.baseline orelse "",
                .availability = event.availability orelse "",
                .intensity_guidance = event.intensity_guidance orelse "",
                .pace_profile = event.pace_profile orelse "",
                .race_date = event.race_date orelse "",
                .source = event.source orelse "",
                .plan_provenance = event.plan_provenance,
                .plan_weeks = event.plan_weeks orelse &.{},
                .recorded_at = event.recorded_at,
            };
            try storage.schedules.put(allocator, value.id, value);
            storage.max_schedule_id = @max(storage.max_schedule_id, value.id);
        },
        .workout => {
            const value: model.Workout = .{
                .id = event.id,
                .schedule_id = event.schedule_id orelse return error.InvalidDataFile,
                .date = event.date orelse return error.InvalidDataFile,
                .week = event.week orelse return error.InvalidDataFile,
                .day = event.day orelse return error.InvalidDataFile,
                .phase = event.phase orelse return error.InvalidDataFile,
                .kind = event.kind orelse return error.InvalidDataFile,
                .intensity = event.intensity orelse "",
                .distance_min_km = event.distance_min_km,
                .distance_max_km = event.distance_max_km,
                .details = event.details orelse return error.InvalidDataFile,
                .segments = event.segments orelse &.{},
                .decision = event.decision,
                .recorded_at = event.recorded_at,
            };
            const parsed_date = date.parse(value.date) catch return error.InvalidDataFile;
            try storage.workouts.put(allocator, value.id, value);
            try storage.workouts_by_schedule_date.put(
                allocator,
                scheduleDateKey(value.schedule_id, parsed_date),
                value.id,
            );
            storage.max_workout_id = @max(storage.max_workout_id, value.id);
        },
        .activity => {
            const value: model.Activity = .{
                .id = event.id,
                .supersedes_activity_id = event.supersedes_activity_id,
                .schedule_id = event.schedule_id orelse return error.InvalidDataFile,
                .workout_id = event.workout_id orelse return error.InvalidDataFile,
                .date = event.date orelse return error.InvalidDataFile,
                .status = event.status orelse return error.InvalidDataFile,
                .distance_km = event.distance_km,
                .duration_seconds = event.duration_seconds,
                .average_heart_rate = event.average_heart_rate,
                .rpe = event.rpe,
                .feeling = event.feeling,
                .pain = event.pain,
                .pain_location = event.pain_location orelse "",
                .deviation_reason = event.deviation_reason orelse "",
                .notes = event.notes orelse "",
                .recorded_at = event.recorded_at,
            };
            try storage.activities.put(allocator, value.id, value);
            storage.max_activity_id = @max(storage.max_activity_id, value.id);
        },
        .morning_check_in => {
            const value: model.MorningCheckIn = .{
                .id = event.id,
                .supersedes_check_in_id = event.supersedes_check_in_id,
                .date = event.date orelse return error.InvalidDataFile,
                .sleep_score = event.sleep_score orelse return error.InvalidDataFile,
                .readiness_score = event.readiness_score orelse return error.InvalidDataFile,
                .notes = event.notes orelse "",
                .recorded_at = event.recorded_at,
            };
            try storage.morning_check_ins.put(allocator, value.id, value);
            storage.max_check_in_id = @max(storage.max_check_in_id, value.id);
        },
    }
}

fn scheduleDateKey(schedule_id: u64, target_date: date.Date) u128 {
    const signed_day: i64 = date.toEpochDay(target_date);
    const day_bits: u64 = @bitCast(signed_day);
    return (@as(u128, schedule_id) << 64) | day_bits;
}
