const std = @import("std");
const model = @import("model.zig");

pub const Input = struct {
    sleep_score: u8,
    readiness_score: u8,
    notes: []const u8 = "",
};

pub fn validate(input: Input) !void {
    if (input.sleep_score > 100) return error.SleepScoreOutOfRange;
    if (input.readiness_score > 100) return error.ReadinessScoreOutOfRange;
}

pub fn make(
    id: u64,
    supersedes_check_in_id: ?u64,
    date_text: []const u8,
    input: Input,
    recorded_at: i64,
) !model.MorningCheckIn {
    try validate(input);
    return .{
        .id = id,
        .supersedes_check_in_id = supersedes_check_in_id,
        .date = date_text,
        .sleep_score = input.sleep_score,
        .readiness_score = input.readiness_score,
        .notes = input.notes,
        .recorded_at = recorded_at,
    };
}

test "validates Oura scores" {
    try validate(.{ .sleep_score = 85, .readiness_score = 79 });
    try std.testing.expectError(
        error.SleepScoreOutOfRange,
        validate(.{ .sleep_score = 101, .readiness_score = 80 }),
    );
    try std.testing.expectError(
        error.ReadinessScoreOutOfRange,
        validate(.{ .sleep_score = 80, .readiness_score = 101 }),
    );
}
