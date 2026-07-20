const std = @import("std");
const model = @import("model.zig");

pub const Input = struct {
    status: model.ActivityStatus = .completed,
    distance_km: ?f64 = null,
    duration_seconds: ?u32 = null,
    average_heart_rate: ?u16 = null,
    rpe: ?u8 = null,
    pain: ?u8 = null,
    pain_location: []const u8 = "",
    deviation_reason: []const u8 = "",
    notes: []const u8 = "",
};

pub fn validate(input: Input) !void {
    if (input.distance_km) |value| {
        if (value <= 0 or !std.math.isFinite(value)) return error.InvalidDistance;
    }
    if (input.duration_seconds) |value| {
        if (value == 0) return error.InvalidDuration;
    }
    if (input.average_heart_rate) |value| {
        if (value == 0) return error.InvalidHeartRate;
    }
    if (input.rpe) |value| {
        if (value < 1 or value > 10) return error.RpeOutOfRange;
    }
    if (input.pain) |value| {
        if (value > 10) return error.PainOutOfRange;
    }
    if (input.status == .modified and input.deviation_reason.len == 0) {
        return error.ModifiedReasonRequired;
    }
}

pub fn make(
    id: u64,
    supersedes_activity_id: ?u64,
    schedule_id: u64,
    workout_id: u64,
    date_text: []const u8,
    input: Input,
    recorded_at: i64,
) !model.Activity {
    try validate(input);
    return .{
        .id = id,
        .supersedes_activity_id = supersedes_activity_id,
        .schedule_id = schedule_id,
        .workout_id = workout_id,
        .date = date_text,
        .status = input.status,
        .distance_km = input.distance_km,
        .duration_seconds = input.duration_seconds,
        .average_heart_rate = input.average_heart_rate,
        .rpe = input.rpe,
        .feeling = null,
        .pain = input.pain,
        .pain_location = input.pain_location,
        .deviation_reason = input.deviation_reason,
        .notes = input.notes,
        .recorded_at = recorded_at,
    };
}

pub fn parseStatus(text: []const u8) !model.ActivityStatus {
    inline for (std.meta.fields(model.ActivityStatus)) |field| {
        if (std.ascii.eqlIgnoreCase(text, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return error.InvalidStatus;
}

pub fn parseDuration(text: []const u8) !u32 {
    var parts = std.mem.splitScalar(u8, text, ':');
    const first = parts.next() orelse return error.InvalidDuration;
    const second = parts.next() orelse {
        const minutes = std.fmt.parseInt(u32, first, 10) catch return error.InvalidDuration;
        const total = std.math.mul(u32, minutes, 60) catch return error.InvalidDuration;
        if (total == 0) return error.InvalidDuration;
        return total;
    };
    const third = parts.next();
    if (parts.next() != null) return error.InvalidDuration;

    if (third) |seconds_text| {
        const hours = std.fmt.parseInt(u32, first, 10) catch return error.InvalidDuration;
        const minutes = std.fmt.parseInt(u32, second, 10) catch return error.InvalidDuration;
        const seconds = std.fmt.parseInt(u32, seconds_text, 10) catch return error.InvalidDuration;
        if (minutes > 59 or seconds > 59) return error.InvalidDuration;
        const total = hours * 3600 + minutes * 60 + seconds;
        if (total == 0) return error.InvalidDuration;
        return total;
    }

    const minutes = std.fmt.parseInt(u32, first, 10) catch return error.InvalidDuration;
    const seconds = std.fmt.parseInt(u32, second, 10) catch return error.InvalidDuration;
    if (seconds > 59) return error.InvalidDuration;
    const total = minutes * 60 + seconds;
    if (total == 0) return error.InvalidDuration;
    return total;
}

test "validates useful coaching signals" {
    try validate(.{
        .status = .completed,
        .rpe = 7,
        .pain = 0,
        .notes = "Completed all six intervals.",
    });
    try validate(.{
        .distance_km = 8,
        .rpe = 6,
        .pain = 0,
    });
    try std.testing.expectError(error.RpeOutOfRange, validate(.{
        .distance_km = 8,
        .rpe = 11,
    }));
    try std.testing.expectError(error.ModifiedReasonRequired, validate(.{
        .status = .modified,
        .distance_km = 6,
    }));
}

test "duration parser" {
    try std.testing.expectEqual(@as(u32, 2640), try parseDuration("44"));
    try std.testing.expectEqual(@as(u32, 3179), try parseDuration("52:59"));
    try std.testing.expectEqual(@as(u32, 3790), try parseDuration("1:03:10"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("5:60"));
}
