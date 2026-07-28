const std = @import("std");
const model = @import("model.zig");

const Io = std.Io;

pub const DurationEstimate = struct {
    minimum_seconds: u32 = 0,
    maximum_seconds: u32 = 0,
    complete: bool = true,
};

pub fn durationEstimate(segments: []const model.Segment) DurationEstimate {
    var result: DurationEstimate = .{};
    for (segments) |segment| {
        const estimate = segmentDurationEstimate(segment);
        result.minimum_seconds += estimate.minimum_seconds;
        result.maximum_seconds += estimate.maximum_seconds;
        result.complete = result.complete and estimate.complete;
    }
    return result;
}

pub fn segmentDurationEstimate(segment: model.Segment) DurationEstimate {
    const repetitions: u32 = segment.repetitions;
    var result: DurationEstimate = .{};

    if (segment.distance_km) |distance_km| {
        const fast = segment.pace_fast_seconds_per_km orelse {
            result.complete = false;
            return result;
        };
        const slow = segment.pace_slow_seconds_per_km orelse {
            result.complete = false;
            return result;
        };
        result.minimum_seconds = secondsForDistance(distance_km, fast) * repetitions;
        result.maximum_seconds = secondsForDistance(distance_km, slow) * repetitions;
    } else if (segment.duration_seconds) |seconds| {
        result.minimum_seconds = seconds * repetitions;
        result.maximum_seconds = seconds * repetitions;
    } else if (!std.mem.eql(u8, segment.kind, "rest")) {
        result.complete = false;
    }

    if (segment.recovery_seconds) |recovery| {
        if (repetitions > 1) {
            const recovery_total = @as(u32, recovery) * (repetitions - 1);
            result.minimum_seconds += recovery_total;
            result.maximum_seconds += recovery_total;
        }
    }
    return result;
}

pub fn printDetails(writer: *Io.Writer, value: model.Workout, indent: []const u8) !void {
    for (value.segments) |segment| {
        try writer.print("{s}- {s}: ", .{ indent, segment.label });
        try printSegmentPrescription(writer, segment);
        try writer.writeByte('\n');
    }

    const estimate = durationEstimate(value.segments);
    const duration_is_already_shown = value.segments.len == 1 and
        value.segments[0].repetitions == 1;
    if (!duration_is_already_shown and
        value.segments.len > 0 and
        estimate.complete and
        estimate.maximum_seconds > 0)
    {
        if (value.distance_min_km != null and value.distance_min_km.? == 0 and
            value.distance_max_km != null and value.distance_max_km.? > 0)
        {
            try writer.print("{s}If run, expected total time: ", .{indent});
        } else {
            try writer.print("{s}Expected total time: ", .{indent});
        }
        try printDurationRange(writer, estimate.minimum_seconds, estimate.maximum_seconds);
        try writer.writeByte('\n');
    }
}

pub fn printSegmentPrescription(writer: *Io.Writer, segment: model.Segment) !void {
    if (segment.repetitions > 1) try writer.print("{d} × ", .{segment.repetitions});

    if (segment.distance_km) |distance_km| {
        try printDistance(writer, distance_km);
    } else if (segment.duration_seconds) |seconds| {
        try printDuration(writer, seconds);
    } else if (std.mem.eql(u8, segment.kind, "rest")) {
        try writer.writeAll("no running");
    } else {
        try writer.writeAll("effort-based");
    }

    if (segment.pace_fast_seconds_per_km != null and
        segment.pace_slow_seconds_per_km != null)
    {
        try writer.writeAll(" at ");
        try printPaceRange(
            writer,
            segment.pace_fast_seconds_per_km.?,
            segment.pace_slow_seconds_per_km.?,
        );

        const one_repetition = segment;
        const fast_seconds = secondsForDistance(
            one_repetition.distance_km.?,
            one_repetition.pace_fast_seconds_per_km.?,
        );
        const slow_seconds = secondsForDistance(
            one_repetition.distance_km.?,
            one_repetition.pace_slow_seconds_per_km.?,
        );
        try writer.writeAll(" (");
        try printDurationRange(writer, fast_seconds, slow_seconds);
        if (segment.repetitions > 1) try writer.writeAll(" each");
        try writer.writeByte(')');
    }

    if (segment.recovery_seconds) |seconds| {
        if (segment.repetitions > 1) {
            try writer.writeAll("; ");
            try printDuration(writer, seconds);
            try writer.writeAll(" easy recovery between repetitions");
        }
    }
    if (segment.notes.len != 0) try writer.print(". {s}", .{segment.notes});
}

pub fn printPaceRange(writer: *Io.Writer, fast: u32, slow: u32) !void {
    try printPace(writer, fast);
    if (fast != slow) {
        try writer.writeAll("–");
        try printPace(writer, slow);
    }
    try writer.writeAll("/km, ");
    try printSpeed(writer, slow);
    if (fast != slow) {
        try writer.writeAll("–");
        try printSpeed(writer, fast);
    }
    try writer.writeAll(" km/h");
}

pub fn printDurationRange(writer: *Io.Writer, minimum: u32, maximum: u32) !void {
    try printDuration(writer, minimum);
    if (minimum != maximum) {
        try writer.writeAll("–");
        try printDuration(writer, maximum);
    }
}

pub fn printDuration(writer: *Io.Writer, seconds: u32) !void {
    const hours = seconds / 3600;
    const minutes = (seconds % 3600) / 60;
    const remaining_seconds = seconds % 60;
    if (hours > 0) {
        try writer.print("{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, remaining_seconds });
    } else {
        try writer.print("{d}:{d:0>2}", .{ minutes, remaining_seconds });
    }
}

fn printPace(writer: *Io.Writer, seconds_per_km: u32) !void {
    try writer.print(
        "{d}:{d:0>2}",
        .{ seconds_per_km / 60, seconds_per_km % 60 },
    );
}

fn printSpeed(writer: *Io.Writer, seconds_per_km: u32) !void {
    const kilometers_per_hour = 3600.0 /
        @as(f64, @floatFromInt(seconds_per_km));
    try writer.print("{d:.1}", .{kilometers_per_hour});
}

fn printDistance(writer: *Io.Writer, distance_km: f64) !void {
    if (distance_km < 1) {
        try writer.print("{d:.0} m", .{distance_km * 1000});
    } else {
        try writer.print("{d:.1} km", .{distance_km});
    }
}

fn secondsForDistance(distance_km: f64, seconds_per_km: u16) u32 {
    return @intFromFloat(@round(distance_km * @as(f64, @floatFromInt(seconds_per_km))));
}

test "distance duration is derived from its pace range" {
    const segments = [_]model.Segment{.{
        .kind = "distance",
        .label = "Run",
        .distance_km = 8,
        .pace_fast_seconds_per_km = 375,
        .pace_slow_seconds_per_km = 420,
    }};
    const estimate = durationEstimate(&segments);
    try std.testing.expect(estimate.complete);
    try std.testing.expectEqual(@as(u32, 3000), estimate.minimum_seconds);
    try std.testing.expectEqual(@as(u32, 3360), estimate.maximum_seconds);
}

test "repeat duration includes recovery only between repetitions" {
    const segment: model.Segment = .{
        .kind = "repeat",
        .label = "Intervals",
        .repetitions = 5,
        .distance_km = 0.8,
        .pace_fast_seconds_per_km = 300,
        .pace_slow_seconds_per_km = 315,
        .recovery_seconds = 120,
    };
    const estimate = segmentDurationEstimate(segment);
    try std.testing.expectEqual(@as(u32, 1680), estimate.minimum_seconds);
    try std.testing.expectEqual(@as(u32, 1740), estimate.maximum_seconds);
}

test "pace range includes speed range in ascending order" {
    var output_buffer: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&output_buffer);

    try printPaceRange(&writer, 371, 416);

    try std.testing.expectEqualStrings(
        "6:11–6:56/km, 8.7–9.7 km/h",
        writer.buffered(),
    );
}

test "single segment details do not repeat the expected duration" {
    const segments = [_]model.Segment{.{
        .kind = "distance",
        .label = "Run",
        .distance_km = 6.5,
        .pace_fast_seconds_per_km = 371,
        .pace_slow_seconds_per_km = 416,
    }};
    const value: model.Workout = .{
        .id = 1,
        .schedule_id = 1,
        .date = "2026-07-27",
        .week = 1,
        .day = "Monday",
        .phase = "foundation",
        .kind = "easy",
        .intensity = "Easy",
        .distance_min_km = 6.5,
        .distance_max_km = 6.5,
        .details = "Easy run.",
        .segments = &segments,
        .recorded_at = 0,
    };
    var output_buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&output_buffer);

    try printDetails(&writer, value, "");

    try std.testing.expectEqualStrings(
        "- Run: 6.5 km at 6:11–6:56/km, 8.7–9.7 km/h (40:12–45:04)\n",
        writer.buffered(),
    );
}
